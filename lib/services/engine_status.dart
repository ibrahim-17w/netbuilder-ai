import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'autopilot_service.dart';
import 'settings_service.dart';
import 'sidecar_supervisor.dart';

/// What the local engine is doing right now.
enum EngineState {
  /// Nothing has been checked yet.
  unknown,

  /// A check is in flight.
  checking,

  /// A start (or restart) is in flight.
  starting,

  /// It answered.
  up,

  /// It did not answer.
  down,
}

/// The app's single source of truth about the .pkt engine.
///
/// Two things matter here and both are performance decisions:
///
/// * A **down engine must never make the app feel slow.** Every probe has a
///   short timeout and the answer is cached for a few seconds, so a screen
///   that asks "is the engine up?" gets an instant reply instead of waiting
///   on a socket that is not there.
/// * The engine should **start itself** - but only when it is the one on this
///   machine. [ensure] probes, and when nothing answers it launches the
///   sidecar through [SidecarSupervisor] and waits for it to come up,
///   reporting progress as it goes. A configured address on another host is
///   somebody else's process, so no local launch is attempted for it.
class EngineStatus extends ChangeNotifier {
  EngineStatus({
    Future<Map<String, dynamic>> Function(String base, Duration timeout)?
        healthProbe,
    Future<SidecarLaunchResult> Function()? launcher,
    this.cacheWindow = const Duration(seconds: 4),
    this.probeTimeout = const Duration(milliseconds: 1800),
    this.startWait = const Duration(seconds: 25),
  })  : _healthProbe = healthProbe ?? _defaultProbe,
        _launcher = launcher ?? SidecarSupervisor.ensureStarted;

  /// The app-wide instance. Tests build their own with fakes.
  static final EngineStatus instance = EngineStatus();

  final Future<Map<String, dynamic>> Function(String base, Duration timeout)
      _healthProbe;
  final Future<SidecarLaunchResult> Function() _launcher;

  /// How long a probe result is trusted before it is asked again.
  final Duration cacheWindow;

  /// How long a single health request may take. Loopback answers in
  /// milliseconds; anything longer than this means "not there".
  final Duration probeTimeout;

  /// How long to wait for a freshly started engine to answer.
  final Duration startWait;

  EngineState _phase = EngineState.unknown;
  String _base = SettingsService.defaultEngineBase();
  String _detail = '';
  String _version = '';
  bool _rpa = false;
  bool _ocr = false;
  String? _logPath;
  DateTime? _lastChecked;
  bool _lastAnswer = false;
  Future<bool>? _inFlight;
  DateTime? _lastStartAttempt;

  /// What the engine answering says about itself (its own file, when that file
  /// was written, its pid, its layout revision). Empty for an engine built
  /// before it reported any of that - which is itself the answer: it is older
  /// than this build.
  Map<String, dynamic> _engine = const {};

  /// One swap per run: an engine that answers again stays.
  bool _staleSwapDone = false;

  EngineState get phase => _phase;
  String get base => _base;
  String get detail => _detail;
  String get version => _version;

  /// Whether the engine can drive the Packet Tracer window. Offline .pkt
  /// generation and auditing work even when this is false.
  bool get hasRpa => _rpa;
  bool get hasOcr => _ocr;
  String? get logPath => _logPath ?? SidecarSupervisor.logPath;
  bool get isUp => _phase == EngineState.up;
  bool get isDown => _phase == EngineState.down;

  /// False on a phone: there is no engine process to start here, so the UI
  /// must not offer a button that cannot work.
  bool get canStartLocally => SidecarSupervisor.canRunLocally;

  /// Shown instead of a start attempt when the configured engine is on
  /// another machine. Says the one thing that can be done about it.
  String get remoteEngineMessage =>
      'The engine is configured at $_base, which is not this machine. This app '
      'does not start a second engine here - start the sidecar on that host, '
      'or set the address back to ${SettingsService.defaultEngineBase()}.';

  /// Whether the configured engine is a process on THIS machine. A remote
  /// host is somebody else's sidecar: the app can talk to it, but it must
  /// never start or stop a local process on its behalf.
  bool get isLocalEngine => SettingsService.isLoopbackEngineBase(_base);
  bool get isBusy =>
      _phase == EngineState.checking || _phase == EngineState.starting;
  DateTime? get lastChecked => _lastChecked;

