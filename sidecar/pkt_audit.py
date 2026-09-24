"""Deep offline .pkt analysis: audit, diff, grade.

Complements pt_autopilot.pkt_audit_network (which reports device/interface
state): this module reads the SERVICE panels, VLAN table and AAA state from
the decoded save, diffs two saves, and grades a save against a target plan.

Pure file work - no Packet Tracer, no GUI, importable without UIA.
"""

from __future__ import annotations

import ipaddress
import re
from typing import Dict, List, Optional, Tuple

import pkt_builder


# --------------------------------------------------------------------------
# Decoding helpers
# --------------------------------------------------------------------------

def decode(path: str) -> bytes:
    """Decode a .pkt to its raw XML bytes (raises PktFormatError)."""
    return pkt_builder.decode_pkt_file(path)


def _text(block: bytes, tag: str) -> str:
    m = re.search(rb"<" + tag.encode() + rb"[^>]*>([^<]*)<", block, re.S)
    return m.group(1).decode("utf-8", "replace").strip() if m else ""


def _enabled(block: bytes, tag: str) -> bool:
    m = re.search(rb"<" + tag.encode() + rb"[^>]*><ENABLED>([01])", block, re.S)
    if not m:
        m = re.search(rb"<" + tag.encode() + rb"><ENABLED>([01])", block, re.S)
    return bool(m and m.group(1) == b"1")


def devices(xml: bytes) -> List[dict]:
    """Device inventory: name, kind, model, config lines, interface IPs."""
    out = []
    for block in re.findall(rb"<DEVICE>.*?</DEVICE>", xml, re.S):
        name = _text(block, "NAME")
        m = re.search(rb'<TYPE customModel="[^"]*" model="([^"]*)">([^<]*)<',
                      block)
        model = m.group(1).decode("utf-8", "replace") if m else ""
        kind = m.group(2).decode("utf-8", "replace") if m else ""
        ips = sorted(set(re.findall(rb"IP_ADDRESS>(\d+\.\d+\.\d+\.\d+)<",
                                    block))
                     | set(re.findall(rb"<IP>(\d+\.\d+\.\d+\.\d+)</IP>",
                                      block)))
        config = ""
        cm = re.search(rb"<RUNNINGCONFIG>(.*?)</RUNNINGCONFIG>", block, re.S)
        if cm:
            config = cm.group(1).decode("utf-8", "replace")
        ref = re.search(rb"save-ref-id:(\d+)", block)
        out.append({
            "name": name,
            "kind": kind,
            "model": model,
            "ips": [ip.decode() for ip in ips],
            "config_lines": config.count("\n") + (1 if config.strip() else 0),
            "config": config,
            "ref": ref.group(1).decode() if ref else "",
        })
    return out


def links(xml: bytes) -> List[dict]:
    """Cable inventory: which device/port connects to which.

    Links reference devices by their save-ref-id, so the id->name map is
    built from the DEVICE blocks first.
    """
    ref_to_name = {d["ref"]: d["name"] for d in devices(xml) if d["ref"]}
    out = []
    for block in re.findall(rb"<LINK>.*?</LINK>", xml, re.S):
        cable = re.search(rb"<CABLE>(.*?)</CABLE>", block, re.S)
        if not cable:
            continue
        body = cable.group(1)
        ports = re.findall(rb"<PORT>([^<]*)</PORT>", body)
        refs = re.findall(rb"<(?:FROM|TO)>save-ref-id:(\d+)<", body)
        if len(refs) < 2:
            continue
        a = ref_to_name.get(refs[0].decode(), "?")
        b = ref_to_name.get(refs[1].decode(), "?")
        out.append({
            "a": a,
            "aIf": ports[0].decode("utf-8", "replace") if ports else "",
            "b": b,
            "bIf": ports[1].decode("utf-8", "replace") if len(ports) > 1
                   else "",
        })
    return out


