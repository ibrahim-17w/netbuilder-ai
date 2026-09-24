"""The tool layer between the model and the network engine.

Spec §2: the LLM must never touch a .pkt file directly. It may only ask for
named, typed operations, and every operation here resolves to code that already
exists in this project:

* read tools  -> the offline audit (`pt_autopilot.pkt_audit_network`) and the
                 validator, plus the deterministic IPv4 helpers in this module;
* modify tools -> NOT applied here. They return a proposal for the app's
                 existing approval gate (`pkt_fix.apply_fixes`), because spec
                 §8 requires a human click before a change reaches a file.

So: reads are facts, writes are proposals. Nothing in this module writes a file.
"""
from __future__ import annotations

import ipaddress
from typing import Any

# --------------------------------------------------------------------------
# deterministic networking (spec §5) - the engine decides, not the model
# --------------------------------------------------------------------------


def parse_cidr(text: str):
    try:
        return ipaddress.ip_interface(str(text).strip())
    except Exception:  # noqa: BLE001 - bad input is a normal answer, not a crash
        return None


def subnet_facts(cidr: str) -> dict | None:
    iface = parse_cidr(cidr)
    if iface is None:
        return None
    net = iface.network
    hosts = list(net.hosts())
    return {
        "address": str(iface.ip),
        "prefix": net.prefixlen,
        "network": str(net.network_address),
        "broadcast": str(net.broadcast_address),
        "netmask": str(net.netmask),
        "firstHost": str(hosts[0]) if hosts else "",
        "lastHost": str(hosts[-1]) if hosts else "",
        "usableHosts": max(len(hosts), 0),
    }


def same_subnet(a: str, b: str) -> bool:
    ia, ib = parse_cidr(a), parse_cidr(b)
    if ia is None or ib is None:
        return False
    if ia.network.prefixlen != ib.network.prefixlen:
        return False
    return ia.network.network_address == ib.network.network_address


def contains(cidr: str, address: str) -> bool:
    iface = parse_cidr(cidr)
    if iface is None:
        return False
    try:
        return ipaddress.ip_address(str(address).strip()) in iface.network
    except Exception:  # noqa: BLE001
        return False


def check_gateway(host_cidr: str, gateway: str) -> dict:
    """A gateway must be a usable address inside the host's own subnet."""
    facts = subnet_facts(host_cidr)
    if facts is None:
        return {"ok": False, "reason": f"the host address `{host_cidr}` is not valid"}
    if parse_cidr(gateway) is None and not _is_plain_ip(gateway):
        return {"ok": False, "reason": f"the gateway `{gateway}` is not valid"}
    if not contains(host_cidr, gateway):
        return {
            "ok": False,
            "reason": f"{gateway} is outside {facts['network']}/{facts['prefix']}",
            "subnet": facts,
        }
    if gateway in (facts["network"], facts["broadcast"]):
        return {"ok": False, "reason": f"{gateway} is a reserved address", "subnet": facts}
    if gateway == facts["address"]:
        return {"ok": False, "reason": "the gateway is the host itself", "subnet": facts}
    return {"ok": True, "reason": f"{gateway} is usable inside "
            f"{facts['network']}/{facts['prefix']}", "subnet": facts}


def _is_plain_ip(text: str) -> bool:
    try:
        ipaddress.ip_address(str(text).strip())
        return True
    except Exception:  # noqa: BLE001
        return False


def duplicate_addresses(interfaces: list[dict]) -> list[dict]:
    seen: dict[str, list[str]] = {}
    for entry in interfaces:
        ip = str(entry.get("ipCidr") or "").split("/")[0]
        if not ip:
            continue
        seen.setdefault(ip, []).append(
            f"{entry.get('node', '?')} {entry.get('iface', '')}".strip())
    return [{"address": ip, "usedBy": who}
            for ip, who in sorted(seen.items()) if len(who) > 1]


# --------------------------------------------------------------------------
# the registry: every tool the model may request
# --------------------------------------------------------------------------

