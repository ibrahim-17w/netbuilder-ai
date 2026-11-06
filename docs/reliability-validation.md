# Reliability validation: export integrity and device counts

Checkpoint before this work: commit `3fe6840` on `origin/p3-product`
("Checkpoint the working tree before the reliability pass").

This pass fixed the reported silent-export and device-count failures. It did
not rebuild the planner, the 14 layouts, the configuration generators or the
`.pkt` codec.

## What was wrong

### 1. Unsupported devices were skipped while the export claimed success

`sidecar/pkt_builder.py` did this when no template matched a device:

```python
if variant is None:
    continue          # only a warning string was left behind
```

The printer was the visible case: the bundled template library has 118 device
models and **none of them is a printer**. Every `PRN*` node disappeared, and
its cable was dropped by the link builder (`endpoint was skipped`). The build
report still carried `deviceCount`/`linkCount`, and nothing compared them with
the plan. That is exactly the reported 50 planned / 46 exported and
49 planned / 45 exported result.

A real `Printer-PT` block does not exist in:

- the repository's `sidecar/pkt_templates/` library (118 models), or
- the three bundled seed saves, or
- any of the 292 `.pkt` files shipped with the installed
  Cisco Packet Tracer 9.0.0.

No template was invented. The generator now refuses the incomplete export
instead.

### 2. The exporter trusted its own counts

`generate_pkt_file` wrote the encrypted payload and immediately reported
success. It never read the bytes back.

### 3. Connection phrases inflated inventory

`BriefSlotPipeline` counted every `N <device>` phrase as inventory. In
"Create 3 routers, 6 switches, 25 PCs ... Connect 5 PCs to Switch 1", the
`5 PCs` was merged into the PC total (and could restate/replace the 25), and
`Switch 1`/`1 printer` were read as counts. The planner's "a repeat restates"
rule then made the result non-deterministic from the user's point of view.

### 4. The built-in viewer labelled plan counts as file counts

`PktViewerScreen` showed `intent.nodes.length` / `intent.links.length` while
saying it was "the same network the file contains". When the export was
incomplete, those were the plan's counts, not the file's.

## What changed

| File | Change |
| --- | --- |
| `sidecar/pkt_builder.py` | Structured preflight: `missingDevices`, `missingLinks`, `modelSubstitutions`, `interfaceRemappings`, `status`, `complete`. `generate_pkt_file` refuses `EXPORT_INCOMPLETE`/`INVALID` by default (`allow_incomplete=True` opts in), decrypts the written temp file, verifies device/link counts and every device name on disk, then replaces the target. |
| `lib/services/nlu/slots.dart` | Connection phrases that name a destination ("connect 5 PCs **to Switch 1**") are classified as distribution, not inventory. "connect two routers over a serial WAN" remains inventory. |
| `lib/widgets/topology_canvas.dart` | Fit-to-screen control; fit keeps a 24 px margin and clamps to a readable minimum (5%) instead of shrinking to a speck. Existing pinch/pan unchanged. |
| `lib/screens/pkt_viewer_screen.dart` | Viewer text now says it draws the approved plan at the build's positions and that an incomplete export can contain fewer devices. Compact badges kept (a longer badge overflowed a 360 px toolbar). |
| `sidecar/test_export_integrity.py` | 10 regression tests: explicit printer failure, blocked write, opt-in incomplete write, read-back verification, unknown cable, duplicate port, model substitution, interface remap, empty plan, 50-device plan with and without printers. |
| `sidecar/test_generation_scenarios.py` | The 20 requested scenarios, deterministic plans compiled against the real 118-model library. |
| `sidecar/builder_test_support.py` | Shared plan builders and plan-vs-file assertions. |
| `test/device_count_distribution_test.dart` | Count regression tests, including the exact reported brief and the "serial WAN" counter-example. |

## Export statuses

`build_pkt`/`generate_pkt_file` now return one of:

- `VALID` - every planned device and link is present, no warnings.
- `VALID_WITH_WARNINGS` - complete, but something was interpreted (model
  substitution, slot remap, duplicate cable on a port, etc.).
- `EXPORT_INCOMPLETE` - at least one planned device or link is missing. The
  lists name every one. `generate_pkt_file` refuses to write unless
  `allow_incomplete=True`.
- `INVALID` - no device could be built at all. No file is written.

The report also carries `plannedDevices`, `deviceCount`, `plannedLinks`,
`linkCount`, `verification` (`deviceCountOnDisk`, `linkCountOnDisk`,
`deviceCountMatches`, `linkCountMatches`, `missingNamesOnDisk`, `ok`).

## Test execution (this machine, 2026-11-06)

Commands actually run:

```
cd sidecar && python -m pytest -q
# 630 passed, 1 skipped in 135.79s

flutter test
# 2885 passed, 0 failed

flutter analyze <changed Dart files>
# No issues found!
```

Targeted runs:

```
cd sidecar && python -m pytest test_export_integrity.py \
  test_generation_scenarios.py test_pkt_generator.py test_pkt_audit.py \
  test_build_completeness.py test_pt_unsupported.py test_serial_ports.py \
  test_serial_module_hint.py test_link_preflight_scope.py -q
# 205 passed

flutter test test/request_understanding \
  test/named_inventory_regression_test.dart test/port_budget_test.dart \
  test/addressing_no_duplicates_test.dart \
  test/device_count_distribution_test.dart
# 112 passed
```

