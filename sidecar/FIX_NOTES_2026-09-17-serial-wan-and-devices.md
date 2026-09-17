# 2026-09-17 — Serial WAN support, and more devices to build

Two related complaints, both about the plan and the canvas disagreeing:

* a plan that asked for a **serial WAN** ended with either a WAN on a spare
  **GigabitEthernet** port or **no cable at all** — `SERIAL_MODULE_HINT` told
  the user to fit the HWIC-2T by hand and nothing did it; and
* the device vocabulary was **routers, switches, PCs and servers**, so a brief
  naming a firewall, an access point, IP phones or an internet edge had
  nowhere to go.

The executor still never guesses: the module is believed only when the live
interface table shows the port, and the cable kind follows the interfaces the
link is actually wired on.

---

## 1. The module is fitted, not explained away

`_install_serial_module(win, dev, project, wanted_full, before)` performs the
hand remedy from the old hint message:

1. open the device window, click the **Physical** tab;
2. **power the device off** (PT refuses a module in a live device);
3. click the module in the **MODULES** list — `HWIC-2T` first, then WIC-2T /
   NIM-2T / HWIC-4T / NIM-4T. This row is printed text, so the OCR word boxes
   locate it exactly; the CAL row is only the fallback and says so;
4. click an **empty HWIC slot** (the slot that worked last time is remembered
   in `hardware_memory.json` and clicked first);
5. **power it back on** and read `show ip interface brief` up to four times,
   with a settle delay, until a serial port appears.

What keeps this honest and cheap:

* **Bounded** — one attempt per `(device, interface)` per run, so a device that
  will not take a module cannot be power-cycled again for every later command;
  `NETBUILDER_SERIAL_MODULE=0` turns it off entirely.
* **Not believed on its own** — `serial_module_installed` is journaled only
  after the live table shows the new port, with the ports it proved.
* **A skipped attempt is not a device failure** — no RPA/OCR stack or an
  unmeasurable window logs and returns, and nothing is journaled against the
  device. A real attempt that fails is `serial_module_install_failed` with the
  step it stopped at, on top of the original hand-remedy hint.

New teachable coordinates: `hw_power`, `hw_module_col0`, `hw_module_row`,
`hw_slot0..hw_slot3`.

## 2. A serial port in the wrong slot beats a LAN port

PT numbers serial interfaces by slot, so an HWIC-2T can come up as `Serial0/1/0`
when the plan said `Serial0/0/0`. `_serial_spare_candidate` now prefers **any
proven serial port** to the GigabitEthernet spare, because a serial WAN on a
different slot is still a serial WAN. The remap stays visible
(`interface_remapped` with `requested`/`actual`) and exact-interface validation
still reports it.

## 3. The cable kind is a decision now

Every link used to be wired with `select_copper()`. That is the whole reason a
serial WAN was never actually cabled: PT refuses a serial port on a copper
cable, and the run never asked for anything else.

* `select_cable(kind)` — printed palette names first, per-kind CAL column
  fallback: copper, copper-cross, **serial-dce**, **serial-dte**, fiber,
  console. `select_copper()` stays as a wrapper.
* `cable_kind_for_link(link, dce_end)` — derives the kind from the **effective**
  interfaces, so the same link that was remapped off Serial0/0/0 is cabled
  copper. A plan `cable` hint only refines the pairs the interface names cannot
  express (fiber/console/crossover).
* `serial_dce_end(link)` — the clocking end: the plan's `dce` hint (device name
  or `'a'`/`'b'`) wins, otherwise the `'a'` endpoint. This is the same decision
  the config renderer uses, so the side that carries `clock rate` and the side
  that holds the DCE half of the cable always agree.
* `place_links` selects the cable before **every** attempt, reports
  `serial_cable_selected`, records `RUN["serial_links"]` (`{link: {dce, cable}}`)
  and the chosen cable in each `link_results` entry.

## 4. `clock rate` on one end only

`CiscoAdapter.isDceSerial` applies the same rule as the executor, so a serial
interface emits `clock rate 64000` on the DCE side and nothing on the DTE side
— PT rejects both mistakes. Interface names are normalized for the check
(`s0/0/0` and `Serial0/0/0` are the same interface, and the plan and the config
disagree on the long form all the time).

