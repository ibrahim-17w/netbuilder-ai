import 'dart:convert';

import '../services/request_understanding/artifact_evidence_service.dart';
import '../services/request_understanding/build_action_identity.dart';

enum PktVerificationCheckState { notChecked, passed, failed, partial, stale }

/// File creation, saved-byte checks and native checks are independent facts.
class PktVerificationSummary {
  final BuildActionIdentity? actionIdentity;
  final String artifactHash;
  final PktVerificationCheckState generatedState;
  final PktVerificationCheckState readBackState;
  final PktVerificationCheckState nativeOpenState;
  final PktVerificationCheckState connectivityState;
  final int passed;
  final int failed;
  final int skipped;
  final int manual;
  final String nativeVersion;
  final String nativeError;
  final String nativeRunId;
  final String checkedAt;

  const PktVerificationSummary({
    this.actionIdentity,
    this.artifactHash = '',
    this.generatedState = PktVerificationCheckState.notChecked,
    this.readBackState = PktVerificationCheckState.notChecked,
    this.nativeOpenState = PktVerificationCheckState.notChecked,
    this.connectivityState = PktVerificationCheckState.notChecked,
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.manual = 0,
    this.nativeVersion = '',
    this.nativeError = '',
    this.nativeRunId = '',
    this.checkedAt = '',
  });

  factory PktVerificationSummary.generated({
    required BuildActionIdentity? actionIdentity,
    required String artifactHash,
    Map<String, dynamic>? audit,
  }) {
    final bound =
        actionIdentity?.isComplete == true &&
        ArtifactEvidenceService.validHash(artifactHash);
    final readBack =
        bound &&
        audit?['artifactHash'] == artifactHash &&
        audit?['hashBinding'] == ArtifactEvidenceService.hashBinding &&
        (audit?['mode'] == 'offline' || audit?['mode'] == 'on-device') &&
        audit?['unreadable'] != true &&
        audit?['inventoryComplete'] == true &&
        audit?['devices'] is List &&
        audit?['links'] is List;
    return PktVerificationSummary(
      actionIdentity: actionIdentity,
      artifactHash: artifactHash,
      generatedState: PktVerificationCheckState.passed,
      readBackState: readBack
          ? PktVerificationCheckState.passed
          : audit?['unreadable'] == true
          ? PktVerificationCheckState.failed
          : PktVerificationCheckState.notChecked,
    );
  }

  PktVerificationSummary refresh({
    required BuildActionIdentity? currentAction,
    required String currentHash,
  }) {
    if (currentAction?.isComplete == true &&
        currentAction == actionIdentity &&
        ArtifactEvidenceService.validHash(currentHash) &&
        currentHash == artifactHash) {
      return this;
    }
    PktVerificationCheckState stale(PktVerificationCheckState state) =>
        state == PktVerificationCheckState.notChecked
        ? state
        : PktVerificationCheckState.stale;
    return PktVerificationSummary(
      actionIdentity: actionIdentity,
      artifactHash: artifactHash,
      generatedState: stale(generatedState),
      readBackState: stale(readBackState),
      nativeOpenState: stale(nativeOpenState),
      connectivityState: stale(connectivityState),
      passed: passed,
      failed: failed,
      skipped: skipped,
      manual: manual,
      nativeVersion: nativeVersion,
      nativeError: nativeError,
      nativeRunId: nativeRunId,
      checkedAt: checkedAt,
    );
  }