  /// A short line for a banner: never a stack trace.
  String get summary {
    switch (_phase) {
      case EngineState.up:
        final bits = <String>[
          if (_version.isNotEmpty) 'v$_version',
          if (_rpa) 'GUI automation' else 'offline only',
          if (_ocr) 'OCR',
        ];
        return 'Local engine is running${bits.isEmpty ? '' : ' (${bits.join(', ')})'}.';
      case EngineState.checking:
        return 'Checking the local engine...';
      case EngineState.starting:
        return 'Starting the local engine...';
      case EngineState.down:
        return _detail.isEmpty
            ? 'The engine is not answering at $_base.'
            : _detail;
      case EngineState.unknown:
        return 'The engine has not been checked yet.';
    }
  }

  void setBase(String base) {
    // The saved address arrives normalized from SettingsService; normalize
    // again so a caller passing a bare host still probes the address the app
    // would actually call.
    final next = SettingsService.engineBaseOr(base, fallback: _base);
    if (next == _base) return;
    _base = next;
    _phase = EngineState.unknown;
    _lastChecked = null;
    _detail = '';
    notifyListeners();
  }

  /// Fast, cached liveness. Pass `force: true` for a user-initiated recheck.
  Future<bool> probe({bool force = false}) {
    final cachedFresh = _lastChecked != null &&
        DateTime.now().difference(_lastChecked!) < cacheWindow;
    if (!force && cachedFresh && _phase != EngineState.unknown) {
      return Future.value(_lastAnswer);
    }
    return _inFlight ??= _runProbe().whenComplete(() => _inFlight = null);
  }

