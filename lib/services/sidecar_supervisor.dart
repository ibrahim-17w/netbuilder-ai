import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The outcome of trying to bring the local engine up.
///
/// It carries the *reason* rather than a bare bool: "python is the Windows
/// Store stub", "pyautogui is missing", "port 5005 is taken" are all things
/// the user can act on, and none of them are discoverable from `false`.
class SidecarLaunchResult {
  /// A process was started (or one was already running).
  final bool ok;

  /// Nothing was started because something already answered there.
  final bool reuse;

  /// How it was found: 'bundled exe', 'virtualenv', 'py launcher',
  /// 'python3', 'python', 'install dir', or 'none'.
  final String method;

  /// The exact command line, for the diagnostics card.
  final String command;

  final int? pid;
  final String? logPath;

  /// A plain sentence for the user.
  final String message;

  const SidecarLaunchResult({
    required this.ok,
    required this.message,
    this.reuse = false,
    this.method = 'none',
    this.command = '',
    this.pid,
    this.logPath,
  });

  @override
  String toString() => 'SidecarLaunchResult(ok=$ok, method=$method, '
      'message=$message)';
}

/// Starts and supervises the bundled Packet Tracer sidecar.
///
/// The app must never need a terminal. So this looks for an interpreter the
/// same way a person would, proves each candidate actually runs (Windows
/// ships a `python.exe` in `WindowsApps` that only opens the Store - it is
/// the single most common reason auto-start silently fails), checks the
/// sidecar's imports *before* launching so a missing dependency is reported
/// as a sentence instead of a dead process, keeps the process handle so it
/// can be stopped, logs its output, and restarts it if it dies.
class SidecarSupervisor {
  SidecarSupervisor._();

  static Process? _process;
  static StreamSubscription<String>? _stdoutSub;
  static StreamSubscription<String>? _stderrSub;
  static Future<SidecarLaunchResult>? _inFlight;

  static SidecarLaunchResult? lastResult;
  static int restarts = 0;

  /// Restarting forever would fight a genuinely broken install, so a run of
  /// failures ends the loop and leaves the message on screen.
  static const maxRestarts = 3;
  static bool _autoRestart = true;

  static bool get weStartedIt => _process != null;
  static String? get logPath => _logPath;
  static String? _logPath;

  /// The bundled/derived interpreter candidates, most specific first.
  /// Pure and side-effect free so it can be tested without a process.
  static List<SidecarTarget> candidateTargets({
    List<String> roots = const [],
    List<String>? pythonsOnPath,
  }) {
    final targets = <SidecarTarget>[];
    for (final root in roots) {
      final sidecar = p.join(root, 'sidecar');
      final bundledExe = p.join(sidecar, 'pt_autopilot.exe');
      if (File(bundledExe).existsSync()) {
        targets.add(SidecarTarget(
          command: bundledExe,
          arguments: const [],
          workingDirectory: sidecar,
          method: 'bundled exe',
          tesseract: _bundledTesseract(root),
        ));
      }
      // A virtualenv beside or inside the project is the recommended dev
      // setup, and its interpreter already has the dependencies.
      for (final venv in const ['.venv', 'venv']) {
        for (final script in const ['Scripts', 'bin']) {
          for (final exe in const ['pythonw.exe', 'python.exe', 'python']) {
            final candidate = p.join(root, venv, script, exe);
            if (File(candidate).existsSync()) {
              targets.add(SidecarTarget(
                command: candidate,
                arguments: [p.join(sidecar, 'pt_autopilot.py')],
                workingDirectory: sidecar,
                method: 'virtualenv',
                tesseract: _bundledTesseract(root),
              ));
            }
          }
        }
      }
      // The `py` launcher always points at a real CPython on Windows.
      if (Platform.isWindows && File(p.join(sidecar, 'pt_autopilot.py')).existsSync()) {
        for (final flag in const ['-3.13', '-3.12', '-3.11', '-3']) {
          targets.add(SidecarTarget(
            command: 'py',
            arguments: [flag, p.join(sidecar, 'pt_autopilot.py')],
            workingDirectory: sidecar,
            method: 'py launcher',
            tesseract: _bundledTesseract(root),
            isWindowsLauncher: true,
          ));
        }
      }
    }
    for (final python in pathInterpreters(pythonsOnPath)) {
      for (final root in roots) {
        final sidecar = p.join(root, 'sidecar');
        final script = p.join(sidecar, 'pt_autopilot.py');
        if (!File(script).existsSync()) continue;
        targets.add(SidecarTarget(
          command: python,
          arguments: [script],
          workingDirectory: sidecar,
          method: p.basenameWithoutExtension(python),
          tesseract: _bundledTesseract(root),
        ));
      }
    }
    for (final python in _installedInterpreters()) {
      for (final root in roots) {
        final sidecar = p.join(root, 'sidecar');
        final script = p.join(sidecar, 'pt_autopilot.py');
        if (!File(script).existsSync()) continue;
        targets.add(SidecarTarget(
          command: python,
          arguments: [script],
          workingDirectory: sidecar,
          method: 'install dir',
          tesseract: _bundledTesseract(root),
        ));
      }
    }
    return targets;
  }

