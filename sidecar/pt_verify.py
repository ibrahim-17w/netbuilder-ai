"""Packet Tracer verification: derive a test list from a build plan and
produce pass/fail evidence from the live Packet Tracer window.

The derivation half of this module is pure and unit-tested.  The live half
lives in pt_autopilot.py (``verify_plan_live``), which reuses the proven
``_pc_ping`` machinery; this module stays importable without UIA so CI can
test derivation and result shaping on any OS.

Plan schema (what the Dart adapters emit):
    nodes:       [{name, type, services: [..]}]
    links:       [{a, aIf, b, bIf}]
    addressing:  [{node, iface, ipCidr}]          # ipCidr like 192.168.1.10/24
    steps:       [{action: 'config_pcs', pcs: {name: {ip, mask, gw}}}, ...]
"""

from __future__ import annotations

import ipaddress
from typing import Any, Dict, List, Optional

# Services that imply a client->server reachability test.  DHCP is excluded:
# it is transactional (IPC config), not pingable, and is already covered by
# the gateway test plus the config_pcs verification.
_TESTABLE_SERVICES = ("dns", "http", "ftp", "email", "aaa", "ntp", "tftp", "syslog")

_ENDPOINT_TYPES = ("pc", "laptop")
_GATEWAY_TYPES = ("router", "firewall", "multilayer-switch", "layer3switch")

_MAX_TESTS = 60
_MAX_PEERS_PER_SRC = 4
_MAX_DNS_PROBES = 12


# --------------------------------------------------------------------------
# Test derivation (pure)
# --------------------------------------------------------------------------

