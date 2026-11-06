"""Export-integrity regression tests for the offline .pkt compiler.

These pin the failures from the field report:

* a device with no template was skipped while the build still claimed
  success;
* the skipped device also silently dropped its cable;
* the report could not distinguish planned from exported counts.

They compile against the repository's real template library, so a model that
exists there is expected to build and one that does not is expected to fail
loudly, never be replaced by an unrelated device. The user-supplied
`test.pkt` supplied the real Printer-PT block, so the printer is now a
positive case and a deliberately unknown model covers the negative one.
"""

from __future__ import annotations

import os
import re

import pytest

import builder_test_support as support
import pkt_builder
import pkt_codec

LIBRARY = support.load_templates()


def _plan_with_printer() -> tuple[dict, list[dict], list[dict]]:
    nodes = [
        support.node("R1", "router", support.ROUTER),
        support.node("SW1", "switch", support.SWITCH),
        support.node("PRN1", "printer", support.PRINTER),
    ]
    links = [
        support.link("R1", "g0/0", "SW1", "g0/1"),
        support.link("SW1", "f0/1", "PRN1", "f0"),
    ]
    return support.plan(nodes, links, project="printer-lab"), nodes, links


def _plan_with_unknown_device() -> tuple[dict, list[dict], list[dict]]:
    nodes = [
        support.node("SW1", "switch", support.SWITCH),
        support.node("HOLO1", "hologram", "Holo-PT"),
    ]
    links = [support.link("SW1", "f0/1", "HOLO1", "f0")]
    return support.plan(nodes, links, project="unknown-device"), nodes, links


def test_printer_with_real_template_builds_and_verifies(tmp_path):
    payload, _, _ = _plan_with_printer()
    target = tmp_path / "printer-lab.pkt"
    report = pkt_builder.generate_pkt_file(
        payload, str(target), library=LIBRARY, project="printer-lab")

    assert report["status"] in ("VALID", "VALID_WITH_WARNINGS")
    assert report["complete"] is True
    assert report["plannedDevices"] == 3
    assert report["deviceCount"] == 3
    assert report["plannedLinks"] == 2
    assert report["linkCount"] == 2
    assert report["missingDevices"] == []
    assert report["missingLinks"] == []
    assert report["verification"]["ok"] is True
    assert report["verification"]["missingNamesOnDisk"] == []
    assert b"Printer-PT" in pkt_codec.decrypt_pkt(target.read_bytes())


def test_unknown_device_is_explicit_not_silent():
    payload, _, _ = _plan_with_unknown_device()
    built = pkt_builder.build_pkt(payload, LIBRARY)

    assert built["status"] == "EXPORT_INCOMPLETE"
    assert built["complete"] is False
    assert built["plannedDevices"] == 2
    assert built["deviceCount"] == 1
    assert [entry["name"] for entry in built["missingDevices"]] == ["HOLO1"]
    assert "HOLO1" in built["missingDevices"][0]["reason"]
    # The skipped device's cable must be reported as a missing link, not
    # dropped from a smaller build that still calls itself successful.
    assert [entry["b"] for entry in built["missingLinks"]] == ["HOLO1"]
    assert built["linkCount"] == 0
    assert built["plannedLinks"] == 1


def test_generate_refuses_to_write_an_incomplete_export(tmp_path):
    payload, _, _ = _plan_with_unknown_device()
    target = tmp_path / "unknown-device.pkt"

    with pytest.raises(pkt_builder.BuildError) as error:
        pkt_builder.generate_pkt_file(
            payload, str(target), library=LIBRARY, project="printer-lab")

    message = str(error.value)
    assert "export incomplete" in message
    assert "HOLO1" in message
    assert "No file was written" in message
    assert not target.exists()
    assert not (tmp_path / "unknown-device.pkt.tmp").exists()


def test_incomplete_export_can_be_requested_explicitly(tmp_path):
    payload, _, _ = _plan_with_unknown_device()
    target = tmp_path / "partial.pkt"

    report = pkt_builder.generate_pkt_file(
        payload, str(target), library=LIBRARY, project="unknown-device",
        allow_incomplete=True)

    assert target.exists()
    assert report["status"] == "EXPORT_INCOMPLETE"
    assert report["complete"] is False
    assert report["deviceCount"] == 1
    assert [entry["name"] for entry in report["missingDevices"]] == ["HOLO1"]
    assert report["verification"]["ok"] is True
    assert report["verification"]["deviceCountOnDisk"] == 1
    assert report["verification"]["linkCountOnDisk"] == 0


def test_unknown_cable_is_a_precise_error():
    nodes = [
        support.node("SW1", "switch", support.SWITCH),
        support.node("PC1", "pc", support.PC),
    ]
    links = [support.link("SW1", "f0/1", "PC1", "f0", cable="not-a-cable")]
    with pytest.raises(pkt_builder.BuildError) as error:
        pkt_builder.build_pkt(
            support.plan(nodes, links), LIBRARY)
    assert "Unknown cable" in str(error.value)
    assert "No replacement was made" in str(error.value)


def test_two_cables_on_one_port_are_reported():
    nodes = [
        support.node("R1", "router", support.ROUTER),
        support.node("SW1", "switch", support.SWITCH),
        support.node("SW2", "switch", support.SWITCH),
    ]
    links = [
        support.link("R1", "g0/0", "SW1", "g0/1"),
        support.link("R1", "g0/0", "SW2", "g0/1"),
    ]
    built = pkt_builder.build_pkt(support.plan(nodes, links), LIBRARY)

    assert built["status"] == "VALID_WITH_WARNINGS"
    assert any("cabled 2 times" in warning for warning in built["warnings"])
    # No silent repair: both links were written, and the clash is surfaced.
    assert built["linkCount"] == 2


