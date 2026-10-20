# Packet Tracer hardware and Android editor update

The planner, Android editor, Dart compiler and Python builder now use one versioned hardware catalog for Packet Tracer 9.0.0.0810. Model aliases, default device names, explicit connection names, requested modules, connector media and serial clocking survive plan serialization.

## Behavior

- Search devices and cables locally. The catalog distinguishes available templates from recognition-only names and lists each available module variant and its named ports.
- Choose hardware when adding or editing a device. Pick free compatible ports for each connection, with separate cables supported between the same pair of devices.
- Explicit model, module, port and cable requests are preserved. Unsupported exact requests fail with an actionable message. Unknown cables never become copper silently. Legacy automatically chosen hardware retains its documented fallback warnings.
- Copper straight-through/crossover, serial DCE/DTE, fiber modes, phone, coaxial, octal, IoE custom and USB use their corresponding saved-file formats. Console is recognized but its offline cable template is unavailable.
- Known USB, coaxial, phone, serial and console connector names can identify a connection medium when no cable was stated. Fiber mode requires compatible optical hardware.
- Long briefs and file compilation run away from the Android UI thread. Catalog/model lookup, library loading and identity checks are cached; output writes are asynchronous.
- The preview retains the chosen layout geometry, uses Packet Tracer-style devices and cable drawing, highlights the first connection endpoint, and enables dragging only during editing. The catalog and cable editor work at phone size. Light-theme text colors now remain explicit after typography customization.

## Coverage and limits

- 151 model names recognized; 92 have templates whose saved device identity matches the catalog.
- 14 cable entries, including mode-unspecified fiber; 13 specifically named types, of which 12 have usable offline saved-file coverage.
- The coverage test constructs each supported device, checks its actual saved XML model identity, then generates, encrypts and decodes representative cable files and checks medium, variant and endpoints.
- Generated cable files and the per-model/per-cable coverage report are under `build/hardware-qa/`.
- Exact 2911 serial-port requests currently report a missing variant rather than being silently changed to a 2811/1841.
- Recognition-only models remain visible with an explanation. A device template being available does not establish support for every optional module, configuration command, or simulator behavior.
- No live Packet Tracer simulation or physical Android-device validation was performed for this update. The UI reports live verification as unrecorded.

## Checks

- Shared catalog generation consistency check.
- Flutter static analysis: clean.
- Python generator, cabling, strict hardware and repair suites: 129 passed.
- Full Flutter regression: 2,471 passed. Focused final hardware/serial/compiler coverage: 31 passed. Phone-size catalog and connection editor interaction checks passed.
- Performance gates passed with monotonic timing; file/container checks passed for the delivered APK.
- Android release APK built successfully. Delivery copy: `C:/ai/netbuilder-hardware.apk`.
