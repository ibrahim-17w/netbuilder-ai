NetBuilder AI - portable tester build
=====================================

This folder is self-contained. It does not need an installer, administrator
rights, Flutter, or Python.

1. Double-click net_builder.exe.
2. Windows SmartScreen may warn because this pilot build is not signed; use
   "More info" only if you trust the person who sent it.
3. The local engine starts from the sidecar folder beside the app.
4. Keep this whole folder together. Moving only net_builder.exe will break the
   engine and the bundled Packet Tracer templates.

The portable build writes settings, logs and generated files beside the app
and under your normal Windows application-data folders. To remove it, close the
app and delete this folder. To remove an installed copy, use
"Uninstall NetBuilder AI" in the Start Menu.

The bundle-manifest.json file records the app version, engine version, source
revision and SHA256 hashes of the shipped files. Send it with a diagnostics
report if a build does not match what you expected.

Packet Tracer is separate software and is not included. Install it from Cisco
if you want the autopilot to drive the GUI; offline .pkt generation works
without it.

Tester notes are in README-TESTER.txt.