def test_model_substitution_is_structured():
    nodes = [
        support.node("R1", "router", "7200"),
        support.node("SW1", "switch", support.SWITCH),
    ]
    links = [support.link("R1", "g0/0", "SW1", "g0/1")]
    built = pkt_builder.build_pkt(support.plan(nodes, links), LIBRARY)

    assert built["missingDevices"] == []
    assert built["modelSubstitutions"], "a swapped model must be reported"
    substitution = built["modelSubstitutions"][0]
    assert substitution["device"] == "R1"
    assert substitution["requested"] == "7200"
    assert substitution["used"]
    assert "instead of" in substitution["reason"]


def test_interface_remap_is_structured_and_applied():
    nodes = [
        support.node("R1", "router", support.ROUTER),
        support.node("SW1", "switch", support.SWITCH),
    ]
    links = [support.link("R1", "g1/0", "SW1", "g0/1")]
    built = pkt_builder.build_pkt(support.plan(nodes, links), LIBRARY)

    remap = next(
        entry for entry in built["interfaceRemappings"]
        if entry["device"] == "R1" and entry["requested"] == "g1/0")
    assert remap["assigned"].startswith("GigabitEthernet")
    assert remap["assigned"] != "g1/0"
    assert built["links"][0]["aIf"] == remap["assigned"]


def test_empty_plan_is_refused():
    with pytest.raises(pkt_builder.BuildError) as error:
        pkt_builder.build_pkt(
            support.plan([], []), LIBRARY)
    assert "no device could be built" in str(error.value).lower()


def _mixed_fifty(include_printers: bool) -> tuple[list[dict], list[dict]]:
    nodes = [support.node(f"R{i}", "router", support.ROUTER)
             for i in range(1, 4)]
    nodes += [support.node(f"SW{i}", "switch", support.SWITCH)
              for i in range(1, 7)]
    pc_count = 25 if include_printers else 29
    nodes += [support.node(f"PC{i}", "pc", support.PC)
              for i in range(1, pc_count + 1)]
    nodes += [support.node(f"L{i}", "laptop", support.LAPTOP)
              for i in range(1, 9)]
    nodes += [support.node(f"SRV{i}", "server", support.SERVER)
              for i in range(1, 5)]
    if include_printers:
        nodes += [support.node(f"PRN{i}", "printer", support.PRINTER)
                  for i in range(1, 5)]

    links: list[dict] = []
    for index in range(6):
        links.append(support.link(
            f"R{index // 2 + 1}", f"g0/{index % 2}",
            f"SW{index + 1}", "g0/1"))

    hosts = [f"PC{i}" for i in range(1, pc_count + 1)]
    hosts += [f"L{i}" for i in range(1, 9)]
    hosts += [f"SRV{i}" for i in range(1, 5)]
    if include_printers:
        hosts += [f"PRN{i}" for i in range(1, 5)]
    slots: dict[int, int] = {}
    for index, host in enumerate(hosts):
        switch = index % 6 + 1
        slot = slots.get(switch, 0) + 1
        slots[switch] = slot
        links.append(support.link(host, "f0", f"SW{switch}", f"f0/{slot}"))
    return nodes, links


def test_fifty_device_build_matches_plan_and_disk(tmp_path):
    nodes, links = _mixed_fifty(include_printers=False)
    payload = support.plan(nodes, links, project="fifty")
    built = pkt_builder.build_pkt(payload, LIBRARY)

    support.assertions_for(built, nodes, links)
    assert built["deviceCount"] == 50
    assert built["modelSubstitutions"] == []

    target = tmp_path / "fifty.pkt"
    report = pkt_builder.generate_pkt_file(
        payload, str(target), library=LIBRARY, project="fifty")

    assert report["status"] in ("VALID", "VALID_WITH_WARNINGS")
    assert report["verification"]["ok"] is True
    assert report["verification"]["deviceCountMatches"] is True
    assert report["verification"]["linkCountMatches"] is True
    assert report["verification"]["deviceCountOnDisk"] == 50
    assert report["verification"]["linkCountOnDisk"] == len(links)

    on_disk = pkt_codec.decrypt_pkt(target.read_bytes())
    assert len(re.findall(rb"<DEVICE>", on_disk)) == 50
    assert len(re.findall(rb"<LINK>", on_disk)) == len(links)
    names = {
        match.decode("utf-8", "replace")
        for match in re.findall(
            rb'<DEVICE>.*?<NAME translate="true">([^<]*)</NAME>',
            on_disk, re.S)
    }
    assert names == {entry["name"] for entry in nodes}


def test_fifty_device_complex_plan_with_printers_is_complete():
    nodes, links = _mixed_fifty(include_printers=True)
    built = pkt_builder.build_pkt(
        support.plan(nodes, links, project="complex"), LIBRARY)

    assert built["plannedDevices"] == 50
    assert built["deviceCount"] == 50
    assert built["plannedLinks"] == len(links)
    assert built["linkCount"] == len(links)
    assert built["status"] in ("VALID", "VALID_WITH_WARNINGS")
    assert built["missingDevices"] == []
    assert built["missingLinks"] == []
