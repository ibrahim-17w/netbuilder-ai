# 2026-09-17 — The Services list must not be read as the service panel

Fixes the 2026-09-16 DHCP run, whose read-backs showed the **DNS** panel while the
flow believed it was filling the DHCP pool's DNS box:

```
dns      filled, read back as 'wick ew ew wey 1J72.°1VU.t.t | DNS | DNG Conor Nnnnn'
mask / user / gateway / start   "not found"
```

Three code facts produced that, and each one is now gone:

1. the Services-list row `DNS` is an **exact** token match, so it outranked the
   panel's own `DNS Server` row;
2. the label search reached out to `fx = 0.50`, which put the sidebar inside it;
3. the fixed `max_fy = 0.58` sat **above** the real pool form on a maximized
   window, which is why `start` / `mask` / `gateway` / `user` were "missing"
   while `dns` still resolved — to the list.

Nothing here is a new heuristic knob: every replacement reads the evidence that
was already on screen.

---

## 1. One edge, one truth: the list ends at `SRV_SIDEBAR_MAX_FX = 0.35`

The edge `_srv_select` always used to avoid clicking a panel control is now a
named constant, and the field-label search consults it too.

The search keeps its `0.50` reach but **demotes** anything left of the edge
instead of hard-cutting it, because the real DHCP form's labels sit *between*
0.35 and 0.50 — a hard cut would have deleted the fields along with the list.
The old 0.50 ceiling is still honoured exactly for any caller that passes
`max_fy` explicitly.

## 2. A word is not evidence; a value box on the line is

`_srv_row_boxes` finds the digit boxes sitting on the label's own line, right of
it. For a word that spells a services-list entry, "no digit box on this line" is
a demotion — which is exactly what separates the sidebar's `DNS` from the `dns`
word of the panel's `DNS Server` row when the two are the same word.

That tier is consulted **only between service words**, which is what keeps the
legitimately empty rows safe: `Pool Name` and a DNS record's `Name` have no
digits in their box yet, so they never meet the rule.

The first time per run that the list and a field row spell one word, the engine
journals `srv_sidebar_shadow`. In the failing run the collision existed only in
a read-back string; now it is an event with the token, the word and the
candidate count.

## 3. The form bottom is read, not assumed

`_srv_form_bottom` takes the panel's own Add / Save / Remove row as the bottom
edge of its entry form (clamped to 0.30–0.92, minus 0.02 for the gap), and falls
back to the old constant `SRV_BODY_FALLBACK_FY = 0.58` when no button row is
readable. A panel that reads nothing therefore behaves exactly as before.

## 4. Read back the cell, not the whole window

The old read-back OCR'd 0.02–0.97 of the window width, which is how a DHCP row
"read back" with `| AAA |` from the sidebar inside it. `_srv_cell_span` now cuts
the band to the field's own cell (label → right edge of its box) plus a small
margin; a span too narrow to contain a value falls back to the old band rather
than cropping the value away. Tab- and row-click fills, whose box x is unknown,
start right of the list edge instead (`_srv_span_without_boxes`).

`_row_read` tolerates a two-argument `_row_text`, the same way the word scanner
tolerates one-argument doubles, so deterministic test doubles and older
integrations keep working.

## 5. Never type into a panel that is provably another service

`_srv_panel_service(title)` names a service only when the title's **first word**
is a known services-list entry. Anything else — an empty read, a dialog, page
text — is not evidence about which panel is open and can never block a fill.

`_srv_fill` now checks that before its first keystroke:

* title names another service → re-select the requested one **once**;
* re-selection fails → type nothing, and journal `srv_panel_mismatch` with the
  panel that *was* open and the field that was asked for;
* unreadable title → proceed.

Previously the engine could only discover a wrong panel *after* typing, from the
read-back — which is one wrong value in the wrong panel. Now it costs at most
one re-select.

## 6. `GET /srv/probe` — measure the panel instead of inferring it

The 2026-09-16 diagnosis had to be reconstructed from a read-back string. The
probe exists so the next one is a measurement. It is **read-only** (pinned by a
test: zero input calls):

* the panel title, the service that title names, the form bottom and the sidebar
  edge the search used;
* for each requested field token, **every** candidate label row with the evidence
  the ranking consults — `service_word`, `value_box_on_line`, `rank`,
  `in_sidebar_band` — and which row won.

`?service=dhcp` supplies the token set (`pool`, `start`, `mask`, `gateway`,
`dns`, `user`); `?tokens=dns,gateway` overrides it; `?device=` picks the window.
Tokens that resolve and tokens that do not are listed separately, and the report
lands in `RUN["srv_probe"]` plus one `SRV PROBE:` log line.

---

## Verification

```
pytest  (app/sidecar)   -> 158 passed        (139 before this work; 17 new gates
                                              in test_srv_panel_scope.py, plus 2
                                              for the golden-harness change)
flutter analyze (app/)  -> No issues found!
```

`test_srv_panel_scope.py` runs with no Packet Tracer, no Tesseract and no RPA
stack: it stubs the word scan and asserts the ranking, the form bottom, the
read-back span, the panel gate and the probe's evidence against a hand-built
panel whose list and form share the word `dns`.

`VERSION` is bumped to `2026-09-17-srv-scope` (served on `/health`), so a live
run states which build it ran.

---

## The golden OCR gate: a DIFF has two causes, and only one is your code

Part of this session was spent on a red gate that had nothing to do with the
change. Worth writing down because it will happen again:

* the baseline was recorded 2026-09-16 22:11; a **live run at 22:58 overwrote
  `shots/before.png`** (a real canvas capture), so the recorded text for that
  image described a different screen — a simulation table, not the canvas;
* the next `pytest` reported exactly 3 diffs, all on `before.png`, with the
  other **48** reads byte-identical. 48 identical reads is the signal that the
  pipeline did not change and the *capture* did.

`ocr_baseline.py --record --only <name>` is the fix for that cause: it
re-records the named captures only, keeps every other entry byte-for-byte, keeps
the baseline's original `recorded`/`settings` metadata, and stamps what it
refreshed under `refreshed`. A capture name that matches nothing is an error
listing what *can* be swept — never an empty sweep, which would look like a pass.

A genuine pipeline change is still a whole-file `--record`, and the tool prints
that reminder after a partial refresh. `shots/before.png`, `after.png` and
`link0_after.png` are written by live runs, so they are the captures to suspect
first when a single image diffs.

## Still unproven

**No live run has driven any of this.** The logic is exercised with stubs, but
the first DHCP build is the real test. After it, read:

* `/srv/probe?service=dhcp&device=DHCP1` while the pool form is open — this is
  what the search sees, before anything is typed;
* `srv_panel_mismatch` (wrong panel refused, and whether the re-select worked),
  `srv_sidebar_shadow` (list/field word collisions), and whether
  `srv_field_missing` for `start`/`mask`/`gateway`/`user` is finally **zero**;
* the run log's `SRV PROBE:` line, and `validation` / `srv_*` outcomes.

Not done here, deliberately: the probe is **not** wired to the Flutter app yet
(no `AutopilotService` method, no button). The endpoint is the deliverable; a UI
to read it is separate work.