def vlans(xml: bytes) -> List[dict]:
    """VLAN database entries found anywhere in the save."""
    out = []
    seen = set()
    for m in re.finditer(
            rb"<VLAN[^>]*>(?:<NAME>([^<]*)</NAME>)?(?:<ID>(\d+)</ID>)?",
            xml, re.S):
        vid = m.group(2)
        if not vid:
            continue
        key = vid.decode()
        if key in seen:
            continue
        seen.add(key)
        out.append({"id": int(key), "name": (m.group(1) or b"").decode()})
    return out


# --------------------------------------------------------------------------
# Service inventory + audit
# --------------------------------------------------------------------------

_SERVICE_PROBES = (
    # (panel tag, service name, extra parse)
    ("DHCP_SERVERS", "dhcp", None),
    ("DNS_SERVER", "dns", None),
    ("HTTP_SERVER", "http", None),
    ("HTTPS_SERVER", "https", None),
    ("FTP_SERVER", "ftp", None),
    ("EMAIL_SERVER", "email", None),
    ("NTP_SERVER", "ntp", None),
    ("TFTP_SERVER", "tftp", None),
    ("SYSLOG_SERVER", "syslog", None),
    ("ACS_SERVER", "aaa", "aaa"),
    ("DHCPV6_SERVER_LIST", "dhcpv6", None),
    ("SNMP_MANAGER", "snmp", None),
    ("IOE_USER_MANAGER", "iot", None),
    ("IOX_VM_MANAGER", "vm", None),
    ("REGISTRATION_SEVER", "iot", None),
)


def server_services(xml: bytes) -> Dict[str, List[dict]]:
    """device name -> [{service, enabled, detail}] for every server panel."""
    out: Dict[str, List[dict]] = {}
    for block in re.findall(rb"<DEVICE>.*?</DEVICE>", xml, re.S):
        name = _text(block, "NAME")
        if not name:
            continue
        rows = []
        for tag, svc, extra in _SERVICE_PROBES:
            m = re.search(rb"<" + tag.encode() + rb"[^>]*>(.*?)</" +
                          tag.encode() + rb">", block, re.S)
            if not m:
                continue
            body = m.group(1)
            enabled = b"<ENABLED>1" in body
            detail = ""
            if extra == "aaa":
                users = len(re.findall(rb"<USERNAME>", body))
                clients = len(re.findall(rb"<CLIENT_NAME>", body))
                detail = f"{users} user(s), {clients} client(s)"
            elif tag == "DHCP_SERVERS":
                pools = len(re.findall(rb"<DHCP_SERVER><ENABLED>", body))
                detail = f"{pools} pool(s)"
            elif tag == "DNS_SERVER":
                records = len(re.findall(rb"<NAME_ALIAS>", body))
                detail = f"{records} record(s)"
            if enabled or detail:
                rows.append({"service": svc, "enabled": enabled,
                             "detail": detail})
        if rows:
            out[name] = rows
    return out


def aaa_state(xml: bytes) -> Dict[str, dict]:
    """Per-device AAA panel state: enabled, users, clients (with type)."""
    out: Dict[str, dict] = {}
    for block in re.findall(rb"<DEVICE>.*?</DEVICE>", xml, re.S):
        name = _text(block, "NAME")
        m = re.search(rb"<ACS_SERVER[^>]*>(.*?)</ACS_SERVER>", block, re.S)
        if not m or not name:
            continue
        body = m.group(1)
        # the builder writes <USER><NAME>; real PT saves may use <USERNAME>
        users = re.findall(rb"<(?:USERNAME|NAME)>([^<]*)</(?:USERNAME|NAME)>",
                           body)
        clients = []
        for cm in re.finditer(
                rb"<CLIENT>(.*?)</CLIENT>", body, re.S):
            cb = cm.group(1)
            cname = re.search(rb"<(?:CLIENT_NAME|DESCRIPTION)>([^<]*)<", cb)
            cip = re.search(rb"<HOST_IP>([^<]*)<", cb)
            ctype = re.search(rb"<SERVER_TYPE>([^<]*)<", cb)
            clients.append({
                "name": (cname.group(1) if cname else
                         (cip or b"")).decode("utf-8", "replace"),
                "ip": (cip.group(1) if cip else b"").decode("utf-8", "replace"),
                "type": (ctype.group(1) if ctype else b"").decode(
                    "utf-8", "replace"),
            })
        out[name] = {
            "enabled": b"<ENABLED>1" in body,
            "users": [u.decode("utf-8", "replace") for u in users],
            "clients": clients,
        }
    return out


