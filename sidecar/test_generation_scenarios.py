"""Twenty deterministic network-generation scenarios for the offline compiler.

Each scenario is a complete approved plan (devices, cables, configs). The
compiler must reproduce that plan exactly: same device names, same links,
same cable types, no missing or extra devices, no silent topology change.

What these tests DO prove: the plan -> .pkt compiler preserves the approved
specification, including interface resolution and configuration text.

What they do NOT prove: that Packet Tracer executes the config, that DHCP
leases are handed out, or that pings succeed. Those need a real Packet Tracer
runtime and are reported as NOT TESTED in the implementation report.

Scenario 17 (wireless association) is expected to be skipped: the template
library has no wireless LINK block, so there is nothing honest to execute.
"""

from __future__ import annotations

import pytest

import builder_test_support as support

LIBRARY = support.load_templates()


def _lan(router: bool = True, switch_count: int = 1, pc_count: int = 5):
    nodes: list[dict] = []
    links: list[dict] = []
    if router:
        nodes.append(support.node("R1", "router", support.ROUTER))
    for index in range(1, switch_count + 1):
        nodes.append(support.node(f"SW{index}", "switch", support.SWITCH))
    if router:
        links.append(support.link("R1", "g0/0", "SW1", "g0/1"))
    for index in range(1, switch_count):
        links.append(support.link(
            f"SW{index}", "g0/1", f"SW{index + 1}", "g0/2"))
    for index in range(1, pc_count + 1):
        switch = f"SW{(index - 1) % switch_count + 1}"
        slot = (index - 1) // switch_count + 1
        nodes.append(support.node(f"PC{index}", "pc", support.PC))
        links.append(support.link(
            f"PC{index}", "f0", switch, f"f0/{slot}"))
    return nodes, links


def _run(nodes, links, configs=None, project="scenario"):
    payload = support.plan(nodes, links, configs=configs, project=project)
    built = support.build(payload, template_dir=None)
    support.assertions_for(built, nodes, links)
    return built


def test_01_one_router_one_switch_five_pcs():
    nodes, links = _lan()
    built = _run(nodes, links)
    assert built["deviceCount"] == 7
    assert built["linkCount"] == 6


def test_02_one_switch_ten_pcs():
    nodes, links = _lan(router=False, switch_count=1, pc_count=10)
    built = _run(nodes, links)
    assert built["deviceCount"] == 11
    assert built["linkCount"] == 10


def test_03_two_switches_connected():
    nodes = [
        support.node("SW1", "switch", support.SWITCH),
        support.node("SW2", "switch", support.SWITCH),
    ]
    links = [support.link("SW1", "g0/1", "SW2", "g0/2")]
    built = _run(nodes, links)
    assert built["linkCount"] == 1
    assert built["links"][0]["cable"] == "copper"


def test_04_two_routers_by_serial_cable():
    nodes = [
        support.node("R1", "router", support.SERIAL_ROUTER, ["WIC-2T"]),
        support.node("R2", "router", support.SERIAL_ROUTER, ["WIC-2T"]),
    ]
    links = [support.link(
        "R1", "s0/2/0", "R2", "s0/2/0", cable="serial", exact=True)]
    configs = {"R1": "interface s0/2/0\n clock rate 64000\n no shutdown"}
    built = _run(nodes, links, configs=configs)
    assert built["links"][0]["cable"] == "serial"
    assert b"clock rate 64000" in built["xml"]
    assert built["modelSubstitutions"] == []


def test_05_three_routers_in_a_chain():
    nodes = [
        support.node("R1", "router", support.ROUTER),
        support.node("R2", "router", support.ROUTER),
        support.node("R3", "router", support.ROUTER),
    ]
    links = [
        support.link("R1", "g0/0", "R2", "g0/0"),
        support.link("R2", "g0/1", "R3", "g0/0"),
    ]
    built = _run(nodes, links)
    assert built["deviceCount"] == 3
    assert built["linkCount"] == 2