  Future<bool> _runProbe() async {
    _phase = EngineState.checking;
    notifyListeners();
    try {
      final health = await _healthProbe(_base, probeTimeout);
      _lastAnswer = health['ok'] == true;
      _version = (health['version'] ?? '').toString();
      _rpa = health['rpa'] == true;
      _ocr = health['ocr'] == true;
      _engine = (health['engine'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      _phase = _lastAnswer ? EngineState.up : EngineState.down;
      if (!_lastAnswer) {
        _detail = 'The local engine answered, but reported a problem.';
      } else {
        _detail = '';
      }
    } catch (e) {
      _lastAnswer = false;
      _phase = EngineState.down;
      _detail = 'Nothing is answering at $_base.';
      _lastError = '$e';
    }
    _lastChecked = DateTime.now();
    notifyListeners();
    return _lastAnswer;
  }

  String _lastError = '';

  /// The last transport error, for the diagnostics card.
  String get lastError => _lastError;

  /// Probe, and start the engine when nothing answers AND the configured
  /// engine is this machine's.
  ///
  /// This is the "it just works" path: the app calls it at launch and the
  /// engine is up by the time the user asks it to do something. It never
  /// throws and never blocks the caller's frame - it reports progress
  /// through [phase] instead.
  Future<bool> ensure({bool force = false}) async {
    if (await probe(force: force)) return _replaceStaleEngineIfAny();
    // On a phone the engine is a PC program. Trying to start one here is not a
    // long shot, it is impossible - and the message has to say what to do
    // instead, not what is missing.
    if (!canStartLocally) {
      _phase = EngineState.down;
      _lastAnswer = false;
      _detail = SidecarSupervisor.phoneEngineMessage;
      _lastChecked = DateTime.now();
      notifyListeners();
      return false;
    }
    // The user pointed the app at another machine. That engine is theirs to
    // start; spawning a local sidecar here would be a second engine nobody
    // asked for, on a different address from the configured one.
    if (!isLocalEngine) {
      _phase = EngineState.down;
      _lastAnswer = false;
      _detail = remoteEngineMessage;
      _lastChecked = DateTime.now();
      notifyListeners();
      return false;
    }
    if (!force &&
        _lastStartAttempt != null &&
        DateTime.now().difference(_lastStartAttempt!) <
            const Duration(seconds: 20)) {
      // A start was just tried and failed. Re-spawning on every screen
      // would hammer the machine; the user has a button for that.
      return false;
    }
    _lastStartAttempt = DateTime.now();
    _phase = EngineState.starting;
    notifyListeners();

    final launch = await _launcher();
    _logPath = launch.logPath ?? _logPath;
    if (!launch.ok) {
      _phase = EngineState.down;
      _lastAnswer = false;
      _detail = launch.message;
      _lastChecked = DateTime.now();
      notifyListeners();
      return false;
    }

    // Wait for it to answer, polling faster than the cache window so a warm
    // start is not padded with a needless delay.
    final deadline = DateTime.now().add(startWait);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (await probe(force: true)) {
        _detail = launch.message;
        return true;
      }
    }
    _phase = EngineState.down;
    _detail = 'The engine was started but never answered at $_base. '
        '${launch.message}';
    _lastChecked = DateTime.now();
    notifyListeners();
    return false;
  }

  /// What the engine answering reported about itself (see [_engine]).
  Map<String, dynamic> get engineIdentity => _engine;

  /// The engine's File Modification time, in milliseconds, as it reported it.
  int get engineBuiltAt => (_engine['builtAt'] as num?)?.toInt() ?? 0;

  /// Whether the engine that is answering is an OLDER build than the one this
  /// app ships.
  bool get engineIsStale => EngineStatus.isStaleEngine(
        identity: _engine,
        bundledFile: SidecarSupervisor.bundledEngineFile(),
        bundledBuiltAt: SidecarSupervisor.fileBuiltAt(
          SidecarSupervisor.bundledEngineFile(),
        ),
      );

  /// Is the engine answering an older copy than the one this build ships?
  ///
  /// The app talks to whatever answers on the engine address, whoever started
  /// it. After an update that is often the process from the PREVIOUS version,
  /// still serving the old code - which is exactly how a fixed .pkt layout
  /// came out of a build looking unchanged, twice. Three rules, all of them
  /// conservative:
  ///
  /// * no engine is shipped here (a dev checkout, a phone): nothing to compare,
  ///   so whatever answers is the one to use;
  /// * an engine that reports NO identity predates the field - it is older than
  ///   any build that reports one;
  /// * a reported identity is only judged when it names this app's own engine
  ///   file. A sidecar someone started by hand from a checkout is not ours to
  ///   replace, however old it is.
  static bool isStaleEngine({
    required Map<String, dynamic> identity,
    required String? bundledFile,
    required int? bundledBuiltAt,
  }) {
    if (bundledFile == null || bundledBuiltAt == null) return false;
    final runningFile = '${identity['file'] ?? ''}'.trim();
    final runningBuiltAt = (identity['builtAt'] as num?)?.toInt() ?? 0;
    if (runningFile.isEmpty || runningBuiltAt <= 0) return true;
    if (!sameFile(runningFile, bundledFile)) return false;
    // A second of slack: the two numbers are file times, not a clock exchange.
    return runningBuiltAt < bundledBuiltAt - 1000;
  }

  /// Two paths naming the same file. Case- and separator-insensitive, because
  /// one side may come from the engine's own environment and the other from
  /// this app's.
  static bool sameFile(String a, String b) {
    String norm(String value) => value
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/{2,}'), '/')
        .toLowerCase();
    return norm(a) == norm(b);
  }

  /// The port the configured engine address uses, for finding its process.
  int get enginePort => Uri.tryParse(_base)?.port ?? 0;

  /// Replace an engine older than the one this build ships, once per run.
  ///
  /// Called after a successful probe. Nothing is killed unless the answer came
  /// from this app's own engine file, and the replacement is only believed when
  /// a fresh engine answers on the same address; anything else leaves the
  /// running engine alone and says what the user can do instead.
  Future<bool> _replaceStaleEngineIfAny() async {
    if (_staleSwapDone || !isLocalEngine || !engineIsStale) return true;
    _staleSwapDone = true;
    final pid = (_engine['pid'] as num?)?.toInt() ??
        await SidecarSupervisor.pidListeningOnPort(enginePort);
    if (pid == null || pid <= 0) {
      _detail =
          'The engine answering at $_base is an older build than the one this '
          'app ships, and its process could not be found to replace it. Stop '
          'it and start the engine again to pick up the update.';
      notifyListeners();
      return true;
    }
    _phase = EngineState.starting;
    _detail = 'Replacing an engine older than the one this app ships...';
    notifyListeners();
    await SidecarSupervisor.stopStrayEngine(pid);
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!await probe(force: true)) break;
    }
    _lastChecked = null;
    _lastAnswer = false;
    _phase = EngineState.unknown;
    _engine = const {};
    SidecarSupervisor.allowAutoRestart();
    return ensure(force: true);
  }

  /// Stop and start again, for the "it got stuck" case.
  ///
  /// A restart is a local-process operation, so it is refused for a remote
  /// engine exactly like a start is: there is no local process to cycle.
  Future<bool> restart() async {
    if (!isLocalEngine) {
      _phase = EngineState.down;
      _lastAnswer = false;
      _detail = remoteEngineMessage;
      _lastChecked = DateTime.now();
      notifyListeners();
      return false;
    }
    _phase = EngineState.starting;
    notifyListeners();
    await SidecarSupervisor.stop();
    SidecarSupervisor.allowAutoRestart();
    _lastStartAttempt = null;
    _lastChecked = null;
    _phase = EngineState.unknown;
    return ensure(force: true);
  }

  /// Stop the engine this app started.
  Future<void> stop() async {
    if (!isLocalEngine) {
      _lastChecked = null;
      _lastAnswer = false;
      _phase = EngineState.down;
      _detail = remoteEngineMessage;
      notifyListeners();
      return;
    }
    await SidecarSupervisor.stop();
    _lastChecked = null;
    _lastAnswer = false;
    _phase = EngineState.down;
    _detail = 'The local engine was stopped.';
    notifyListeners();
  }

  /// The tail of the engine's own log - the only way to explain a start that
  /// died before it could say anything.
  Future<String> readLogTail({int lines = 60}) async {
    final path = logPath;
    if (path == null || !File(path).existsSync()) {
      return 'No engine log yet. It is written the first time the app '
          'starts the engine itself.';
    }
    try {
      final text = await File(path).readAsString();
      final all = text.split(RegExp(r'\r?\n'));
      if (all.length <= lines) return text;
      return all.sublist(all.length - lines).join('\n');
    } catch (e) {
      return 'Could not read $path: $e';
    }
  }

  /// A copyable block for a bug report.
  Future<String> diagnose() async {
    final buffer = StringBuffer()
      ..writeln('NetBuilder AI - local engine report')
      ..writeln('platform: ${defaultTargetPlatform.name}')
      ..writeln('can host the engine here: $canStartLocally')
      ..writeln('address: $_base')
      ..writeln('engine is on this machine: $isLocalEngine')
      ..writeln('phase: ${_phase.name}')
      ..writeln('detail: $detail')
      ..writeln('version: ${_version.isEmpty ? "(unknown)" : _version}')
      ..writeln('gui automation available: $hasRpa')
      ..writeln('ocr available: $hasOcr')
      ..writeln('started by the app: ${SidecarSupervisor.weStartedIt}')
      ..writeln('engine file: ${_engine['file'] ?? "(not reported)"}')
      ..writeln('engine built: ${engineBuiltAt == 0 ? "(not reported)" : engineBuiltAt}')
      ..writeln('layout revision: ${_engine['layoutRevision'] ?? "(not reported)"}')
      ..writeln('older than the shipped engine: $engineIsStale')
      ..writeln('last start: ${SidecarSupervisor.lastResult?.method ?? "-"}')
      ..writeln('log: ${logPath ?? "(none)"}')
      ..writeln('last transport error: ${_lastError.isEmpty ? "-" : _lastError}')
      ..writeln()
      ..writeln('--- log tail ---')
      ..writeln(await readLogTail(lines: 40));
    return buffer.toString();
  }

  static Future<Map<String, dynamic>> _defaultProbe(
    String base,
    Duration timeout,
  ) =>
      AutopilotService(base: base).healthDetails(timeout: timeout);
}