def audit(path: str, project: str = "") -> dict:
    """Full offline audit: devices, services, VLANs, AAA, findings."""
    xml = decode(path)
    devs = devices(xml)
    svcs = server_services(xml)
    aaa = aaa_state(xml)
    vlan_rows = vlans(xml)
    cable_rows = links(xml)

    findings: List[dict] = []
    counter = {"n": 0}

    def add(severity: str, device: str, text: str) -> None:
        counter["n"] += 1
        findings.append({"id": f"deep:{counter['n']}", "severity": severity,
                         "device": device, "text": text})

    by_name = {d["name"]: d for d in devs}
    for name, state in aaa.items():
        if state["enabled"] and not state["users"]:
            add("high", name, "AAA is ON but has no user accounts - logins "
                              "against it can never succeed")
        if state["enabled"] and not state["clients"]:
            add("high", name, "AAA is ON but has no client entries - no "
                              "router/NAS is registered to use it")
        if state["enabled"] and state["users"] and state["clients"]:
            for c in state["clients"]:
                router = by_name.get(c["name"])
                if router is None:
                    add("medium", name,
                        f"AAA client '{c['name']}' does not match any device "
                        "on the canvas")
                elif not any("tacacs" in router["config"].lower() or
                             "radius" in router["config"].lower()
                             for _ in [0]):
                    pass  # router-side check below

    # routers configured for AAA whose server panel is not enabled
    for d in devs:
        cfg = d["config"].lower()
        if "aaa new-model" in cfg or "tacacs-server host" in cfg \
                or "radius-server host" in cfg:
            srv = aaa.get(d["name"], {}).get("enabled", False)
            if not srv:
                # expected: the router is the CLIENT, the server runs the
                # panel - only flag when no AAA-enabled server exists at all
                if not any(s.get("enabled") for s in aaa.values()):
                    add("high", d["name"],
                        "router asks for AAA but no server has the AAA "
                        "panel enabled")

    # gateways: every subnet present on a PC/server should have a router IP
    router_ips = set()
    for d in devs:
        if "router" in d["kind"].lower() or "switch" in d["kind"].lower():
            router_ips.update(d["ips"])
    for d in devs:
        if not (d["kind"].lower() in ("pc", "laptop", "server", "printer")
                or "pc" in d["kind"].lower()):
            continue
        for ip_s in d["ips"]:
            try:
                net = ipaddress.ip_network(f"{ip_s}/24", strict=False)
            except ValueError:
                continue
            gw = net.network_address + 1
            if str(gw) not in router_ips:
                add("medium", d["name"],
                    f"no device holds {gw} (the usual gateway for {ip_s})")

    # DHCP pools vs subnet size
    for block in re.findall(rb"<DEVICE>.*?</DEVICE>", xml, re.S):
        name = _text(block, "NAME")
        for pm in re.finditer(
                rb"<START_IP>([^<]*)</START_IP>.*?<END_IP>([^<]*)</END_IP>",
                block, re.S):
            try:
                start = ipaddress.ip_address(pm.group(1).decode())
                end = ipaddress.ip_address(pm.group(2).decode())
            except ValueError:
                continue
            size = int(end) - int(start) + 1
            if size <= 0:
                add("high", name, f"DHCP pool is inverted "
                                  f"({pm.group1 if False else pm.group(1).decode()} "
                                  f"> {pm.group(2).decode()})")
            elif size < 5:
                add("info", name, f"DHCP pool only has {size} address(es)")

    return {
        "mode": "deep-offline",
        "path": path,
        "project": project,
        "devices": [
            {k: d[k] for k in ("name", "kind", "model", "ips",
                               "config_lines")} for d in devs
        ],
        "services": svcs,
        "aaa": aaa,
        "vlans": vlan_rows,
        "links": cable_rows,
        "findings": findings,
        "summary": {
            "devices": len(devs),
            "links": len(cable_rows),
            "servicesEnabled": sum(
                1 for rows in svcs.values() for r in rows if r["enabled"]),
            "findings": len(findings),
            "high": sum(1 for f in findings if f["severity"] == "high"),
        },
    }


