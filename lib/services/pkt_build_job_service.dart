import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pkt/on_device_pkt_builder.dart';

enum PktBuildJobStatus { idle, running, ready, failed, cancelled, saved }

/// A durable summary of one generated Packet Tracer file.
///
/// The file itself stays where the builder wrote it. History stores only the
/// local path and a few useful details so the person can reopen or export it.
@immutable
class PktBuildJobEntry {
  final String id;
  final String project;
  final PktBuildJobStatus status;
  final String stage;
  final String error;
  final String filePath;
  final String savedLocation;
  final DateTime updatedAt;
  final int deviceCount;
  final int linkCount;
  final int? sourceRecordId;
  final String planRevision;
  final String planJson;
  final String target;
  final bool dismissed;

  const PktBuildJobEntry({
    required this.id,
    required this.project,
    required this.status,
    required this.stage,
    required this.error,
    required this.filePath,
    required this.savedLocation,
    required this.updatedAt,
    required this.deviceCount,
    required this.linkCount,
    this.sourceRecordId,
    this.planRevision = '',
    this.planJson = '',
    this.target = 'packet-tracer',
    this.dismissed = false,
  });

  PktBuildJobEntry copyWith({
    PktBuildJobStatus? status,
    String? stage,
    String? error,
    String? filePath,
    String? savedLocation,
    DateTime? updatedAt,
    int? deviceCount,
    int? linkCount,
    int? sourceRecordId,
    String? planRevision,
    String? planJson,
    String? target,
    bool? dismissed,
  }) => PktBuildJobEntry(
    id: id,
    project: project,
    status: status ?? this.status,
    stage: stage ?? this.stage,
    error: error ?? this.error,
    filePath: filePath ?? this.filePath,
    savedLocation: savedLocation ?? this.savedLocation,
    updatedAt: updatedAt ?? this.updatedAt,
    deviceCount: deviceCount ?? this.deviceCount,
    linkCount: linkCount ?? this.linkCount,
    sourceRecordId: sourceRecordId ?? this.sourceRecordId,
    planRevision: planRevision ?? this.planRevision,
    planJson: planJson ?? this.planJson,
    target: target ?? this.target,
    dismissed: dismissed ?? this.dismissed,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'project': project,
    'status': status.name,
    'stage': stage,
    'error': error,
    'filePath': filePath,
    'savedLocation': savedLocation,
    'updatedAt': updatedAt.toIso8601String(),
    'deviceCount': deviceCount,
    'linkCount': linkCount,
    if (sourceRecordId != null) 'sourceRecordId': sourceRecordId,
    if (planRevision.isNotEmpty) 'planRevision': planRevision,
    if (planJson.isNotEmpty) 'planJson': planJson,
    'target': target,
    'dismissed': dismissed,
  };

  factory PktBuildJobEntry.fromJson(Map<String, dynamic> json) {
    final statusName = json['status'] as String? ?? 'failed';
    final status = PktBuildJobStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () => PktBuildJobStatus.failed,
    );
    return PktBuildJobEntry(
      id: json['id'] as String? ?? '',
      project: json['project'] as String? ?? 'Network design',
      status: status,
      stage: json['stage'] as String? ?? '',
      error: json['error'] as String? ?? '',
      filePath: json['filePath'] as String? ?? '',
      savedLocation: json['savedLocation'] as String? ?? '',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      deviceCount: (json['deviceCount'] as num?)?.toInt() ?? 0,
      linkCount: (json['linkCount'] as num?)?.toInt() ?? 0,
      sourceRecordId: (json['sourceRecordId'] as num?)?.toInt(),
      planRevision: json['planRevision'] as String? ?? '',
      planJson: json['planJson'] as String? ?? '',
      target: json['target'] as String? ?? 'packet-tracer',
      dismissed: json['dismissed'] == true,
    );
  }
}