def derive_tests(plan: dict) -> List[dict]:
    """Build the verification test list from a plan.

    - every end device pings its gateway (nearest router/firewall by the
      link graph, addressing taken from that link's subnet)
    - every end device pings each server offering a testable service
      (dedup by src+dst)
    - plan["tests"] strings (free-form asks from the brief) are appended as
      kind="custom" rows for the UI to show as manual steps
    - capped, gateway tests first
    """
    nodes: List[dict] = [n for n in (plan.get("nodes") or []) if isinstance(n, dict)]
    links: List[dict] = [l for l in (plan.get("links") or []) if isinstance(l, dict)]
    by_name = {str(n.get("name") or ""): n for n in nodes if n.get("name")}

    adj: Dict[str, set] = {}
    for l in links:
        a, b = str(l.get("a") or ""), str(l.get("b") or "")
        if a and b:
            adj.setdefault(a, set()).add(b)
            adj.setdefault(b, set()).add(a)

    def nearest_gateway(dev: str) -> Optional[str]:
        seen, frontier = {dev}, [dev]
        while frontier:
            nxt: List[str] = []
            for cur in frontier:
                for peer in sorted(adj.get(cur, ())):
                    if peer in seen:
                        continue
                    seen.add(peer)
                    kind = str((by_name.get(peer) or {}).get("type") or "").lower()
                    if kind in _GATEWAY_TYPES:
                        return peer
                    nxt.append(peer)
            frontier = nxt
        return None

    tests: List[dict] = []
    seen: set = set()

    def add(src: str, dst: str, kind: str, detail: str) -> None:
        key = (src, dst)
        if not src or not dst or src == dst or key in seen:
            return
        seen.add(key)
        tests.append({"src": src, "dst": dst, "kind": kind, "detail": detail})

    def connected(src: str, dst: str) -> bool:
        frontier, visited = [src], {src}
        while frontier:
            current = frontier.pop(0)
            if current == dst:
                return True
            for peer in adj.get(current, ()):
                if peer not in visited:
                    visited.add(peer)
                    frontier.append(peer)
        return False

    for node in nodes:
        name = str(node.get("name") or "")
        if str(node.get("type") or "").lower() not in _ENDPOINT_TYPES:
            continue
        gw = nearest_gateway(name)
        if gw:
            add(name, gw, "gateway", "end device reaches its gateway")
        for peer in nodes:
            pname = str(peer.get("name") or "")
            if pname == name or str(peer.get("type") or "").lower() != "server":
                continue
            if _testable_services(peer):
                add(name, pname, "service",
                    f"reaches {', '.join(_testable_services(peer))} services")

    # Ping proves only reachability. This separate probe asks a client to
    # resolve a configured record through its current DNS settings.
    dns_probe_count = 0
    for endpoint in nodes:
        src = str(endpoint.get("name") or "")
        if str(endpoint.get("type") or "").lower() not in _ENDPOINT_TYPES:
            continue
        for server in nodes:
            if dns_probe_count >= _MAX_DNS_PROBES:
                break
            if str(server.get("type") or "").lower() != "server":
                continue
            server_name = str(server.get("name") or "")
            if "dns" not in [str(role).lower() for role in (server.get("services") or [])]:
                continue
            if not connected(src, server_name):
                continue
            rules = server.get("serviceRules") if isinstance(server.get("serviceRules"), dict) else {}
            dns = rules.get("dns") if isinstance(rules.get("dns"), dict) else {}
            records = dns.get("records") if isinstance(dns.get("records"), list) else []
            record = next((r for r in records if isinstance(r, dict)
                           and str(r.get("name") or "").strip()
                           and _ipv4(str(r.get("address") or ""))), None)
            if record is None:
                continue
            query = str(record["name"]).strip()
            expected = str(record["address"]).strip().split("/")[0]
            tests.append({
                "src": src, "dst": server_name, "kind": "dns",
                "query": query, "expectedIp": expected,
                "detail": f"Resolve {query} from this client; expected {expected}.",
            })
            dns_probe_count += 1
        if dns_probe_count >= _MAX_DNS_PROBES:
            break

    # A successful ping proves only reachability. Add explicit, honest
    # service checks to the report so users do not mistake ICMP for proof
    # that DHCP, DNS, HTTP, or authentication works. These are manual until
    # Packet Tracer exposes a stable way to exercise the service from a PC.
    service_steps = {
        "dhcp": "Renew a client lease; confirm its address, gateway, and DNS match its VLAN.",
        "dns": "Resolve a configured DNS name from a client and confirm the expected address.",
        "http": "Open the web service from an allowed client; check that restricted clients are denied.",
        "aaa": "Sign in with a valid test account, then confirm an invalid account is rejected.",
        "ftp": "Log in with a test account, transfer a small file, and confirm an invalid login fails.",
        "email": "Send a test message between configured users and confirm delivery.",
        "ntp": "Confirm a client or network device synchronizes to the configured time server.",
        "tftp": "Transfer a small test file from a client and verify the saved file.",
        "syslog": "Trigger a harmless test event and confirm it appears on the syslog server.",
    }
    for server in nodes:
        if str(server.get("type") or "").lower() != "server":
            continue
        roles = [str(s).lower() for s in (server.get("services") or [])]
        for role in roles:
            detail = service_steps.get(role)
            if role == "dns" and dns_probe_count:
                continue
            if role == "dns":
                detail = "Resolve a configured host name from a client; no usable DNS record was available for an automatic check."
            if detail:
                tests.append({"src": "", "dst": str(server.get("name") or ""),
                              "kind": "manual", "detail": f"{role.upper()}: {detail}"})

    security = plan.get("security") if isinstance(plan.get("security"), dict) else {}
    if security.get("extendedAcl"):
        tests.append({"src": "", "dst": "", "kind": "manual",
                      "detail": "ACL positive and negative: confirm an allowed user reaches the approved service, then confirm a restricted user is denied."})
    if security.get("portSecurity"):
        tests.append({"src": "", "dst": "", "kind": "manual",
                      "detail": "Port security: connect an unapproved test device and confirm the switch blocks or disables that port."})
    if security.get("dhcpSnooping"):
        tests.append({"src": "", "dst": "", "kind": "manual",
                      "detail": "DHCP snooping: confirm clients receive a lease through the trusted uplink and rogue DHCP offers are blocked."})
    security_steps = {
        "acl": "ACL positive and negative: confirm an allowed client reaches its approved service and a restricted client is denied.",
        "port_security": "Port security: connect an unapproved test device and confirm the access port blocks it.",
        "dhcp_snooping": "DHCP snooping: confirm a legitimate lease succeeds and a rogue DHCP offer is blocked.",
        "aaa": "AAA: sign in with a valid test account, then confirm an invalid account is rejected.",
        "ike": "VPN: generate traffic between the two protected networks and confirm the tunnel comes up.",
        "ipsec": "VPN: generate protected traffic and confirm the encryption counters increase.",
    }
    for step in plan.get("steps") or []:
        if not isinstance(step, dict) or step.get("action") != "verify_security":
            continue
        for check in step.get("checks") or []:
            if not isinstance(check, dict):
                continue
            detail = security_steps.get(str(check.get("kind") or "").lower())
            if detail:
                tests.append({"src": "", "dst": str(check.get("device") or ""),
                              "kind": "manual", "detail": detail})
    for step in (security.get("tests") or [])[:10]:
        if isinstance(step, str) and step.strip():
            tests.append({"src": "", "dst": "", "kind": "manual",
                          "detail": f"Security policy: {step.strip()}"})

    for t in (plan.get("tests") or [])[:10]:
        if isinstance(t, str) and t.strip():
            tests.append({"src": "", "dst": "", "kind": "custom", "detail": t.strip()})

    # Keep the interactive checklist visible even for large topologies; a
    # long list of pings must not push every service/security check off the end.
    manual_all = [t for t in tests if t.get("kind") in ("manual", "custom")]
    automatic = [t for t in tests if t.get("kind") not in ("manual", "custom")]
    manual = manual_all[:20]
    automatic_limit = _MAX_TESTS - len(manual)
    omitted_automatic = max(0, len(automatic) - automatic_limit)
    omitted_manual = max(0, len(manual_all) - len(manual))
    if omitted_automatic or omitted_manual:
        # Reserve one visible row for coverage limits, so a capped report never
        # looks like every planned check ran. Recalculate omissions after
        # reserving that row, since it reduces both visible capacities.
        manual = manual_all[:19]
        omitted_manual = len(manual_all) - len(manual)
        automatic_limit = _MAX_TESTS - len(manual) - 1
        omitted_automatic = max(0, len(automatic) - automatic_limit)
        details = []
        if omitted_automatic:
            details.append(f"{omitted_automatic} automatic checks were not run")
        if omitted_manual:
            details.append(f"{omitted_manual} manual checks are not shown")
        manual.append({
            "src": "", "dst": "", "kind": "manual",
            "detail": "Coverage limit: " + "; ".join(details) +
                      ". Review a smaller topology or its service checklist.",
        })
    return automatic[:automatic_limit] + manual


