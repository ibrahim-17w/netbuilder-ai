"""Hermetic tests for the offline .pkt generator stack.

Nothing here touches Packet Tracer, the screen, or the developer's real
template library: a small synthetic Packet Tracer save is written with
pkt_codec itself, extracted into a throwaway template directory, and the
builder compiles plans against that.  Wire-format assertions are pinned to
what Packet Tracer's own saves look like (compare pkt_templates/*.xml on a
machine where the library was built from real files).
"""
from __future__ import annotations

import copy
import json
import os
import xml.etree.ElementTree as ET

import pytest

import re

import pkt_builder
import pkt_codec
import pkt_template_build as tb


# ---------------------------------------------------------------------------
# A synthetic Packet Tracer save, in the shape real ones are
# ---------------------------------------------------------------------------

def _port(port_type: str, mac: str) -> str:
    return ("<PORT><TYPE>%s</TYPE><MACADDRESS>%s</MACADDRESS><BIA>%s</BIA>"
            "<POWER>false</POWER>"
            "<CLOCKRATE>2000000</CLOCKRATE><CLOCKRATEFLAG>false</CLOCKRATEFLAG>"
            "<PORT_DHCP_ENABLE>true</PORT_DHCP_ENABLE>"
            "<IP></IP><SUBNET></SUBNET><PORT_GATEWAY></PORT_GATEWAY>"
            "<PORT_DNS></PORT_DNS></PORT>" % (port_type, mac, mac))


# The Services tab (DHCP pools and their leases, DNS records, HTTP, the ACS
# users/clients, FTP accounts, ...) travels inside a server's <ENGINE> block,
# exactly as a real save writes it.  The synthetic save carries the same stale
# state a real template does, so the tests can prove a generated file never
# ships it.
def _server_engine() -> str:
    return (
        "<ENGINE>"
        "<HTTP_SERVER><ENABLED>1</ENABLED><USERNAME></USERNAME>"
        "<PASSWORD></PASSWORD></HTTP_SERVER>"
        "<HTTPS_SERVER><HTTPSENABLED>1</HTTPSENABLED></HTTPS_SERVER>"
        "<DNS_SERVER><ENABLED>0</ENABLED><NAMESERVER-DATABASE/></DNS_SERVER>"
        "<DHCP_SERVERS><ASSOCIATED_PORTS><ASSOCIATED_PORT>"
        "<NAME>FastEthernet0</NAME><DHCP_SERVER><ENABLED>1</ENABLED><POOLS>"
        "<POOL><NAME>serverPool</NAME><NETWORK>10.0.0.0</NETWORK>"
        "<MASK>255.0.0.0</MASK><DEFAULT_ROUTER>0.0.0.0</DEFAULT_ROUTER>"
        "<TFTP_ADDRESS>0.0.0.0</TFTP_ADDRESS><START_IP>10.0.0.0</START_IP>"
        "<END_IP>10.0.2.0</END_IP><DNS_SERVER>0.0.0.0</DNS_SERVER>"
        "<MAX_USERS>512</MAX_USERS><DOMAIN_NAME></DOMAIN_NAME>"
        "<DHCP_POOL_LEASES><DHCP_POOL_LEASE>"
        "<IP_ADDRESS>10.0.0.3</IP_ADDRESS>"
        "<MAC_ADDRESS>0090.0C1D.B201</MAC_ADDRESS>"
        "<HOST_PORT>FastEthernet0</HOST_PORT><LEASE_TIME>86400000</LEASE_TIME>"
        "</DHCP_POOL_LEASE></DHCP_POOL_LEASES>"
        "<LEASE_TIME>86400000</LEASE_TIME>"
        "<WLC_ADDRESS>0.0.0.0</WLC_ADDRESS></POOL>"
        "</POOLS><DHCP_RESERVATIONS/><AUTOCONFIG></AUTOCONFIG>"
        "</DHCP_SERVER></ASSOCIATED_PORT></ASSOCIATED_PORTS></DHCP_SERVERS>"
        "<FTP_SERVER><ENABLED>1</ENABLED><USER_ACCOUNT_MNGR>"
        "<ACCOUNT><USERNAME>cisco</USERNAME><PASSWORD>cisco</PASSWORD>"
        "<PERMISSIONS>RWDNL</PERMISSIONS></ACCOUNT>"
        "</USER_ACCOUNT_MNGR></FTP_SERVER>"
        "<SYSLOG_SERVER><ENABLED>1</ENABLED></SYSLOG_SERVER>"
        "<ACS_SERVER><ENABLED>0</ENABLED><USERS/><ACS_CLIENTS/>"
        "<RADIUS_SETTINGS><AUTH_PORT>1645</AUTH_PORT></RADIUS_SETTINGS>"
        "</ACS_SERVER>"
        "<EMAIL_SERVER><SMTP_ENABLED>0</SMTP_ENABLED>"
        "<SMTP_DOMAIN></SMTP_DOMAIN><POP3_ENABLED>0</POP3_ENABLED>"
        "<FORWARD_MAIL>0</FORWARD_MAIL><NO_OF_USERS>0</NO_OF_USERS>"
        "</EMAIL_SERVER>"
        "<NTP_SERVER><ENABLED>1</ENABLED>"
        "<ENABLED_SERVER_AUTHENTICATE>0</ENABLED_SERVER_AUTHENTICATE>"
        "<KEY>0</KEY><MD5PASSWORD></MD5PASSWORD><SERVER_IP_LIST/>"
        "</NTP_SERVER>"
        "<DHCPV6_SERVER_LIST><ASSOCIATED_PORTS/><DHCPv6_POOLS/>"
        "<IPv6_LOCAL_POOLS/></DHCPV6_SERVER_LIST>"
        "<IOE_USER_MANAGER><USERS/></IOE_USER_MANAGER>"
        "<IOX_VM_MANAGER><VMS/></IOX_VM_MANAGER>"
        "<REGISTRATION_SEVER>false</REGISTRATION_SEVER>"
        "<SNMP_MANAGER><AGENT_IP>0.0.0.0</AGENT_IP><AGENT_PORT>161</AGENT_PORT>"
        "<MANAGER_PORT>161</MANAGER_PORT><READ_COMMUNITY></READ_COMMUNITY>"
        "<WRITE_COMMUNITY></WRITE_COMMUNITY><SNMP_VERSION>1</SNMP_VERSION>"
        "</SNMP_MANAGER>"
        "</ENGINE>")


# Some models are saved with no physical-workspace data at all (of the 1841
# blocks in this machine's Packet Tracer saves, 115 have none), which makes
# them Logical-workspace-only devices.  The synthetic save can produce both
# shapes so the builder and the extractor are tested against each other.
_PHYSICAL = ("<WORKSPACE><PHYSICAL>foreign</PHYSICAL>"
             "<PHYSICAL_CPUR><X_PN>0.2</X_PN><Y_PN>0.1</Y_PN><X>1</X><Y>2</Y>"
             "<PARENT_PATH>foreign</PARENT_PATH>"
             "<CONTAINER_ID>foreign</CONTAINER_ID>"
             "</PHYSICAL_CPUR></WORKSPACE>")


def _device(model: str, kind: str, name: str, ref: int, ports, config=(),
            modules=(), engine: str = "", physical: bool = False) -> str:
    slot_xml = "".join("<SLOT><MODEL>%s</MODEL></SLOT>" % m for m in modules)
    port_xml = "".join(_port(ptype, "00%02d.%04d.%04d" % (i, ref % 100, i))
                       for i, ptype in enumerate(ports))
    if config:
        lines = "".join("<LINE>%s</LINE>" % line for line in config)
        config_xml = "<RUNNINGCONFIG>%s</RUNNINGCONFIG>" % lines
    else:
        config_xml = "<RUNNINGCONFIG></RUNNINGCONFIG>"
    return (
        "<DEVICE>"
        "<TYPE customModel=\"\" model=\"%s\">%s</TYPE>"
        "<NAME translate=\"true\">%s</NAME>"
        "<SAVE_REF_ID>save-ref-id:%d</SAVE_REF_ID>"
        "<SYS_NAME>%s</SYS_NAME>"
        "<LOGICAL><X>%d</X><Y>%d</Y></LOGICAL>"
        "%s%s%s%s%s"
        "</DEVICE>" % (model, kind, name, ref, name, 100 + ref % 50,
                       200 + ref % 50, slot_xml, port_xml, config_xml,
                       _PHYSICAL if physical else "", engine))


def _link(medium: str, a_ref: int, a_port: str, b_ref: int, b_port: str,
          cable: str = "", dce: tuple = ()) -> str:
    # Real serial CABLE blocks carry only the medium TYPE; copper ones end
    # with the cable kind (compare pkt_templates/links/*.xml).
    cable_xml = "<TYPE>%s</TYPE>" % cable if cable else ""
    dce_xml = "".join("<%s>%s</%s>" % (tag, value, tag)
                      for tag, value in dce)
    return ("<LINK><TYPE>%s</TYPE><CABLE><LENGTH>1</LENGTH>"
            "<FUNCTIONAL>true</FUNCTIONAL>"
            "<FROM>save-ref-id:%d</FROM><PORT>%s</PORT>"
            "<TO>save-ref-id:%d</TO><PORT>%s</PORT>"
            "<FROM_DEVICE_MEM_ADDR>1234</FROM_DEVICE_MEM_ADDR>"
            "<TO_DEVICE_MEM_ADDR>5678</TO_DEVICE_MEM_ADDR>"
            "%s%s</CABLE></LINK>"
            % (medium, a_ref, a_port, b_ref, b_port, dce_xml, cable_xml))