# --------------------------------------------------------------------------
# Diff
# --------------------------------------------------------------------------

def _config_set(config: str) -> set:
    """Normalized config lines for diffing (order-insensitive)."""
    out = set()
    for line in (config or "").splitlines():
        line = line.strip()
        if line and not line.startswith("!"):
            out.add(re.sub(r"\s+", " ", line).lower())
    return out


def diff(path_a: str, path_b: str) -> dict:
    """What changed between two saves: devices, links, services, configs."""
    ax, bx = decode(path_a), decode(path_b)
    a_devs = {d["name"]: d for d in devices(ax)}
    b_devs = {d["name"]: d for d in devices(bx)}
    a_svc = server_services(ax)
    b_svc = server_services(bx)

    added = sorted(set(b_devs) - set(a_devs))
    removed = sorted(set(a_devs) - set(b_devs))

    config_changes = []
    for name in sorted(set(a_devs) & set(b_devs)):
        ca = _config_set(a_devs[name]["config"])
        cb = _config_set(b_devs[name]["config"])
        added_lines = sorted(cb - ca)
        removed_lines = sorted(ca - cb)
        if added_lines or removed_lines:
            config_changes.append({
                "device": name,
                "added": added_lines[:40],
                "removed": removed_lines[:40],
            })

    service_changes = []
    for name in sorted(set(a_svc) | set(b_svc)):
        sa = {r["service"]: r["enabled"] for r in a_svc.get(name, [])}
        sb = {r["service"]: r["enabled"] for r in b_svc.get(name, [])}
        for svc in sorted(set(sa) | set(sb)):
            if sa.get(svc) != sb.get(svc):
                service_changes.append({
                    "device": name, "service": svc,
                    "was": sa.get(svc, False), "now": sb.get(svc, False),
                })

    la = {(l["a"], l["aIf"], l["b"], l["bIf"]) for l in links(ax)}
    lb = {(l["a"], l["aIf"], l["b"], l["bIf"]) for l in links(bx)}
    return {
        "pathA": path_a,
        "pathB": path_b,
        "devicesAdded": added,
        "devicesRemoved": removed,
        "linksAdded": sorted(f"{a}:{aif} -> {b}:{bif}"
                             for a, aif, b, bif in lb - la),
        "linksRemoved": sorted(f"{a}:{aif} -> {b}:{bif}"
                               for a, aif, b, bif in la - lb),
        "configChanges": config_changes,
        "serviceChanges": service_changes,
        "unchanged": (not added and not removed and not config_changes
                      and not service_changes and la == lb),
    }


# --------------------------------------------------------------------------
# Grade against a target plan
# --------------------------------------------------------------------------

def _plan_servers(plan: dict) -> Dict[str, List[str]]:
    out: Dict[str, List[str]] = {}
    for n in plan.get("nodes") or []:
        svcs = [str(s).lower() for s in (n.get("services") or [])]
        if svcs:
            out[str(n.get("name") or "")] = svcs
    return out