# kind: "read" never changes anything; "modify" only ever returns a proposal.
TOOLS: dict[str, dict] = {
    "get_topology": {"kind": "read", "args": {},
                     "summary": "devices and links of the opened capture"},
    "get_devices": {"kind": "read", "args": {},
                    "summary": "every device with its type and model"},
    "get_device": {"kind": "read", "args": {"device": "string"},
                   "summary": "one device"},
    "get_interfaces": {"kind": "read", "args": {"device": "string"},
                       "summary": "interfaces and addresses of one device"},
    "get_device_config": {"kind": "read", "args": {"device": "string"},
                          "summary": "the saved CLI configuration of one device"},
    "get_vlans": {"kind": "read", "args": {}, "summary": "VLANs in the capture"},
    "get_links": {"kind": "read", "args": {}, "summary": "cabling"},
    "get_routing_table": {"kind": "read", "args": {"device": "string"},
                          "summary": "routes of one device"},
    "get_network_summary": {"kind": "read", "args": {},
                            "summary": "counts, addressing and findings at a glance"},
    "check_connectivity": {"kind": "read",
                           "args": {"source": "string", "destination": "string"},
                           "summary": "can source reach destination, and where it breaks"},
    "check_subnet": {"kind": "read",
                     "args": {"device1": "string", "device2": "string"},
                     "summary": "are two devices in the same subnet"},
    "check_gateway": {"kind": "read", "args": {"device": "string"},
                      "summary": "is this device's default gateway valid"},
    "check_routes": {"kind": "read", "args": {}, "summary": "routing problems"},
    "check_vlans": {"kind": "read", "args": {}, "summary": "VLAN problems"},
    "check_dhcp": {"kind": "read", "args": {}, "summary": "DHCP problems"},
    "check_acls": {"kind": "read", "args": {}, "summary": "ACL problems"},
    "analyze_network": {"kind": "read", "args": {},
                        "summary": "the full audit: observed facts + findings"},
    "verify_repair": {"kind": "read",
                      "args": {"before": "object",
                               "after": "object",
                               "fixes": "array"},
                      "summary": "check whether an approved fix"
                                 " actually cleared the finding"},
    "validate_network": {"kind": "read", "args": {},
                         "summary": "the structural validator's verdict"},
    # --- modifying: proposals only, always behind the approval gate ---------
    "set_ip": {"kind": "modify",
               "args": {"device": "string", "interface": "string",
                        "cidr": "string"},
               "summary": "propose an interface address change"},
    "set_subnet_mask": {"kind": "modify",
                       "args": {"device": "string",
                                "interface": "string",
                                "mask": "string"},
                       "summary": "propose a subnet-mask change"},
    "set_gateway": {"kind": "modify",
                    "args": {"device": "string", "gateway": "string"},
                    "summary": "propose a default-gateway change"},
    "enable_interface": {"kind": "modify",
                         "args": {"device": "string", "interface": "string"},
                         "summary": "propose bringing an interface up"},
    "disable_interface": {"kind": "modify",
                          "args": {"device": "string", "interface": "string"},
                          "summary": "propose shutting an interface down"},
    "configure_vlan": {"kind": "modify",
                       "args": {"device": "string", "vlan": "string",
                                "name": "string"},
                       "summary": "propose creating a VLAN"},
    "configure_route": {"kind": "modify",
                        "args": {"device": "string", "network": "string",
                                 "nextHop": "string"},
                        "summary": "propose a static route"},
    "configure_ospf": {"kind": "modify",
                       "args": {"device": "string", "network": "string",
                                "area": "string"},
                       "summary": "propose an OSPF network statement"},
    "configure_dhcp": {"kind": "modify",
                       "args": {"device": "string", "pool": "string",
                                "network": "string"},
                       "summary": "propose a DHCP pool"},
    "connect_devices": {"kind": "modify",
                        "args": {"a": "string", "b": "string"},
                        "summary": "propose a cable"},
    "disconnect_devices": {"kind": "modify",
                           "args": {"a": "string", "b": "string"},
                           "summary": "propose removing a cable"},
    "save_pkt": {"kind": "modify", "args": {"name": "string"},
                 "summary": "propose writing the fixed capture to the output folder"},
}


def _finding_map(audit: dict) -> dict:
    """Every finding in the capture, keyed by its stable id."""
    out = {}
    for device in _devices(audit):
        for finding in (device.get("findings") or []):
            if not isinstance(finding, dict):
                continue
            fid = str(finding.get("id") or "")
            if not fid:
                continue
            out[fid] = {
                "device": device.get("name"),
                "severity": finding.get("severity"),
                "title": finding.get("title")
                or finding.get("message")
                or finding.get("detail")
                or fid,
            }
    return out


