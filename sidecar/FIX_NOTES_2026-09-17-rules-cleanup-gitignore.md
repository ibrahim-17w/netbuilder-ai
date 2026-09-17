# 2026-09-17 — More rules for the AI, a clean tree, and a GitHub-ready repo

Three asks in one pass: **the planner knows more**, **the workspace carries no
dead weight**, and **the repo can be pushed to GitHub without leaking or
bloating it**.

---

## 1. Rule packs: 16 → 43 rules

`RulePacksService.packs` is the AI planner's networking knowledge — every rule
is injected into the Gemini context block. The expansion covers what real
builds keep getting wrong:

* **core-06..12 (addressing & design)** — one addressing block per site,
  gateway = first usable host with the pool excluding it and the server
  range, every end device needs a working default gateway, subnet sized to
  the stated host count, unique Loopback0 per router for router-id/peering,
  purposeful VLAN numbering (no VLAN 1, users 10/20/30, native 99, mgmt
  100+), and nothing configured that the brief did not ask for.
* **cisco-04..13 (IOS hardening & services)** — enable secret not enable
  password, VTY locked to the manager subnet over SSHv2 with a banner,
  access vs trunk port roles with portfast and allowed-VLAN lists, precise
  OSPF wildcards with passive-interface on user ports, defaults pointing at
  the edge (never router-to-router loops), ACL order and placement rules,
  NAT inside/outside roles with overload, DHCP pool per subnet with
  helper-address for remote servers, router-on-a-stick or SVI (never both
  per VLAN), and hostnames/descriptions matching the plan.
* **gns3-02** — Idle PC is set after boot; a host CPU at 100% is a
  misconfiguration, not work.
* **pt-06..13 (executor reality)** — cable kind per port pair
  (straight-through vs cross-over vs serial DCE/DTE vs fiber), access vs
  trunk roles on PT switches, port security on user ports only, DHCP
  snooping trusting only the server port, ASA interface naming/security
  levels before any ACL applies, IPSec peers with matching ISAKMP/transform
  sets and interesting-traffic ACLs both ways, an AP bridging clients into
  the SSID's VLAN with DHCP for that VLAN, and the evidence rule: the
  executor believes only `show ip interface brief` and panel read-backs,
  never a guess.
* **sec-01..04 (security obligations)** — every requested control maps to a
  listed test, credentials are never invented (they become questions),
  AAA is configured server+key+method together, and manager/office-hours
  ACLs are time-range ACLs whose period matches the brief.
* **aws-02** — private and public route tables are split; 0.0.0.0/0 never
  crosses between them.
* **val-02 (warn)** — plan-internal consistency gate: links must endpoint at
  interfaces the named models actually have.

Two of the most expensive rules were also added to the **Gemini hard-rule
block** in `gemini_service.dart` (gateway/host placement, no overlapping
subnets; cable kind follows the interfaces), because those two failures cost
the most execution retries.

## 2. The packs are mirrored — and a test now proves it

The YAML assets (`assets/rule_packs/*.yaml`) are the user-editable mirror;
`security.yaml` is new for the sec-* family. `parser_render_test.dart`
gained four gates:

* ids unique, non-empty rules, nothing too vague to steer the planner;
* every target is one the app understands (all/gns3/cisco-ssh/
  packet-tracer/aws-vpc);
* a coverage test naming the key rules per family (addressing, IOS, PT
  reality, security, AWS, severities block/warn);
* **the sync gate**: every embedded pack id must exist in the asset YAML and
  every asset id must be embedded, with a rule-text spot check — a rule
  added in only one place fails CI with the exact missing list.

## 3. Dead weight removed (≈1.3 GB + strays)

* `backups/` — ten pre-fix snapshot trees from Sep 12–16; git history is the
  backup now (user-approved deletion).
* `app/Q` — a 482 KB binary with no extension, referenced by nothing.
* `_t.png` — a stray screenshot at the repo root.
* `DELIVERY/` — an empty PT-FIX directory tree.
* `docx_review_network_security/` — empty directory.
* `__pycache__/`, `.pytest_cache/` — regenerable caches.

Kept deliberately: `app/sidecar/shots/` (the OCR golden gate's captures),
`ocr_golden.json`, the `*_memory.json`/`failures.jsonl` state, calibration
files, and all packaging scripts — each is load-bearing for a test or a
live run.

## 4. `.gitignore` — repo root, GitHub-ready

One root file instead of scattered ones, with sections: secrets (env/key/
pem/pfx, `!*.env.example`), regenerable artifacts (`backups/`, `app/dist/`,
builds), Python caches, **sidecar run artifacts** (`shots/`, `pkt_backups/`,
`*.log`, `*.jsonl`, `experience_memory.jsonl` — learned runtime state lives
with the user, not in git), Flutter/Dart ephemeral dirs, IDE/OS junk, and
the local-only agent workspace (`.mimosa/`, `.freebuff/`).

`pubspec.lock` is ignored (application, not a package); `cal.json`,
`pc_tiles.json`, `device_memory.json` and friends stay tracked — they ship
with the app. Verified with `git check-ignore` against the real paths.

---

## Verification

```
flutter test (app/)     -> 39 passed    (35 before; +4 rule-pack gates)
flutter analyze (app/)  -> clean
pytest (app/sidecar)    -> 181 passed   (untouched; run pre-cleanup)
```

Deleted files were not referenced by any test, script or import
(`grep`-checked before removal).