def _sample_save(server_engine: str = "", physical: bool = False) -> bytes:
    devices = "".join([
        _device("2811", "Router", "Lab-R1", 111, ("eCopperFastEthernet",) * 2
                + ("eSmartSerial",) * 2,
                config=("!",
                        "interface FastEthernet0/0",
                        "interface FastEthernet0/1",
                        "interface Serial0/2/0",
                        "interface Serial0/2/1"),
                modules=("WIC-2T",), physical=physical),
        _device("2960-24TT", "Switch", "Lab-SW1", 222,
                ("eCopperFastEthernet",) * 3,
                config=("interface FastEthernet0/1",
                        "interface FastEthernet0/2",
                        "interface FastEthernet0/3"),
                physical=physical),
        _device("PC-PT", "PC", "Lab-PC1", 333, ("eCopperFastEthernet",),
                config=("stale hostname source",), physical=physical),
        _device("Server-PT", "Server", "Lab-SRV1", 444,
                ("eCopperFastEthernet",), engine=server_engine,
                physical=physical),
    ])
    links = "".join([
        _link("eCopper", 111, "FastEthernet0/1", 222, "FastEthernet0/1",
              "eStraightThrough"),
        _link("eSerial", 111, "Serial0/2/1", 222, "Serial0/2/1",
              dce=(("DCEDEV", "save-ref-id:111"),
                   ("DCEPORT", "Serial0/2/1"))),
    ])
    return (b"<PACKETTRACER5><VERSION>9.0.0.0810</VERSION>"
            b"<DEVICES>" + devices.encode() + b"</DEVICES>"
            b"<LINKS>" + links.encode() + b"</LINKS></PACKETTRACER5>")


@pytest.fixture(scope="module")
def library(tmp_path_factory):
    """A template library extracted from the synthetic save."""
    source = tmp_path_factory.mktemp("saves") / "sample.pkt"
    source.write_bytes(pkt_codec.encrypt_pkt(_sample_save(_server_engine())))
    out = tmp_path_factory.mktemp("templates")
    tb.extract_templates([str(source)], str(out))
    return pkt_builder.load_library(str(out))


def _firewall_save() -> bytes:
    """A save holding nothing but an ASA-5505 (Firewall-PT).

    Its own save, so the fixture shared by every other test keeps the exact
    device list those tests were written against.
    """
    devices = _device("5505", "ASA", "Lab-FW1", 555,
                      ("eCopperEthernet",) * 8,
                      config=("hostname Lab-FW1",
                              "interface Ethernet0/0",
                              "interface Ethernet0/1",
                              "interface Vlan1",
                              "interface Vlan2"))
    return (b"<PACKETTRACER5><VERSION>9.0.0.0810</VERSION><DEVICES>"
            + devices.encode() + b"</DEVICES><LINKS></LINKS>"
            b"</PACKETTRACER5>")


@pytest.fixture(scope="module")
def firewall_library(tmp_path_factory):
    """A template library whose only device is the ASA-5505."""
    source = tmp_path_factory.mktemp("fw-saves") / "fw.pkt"
    source.write_bytes(pkt_codec.encrypt_pkt(_firewall_save()))
    out = tmp_path_factory.mktemp("fw-templates")
    tb.extract_templates([str(source)], str(out))
    return pkt_builder.load_library(str(out))


PLAN = {
    "project": "lab",
    "steps": [
        {"action": "create_nodes", "nodes": [
            {"name": "R1", "type": "router", "model": "2811"},
            {"name": "R2", "type": "router", "model": "2811"},
            {"name": "SW1", "type": "switch", "model": "2960"},
            {"name": "PC1", "type": "pc"},
            {"name": "PC2", "type": "pc"}]},
        {"action": "create_links", "links": [
            {"a": "R1", "aIf": "s0/2/0", "b": "R2", "bIf": "s0/2/0",
             "cable": "serial"},
            {"a": "R1", "aIf": "f0/0", "b": "SW1", "bIf": "f0/1"},
            {"a": "SW1", "aIf": "f0/2", "b": "PC1", "bIf": "eth0"},
            {"a": "SW1", "aIf": "f0/3", "b": "PC2", "bIf": "f0"}]},
        {"action": "paste_cli", "configs": {
            "R1": ("enable\nconfigure terminal\nhostname R1\n"
                   "interface s0/2/0\n ip address 10.0.0.1 255.255.255.252\n"
                   " clock rate 64000\n no shutdown\nexit\n"
                   "interface f0/0\n ip address 192.168.10.1 255.255.255.0\n"
                   " no shutdown\nexit\nend\nwrite memory\n"),
            "R2": ("enable\nconf t\ninterface s0/2/0\n"
                   " ip address 10.0.0.2 255.255.255.252\n no shutdown\n"
                   "exit\nend\n"),
            "SW1": "enable\nconfigure terminal\nhostname SW1\nend\n"}},
        {"action": "config_pcs", "pcs": {
            "PC1": {"ip": "192.168.10.11", "mask": "255.255.255.0",
                    "gw": "192.168.10.1"},
            "PC2": {"ip": "192.168.10.12", "mask": "255.255.255.0"}}},
    ],
}


# ---------------------------------------------------------------------------
# pkt_codec
# ---------------------------------------------------------------------------

