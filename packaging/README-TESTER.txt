NetBuilder AI tester build
==========================

Install
-------
1. Close any older NetBuilder AI window.
2. Run NetBuilderAI-Tester-Setup.exe. It installs for the current Windows user
   under %LOCALAPPDATA%\NetBuilderAI and does not ask for administrator rights.
   If SmartScreen warns, use "More info" only if you trust the person who sent
   the build.
3. The installer creates Desktop and Start Menu shortcuts. The app opens when
   installation finishes.

If the installer is blocked, use NetBuilderAI-Tester-Portable.zip instead:
unzip the whole folder and double-click net_builder.exe. Do not move only the
.exe; the sidecar and template folders must stay beside it.

First run
---------
1. Install Cisco Packet Tracer separately and sign in if it asks.
2. Keep Packet Tracer open and maximized when running an autopilot build.
3. The local engine starts automatically when NetBuilder AI opens.
4. Open Settings to add your own API key if you want online model help. Gemini
   and GNS3 are optional; this package contains no API keys or passwords.
5. Use PKT Files > Choose .pkt file to select a Packet Tracer project.
6. Use Open + analyze for a read-only topology audit. The app creates a backup
   before opening the file and waits for approval before any suggested fix.
7. Open Memory > Tester diagnostics to create a redacted report to send back.

Versions and support
--------------------
The installer writes config\install.json with the app version, engine version,
source revision and bundle-manifest hash. The same information is in
bundle-manifest.json beside the installed app. Include it with a report if the
build does not match what you expected.

The default diagnostics export excludes API keys, passwords, raw
configurations, Packet Tracer .pkt files, and screenshots. Screenshots are
optional because they may contain visible names or IP addresses.

The app stores learned memory and diagnostics locally under:
%LOCALAPPDATA%\NetBuilderAI\sidecar

Uninstall
---------
Use Start Menu > Uninstall NetBuilder AI. By default it removes the app but
keeps saved projects, logs and settings under %LOCALAPPDATA%\NetBuilderAI so
you can recover work. Run uninstall.ps1 -Purge from that folder to remove
everything.
