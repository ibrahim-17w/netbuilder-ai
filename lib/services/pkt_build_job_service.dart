import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/request_coverage.dart';
import '../models/pkt_verification.dart';
import 'pkt/on_device_pkt_builder.dart';
import 'request_understanding/build_action_identity.dart';
import 'request_understanding/artifact_evidence_service.dart';

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
  final BuildActionIdentity? actionIdentity;
  final String artifactHash;
  final CoverageReport? coverage;
  final PktVerificationSummary? verification;

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
    this.actionIdentity,
    this.artifactHash = '',
    this.coverage,
    this.verification,
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
    String? artifactHash,
    CoverageReport? coverage,
    PktVerificationSummary? verification,
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
    actionIdentity: actionIdentity,
    artifactHash: artifactHash ?? this.artifactHash,
    coverage: coverage ?? this.coverage,
    verification: verification ?? this.verification,
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
    if (actionIdentity != null) 'actionIdentity': actionIdentity!.toJson(),
    if (artifactHash.isNotEmpty) 'artifactHash': artifactHash,
    if (coverage != null) 'coverage': coverage!.toJson(),
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
      actionIdentity: _readIdentity(json['actionIdentity']),
      artifactHash: json['artifactHash'] is String
          ? json['artifactHash'] as String
          : '',
      coverage: _readCoverage(json['coverage']),
    );
  }

  static BuildActionIdentity? _readIdentity(Object? value) {
    if (value == null) return null;
    try {
      return BuildActionIdentity.fromJson(value);
    } catch (_) {
      return null;
    }
  }

  static CoverageReport? _readCoverage(Object? value) {
    if (value == null) return null;
    try {
      return CoverageReport.fromJson(value);
    } catch (_) {
      return null;
    }
  }

  /// Old JSON lacking an identity/hash remains history, never current proof.
  bool matchesArtifact(BuildActionIdentity identity, String currentHash) =>
      identity.isComplete &&
      actionIdentity == identity &&
      ArtifactEvidenceService.validHash(currentHash) &&
      artifactHash == currentHash;
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
  BuildActionIdentity? _actionIdentity;
  String _artifactHash = '';
  CoverageReport? _coverage;
  PktVerificationSummary? _verification;
  String? _activeKey;
  Future<dynamic>? _exclusiveRun;
  int _runSequence = 0;
  String? _latestRunId;
  BuildActionIdentity? get actionIdentity => _actionIdentity;
  String? get activeKey => _activeKey;
  bool get hasActiveBuild => _activeKey != null;
  String? get currentJobId => _latestRunId ?? _currentJobId;

  /// The active job's verification summary, as far as it actually got:
  /// generation, on-device read-back, and - once a native run is bound -
  /// the Packet Tracer observations. Nothing here is inferred; an unchecked
  /// column stays notChecked.
  PktVerificationSummary? get currentVerification => _verification;

  Future<OnDeviceBuild?> Function(
    void Function(String stage, double? progress) report,
  )?
  _lastBuild;

  Future<void> loadHistory() async {
    if (_historyLoaded) return;
    final sequence = _runSequence;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_storageKey);
      final restored = <PktBuildJobEntry>[];
      if (stored != null && stored.isNotEmpty) {
        final decoded = jsonDecode(stored);
        if (decoded is List) {
          for (final row in decoded.whereType<Map>()) {
            try {
              restored.add(
                PktBuildJobEntry.fromJson(Map<String, dynamic>.from(row)),
              );
            } catch (_) {
              // A malformed legacy row does not erase the rest of history.
            }
          }
        }
      }
      for (var i = 0; i < restored.length; i++) {
        var entry = restored[i];
        if (entry.actionIdentity != null && entry.coverage != null) {
          entry = entry.copyWith(
            coverage: await ArtifactEvidenceService.refreshFile(
              coverage: entry.coverage!,
              currentAction: entry.actionIdentity!,
              file: File(entry.filePath),
            ),
          );
        }
        if (entry.status == PktBuildJobStatus.running) {
          entry = entry.copyWith(
            status: PktBuildJobStatus.failed,
            stage: 'Build interrupted',
            error: 'The app closed before this build finished.',
            updatedAt: DateTime.now(),
          );
        }
        restored[i] = entry;
      }
      // History loading can complete after a new build was started. Merge
      // old rows without clearing a new job or adopting an old active banner.
      for (final entry in restored) {
        if (!_history.any((current) => current.id == entry.id)) {
          _history.add(entry);
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
      if (_runSequence == sequence &&
          _activeKey == null &&
          _currentJobId == null &&
          active != null &&
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
    _sourceRecordId = entry.sourceRecordId;
    _planRevision = entry.planRevision;
    _planJson = entry.planJson;
    _target = entry.target;
    _actionIdentity = entry.actionIdentity;
    _artifactHash = entry.artifactHash;
    _coverage = entry.coverage;
    _verification = entry.verification;
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
    BuildActionIdentity? actionIdentity,
    required Future<OnDeviceBuild?> Function(
      void Function(String stage, double? progress) report,
    )
    build,
  }) {
    final key =
        actionIdentity?.key ??
        _legacyKey(project, planRevision, planJson, target, sourceRecordId);
    if (_activeKey != null) {
      if (_activeKey == key && _activeRun != null) return _activeRun!;
      return Future<OnDeviceBuild?>.error(
        StateError(
          'A different build is already active. Wait for it to finish or cancel it first.',
        ),
      );
    }
    if (actionIdentity != null && !actionIdentity.isComplete) {
      return Future<OnDeviceBuild?>.error(
        StateError('The build action identity is incomplete.'),
      );
    }
    _lastBuild = build;
    _project = project.trim().isEmpty ? 'Network design' : project.trim();
    _sourceRecordId = sourceRecordId;
    _planRevision = planRevision;
    _planJson = planJson;
    _target = target;
    _actionIdentity = actionIdentity;
    return _begin(build, key: key);
  }

  static String _legacyKey(
    String project,
    String revision,
    String planJson,
    String target,
    int? sourceRecordId,
  ) => BuildActionIdentity.digestJson({
    'project': project.trim(),
    'revision': revision,
    'planJson': planJson,
    'target': target,
    'sourceRecordId': sourceRecordId,
  });

  /// Desktop builds share the same reservation as phone jobs, without a new
  /// queue or a fake OnDeviceBuild. Only an identical active key can join it.
  Future<T> runExclusive<T>({
    required BuildActionIdentity identity,
    required Future<T> Function() build,
  }) {
    if (!identity.isComplete) {
      return Future<T>.error(
        StateError('The build action identity is incomplete.'),
      );
    }
    if (_activeKey != null) {
      final active = _exclusiveRun;
      if (_activeKey == identity.key && active is Future<T>) return active;
      return Future<T>.error(
        StateError(
          'A different build is already active. Wait for it to finish or cancel it first.',
        ),
      );
    }
    final token = ++_runSequence;
    _latestRunId = '${DateTime.now().microsecondsSinceEpoch}-$token';
    final completion = Completer<T>();
    _activeKey = identity.key;
    _exclusiveRun = completion.future;
    notifyListeners();
    () async {
      try {
        final value = await build();
        if (token == _runSequence) {
          _activeKey = null;
          _exclusiveRun = null;
        }
        completion.complete(value);
      } catch (error, stack) {
        if (token == _runSequence) {
          _activeKey = null;
          _exclusiveRun = null;
        }
        completion.completeError(error, stack);
      } finally {
        notifyListeners();
      }
    }();
    return completion.future;
  }

  Future<OnDeviceBuild?> retry() {
    final build = _lastBuild;
    if (build == null) return Future<OnDeviceBuild?>.value(null);
    if (_activeKey != null) {
      if (_activeRun != null) return _activeRun!;
      return Future<OnDeviceBuild?>.error(
        StateError('A different build is already active.'),
      );
    }
    return _begin(
      build,
      key:
          _actionIdentity?.key ??
          _legacyKey(
            _project,
            _planRevision,
            _planJson,
            _target,
            _sourceRecordId,
          ),
    );
  }

  Future<OnDeviceBuild?> _begin(
    Future<OnDeviceBuild?> Function(
      void Function(String stage, double? progress) report,
    )
    build, {
    required String key,
  }) {
    final token = ++_runSequence;
    final completion = Completer<OnDeviceBuild?>();
    _activeKey = key;
    _activeRun = completion.future;
    _artifactHash = '';
    _coverage = null;
    _verification = null;
    _cancelRequested = false;
    _result = null;
    _error = '';
    _savedLocation = '';
    _status = PktBuildJobStatus.running;
    _stage = 'Preparing the phone build';
    _progress = 0.03;
    _currentJobId = '${DateTime.now().microsecondsSinceEpoch}-$token';
    _latestRunId = _currentJobId;
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
        sourceRecordId: _sourceRecordId,
        planRevision: _planRevision,
        planJson: _planJson,
        target: _target,
        actionIdentity: _actionIdentity,
      ),
    );
    notifyListeners();

    final jobId = _currentJobId!;
    _execute(
      build,
      token,
      jobId,
    ).then(completion.complete, onError: completion.completeError);
    return completion.future;
  }

  Future<OnDeviceBuild?> _execute(
    Future<OnDeviceBuild?> Function(
      void Function(String stage, double? progress) report,
    )
    build,
    int token,
    String jobId,
  ) async {
    try {
      final result = await build((stage, progress) {
        if (_runSequence == token && _currentJobId == jobId) {
          _reportProgress(stage, progress);
        }
      });
      if (_runSequence != token || _currentJobId != jobId) return null;
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
        // History records real saved bytes; a generator report is not evidence.
        try {
          _artifactHash = await ArtifactEvidenceService.contentHash(
            result.file,
          );
        } catch (_) {
          _artifactHash = '';
        }
        if (_runSequence != token || _currentJobId != jobId) return null;
        if (_cancelRequested) throw const OnDeviceBuildCancelled();
        _status = PktBuildJobStatus.ready;
        _stage = 'The .pkt is ready to save';
        _progress = 1;
      }
      _recordCurrent();
      notifyListeners();
      return result;
    } catch (error) {
      if (_runSequence != token || _currentJobId != jobId) return null;
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
      if (_runSequence == token && _currentJobId == jobId) {
        _activeRun = null;
        _activeKey = null;
      }
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
    BuildActionIdentity? actionIdentity,
    String artifactHash = '',
    CoverageReport? coverage,
    Map<String, dynamic>? audit,
    String? expectedJobId,
  }) {
    if (filePath.trim().isEmpty) return;
    if (expectedJobId != null && expectedJobId != _latestRunId) return;
    if (actionIdentity != null && expectedJobId == null) return;
    if (_activeKey != null && actionIdentity?.key != _activeKey) return;
    final verification =
        actionIdentity != null &&
            ArtifactEvidenceService.validHash(artifactHash)
        ? PktVerificationSummary.generated(
            actionIdentity: actionIdentity,
            artifactHash: artifactHash,
            audit: audit,
          )
        : null;
    final entry = PktBuildJobEntry(
      id: expectedJobId ?? DateTime.now().microsecondsSinceEpoch.toString(),
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
      actionIdentity: actionIdentity,
      artifactHash: artifactHash,
      coverage: coverage == null || actionIdentity == null
          ? coverage
          : ArtifactEvidenceService.refresh(
              coverage: coverage,
              currentAction: actionIdentity,
              currentArtifactHash: artifactHash,
            ),
      verification: verification,
      dismissed: true,
    );
    if (entry.id == _latestRunId) _verification = verification;
    _upsert(entry);
    notifyListeners();
  }

  /// Attach a finished phone audit without adding a second history row.
  /// The build snapshot and saved-byte hash must both still match. A late
  /// callback from an older job cannot overwrite a newer job's evidence.
  bool updateEvidence({
    required BuildActionIdentity actionIdentity,
    required String artifactHash,
    required CoverageReport coverage,
    Map<String, dynamic>? audit,
    String? jobId,
  }) {
    if (_currentJobId == null ||
        jobId == null ||
        jobId != _currentJobId ||
        jobId != _latestRunId ||
        _actionIdentity != actionIdentity ||
        _artifactHash != artifactHash ||
        !ArtifactEvidenceService.validHash(artifactHash) ||
        (_status != PktBuildJobStatus.ready &&
            _status != PktBuildJobStatus.saved)) {
      return false;
    }
    _coverage = ArtifactEvidenceService.refresh(
      coverage: coverage,
      currentAction: actionIdentity,
      currentArtifactHash: artifactHash,
    );
    if (audit != null) {
      // The read-back facts ride on the verification summary. A native run
      // already recorded is never rolled back by a late audit callback.
      final current = _verification;
      _verification = current == null || current.nativeRunId.isEmpty
          ? PktVerificationSummary.generated(
              actionIdentity: actionIdentity,
              artifactHash: artifactHash,
              audit: audit,
            )
          : current;
    }
    _recordCurrent();
    notifyListeners();
    return true;
  }

  /// Match a version only after reading the current file hash. Matching paths,
  /// dates, names, or legacy semantic-only revisions are not sufficient.
  PktBuildJobEntry? matchingArtifact({
    required BuildActionIdentity actionIdentity,
    required String currentArtifactHash,
  }) {
    for (final entry in _history) {
      if ((entry.status == PktBuildJobStatus.ready ||
              entry.status == PktBuildJobStatus.saved) &&
          entry.matchesArtifact(actionIdentity, currentArtifactHash)) {
        return entry;
      }
    }
    return null;
  }

  Future<PktBuildJobEntry?> matchingFile({
    required BuildActionIdentity actionIdentity,
    required File file,
  }) async {
    String hash;
    try {
      hash = await ArtifactEvidenceService.contentHash(file);
    } catch (_) {
      return null;
    }
    for (final entry in _history) {
      if (entry.filePath == file.path &&
          entry.matchesArtifact(actionIdentity, hash) &&
          (entry.status == PktBuildJobStatus.ready ||
              entry.status == PktBuildJobStatus.saved)) {
        return entry;
      }
    }
    return null;
  }

  void dismiss() {
    if (_activeKey != null) return;
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
    _latestRunId = null;
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
        actionIdentity: _actionIdentity,
        artifactHash: _artifactHash,
        coverage: _coverage,
        verification: _verification,
      ),
    );
  }

  /// Bind a finished NATIVE Packet Tracer verification to its job.
  ///
  /// The report is only recorded when every binding holds: it names this
  /// job, the run id the engine issued for it, a terminal state, and the
  /// same action identity and saved-byte hash the job was built under
  /// ([PktVerificationSummary.withNativeReport] arbitrates). Anything else
  /// returns false and nothing changes - a report that cannot prove which
  /// run and which file it belongs to is never quoted as evidence.
  Future<bool> recordNativeVerification(
    Map<String, dynamic> report, {
    required String jobId,
    required String expectedRunId,
  }) async {
    // The report must belong to the job that is still the app's latest run
    // (an older job's late-arriving evidence cannot overwrite a newer one).
    if (jobId.isEmpty || jobId != currentJobId || expectedRunId.isEmpty) {
      return false;
    }
    final index = _history.indexWhere((item) => item.id == jobId);
    if (index < 0) return false;
    final entry = _history[index];
    if (entry.actionIdentity == null ||
        !ArtifactEvidenceService.validHash(entry.artifactHash)) {
      return false;
    }
    try {
      // withNativeReport arbitrates every binding: the report must name this
      // run id, a terminal state, and the same action identity and saved-byte
      // hash this entry was built under.
      final summary =
          (entry.verification ??
                  PktVerificationSummary.generated(
                    actionIdentity: entry.actionIdentity,
                    artifactHash: entry.artifactHash,
                  ))
              .withNativeReport(report, expectedRunId: expectedRunId);
      _history[index] = entry.copyWith(verification: summary);
      if (jobId == _currentJobId) _verification = summary;
      _persist();
      notifyListeners();
      return true;
    } on FormatException {
      return false;
    }
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
