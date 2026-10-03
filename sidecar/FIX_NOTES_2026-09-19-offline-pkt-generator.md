# Offline .pkt generator (2026-09-19): build the file without Packet Tracer

Until today the only way to produce a .pkt was to drive Packet Tracer's GUI
(mouse, OCR, screenshots) and then use its own Save As. That is the slow path
and it requires PT open and focused. Three new sidecar modules turn a plan
into a save file directly, with no PT, no screen, no clicks:

* `pkt_codec.py` — the verified .pkt container: Twofish-EAX with the CBC
  fallback decode, self-tests against the published block-cipher vector,
  and `pkt_xml_summary` for structure-only facts (never configuration text).
* `pkt_template_build.py` — extracts the global skeleton, per-model device
  blocks and per-cable link blocks **from the user's own .pkt saves** into a
  machine-local library (`sidecar/pkt_templates/`, gitignored). Nothing
  Cisco-authored is committed. Port names, which the XML does not store, are
  recovered from each device's own running config, paired with `<PORT>`
  elements by family via a depth-aware span scanner; host devices fall back
  to the module-derived `FastEthernet0`.
* `pkt_builder.py` — compiles the **same plan the executor drives the GUI
  with** (`create_nodes` / `create_links` / `paste_cli` / `config_pcs` /
  `config_servers`) into save XML: cloned devices with fresh ids, names,
  MACs, canvas positions and embedded running configs; links resolved to
  real port names; `clock rate` becomes the DCE marker on the right end;
  PC IP settings land on the port that carries the link. What it cannot
  know is warned about, never invented. Server service panels are runtime
  state and stay a reported limitation. Deterministic: the same plan
  produces a byte-identical file (same sha256).

## Sidecar API

* `POST /pkt/generate` `{plan, project?, filename?, replace?}` — builds the
  file into the artifact dir (`NETBUILDER_PKT_DIR`), synchronously (bounded
  file work, no activity lock). The filename is reduced to its basename and
  sanitized, so a request can only land in the artifact dir. `replace`
  keeps the old file as a timestamped backup, like a forced `save_verified`.
  Writes the companion `.netbuilder.json` manifest with
  `"generator": "offline"` so a generated file can never masquerade as a
  Packet Tracer save. Serves the report on `/pkt/report`.
* `POST /pkt/templates/build` `{paths, outDir?}` — (re)extract the template
  library from the user's saves.
* `GET /pkt/templates/status` — coverage report (device kinds/models, cable
  kinds, sources) for the UI to show before a build.

Flutter: `pktGenerate`, `pktTemplatesBuild`, `pktTemplatesStatus` on
AutopilotService. The version string serves as
`2026-09-19-offline-pkt-generator` on `/health`.

## Bugs the tests caught (both real, both fixed)

1. **Stale hostname on non-CLI devices** — `_set_name` only rewrote
   `SYS_NAME` for CLI kinds, and `clean_device` never neutralised it, so a
   generated PC would have inherited the template source's hostname (e.g.
   `Lab-PC1`). `SYS_NAME` is now always written by the builder and wiped by
   the extractor.
2. Nothing else — the remaining initial failures were fixture drift (the
   synthetic serial CABLE carries only the medium `<TYPE>`, like real saves)
   and test expectations that did not match the implemented notes.

## Tests

`test_pkt_generator.py` (new, hermetic — a synthetic save is written with
`pkt_codec` itself and extracted into a throwaway library; no Packet Tracer,
no screen, no developer library): 41 tests across codec round-trip/tamper/
guards/summary, template extraction (dedupe, identity neutralisation, port
inventory pairing + fallbacks + warnings, skeleton, status), builder (ids,
MACs, layout rows, config embedding and exec-line dropping, clock rate →
DCE, missing-DCE warning, PC IP placement, cable-kind rewrite, skipped-node
link warnings, no-model error, server limitation), file generation (round
trip, guards, determinism, missing library) and the new sidecar functions
(generate + guards + path traversal + backup-on-replace + manifest,
templates build).

Full sidecar suite: **336 passed, 1 deselected**
(`test_ocr_perf.py::test_golden_ocr_text_matches_recorded_baseline` — the
pre-existing environment-dependent OCR-golden gate, unchanged by this work).
E2E sanity earlier today: plan → `demo-lab.pkt` (5 devices, 4 links, serial
WAN with clock rate, PC IPs) → decode → parse back clean.

## Deliberately out of scope

* Server service panels (DHCP/DNS/FTP) — runtime state, not in save files.
* A UI surface for the generator (the service methods exist; wiring a
  generate button and coverage panel into the builder screens is app work).
* Devices not present in the user's library are warned and skipped, so a
  firewall needs one ASA save before it can be generated.

## First live run (2026-09-19, PT 9.0): what it exposed

A real plan (2 routers, 2 switches, 2 PCs, serial WAN + copper LANs) opened
in Packet Tracer 9 and proved the container, models, layout and configs load.
The canvas exposed two real defects, both fixed:

1. **Red serial link** - Packet Tracer loads interface up/down and the IP
   from the `<PORT>` element, it does NOT replay `RUNNINGCONFIG` on open.
   A generated file embedded config text but left ports at template state,
   so the serial interfaces came up down. The builder now mirrors interface
   state into the ports: `no shutdown` -> `POWER=true`, `shutdown` ->
   `false`, `ip address a b` -> `IP`/`SUBNET` on the exact port.
   (Per-port `CLOCKRATEFLAG=true` inherited from the template source is
   proven harmless: every serial port in the source save has it and its
   links are green.)
2. **Router-switch links refused** - the plan asked for 1941 routers with
   `g0/1` LANs; the library's 2811 is FastEthernet-only, and the port
   resolver would not cross the Gig/Fast family boundary, so both LAN links
   were dropped and `interface g0/1` stayed dead in the config. Copper
   Ethernet families are now interchangeable in `resolve_port` (Gigabit <->
   Fast <-> Ethernet, always with a visible remap note), and a link whose
   interface still cannot resolve falls back to a free Ethernet port on
   that device (`_spare_ethernet_port`, first-come-first-served, claims
   recorded in `used_ports` so two links never share a port).

Verified on the regenerated plan: 5/5 links resolved (g0/1 -> Fa0/0 remap),
R1 serial `POWER=true IP=10.0.0.1 CR=64000`, R2 serial `POWER=true
IP=10.0.0.2` (DTE side by link marker). New tests: config-state mirroring,
family fallback; suite now 337 passed.
