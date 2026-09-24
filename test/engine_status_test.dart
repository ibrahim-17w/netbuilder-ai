import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/screens/engine_screen.dart';
import 'package:net_builder/services/engine_status.dart';
import 'package:net_builder/services/sidecar_supervisor.dart';
import 'package:path/path.dart' as p;

/// The engine is optional, so the two properties that matter are: a missing
/// engine is reported instantly, and the app tries to start one itself.
void main() {
  group('engine status', () {
    test('a down engine is reported instantly and cached', () async {
      var probes = 0;
      final status = EngineStatus(
        healthProbe: (base, timeout) async {
          probes++;
          throw Exception('connection refused');
        },
        cacheWindow: const Duration(seconds: 30),
      );

      expect(await status.probe(), isFalse);
      expect(status.phase, EngineState.down);
      expect(status.isDown, isTrue);
      expect(status.summary, contains('Nothing is answering'));

      // The second look is served from cache: a down engine must not cost a
      // timeout on every screen that wants to know.
      expect(await status.probe(), isFalse);
      expect(probes, 1);

      // A user-initiated recheck really does ask again.
      await status.probe(force: true);
      expect(probes, 2);
    });

    test('the cache expires so a later engine is picked up', () async {
      var healthy = false;
      final status = EngineStatus(
        healthProbe: (base, timeout) async => {
          'ok': healthy,
          'version': '9.9',
          'rpa': true,
          'ocr': false,
        },
        cacheWindow: Duration.zero,
      );

      expect(await status.probe(), isFalse);
      healthy = true;
      expect(await status.probe(), isTrue);
      expect(status.phase, EngineState.up);
      expect(status.version, '9.9');
      expect(status.hasRpa, isTrue);
      expect(status.hasOcr, isFalse);
      expect(status.summary, contains('v9.9'));
    });

    test('ensure starts the engine and waits until it answers', () async {
      var launched = 0;
      var up = false;
      final status = EngineStatus(
        healthProbe: (base, timeout) async {
          if (!up) throw Exception('refused');
          return {'ok': true, 'version': '1.0', 'rpa': false, 'ocr': false};
        },
        launcher: () async {
          launched++;
          up = true;
          return const SidecarLaunchResult(
            ok: true,
            method: 'py launcher',
            pid: 4242,
            logPath: r'C:\logs\engine.log',
            message: 'Started the local engine (py launcher).',
          );
        },
      );

      expect(await status.ensure(), isTrue);
      expect(launched, 1);
      expect(status.phase, EngineState.up);
      expect(status.isUp, isTrue);
    });

    test('a failed start reports the reason and does not retry in a loop',
        () async {
      var launched = 0;
      final status = EngineStatus(
        healthProbe: (base, timeout) async => throw Exception('refused'),
        launcher: () async {
          launched++;
          return const SidecarLaunchResult(
            ok: false,
            message: '"C:\\WindowsApps\\python.exe" is not a working Python 3.',
          );
        },
      );

      expect(await status.ensure(), isFalse);
      expect(status.phase, EngineState.down);
      expect(status.summary, contains('not a working Python 3'));

      // Asking again immediately must not spawn another attempt: a broken
      // install would otherwise be hammered by every screen that checks.
      expect(await status.ensure(), isFalse);
      expect(launched, 1);

      // But a deliberate retry does.
      expect(await status.ensure(force: true), isFalse);
      expect(launched, 2);
    });

    test('a started engine that never answers is reported as such', () async {
      final status = EngineStatus(
        healthProbe: (base, timeout) async => throw Exception('refused'),
        launcher: () async => const SidecarLaunchResult(
          ok: true,
          method: 'virtualenv',
          message: 'Started the local engine (virtualenv).',
        ),
        startWait: const Duration(milliseconds: 200),
      );

      expect(await status.ensure(), isFalse);
      expect(status.phase, EngineState.down);
      expect(status.summary, contains('never answered'));
    });

    test('changing the address resets the answer', () async {
      final status = EngineStatus(
        healthProbe: (base, timeout) async => {
          'ok': true,
          'version': '1',
          'rpa': true,
          'ocr': true,
        },
      );
      await status.probe();
      expect(status.phase, EngineState.up);

      var notified = 0;
      status.addListener(() => notified++);
      status.setBase('http://192.168.1.20:5005');
      expect(status.phase, EngineState.unknown);
      expect(status.base, 'http://192.168.1.20:5005');
      expect(notified, 1);

      // Setting the same address again is not a change.
      status.setBase('http://192.168.1.20:5005');
      expect(notified, 1);
    });

    test('the report explains the state without any engine present', () async {
      final status = EngineStatus(
        healthProbe: (base, timeout) async => throw Exception('refused'),
      );
      await status.probe();
      final report = await status.diagnose();
      expect(report, contains('address: http://127.0.0.1:5005'));
      expect(report, contains('phase: down'));
      expect(report, contains('--- log tail ---'));
    });

    test('a missing log is answered with words, not an exception', () async {
      final status = EngineStatus(
        healthProbe: (base, timeout) async => throw Exception('refused'),
      );
      expect(await status.readLogTail(), contains('No engine log yet'));
    });
  });

  group('interpreter discovery', () {
    test('the Windows Store placeholder is not a Python', () {
      expect(
        SidecarSupervisor.looksLikeStoreAlias(
            r'C:\Users\L\AppData\Local\Microsoft\WindowsApps\python.exe'),
        isTrue,
      );
      expect(
        SidecarSupervisor.looksLikeStoreAlias(
            r'C:\Python314\python.exe'),
        isFalse,
      );
    });

    test('path interpreters drop the alias and keep real installs', () {
      final found = SidecarSupervisor.pathInterpreters([
        r'C:\Users\L\AppData\Local\Microsoft\WindowsApps\python.exe',
        '',
        r'C:\Python314\pythonw.exe',
        r'C:\Python314\pythonw.exe',
      ]);
      expect(found, [r'C:\Python314\pythonw.exe']);
    });

    test('a bundled engine exe wins over any interpreter', () {
      final root = Directory.systemTemp.createTempSync('netbuilder-engine');
      addTearDown(() => root.deleteSync(recursive: true));
      final sidecar = Directory(p.join(root.path, 'sidecar'))..createSync();
      File(p.join(sidecar.path, 'pt_autopilot.exe')).writeAsStringSync('');
      File(p.join(sidecar.path, 'pt_autopilot.py')).writeAsStringSync('');

      final targets = SidecarSupervisor.candidateTargets(
        roots: [root.path],
        pythonsOnPath: [r'C:\Python314\python.exe'],
      );
      expect(targets.first.method, 'bundled exe');
      expect(targets.first.command, endsWith('pt_autopilot.exe'));
      expect(targets.map((t) => t.method), contains('python'));

      // `py -3 <script>` takes its flags before the script, so a probe has
      // to keep the flags and drop the script.
      final launcher = SidecarTarget(
        command: 'py',
        arguments: ['-3', r'C:\x\pt_autopilot.py'],
        workingDirectory: r'C:\x',
        method: 'py launcher',
        isWindowsLauncher: true,
      );
      expect(launcher.argumentsForProbe, ['-3']);
      expect(launcher.commandLine, contains('pt_autopilot.py'));
    });
  });

  testWidgets('the engine screen states what works without an engine',
      (tester) async {
    // Tall enough that the lazily-built cards below the status area exist.
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: EngineScreen()));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('What needs what'), findsOneWidget);
    expect(find.text('With no engine at all'), findsOneWidget);
    expect(find.text('Start the engine'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Copy a report'), findsOneWidget);
    expect(find.text('Engine log'), findsOneWidget);
  });
}
