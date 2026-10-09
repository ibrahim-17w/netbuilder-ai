"""A cabled switch and AP both end up in the file, joined by a cable.

The reported bug: a plan that placed SW1 and an AP produced a .pkt with the
AP floating in the workspace, cabled to nothing. The network inspector said
``link SW1-AP1: port1 not usable on AP1``.

Two things were wrong:

* ``AccessPoint-PT-A``'s Ethernet port carries no ``<NAME>`` in any Packet
  Tracer save - the port is named from the host module and never written out -
  so the manifest recorded it empty and no interface on the AP could be
  resolved. 34 models were in that state (every AccessPoint, the IpPhone, the
  Hub, the IoT/MCU family). ``pkt_template_build.port_inventory`` now names
  every cableable port from its family, which is ``FastEthernet0`` for a
  FastEthernet.
* the builder wrote the LINK's ``<PORT>`` name but never created the
  ``<NAME>`` the AP's own device block was missing, so even a resolved name
  pointed at a port the device did not declare.
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pkt_builder as pb  # noqa: E402
import pkt_codec  # noqa: E402
import pt_autopilot as pt  # noqa: E402
import pkt_template_build as tb  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def _library():
    return pb.load_library(os.path.join(HERE, "pkt_templates"))


def _build(tmp_path, name, plan):
    pt_dir = tmp_path / "out"
    pt_dir.mkdir(parents=True, exist_ok=True)
    os.environ["NETBUILDER_PKT_DIR"] = str(pt_dir)
    try:
        result = pt.pkt_generate(
            {"projectName": name, "steps": plan})
    finally:
        os.environ.pop("NETBUILDER_PKT_DIR", None)
    assert result.get("path"), result
    return result, result["path"]


PLAN = [
    {"action": "create_nodes",
     "nodes": [
         {"name": "SW1", "type": "switch", "model": "2960"},
         {"name": "AP1", "type": "wireless",
          "model": "AccessPoint-PT-A"},
     ]},
    {"action": "create_links",
     "links": [{"a": "SW1", "aIf": "f0/1", "b": "AP1", "bIf": "FastEthernet0"}]},
]


def test_the_access_point_model_has_a_cableable_port():
    library = _library()
    model = next(
        (d for d in library["devices"]
         if d["model"] == "AccessPoint-PT-A"), None)
    assert model is not None, "the library has no AccessPoint-PT-A"
    named = pb._named_variant(model)
    wired = [p for p in named["ports"]
             if p.get("family") and p["family"] != "wireless"]
    assert wired, "the AP has no cableable port at all"
    for port in wired:
        assert port.get("name"), (
            "an unnamed cableable port can never be cabled: the AP would be "
            "placed floating in the workspace")


def test_no_model_needs_a_cable_that_cannot_be_laid():
    """Selection still judges the raw library; the build names every port.

    The raw manifest is what Packet Tracer wrote, and some of its ports have
    no name at all. What matters is that once a model is CHOSEN, every port a
    cable could need has a name.
    """
    library = _library()
    unnamed = []
    for device in library["devices"]:
        for port in pb._named_variant(device)["ports"]:
            if port.get("family") and not port.get("name"):
                unnamed.append(f"{device['model']}[{port['index']}]")
    assert not unnamed, f"ports no cable can reach: {unnamed}"


def test_a_plan_that_cables_a_switch_to_an_ap_keeps_the_link(tmp_path):
    result, path = _build(tmp_path, "ap-cabled", PLAN)

    links = result.get("links") or []
    ap_links = [l for l in links if l.get("a") == "AP1" or l.get("b") == "AP1"]
    assert ap_links, (
        "the SW1-AP1 cable is missing, so the AP is placed floating")

    warnings = [w for w in result.get("warnings", []) if "AP1" in w]
    assert not warnings, f"the AP link was not cabled cleanly: {warnings}"


def test_the_generated_file_declares_the_port_its_cable_uses(tmp_path):
    result, path = _build(tmp_path, "ap-named", PLAN)
    with open(path, "rb") as stream:
        xml = pkt_codec.decrypt_pkt(stream.read()).decode("utf-8", "replace")

    ap_block = next(
        (b for b in xml.split("</DEVICE>")
         if "AccessPoint" in b and "<DEVICE>" in b),
        None)
    assert ap_block is not None, "the AP is not in the generated file"

    # The AP end of the cable must be a port the AP's own block declares.
    link = next(
        (l for l in xml.split("</LINK>") if "AP1" in l and "SW1" in l),
        None)
    assert link is not None, "no cable between SW1 and AP1 in the file"
    ports = pb.re.findall(r"<PORT>([^<]*)</PORT>", link)
    assert ports, "the LINK block names no ports"
    declared = pb.re.findall(r"<NAME[^>]*>([^<]*)</NAME>", ap_block)
    ap_port = next((p for p in ports if p in declared), None)
    assert ap_port is not None, (
        f"the cable references {ports}, but the AP block only declares "
        f"{declared} - so the AP end of the cable resolves to nothing")


def test_the_ap_is_placed_on_the_canvas_not_floating(tmp_path):
    result, path = _build(tmp_path, "ap-placed", PLAN)
    with open(path, "rb") as stream:
        xml = pkt_codec.decrypt_pkt(stream.read()).decode("utf-8", "replace")
    # A device with no physical-workspace data is the one Packet Tracer
    # cannot show on the workspace at all.
    ap_block = next(
        (b for b in xml.split("</DEVICE>")
         if "AccessPoint" in b and "<DEVICE>" in b),
        None)
    assert ap_block is not None
    for tag in ("PHYSICAL_CPUR", "CONTAINER_ID"):
        assert tag in ap_block, (
            f"the AP has no <{tag}> data, which is what 'floating' looks like "
            "in the saved file")
