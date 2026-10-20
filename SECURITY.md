# Security policy

## Supported versions

Security fixes are provided for the current `1.x` release line. Older builds
are not supported; update to the latest release before reporting a problem.

## Reporting a vulnerability

Please use the repository's private security advisory flow:

<https://github.com/ibrahim-17w/netbuilder-ai/security/advisories/new>

Do not open a public issue containing an API key, password, private topology,
raw provider response or a working credential leak. If the advisory form is
unavailable, contact the maintainer privately and include only the minimum
needed to reproduce.

Please include:

- the app and engine versions (`About` / `flutter --version`);
- the platform and, for autopilot issues, the Packet Tracer build;
- the steps, expected result and actual result;
- a redacted diagnostics archive if one is useful. Never include a live key.

Do not test against networks or Packet Tracer labs you do not own or have
permission to change.

## Security model

- **Local-first.** The engine binds to `127.0.0.1`. There is no supported
  LAN or `0.0.0.0` binding. Remote engine control is experimental and
  unsupported.
- **Provider keys stay on the engine.** Keys are stored in OS secure storage.
  The local engine receives them over loopback and keeps them in memory. A
  remote engine is refused, so a key cannot be shipped to another host.
- **No cleartext in release.** Release Android builds keep cleartext traffic
  disabled. Debug builds may allow local HTTP for development.
- **Redacted diagnostics.** The app log and diagnostics archive pass through
  `CredentialRedaction`; the sidecar redacts again at the archive boundary.
  Diagnostic export is a local action and never uploads automatically.
  Screenshots are opt-in because they may show names or addresses.
- **Fail-closed automation.** The autopilot verifies each action on screen.
  A step it cannot prove is reported, not assumed.

## Out of scope

- A user deliberately exporting a diagnostics archive that contains visible
  names or addresses with screenshots enabled.
- A compromised OS account, keychain or Packet Tracer installation.
- Multi-user installs sharing one SQLite file.
- Third-party providers' own handling of data once a user sends a model
  request with their key.
