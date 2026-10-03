import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/engine_status.dart';
import 'package:net_builder/services/sidecar_supervisor.dart';

/// An engine from an older build keeps answering on the engine port after the
/// app has been updated, serving the old code: that is why a fixed .pkt layout
/// came out of a build looking unchanged. These are the rules that let the app
/// notice, and the parsing that finds the stray process.
void main() {
  group('the engine answering is compared with the one this app ships', () {
    const bundled = r'C:\ai\app\build\windows\x64\runner\Release\sidecar\pt_autopilot.exe';
    const newer = 1790800000000;
    const older = 1780000000000;

    test('nothing to compare against means nothing to replace', () {
      expect(
        EngineStatus.isStaleEngine(
          identity: const {},
          bundledFile: null,
          bundledBuiltAt: null,
        ),
        isFalse,
        reason: 'a dev checkout ships no engine',
      );
    });

    test('an engine that reports no identity predates the field', () {
      expect(
        EngineStatus.isStaleEngine(
          identity: const {},
          bundledFile: bundled,
          bundledBuiltAt: newer,
        ),
        isTrue,
      );
    });

    test('an older copy of this app\'s own engine is stale', () {
      expect(
        EngineStatus.isStaleEngine(
          identity: const {'file': bundled, 'builtAt': older},
          bundledFile: bundled,
          bundledBuiltAt: newer,
        ),
        isTrue,
      );
    });

    test('the shipped engine, or a newer one, is used as it is', () {
      expect(
        EngineStatus.isStaleEngine(
          identity: const {'file': bundled, 'builtAt': newer},
          bundledFile: bundled,
          bundledBuiltAt: newer,
        ),
        isFalse,
      );
      expect(
        EngineStatus.isStaleEngine(
          identity: const {'file': bundled, 'builtAt': newer + 5000},
          bundledFile: bundled,
          bundledBuiltAt: newer,
        ),
        isFalse,
      );
    });

    test('an engine someone runs by hand is not ours to replace', () {
      expect(
        EngineStatus.isStaleEngine(
          identity: const {
            'file': r'C:\dev\checkout\sidecar\pt_autopilot.py',
            'builtAt': older,
          },
          bundledFile: bundled,
          bundledBuiltAt: newer,
        ),
        isFalse,
        reason: 'same build time or not, that process belongs to the person '
            'who started it from a terminal',
      );
    });

    test('a path is compared the way Windows names one', () {
      expect(
        EngineStatus.sameFile(
          r'C:\AI\app\sidecar\pt_autopilot.exe',
          'c:/ai/app/sidecar//pt_autopilot.exe',
        ),
        isTrue,
      );
      expect(
        EngineStatus.sameFile(
          r'C:\ai\app\one.exe',
          r'C:\ai\app\two.exe',
        ),
        isFalse,
      );
    });
  });

  group('the process holding the engine port is found', () {
    // Real `netstat -ano` shape (columns: Proto, Local, Foreign, State, PID).
    const output = '''
  TCP    127.0.0.1:5005         0.0.0.0:0              LISTENING       15808
  TCP    127.0.0.1:50050        0.0.0.0:0              LISTENING       11111
  TCP    0.0.0.0:5040           0.0.0.0:0              LISTENING       9304
  TCP    127.0.0.1:5005         127.0.0.1:52134        ESTABLISHED     15808
  UDP    127.0.0.1:5005         *:*                                    15808
''';

    test('the listener on the engine port is picked, not the connection', () {
      expect(SidecarSupervisor.listeningPid(output, 5005), 15808);
    });

    test('a port that merely starts the same way is never matched', () {
      expect(SidecarSupervisor.listeningPid(output, 500), isNull);
      expect(SidecarSupervisor.listeningPid(output, 50055), isNull);
    });

    test('nothing listening means no pid to kill', () {
      expect(
        SidecarSupervisor.listeningPid('  TCP    0.0.0.0:5040  0.0.0.0:0  '
            'LISTENING  9304', 5999),
        isNull,
      );
      expect(SidecarSupervisor.listeningPid('', 5005), isNull);
    });
  });
}
