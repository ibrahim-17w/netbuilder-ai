import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/autopilot_service.dart';
import 'package:net_builder/services/engine_status.dart';
import 'package:net_builder/services/sidecar_supervisor.dart';
import 'package:path/path.dart' as p;

/// These exercise the *real* code path that starts the engine - find it,
/// prove the interpreter works, spawn it, capture its output, wait for it to
/// answer - against a throwaway tree, so it is the same logic the app runs at
/// launch and not a mock of it.
///
/// The stand-in engine is a tiny Python HTTP server on its own port, so
/// nothing here touches the user's real installation or its port.
const _testPort = 5099;

String _fakeEngine() => '''
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"ok": True, "version": "test-engine", "rpa": False,
                           "ocr": False}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


print("test engine listening on $_testPort", flush=True)
HTTPServer(("127.0.0.1", $_testPort), H).serve_forever()
''';

void main() {
  late Directory root;
  late String logPath;

  setUp(() {
    root = Directory.systemTemp.createTempSync('netbuilder-launch');
    Directory(p.join(root.path, 'sidecar')).createSync();
    File(p.join(root.path, 'sidecar', 'pt_autopilot.py'))
        .writeAsStringSync(_fakeEngine());
    logPath = p.join(root.path, 'engine.log');
  });

  tearDown(() async {
    await SidecarSupervisor.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('discovery finds the sidecar and proves the interpreter', () async {
    final python = SidecarSupervisor.pathInterpreters();
    if (python.isEmpty) {
      markTestSkipped('no Python on PATH');
      return;
    }

    final targets = SidecarSupervisor.candidateTargets(
      roots: [root.path],
      pythonsOnPath: python,
    );
    expect(targets, isNotEmpty, reason: 'the sidecar script is right there');
    final target = targets.firstWhere((t) => t.method != 'py launcher');
    expect(target.workingDirectory, endsWith('sidecar'));

    // The real proof: run it. A Store placeholder fails this.
    expect(await SidecarSupervisor.verify(target), isTrue);

    // A missing dependency is reported as the import error itself, which is
    // what turns "it will not start" into something the user can act on.
    final missing = await SidecarSupervisor.missingRpaDependencies(
      target,
      modules: 'netbuilder_no_such_module',
    );
    expect(missing, isNotNull);
    expect(missing, contains('netbuilder_no_such_module'));
  });

  test('the app starts the engine, captures its log, and can stop it',
      () async {
    final python = SidecarSupervisor.pathInterpreters();
    if (python.isEmpty) {
      markTestSkipped('no Python on PATH');
      return;
    }

    final engine = EngineStatus(
      // The stand-in answers on its own port, so point the probe there.
      healthProbe: (base, timeout) =>
          AutopilotService(base: 'http://127.0.0.1:$_testPort')
              .healthDetails(timeout: timeout),
      launcher: () => SidecarSupervisor.ensureStarted(
        force: true,
        pythonsOnPath: python,
        roots: [root.path],
        logPath: logPath,
      ),
      probeTimeout: const Duration(seconds: 2),
      startWait: const Duration(seconds: 40),
    )..setBase('http://127.0.0.1:$_testPort');

    final result = await SidecarSupervisor.ensureStarted(
      force: true,
      pythonsOnPath: python,
      roots: [root.path],
      logPath: logPath,
    );
    expect(result.ok, isTrue, reason: result.message);
    expect(result.pid, isNotNull);
    expect(SidecarSupervisor.weStartedIt, isTrue);

    // It really is answering, and the app discovered that by itself.
    expect(await engine.ensure(), isTrue);
    expect(engine.phase, EngineState.up);
    expect(engine.version, 'test-engine');
    expect(engine.hasRpa, isFalse);

    // Its output was captured, which is what makes a failed start fixable.
    final log = await engine.readLogTail();
    expect(log, contains('test engine listening'));

    await engine.stop();
    expect(SidecarSupervisor.weStartedIt, isFalse);
    expect(engine.phase, EngineState.down);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the real sidecar in this checkout is discoverable and runnable',
      () async {
    // The app looks here when run from app/ - this is the exact search the
    // launch does on this machine, against this repository.
    final roots = SidecarSupervisor.searchRoots();
    final targets = SidecarSupervisor.candidateTargets(
      roots: roots,
      pythonsOnPath: SidecarSupervisor.pathInterpreters(),
    );
    // A target for this checkout references the script either as its command
    // (bundled exe) or in its arguments (interpreter + script).
    bool referencesCheckoutScript(SidecarTarget t) =>
        p.basename(t.command).contains('pt_autopilot') ||
        t.arguments.any((a) => p.basename(a) == 'pt_autopilot.py');
    final ours = targets.where(referencesCheckoutScript).toList();
    if (ours.isEmpty) {
      markTestSkipped('no launcher found for the checkout sidecar');
      return;
    }
    expect(ours.any((t) => t.workingDirectory.endsWith('sidecar')), isTrue,
        reason: 'the script lives in sidecar/');

    // And one of them is a real Python 3 - the same proof the app runs
    // before trusting a candidate.
    var verified = false;
    for (final t in ours) {
      if (await SidecarSupervisor.verify(t)) {
        verified = true;
        break;
      }
    }
    expect(verified, isTrue,
        reason: 'at least one discovered target is a working Python 3');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
