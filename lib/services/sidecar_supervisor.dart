import 'dart:io';

import 'package:path/path.dart' as p;

import 'autopilot_service.dart';

/// Starts the bundled Packet Tracer sidecar when the Windows app opens.
///
/// In development it can fall back to the user's Python installation. In a
/// tester package the sidecar is a self-contained executable beside the app,
/// so no terminal window or manual setup step is required.
class SidecarSupervisor {
  static bool _starting = false;

  static Future<bool> ensureRunning() async {
    if (!Platform.isWindows || _starting) return false;
    if (await AutopilotService().healthy) return true;

    final target = _findTarget();
    if (target == null) return false;
    _starting = true;
    try {
      final environment = <String, String>{...Platform.environment};
      if (target.tesseract != null) {
        environment['TESSERACT_CMD'] = target.tesseract!;
      }
      await Process.start(
        target.command,
        target.arguments,
        workingDirectory: target.workingDirectory,
        environment: environment,
        mode: ProcessStartMode.detached,
      );
      for (var attempt = 0; attempt < 24; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (await AutopilotService().healthy) return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      _starting = false;
    }
  }

  static _SidecarTarget? _findTarget() {
    final executableDirectory = p.dirname(Platform.resolvedExecutable);
    final roots = <String>[];
    var cursor = executableDirectory;
    for (var depth = 0; depth < 7; depth++) {
      roots.add(cursor);
      final parent = p.dirname(cursor);
      if (parent == cursor) break;
      cursor = parent;
    }

    for (final root in roots) {
      final sidecar = p.join(root, 'sidecar');
      final bundledExe = p.join(sidecar, 'pt_autopilot.exe');
      if (File(bundledExe).existsSync()) {
        final bundledTesseract = p.join(root, 'tesseract', 'tesseract.exe');
        return _SidecarTarget(
          command: bundledExe,
          arguments: const [],
          workingDirectory: sidecar,
          tesseract: File(bundledTesseract).existsSync()
              ? bundledTesseract
              : null,
        );
      }

      final script = p.join(sidecar, 'pt_autopilot.py');
      if (File(script).existsSync()) {
        final python = _pythonCommand();
        if (python != null) {
          return _SidecarTarget(
            command: python,
            arguments: [script],
            workingDirectory: sidecar,
            tesseract: null,
          );
        }
      }
    }
    return null;
  }

  static String? _pythonCommand() {
    for (final name in const ['pythonw.exe', 'python.exe', 'python']) {
      final candidate = Process.runSync('where.exe', [name], runInShell: false);
      if (candidate.exitCode == 0) {
        final first = candidate.stdout.toString().splitLines().firstWhere(
          (line) => line.trim().isNotEmpty,
          orElse: () => '',
        );
        if (first.trim().isNotEmpty) return first.trim();
      }
    }
    return null;
  }
}

class _SidecarTarget {
  final String command;
  final List<String> arguments;
  final String workingDirectory;
  final String? tesseract;

  const _SidecarTarget({
    required this.command,
    required this.arguments,
    required this.workingDirectory,
    required this.tesseract,
  });
}

extension on String {
  Iterable<String> splitLines() => split(RegExp(r'\r?\n'));
}