def test_06_small_office_with_dhcp():
    nodes, links = _lan()
    configs = {
        "R1": "\n".join([
            "ip dhcp excluded-address 192.168.10.1 192.168.10.10",
            "ip dhcp pool LAN",
            " network 192.168.10.0 255.255.255.0",
            " default-router 192.168.10.1",
            " dns-server 192.168.10.2",
            "interface g0/0",
            " ip address 192.168.10.1 255.255.255.0",
            " no shutdown",
        ]),
    }
    built = _run(nodes, links, configs=configs)
    assert b"ip dhcp pool LAN" in built["xml"]
    assert b"default-router 192.168.10.1" in built["xml"]
    assert b"ip address 192.168.10.1 255.255.255.0" in built["xml"]


def test_07_small_office_with_dns_server():
    nodes, links = _lan(pc_count=2)
    nodes.append(support.node("SRV1", "server", support.SERVER))
    links.append(support.link("SRV1", "f0", "SW1", "f0/3"))
    configs = {
        "R1": "\n".join([
            "ip dns server",
            "ip host srv1.lab 192.168.10.10",
            "ip name-server 192.168.10.10",
        ]),
    }
    built = _run(nodes, links, configs=configs)
    assert b"ip dns server" in built["xml"]
    assert b"ip host srv1.lab 192.168.10.10" in built["xml"]


def test_08_network_with_aaa_authentication():
    nodes, links = _lan(pc_count=1)
    nodes.append(support.node("SRV1", "server", support.SERVER))
    links.append(support.link("SRV1", "f0", "SW1", "f0/2"))
    configs = {
        "R1": "\n".join([
            "aaa new-model",
            "tacacs server TAC1",
            " address ipv4 192.168.10.10",
            " key labkey",
            "aaa authentication login default group tacacs+ local",
        ]),
    }
    built = _run(nodes, links, configs=configs)
    assert b"aaa new-model" in built["xml"]
    assert b"aaa authentication login default group tacacs+ local" in built["xml"]


def test_09_two_lans_connected_by_static_routing():
    nodes = [
        support.node("R1", "router", support.ROUTER),
        support.node("R2", "router", support.ROUTER),
        support.node("SW1", "switch", support.SWITCH),
        support.node("SW2", "switch", support.SWITCH),
        *[support.node(f"PC{i}", "pc", support.PC) for i in range(1, 5)],
    ]
    links = [
        support.link("R1", "g0/0", "R2", "g0/0"),
        support.link("R1", "g0/1", "SW1", "g0/1"),
        support.link("R2", "g0/1", "SW2", "g0/1"),
        support.link("PC1", "f0", "SW1", "f0/1"),
        support.link("PC2", "f0", "SW1", "f0/2"),
        support.link("PC3", "f0", "SW2", "f0/1"),
        support.link("PC4", "f0", "SW2", "f0/2"),
    ]
    configs = {
        "R1": "ip route 192.168.20.0 255.255.255.0 10.0.0.2",
        "R2": "ip route 192.168.10.0 255.255.255.0 10.0.0.1",
    }
    built = _run(nodes, links, configs=configs)
    assert b"ip route 192.168.20.0 255.255.255.0 10.0.0.2" in built["xml"]
    assert b"ip route 192.168.10.0 255.255.255.0 10.0.0.1" in built["xml"]


def test_10_three_routers_with_static_routes():
    nodes = [
        support.node("R1", "router", support.ROUTER),
        support.node("R2", "router", support.ROUTER),
        support.node("R3", "router", support.ROUTER),
    ]
    links = [
        support.link("R1", "g0/0", "R2", "g0/0"),
        support.link("R2", "g0/1", "R3", "g0/0"),
    ]
    configs = {
        "R1": "ip route 192.168.30.0 255.255.255.0 10.0.2.2",
        "R2": "ip route 192.168.10.0 255.255.255.0 10.0.0.1\n"
              "ip route 192.168.30.0 255.255.255.0 10.0.1.2",
        "R3": "ip route 192.168.10.0 255.255.255.0 10.0.1.1",
    }
    built = _run(nodes, links, configs=configs)
    assert built["deviceCount"] == 3
    assert built["linkCount"] == 2