/// App-wide build state plus a small durable history for generated .pkt files.
/// The active job can outlive its screen, and its outcome survives app restarts.
class PktBuildJobService extends ChangeNotifier {
  PktBuildJobService._();

  @visibleForTesting
  PktBuildJobService.createForTesting() : this._();

  static final PktBuildJobService instance = PktBuildJobService._();
  static const _storageKey = 'netbuilder.pkt_build_jobs.v1';
  static const _historyLimit = 30;

  PktBuildJobStatus _status = PktBuildJobStatus.idle;
  PktBuildJobStatus get status => _status;
  String _project = '';
  String get project => _project;
  String _stage = '';
  String get stage => _stage;
  double? _progress = 0;
  double? get progress => _progress;
  String _error = '';
  String get error => _error;
  String _savedLocation = '';
  String get savedLocation => _savedLocation;
  OnDeviceBuild? _result;
  OnDeviceBuild? get result => _result;
  bool _cancelRequested = false;
  bool get cancelRequested => _cancelRequested;
  Future<OnDeviceBuild?>? _activeRun;
  Future<void> _writes = Future<void>.value();
  final List<PktBuildJobEntry> _history = [];
  List<PktBuildJobEntry> get history => List.unmodifiable(_history);
  bool _historyLoaded = false;
  bool get historyLoaded => _historyLoaded;
  String? _currentJobId;
  int? _sourceRecordId;
  String _planRevision = '';
  String _planJson = '';
  String _target = 'packet-tracer';

  Future<OnDeviceBuild?> Function(
    void Function(String stage, double? progress) report,
  )?
  _lastBuild;