def _testable_services(node: dict) -> List[str]:
    out = []
    for s in node.get("services") or []:
        s = str(s).lower()
        if s in _TESTABLE_SERVICES and s not in out:
            out.append(s)
    return out


def _ipv4(value: str) -> bool:
    try:
        return ipaddress.ip_address(value.split("/")[0].strip()).version == 4
    except ValueError:
        return False


# --------------------------------------------------------------------------
# Address resolution (pure)
# --------------------------------------------------------------------------

def ip_index(plan: dict) -> Dict[str, str]:
    """node name -> IPv4 address (first addressing entry that is a real IP)."""
    out: Dict[str, str] = {}
    for a in plan.get("addressing") or []:
        if not isinstance(a, dict):
            continue
        node = str(a.get("node") or "")
        cidr = str(a.get("ipCidr") or "")
        ip = cidr.split("/")[0].strip()
        if not node or node in out:
            continue
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if addr.version == 4 and ip != "0.0.0.0":
            out[node] = ip
    return out


def gateway_ip_for(plan: dict, src: str, gw_node: str) -> Optional[str]:
    """The gateway node's address on the SOURCE's subnet (routers have many)."""
    ips = ip_index(plan)
    src_ip = ips.get(src)
    gw_ip = ips.get(gw_node)
    if not gw_ip:
        return None
    if not src_ip:
        return gw_ip
    # same-subnet match first: the router address the device can actually reach
    try:
        src_net = ipaddress.ip_network(
            f"{src_ip}/{_prefix_of(plan, src)}", strict=False)
    except ValueError:
        return gw_ip
    for prefix in _prefixes_of(plan, gw_node):
        try:
            gnet = ipaddress.ip_network(f"{gw_ip}/{prefix}", strict=False)
        except ValueError:
            continue
        if src_net.network_address in gnet:
            return gw_ip
    return gw_ip


