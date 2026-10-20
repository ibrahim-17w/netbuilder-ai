# NetBuilder next-phase plan

Prepared 12 October 2026. Recommended next objective: prove that the installed Windows app completes real user workflows, then expand service verification and run a small pilot.

## Starting evidence

- The latest local run passed 2,428 Flutter tests, 549 sidecar tests, static analysis, whitespace checks, and a Windows Flutter release build.
- Live Packet Tracer interaction was not exercised in that run. DNS interaction tests used a mocked UI.
- Installer construction and bundle/installed-app checks already exist in `packaging/`. The installer builder rebuilds the frozen sidecar; a Flutter-only build does not establish that the bundled engine matches the edited Python source.
- CI currently tests the app and sidecar and compiles a Windows release. It does not run the packaged installer acceptance workflows.
- The verification report deliberately leaves DHCP, HTTP, authentication, and security behavior as manual checks. Lab grading checks generated configuration rather than live simulation.
- The implementation is still present as local modified and new files. A reviewed source checkpoint should precede release work.

## Stage 1: Produce a reproducible tester package

**Purpose:** ensure testers receive the exact app and engine that were validated.

1. Review the current diff, include every required new source/test file, exclude credentials and generated output, and create a local source checkpoint.
2. Assign a release version and produce a manifest identifying the source revision, any local modifications, app version, sidecar identity, and hashes of shipped executables and template assets. Produce hashes after assembling the package.
3. Extend `build_installer.ps1` and the existing verification scripts rather than adding a parallel installer path. Rebuild the Flutter app, frozen engine, OCR payload, and template library together.
4. Verify that the process serving engine health is the shipped executable and that its identity matches the manifest. Surface a useful mismatch explanation when a stale engine owns the configured endpoint.
5. Test the package on a clean Windows account/machine with no development checkout, Flutter SDK, or Python dependency. Test offline planning and file generation, then confirm the engine starts automatically.
6. Test an upgrade over a tester installation with synthetic history, settings, and test credentials. Confirm they survive the upgrade. Keep release version reporting consistent in the UI and diagnostics.
7. Add packaged bundle checks to Windows CI where they can run without Packet Tracer. Retain a separate recorded gate for interactive simulator checks.

**Deliverables:** reproducible tester installer, release manifest, expanded bundle/upgrade verification, and installation evidence.

**Acceptance:** the shipped engine matches the manifest; offline file generation works without developer tools; upgrade preserves the fixture data; startup health belongs to the expected process. Capture the first-launch screenshot and sanitized health output.

## Stage 2: Verify complete workflows in the installed app

**Purpose:** discover integration failures that unit tests and compilation cannot establish.

Use disposable projects and test data. Record app/engine identity, Packet Tracer version, plan version, expected result, observed result, and sanitized evidence for each scenario.

| Scenario | Required result |
| --- | --- |
| Offline basic LAN | Chat request, follow-up, topology edit, saved version, export, and reopened `.pkt` agree on devices, links, and addresses. The whole app workflow works without an API key. |
| Two VLANs with DHCP | Clients obtain addresses, masks, gateway, and DNS appropriate to their VLAN. Generated configuration and live behavior are recorded separately. |
| DNS and HTTP | A configured name resolves correctly and the page opens from the intended client. Incorrect DNS and unavailable HTTP produce useful failure/manual evidence rather than a false pass. |
| Two-router OSPF | Transit addressing is valid, routes appear, and hosts in the two LANs communicate. A missing route or disconnected transit produces a failure. |
| Secure management | Valid SSH access succeeds; a wrong credential and a prohibited access attempt fail as intended. No credential appears in report exports. |
| History and backup merge | Rename a device with several interfaces, compare versions, reopen the earlier version, and merge a backup with colliding IDs. Interface addresses and references remain correct; a repeated merge creates no duplicates. |
| Recovery and privacy | Restart the app and engine, interrupt a run, disconnect/reconnect the engine, and toggle Private Mode. The UI stays responsive, data remains intact, and the engine applies the current privacy configuration. |

Create a small app integration suite for deterministic UI/data workflows. Keep the real Packet Tracer checks as explicit simulator acceptance runs with captured evidence. Fix confirmed failures and rerun the affected workflow before the complete acceptance pass.

**Deliverables:** repeatable fixtures, integration checks, completed acceptance matrix, and fixes for observed defects.

**Acceptance:** all required scenarios pass in the installed package. Record unsupported capabilities explicitly; do not convert unavailable or ambiguous evidence into a pass.

## Stage 3: Expand service verification in measured increments

**Purpose:** reduce manual checking while preserving trustworthy results.

Implement in this order, using the disposable fixtures from Stage 2:

1. **DHCP:** request/renew a test client's lease and inspect its actual address, mask, gateway, and DNS. Compare each observed field with the expected VLAN/pool; exercise an unavailable DHCP server.
2. **HTTP:** open the configured URL in the Packet Tracer client and verify expected page evidence. Exercise an unavailable service and a restricted client.
3. **ACL and management:** run one allowed and one denied connection for each supported policy, then a valid and invalid SSH/AAA login where the simulator interaction is reliable.

Every result should retain check type, plan version, source/target, expected and observed values, timestamp, status, and sanitized evidence. Treat an inaccessible UI or uncertain OCR reading as unavailable/manual. Promote a check to automatic only after positive and negative real simulator cases pass. Preserve the manual checklist for capabilities that remain unsupported.

**Deliverables:** DHCP and HTTP probes, then supported security probes; focused automated tests and real simulator evidence for each.

**Acceptance:** a service that merely responds to ping cannot satisfy its functional probe; deliberately broken configurations produce a failure or explicit unavailable status.

## Stage 4: Improve first use and run a small pilot

**Purpose:** establish that someone unfamiliar with the repository can use the product successfully.

- Provide a first-run readiness panel showing engine availability, OCR, template assets, and optional Packet Tracer support, with a direct next action for each missing requirement.
- Preserve the user's draft during engine failures and make retry/cancel outcomes understandable. Measure cold startup, engine reconnect, and planning latency on a named reference Windows machine; set budgets from that baseline and fix visible stalls.
- Add persistent lab progress and explanations tied to specific failed requirements. Keep configuration grading and live verification visibly distinct. Re-grade after a targeted correction.
- Provide an opt-in diagnostic export containing versions, sanitized errors, and reproduction details. Preview/redact the export locally before sharing it.
- Update the existing README/tester instructions for all provider paths, privacy behavior, backup merge, labs, and verification limits.
- Run a pilot with three to five testers. Each installs the package and completes a basic build, a guided lab, and a backup/reopen workflow without developer help. Track completion, blockers, ambiguous instructions, and reproducible failures.

**Deliverables:** readiness and recovery improvements, useful lab feedback, updated documentation, and a short pilot report.

**Acceptance:** testers complete the core workflow without terminal/dependency setup; no data loss or exposed secrets; every blocking pilot defect has a verified fix before broader release.

## Execution order and release gate

Start with Stage 1 and Stage 2. Begin Stage 3 only after the installed baseline is understood; use Stage 2 fixtures to validate each added probe. Run the pilot after the verified package and usability fixes are ready.

A release candidate needs a reviewed source checkpoint, matching packaged identities, passing relevant automated checks, completed real simulator acceptance evidence, and a successful upgrade test. Keep any unsupported service checks visible as manual requirements.

This plan adds no fixed delivery date: the first packaged acceptance run will establish the actual repair effort. Estimate subsequent stages from its observed failures and simulator compatibility.