def test_11_multiple_switches_with_vlans():
    nodes = [
        *[support.node(f"SW{i}", "switch", support.SWITCH) for i in range(1, 3)],
        *[support.node(f"PC{i}", "pc", support.PC) for i in range(1, 5)],
    ]
    links = [
        support.link("SW1", "g0/1", "SW2", "g0/1"),
        support.link("PC1", "f0", "SW1", "f0/1"),
        support.link("PC2", "f0", "SW1", "f0/2"),
        support.link("PC3", "f0", "SW2", "f0/3"),
        support.link("PC4", "f0", "SW2", "f0/4"),
    ]
    configs = {
        "SW1": "\n".join([
            "vlan 10",
            " name sales",
            "vlan 20",
            " name engineering",
            "interface f0/1",
            " switchport mode access",
            " switchport access vlan 10",
            "interface g0/1",
            " switchport mode trunk",
        ]),
        "SW2": "\n".join([
            "vlan 10",
            "vlan 20",
            "interface g0/1",
            " switchport mode trunk",
        ]),
    }
    built = _run(nodes, links, configs=configs)
    assert b"switchport mode trunk" in built["xml"]
    assert b"switchport access vlan 10" in built["xml"]


def test_12_inter_vlan_routing():
    nodes, links = _lan(pc_count=4)
    configs = {
        "R1": "\n".join([
            "interface g0/0.10",
            " encapsulation dot1Q 10",
            " ip address 192.168.10.1 255.255.255.0",
            "interface g0/0.20",
            " encapsulation dot1Q 20",
            " ip address 192.168.20.1 255.255.255.0",
        ]),
        "SW1": "\n".join([
            "vlan 10",
            "vlan 20",
            "interface g0/1",
            " switchport mode trunk",
        ]),
    }
    built = _run(nodes, links, configs=configs)
    assert b"interface GigabitEthernet0/0.10" in built["xml"]
    assert b"encapsulation dot1Q 10" in built["xml"]
    assert b"interface GigabitEthernet0/0.20" in built["xml"]


def test_13_network_using_ospf():
    nodes = [
        support.node("R1", "router", support.ROUTER),
        support.node("R2", "router", support.ROUTER),
        support.node("R3", "router", support.ROUTER),
    ]
    links = [
        support.link("R1", "g0/0", "R2", "g0/0"),
        support.link("R2", "g0/1", "R3", "g0/0"),
    ]
    configs = {
        name: "router ospf 1\n network 10.0.0.0 0.255.255.255 area 0"
        for name in ("R1", "R2", "R3")
    }
    built = _run(nodes, links, configs=configs)
    # The plan's lines are written to both RUNNINGCONFIG and STARTUPCONFIG
    # (a generated device has never run `write memory`), so count the
    # per-device config rather than raw occurrences in the whole document.
    assert all(entry["configLines"] == 2 for entry in built["devices"])
    assert b"router ospf 1" in built["xml"]
    assert b"network 10.0.0.0 0.255.255.255 area 0" in built["xml"]


def test_14_network_with_multiple_servers():
    nodes, links = _lan(pc_count=2)
    for index in range(1, 4):
        nodes.append(support.node(f"SRV{index}", "server", support.SERVER))
        links.append(support.link(
            f"SRV{index}", "f0", "SW1", f"f0/{index + 2}"))
    built = _run(nodes, links)
    # R1, SW1, two PCs and three servers.
    assert built["deviceCount"] == 7
    assert built["linkCount"] == 6


def test_15_network_with_printers_is_refused_explicitly():
    nodes, links = _lan(pc_count=2)
    for index in range(1, 3):
        nodes.append(support.node(f"PRN{index}", "printer", support.PRINTER))
        links.append(support.link(
            f"PRN{index}", "f0", "SW1", f"f0/{index + 2}"))
    built = support.build(support.plan(nodes, links), template_dir=LIBRARY)

    assert built["status"] == "EXPORT_INCOMPLETE"
    assert built["deviceCount"] == built["plannedDevices"] - 2
    assert {entry["name"] for entry in built["missingDevices"]} == {"PRN1", "PRN2"}
    assert len(built["missingLinks"]) == 2