def grade(path: str, plan: dict) -> dict:
    """Score a saved .pkt against the plan it was supposed to implement.

    Rubric (each requirement is a row): device presence, links, addressing
    (node IPs), every planned service enabled with the right panel, AAA
    users+clients, and the router side of AAA in its config.
    """
    xml = decode(path)
    devs = {d["name"]: d for d in devices(xml)}
    svcs = server_services(xml)
    aaa = aaa_state(xml)
    got_links = links(xml)

    reqs: List[dict] = []

    def req(name: str, ok: bool, detail: str) -> None:
        reqs.append({"name": name, "ok": bool(ok), "detail": detail})

    # devices
    planned_nodes = [n for n in (plan.get("nodes") or [])
                     if isinstance(n, dict) and n.get("name")]
    for n in planned_nodes:
        name = str(n["name"])
        req(f"device {name}", name in devs,
            "present" if name in devs else "missing from the file")

    # links (unordered pair match on device names)
    planned_pairs = set()
    for l in plan.get("links") or []:
        a, b = str(l.get("a") or ""), str(l.get("b") or "")
        if a and b:
            planned_pairs.add(frozenset((a, b)))
    got_pairs = {frozenset((l["a"], l["b"])) for l in got_links
                 if l["a"] and l["b"]}
    for pair in planned_pairs:
        a, b = sorted(pair)
        req(f"link {a}<->{b}", pair in got_pairs,
            "cabled" if pair in got_pairs else "missing cable")

    # addressing
    for a in plan.get("addressing") or []:
        if not isinstance(a, dict):
            continue
        node = str(a.get("node") or "")
        cidr = str(a.get("ipCidr") or "")
        ip = cidr.split("/")[0]
        if not node or ip in ("", "0.0.0.0"):
            continue
        d = devs.get(node)
        ok = d is not None and ip in d["ips"]
        req(f"ip {node}={ip}", ok,
            "set" if ok else ("device missing" if d is None
                              else f"device has {', '.join(d['ips'] or ['no IP'])}"))

    # services
    for srv_name, wanted in _plan_servers(plan).items():
        got = {r["service"]: r for r in svcs.get(srv_name, [])}
        for svc in wanted:
            if svc in ("pc", "laptop"):
                continue
            row = got.get(svc)
            ok = row is not None and row["enabled"]
            req(f"service {svc} on {srv_name}", ok,
                "enabled" if ok else ("present but off" if row
                                      else "panel not configured"))

    # AAA both ends
    sec = plan.get("security") or {}
    if isinstance(sec, dict) and sec.get("requested"):
        proto = str(sec.get("aaaProtocol") or "tacacs+").lower()
        want_type = "RADIUS" if "radius" in proto else "TACACS"
        srv_name = str(sec.get("aaaServer") or "")
        any_aaa_on = any(s.get("enabled") for s in aaa.values())
        req("AAA server panel", any_aaa_on,
            "enabled" if any_aaa_on else "no server has AAA on")
        if srv_name and srv_name in aaa:
            st = aaa[srv_name]
            req("AAA users", bool(st["users"]),
                f"{len(st['users'])} user(s)")
            clients_ok = any(c["type"].upper().startswith(want_type)
                             for c in st["clients"])
            req(f"AAA client ({want_type})", clients_ok,
                f"{len(st['clients'])} client(s)")
        # router side
        router_ok = False
        for d in devs.values():
            cfg = d["config"].lower()
            if ("aaa new-model" in cfg and
                    (("tacacs-server" in cfg) if want_type == "TACACS"
                     else ("radius-server" in cfg))):
                router_ok = True
                break
        req("AAA router config", router_ok,
            "new-model + server host found" if router_ok
            else f"no router runs aaa new-model + {want_type.lower()}-server")

    passed = sum(1 for r in reqs if r["ok"])
    total = len(reqs)
    return {
        "path": path,
        "score": passed,
        "max": total,
        "percent": round(100.0 * passed / total, 1) if total else 0.0,
        "requirements": reqs,
    }
