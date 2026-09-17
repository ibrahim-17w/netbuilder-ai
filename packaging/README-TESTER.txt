NetBuilder AI tester build
==========================

1. Install Cisco Packet Tracer separately and sign in if it asks.
2. Open NetBuilder AI from the desktop or Start Menu shortcut.
3. Keep Packet Tracer open and maximized when running an autopilot build.
4. The local Packet Tracer sidecar starts automatically when NetBuilder AI opens.
5. Use PKT Files > Choose .pkt file to select a Packet Tracer project.
6. Use Open + analyze for a read-only topology audit. The app creates a backup
   before opening the file and waits for approval before any suggested fix.
7. Open Memory > Tester diagnostics to create a redacted report to send back.

The default diagnostics export excludes API keys, passwords, raw configurations,
Packet Tracer .pkt files, and screenshots. Screenshots are optional because they
may contain visible names or IP addresses.

The app stores learned memory and diagnostics locally under:
%LOCALAPPDATA%\NetBuilderAI\sidecar

Gemini and GNS3 are optional. Testers must enter their own credentials; this
package contains no API keys or service passwords.