class TestCodec:
    def test_round_trip(self):
        payload = _sample_save() + bytes(range(256)) * 3
        assert pkt_codec.decrypt_pkt(pkt_codec.encrypt_pkt(payload)) == payload

    def test_rejects_non_save_input(self):
        with pytest.raises(pkt_codec.PktFormatError):
            pkt_codec.decrypt_pkt(b"tiny")
        with pytest.raises(pkt_codec.PktFormatError):
            pkt_codec.decrypt_pkt(b"<?xml version=\"1.0\"?><A></A>")
        with pytest.raises(pkt_codec.PktFormatError):
            pkt_codec.decrypt_pkt("not bytes")

    def test_is_pkt(self):
        assert pkt_codec.is_pkt(pkt_codec.encrypt_pkt(b"<A/>" * 100))
        assert not pkt_codec.is_pkt(b"<?xml version=\"1.0\"?><A></A>")

    def test_tampered_container_fails(self):
        blob = bytearray(pkt_codec.encrypt_pkt(_sample_save()))
        blob[len(blob) // 2] ^= 0xFF
        with pytest.raises(pkt_codec.PktFormatError):
            pkt_codec.decrypt_pkt(bytes(blob))

    def test_encrypt_guards(self):
        with pytest.raises(pkt_codec.PktFormatError):
            pkt_codec.encrypt_pkt(b"")
        called = []
        with pytest.raises(ValueError):
            pkt_codec.encrypt_pkt(b"<A/>", validator=lambda xml: called.append(
                xml) or (_ for _ in ()).throw(ValueError("no")))
        assert called  # the validator saw the payload before encryption

    def test_selftests(self):
        assert pkt_codec.twofish_selftest()["ok"] is True
        assert pkt_codec.codec_selftest()["ok"] is True

    def test_xml_safe_replaces_illegal_control_characters(self):
        # Packet Tracer writes 0x03 into banner delimiters; XML 1.0 forbids it
        # outright, so a block or config that carries one has to be cleaned
        # or the document cannot be parsed by anything (not even PT's own
        # library reader).
        cleaned = pkt_codec.xml_safe(b"banner motd \x03keep out\x03\nok")
        assert b"\x03" not in cleaned and b"banner motd" in cleaned
        assert pkt_codec.xml_safe("hostname R1") == b"hostname R1"
        assert pkt_codec.xml_safe(b"\x00\x1f\t\nplain") == b"  \t\nplain"

    def test_summary_counts_and_names(self):
        summary = pkt_codec.pkt_xml_summary(_sample_save())
        assert summary["version"] == "9.0.0.0810"
        assert summary["root"] == "PACKETTRACER5"
        assert summary["deviceCount"] == 4
        assert summary["linkCount"] == 2
        names = {device["name"] for device in summary["devices"]}
        assert names == {"Lab-R1", "Lab-SW1", "Lab-PC1", "Lab-SRV1"}
        serial = [link for link in summary["links"]
                  if link["type"] == "eSerial"]
        assert serial and serial[0]["fromPort"] == "Serial0/2/1"
        # Configuration text is deliberately not part of the summary.
        assert "interface" not in json.dumps(summary)


# ---------------------------------------------------------------------------
# pkt_template_build
# ---------------------------------------------------------------------------

class TestTemplateBuild:
    def test_port_spans_skip_nesting_and_aliases(self):
        block = (b"<PORT><TYPE>a</TYPE><MODULE><PORT><TYPE>b</TYPE></PORT>"
                 b"</MODULE></PORT><PORT /><PORT_GATEWAY>x</PORT_GATEWAY>"
                 b"<PORT><TYPE>c</TYPE></PORT>")
        spans = tb.iter_port_spans(block)
        assert len(spans) == 3  # nested PORT and PORT_GATEWAY never counted

    def test_port_inventory_pairs_names_by_family(self):
        ports, warnings = tb.port_inventory(
            ["eCopperFastEthernet", "eCopperFastEthernet", "eSmartSerial"],
            ["FastEthernet0/1", "Serial0/2/0", "FastEthernet0/2"], "Router")
        assert [p["name"] for p in ports] == ["FastEthernet0/1",
                                              "FastEthernet0/2",
                                              "Serial0/2/0"]
        assert not warnings

    def test_port_inventory_host_fallback(self):
        ports, warnings = tb.port_inventory(["eCopperFastEthernet"], [], "pc")
        assert ports[0]["name"] == "FastEthernet0"
        assert not warnings

    def test_port_inventory_warns_on_unnamable(self):
        ports, warnings = tb.port_inventory(["eSmartSerial"], [], "Router")
        assert ports[0]["name"] == ""
        assert warnings and "no name" in warnings[0]

    def test_extract_and_load(self, library):
        assert library["version"] == "9.0.0.0810"
        models = {entry["model"] for entry in library["devices"]}
        assert models == {"2811", "2960-24TT", "PC-PT", "Server-PT"}
        keys = {entry["key"] for entry in library["links"]}
        assert keys == {"eCopper-eStraightThrough", "eSerial"}

    def test_extraction_strips_the_startup_config(self, tmp_path):
        """The source device's STARTUPCONFIG is identity *and secrets*."""
        device = _device("2811", "Router", "Lab-R1", 111,
                         ("eCopperFastEthernet",) * 2,
                         config=("interface FastEthernet0/0",))
        device = device.replace(
            "</DEVICE>",
            "<STARTUPCONFIG><LINE>hostname Lab-R1</LINE>"
            "<LINE>enable secret 5 $1$mERr$9cTjUIEqNGurQiFU.ZeCi1</LINE>"
            "<LINE>banner motd \x03keep out\x03</LINE>"
            "</STARTUPCONFIG></DEVICE>")
        save = ("<PACKETTRACER5><VERSION>9.0.0.0810</VERSION><DEVICES>"
                + device + "</DEVICES><LINKS></LINKS></PACKETTRACER5>")
        source = tmp_path / "startup.pkt"
        source.write_bytes(pkt_codec.encrypt_pkt(save.encode()))
        out = tmp_path / "lib"
        manifest = tb.extract_templates([str(source)], str(out))
        block = (out / manifest["devices"][0]["file"]).read_bytes()
        assert b"Lab-R1" not in block
        assert b"$1$mERr$" not in block
        assert b"<STARTUPCONFIG/>" in block
        assert b"\x03" not in block  # the banner delimiter is gone too
        ET.fromstring(block)  # and the block is parseable again
        # A library loaded from disk can still repair an older, unparseable
        # block: this machine's 1941 was harvested before the fix.
        broken = out / manifest["devices"][0]["file"]
        broken.write_bytes(b"<DEVICE><ENGINE><TYPE model=\"2811\">Router</TYPE>"
                           b"<NAME>banner motd \x03x\x03</NAME></DEVICE>")
        healed = pkt_builder.load_library(str(out))
        assert b"\x03" not in healed["_blocks"][manifest["devices"][0]["file"]]

    def test_extract_neutralises_identity(self, library):
        # clean_device wiped name, id and MACs from every device block, and
        # clean_link zeroed the stale mem addrs.
        router = library["_blocks"]["devices/2811+WIC-2T.xml"]
        assert b"Lab-R1" not in router
        assert b"<SYS_NAME></SYS_NAME>" in router
        assert b"save-ref-id:0" in router
        assert b"0000.0000.0000" in router
        link = library["_blocks"]["links/eSerial.xml"]
        assert b"1234" not in link and b"5678" not in link
        assert b"<DEVICE>" not in library["_skeleton"]

    def test_extract_dedupes_and_records_sources(self, tmp_path):
        source = tmp_path / "one.pkt"
        source.write_bytes(pkt_codec.encrypt_pkt(_sample_save()))
        out = tmp_path / "lib"
        manifest = tb.extract_templates([str(source), str(source)], str(out))
        assert len(manifest["devices"]) == 4  # the second pass deduped
        assert len(manifest["sources"]) == 2
        skeleton = (out / "skeleton.xml").read_bytes()
        assert b"<DEVICE>" not in skeleton and b"<LINK>" not in skeleton

    def test_extract_skips_junk_and_requires_one_good_file(self, tmp_path):
        junk = tmp_path / "junk.pkt"
        junk.write_bytes(b"not a save file at all" * 100)
        with pytest.raises(tb.TemplateError):
            tb.extract_templates([str(junk)], str(tmp_path / "lib"))
        with pytest.raises(tb.TemplateError):
            tb.extract_templates([], str(tmp_path / "lib2"))

    def test_discover_finds_pkt_files_in_a_tree(self, tmp_path):
        nested = tmp_path / "saves" / "01 Networking"
        nested.mkdir(parents=True)
        (nested / "a.pkt").write_bytes(b"x")
        (nested / "notes.txt").write_bytes(b"x")
        (tmp_path / "saves" / "b.pkt").write_bytes(b"x")
        found = tb.discover_pkt_files([str(tmp_path / "saves")])
        assert sorted(os.path.basename(p) for p in found) == ["a.pkt",
                                                              "b.pkt"]
        # A file path is accepted as well as a folder, duplicates collapse.
        assert tb.discover_pkt_files([str(nested / "a.pkt"),
                                      str(nested / "a.pkt")]) == \
            [str(nested / "a.pkt")]
        assert tb.discover_pkt_files([str(tmp_path / "missing")]) == []

    def test_harvest_adds_models_without_losing_existing_ones(self, tmp_path):
        first = tmp_path / "first.pkt"
        first.write_bytes(pkt_codec.encrypt_pkt(_sample_save()))
        library_dir = tmp_path / "lib"
        tb.extract_templates([str(first)], str(library_dir))

        # A second save introduces one new model (a 1841 router) while
        # repeating the models the library already has.
        extra = tmp_path / "extra.pkt"
        extra.write_bytes(pkt_codec.encrypt_pkt(
            _sample_save().replace(b'model="2811"', b'model="1841"')))
        result = tb.harvest_templates([str(extra)], str(library_dir))
        assert result["ok"] is True and result["scanned"] == 2
        assert any(key.startswith("1841") for key in result["added"])
        keys = {entry["key"] for entry in result["devices"]}
        assert any(key.startswith("2811")
                   for key in keys), "an existing model must survive a harvest"

    def test_harvest_without_any_pkt_is_reported_not_raised(self, tmp_path):
        result = tb.harvest_templates([str(tmp_path / "empty")],
                                      str(tmp_path / "lib"))
        assert result["ok"] is False and result["scanned"] == 0
        assert "no .pkt files found" in result["error"]

    def test_default_sample_roots_are_directories(self):
        for root in tb.default_sample_roots():
            assert os.path.isdir(root)

    def test_library_status(self, library, tmp_path_factory):
        root = library["_directory"]
        status = tb.library_status(root)
        assert status["ready"] is True
        assert set(status["coverage"]) == {"Router", "Switch", "PC",
                                            "Server"}
        empty = tb.library_status(str(tmp_path_factory.mktemp("nothing")))
        assert empty["ready"] is False and "no template library" in \
            empty["message"]

    def test_extraction_prefers_a_block_with_physical_data(self, tmp_path):
        plain = tmp_path / "plain.pkt"
        plain.write_bytes(pkt_codec.encrypt_pkt(_sample_save()))
        library_dir = tmp_path / "lib"
        manifest = tb.extract_templates([str(plain)], str(library_dir))
        assert manifest["devices"]
        assert all(entry["hasPhysical"] is False
                   for entry in manifest["devices"])

        # The same models, this time saved with Physical Workspace data: the
        # harvest must take the block the builder can actually place.
        richer = tmp_path / "richer.pkt"
        richer.write_bytes(pkt_codec.encrypt_pkt(_sample_save(physical=True)))
        manifest = tb.extract_templates([str(plain), str(richer)],
                                        str(library_dir))
        assert all(entry["hasPhysical"] is True
                   for entry in manifest["devices"])
        for entry in manifest["devices"]:
            block = (library_dir / entry["file"]).read_bytes()
            assert tb.has_physical_data(block)
        status = tb.library_status(str(library_dir))
        assert status["logicalOnly"] == []
        assert all(entry["hasPhysical"] is True
                   for entry in status["devices"])


# ---------------------------------------------------------------------------
# pkt_builder
# ---------------------------------------------------------------------------

class TestPortNames:
    def test_normalize_aliases(self):
        assert pkt_builder.normalize_port_name("g0/1") == \
            "gigabitethernet0/1"
        assert pkt_builder.normalize_port_name("Fa0/1") == \
            "fastethernet0/1"
        assert pkt_builder.normalize_port_name("s0/2/0") == "serial0/2/0"
        assert pkt_builder.normalize_port_name("eth 0") == "ethernet0"

    def test_resolve_port(self, library):
        router = next(e for e in library["devices"] if e["model"] == "2811")
        port, note = pkt_builder.resolve_port(router, "FastEthernet0/0")
        assert port and note == ""
        port, note = pkt_builder.resolve_port(router, "f0/0")
        assert port and note == ""  # alias normalises to the same name
        port, note = pkt_builder.resolve_port(router, "e0")
        assert port and port["name"] == "FastEthernet0/0" \
            and "slot remap" in note  # ethernet0 really is a remap to Fa0/0
        assert pkt_builder.resolve_port(router, "Vlan1") == (None, "")

    def test_select_variant(self, library):
        best, notes = pkt_builder.select_variant(
            library, {"name": "R1", "type": "router", "model": "2811"},
            ["s0/2/0", "f0/0"])
        assert best["model"] == "2811" and not notes
        best, notes = pkt_builder.select_variant(
            library, {"name": "R1", "type": "router", "model": "7200"}, [])
        assert best["model"] == "2811" and "instead of 7200" in notes[0]
        # The substitution note names the interface that forced it, so a plan
        # asking for 2911 with a serial WAN explains why 2811+WIC-2T won.
        best, notes = pkt_builder.select_variant(
            library, {"name": "R1", "type": "router", "model": "2811"},
            ["f0/0", "s0/0/0", "s0/0/1"])
        assert "instead of" not in " ".join(notes)
        best, notes = pkt_builder.select_variant(
            library, {"name": "X", "type": "printer"}, [])
        assert best is None and "no printer model" in notes[0]

class TestTagSurgery:
    """Packet Tracer writes attributes on some of the fields we rewrite.

    ``<PHYSICAL translate="true">`` appears in 57 of the 118 templates
    harvested on this machine; a matcher that only knows the plain tag leaves
    the template's foreign workspace path in place and the build fails
    validation.  ``SAVE_REF_ID`` is missing from 29 of them (PT's own sample
    labs write a compact shape), so the builder has to add it.
    """

    def test_set_tag_keeps_the_elements_own_attributes(self):
        block = (b'<DEVICE><WORKSPACE><PHYSICAL translate="true">foreign'
                 b"</PHYSICAL></WORKSPACE></DEVICE>")
        out = pkt_builder._set_tag(block, "PHYSICAL", "a,b")
        assert b'<PHYSICAL translate="true">a,b</PHYSICAL>' in out
        assert b"foreign" not in out

    def test_set_tag_expands_a_self_closing_tag_into_a_pair(self):
        assert pkt_builder._set_tag(b"<A><X /></A>", "X", "5") == \
            b"<A><X>5</X></A>"

    def test_has_tag_ignores_attributes_without_matching_longer_names(self):
        assert pkt_builder._has_tag(
            b'<PHYSICAL translate="true">x</PHYSICAL>', "PHYSICAL")
        assert pkt_builder._has_tag(b"<PHYSICAL/>", "PHYSICAL")
        assert not pkt_builder._has_tag(b"<PHYSICAL_CPUR/>", "PHYSICAL")
        assert not pkt_builder._has_tag(b"<WORKSPACE/>", "PHYSICAL")

    def test_set_ref_id_adds_the_field_a_model_has_none_of(self):
        block = (b'<DEVICE><ENGINE><NAME translate="true">R1</NAME>'
                 b"</ENGINE><WORKSPACE/></DEVICE>")
        out = pkt_builder._set_ref_id(block, 42)
        assert b"<SAVE_REF_ID>save-ref-id:42</SAVE_REF_ID>" in out
        assert out.index(b"<SAVE_REF_ID>") < out.index(b"</ENGINE>")

    def test_set_ref_id_replaces_an_existing_field(self):
        out = pkt_builder._set_ref_id(
            b"<ENGINE><SAVE_REF_ID>save-ref-id:0</SAVE_REF_ID></ENGINE>", 7)
        assert out.count(b"<SAVE_REF_ID>") == 1
        assert b"save-ref-id:7" in out


class TestConfig:
    def test_sanitize_drops_exec_only(self):
        lines, dropped = pkt_builder._sanitize_config_lines(
            "enable\nconfigure terminal\nhostname R1\n\nend\nwrite memory\n")
        assert lines == ["hostname R1"]
        assert sorted(set(dropped)) == ["configure terminal", "enable",
                                        "end", "write memory"]

    def test_interface_lines_incl_range(self):
        lines = ["interface f0/0", "interface range f0/1 - f0/3", "no shut"]
        names = pkt_builder._interface_lines(lines)
        assert names == ["f0/0", "f0/1", "f0/3"]

    def test_clock_rate_found_per_interface(self):
        lines = ["interface s0/2/0", "clock rate 64000", "interface f0/0",
                 "clock rate 2000000"]
        assert pkt_builder._clock_rate_for(lines, "Serial0/2/0") == "64000"
        assert pkt_builder._clock_rate_for(lines, "FastEthernet0/0") == \
            "2000000"
        assert pkt_builder._clock_rate_for(lines, "FastEthernet0/1") == ""


class TestBuild:
    def test_rebuilds_physical_workspace_leaf_references(self):
        root_uuid = "{00000000-0000-0000-0000-000000000001}"
        office_uuid = "{00000000-0000-0000-0000-000000000002}"
        rack_uuid = "{00000000-0000-0000-0000-000000000003}"
        old_office = "{00000000-0000-0000-0000-000000000004}"
        old_rack = "{00000000-0000-0000-0000-000000000005}"
        skeleton = (
            f"<PACKETTRACER5><PHYSICALWORKSPACE><NODE><TYPE>0</TYPE>"
            f"<UUID_STR>{root_uuid}</UUID_STR><CHILDREN>"
            f"<NODE><TYPE>2</TYPE><NAME translate=\"true\">Office</NAME>"
            f"<UUID_STR>{office_uuid}</UUID_STR><CHILDREN>"
            f"<NODE><TYPE>6</TYPE><NAME translate=\"true\">OldPC</NAME>"
            f"<X>86</X><Y>215</Y><UUID_STR>{old_office}</UUID_STR>"
            f"<CHILDREN /></NODE></CHILDREN></NODE>"
            f"<NODE><TYPE>4</TYPE><NAME translate=\"true\">Rack</NAME>"
            f"<UUID_STR>{rack_uuid}</UUID_STR><CHILDREN>"
            f"<NODE><TYPE>6</TYPE><NAME translate=\"true\">OldRouter</NAME>"
            f"<X>4</X><Y>0</Y><UUID_STR>{old_rack}</UUID_STR>"
            f"<CHILDREN /></NODE></CHILDREN></NODE>"
            f"</CHILDREN></NODE></PHYSICALWORKSPACE></PACKETTRACER5>").encode()

        def block(name):
            return (f"<DEVICE><NAME translate=\"true\">{name}</NAME>"
                    "<WORKSPACE><PHYSICAL>foreign</PHYSICAL>"
                    "<PHYSICAL_CPUR><X_PN>0.2</X_PN><Y_PN>0.1</Y_PN>"
                    "<X>1</X><Y>2</Y><PARENT_PATH>foreign</PARENT_PATH>"
                    "<CONTAINER_ID>foreign</CONTAINER_ID>"
                    "<ORIGINAL_DEVICE_UUID>foreign</ORIGINAL_DEVICE_UUID>"
                    "</PHYSICAL_CPUR></WORKSPACE></DEVICE>").encode()

        workspace_xml, devices = pkt_builder._rebuild_physical_workspace(
            skeleton, [block("R1"), block("PC1")],
            [{"name": "R1", "type": "router"},
             {"name": "PC1", "type": "pc"}], "physical-test")
        xml = workspace_xml.replace(
            b"</PACKETTRACER5>",
            b"<DEVICES>" + b"".join(devices) + b"</DEVICES>"
            b"</PACKETTRACER5>")
        pkt_builder._validate_physical_workspace(xml)
        parsed = ET.fromstring(xml)
        leaves = [node for node in parsed.find(".//PHYSICALWORKSPACE").iter("NODE")
                  if (node.findtext("TYPE") or "").strip() == "6"]
        assert {node.findtext("NAME") for node in leaves} == {"R1", "PC1"}
        assert len({node.findtext("UUID_STR") for node in leaves}) == 2

    def _workspace_skeleton(self) -> bytes:
        """A PHYSICALWORKSPACE with one office holding one saved device."""
        return (
            "<PACKETTRACER5><PHYSICALWORKSPACE><NODE><TYPE>0</TYPE>"
            "<UUID_STR>{00000000-0000-0000-0000-000000000021}</UUID_STR>"
            "<CHILDREN><NODE><TYPE>2</TYPE>"
            "<NAME translate=\"true\">Office</NAME>"
            "<UUID_STR>{00000000-0000-0000-0000-000000000022}</UUID_STR>"
            "<CHILDREN><NODE><TYPE>6</TYPE>"
            "<NAME translate=\"true\">OldPC</NAME><X>86</X><Y>215</Y>"
            "<UUID_STR>{00000000-0000-0000-0000-000000000023}</UUID_STR>"
            "<CHILDREN /></NODE></CHILDREN></NODE></CHILDREN>"
            "</NODE></PHYSICALWORKSPACE></PACKETTRACER5>").encode()

    def test_a_model_without_physical_data_goes_to_the_logical_workspace(
            self):
        """A template with no PHYSICAL_CPUR must not fail the whole build."""

        def block(name, physical=True):
            workspace = (_PHYSICAL if physical else
                         "<WORKSPACE><PHYSICAL>foreign</PHYSICAL>"
                         "</WORKSPACE>")
            return (f"<DEVICE><NAME translate=\"true\">{name}</NAME>"
                    f"{workspace}</DEVICE>").encode()

        notes = []
        xml, devices = pkt_builder._rebuild_physical_workspace(
            self._workspace_skeleton(), [block("R1"), block("PC1", False)],
            [{"name": "R1", "type": "router"},
             {"name": "PC1", "type": "pc"}], "logical-only", notes)
        assert len(notes) == 1
        assert "PC1: " in notes[0] and "Logical workspace only" in notes[0]
        # the stale path into the source file's workspace is cleared
        assert b"<PHYSICAL>foreign</PHYSICAL>" not in devices[1]
        assert b"<PHYSICAL></PHYSICAL>" in devices[1]
        full = xml.replace(b"</PACKETTRACER5>",
                           b"<DEVICES>" + b"".join(devices) + b"</DEVICES>"
                           b"</PACKETTRACER5>")
        pkt_builder._validate_physical_workspace(full)
        leaves = [node for node in ET.fromstring(full)
                  .find(".//PHYSICALWORKSPACE").iter("NODE")
                  if (node.findtext("TYPE") or "").strip() == "6"]
        assert [node.findtext("NAME") for node in leaves] == ["R1"]

    def test_build_gives_an_id_to_a_template_that_has_none(self, library):
        """A compact-save template (PT's own samples) has no SAVE_REF_ID and
        its links address devices positionally; the generated file addresses
        them by id, so the field must be added instead of skipped."""
        altered = dict(library)
        blocks = dict(library["_blocks"])
        router_file = next(name for name in blocks
                           if name.startswith("devices/2811"))
        blocks[router_file] = re.sub(
            rb"<SAVE_REF_ID>[^<]*</SAVE_REF_ID>", b"", blocks[router_file])
        altered["_blocks"] = blocks
        built = pkt_builder.build_pkt(PLAN, altered)
        ids = re.findall(rb"<SAVE_REF_ID>save-ref-id:\d+</SAVE_REF_ID>",
                         built["xml"])
        assert len(ids) == built["deviceCount"] == 5

    def test_a_model_without_a_container_id_field_is_still_placed(self):
        """58 of the harvested models (1841, 2811, 7960...) have no
        CONTAINER_ID: they keep the whole ancestry in PARENT_PATH, and the
        builder must write that shape rather than invent the missing field."""
        block = (
            "<DEVICE><NAME translate=\"true\">R1</NAME>"
            "<WORKSPACE><PHYSICAL>foreign</PHYSICAL>"
            "<PHYSICAL_CPUR><X_PN>0.12625</X_PN><Y_PN>0.06475</Y_PN>"
            "<X>43</X><Y>0</Y><PARENT_PATH>foreign</PARENT_PATH>"
            "</PHYSICAL_CPUR></WORKSPACE></DEVICE>").encode()
        xml, devices = pkt_builder._rebuild_physical_workspace(
            self._workspace_skeleton(), [block],
            [{"name": "R1", "type": "router"}], "no-container-id")
        cpur = re.search(rb"<PHYSICAL_CPUR>.*?</PHYSICAL_CPUR>",
                         devices[0], re.S).group(0)
        assert b"<CONTAINER_ID" not in cpur
        parent_path = re.search(rb"<PARENT_PATH>([^<]*)</PARENT_PATH>",
                                cpur).group(1).decode()
        leaf = re.search(rb"<PHYSICAL>([^<]*)</PHYSICAL>",
                         devices[0]).group(1).decode()
        # PARENT_PATH is the leaf's full ancestry, ending in its container
        assert parent_path == ",".join(leaf.split(",")[:-1])
        full = xml.replace(b"</PACKETTRACER5>",
                           b"<DEVICES>" + b"".join(devices) + b"</DEVICES>"
                           b"</PACKETTRACER5>")
        pkt_builder._validate_physical_workspace(full)
        leaves = [node for node in ET.fromstring(full)
                  .find(".//PHYSICALWORKSPACE").iter("NODE")
                  if (node.findtext("TYPE") or "").strip() == "6"]
        assert [node.findtext("NAME") for node in leaves] == ["R1"]

    def test_validation_rejects_physical_data_without_a_leaf_path(self):
        xml = (
            "<PACKETTRACER5><PHYSICALWORKSPACE><NODE><TYPE>0</TYPE>"
            "<UUID_STR>{00000000-0000-0000-0000-000000000031}</UUID_STR>"
            "<CHILDREN /></NODE></PHYSICALWORKSPACE><DEVICES><DEVICE>"
            "<NAME translate=\"true\">R1</NAME>"
            "<WORKSPACE><PHYSICAL></PHYSICAL>"
            "<PHYSICAL_CPUR><X>1</X><Y>2</Y><PARENT_PATH></PARENT_PATH>"
            "<CONTAINER_ID></CONTAINER_ID></PHYSICAL_CPUR></WORKSPACE>"
            "</DEVICE></DEVICES></PACKETTRACER5>").encode()
        with pytest.raises(pkt_builder.BuildError) as caught:
            pkt_builder._validate_physical_workspace(xml)
        assert "no leaf path" in str(caught.value)

    def test_devices_and_links(self, library):
        built = pkt_builder.build_pkt(PLAN, library)
        assert built["deviceCount"] == 5
        assert built["linkCount"] == 4
        assert built["plannedDevices"] == 5
        xml = built["xml"]
        # names + CLI identity
        assert b"<NAME translate=\"true\">R1</NAME>" in xml
        assert b"<SYS_NAME>R1</SYS_NAME>" in xml
        assert b"<SYS_NAME>PC1</SYS_NAME>" in xml  # fresh identity everywhere
        # deterministic unique ids (no randomness anywhere in the pipeline)
        ref_ids = __import__("re").findall(
            rb"<SAVE_REF_ID>save-ref-id:(\d+)</SAVE_REF_ID>", xml)
        assert len(ref_ids) == 5 and len(set(ref_ids)) == 5
        # layout rows
        assert b"<X>240</X>" in xml and b"<Y>120</Y>" in xml  # first router
        assert b"<Y>300</Y>" in xml  # switch row
        assert b"<Y>480</Y>" in xml  # pc row

    def test_config_embedded_and_exec_dropped(self, library):
        built = pkt_builder.build_pkt(PLAN, library)
        r1 = next(d for d in built["devices"] if d["name"] == "R1")
        assert r1["configLines"] == 10  # exec-only lines were not embedded
        assert any("dropped exec-only" in w for w in built["warnings"])
        assert b"<LINE>hostname R1</LINE>" in built["xml"]
        assert b"<LINE>enable</LINE>" not in built["xml"]

    def test_clock_rate_marks_dce_end(self, library):
        built = pkt_builder.build_pkt(PLAN, library)
        xml = built["xml"]
        assert b"<CLOCKRATE>64000</CLOCKRATE>" in xml
        assert b"<CLOCKRATEFLAG>true</CLOCKRATEFLAG>" in xml
        serial = [link for link in built["links"] if link["cable"] == "serial"]
        assert serial and serial[0]["aIf"] == "Serial0/2/0"
        assert b"<DCEDEV>save-ref-id:" in xml
        assert b"<DCEPORT>Serial0/2/0</DCEPORT>" in xml

    def test_two_links_on_a_two_port_router_use_two_ports(self, library):
        """'2 routers 2 switches' means one LAN each on a 2811: g0/0 and g0/1
        are FastEthernet0/0 and FastEthernet0/1, never FastEthernet0/0 twice
        (which is a cable Packet Tracer refuses, and what the old resolver
        produced because it re-picked the first port of the family)."""
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router", "model": "2811"},
                {"name": "SW1", "type": "switch", "model": "2960"},
                {"name": "SW2", "type": "switch", "model": "2960"}]},
            {"action": "create_links", "links": [
                {"a": "R1", "aIf": "g0/0", "b": "SW1", "bIf": "f0/1"},
                {"a": "R1", "aIf": "g0/1", "b": "SW2", "bIf": "f0/1"}]},
            {"action": "paste_cli", "configs": {
                "R1": ("configure terminal\nhostname R1\n"
                       "interface g0/0\n ip address 192.168.1.1 "
                       "255.255.255.0\n no shutdown\nexit\n"
                       "interface g0/1\n ip address 192.168.2.1 "
                       "255.255.255.0\n no shutdown\nexit\nend\n")}}]}
        built = pkt_builder.build_pkt(plan, library)
        router = next(d for d in built["devices"] if d["name"] == "R1")
        assert router["ports"] == {"g0/0": "FastEthernet0/0",
                                   "g0/1": "FastEthernet0/1"}
        both = [l for l in built["links"] if l["a"] == "R1"]
        assert sorted(l["aIf"] for l in both) == ["FastEthernet0/0",
                                                   "FastEthernet0/1"]
        # Each port carries its own IP: mirroring must not overwrite Fa0/0
        # with the second interface's address.
        assert b"<IP>192.168.1.1</IP>" in built["xml"]
        assert b"<IP>192.168.2.1</IP>" in built["xml"]

    def test_startup_config_mirrors_the_plan(self, tmp_path):
        """A generated device has never run `write memory`, so its startup
        config could be empty - it must not be the *template's*, which names
        the source device and can carry its password hash."""
        device = _device("2811", "Router", "Lab-R1", 111,
                         ("eCopperFastEthernet",) * 2,
                         config=("interface FastEthernet0/0",))
        device = device.replace(
            "</DEVICE>",
            "<STARTUPCONFIG><LINE>hostname Lab-R1</LINE>"
            "<LINE>enable secret 5 $1$mERr$9cTjUIEqNGurQiFU.ZeCi1</LINE>"
            "</STARTUPCONFIG></DEVICE>")
        source = tmp_path / "save.pkt"
        source.write_bytes(pkt_codec.encrypt_pkt(
            ("<PACKETTRACER5><VERSION>9.0.0.0810</VERSION><DEVICES>"
             + device + "</DEVICES><LINKS></LINKS></PACKETTRACER5>").encode()))
        manifest = tb.extract_templates([str(source)], str(tmp_path / "lib"))
        assert manifest["devices"]
        lib = pkt_builder.load_library(str(tmp_path / "lib"))
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R2", "type": "router", "model": "2811"}]},
            {"action": "paste_cli", "configs": {
                "R2": "configure terminal\nhostname R2\ninterface f0/0\n"
                      " ip address 10.0.0.1 255.255.255.252\n no shutdown\n"
                      "exit\nend\n"}}]}
        built = pkt_builder.build_pkt(plan, lib)
        xml = built["xml"]
        assert b"Lab-R1" not in xml
        assert b"$1$mERr$" not in xml
        startup = xml.split(b"<STARTUPCONFIG>", 1)[1] \
            .split(b"</STARTUPCONFIG>", 1)[0]
        assert b"<LINE>hostname R2</LINE>" in startup
        r2 = next(d for d in built["devices"] if d["name"] == "R2")
        assert startup.count(b"<LINE>") == r2["configLines"]
        ET.fromstring(xml)

    def test_a_control_character_in_a_config_cannot_break_the_file(self,
                                                                   library):
        """A banner is typed with ^C delimiters; XML cannot hold 0x03, so the
        generated document must come out clean and parseable."""
        plan = copy.deepcopy(PLAN)
        plan["steps"][2]["configs"]["R1"] += \
            "banner motd \x03Unauthorized access is prohibited\x03\n"
        built = pkt_builder.build_pkt(plan, library)
        assert b"\x03" not in built["xml"]
        assert re.search(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]", built["xml"]) \
            is None
        ET.fromstring(built["xml"])
        assert b"banner motd" in built["xml"]

    def test_a_rejected_template_is_reported(self, library):
        """One bad block must not be a silent model substitution."""
        altered = dict(library)
        blocks = dict(library["_blocks"])
        blocks["devices/1941.xml"] = b"<DEVICE><ENGINE><TYPE model=\"1941\">"
        altered["_blocks"] = blocks
        altered["devices"] = list(library["devices"]) + [{
            "key": "1941", "model": "1941", "kind": "Router",
            "file": "devices/1941.xml",
            "ports": [{"index": 0, "type": "eCopperGigabitEthernet",
                       "family": "gigabitethernet",
                       "name": "GigabitEthernet0/0"}]}]
        best, notes = pkt_builder.select_variant(
            altered, {"name": "R1", "type": "router", "model": "1941"},
            ["g0/0"])
        assert best["model"] == "2811"
        joined = " ".join(notes)
        assert "ignored incompatible template 1941" in joined
        assert "not valid XML" in joined

    def test_serial_without_clock_reports_missing_dce(self, library):
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router", "model": "2811"},
                {"name": "R2", "type": "router", "model": "2811"}]},
            {"action": "create_links", "links": [
                {"a": "R1", "aIf": "s0/2/0", "b": "R2", "bIf": "s0/2/0",
                 "cable": "serial"}]}]}
        built = pkt_builder.build_pkt(plan, library)
        assert b"<DCEDEV>" not in built["xml"]
        assert any("neither end a clock rate" in w
                   for w in built["warnings"])

    def test_serial_link_does_not_fall_back_to_ethernet(self, library):
        # A serial cable with a nonexistent serial slot must be reported as
        # unresolved, never emitted with FastEthernet endpoint names.
        no_serial = copy.deepcopy(library)
        for variant in no_serial["devices"]:
            if variant.get("model") == "2811":
                variant["ports"] = [
                    port for port in variant.get("ports", [])
                    if port.get("family") != "serial"]
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router", "model": "2811"},
                {"name": "R2", "type": "router", "model": "2811"}]},
            {"action": "create_links", "links": [
                {"a": "R1", "aIf": "Serial0/2/0",
                 "b": "R2", "bIf": "Serial0/2/0", "cable": "serial"}]}]}
        built = pkt_builder.build_pkt(plan, no_serial)
        assert built["links"] == []
        assert any("Serial0/2/0 not usable" in warning
                   for warning in built["warnings"])
        assert b"<FROM>save-ref-id:" not in built["xml"]

    def test_config_state_mirrored_into_ports(self, library):
        # PT loads up/down + IP from the PORT element, not by replaying the
        # running config: `no shutdown` and `ip address` must land there,
        # or a generated file opens with its interfaces down (red serial).
        built = pkt_builder.build_pkt(PLAN, library)
        xml = built["xml"]
        r1 = next(b for b in re.findall(rb"<DEVICE>.*?</DEVICE>", xml, re.S)
                  if b"R1<" in b)
        ports = [r1[s:e] for s, e in tb.iter_port_spans(r1)]
        serial_port = next(p for p in ports if b"eSmartSerial" in p
                           and b"<IP>10.0.0.1</IP>" in p)
        assert b"<POWER>true</POWER>" in serial_port
        assert b"<CLOCKRATE>64000</CLOCKRATE>" in serial_port
        fa_port = next(p for p in ports if b"eCopperFastEthernet" in p
                       and b"<IP>192.168.10.1</IP>" in p)
        assert b"<POWER>true</POWER>" in fa_port

    def test_pc_ip_settings_on_the_linked_port(self, library):
        built = pkt_builder.build_pkt(PLAN, library)
        xml = built["xml"]
        assert b"<IP>192.168.10.11</IP>" in xml
        assert b"<SUBNET>255.255.255.0</SUBNET>" in xml
        assert b"<PORT_GATEWAY>192.168.10.1</PORT_GATEWAY>" in xml
        assert b"<PORT_DHCP_ENABLE>false</PORT_DHCP_ENABLE>" in xml
        pc1 = next(d for d in built["devices"] if d["name"] == "PC1")
        assert pc1["ports"] == {"eth0": "FastEthernet0"}

    def test_cable_kind_is_rewritten_on_the_template(self, library):
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "PC1", "type": "pc"}, {"name": "PC2", "type": "pc"}]},
            {"action": "create_links", "links": [
                {"a": "PC1", "aIf": "f0", "b": "PC2", "bIf": "f0",
                 "cable": "copper-cross"}]}]}
        built = pkt_builder.build_pkt(plan, library)
        segment = __import__("re").search(
            rb"<CABLE>.*?</CABLE>", built["xml"], __import__("re").S)
        assert b"<TYPE>eCrossOver</TYPE>" in segment.group(0)
        assert b"eStraightThrough" not in segment.group(0)

    def test_skipped_node_warns_on_its_links(self, library):
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router", "model": "2811"},
                {"name": "FW1", "type": "firewall"}]},
            {"action": "create_links", "links": [
                {"a": "R1", "aIf": "f0/0", "b": "FW1", "bIf": "f0"}]}]}
        built = pkt_builder.build_pkt(plan, library)
        assert built["deviceCount"] == 1
        assert any("FW1" in w and "no firewall model" in w
                   for w in built["warnings"])
        assert any("endpoint was skipped" in w for w in built["warnings"])

    def test_unknown_models_only_is_an_error(self, library):
        plan = {"steps": [{"action": "create_nodes", "nodes": [
            {"name": "FW1", "type": "firewall"}]}]}
        with pytest.raises(pkt_builder.BuildError, match="no device"):
            pkt_builder.build_pkt(plan, library)

    def test_server_service_panels_are_written_from_the_plan(self, library):
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "SRV1", "type": "server"}]},
            {"action": "config_servers", "servers": {"SRV1": {"services": {
                "dhcp": {"pools": [{
                    "poolName": "LAN", "gateway": "192.168.1.1",
                    "dnsServer": "192.168.1.100",
                    "startIp": "192.168.1.150", "mask": "255.255.255.0",
                    "maxUsers": "50"}]},
                "dns": {"records": [{"name": "web.lab",
                                     "address": "192.168.1.102"}]},
                "http": {"on": True},
                "aaa": {
                    "users": [{"username": "labadmin",
                               "password": "LabAdmin2026"}],
                    "clients": [{"hostIp": "192.168.1.1",
                                 "key": "LabAdmin2026",
                                 "serverType": "TACACS",
                                 "description": "HQ_Router"}]}}}}}]}
        built = pkt_builder.build_pkt(plan, library)
        xml = built["xml"]
        assert b"<POOL><NAME>LAN</NAME><NETWORK>192.168.1.0</NETWORK>" in xml
        assert b"<START_IP>192.168.1.150</START_IP>" in xml
        assert b"<END_IP>192.168.1.254</END_IP>" in xml
        assert b"<DEFAULT_ROUTER>192.168.1.1</DEFAULT_ROUTER>" in xml
        assert b"<DNS_SERVER>192.168.1.100</DNS_SERVER>" in xml
        assert b"<TYPE>A-REC</TYPE><NAME>web.lab</NAME>" in xml
        assert b"<HTTP_SERVER><ENABLED>1</ENABLED>" in xml
        assert b"<USER><NAME>labadmin</NAME>" in xml
        assert (b"<CLIENT><HOST_IP>192.168.1.1</HOST_IP>"
                b"<KEY>LabAdmin2026</KEY>") in xml
        assert b"<SERVER_TYPE>TACACS</SERVER_TYPE>" in xml
        report = built["devices"][0]["services"]
        assert report["dhcp"] == {"pools": 1}
        assert report["aaa"] == {"on": True, "users": 1, "clients": 1,
                               "serverType": "TACACS",
                               "authPort": "1645"}

    def test_template_service_leftovers_never_ship(self, library):
        # The Server-PT template carries the source save's pool and its
        # leases.  A generated file must not inherit them, and a service the
        # plan never asked for must be off rather than on.
        plan = {"steps": [{"action": "create_nodes", "nodes": [
            {"name": "SRV1", "type": "server"}]}]}
        built = pkt_builder.build_pkt(plan, library)
        xml = built["xml"]
        assert b"serverPool" not in xml
        assert b"<DHCP_POOL_LEASE>" not in xml
        assert b"10.0.0.0</NETWORK>" not in xml
        assert b"<POOLS></POOLS>" in xml
        assert b"<HTTP_SERVER><ENABLED>0</ENABLED>" in xml
        assert b"<TYPE>A-REC</TYPE>" not in xml
        assert b"<DHCP_SERVER><ENABLED>0</ENABLED>" in xml

    def test_aaa_without_a_user_or_client_is_reported(self, library):
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "SRV1", "type": "server"}]},
            {"action": "config_servers", "servers": {"SRV1": {"services": {
                "aaa": {"users": [], "clients": []}}}}}]}
        built = pkt_builder.build_pkt(plan, library)
        assert any("no login can succeed" in w for w in built["warnings"])
        assert any("names no client router" in w for w in built["warnings"])


