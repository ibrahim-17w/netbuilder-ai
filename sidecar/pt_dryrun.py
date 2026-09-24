"""Dry-run: walk a plan against PT constraints WITHOUT touching the UI.

Answers "what will this build do?" before the user commits to a live run:
which devices get placed, cabled, typed into, IP-configured, and which plan
steps carry risks the live executor has tripped over before (template gaps,
missing gateways, unaddressed transit ends).  Pure logic - no UIA, no OCR -
so it runs in CI and never steals focus.
"""

from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))

# Same families the builder treats as configurable Ethernet endpoints.
_ETHERNET_FAMILIES = ("fastethernet", "gigabitethernet", "ethernet")

# Device types the executor configures through Desktop > IP Configuration
# (must match PacketTracerAdapter.autopilotPlan's config_pcs filter).
_IPCONFIG_TYPES = {"pc", "laptop", "server", "printer"}


def _norm_iface(spec: str) -> str:
    t = re.sub(r"\s+", "", str(spec or "")).lower()
    for full in ("gigabitethernet", "fastethernet", "serial", "ethernet"):
        if t.startswith(full):
            return full[0] + t[len(full):]
    return t


def dry_run_plan(plan: dict) -> dict:
    """Return a structured walk-through of what a live run would do."""
    steps = [s for s in (plan or {}).get("steps") or [] if isinstance(s, dict)]
    nodes, links, configs, pcs, servers = [], [], {}, {}, {}
    for step in steps:
        action = step.get("action")
        if action == "create_nodes":
            nodes.extend(step.get("nodes") or [])
        elif action == "create_links":
            links.extend(step.get("links") or [])
        elif action == "paste_cli":
            configs.update(step.get("configs") or {})
        elif action == "config_pcs":
            pcs.update(step.get("pcs") or {})
        elif action == "config_servers":
            servers.update(step.get("servers") or {})

    names = [str(n.get("name") or "") for n in nodes]
    types = {str(n.get("name") or ""): str(n.get("type") or "") for n in nodes}
    warnings: list = []
    actions: list = []

    def act(device: str, action: str, detail: str = "") -> dict:
        row = {"device": device, "action": action}
        if detail:
            row["detail"] = detail
        return row

    # ---- placement -----------------------------------------------------
    actions.extend(act(n, "place") for n in names)
    if len(set(names)) != len(names):
        dupes = sorted({n for n in names if names.count(n) > 1})
        warnings.append(f"duplicate device names: {', '.join(dupes)}")

    # ---- cabling -------------------------------------------------------
    for l in links:
        a, b = str(l.get("a") or ""), str(l.get("b") or "")
        if a not in types or b not in types:
            warnings.append(f"link references unknown device: {a}-{b}")
            continue
        actions.append(act(a, "cable", f"{a}:{l.get('aIf')} <-> {b}:{l.get('bIf')}"))

    # ---- CLI -----------------------------------------------------------
    for dev, cfg in configs.items():
        if dev not in types:
            warnings.append(f"cli for unknown device {dev}")
            continue
        kind = types[dev]
        if kind not in ("router", "switch"):
            warnings.append(
                f"cli targets {dev} ({kind}) which has no IOS prompt; the "
                "config still lands in the saved device but nothing is typed")
        lines = [l for l in str(cfg).splitlines() if l.strip()]
        actions.append(act(dev, "cli", f"{len(lines)} line(s)"))

    # ---- endpoint addressing ------------------------------------------
    unaddressed = []
    for dev, settings in pcs.items():
        if not isinstance(settings, dict):
            continue
        missing = [k for k in ("ip", "mask", "gw") if not settings.get(k)]
        if missing:
            warnings.append(f"{dev}: ip config missing {', '.join(missing)}")
        actions.append(act(dev, "ip_config",
                           f"ip={settings.get('ip', '')} gw={settings.get('gw', '')}"))

    # ---- servers -------------------------------------------------------
    for dev, entry in servers.items():
        if not isinstance(entry, dict):
            continue
        services = entry.get("services") if isinstance(entry.get("services"),
                                                       dict) else entry
        if isinstance(services, dict):
            actions.append(act(dev, "services",
                               ", ".join(sorted(k for k in services
                                                if k != "wireless")) or "none"))

    # ---- transit sanity ------------------------------------------------
    addressing = {(a.get("node"), _norm_iface(a.get("iface", "")))
                  for a in (plan.get("addressing") or [])}
    router_router = [l for l in links
                     if types.get(str(l.get("a") or "")) == "router"
                     and types.get(str(l.get("b") or "")) == "router"]
    for l in router_router:
        for end, ifspec in ((l.get("a"), l.get("aIf")),
                            (l.get("b"), l.get("bIf"))):
            if (str(end or ""), _norm_iface(str(ifspec or ""))) not in addressing:
                warnings.append(
                    f"router-router link {l.get('a')}-{l.get('b')}: {end}"
                    f":{ifspec} has no address in the plan (dead transit)")

    # Unconfigured endpoints on a LAN with a gateway - they will be typing
    # nothing but still count as expected outcomes in verification.
    configured = set(pcs) | {s for s in servers}
    for n in nodes:
        dev = str(n.get("name") or "")
        if types.get(dev) in _IPCONFIG_TYPES and dev not in configured:
            warnings.append(f"{dev}: endpoint left unconfigured (no ip config)")

    return {
        "ok": True,
        "dryRun": True,
        "project": str(plan.get("project") or "default"),
        "actions": actions,
        "warnings": warnings,
        "summary": {
            "devices": len(names),
            "links": len(links),
            "cliDevices": len(configs),
            "ipConfigured": len(pcs),
            "servers": len(servers),
            "warnings": len(warnings),
        },
    }