def verify_repair(before: dict, after: dict, fixes: list) -> dict:
    """Did an approved fix actually change what the audit reports?

    The honest answer comes from comparing the re-audited capture against the
    original one, not from trusting the fix that was applied. A finding that
    is gone is verified fixed; one that survives is reported as still broken;
    and anything the fix introduced is called out rather than hidden.
    """
    was = _finding_map(before or {})
    now = _finding_map(after or {})

    targeted = set()
    for fix in fixes or []:
        if isinstance(fix, dict):
            fid = fix.get("id") or fix.get("findingId") or fix.get("finding")
            if fid:
                targeted.add(str(fid))

    resolved = sorted(fid for fid in targeted if fid in was and fid not in now)
    still = sorted(fid for fid in targeted if fid in now)
    introduced = sorted(fid for fid in now if fid not in was)

    if not now and was:
        # The re-read produced no findings at all: that is not a clean bill of
        # health, it means the second audit could not see the capture.
        verdict, summary = "unverified", (
            "The re-audit returned nothing, so it cannot confirm the fix. "
            "This is not the same as the problem being gone."
        )
    elif targeted and resolved and not still:
        verdict, summary = "fixed", (
            "Verified: the re-audit no longer reports "
            + ", ".join(resolved)
            + "."
        )
    elif targeted and still and not resolved:
        verdict, summary = "not_fixed", (
            "Still broken: the re-audit reports "
            + ", ".join(still)
            + " after the fix."
        )
    elif resolved and still:
        verdict, summary = "partly_fixed", (
            "Partly fixed: cleared " + ", ".join(resolved)
            + ", but " + ", ".join(still) + " remain."
        )
    elif not targeted:
        verdict, summary = "unverified", (
            "None of the approved fixes named a finding this verifier can "
            "match, so nothing could be confirmed."
        )
    else:
        verdict, summary = "unchanged", (
            "The re-audit reports the same findings as before, so the fix "
            "did not change them."
        )

    if introduced:
        summary += (
            " The fix also introduced "
            + ", ".join(introduced)
            + ", which was not present before."
        )

    return {
        "verdict": verdict,
        "summary": summary,
        "verified": verdict == "fixed",
        "resolved": [{"id": fid, **was[fid]} for fid in resolved],
        "stillBroken": [{"id": fid, **now[fid]} for fid in still],
        "introduced": [{"id": fid, **now[fid]} for fid in introduced],
        "countsBefore": len(was),
        "countsAfter": len(now),
    }


def list_tools() -> dict:
    return {
        "ok": True,
        "count": len(TOOLS),
        "tools": [
            {"name": name, **spec} for name, spec in sorted(TOOLS.items())
        ],
    }


class ToolError(RuntimeError):
    """A tool could not answer - message is meant for the chat."""


def call(name: str, args: dict, audit: dict) -> dict:
    """Run one tool. [audit] is the report from pt_autopilot.pkt_audit_network."""
    spec = TOOLS.get(name)
    if spec is None:
        raise ToolError(f"no such tool: `{name}`")
    args = args or {}
    if spec["kind"] == "modify":
        # Spec §8: never apply. Hand back a proposal for the approval gate.
        return {
            "tool": name,
            "kind": "modify",
            "requiresApproval": True,
            "proposal": {"tool": name, "args": args,
                         "note": "approve in the chat to apply this change"},
        }
    return _read(name, args, audit)


def _devices(audit: dict) -> list[dict]:
    return [dict(d) for d in (audit.get("devices") or [])]


def _find(audit: dict, name: str) -> dict:
    wanted = str(name or "").strip().lower()
    for d in _devices(audit):
        if str(d.get("name", "")).lower() == wanted:
            return d
    raise ToolError(f"there is no device `{name}` in this capture")


def _interfaces(audit: dict) -> list[dict]:
    out = []
    for d in _devices(audit):
        for i in (d.get("interfaces") or []):
            out.append(dict(i))
    return out


def _findings(audit: dict, needle: str = "") -> list[dict]:
    out = []
    for d in _devices(audit):
        for f in (d.get("findings") or []):
            row = dict(f)
            if needle and needle not in str(row.get("id", "")):
                continue
            out.append(row)
    return out