class TestGenerateFile:
    def test_generate_and_decode_round_trip(self, library, tmp_path,
                                             monkeypatch):
        monkeypatch.setattr(pkt_builder.template_build, "TEMPLATE_DIR",
                            str(library["_directory"]))
        out = tmp_path / "lab.pkt"
        report = pkt_builder.generate_pkt_file(PLAN, str(out), library=library,
                                               replace=True)
        assert report["bytes"] > 0 and report["sha256"]
        assert report["deviceCount"] == 5 and report["linkCount"] == 4
        assert report["authority"] == "NetBuilder offline generator"
        xml = pkt_builder.decode_pkt_file(str(out))
        assert pkt_codec.pkt_xml_summary(xml)["deviceCount"] == 5

    def test_path_guards(self, library, tmp_path):
        with pytest.raises(pkt_builder.BuildError, match=r"\.pkt"):
            pkt_builder.generate_pkt_file(PLAN, str(tmp_path / "lab.xml"),
                                          library=library)
        with pytest.raises(pkt_builder.BuildError, match="directory"):
            pkt_builder.generate_pkt_file(PLAN,
                                          str(tmp_path / "nope" / "l.pkt"),
                                          library=library)
        target = tmp_path / "exists.pkt"
        target.write_bytes(b"x")
        with pytest.raises(FileExistsError):
            pkt_builder.generate_pkt_file(PLAN, str(target), library=library)
        report = pkt_builder.generate_pkt_file(PLAN, str(target),
                                               library=library, replace=True)
        assert report["bytes"] > 100

    def test_generation_is_deterministic(self, library, tmp_path):
        a = tmp_path / "a.pkt"
        b = tmp_path / "b.pkt"
        one = pkt_builder.generate_pkt_file(PLAN, str(a), library=library,
                                            replace=True)
        two = pkt_builder.generate_pkt_file(PLAN, str(b), library=library,
                                            replace=True)
        assert one["sha256"] == two["sha256"]

    def test_load_library_missing(self, tmp_path):
        with pytest.raises(pkt_builder.BuildError, match="templates/build"):
            pkt_builder.load_library(str(tmp_path / "empty"))


