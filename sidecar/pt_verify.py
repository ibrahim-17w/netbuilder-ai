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

_MAX_TESTS = 25
_MAX_PEERS_PER_SRC = 4


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

    for t in (plan.get("tests") or [])[:10]:
        if isinstance(t, str) and t.strip():
            tests.append({"src": "", "dst": "", "kind": "custom", "detail": t.strip()})

    return tests[:_MAX_TESTS]


def _testable_services(node: dict) -> List[str]:
    out = []
    for s in node.get("services") or []:
        s = str(s).lower()
        if s in _TESTABLE_SERVICES and s not in out:
            out.append(s)
    return out


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
        if t.get("kind") == "custom":
            out.append({**t, "status": "skipped",
                        "detail": f"manual: {t.get('detail', '')}"})
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
    skipped = sum(1 for r in results if r.get("status") == "skipped")
    return {
        "passed": passed, "failed": failed, "skipped": skipped,
        "total": len(results),
        "summary": f"{passed} passed, {failed} failed, {skipped} skipped",
        "ok": failed == 0 and passed > 0,
    }
