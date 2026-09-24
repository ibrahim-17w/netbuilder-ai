import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'autopilot_service.dart';
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

/// The app's single source of truth about the local .pkt engine.
///
/// Two things matter here and both are performance decisions:
///
/// * A **down engine must never make the app feel slow.** Every probe has a
///   short timeout and the answer is cached for a few seconds, so a screen
///   that asks "is the engine up?" gets an instant reply instead of waiting
///   on a socket that is not there.
/// * The engine should **start itself.** [ensure] probes, and when nothing
///   answers it launches the sidecar through [SidecarSupervisor] and waits
///   for it to come up, reporting progress as it goes.
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
  String _base = 'http://127.0.0.1:5005';
  String _detail = '';
  String _version = '';
  bool _rpa = false;
  bool _ocr = false;
  String? _logPath;
  DateTime? _lastChecked;
  bool _lastAnswer = false;
  Future<bool>? _inFlight;
  DateTime? _lastStartAttempt;

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
            ? 'The local engine is not answering at $_base.'
            : _detail;
      case EngineState.unknown:
        return 'The local engine has not been checked yet.';
    }
  }

  void setBase(String base) {
    final next = base.trim();
    if (next.isEmpty || next == _base) return;
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

  /// Probe, and start the engine when nothing answers.
  ///
  /// This is the "it just works" path: the app calls it at launch and the
  /// engine is up by the time the user asks it to do something. It never
  /// throws and never blocks the caller's frame - it reports progress
  /// through [phase] instead.
  Future<bool> ensure({bool force = false}) async {
    if (await probe(force: force)) return true;
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

  /// Stop and start again, for the "it got stuck" case.
  Future<bool> restart() async {
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
      ..writeln('address: $_base')
      ..writeln('phase: ${_phase.name}')
      ..writeln('detail: $detail')
      ..writeln('version: ${_version.isEmpty ? "(unknown)" : _version}')
      ..writeln('gui automation available: $hasRpa')
      ..writeln('ocr available: $hasOcr')
      ..writeln('started by the app: ${SidecarSupervisor.weStartedIt}')
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
