# Clean-VM install check

This is the release gate that catches packaging mistakes a developer machine
hides: a missing DLL, a dependency on a checkout, an administrator prompt, a
stale engine, or an uninstaller that leaves the app behind. Run it on a clean
Windows account or a Windows Sandbox with no Flutter, Python, Visual Studio, or
repository checkout.

## Prepare the evidence set

Copy these files to the VM and record their SHA256:

- `NetBuilderAI-Tester-Setup.exe`
- `NetBuilderAI-Tester-Portable.zip`
- `bundle-manifest.json`
- `release-manifest.json`
- `SHA256SUMS.txt`
- `README-TESTER.txt`
- the completed pilot scorecard (if one exists)

On the host, before copying:

```powershell
powershell -ExecutionPolicy Bypass -File packaging\verify_release.ps1 -RequireSigned
powershell -ExecutionPolicy Bypass -File packaging\test_install.ps1
powershell -ExecutionPolicy Bypass -File packaging\test_upgrade.ps1
```

## Run in the clean VM

1. Confirm the VM has no `flutter`, `dart`, `python`, or previous
   `%LOCALAPPDATA%\NetBuilderAI` folder.
2. Check the installer hash against `SHA256SUMS.txt` with
   `Get-FileHash .\NetBuilderAI-Tester-Setup.exe -Algorithm SHA256`.
3. Run the installer as the normal user. Record:
   - whether Windows asked for administrator rights (it must not);
   - the SmartScreen prompt and what the tester chose;
   - install duration;
   - whether the app opened on its own.
4. Open the first-run readiness panel. Record the engine, model-key, Packet
   Tracer, OCR and permission lines.
5. Without an API key, ask for a small wired/wireless office LAN, generate the
   `.pkt`, close the app, and reopen the file. Confirm devices, links and
   addresses agree with the plan.
6. Confirm the engine process path is the installed
   `sidecar\pt_autopilot.exe`, not a process from the host or a previous
   install. Compare `/health`'s `version` and `appVersion` with
   `bundle-manifest.json` and `config\install.json`.
7. Export diagnostics. Confirm it is local and that no API key, password, raw
   configuration, `.pkt`, or screenshot appears unless explicitly included.
8. Use Start Menu > Uninstall NetBuilder AI. Confirm the app and shortcuts are
   gone and that saved work remains by default. Repeat with
   `uninstall.ps1 -Purge` in a throwaway install and confirm the folder is gone.
9. Test the portable ZIP in a separate folder. Double-click
   `net_builder.exe`; the engine must start from the ZIP's `sidecar` folder.
10. If testing an upgrade, install the older package first, create a plan and a
    diagnostic export, then install the new package over it. Confirm the plan,
    settings and logs survive and the engine version matches the new manifest.

## Evidence to keep

- first-launch screenshot (sanitized);
- `/health` JSON with the process path and versions;
- `install.json` and `bundle-manifest.json`;
- install, first-topology and uninstall timings;
- any SmartScreen or policy prompt;
- diagnostics archive path and confirmation of its contents;
- the pilot scorecard row for this session.

Do not mark a scenario passed when the evidence is missing or ambiguous. Record
it as unavailable/manual instead; that distinction is part of the acceptance
contract in `next-phase-plan-2026-10-12.md`.

## Windows Sandbox sketch

If Windows Sandbox is available, map the release folder read-only and a results
folder read-write:

```xml
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>C:\netbuilder\dist</HostFolder>
      <SandboxFolder>C:\Release</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>C:\netbuilder\pilot-results</HostFolder>
      <SandboxFolder>C:\Results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -Command "Start-Process C:\Release\NetBuilderAI-Tester-Setup.exe"</Command>
  </LogonCommand>
</Configuration>
```

The manual steps above still apply inside the sandbox; the mapping only keeps
the host clean. Copy screenshots and logs to `C:\Results` before closing it.
