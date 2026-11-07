# NetBuilder AI - tester runbook

Thank you for testing. This should take about 20 minutes and needs no API key,
no developer tools, and no Python. Packet Tracer is optional.

Keep this page open while you work. If something goes wrong, the note at the
end tells you what to send back.

## 1. Install

1. Check the installer's SHA256 against the value you were given:
   `Get-FileHash .\NetBuilderAI-Tester-Setup.exe -Algorithm SHA256`.
2. Run `NetBuilderAI-Tester-Setup.exe`. It installs for your user only -
   **no administrator prompt should appear**.
3. Windows SmartScreen will warn you because this build is unsigned. Choose
   "More info" then "Run anyway". Please note down that it appeared.
4. Tell us how long the install took, then open NetBuilder AI from the Start
   menu.

The app may also open by itself. If you prefer not to install, the portable ZIP
runs the same app from any folder.

## 2. First screen

The chat screen shows a short readiness checklist. You do **not** need to fix
any of it to continue - it is telling you what is available:

- **Local engine** - runs on this PC; needed for some extra checks.
- **Model key** - optional. Leave it unset: everything below works without it.
- **Packet Tracer** - optional. Leave it closed.
- **OCR** - reads text out of screenshots you attach.
- **No administrator rights** - expected.

You should be able to name those four things without opening Settings. If you
cannot, that is a finding - say so.

## 3. Build a network (no key, offline)

Type this into the chat, exactly as written:

> 2 routers, 4 switches and 20 PCs with OSPF

1. A plan appears. Check that it has the devices you asked for before accepting
   it. If you had to add, remove, rename or re-address anything, note
   "repaired the plan" - that counts against us, not you.
2. Accept the plan and choose a layout when asked.
3. Tap the build card to generate the `.pkt`. Time how long it takes.
4. Read the result. It should show device and cable counts, an export status,
   a verification line and a design review. **A file with an "export status"
   that is not VALID is a partial file** - tell us the exact wording.

## 4. Change it

Ask for a follow-up in your own words, for example:

> add a guest VLAN with DHCP

The existing devices and addresses should survive. Then build again.

## 5. Reopen what you built

1. Close the app completely.
2. Reopen it and find the saved network in the app.
3. The topology, device and cable counts must match what you built.
4. If you have Packet Tracer, open the `.pkt` and confirm the devices and
   cables are on the canvas. This is the step we most need evidence for.

## 6. Ask a question (no build)

Type:

> how many access points do I need for 50 users?

or

> how do I configure a trunk port?

These are answered without touching your lab, without a key, and without
creating a file. Nothing should be built or changed.

## 7. Diagnostics and versions

Open Settings and export diagnostics. The export is local: it must not contain
an API key, a password, raw device configuration, or a `.pkt` file. Confirm you
can find the app version, engine version and source revision in it.

## 8. Uninstall

Use Start menu -> Uninstall NetBuilder AI. The app and shortcuts should go, and
**your saved work should remain**. Say whether that was clear from the prompts.
In a throwaway install only, try `uninstall.ps1 -Purge` and confirm the folder
is gone.

## What "offline" means here

- Planning, editing, the assistant, subnet math, `.pkt` generation, `.pkt`
  analysis and lab grading all run on this machine.
- No key, no account, no internet connection is required for any task above.
- Without Packet Tracer running, the app does not claim your lab works in
  simulation. "Verification" means the **file** was read back and compared
  with the plan - not that a ping succeeded.
- Wireless clients cannot be cabled by the generator yet, and some uncommon
  device types build into the file but cannot be placed automatically in a live
  Packet Tracer run. Both are reported, not hidden.

## If something goes wrong

Write down, in your own words:

- which task number above you were on (for example "task 3");
- what you expected and what happened instead;
- the exact on-screen wording if there was an error;
- whether Packet Tracer was open at the time.

Attach the diagnostics export. Send those four things together - they are what
we can actually act on. Do not reinstall or retry repeatedly to make it work:
the first failure is the valuable one.