def test_16_network_with_laptops():
    nodes = [support.node("SW1", "switch", support.SWITCH)]
    links = []
    for index in range(1, 7):
        nodes.append(support.node(f"L{index}", "laptop", support.LAPTOP))
        links.append(support.link(f"L{index}", "f0", "SW1", f"f0/{index}"))
    built = _run(nodes, links)
    assert built["deviceCount"] == 7
    assert built["linkCount"] == 6


def test_17_wired_and_wireless_is_explicit_when_unsupported():
    """No wireless LINK template exists, so association cannot be built.

    The invariant under test is that the compiler never silently drops the
    wireless devices: either they are all in the file, or each one is named
    in missingDevices with an incomplete status.
    """
    nodes = [
        support.node("SW1", "switch", support.SWITCH),
        support.node("AP1", "wireless", "AccessPoint-PT"),
        support.node("L1", "laptop", support.LAPTOP),
        support.node("L2", "laptop", support.LAPTOP),
    ]
    links = [support.link("SW1", "g0/1", "AP1", "f0")]

    built = support.build(support.plan(nodes, links), template_dir=LIBRARY)
    if built["status"] in ("VALID", "VALID_WITH_WARNINGS"):
        assert support.device_names(built) == {item["name"] for item in nodes}
    else:
        missing = {entry["name"] for entry in built["missingDevices"]}
        assert missing, "wireless devices disappeared without a report"
        assert support.device_names(built) | missing == {
            item["name"] for item in nodes}


def test_18_thirty_mixed_devices():
    nodes = [
        *[support.node(f"R{i}", "router", support.ROUTER) for i in range(1, 4)],
        *[support.node(f"SW{i}", "switch", support.SWITCH) for i in range(1, 7)],
        *[support.node(f"PC{i}", "pc", support.PC) for i in range(1, 16)],
        *[support.node(f"L{i}", "laptop", support.LAPTOP) for i in range(1, 4)],
        *[support.node(f"SRV{i}", "server", support.SERVER) for i in range(1, 4)],
    ]
    links = []
    for index in range(6):
        links.append(support.link(
            f"R{index // 2 + 1}", f"g0/{index % 2}",
            f"SW{index + 1}", "g0/1"))
    hosts = [f"PC{i}" for i in range(1, 16)]
    hosts += [f"L{i}" for i in range(1, 4)]
    hosts += [f"SRV{i}" for i in range(1, 4)]
    slots: dict[int, int] = {}
    for index, host in enumerate(hosts):
        switch = index % 6 + 1
        slot = slots.get(switch, 0) + 1
        slots[switch] = slot
        links.append(support.link(host, "f0", f"SW{switch}", f"f0/{slot}"))

    assert len(nodes) == 30
    built = _run(nodes, links)
    assert built["deviceCount"] == 30


def _mixed_fifty(include_printers: bool):
    nodes = [
        *[support.node(f"R{i}", "router", support.ROUTER) for i in range(1, 4)],
        *[support.node(f"SW{i}", "switch", support.SWITCH) for i in range(1, 7)],
    ]
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

    links = []
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


def test_19_exactly_fifty_devices():
    nodes, links = _mixed_fifty(include_printers=False)
    assert len(nodes) == 50
    built = _run(nodes, links)
    assert built["deviceCount"] == 50
    assert built["linkCount"] == len(links)


def test_20_complex_fifty_device_network_with_printers():
    nodes, links = _mixed_fifty(include_printers=True)
    assert len(nodes) == 50
    built = support.build(support.plan(nodes, links), template_dir=LIBRARY)

    # The printers are genuinely unsupported by this machine's template
    # library. The correct result is an incomplete export that names them,
    # not a 46-device file reported as a success.
    assert built["status"] == "EXPORT_INCOMPLETE"
    assert built["deviceCount"] == 46
    assert built["plannedDevices"] == 50
    assert {entry["name"] for entry in built["missingDevices"]} == {
        f"PRN{i}" for i in range(1, 5)
    }
    assert len(built["missingLinks"]) == 4