def _prefix_of(plan: dict, node: str) -> str:
    for a in plan.get("addressing") or []:
        if isinstance(a, dict) and str(a.get("node")) == node:
            parts = str(a.get("ipCidr") or "").split("/")
            if len(parts) == 2:
                return parts[1]
    return "24"


def _prefixes_of(plan: dict, node: str) -> List[str]:
    out = []
    for a in plan.get("addressing") or []:
        if isinstance(a, dict) and str(a.get("node")) == node:
            parts = str(a.get("ipCidr") or "").split("/")
            if len(parts) == 2 and parts[1] not in out:
                out.append(parts[1])
    return out or ["24"]


# --------------------------------------------------------------------------
# Result shaping (pure) - the live runner hands us rows, we normalize
# --------------------------------------------------------------------------

def shape_results(rows: List[dict], tests: List[dict],
                  ips: Optional[Dict[str, str]] = None,
                  plan: Optional[dict] = None) -> List[dict]:
    """Normalize live ping rows into the report's test list.

    rows:  [{source, target, ok, attempts, evidence}] from _pc_ping
    tests: derived test rows (src/dst names); each may carry ``_dstIp``
    ips:   optional node->IP map (resolved from ``plan`` when omitted)
    plan:  optional plan for resolving ips when ``ips`` is not supplied
    """
    by_pair: Dict[tuple, dict] = {}
    for r in rows or []:
        key = (str(r.get("source") or ""), str(r.get("target") or ""))
        if key not in by_pair or (r.get("ok") and not by_pair[key].get("ok")):
            by_pair[key] = r

    if ips is None and isinstance(plan, dict):
        ips = ip_index(plan)
    ip_map = ips or {}
    out: List[dict] = []
    for t in tests:
        if t.get("kind") in ("manual", "custom"):
            out.append({**t,
                        "status": "manual" if t.get("kind") == "manual" else "skipped",
                        "detail": f"Manual check: {t.get('detail', '')}"})
            continue
        if t.get("kind") == "dns":
            src, query = str(t.get("src") or ""), str(t.get("query") or "")
            row = by_pair.get((src, query))
            if row is None or row.get("available") is False:
                out.append({
                    **t,
                    "status": "skipped",
                    "detail": str((row or {}).get("evidence") or
                                  f"DNS lookup for {query} was not run (client unavailable)."),
                })
            else:
                out.append({
                    **t,
                    "status": "passed" if row.get("ok") else "failed",
                    "detail": str(row.get("evidence") or
                                  (f"{query} resolved to {t.get('expectedIp')}" if row.get("ok")
                                   else f"{query} did not resolve to {t.get('expectedIp')}")),
                    "evidence": str(row.get("evidence") or "")[-260:],
                })
            continue
        src, dst = str(t.get("src") or ""), str(t.get("dst") or "")
        dst_ip = str(t.get("_dstIp") or ip_map.get(dst) or dst)
        row = by_pair.get((src, dst_ip)) or by_pair.get((src, dst))
        if row is not None:
            out.append({
                **t,
                "status": "passed" if row.get("ok") else "failed",
                "detail": (f"ping {row.get('target')}: "
                           + ("replies" if row.get("ok") else "no reply")
                           + f" ({int(row.get('attempts') or 1)} attempt(s))"),
                "evidence": str(row.get("evidence") or "")[-200:],
            })
        else:
            out.append({**t, "status": "skipped",
                        "detail": f"{src} -> {dst}: not run (device unavailable)"})
    return out


def summarize(results: List[dict]) -> dict:
    passed = sum(1 for r in results if r.get("status") == "passed")
    failed = sum(1 for r in results if r.get("status") == "failed")
    skipped = sum(1 for r in results
                  if r.get("status") == "skipped" and r.get("kind") != "custom")
    manual = sum(1 for r in results if r.get("status") == "manual" or
                 (r.get("status") == "skipped" and r.get("kind") == "custom"))
    return {
        "passed": passed, "failed": failed, "skipped": skipped, "manual": manual,
        "total": len(results),
        "summary": f"{passed} passed, {failed} failed, {skipped} skipped, {manual} manual",
        "ok": failed == 0 and passed > 0,
    }
