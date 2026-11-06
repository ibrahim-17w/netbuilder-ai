"""Shared helpers for the offline .pkt generation tests.

These tests compile a deterministic plan against the repository's own
template library (the same 118 models the app ships) and check what the
compiler actually wrote. They do not open Packet Tracer.
"""

from __future__ import annotations

import os

import pkt_builder

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(HERE, "pkt_templates")

ROUTER = "2911"
SERIAL_ROUTER = "2811"
SWITCH = "2960-24TT"
PC = "PC-PT"
LAPTOP = "Laptop-PT"
SERVER = "Server-PT"
PRINTER = "Printer-PT"


def load_templates() -> dict:
    return pkt_builder.load_library(TEMPLATE_DIR)


def node(name: str, kind: str, model: str | None = None,
         modules: list[str] | None = None) -> dict:
    entry: dict = {"name": name, "type": kind}
    if model:
        entry["model"] = model
    if modules:
        entry["modules"] = list(modules)
        entry["exactModel"] = True
    return entry


def link(a: str, a_if: str, b: str, b_if: str, cable: str = "copper",
         exact: bool = False) -> dict:
    entry = {"a": a, "aIf": a_if, "b": b, "bIf": b_if, "cable": cable}
    if exact:
        entry["exactPorts"] = True
    return entry


def plan(nodes: list[dict], links: list[dict],
         configs: dict[str, str] | None = None,
         pcs: dict[str, dict] | None = None,
         servers: dict[str, dict] | None = None,
         project: str = "scenario") -> dict:
    steps: list[dict] = [
        {"action": "create_nodes", "nodes": nodes},
        {"action": "create_links", "links": links},
    ]
    if configs:
        steps.append({"action": "paste_cli", "configs": dict(configs)})
    if pcs:
        steps.append({"action": "config_pcs", "pcs": dict(pcs)})
    if servers:
        steps.append({"action": "config_servers", "servers": dict(servers)})
    return {"project": project, "steps": steps}


def build(payload: dict, template_dir: str | None = None) -> dict:
    return pkt_builder.build_pkt(payload, template_dir or load_templates())


def device_names(built: dict) -> set[str]:
    return {str(entry.get("name") or "") for entry in built.get("devices", [])}


def link_pairs(built: dict) -> set[frozenset[str]]:
    return {
        frozenset((str(item.get("a") or ""), str(item.get("b") or "")))
        for item in built.get("links", [])
    }


def assertions_for(built: dict, nodes: list[dict], links: list[dict]) -> None:
    """Every planned device and link is present, with no silent extra/missing."""
    assert built["status"] in ("VALID", "VALID_WITH_WARNINGS"), built["status"]
    assert built["missingDevices"] == []
    assert built["missingLinks"] == []
    assert built["plannedDevices"] == len(nodes)
    assert built["plannedLinks"] == len(links)
    assert built["deviceCount"] == len(nodes)
    assert built["linkCount"] == len(links)
    assert device_names(built) == {item["name"] for item in nodes}
    assert link_pairs(built) == {
        frozenset((item["a"], item["b"])) for item in links
    }
    reported_cables = {
        frozenset((item["a"], item["b"])): item["cable"]
        for item in built["links"]
    }
    for item in links:
        pair = frozenset((item["a"], item["b"]))
        assert reported_cables[pair] == item.get("cable", "copper")