  /// The Windows Store ships `python.exe` shims that only open the Store.
  /// Launching one produces a process that exits instantly with code 9009.
  static bool looksLikeStoreAlias(String path) {
    final lower = path.toLowerCase().replaceAll('/', r'\');
    return lower.contains(r'\windowsapps\');
  }

  /// Interpreters named on PATH, with the Store placeholders dropped. Visible
  /// for testing: the filtering is the part that fails silently in the wild.
  static List<String> pathInterpreters([List<String>? override]) {
    final raw = override ?? _where(['pythonw.exe', 'python.exe', 'python3', 'python']);
    final result = <String>[];
    for (final entry in raw) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;
      if (looksLikeStoreAlias(trimmed)) continue;
      if (!result.contains(trimmed)) result.add(trimmed);
    }
    return result;
  }

  static List<String> _where(List<String> names) {
    final found = <String>[];
    for (final name in names) {
      try {
        final r = Process.runSync('where.exe', [name], runInShell: false);
        if (r.exitCode == 0) {
          found.addAll(r.stdout
              .toString()
              .split(RegExp(r'[\r\n]+'))
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty));
        }
      } catch (_) {}
    }
    return found;
  }

  /// `%LOCALAPPDATA%\Programs\Python\Python3xx\pythonw.exe`, newest first.
  /// A per-user install that is not on PATH is extremely common.
  static List<String> _installedInterpreters() {
    if (!Platform.isWindows) return const [];
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null) return const [];
    final root = Directory(p.join(base, 'Programs', 'Python'));
    if (!root.existsSync()) return const [];
    final dirs = root
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path)
        .toList()
      ..sort((a, b) => b.compareTo(a));
    final found = <String>[];
    for (final dir in dirs) {
      for (final exe in const ['pythonw.exe', 'python.exe']) {
        final candidate = p.join(dir, exe);
        if (File(candidate).existsSync()) found.add(candidate);
      }
    }
    return found;
  }

  /// Proves a candidate is a working Python 3 before we trust it: the Store
  /// shim, a broken install and Python 2 all fail here.
  static Future<bool> verify(SidecarTarget target,
      {Duration timeout = const Duration(seconds: 10)}) async {
    try {
      final args = <String>[
        ...target.argumentsForProbe,
        '-c',
        'import sys; print(sys.version_info[0])',
      ];
      final r = await Process.run(target.command, args,
          workingDirectory: target.workingDirectory.isEmpty
              ? null
              : target.workingDirectory,
          runInShell: false).timeout(timeout);
      if (r.exitCode != 0) return false;
      return r.stdout.toString().trim().startsWith('3');
    } catch (_) {
      return false;
    }
  }

  /// Reports what the sidecar needs and cannot import. The offline .pkt
  /// generator is stdlib-only, so a missing RPA dependency is a *warning*
  /// (GUI runs need it, file generation does not).
  static Future<String?> missingRpaDependencies(
    SidecarTarget target, {
    Duration timeout = const Duration(seconds: 25),
    String modules = 'pyautogui, pywinauto',
  }) async {
    try {
      final r = await Process.run(
        target.command,
        <String>[
          ...target.argumentsForProbe,
          '-c',
          'import $modules; print("OK")',
        ],
        workingDirectory: target.workingDirectory.isEmpty
            ? null
            : target.workingDirectory,
        runInShell: false,
      ).timeout(timeout);
      if (r.exitCode == 0 && r.stdout.toString().contains('OK')) return null;
      // Python puts the actual reason on its LAST line; the first line is
      // always "Traceback (most recent call last):", which explains nothing.
      final lines = '${r.stderr}\n${r.stdout}'
          .split(RegExp(r'[\r\n]+'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) return 'the import failed';
      final reason = lines.lastWhere(
        (l) => l.contains('Error') || l.contains('error'),
        orElse: () => lines.last,
      );
      return reason;
    } catch (e) {
      return '$e';
    }
  }

  /// Bring the engine process up. Safe to call repeatedly: concurrent calls
  /// share one attempt, and a live process is never duplicated.
  static Future<SidecarLaunchResult> ensureStarted({
    bool force = false,
    List<String>? pythonsOnPath,
    List<String>? roots,
    String? logPath,
  }) {
    if (!force && _process != null) {
      return Future.value(lastResult ??
          const SidecarLaunchResult(
              ok: true, message: 'The local engine is already running.'));
    }
    return _inFlight ??= _start(
      pythonsOnPath: pythonsOnPath,
      roots: roots,
      logPath: logPath,
    ).whenComplete(() => _inFlight = null);
  }

  /// [roots] and [logPath] exist so the launch path (discover, verify, spawn,
  /// capture output, watch for exit) can be driven against a throwaway tree
  /// in a test instead of the user's real installation.
  static Future<SidecarLaunchResult> _start({
    List<String>? pythonsOnPath,
    List<String>? roots,
    String? logPath,
  }) async {
    final searchRoots = roots ?? SidecarSupervisor.searchRoots();
    final targets = candidateTargets(
      roots: searchRoots,
      pythonsOnPath: pythonsOnPath,
    );
    if (targets.isEmpty) {
      return lastResult = SidecarLaunchResult(
        ok: false,
        message: 'No sidecar script and no Python were found. Install '
            'Python 3 (python.org) or use a packaged build with the engine '
            'included.',
      );
    }

    String? lastReason;
    // Resolved once: a start that fails still deserves somewhere to say so.
    final log = logPath ?? _logFilePath();
    _logPath = log;
    var warnings = <String>[];

    for (final target in targets) {
      // The bundled exe needs no verification: it IS the engine.
      if (target.method != 'bundled exe') {
        if (!await verify(target)) {
          lastReason = '"${target.command}" is not a working Python 3 '
              '(the Windows Store placeholder does not count).';
          continue;
        }
        final missing = await missingRpaDependencies(target);
        if (missing != null) {
          // The sidecar still serves /health and generates .pkt files
          // without these, so this is a warning, not a failure.
          warnings = [...warnings, missing];
        }
      }
      _autoRestart = true;
      final pid = await _spawn(target, log);
      if (pid == null) {
        lastReason = 'Could not start "${target.command}".';
        continue;
      }
      final warning = warnings.isEmpty ? '' : ' GUI runs need: ${warnings.first}';
      return lastResult = SidecarLaunchResult(
        ok: true,
        method: target.method,
        command: target.commandLine,
        pid: pid,
        logPath: log,
        message: 'Started the local engine (${target.method}).$warning',
      );
    }

    return lastResult = SidecarLaunchResult(
      ok: false,
      message: lastReason ??
          'No Python interpreter could be started. Install Python 3 from '
              'python.org and tick "Add python.exe to PATH".',
      logPath: log,
    );
  }

  static Future<int?> _spawn(SidecarTarget target, String logPath) async {
    try {
      final environment = <String, String>{
        ...Platform.environment,
        // Unbuffered so the log is useful the moment something goes wrong.
        'PYTHONUNBUFFERED': '1',
        'PYTHONIOENCODING': 'utf-8',
      };
      if (target.tesseract != null) {
        environment['TESSERACT_CMD'] = target.tesseract!;
      }
      final process = await Process.start(
        target.command,
        target.arguments,
        workingDirectory: target.workingDirectory,
        environment: environment,
        runInShell: false,
      );
      _process = process;
      await _pump(
        process.stdout,
        logPath,
        tag: 'out',
      );
      await _pump(
        process.stderr,
        logPath,
        tag: 'err',
      );
      unawaited(process.exitCode.then(_onExit));
      return process.pid;
    } catch (e) {
      _appendLog(logPath, 'launch failed: $e\n');
      return null;
    }
  }

  static Future<void> _pump(
    Stream<List<int>> stream,
    String logPath, {
    required String tag,
  }) async {
    final sub = stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) => _appendLog(logPath, chunk));
    if (tag == 'out') {
      _stdoutSub = sub;
    } else {
      _stderrSub = sub;
    }
    unawaited(sub.asFuture<void>().catchError((_) {}));
  }

  /// The engine died. Put it back, but only a bounded number of times so a
  /// genuinely broken install does not spin forever behind the user's back.
  static Future<void> _onExit(int code) async {
    final log = _logPath;
    if (log != null) _appendLog(log, '\n[engine exited with code $code]\n');
    _process = null;
    unawaited(_stdoutSub?.cancel());
    unawaited(_stderrSub?.cancel());
    _stdoutSub = null;
    _stderrSub = null;
    if (!_autoRestart || restarts >= maxRestarts) return;
    restarts++;
    await Future<void>.delayed(Duration(seconds: 2 * restarts));
    if (!_autoRestart) return;
    await ensureStarted(force: true);
  }

  /// Stop the engine this app started. Nothing happens when the engine was
  /// started by hand (or is on another machine) - that is not ours to kill.
  static Future<void> stop() async {
    _autoRestart = false;
    final process = _process;
    _process = null;
    if (process == null) return;
    try {
      final log = _logPath;
      if (log != null) _appendLog(log, '\n[stopping the engine]\n');
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5),
          onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      });
    } catch (_) {}
  }

  /// Lets a later start try again after a user-initiated stop.
  static void allowAutoRestart() {
    _autoRestart = true;
    restarts = 0;
  }

  /// Where the engine's output goes. Always a real path: "the log is
  /// somewhere else" is not a useful answer when a start has just failed.
  static String _logFilePath() {
    final home = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    final fallback = p.join(Directory.systemTemp.path, 'netbuilder-engine.log');
    try {
      final dir = Directory(p.join(home, 'NetBuilderAI', 'logs'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return p.join(dir.path, 'engine.log');
    } catch (_) {
      return fallback;
    }
  }

  static void _appendLog(String? path, String text) {
    if (path == null) return;
    _logPath = path;
    try {
      final file = File(path);
      // Keep it small: this is a diagnosis aid, not an archive.
      if (file.existsSync() && file.lengthSync() > 2 * 1024 * 1024) {
        file.writeAsStringSync('[log trimmed]\n');
      }
      file.writeAsStringSync(text, mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  static String? _bundledTesseract(String root) {
    final bundled = p.join(root, 'tesseract', 'tesseract.exe');
    return File(bundled).existsSync() ? bundled : null;
  }

  /// Where to look for `sidecar/`: a packaged build puts it beside the exe,
  /// a development run has it one level up from `app/`. Public because the
  /// diagnostics card reports where the app actually looked.
  static List<String> searchRoots() {
    final roots = <String>[];
    var cursor = p.dirname(Platform.resolvedExecutable);
    for (var depth = 0; depth < 7; depth++) {
      roots.add(cursor);
      final parent = p.dirname(cursor);
      if (parent == cursor) break;
      cursor = parent;
    }
    // Also try relative to the current directory (flutter run from app/).
    var here = Directory.current.path;
    for (var depth = 0; depth < 3; depth++) {
      roots.add(here);
      final parent = p.dirname(here);
      if (parent == here) break;
      here = parent;
    }
    return roots.toSet().toList();
  }
}

/// One way of launching the sidecar.
class SidecarTarget {
  final String command;
  final List<String> arguments;
  final String workingDirectory;
  final String method;
  final String? tesseract;
  final bool isWindowsLauncher;

  const SidecarTarget({
    required this.command,
    required this.arguments,
    required this.workingDirectory,
    required this.method,
    this.tesseract,
    this.isWindowsLauncher = false,
  });

  /// `py -3 <script>` takes its flags BEFORE the script, so a probe has to
  /// drop the script argument and keep the flags.
  List<String> get argumentsForProbe => isWindowsLauncher
      ? arguments.where((a) => a.startsWith('-')).toList()
      : const [];

  String get commandLine => [command, ...arguments].join(' ');
}
