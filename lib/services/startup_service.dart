import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_diagnostics.dart';
import 'credential_redaction.dart';

/// Where one startup subsystem is in its lifecycle.
enum StartupPhase { loading, ready, failed }

/// One independently-loaded piece of app startup.
@immutable
class StartupStatus {
  final String id;
  final String label;
  final StartupPhase phase;

  /// Why a failed subsystem is using safe defaults. Empty when ready.
  final String detail;

  /// How long the subsystem took (or how long the timeout took to fire).
  final int elapsedMs;

  const StartupStatus({
    required this.id,
    required this.label,
    this.phase = StartupPhase.loading,
    this.detail = '',
    this.elapsedMs = 0,
  });

  bool get isLoading => phase == StartupPhase.loading;
  bool get isReady => phase == StartupPhase.ready;
  bool get isFailed => phase == StartupPhase.failed;

  StartupStatus copyWith({
    StartupPhase? phase,
    String? detail,
    int? elapsedMs,
  }) => StartupStatus(
    id: id,
    label: label,
    phase: phase ?? this.phase,
    detail: detail ?? this.detail,
    elapsedMs: elapsedMs ?? this.elapsedMs,
  );
}

/// An immutable view of all startup work, suitable for a ValueListenable.
@immutable
class StartupSnapshot {
  final List<StartupStatus> statuses;

  const StartupSnapshot(this.statuses);

  StartupStatus? statusOf(String id) {
    for (final status in statuses) {
      if (status.id == id) return status;
    }
    return null;
  }

  bool get isLoading => statuses.any((status) => status.isLoading);
  bool get isReady => statuses.every((status) => status.isReady);
  bool get isDegraded => statuses.any((status) => status.isFailed);

  List<String> get loadingLabels => [
    for (final status in statuses)
      if (status.isLoading) status.label,
  ];

  List<String> get failedLabels => [
    for (final status in statuses)
      if (status.isFailed) status.label,
  ];

  List<String> get details => [
    for (final status in statuses)
      if (status.isFailed && status.detail.isNotEmpty)
        '${status.label}: ${status.detail}',
  ];
}

/// Loads settings, memory, build history and the app version without holding
/// the first frame hostage.
///
/// Each subsystem has its own deadline. A hung keychain or a locked database
/// becomes a visible degraded state with safe defaults; it never prevents the
/// shell from painting, and it never leaves the rest of startup waiting.
class StartupCoordinator extends ValueNotifier<StartupSnapshot> {
  StartupCoordinator({this.timeout = const Duration(seconds: 8)})
    : super(
        const StartupSnapshot([
          StartupStatus(
            id: 'settings',
            label: 'Settings',
            phase: StartupPhase.loading,
          ),
          StartupStatus(
            id: 'memory',
            label: 'Memory',
            phase: StartupPhase.loading,
          ),
          StartupStatus(
            id: 'history',
            label: 'Build history',
            phase: StartupPhase.loading,
          ),
          StartupStatus(
            id: 'version',
            label: 'App version',
            phase: StartupPhase.loading,
          ),
        ]),
      );

  final Duration timeout;
  bool _started = false;

  /// Start all four loads in parallel. Calling this more than once is a no-op.
  Future<void> start({
    required Future<void> Function() settings,
    required Future<void> Function() memory,
    required Future<void> Function() history,
    required Future<void> Function() version,
  }) async {
    if (_started) return;
    _started = true;
    await Future.wait([
      _run('settings', settings),
      _run('memory', memory),
      _run('history', history),
      _run('version', version),
    ]);
  }

  Future<void> _run(String id, Future<void> Function() task) async {
    final watch = Stopwatch()..start();
    try {
      await task().timeout(timeout);
      _complete(id, StartupPhase.ready, '', watch.elapsedMilliseconds);
    } on TimeoutException {
      _complete(
        id,
        StartupPhase.failed,
        'Timed out after ${timeout.inSeconds}s; using safe defaults.',
        watch.elapsedMilliseconds,
      );
    } catch (error) {
      _complete(
        id,
        StartupPhase.failed,
        'Using safe defaults: ${_safe(error)}',
        watch.elapsedMilliseconds,
      );
    }
  }

  void _complete(String id, StartupPhase phase, String detail, int elapsedMs) {
    final next = [
      for (final status in value.statuses)
        if (status.id == id)
          status.copyWith(phase: phase, detail: detail, elapsedMs: elapsedMs)
        else
          status,
    ];
    value = StartupSnapshot(next);
    debugPrint(
      '[startup] $id ${phase.name} in ${elapsedMs}ms'
      '${detail.isEmpty ? '' : ': $detail'}',
    );
    if (phase == StartupPhase.failed && AppDiagnostics.instance.installed) {
      debugPrint('[startup] recording $id failure in the local diagnostics log');
      unawaited(
        AppDiagnostics.instance.record(
          'startup/$id',
          detail.isEmpty ? 'startup failed' : detail,
        ),
      );
    }
  }

  static String _safe(Object error) {
    final text = CredentialRedaction.redact(error.toString());
    return text.length <= 300 ? text : '${text.substring(0, 300)}...';
  }
}