  /// Only a current, terminal native run may supply native observations.
  PktVerificationSummary withNativeReport(
    Map<String, dynamic> report, {
    required String expectedRunId,
  }) {
    BuildActionIdentity? reportedAction;
    try {
      reportedAction = BuildActionIdentity.fromJson(report['actionIdentity']);
    } catch (_) {
      throw const FormatException(
        'Native report has no valid action identity.',
      );
    }
    final state = report['state'];
    final when = DateTime.tryParse('${report['checkedAt'] ?? ''}');
    if (expectedRunId.isEmpty ||
        report['schema'] != 1 ||
        report['checker'] != 'packet-tracer-native-v1' ||
        report['hashBinding'] != 'native-session-v1' ||
        report['runId'] != expectedRunId ||
        !const ['completed', 'failed', 'cancelled'].contains(state) ||
        reportedAction != actionIdentity ||
        reportedAction.isComplete != true ||
        report['artifactHash'] != artifactHash ||
        !ArtifactEvidenceService.validHash(artifactHash) ||
        when == null) {
      throw const FormatException(
        'Native report is stale, unbound or unfinished.',
      );
    }
    final version = '${report['packetTracerVersion'] ?? ''}';
    final open = report['openEvidence'];
    final opened =
        state == 'completed' &&
        report['opened'] == true &&
        open is Map &&
        open['loadedFileMatches'] == true &&
        open['topologyMatches'] == true &&
        RegExp(r'^\d+\.\d+(?:\.\d+){0,2}$').hasMatch(version);
    final openFailed = open is Map && open['failed'] == true;
    var successes = 0, failures = 0, omissions = 0, manualChecks = 0;
    final tests = report['tests'];
    if (tests is! List || tests.any((row) => row is! Map)) {
      throw const FormatException('Native report has invalid tests.');
    }
    for (final row in tests.cast<Map>()) {
      final kind = '${row['kind'] ?? ''}';
      final status = '${row['status'] ?? ''}';
      final evidence = '${row['evidence'] ?? ''}'.trim();
      if (kind == 'manual' || status == 'manual' || kind == 'custom') {
        manualChecks++;
      } else if (status == 'pass' && evidence.isNotEmpty) {
        successes++;
      } else if (status == 'fail' && evidence.isNotEmpty) {
        failures++;
      } else {
        omissions++;
      }
    }
    final total = successes + failures + omissions + manualChecks;
    final connectivity = !opened || total == 0
        ? PktVerificationCheckState.notChecked
        : failures > 0
        ? PktVerificationCheckState.failed
        : omissions > 0 || manualChecks > 0
        ? PktVerificationCheckState.partial
        : successes > 0
        ? PktVerificationCheckState.passed
        : PktVerificationCheckState.notChecked;
    return PktVerificationSummary(
      actionIdentity: actionIdentity,
      artifactHash: artifactHash,
      generatedState: generatedState,
      readBackState: readBackState,
      nativeOpenState: opened
          ? PktVerificationCheckState.passed
          : openFailed
          ? PktVerificationCheckState.failed
          : PktVerificationCheckState.notChecked,
      connectivityState: connectivity,
      passed: successes,
      failed: failures,
      skipped: omissions,
      manual: manualChecks,
      nativeVersion: version,
      nativeError: '${report['error'] ?? ''}',
      nativeRunId: expectedRunId,
      checkedAt: when.toUtc().toIso8601String(),
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': 1,
    if (actionIdentity != null) 'actionIdentity': actionIdentity!.toJson(),
    'artifactHash': artifactHash,
    'generatedState': generatedState.name,
    'readBackState': readBackState.name,
    'nativeOpenState': nativeOpenState.name,
    'connectivityState': connectivityState.name,
    'passed': passed,
    'failed': failed,
    'skipped': skipped,
    'manual': manual,
    'nativeVersion': nativeVersion,
    'nativeError': nativeError,
    'nativeRunId': nativeRunId,
    'checkedAt': checkedAt,
  };

  factory PktVerificationSummary.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Unknown verification schema.');
    }
    BuildActionIdentity? identity;
    if (json['actionIdentity'] != null) {
      identity = BuildActionIdentity.fromJson(json['actionIdentity']);
    }
    PktVerificationCheckState readState(String key) =>
        PktVerificationCheckState.values.firstWhere(
          (s) => s.name == json[key],
          orElse: () => PktVerificationCheckState.notChecked,
        );
    int count(String key) {
      final value = json[key];
      if (value is! int || value < 0) {
        throw const FormatException('Invalid verification count.');
      }
      return value;
    }

    final nativeRunId = '${json['nativeRunId'] ?? ''}';
    final version = '${json['nativeVersion'] ?? ''}';
    final checkedAt = '${json['checkedAt'] ?? ''}';
    final nativeValid =
        identity?.isComplete == true &&
        ArtifactEvidenceService.validHash('${json['artifactHash'] ?? ''}') &&
        nativeRunId.isNotEmpty &&
        DateTime.tryParse(checkedAt) != null &&
        RegExp(r'^\d+\.\d+(?:\.\d+){0,2}$').hasMatch(version);
    return PktVerificationSummary(
      actionIdentity: identity,
      artifactHash: '${json['artifactHash'] ?? ''}',
      generatedState: readState('generatedState'),
      readBackState: readState('readBackState'),
      nativeOpenState: nativeValid
          ? readState('nativeOpenState')
          : PktVerificationCheckState.notChecked,
      connectivityState: nativeValid
          ? readState('connectivityState')
          : PktVerificationCheckState.notChecked,
      passed: count('passed'),
      failed: count('failed'),
      skipped: count('skipped'),
      manual: count('manual'),
      nativeVersion: version,
      nativeError: '${json['nativeError'] ?? ''}',
      nativeRunId: nativeRunId,
      checkedAt: checkedAt,
    );
  }

  List<String> get lines => [
    '- Generated: ${generatedState.name}.',
    '- File read-back checked: ${readBackState.name}.',
    '- Opened in Packet Tracer: ${nativeOpenState.name}.',
    '- Connectivity tested: ${connectivityState.name} '
        '($passed passed, $failed failed, $skipped skipped, $manual manual).',
    if (nativeVersion.isNotEmpty) '- Native check version: $nativeVersion.',
    '- These checks do not establish behavior outside the tested probes.',
  ];

  @override
  bool operator ==(Object other) =>
      other is PktVerificationSummary &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