  Future<void> loadHistory() async {
    if (_historyLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_storageKey);
      if (stored != null && stored.isNotEmpty) {
        final decoded = jsonDecode(stored);
        if (decoded is List) {
          _history
            ..clear()
            ..addAll(
              decoded.whereType<Map>().map(
                (entry) =>
                    PktBuildJobEntry.fromJson(Map<String, dynamic>.from(entry)),
              ),
            );
        }
      }
      for (var i = 0; i < _history.length; i++) {
        final entry = _history[i];
        if (entry.status == PktBuildJobStatus.running) {
          _history[i] = entry.copyWith(
            status: PktBuildJobStatus.failed,
            stage: 'Build interrupted',
            error: 'The app closed before this build finished.',
            updatedAt: DateTime.now(),
          );
        }
      }
      _sortAndTrim();
      PktBuildJobEntry? active;
      for (final entry in _history) {
        if (!entry.dismissed) {
          active = entry;
          break;
        }
      }
      if (active != null &&
          active.status != PktBuildJobStatus.failed &&
          active.status != PktBuildJobStatus.cancelled) {
        _restoreActive(active);
      }
      _historyLoaded = true;
      _persist();
    } catch (_) {
      // A history read error must never prevent planning or building. The
      // current process can still save new history once preferences recover.
      _historyLoaded = true;
    }
    notifyListeners();
  }

  void _restoreActive(PktBuildJobEntry entry) {
    _currentJobId = entry.id;
    _project = entry.project;
    _status = entry.status;
    _stage = entry.stage;
    _error = entry.error;
    _savedLocation = entry.savedLocation;
    _progress =
        entry.status == PktBuildJobStatus.ready ||
            entry.status == PktBuildJobStatus.saved
        ? 1
        : 0;
    if (entry.filePath.isEmpty) return;
    final file = File(entry.filePath);
    if (!file.existsSync()) {
      _status = PktBuildJobStatus.failed;
      _stage = 'Generated file not found';
      _error = 'The saved .pkt is no longer on this device.';
      _updateCurrent(
        entry.copyWith(
          status: _status,
          stage: _stage,
          error: _error,
          updatedAt: DateTime.now(),
        ),
      );
      return;
    }
    final manifest = File('${entry.filePath}.netbuilder.json');
    _result = OnDeviceBuild(
      file: file,
      xml: '',
      refIds: const {},
      warnings: const [],
      manifest: manifest,
    );
  }

  Future<OnDeviceBuild?> start({
    required String project,
    int? sourceRecordId,
    String planRevision = '',
    String planJson = '',
    String target = 'packet-tracer',
    required Future<OnDeviceBuild?> Function(
      void Function(String stage, double? progress) report,
    )
    build,
  }) {
    if (_status == PktBuildJobStatus.running && _activeRun != null) {
      return _activeRun!;
    }
    _lastBuild = build;
    _project = project.trim().isEmpty ? 'Network design' : project.trim();
    _sourceRecordId = sourceRecordId;
    _planRevision = planRevision;
    _planJson = planJson;
    _target = target;
    return _begin(build);
  }

  Future<OnDeviceBuild?> retry() {
    final build = _lastBuild;
    if (build == null) return Future<OnDeviceBuild?>.value(null);
    return _begin(build);
  }

  Future<OnDeviceBuild?> _begin(
    Future<OnDeviceBuild?> Function(
      void Function(String stage, double? progress) report,
    )
    build,
  ) {
    _cancelRequested = false;
    _result = null;
    _error = '';
    _savedLocation = '';
    _status = PktBuildJobStatus.running;
    _stage = 'Preparing the phone build';
    _progress = 0.03;
    _currentJobId = DateTime.now().microsecondsSinceEpoch.toString();
    _upsert(
      PktBuildJobEntry(
        id: _currentJobId!,
        project: _project,
        status: _status,
        stage: _stage,
        error: '',
        filePath: '',
        savedLocation: '',
        updatedAt: DateTime.now(),
        deviceCount: 0,
        linkCount: 0,
      ),
    );
    notifyListeners();

    final run = _execute(build);
    _activeRun = run;
    return run;
  }

  Future<OnDeviceBuild?> _execute(
    Future<OnDeviceBuild?> Function(
      void Function(String stage, double? progress) report,
    )
    build,
  ) async {
    try {
      final result = await build(_reportProgress);
      if (_cancelRequested) {
        if (result != null) {
          if (await result.manifest.exists()) await result.manifest.delete();
          if (await result.file.exists()) await result.file.delete();
        }
        throw const OnDeviceBuildCancelled();
      }
      if (result == null) {
        _status = PktBuildJobStatus.failed;
        _error = 'There are no devices to build in this plan.';
        _stage = 'Build could not start';
        _progress = 0;
      } else {
        _result = result;
        _status = PktBuildJobStatus.ready;
        _stage = 'The .pkt is ready to save';
        _progress = 1;
      }
      _recordCurrent();
      notifyListeners();
      return result;
    } catch (error) {
      if (_cancelRequested || error is OnDeviceBuildCancelled) {
        _status = PktBuildJobStatus.cancelled;
        _stage = 'Build cancelled';
        _progress = 0;
        _error = '';
      } else {
        _status = PktBuildJobStatus.failed;
        _stage = 'Build failed';
        _progress = 0;
        _error = error
            .toString()
            .replaceFirst(RegExp(r'^Exception: '), '')
            .replaceFirst(RegExp(r'^StateError: '), '');
      }
      _recordCurrent();
      notifyListeners();
      return null;
    } finally {
      _activeRun = null;
    }
  }

  void _reportProgress(String stage, double? progress) {
    if (_cancelRequested || _status != PktBuildJobStatus.running) return;
    _stage = stage;
    _progress = progress?.clamp(0, 1).toDouble();
    notifyListeners();
  }

  void cancel() {
    if (_status != PktBuildJobStatus.running) return;
    _cancelRequested = true;
    OnDevicePktBuilder.cancelActiveBuild();
    _stage = 'Cancelling the build';
    notifyListeners();
  }

  void markSaved(String location) {
    if (_result == null) return;
    _savedLocation = location;
    _stage = 'Saved the .pkt';
    _status = PktBuildJobStatus.saved;
    _recordCurrent();
    notifyListeners();
  }

  void markHistoryItemSaved(String id, String location) {
    final index = _history.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    _history[index] = _history[index].copyWith(
      status: PktBuildJobStatus.saved,
      stage: 'Saved the .pkt',
      savedLocation: location,
      updatedAt: DateTime.now(),
    );
    if (_currentJobId == id) {
      _status = PktBuildJobStatus.saved;
      _stage = 'Saved the .pkt';
      _savedLocation = location;
    }
    _persist();
    notifyListeners();
  }

  /// Add a completed desktop-sidecar build to the same history as phone jobs.
  /// It does not take over the active-job banner.
  void recordGeneratedFile({
    required String project,
    required String filePath,
    int deviceCount = 0,
    int linkCount = 0,
    int? sourceRecordId,
    String planRevision = '',
    String planJson = '',
    String target = 'packet-tracer',
  }) {
    if (filePath.trim().isEmpty) return;
    _upsert(
      PktBuildJobEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        project: project.trim().isEmpty ? 'Network design' : project.trim(),
        status: PktBuildJobStatus.ready,
        stage: 'Generated by Packet Tracer',
        error: '',
        filePath: filePath,
        savedLocation: '',
        updatedAt: DateTime.now(),
        deviceCount: deviceCount,
        linkCount: linkCount,
        sourceRecordId: sourceRecordId,
        planRevision: planRevision,
        planJson: planJson,
        target: target,
        dismissed: true,
      ),
    );
    notifyListeners();
  }

  void dismiss() {
    if (_status == PktBuildJobStatus.running) return;
    final current = _currentJobId;
    if (current != null) {
      final index = _history.indexWhere((entry) => entry.id == current);
      if (index >= 0) {
        _history[index] = _history[index].copyWith(
          dismissed: true,
          updatedAt: DateTime.now(),
        );
      }
    }
    _status = PktBuildJobStatus.idle;
    _stage = '';
    _progress = 0;
    _error = '';
    _result = null;
    _savedLocation = '';
    _lastBuild = null;
    _currentJobId = null;
    _persist();
    notifyListeners();
  }

  void _recordCurrent() {
    final id = _currentJobId;
    if (id == null) return;
    final report = _result?.report ?? const <String, dynamic>{};
    _updateCurrent(
      PktBuildJobEntry(
        id: id,
        project: _project,
        status: _status,
        stage: _stage,
        error: _error,
        filePath: _result?.file.path ?? '',
        savedLocation: _savedLocation,
        updatedAt: DateTime.now(),
        deviceCount: (report['deviceCount'] as num?)?.toInt() ?? 0,
        linkCount: (report['linkCount'] as num?)?.toInt() ?? 0,
        sourceRecordId: _sourceRecordId,
        planRevision: _planRevision,
        planJson: _planJson,
        target: _target,
      ),
    );
  }

  void _updateCurrent(PktBuildJobEntry entry) {
    final index = _history.indexWhere((item) => item.id == entry.id);
    if (index >= 0) _history[index] = entry;
    _sortAndTrim();
    _persist();
  }

  void _upsert(PktBuildJobEntry entry) {
    _history.removeWhere((item) => item.id == entry.id);
    _history.insert(0, entry);
    _sortAndTrim();
    _persist();
  }

  void _sortAndTrim() {
    _history.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (_history.length > _historyLimit) {
      _history.removeRange(_historyLimit, _history.length);
    }
  }

  void _persist() {
    final snapshot = jsonEncode(
      _history.map((entry) => entry.toJson()).toList(),
    );
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_storageKey, snapshot);
      } catch (_) {
        // Persistence is best-effort; a plugin failure must not fail a build.
      }
    });
  }

  @visibleForTesting
  Future<void> flushForTesting() => _writes;
}