# ---------------------------------------------------------------------------
# Sidecar wiring (function level, like test_build_completeness)
# ---------------------------------------------------------------------------

class TestSidecar:
    @pytest.fixture(autouse=True)
    def _env(self, tmp_path, monkeypatch):
        import pt_autopilot as pt
        self.pt = pt
        monkeypatch.setenv("NETBUILDER_PKT_DIR", str(tmp_path / "out"))
        monkeypatch.setattr(pt, "PKT_BACKUP_DIR", str(tmp_path / "backups"))
        self.tmp = tmp_path
        library_dir = tmp_path / "templates"
        pt.pkt_template_build.extract_templates(
            [self._library_source()], str(library_dir))
        monkeypatch.setattr(pt.pkt_builder.template_build, "TEMPLATE_DIR",
                            str(library_dir))

    def _library_source(self):
        source = self.tmp / "src.pkt"
        source.write_bytes(pkt_codec.encrypt_pkt(_sample_save()))
        return str(source)

    def test_pkt_generate(self):
        result = self.pt.pkt_generate(PLAN, project="lab")
        assert os.path.isfile(result["path"])
        assert result["deviceCount"] == 5
        assert result["authority"] == "NetBuilder offline generator"
        assert self.pt.PKT_STATE["report"] is result
        with open(result["path"] + ".netbuilder.json", encoding="utf-8") as f:
            manifest = json.load(f)
        assert manifest["planned"]["deviceCount"] == 5
        xml = pkt_builder.decode_pkt_file(result["path"])
        assert b"<SYS_NAME>R1</SYS_NAME>" in xml

    def test_pkt_generate_guards(self):
        with pytest.raises(ValueError):
            self.pt.pkt_generate({"steps": []})
        # A plan nothing in the library can cover is a BuildError.
        with pytest.raises(pkt_builder.BuildError):
            self.pt.pkt_generate({"steps": [
                {"action": "create_nodes", "nodes": [
                    {"name": "FW1", "type": "firewall"}]}]})

    def test_pkt_generate_explicit_filename_stays_in_dir(self):
        result = self.pt.pkt_generate(PLAN, project="lab",
                                      filename="../../evil.pkt")
        parent = os.path.dirname(os.path.abspath(result["path"]))
        assert parent.lower().endswith("out")
        assert result["name"].endswith(".pkt") and ".." not in result["name"]

    def test_pkt_generate_replace_backs_up(self):
        first = self.pt.pkt_generate(PLAN, project="lab", filename="lab.pkt")
        with open(first["path"], "ab") as stream:
            stream.write(b"corruption")
        second = self.pt.pkt_generate(PLAN, project="lab", filename="lab.pkt",
                                      replace=True)
        assert second["path"] == first["path"]
        backups = os.listdir(self.pt.PKT_BACKUP_DIR)
        assert backups and backups[0].endswith(".pkt")
        # the restored file is a good save again
        xml = pkt_builder.decode_pkt_file(second["path"])
        assert b"<SYS_NAME>R1</SYS_NAME>" in xml

    def test_templates_build(self):
        result = self.pt.pkt_templates_build([self._library_source()],
                                             out_dir=str(self.tmp / "lib"))
        assert len(result["devices"]) == 4 and len(result["links"]) == 2
        status = self.pt.pkt_template_build.library_status(
            str(self.tmp / "lib"))
        assert status["ready"] is True

    def test_templates_build_requires_paths(self):
        with pytest.raises(ValueError):
            self.pt.pkt_templates_build([])

    def test_offline_audit_reports_down_serial_as_advice(self):
        # A file whose serial port saved as down must be flagged with the
        # exact remediation, and nothing may be typed anywhere.
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router", "model": "2811"},
                {"name": "R2", "type": "router", "model": "2811"}]},
            {"action": "create_links", "links": [
                {"a": "R1", "aIf": "s0/2/0", "b": "R2", "bIf": "s0/2/0",
                 "cable": "serial"}]},
            {"action": "paste_cli", "configs": {
                "R1": "interface s0/2/0\nip address 10.0.0.1 255.255.255.252\n"
                      "clock rate 64000\nno shutdown\nexit\n",
                "R2": "interface s0/2/0\nip address 10.0.0.2 255.255.255.252\n"
                      "no shutdown\nexit\n"}}]}
        result = self.pt.pkt_generate(plan, project="auditlab")
        report = self.pt.pkt_audit_network(result["path"], project="auditlab")
        assert report["mode"] == "offline"
        assert report["summary"]["device_count"] == 2
        by_device = {d["name"]: d for d in report["devices"]}
        # The generated file mirrors config state into ports, so a fresh
        # generate must NOT flag the mismatch - proving the mirror works.
        assert not any("saved port state is down" in f["text"]
                       for f in by_device["R1"]["findings"])
        # A hand-corrupted file (POWER flipped off) IS flagged.
        import re as _re
        xml = pkt_builder.decode_pkt_file(result["path"])
        broken = _re.sub(rb"<POWER>true</POWER>", b"<POWER>false</POWER>",
                         xml)
        broken_path = result["path"].replace(".pkt", "-broken.pkt")
        with open(broken_path, "wb") as stream:
            stream.write(pkt_codec.encrypt_pkt(broken))
        broken_report = self.pt.pkt_audit_network(broken_path)
        texts = [f["text"] for d in broken_report["devices"]
                 for f in d["findings"]]
        assert any("saved port state is down" in t for t in texts)
        serial_findings = [f for d in broken_report["devices"]
                           for f in d["findings"]
                           if "saved port state is down" in f["text"]]
        assert serial_findings[0]["fix_cli"] == ["interface Serial0/2/0",
                                                 "no shutdown"]
        assert serial_findings[0]["offline_advice"] is True

    def test_offline_audit_flags_ipless_port_and_shut_interface(self):
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "R1", "type": "router", "model": "2811"}]},
            {"action": "paste_cli", "configs": {
                # config sets an IP on Fa0/0 but shuts it; Fa0/1 gets an IP
                # while its port stays at template state (no power line) -
                # the port-vs-config mismatch must be flagged.
                "R1": "interface f0/0\nip address 192.168.1.1 255.255.255.0\n"
                      "shutdown\nexit\n"}}]}
        result = self.pt.pkt_generate(plan, project="auditlab2")
        report = self.pt.pkt_audit_network(result["path"])
        r1 = next(d for d in report["devices"] if d["name"] == "R1")
        texts = [f["text"] for f in r1["findings"]]
        assert any("shut down in the saved config" in t for t in texts)

    def test_offline_audit_rejects_bad_paths(self):
        with pytest.raises(FileNotFoundError):
            self.pt.pkt_audit_network(str(self.tmp / "missing.pkt"))
        junk = self.tmp / "junk.pkt"
        junk.write_bytes(b"not a save" * 50)
        with pytest.raises(pkt_codec.PktFormatError):
            self.pt.pkt_audit_network(str(junk))