def _read(name: str, args: dict, audit: dict) -> dict:
    # This one compares two audits rather than reading one, so it is
    # answered from its arguments before anything else.
    if name == "verify_repair":
        return verify_repair(
            args.get("before") or {},
            args.get("after") or {},
            args.get("fixes") or [],
        )
    if name == "get_topology":
        return {"devices": [{"name": d.get("name"), "type": d.get("type")}
                            for d in _devices(audit)],
                "links": audit.get("links") or []}
    if name == "get_devices":
        return {"devices": [{"name": d.get("name"), "type": d.get("type"),
                             "model": d.get("model")} for d in _devices(audit)]}
    if name == "get_device":
        d = _find(audit, args.get("device"))
        return {"device": {"name": d.get("name"), "type": d.get("type"),
                           "model": d.get("model"),
                           "interfaceCount": len(d.get("interfaces") or [])}}
    if name == "get_interfaces":
        d = _find(audit, args.get("device"))
        return {"device": d.get("name"), "interfaces": d.get("interfaces") or []}
    if name == "get_device_config":
        d = _find(audit, args.get("device"))
        return {"device": d.get("name"),
                "config": d.get("config") or d.get("runningConfig") or "",
                "note": "read-only: the saved configuration as found"}
    if name == "get_vlans":
        return {"vlans": audit.get("vlans") or []}
    if name == "get_links":
        return {"links": audit.get("links") or []}
    if name == "get_routing_table":
        d = _find(audit, args.get("device"))
        return {"device": d.get("name"), "routes": d.get("routes") or []}
    if name == "get_network_summary":
        interfaces = _interfaces(audit)
        return {
            "devices": len(_devices(audit)),
            "links": len(audit.get("links") or []),
            "interfaces": len(interfaces),
            "findings": len(_findings(audit)),
            "duplicateAddresses": duplicate_addresses(interfaces),
            "withAddresses": [i for i in interfaces if i.get("ipCidr")][:40],
        }
    if name == "check_subnet":
        a = _first_address(audit, args.get("device1"))
        b = _first_address(audit, args.get("device2"))
        return {"device1": args.get("device1"), "device2": args.get("device2"),
                "address1": a, "address2": b,
                "sameSubnet": same_subnet(a, b),
                "reason": ("the masks differ, so they can never share a subnet"
                           if a and b and
                           (parse_cidr(a).network.prefixlen !=
                            parse_cidr(b).network.prefixlen)
                           else "")}
    if name == "check_gateway":
        device = _find(audit, args.get("device"))
        gateway = _gateway_of(device)
        host = _first_address(audit, args.get("device"))
        if not gateway:
            return {"device": device.get("name"), "gateway": "",
                    "ok": False,
                    "reason": "no default gateway is configured"}
        return {"device": device.get("name"), "gateway": gateway,
                "host": host, **check_gateway(host, gateway)}
    if name == "check_connectivity":
        return _connectivity(audit, str(args.get("source")),
                             str(args.get("destination")))
    if name in ("analyze_network", "validate_network"):
        return {"findings": _findings(audit),
                "summary": audit.get("summary"),
                "verdict": "no findings" if not _findings(audit)
                else f"{len(_findings(audit))} finding(s) to review"}
    if name == "check_routes":
        return {"findings": [f for f in _findings(audit)
                             if "rout" in str(f.get("text", "")).lower()]}
    if name == "check_vlans":
        return {"findings": [f for f in _findings(audit)
                             if "vlan" in str(f.get("text", "")).lower()],
                "vlans": audit.get("vlans") or []}
    if name == "check_dhcp":
        return {"findings": [f for f in _findings(audit)
                             if "dhcp" in str(f.get("text", "")).lower()]}
    if name == "check_acls":
        return {"findings": [f for f in _findings(audit)
                             if "acl" in str(f.get("text", "")).lower()]}
    raise ToolError(f"tool `{name}` is declared but not implemented")


def _first_address(audit: dict, device: str) -> str:
    d = _find(audit, device)
    for i in (d.get("interfaces") or []):
        if i.get("ipCidr"):
            return str(i["ipCidr"])
    return ""


def _gateway_of(device: dict) -> str:
    for key in ("gateway", "defaultGateway"):
        if device.get(key):
            return str(device[key])
    for i in (device.get("interfaces") or []):
        if i.get("gateway"):
            return str(i["gateway"])
    return ""


def _connectivity(audit: dict, source: str, destination: str) -> dict:
    """Deterministic reachability over the saved topology.

    Deliberately conservative: it reports what the file proves (same subnet, or
    a path through devices that carry the address) and says which step could
    not be confirmed, instead of guessing.
    """
    src_ip = _first_address(audit, source)
    dst_ip = _first_address(audit, destination)
    if not src_ip or not dst_ip:
        return {
            "source": source, "destination": destination,
            "reachable": None,
            "reason": "one of the devices has no address in the capture, so "
                      "reachability cannot be determined from the file",
        }
    if same_subnet(src_ip, dst_ip):
        return {
            "source": source, "destination": destination,
            "sourceAddress": src_ip, "destinationAddress": dst_ip,
            "reachable": True,
            "reason": f"both are inside {subnet_facts(src_ip)['network']}"
                      f"/{subnet_facts(src_ip)['prefix']}",
        }
    # Different subnets: only a device that has an interface in BOTH subnets
    # can bridge them in the saved state.
    bridges = []
    for d in _devices(audit):
        addrs = [str(i.get("ipCidr")) for i in (d.get("interfaces") or [])
                 if i.get("ipCidr")]
        if any(contains(a, src_ip.split("/")[0]) for a in addrs) and \
           any(contains(a, dst_ip.split("/")[0]) for a in addrs):
            bridges.append(d.get("name"))
    if bridges:
        return {
            "source": source, "destination": destination,
            "sourceAddress": src_ip, "destinationAddress": dst_ip,
            "reachable": None,
            "bridgingDevices": bridges,
            "reason": "the subnets differ; " + ", ".join(bridges) +
                      " has an interface in both, so routing decides it - the "
                      "saved routes must carry the prefix",
        }
    return {
        "source": source, "destination": destination,
        "sourceAddress": src_ip, "destinationAddress": dst_ip,
        "reachable": False,
        "reason": "the addresses are in different subnets and no device has an "
                  "interface in both",
    }