### The 20 scenarios

All 20 were executed. A scenario is "complete" when
`plannedDevices == deviceCount`, `plannedLinks == linkCount`, every device
name is in the file and every planned endpoint pair/cable is present.

| # | Scenario | Result |
| --- | --- | --- |
| 1 | 1 router, 1 switch, 5 PCs | PASS |
| 2 | 1 switch, 10 PCs | PASS |
| 3 | 2 switches connected | PASS |
| 4 | 2 routers, serial cable | PASS (serial cable, clock rate present) |
| 5 | 3 routers in a chain | PASS |
| 6 | Small office with DHCP | PASS (structural: pool/exclusion/gateway text) |
| 7 | Small office with DNS server | PASS (structural) |
| 8 | AAA authentication | PASS (structural) |
| 9 | Two LANs with static routing | PASS (structural) |
| 10 | Three routers with static routes | PASS |
| 11 | Multiple switches with VLANs | PASS (structural) |
| 12 | Inter-VLAN routing | PASS (`Gi0/0.10`, `dot1Q 10` remapped and present) |
| 13 | OSPF | PASS (structural) |
| 14 | Multiple servers | PASS |
| 15 | Printers | EXPECTED INCOMPLETE (2 printers named; no printer template exists) |
| 16 | Laptops | PASS |
| 17 | Wired + wireless | PARTIAL - no wireless link template; test asserts every wireless device is either built or explicitly named missing. Association is NOT TESTED. |
| 18 | 30 mixed devices | PASS |
| 19 | Exactly 50 devices | PASS (50/50 devices, all links, disk read-back verified) |
| 20 | Complex 50 with printers | EXPECTED INCOMPLETE (46/50 built, all 4 printers named) |

Scenario 20 reproduces the reported field result exactly: 50 planned, 46
exported. It is now an explicit failure, not a success report.

## Edge cases covered

- Zero devices: refused.
- Exactly 50 devices: complete and verified on disk.
- Unsupported device (printer): explicit, blocking, no substitution.
- Unsupported cable name: precise `BuildError`, no replacement.
- Duplicate cable on one interface: both links written, warning raised.
- Unsupported model requested (7200): structured substitution record with the
  model actually used.
- Interface that the model does not have (`g1/0`): structured remap record and
  the report/link show the same assigned port.
- Skipped device's links: listed as missing, not silently dropped.
- Written file that does not match the report: blocked by read-back
  verification before it can replace the target.

Existing tests already cover duplicate IPs, invalid subnets, missing gateways
and switch port budgets; they were run and still pass.

## Remaining limitations

1. **Printers cannot be exported on this machine.** The template library and
   all 292 PT saves were scanned; no `Printer-PT` device block exists. The
   application now says so and refuses. Adding printer support requires a real
   Packet Tracer save containing a printer; then
   `python sidecar/pkt_template_build.py <save.pkt>` (or
   `harvest_templates`) will add it.
2. **Wireless association is not buildable.** There is no wireless `LINK`
   template in the library. Wired AP hardware may build; association tests are
   marked NOT TESTED.
3. **No Packet Tracer runtime test.** No DHCP lease, AAA login, OSPF adjacency
   or ping was executed. The tests prove the plan, interface assignment,
   configuration text and file contents. They do not prove PT behaviour.
4. **Configuration validation is structural.** IP uniqueness/subnet/gateway
   checks remain in `ValidatorService`; the new scenarios assert generated
   commands, not device execution.
5. **The viewer still draws the plan.** It now says so and shows the plan's
   counts; the verified file counts are in the export report. A viewer that
   parses the `.pkt` back and draws only its devices is still a future step.
6. **The 50-device cap is a planner limit.** The Python compiler does not
   impose one. Requests above 50 through the planner were not separately
   tested here.
7. **Unknown save metadata** (scenarios, GUI-only settings) is still outside
   the plan model, as before.

## Manual Packet Tracer checks still required

1. Open the verified 50-device file from scenario 19 in PT 9.0.0 and confirm
   all 50 devices and 47 cables are on the logical canvas.
2. On scenario 6, confirm a PC receives a DHCP lease in the plan's subnet.
3. On scenario 8, confirm the AAA user can authenticate on the router.
4. On scenarios 9/13, confirm static routes/OSPF neighbours and end-to-end
   pings.
5. On scenario 12, confirm inter-VLAN pings with the sub-interfaces.
6. On scenario 4, confirm the serial link comes up with the DCE clock.

## Recommended next steps

1. Harvest a real `Printer-PT` block from a user save and add it to the
   library, then flip scenario 15/20 from EXPECTED INCOMPLETE to PASS.
2. Add a wireless `LINK` template and name AP wireless ports, then test
   laptop-to-AP association.
3. Make the built-in viewer consume the verified report (or parse the `.pkt`)
   so its device/cable badges are the file's counts, not the plan's.
4. Add a PT-runtime integration test that opens the generated file and runs
   `ping`/DHCP checks, marked separately from structural tests.
5. Surface `status`, `missingDevices` and `verification` in the chat build
   card instead of only the device/link totals.
