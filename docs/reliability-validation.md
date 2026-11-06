# Reliability validation: export integrity, device counts and the harvested device library

Checkpoint before the reliability pass: commit `3fe6840` on
`origin/p3-product`. The reliability work is commit `2d210ba`; the device
library expansion in this report is the working-tree change that follows it.

## 1. Reliability fixes

### Silent device/link loss

`sidecar/pkt_builder.py` skipped any device with no template and still
reported a successful file. It now returns structured `missingDevices`,
`missingLinks`, `modelSubstitutions`, `interfaceRemappings`, plus a status:
`VALID`, `VALID_WITH_WARNINGS`, `EXPORT_INCOMPLETE`, or `INVALID`.
`generate_pkt_file` refuses an incomplete export by default
(`allow_incomplete=True` opts in), so the reported 50-planned/46-exported
result is now a precise error naming every missing device.

### Export verification

The exporter writes a temp file, decrypts it, checks device/link counts and
every device name against the report, and only then replaces the target. A
file that does not match is rejected and removed.

### Device-count interpretation

Connection phrases with a destination are distribution, not inventory:
"connect 5 PCs to Switch 1" does not alter the stated PC total.
"connect two routers over a serial WAN" remains an inventory request. The
exact reported 3 routers / 6 switches / 25 PCs / 8 laptops / 4 servers /
4 printers brief is pinned in `test/device_count_distribution_test.dart`.

### Preview

The built-in viewer says it draws the approved plan at the build's positions
and that an incomplete export can contain fewer devices. It has a
fit-to-screen control with a readable minimum zoom; pinch/pan and all 14
layouts are unchanged.

## 2. Device library expansion from `test.pkt`

The user supplied `test.pkt` (17 devices, no links). Thirteen device types
were already in the library. Harvesting it added four real Packet Tracer
device blocks:

| Model | Ports found | Use |
| --- | --- | --- |
| `Printer-PT` | `FastEthernet0` | Printer, cabled and addressed |
| `TV-PT` | coaxial port (unnamed) | Placed; no cable template |
| `WiredEndDevice-PT` | `FastEthernet0` | Wired generic endpoint |
| `WirelessEndDevice-PT` | wireless ports (unnamed) | Placed wirelessly |

The bundled library now has **122 device models and 10 link templates**.
`sidecar/pkt_templates/manifest.json` records the user save with its hash;
the original path is not committed. The generated catalog
(`assets/packet_tracer/catalog.json`, `catalog_data.dart`,
`pt_catalog_data.py`) was refreshed, so `Printer-PT` now has a real variant
instead of an empty one.

Cable audit: 298 saved `.pkt` files were scanned for link templates (18 were
unreadable). The only media present are `eCopper`, `eSerial`, `ePhoneLine`,
`eCoaxial`, `eOctal`, `eCustomIOLink`, `eUsb` and `eFiber`. None defines a
console, wireless-association or additional coaxial link template, so the
library keeps its 10 real templates and a request for an unavailable medium
still fails explicitly rather than being silently dropped.

### Newly usable device kinds

- `printer` - supported offline and in the Dart builder (real template).
- `tv` - supported offline (template was missing before).
- `meraki-server` - Meraki dashboard host; placed and cabled, no IOS config.
- `wired-end-device`, `wireless-end-device` - generic PT endpoints.
- `analog-phone`, `voip-adapter` - moved out of the unsupported list; real
  templates, offline build only.
- `mcu`, `sbc` - control and single-board computers; real templates, offline
  build only.
- `cell-tower`, `central-office` - telecom templates, offline build only.

Nine kinds are in `offlineOnlyDeviceKinds` / `OFFLINE_ONLY_DEVICE_KINDS`:
`meraki-server`, `wired-end-device`, `wireless-end-device`, `analog-phone`,
`voip-adapter`, `mcu`, `sbc`, `cell-tower` and `central-office`. They compile
into offline `.pkt` files, and a live Packet Tracer run reports `offline_only`
rather than substituting a different device.

Everyday names were added for NAS/network-attached storage, multifunction
printers, NGFW/UTM security appliances, ONT/broadband/fibre modems,
televisions, protocol analyzers/packet captures, PDUs/UPS units, desk phones,
wired/wireless clients and WiFi access points. Multi-word names survive the
number-word bridge: `single board computer` is read as an SBC, not as a PC.

## 3. Test execution (this machine, 2026-11-06)

```
cd sidecar && python -m pytest -q
# 632 passed in 151.56s

flutter test
# 2890 passed, 0 failed

flutter analyze <changed Dart files>
# No issues found!
```

