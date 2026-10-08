import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'settings_service.dart';

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

  /// Whether this platform can run the engine at all.
  ///
  /// The engine is Python that drives a Packet Tracer window. A phone has no
  /// Python process to start and no Packet Tracer to drive, so looking for one
  /// there produced the worst possible answer - "install Python 3" - instead
  /// of the true one: the engine lives on the PC, point the app at it.
  ///
  /// One source of truth for that fact ([SettingsService.canHostEngine]), so a
  /// phone cannot be a phone in one place and a desktop in another.
  static bool get canRunLocally => SettingsService.canHostEngine;

  /// The one sentence a phone user needs, used by every caller so the wording
  /// cannot drift.
  static const String phoneEngineMessage =
      'This device runs no engine of its own. The .pkt engine is a PC '
      'program: start it on the PC (python pt_autopilot.py) and set this app\'s '
      'engine address to that PC - for example http://192.168.1.20:5005. On the '
      'Android emulator the host is 10.0.2.2.';

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
  ///
  /// Synchronous, and kept so. It blocks on `where.exe`, so the LAUNCH path
  /// must not use it - see [pathInterpretersAsync]. Tests and any caller that
  /// already knows the list keep working unchanged.
  static List<String> pathInterpreters([List<String>? override]) {
    final raw = override ?? _where(_pathNames);
    return _filterInterpreters(raw);
  }

  /// The same list as [pathInterpreters], without blocking the UI isolate.
  ///
  /// This is what the launch path uses. `Process.runSync` BLOCKS the calling
  /// isolate until the child exits, so looking up PATH on the UI isolate froze
  /// the frame for the length of four process spawns - on the only path every
  /// desktop user takes, before the app has drawn anything. `where.exe` is
  /// cheap when the disk is warm and can be very slow the first time an
  /// antivirus or a cold cache gets to it, and there is no partial-frame
  /// benefit to paying that on the UI thread.
  ///
  /// The four lookups run CONCURRENTLY, but the results are flattened in the
  /// original name order, so the candidate list is byte-for-byte what
  /// [pathInterpreters] returns. Order decides which interpreter
  /// [candidateTargets] offers first, and `_start` takes the first one that
  /// verifies, so this is load-bearing and deliberately preserved.
  static Future<List<String>> pathInterpretersAsync([
    List<String>? override,
  ]) async {
    if (override != null) return _filterInterpreters(override);
    final raw = await (_pathScan ??= _whereAsync(_pathNames).whenComplete(() {
      _pathScan = null;
    }));
    return _filterInterpreters(raw);
  }

  /// Names probed on PATH, most preferred first. One list so the sync and
  /// async lookups can never drift into probing different sets.
  static const List<String> _pathNames = [
    'pythonw.exe',
    'python.exe',
    'python3',
    'python',
  ];

  /// In-flight PATH scan, shared so two launches do not spawn eight
  /// `where.exe` processes between them. Cleared when the scan settles.
  static Future<List<String>>? _pathScan;

  /// How many PATH scans have actually run.
  ///
  /// The memo above is an optimisation nobody can see: two callers get the
  /// same list whether they shared one scan or each spawned four processes,
  /// so a test asserting only the results passes with the memo deleted. This
  /// counter is what makes "they shared" an assertable fact instead of a
  /// claim in a comment.
  @visibleForTesting
  static int pathScanCount = 0;

  /// The one filtering rule, shared by both lookups. Trims, drops the Windows
  /// Store shims, and de-duplicates while keeping first-seen order.
  static List<String> _filterInterpreters(List<String> raw) {
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
          found.addAll(_lines(r.stdout));
        }
      } catch (_) {}
    }
    return found;
  }

  /// [_where] without the blocking call.
  ///
  /// Each name is probed concurrently; [Future.wait] hands the results back in
  /// the order they were started, and flattening in that order reproduces
  /// [_where]'s sequential output exactly. A name that cannot be spawned, or
  /// that is simply not on PATH, contributes nothing - the same silent skip
  /// [_where] has always made, because "not installed" is the normal case here
  /// rather than an error worth surfacing.
  static Future<List<String>> _whereAsync(List<String> names) async {
    pathScanCount++;
    final perName = await Future.wait(names.map((name) async {
      try {
        final r = await Process.run('where.exe', [name], runInShell: false)
            .timeout(const Duration(seconds: 5));
        if (r.exitCode != 0) return <String>[];
        return _lines(r.stdout);
      } catch (_) {
        return <String>[];
      }
    }));
    return [for (final group in perName) ...group];
  }

  static List<String> _lines(Object? stdout) => stdout
      .toString()
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

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
    // A phone cannot host the engine. Saying so immediately is both the truth
    // and the only useful answer - the alternative was searching a filesystem
    // for Python that cannot exist there.
    if (!canRunLocally) {
      return Future.value(
        lastResult = const SidecarLaunchResult(
          ok: false,
          method: 'phone',
          message: phoneEngineMessage,
        ),
      );
    }
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
    // Resolved BEFORE discovery, and asynchronously: `candidateTargets` stays
    // pure and synchronous, while the one thing in here that costs a process
    // spawn per name happens off the UI isolate. Passing the resolved list in
    // also means the PATH scan cannot run twice for one start.
    final targets = candidateTargets(
      roots: searchRoots,
      pythonsOnPath: pythonsOnPath ?? await pathInterpretersAsync(),
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

  /// The engine executable this build ships, or null when there is none (a
  /// dev run against a checkout, or a phone).
  static String? bundledEngineFile({List<String>? roots}) {
    for (final root in roots ?? searchRoots()) {
      final exe = p.join(root, 'sidecar', 'pt_autopilot.exe');
      if (File(exe).existsSync()) return exe;
    }
    return null;
  }

  /// When a file was written, in milliseconds - the same scale the engine
  /// reports about itself, so the two numbers can be compared directly.
  static int? fileBuiltAt(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return file.statSync().modified.millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  /// The pid of whatever is LISTENING on a loopback port.
  ///
  /// The app talks to `127.0.0.1:5005` without caring who started the process
  /// behind it - and that is exactly how an engine from an older build keeps
  /// answering after the app has been updated, serving the old behaviour and
  /// making a fix look like it never happened. This is how the app finds the
  /// stray process it has to replace. Null when nothing is listening (or the
  /// platform will not say).
  static Future<int?> pidListeningOnPort(int port) async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('netstat.exe', ['-ano'], runInShell: false)
            .timeout(const Duration(seconds: 5));
        if (r.exitCode != 0) return null;
        return listeningPid('${r.stdout}', port);
      }
      final r = await Process.run('lsof', ['-ti', 'tcp:$port'],
          runInShell: false).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      return int.tryParse('${r.stdout}'.trim().split(RegExp(r'\s+')).first);
    } catch (_) {
      return null;
    }
  }

  /// The pid from one line of `netstat -ano` output for [port].
  ///
  /// Pure, so the parsing - the part that silently returns the wrong process -
  /// is tested against real netstat text instead of being trusted.
  static int? listeningPid(String output, int port) {
    final suffix = ':$port';
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final fields = line
          .trim()
          .split(RegExp(r'\s+'))
          .where((f) => f.isNotEmpty)
          .toList();
      // PROTO  LOCAL  FOREIGN  STATE  PID
      if (fields.length < 5) continue;
      if (!fields[1].endsWith(suffix)) continue;
      if (!fields[3].toUpperCase().contains('LISTEN')) continue;
      final pid = int.tryParse(fields.last);
      if (pid != null && pid > 0) return pid;
    }
    return null;
  }

  /// Stop a process the app did NOT start.
  ///
  /// [stop] deliberately refuses that - a hand-started engine is not ours to
  /// kill - but an engine older than the one this build ships is a different
  /// case: it is holding the port the app must use, and it will keep answering
  /// with the behaviour the user just updated away from.
  static Future<bool> stopStrayEngine(int pid) async {
    if (pid <= 0) return false;
    try {
      final log = _logPath;
      if (log != null) {
        _appendLog(log, '\n[replacing the stale engine, pid $pid]\n');
      }
      return Process.killPid(pid, ProcessSignal.sigkill);
    } catch (_) {
      return false;
    }
  }

  /// Where to look for `sidecar/`: a packaged build puts it beside the exe,
  /// a development run has it one level up from `app/`. Public because the
  /// diagnostics card reports where the app actually looked.
  static List<String> searchRoots() {
    // Nothing to find on a phone, and walking its filesystem is pure cost.
    if (!canRunLocally) return const [];
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