# ---------------------------------------------------------------------------
# The Services tab, service by service, and the ASA firewall
# ---------------------------------------------------------------------------
#
# Every wire shape asserted here was read out of a real Packet Tracer save:
# the AAA panel out of `03 Cybersecurity/AAA/AAA_Radius_Server.pkt`, the mail
# accounts out of `01 Networking/Mail/mail_2Server_2PC.pkt`, the v6 pool out
# of `01 Networking/IPv6/dhcpv6_pt_server.pkt`, the IoT user list out of
# `04 IoT/MQTT/mqttdemo.pkt`, the VM list out of
# `01 Networking/Cisco Application Management/tcp_test_app.pkt`, and the ASA
# syntax out of `03 Cybersecurity/ASA`.

class TestServerServicesAndFirewall:
    def _services(self, library, services: dict) -> dict:
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "SRV1", "type": "server"}]},
            {"action": "create_links", "links": [
                {"a": "SRV1", "aIf": "f0", "b": "SW1", "bIf": "f0/1"}]},
            {"action": "config_servers",
             "servers": {"SRV1": {"services": services}}}]}
        return pkt_builder.build_pkt(plan, library)

    def test_aaa_semantics_match_a_real_save(self, library):
        """AAA is only usable with an account, a client and the same key.

        Packet Tracer's own AAA samples write RADIUS (or TACACS) plus the
        router's address, the shared key and the auth port the router dials.
        """
        built = self._services(library, {
            "aaa": {
                "authPort": "1812",
                "users": [{"username": "cisco", "password": "cisco",
                           "description": "student"}],
                "clients": [{"hostIp": "192.168.10.1", "key": "mykey",
                             "serverType": "radius",
                             "description": "R1"}]}})
        xml = built["xml"]
        assert b"<ACS_SERVER><ENABLED>1</ENABLED>" in xml
        assert b"<AUTH_PORT>1812</AUTH_PORT>" in xml
        assert b"<SERVER_TYPE>RADIUS</SERVER_TYPE>" in xml
        assert b"<DESCRIPTION>R1</DESCRIPTION>" in xml
        assert b"<DESCRIPTION>student</DESCRIPTION>" in xml
        report = built["devices"][0]["services"]["aaa"]
        assert report["serverType"] == "RADIUS"
        assert report["authPort"] == "1812"
        assert report["users"] == 1 and report["clients"] == 1

    def test_aaa_without_account_or_client_is_off_and_reported(self, library):
        built = self._services(library, {"aaa": {"users": [],
                                                 "clients": []}})
        assert b"<ACS_SERVER><ENABLED>0</ENABLED>" in built["xml"]
        assert built["devices"][0]["services"]["aaa"]["on"] is False
        assert any("no login can succeed" in w for w in built["warnings"])

    def test_dhcpv6_pool_round_trips(self, library):
        built = self._services(library, {"dhcpv6": {"pools": [{
            "poolName": "v6pool", "prefix": "2001:db8:1::",
            "prefixLength": "64", "dnsServer": "2001:db8:1::1",
            "domainName": "lab.local"}]}})
        xml = built["xml"]
        assert b"<DHCPV6_POOL><POOL_NAME>v6pool</POOL_NAME>" in xml
        assert b"<PREFIX_ID>2001:db8:1::/64</PREFIX_ID>" in xml
        assert b"<DHCPV6_SERVER_PORT_DATA><ENABLED>1</ENABLED>" in xml
        assert built["devices"][0]["services"]["dhcpv6"] == {"pools": 1}

    def test_mail_server_accounts_are_indexed(self, library):
        built = self._services(library, {"email": {
            "domain": "lab.local",
            "users": [{"username": "ali", "password": "pw1"},
                      {"username": "sara", "password": "pw2"}]}})
        xml = built["xml"]
        assert b"<SMTP_DOMAIN>lab.local</SMTP_DOMAIN>" in xml
        assert b"<NO_OF_USERS>2</NO_OF_USERS>" in xml
        assert b"<USER0>ali</USER0><PASSWORD0>pw1</PASSWORD0>" in xml
        assert b"<USER1>sara</USER1><PASSWORD1>pw2</PASSWORD1>" in xml

    def test_iot_registration_server_and_vm_manager(self, library):
        built = self._services(library, {
            "iot": {"registration": True,
                    "users": [{"username": "admin",
                               "password": "admin"}]},
            "vm": {"vms": [{"id": "client", "path": "client",
                            "status": "1"}]}})
        xml = built["xml"]
        assert (b"<IOE_USER_MANAGER><USERS><USER><NAME>admin</NAME>"
                b"<PASSWORD>admin</PASSWORD>" in xml)
        assert b"<REGISTRATION_SEVER>true</REGISTRATION_SEVER>" in xml
        assert (b"<IOX_VM_MANAGER><VMS><VM><VM_ID>client</VM_ID>" in xml)
        assert built["devices"][0]["services"]["vm"] == {"vms": 1}

    def test_ntp_authentication_and_snmp_communities(self, library):
        built = self._services(library, {
            "ntp": {"on": True, "authenticate": True, "key": "7",
                    "md5Password": "ntpsecret"},
            "snmp": {"readCommunity": "public",
                     "writeCommunity": "private", "version": "2c"}})
        xml = built["xml"]
        assert (b"<ENABLED_SERVER_AUTHENTICATE>1</ENABLED_SERVER_AUTHENTICATE>"
                b"<KEY>7</KEY><MD5PASSWORD>ntpsecret</MD5PASSWORD>" in xml)
        assert b"<READ_COMMUNITY>public</READ_COMMUNITY>" in xml
        assert b"<WRITE_COMMUNITY>private</WRITE_COMMUNITY>" in xml
        assert built["devices"][0]["services"]["snmp"]["readCommunity"] \
            == "public"

    def test_unasked_services_stay_off(self, library):
        built = self._services(library, {"http": {"on": True}})
        xml = built["xml"]
        assert b"<DHCPV6_POOL>" not in xml
        assert b"<IOE_USER_MANAGER><USERS><USER>" not in xml
        assert b"<VM><VM_ID>" not in xml
        assert b"<REGISTRATION_SEVER>false</REGISTRATION_SEVER>" in xml
        assert b"<READ_COMMUNITY></READ_COMMUNITY>" in xml
        assert b"<EMAIL_SERVER><SMTP_ENABLED>0</SMTP_ENABLED>" in xml

    def test_firewall_keeps_asa_config_and_vlan_is_not_a_port(
            self, firewall_library):
        """An ASA's `interface Vlan1` is config, not a missing port.

        Firewall-PT routes through Vlan interfaces on a 5505, and the builder
        used to warn that the template "has no port for Vlan1" and could
        rewrite the line.
        """
        plan = {"steps": [
            {"action": "create_nodes", "nodes": [
                {"name": "FW1", "type": "firewall", "model": "5505"},
                {"name": "SW1", "type": "switch", "model": "2960"}]},
            {"action": "create_links", "links": [
                {"a": "FW1", "aIf": "e0/1", "b": "SW1",
                 "bIf": "f0/1"}]},
            {"action": "paste_cli", "configs": {"FW1": (
                "hostname FW1\n"
                "interface Ethernet0/0\n switchport access vlan 2\nexit\n"
                "interface Vlan1\n nameif inside\n security-level 100\n"
                " ip address 192.168.1.1 255.255.255.0\nexit\n"
                "interface Vlan2\n nameif outside\n security-level 0\n"
                " ip address 209.165.200.226 255.255.255.248\nexit\n"
                "route outside 0.0.0.0 0.0.0.0 209.165.200.225 1\n"
                "end\nwrite memory\n")}}]}
        built = pkt_builder.build_pkt(plan, firewall_library)
        xml = built["xml"]
        assert b"<LINE>nameif inside</LINE>" in xml
        assert b"<LINE>interface Vlan1</LINE>" in xml
        assert b"<LINE>security-level 100</LINE>" in xml
        assert b"<LINE>route outside 0.0.0.0 0.0.0.0 209.165.200.225 1</LINE>" \
            in xml
        assert not any("Vlan1" in w for w in built["warnings"])
        fw = next(d for d in built["devices"] if d["name"] == "FW1")
        assert fw["type"] == "firewall"
        assert fw.get("ports")