New or changed coverage:

- `sidecar/test_export_integrity.py` - printer now builds and verifies on
  disk; a deliberately unknown device is still refused explicitly, including
  its dropped cable; 50-device plan with printers is complete.
- `sidecar/test_generation_scenarios.py` - all 20 scenarios; scenarios 15
  (printers) and 20 (complex 50 with printers) now complete.
- `sidecar/test_device_palette.py` - all offline-only kinds, including the
  nine current ones, compile from real templates.
- `test/device_vocabulary_coverage_test.dart` - each everyday equipment name
  produces exactly one node of its kind, and the four new template-backed
  kinds keep their real model names (`MCU-PT`, `SBC-PT`, `Cell-Tower`,
  `Central-Office-Server`).
- `test/harvested_device_kinds_test.dart` - the parser recognizes the new
  kinds; the bundled library contains `Printer-PT`; a router/switch/printer
  plan builds in the Dart compiler with 3 devices and 2 links.
- `test/chat_plan_repair_test.dart` - an oversized printer plan is no longer
  blocked for a missing template, only by its real size/link blockers.

### The 20 scenarios

| # | Scenario | Result |
| --- | --- | --- |
| 1 | 1 router, 1 switch, 5 PCs | PASS |
| 2 | 1 switch, 10 PCs | PASS |
| 3 | 2 switches connected | PASS |
| 4 | 2 routers, serial cable | PASS |
| 5 | 3 routers in a chain | PASS |
| 6 | Small office with DHCP | PASS (structural) |
| 7 | Small office with DNS server | PASS (structural) |
| 8 | AAA authentication | PASS (structural) |
| 9 | Two LANs with static routing | PASS (structural) |
| 10 | Three routers with static routes | PASS |
| 11 | Multiple switches with VLANs | PASS (structural) |
| 12 | Inter-VLAN routing | PASS |
| 13 | OSPF | PASS (structural) |
| 14 | Multiple servers | PASS |
| 15 | Printers | PASS - 6/6 devices, 5/5 links |
| 16 | Laptops | PASS |
| 17 | Wired + wireless | PARTIAL - no wireless link template; every device is built or named missing |
| 18 | 30 mixed devices | PASS |
| 19 | Exactly 50 devices | PASS - 50/50 devices, 47/47 links, disk read-back |
| 20 | Complex 50 with printers | PASS - 50/50 devices, 47/47 links |

## 4. Remaining limitations

1. **Packet Tracer runtime is not tested.** No DHCP lease, AAA login, OSPF
   adjacency or ping was executed. Tests prove plan, port assignment, config
   text and file contents only.
2. **Wireless association is not buildable.** There is no wireless `LINK`
   template. `WirelessEndDevice-PT` and the TV template have unnamed wireless
   or coaxial ports, so they are placed but cannot be cabled.
3. **Nine kinds are offline-only.** The live executor has no taught palette
   path for the Meraki server, either end device, the analog phone, the VoIP
   adapter, the MCU, the SBC, the cell tower or the central office; a live run
   reports `offline_only`.
4. **The viewer still draws the plan.** It now says so; verified file counts
   are in the export report.
5. **Configuration validation is structural.** `ValidatorService` keeps its
   IP/subnet/gateway checks; the scenarios assert generated commands, not
   device execution.
6. **The 50-device cap is a planner limit.** The Python compiler does not
   impose one; requests above 50 through the planner were not separately
   tested.

## 5. Manual Packet Tracer checks still required

1. Open a generated printer lab and confirm the printer has `FastEthernet0`,
   its cable is present, and its IP Configuration panel is filled.
2. Open the 50-device printer scenario and confirm 50 devices and 47 cables
   on the logical canvas.
3. Confirm DHCP leases (scenario 6), AAA login (scenario 8), OSPF/static
   routes (9/13), inter-VLAN pings (12), and serial link clocking (4).
4. Confirm the TV and wireless end device appear when placed, even though
   they cannot be cabled by the compiler.

## 6. Recommended next steps

1. Harvest more user saves for missing models (wireless AP link blocks, TV
   coaxial cable, generic end-device ports).
2. Teach live palette paths for the offline-only kinds, or keep reporting
   `offline_only` honestly.
3. Add a PT-runtime integration test for DHCP/AAA/ping, marked separately
   from structural tests.
4. Make the viewer consume the verified report (or parse the `.pkt`) so its
   badges are the file's counts.
5. Surface `status`, `missingDevices` and `verification` in the build card.