## 5. More devices to build

The Flutter app now owns one `DeviceKind` table (`lib/models/network_intent.dart`)
with **17 kinds**: router, wireless-router, switch, pc, laptop, server, printer,
firewall (ASA), wireless (AP), wlc, phone, tablet, smartphone, tv, cloud, modem,
iot. Each entry carries the request keywords, the best-fit PT models, the port
it cables on, and what it supports (`cli`, `ipConfig`, `wireless`).

The planner uses it for counting (`2 IP phones`, `1 access point`, and a
word-bounded match so **a laptop is not an access point**), naming (`FW1`,
`AP1`, `CLOUD1`...), model choice, cabling and the plan's assumptions. The
executor mirrors it:

* `DEVICE_PALETTE` — group → sub-list → model names → strip column → CAL anchor
  for every kind, replacing the old if/elif ladder. **Security** opens straight
  onto its model list, so an empty sub-list is legitimate; an unknown type logs
  and takes the router path so the miss shows up in the slot check instead of
  silently placing a router.
* `PORT_NAME_VOCAB` — `port1` → `Port 1`, `ethernet1`, `coaxial1`, `modem1`,
  `internet`, `console`. Never a bare `port`: the match is a substring, so that
  would also satisfy `Port 2` and cable the wrong interface on an IP phone.
* Non-CLI kinds are never typed at: `CiscoAdapter` renders router/switch only,
  and `config_pcs` covers the kinds PT configures through Desktop > IP
  Configuration (pc/server/laptop/printer).
* Topology sense: the **firewall/cloud/modem are wired on the WAN side** of the
  first router (firewall between the router and the internet edge) — never off a
  user switch; **wireless-only clients are never cabled**; the WLC's and IoT
  devices' ports are not invented (placed, with an assumption saying so).
* Rule packs `core-04/05` and `pt-02..pt-05` (Dart + mirrored assets) and the
  Gemini prompt schema now carry the device kinds, the server roles, the
  serial/DCE requirement and the "only router/switch get CLI" rule.
* The validator derives its supported types from the catalog, and its serial
  message now describes the automatic module path instead of only the manual
  one.

---

## Verification

```
pytest  (app/sidecar)   -> 181 passed   (158 before; +16 test_serial_ports.py,
                                          +7 test_device_palette.py)
flutter test (app/)     -> 35 passed    (31 before; +4 parser/render + 1 fixed)
flutter analyze (app/)  -> No issues found!
```

* `test_serial_ports.py` — cable kind from effective interfaces, DCE/DTE
  choice, palette click order and CAL fallback, the install sequence
  (two power toggles, module row, slot), once-per-run bound, success believed
  only from the live table, failure journaled with its reason, the off switch,
  the learned slot, the preflight's preference for another serial port, and
  `place_links` selecting the serial cable.
* `test_device_palette.py` — a **cross-language gate**: it parses
  `lib/models/network_intent.dart` and asserts both directions (every kind the
  planner can emit has a palette path, nothing in the palette is unreachable),
  that the palette offers the model the planner picks, and that every declared
  port resolves to a name PT will show.
* `app_test.dart` — the firewall assertion changed: **a firewall is buildable
  now**, so that test uses a type outside the catalog to keep exercising the
  validator's unknown-type branch, plus a new positive case for the ASA.

`VERSION = "2026-09-17-serial-wan"` (served on `/health`).

## Still unproven

**No live Packet Tracer run has driven any of this.** The logic is pinned with
doubles; the first real WAN build is the test. Specifically:

* The Physical-tab and palette coordinates (`hw_power`, `hw_slot0..3`,
  `pal_security`, `pal_wireless`, `pal_wan`) are **guesses** until taught — the
  module row itself needs no calibration because it is clicked from OCR text.
* What to read after that run: `serial_module_installed` /
  `serial_module_install_failed` (with the step), `serial_cable_selected`,
  `RUN["serial_links"]`, `interface_remaps`, and whether `show ip interface
  brief` really lists `Serial0/0/0` before the config is typed.
* A palette group that cannot be found by name records
  `placement_unverified` for that device rather than pretending it landed.
