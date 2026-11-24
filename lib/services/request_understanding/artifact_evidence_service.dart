import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../models/network_intent.dart';
import '../../models/request_coverage.dart';
import '../../models/request_requirement.dart';
import '../network_math.dart';
import '../pkt/on_device_pkt_builder.dart';
import 'build_action_identity.dart';
import 'saved_artifact_audit.dart';

class ArtifactEvidenceResult {
  final BuildActionIdentity action;
  final String artifactHash;
  final CoverageReport coverage;
  final bool isBound;
  final List<String> lines;
  final List<String> findings;
  final Map<String, dynamic> audit;

  ArtifactEvidenceResult({
    required this.action,
    required this.artifactHash,
    required this.coverage,
    required this.isBound,
    required List<String> lines,
    required List<String> findings,
    Map<String, dynamic> audit = const {},
  }) : lines = List.unmodifiable(lines),
       findings = List.unmodifiable(findings),
       audit = Map.unmodifiable(audit);

  /// Requirement delivery is not a live network verdict. Empty coverage is
  /// deliberately not an affirmative verification of an entire artifact.
  bool get verified =>
      isBound &&
      findings.isEmpty &&
      coverage.requirements.any(
        (row) => row.planning != PlanningStatus.superseded,
      ) &&
      coverage.requirements
          .where((row) => row.planning != PlanningStatus.superseded)
          .every((row) => row.delivery == DeliveryStatus.verified);
}

/// Joins independent saved-byte observations to requirements, never a
/// generator report or a reconstructed plan with parser defaults.
class ArtifactEvidenceService {
  const ArtifactEvidenceService._();

  static const hashBinding = 'saved-bytes-v1';

  static bool validHash(String hash) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(hash);

  static Future<String> contentHash(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();

  /// The file is read once. Both the hash and decoder see that exact buffer.
  /// A caller checking an existing card later must read [contentHash] again.
  static Future<ArtifactEvidenceResult> completeOnDevice({
    required File file,
    required BuildActionIdentity action,
    required Iterable<Requirement> requirements,
    CoverageReport? planning,
    CoverageReport? previousCoverage,
    DateTime? checkedAt,
  }) async {
    Map<String, dynamic> audit;
    try {
      final bytes = await file.readAsBytes();
      audit = OnDevicePktBuilder.auditReport(
        bytes,
        path: file.path,
        project: action.projectId,
      );
    } catch (_) {
      audit = const {'unreadable': true};
    }
    return completeAudit(
      action: action,
      requirements: requirements,
      audit: audit,
      planning: planning,
      previousCoverage: previousCoverage,
      checkedAt: checkedAt,
    );
  }

  /// Engine `/pkt/audit` and on-device reports carry a decoder-origin hash
  /// binding. A generator's hash, path, count, or XML string is not sufficient.
  /// Legacy/unreadable reports are retained as unverified observations.
  static ArtifactEvidenceResult completeAudit({
    required BuildActionIdentity action,
    required Iterable<Requirement> requirements,
    required Map<String, dynamic> audit,
    CoverageReport? planning,
    CoverageReport? previousCoverage,
    DateTime? checkedAt,
  }) {
    final requested = requirements.toList();
    final saved = SavedArtifactAudit(audit);
    final hash = SavedArtifactAudit.text(audit['artifactHash']).toLowerCase();
    final isBound =
        action.isComplete &&
        action.requirementsDigest ==
            BuildActionIdentity.digestRequirements(requested) &&
        action.target == 'packet-tracer' &&
        validHash(hash) &&
        audit['hashBinding'] == hashBinding &&
        (audit['mode'] == 'offline' || audit['mode'] == 'on-device') &&
        audit['unreadable'] != true &&
        audit['inventoryComplete'] != false;
    final entries = <RequirementCoverage>[];
    final when = (checkedAt ?? DateTime.now()).toUtc().toIso8601String();
    for (final requirement in requested) {
      final plan = planning?.forRequirement(requirement.id);
      final previous = previousCoverage?.forRequirement(requirement.id);
      final history = <RequirementEvidence>{
        ...?previous?.evidence,
        ...?plan?.evidence,
      }.toList();
      if (requirement.state == RequirementState.superseded) {
        entries.add(
          RequirementCoverage(
            requirementId: requirement.id,
            planning: PlanningStatus.superseded,
            delivery: DeliveryStatus.notRequested,
            evidence: history,
            explanation:
                'This requirement was superseded; its evidence is historical.',
          ),
        );
        continue;
      }
      final observation = !isBound
          ? const _Observation.unknown(
              'No saved-byte audit is bound to these exact action inputs.',
            )
          : requirement.state != RequirementState.active
          ? const _Observation.unknown('The request remains unresolved.')
          : requirement.phase == RequirementPhase.liveVerification
          ? const _Observation.unknown(
              'An offline artifact read cannot verify a live check.',
            )
          : _observe(requirement, saved);
      // Offline observations must never masquerade as a live test, even when
      // the original requirement asks for one.
      final evidence = RequirementEvidence(
        requirementId: requirement.id,
        planRevision: action.planRevision,
        target: action.target,
        phase: RequirementPhase.artifact,
        artifactHash: hash,
        measuredValue: observation.value,
        checker: 'saved-artifact-v1',
        checkedAt: when,
        explanation: observation.explanation,
        projectId: action.projectId,
        buildRevision: action.buildRevision,
        requirementsDigest: action.requirementsDigest,
        scope: action.scope,
        layoutIdentity: action.layoutIdentity,
        outputIdentity: action.outputIdentity,
        deliveryStatus: observation.status,
      );
      entries.add(
        RequirementCoverage(
          requirementId: requirement.id,
          planning:
              plan?.planning ?? previous?.planning ?? PlanningStatus.unresolved,
          delivery: observation.status,
          evidence: [...history, evidence],
          explanation: observation.explanation,
        ),
      );
    }
    // Removed requirements are forensic history, not active successful claims.
    final ids = requested.map((row) => row.id).toSet();
    for (final old
        in previousCoverage?.requirements ?? <RequirementCoverage>[]) {
      if (ids.contains(old.requirementId)) continue;
      entries.add(
        RequirementCoverage(
          requirementId: old.requirementId,
          planning: PlanningStatus.superseded,
          delivery: DeliveryStatus.unverified,
          evidence: old.evidence,
          explanation:
              'Historical requirement; not part of the current requirement set.',
        ),
      );
    }
    final verified = entries
        .where((row) => row.delivery == DeliveryStatus.verified)
        .length;
    final mismatches = entries
        .where((row) => row.delivery == DeliveryStatus.mismatch)
        .length;
    final unknown = entries
        .where((row) => row.delivery == DeliveryStatus.unverified)
        .length;
    return ArtifactEvidenceResult(
      action: action,
      artifactHash: hash,
      coverage: CoverageReport(requirements: entries),
      isBound: isBound,
      audit: audit,
      findings: saved.findings,
      lines: [
        '- Artifact requirements: $verified verified, $mismatches mismatched, $unknown unverified.',
        if (!isBound)
          '- Freshness: no current saved-byte binding; delivery is unverified.',
        if (saved.findings.isNotEmpty)
          '- Saved-file findings: ${saved.findings.join('; ')}',
        '- Live behavior was not verified by this offline read.',
      ],
    );
  }

  /// Refresh against BOTH current action inputs and current file bytes. Never
  /// rewrite the old evidence to look fresh: retain it, downgrade the claim.
  static CoverageReport refresh({
    required CoverageReport coverage,
    required BuildActionIdentity currentAction,
    required String currentArtifactHash,
  }) => CoverageReport(
    requirements: [
      for (final row in coverage.requirements)
        if (row.delivery == DeliveryStatus.verified ||
            row.delivery == DeliveryStatus.mismatch)
          _refreshEntry(row, currentAction, currentArtifactHash)
        else
          row,
    ],
  );

  static RequirementCoverage _refreshEntry(
    RequirementCoverage row,
    BuildActionIdentity action,
    String hash,
  ) {
    // Only the latest artifact observation is authoritative. An old success
    // cannot outvote a newer unreadable/mismatched result for the same bytes.
    final latest = row.evidence
        .where((item) => item.phase == RequirementPhase.artifact)
        .lastOrNull;
    if (latest != null &&
        evidenceMatches(latest, action, hash) &&
        latest.deliveryStatus == row.delivery) {
      return row;
    }
    return RequirementCoverage(
      requirementId: row.requirementId,
      planning: row.planning,
      delivery: DeliveryStatus.unverified,
      evidence: row.evidence,
      explanation:
          'Stale or unbound artifact evidence: action inputs or saved bytes changed. Re-audit the current file.',
    );
  }

  static bool evidenceMatches(
    RequirementEvidence evidence,
    BuildActionIdentity action,
    String hash,
  ) =>
      action.isComplete &&
      validHash(hash) &&
      evidence.artifactHash == hash &&
      evidence.projectId == action.projectId &&
      evidence.planRevision == action.planRevision &&
      evidence.buildRevision == action.buildRevision &&
      evidence.requirementsDigest == action.requirementsDigest &&
      evidence.target == action.target &&
      evidence.scope == action.scope &&
      evidence.layoutIdentity == action.layoutIdentity &&
      evidence.outputIdentity == action.outputIdentity;

  static Future<CoverageReport> refreshFile({
    required CoverageReport coverage,
    required BuildActionIdentity currentAction,
    required File file,
  }) async {
    String hash;
    try {
      hash = await contentHash(file);
    } catch (_) {
      hash = '';
    }
    return refresh(
      coverage: coverage,
      currentAction: currentAction,
      currentArtifactHash: hash,
    );
  }

  /// A layout-only request has two independent checks: semantic equality and
  /// actual saved positions. A named automatic layout style is not itself
  /// read-back evidence; if no explicit positions are observable it is unknown.
  static ({
    bool semanticsPreserved,
    DeliveryStatus delivery,
    List<String> lines,
  })
  checkLayoutOnly({
    required NetworkIntent before,
    required NetworkIntent after,
    required Map<String, dynamic> audit,
  }) {
    final unchanged = BuildActionIdentity.preservesSemantics(before, after);
    if (!unchanged) {
      return (
        semanticsPreserved: false,
        delivery: DeliveryStatus.mismatch,
        lines: const ['A layout-only edit changed semantic network content.'],
      );
    }
    final saved = SavedArtifactAudit(audit);
    if (!validHash(SavedArtifactAudit.text(audit['artifactHash'])) ||
        audit['hashBinding'] != hashBinding ||
        !{'on-device', 'offline'}.contains(audit['mode']) ||
        !saved.hasDeviceInventory) {
      return (
        semanticsPreserved: true,
        delivery: DeliveryStatus.unverified,
        lines: const ['Layout observations have no saved-byte audit binding.'],
      );
    }
    final checks = <_Observation>[];
    for (final entry in after.layout.entries) {
      if (entry.value == null) continue;
      checks.add(
        _position(saved.device(entry.key), {
          'x': entry.value!.dx.round(),
          'y': entry.value!.dy.round(),
        }),
      );
    }
    final result = _combine(checks, 'Saved positions');
    return (
      semanticsPreserved: true,
      delivery: result.status,
      lines: [result.explanation],
    );
  }

  static String _property(String value) => value
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .toLowerCase()
      .replaceAll('-', '_');

  static _Observation _observe(Requirement r, SavedArtifactAudit saved) {
    var property = _property(r.property);
    if (r.quantityRole == QuantityRole.userLoad) {
      return const _Observation.unknown(
        'User load is not a saved device count.',
      );
    }
    if (!saved.hasDeviceInventory) {
      return const _Observation.unknown(
        'The saved device inventory is missing, incomplete, or ambiguous.',
      );
    }
    if (r.scope.kind == RequirementScopeKind.site ||
        r.scope.kind == RequirementScopeKind.vlan ||
        r.scope.kind == RequirementScopeKind.output ||
        r.scope.kind == RequirementScopeKind.service) {
      return const _Observation.unknown(
        'This scope is not independently identified by the saved-file reader.',
      );
    }
    Object? expected = r.value;
    if (r.comparator == RequirementComparator.preserve) {
      if (expected is! Map ||
          expected['binding'] != 'preserve_v1' ||
          SavedArtifactAudit.text(expected['baseRevision']).isEmpty) {
        return const _Observation.unknown(
          'A preserve requirement needs its bound prior snapshot.',
        );
      }
      property = _property(SavedArtifactAudit.text(expected['property']));
      expected = expected['expected'];
    } else if (r.quantityRole == QuantityRole.increment) {
      if (expected is! Map ||
          expected['binding'] != 'device_count_delta_v1' ||
          expected['expectedTotal'] is! int ||
          expected['baseCount'] is! int ||
          expected['delta'] is! int ||
          (expected['baseCount'] as int) < 0 ||
          expected['expectedTotal'] !=
              (expected['baseCount'] as int) + (expected['delta'] as int) ||
          SavedArtifactAudit.text(expected['baseRevision']).isEmpty) {
        return const _Observation.unknown(
          'An increment needs its bound expected total.',
        );
      }
      expected = expected['expectedTotal'];
    }
    final selected = _selected(r, saved);
    if (r.comparator == RequirementComparator.preserve &&
        !{'device_counts', 'addressing', 'layout'}.contains(property)) {
      return const _Observation.unknown(
        'The complete preserved snapshot contains properties this saved-file reader cannot independently verify.',
      );
    }
    if (r.comparator == RequirementComparator.atLeast ||
        r.comparator == RequirementComparator.atMost) {
      if (!{
        'device_count',
        'count',
        'scale',
        'link_count',
      }.contains(property)) {
        return const _Observation.unknown(
          'This comparator has no saved-file checker for the requested property.',
        );
      }
    }
    if (property == 'device_count' ||
        property == 'count' ||
        property == 'scale' ||
        property == 'device_counts') {
      if (saved.devices.any(
        (row) => SavedArtifactAudit.deviceKind(row['type']).isEmpty,
      )) {
        return const _Observation.unknown(
          'A saved device type could not be read.',
        );
      }
      if (!_knownSubject(r.subject)) {
        return const _Observation.unknown(
          'The requested device kind is not recognized.',
        );
      }
      if (expected is Map &&
          (property == 'device_counts' ||
              r.comparator == RequirementComparator.preserve)) {
        final subject = SavedArtifactAudit.deviceKind(r.subject);
        final allKinds = {
          'network',
          'project',
          'device',
          'devices',
          'all',
        }.contains(subject);
        final counts = <String, int>{if (!allKinds) subject: 0};
        for (final row in selected) {
          final kind = SavedArtifactAudit.deviceKind(row['type']);
          counts[kind] = (counts[kind] ?? 0) + 1;
        }
        final want = {
          for (final entry in expected.entries)
            SavedArtifactAudit.deviceKind(entry.key): entry.value,
        };
        return _equal(
          BuildActionIdentity.digestJson(counts) ==
              BuildActionIdentity.digestJson(want),
          counts,
          'Saved device counts',
        );
      }
      if (expected is! num || expected < 0 || expected != expected.toInt()) {
        return const _Observation.unknown(
          'The requested count is not bound to a non-negative integer.',
        );
      }
      return _compareNumber(
        selected.length,
        expected,
        r.comparator,
        'Saved device count',
      );
    }
    if (property == 'device_name' ||
        property == 'name' ||
        property == 'device_presence') {
      final wanted = expected is String ? expected : r.scope.scopeId;
      if (wanted.isEmpty) {
        return const _Observation.unknown(
          'No device name was bound to this requirement.',
        );
      }
      if (!_knownSubject(r.subject)) {
        return const _Observation.unknown(
          'The requested device kind is not recognized.',
        );
      }
      final wantedKind = SavedArtifactAudit.deviceKind(r.subject);
      final anyKind = {
        'network',
        'project',
        'device',
        'devices',
        'all',
      }.contains(wantedKind);
      if (!anyKind &&
          selected.any(
            (row) => SavedArtifactAudit.deviceKind(row['type']).isEmpty,
          )) {
        return const _Observation.unknown(
          'The saved device kind could not be read.',
        );
      }
      final found = selected.any(
        (row) =>
            SavedArtifactAudit.text(row['name']).toLowerCase() ==
                wanted.toLowerCase() &&
            (anyKind ||
                SavedArtifactAudit.deviceKind(row['type']) == wantedKind),
      );
      final absent =
          r.comparator == RequirementComparator.forbidden || expected == false;
      return _equal(absent ? !found : found, {
        'name': wanted,
        'present': found,
      }, 'Saved device presence');
    }
    if (property == 'device_type' || property == 'type') {
      final wanted = SavedArtifactAudit.deviceKind(
        expected is String ? expected : r.subject,
      );
      if (wanted.isEmpty) {
        return const _Observation.unknown('No device type was bound.');
      }
      if (saved.devices.any(
        (row) => SavedArtifactAudit.deviceKind(row['type']).isEmpty,
      )) {
        return const _Observation.unknown(
          'A saved device type could not be read.',
        );
      }
      final present = selected.any(
        (row) => SavedArtifactAudit.deviceKind(row['type']) == wanted,
      );
      return _equal(
        r.comparator == RequirementComparator.forbidden ? !present : present,
        {'type': wanted, 'present': present},
        'Saved device type',
      );
    }
    if ([
      'model',
      'device_model',
      'router_model',
      'switch_model',
    ].contains(property)) {
      if (expected is! String || expected.trim().isEmpty) {
        return const _Observation.unknown('No requested model was bound.');
      }
      if (selected.isEmpty) {
        return const _Observation.mismatch(
          'The required device is absent from the saved file.',
        );
      }
      if (selected.any(
        (row) => SavedArtifactAudit.text(row['model']).isEmpty,
      )) {
        return const _Observation.unknown('The saved model is unreadable.');
      }
      String model(Object? value) => SavedArtifactAudit.text(
        value,
      ).toLowerCase().replaceFirst(RegExp(r'^cisco\s+'), '');
      final values = selected
          .map((row) => SavedArtifactAudit.text(row['model']))
          .toList();
      final matches = r.comparator == RequirementComparator.forbidden
          ? values.every((value) => model(value) != model(expected))
          : values.every((value) => model(value) == model(expected));
      return _equal(matches, values, 'Saved device model');
    }
    if ([
      'service',
      'services',
      'service_role',
      'excluded_service',
      'service_exclusion',
      'dns_excluded',
    ].contains(property)) {
      return _service(r, expected, selected, saved, property);
    }
    if ([
      'addressing',
      'interface_address',
      'ip_cidr',
      'address',
      'ip_address',
    ].contains(property)) {
      if (r.comparator == RequirementComparator.forbidden) {
        return const _Observation.unknown(
          'Address exclusion needs an independent complete scoped address checker.',
        );
      }
      if (expected is List) return _addressSnapshot(expected, saved, selected);
      if (expected is Map && expected['node'] != null) {
        return _addressSnapshot([expected], saved, selected);
      }
      if (expected is String &&
          r.scope.kind == RequirementScopeKind.linkInterface) {
        final scope = r.scope.scopeId.split(':');
        final name = scope.first;
        final iface = scope.length > 1 ? scope.sublist(1).join(':') : r.subject;
        return _address(saved.device(name), iface, expected);
      }
      return const _Observation.unknown(
        'The interface address was not bound to a readable scope.',
      );
    }
    if (property == 'base_subnet' || property == 'subnet') {
      return _subnet(
        selected,
        expected,
        property == 'base_subnet',
        r.comparator,
        interface: r.scope.kind == RequirementScopeKind.linkInterface
            ? r.scope.scopeId.split(':').skip(1).join(':')
            : null,
      );
    }
    if (property == 'link_count') {
      if (r.scope.kind != RequirementScopeKind.project) {
        return const _Observation.unknown(
          'Scoped cable inventory is not independently identified.',
        );
      }
      if (!saved.hasLinkInventory || expected is! num) {
        return const _Observation.unknown(
          'The saved cable inventory or requested count is unavailable.',
        );
      }
      return _compareNumber(
        saved.links.length,
        expected,
        r.comparator,
        'Saved cable count',
      );
    }
    if (property == 'links' || property == 'link_endpoints') {
      if (r.scope.kind != RequirementScopeKind.project ||
          r.comparator != RequirementComparator.equals) {
        return const _Observation.unknown(
          'This scoped cable comparator is not supported by saved endpoint inventory.',
        );
      }
      if (!saved.hasLinkInventory || expected is! List) {
        return const _Observation.unknown(
          'Saved cable endpoints or the requested snapshot are unavailable.',
        );
      }
      String key(Map row) {
        final ends = [
          '${SavedArtifactAudit.text(row['a']).toLowerCase()}:${SavedArtifactAudit.interfaceName(row['aIf'])}',
          '${SavedArtifactAudit.text(row['b']).toLowerCase()}:${SavedArtifactAudit.interfaceName(row['bIf'])}',
        ]..sort();
        return ends.join('<->');
      }

      if (expected.any((row) => row is! Map)) {
        return const _Observation.unknown('The cable snapshot is invalid.');
      }
      final got = saved.links.map(key).toList()..sort();
      final want = expected.cast<Map>().map(key).toList()..sort();
      final endpointsMatch =
          BuildActionIdentity.digestJson(got) ==
          BuildActionIdentity.digestJson(want);
      if (!endpointsMatch) return _equal(false, got, 'Saved cable endpoints');
      if (expected.cast<Map>().any(
        (row) =>
            row['exactPorts'] == true ||
            row['cable'] != null ||
            row['dce'] != null,
      )) {
        return _Observation(
          DeliveryStatus.unverified,
          got,
          'Saved endpoints match, but requested cable kind/clocking needs a dedicated checker.',
        );
      }
      return _equal(true, got, 'Saved cable endpoints');
    }
    if (property == 'position' || property == 'layout_position') {
      if (r.comparator != RequirementComparator.equals) {
        return const _Observation.unknown(
          'This position comparator is not independently supported.',
        );
      }
      return _position(saved.device(r.scope.scopeId), expected);
    }
    if (property == 'layout' && expected is Map) {
      if (r.comparator != RequirementComparator.equals &&
          r.comparator != RequirementComparator.preserve) {
        return const _Observation.unknown(
          'This layout comparator is not independently supported.',
        );
      }
      final positions = expected['positions'] is Map
          ? expected['positions'] as Map
          : expected;
      final observations = [
        for (final entry in positions.entries)
          _position(saved.device('${entry.key}'), entry.value),
      ];
      if (expected['notes'] is List && (expected['notes'] as List).isNotEmpty) {
        observations.add(
          const _Observation.unknown(
            'A requested named layout style is not directly observed in saved coordinates.',
          ),
        );
      }
      return _combine(observations, 'Saved layout');
    }
    return const _Observation.unknown(
      'No independent saved-file checker can observe this requested property.',
    );
  }

  static bool _knownSubject(String raw) => {
    'network',
    'project',
    'device',
    'devices',
    'all',
    'router',
    'switch',
    'server',
    'pc',
    'laptop',
    'accesspoint',
    'firewall',
    'cloud',
    'hub',
  }.contains(SavedArtifactAudit.deviceKind(raw));

  static List<Map> _selected(Requirement r, SavedArtifactAudit saved) {
    if (r.scope.kind == RequirementScopeKind.device ||
        r.scope.kind == RequirementScopeKind.linkInterface) {
      final device = saved.device(r.scope.scopeId.split(':').first);
      return device == null ? [] : [device];
    }
    final kind = SavedArtifactAudit.deviceKind(r.subject);
    if ([
      'network',
      'project',
      'device',
      'devices',
      'all',
      'service',
      'services',
    ].contains(kind)) {
      return saved.devices;
    }
    const types = {
      'router',
      'switch',
      'server',
      'pc',
      'laptop',
      'accesspoint',
      'firewall',
      'cloud',
      'hub',
    };
    return types.contains(kind)
        ? saved.devices
              .where(
                (row) => SavedArtifactAudit.deviceKind(row['type']) == kind,
              )
              .toList()
        : saved.devices;
  }

  static _Observation _service(
    Requirement r,
    Object? expected,
    List<Map> selected,
    SavedArtifactAudit saved,
    String property,
  ) {
    final role = property == 'dns_excluded'
        ? 'dns'
        : SavedArtifactAudit.text(
            expected is String ? expected : r.subject,
          ).toLowerCase();
    if (role.isEmpty || role == 'network' || role == 'service') {
      return const _Observation.unknown('No service role was bound.');
    }
    final excluded =
        {
          'excluded_service',
          'service_exclusion',
          'dns_excluded',
        }.contains(property) ||
        r.comparator == RequirementComparator.forbidden;
    final want = excluded
        ? false
        : expected is Map
        ? SavedArtifactAudit.observedBool(expected['enabled'])
        : expected is bool
        ? expected
        : true;
    if (want == null) {
      return const _Observation.unknown(
        'The requested service state is unresolved.',
      );
    }
    final exclusive = expected is Map && expected['exclusive'] == true;
    if (selected.isEmpty) {
      return const _Observation.mismatch(
        'The device assigned this service is absent from the saved file.',
      );
    }
    final values = <String, Object?>{};
    var unknown = false;
    var mismatch = false;
    var anyEnabled = false;
    for (final device in selected) {
      final value = SavedArtifactAudit.serviceStates(device)[role];
      values[SavedArtifactAudit.text(device['name'])] = value;
      unknown = unknown || value == null;
      anyEnabled = anyEnabled || value == true;
      if (value != null && value != want) mismatch = true;
    }
    final scoped = r.scope.kind == RequirementScopeKind.device;
    // A project-level enabled role asks for at least one instance. Exclusion
    // needs an observed disabled flag everywhere; null is never absence.
    if (!scoped && want) {
      mismatch = !anyEnabled && !unknown;
      if (anyEnabled) unknown = false;
    }
    if (exclusive) {
      for (final device in saved.devices) {
        if (selected.contains(device)) continue;
        final value = SavedArtifactAudit.serviceStates(device)[role];
        values[SavedArtifactAudit.text(device['name'])] = value;
        unknown = unknown || value == null;
        mismatch = mismatch || value == true;
      }
    }
    if (mismatch) {
      return _Observation(
        DeliveryStatus.mismatch,
        values,
        'The saved $role service state differs from the request.',
      );
    }
    if (unknown) {
      return _Observation(
        DeliveryStatus.unverified,
        values,
        'The $role enabled flag could not be read on every required device.',
      );
    }
    return _Observation(
      DeliveryStatus.verified,
      values,
      'The requested $role enabled state was read from the saved file.',
    );
  }

  static _Observation _addressSnapshot(
    List expected,
    SavedArtifactAudit saved,
    List<Map> selected,
  ) {
    final checks = <_Observation>[];
    final expectedKeys = <String>{};
    final names = selected
        .map((row) => SavedArtifactAudit.text(row['name']).toLowerCase())
        .toSet();
    for (final row in expected) {
      if (row is! Map) {
        return const _Observation.unknown(
          'The preserved address snapshot is invalid.',
        );
      }
      final name = SavedArtifactAudit.text(row['node']);
      final iface = SavedArtifactAudit.text(row['iface']);
      if (name.isEmpty || iface.isEmpty) {
        return const _Observation.unknown(
          'The preserved address scope is missing.',
        );
      }
      names.add(name.toLowerCase());
      expectedKeys.add(
        '${name.toLowerCase()}:${SavedArtifactAudit.interfaceName(iface)}',
      );
      checks.add(
        _address(
          saved.device(name),
          iface,
          SavedArtifactAudit.text(row['ipCidr']),
        ),
      );
      if (SavedArtifactAudit.text(row['ip6Cidr']).isNotEmpty) {
        checks.add(
          const _Observation.unknown(
            'The IPv6 address is not observed by this saved-port reader.',
          ),
        );
      }
    }
    // A preservation snapshot must catch newly added addresses as well as
    // changed or removed ones. Unassigned raw ports are not extra addresses.
    for (final device in saved.devices) {
      final name = SavedArtifactAudit.text(device['name']).toLowerCase();
      if (!names.contains(name)) continue;
      final rows = device['interfaces'];
      if (rows is! List) {
        checks.add(
          const _Observation.unknown(
            'Saved interface inventory is incomplete.',
          ),
        );
        continue;
      }
      for (final row in rows.whereType<Map>()) {
        if (!row.containsKey('ip') || row['ipObserved'] == false) {
          checks.add(
            const _Observation.unknown('A saved address could not be read.'),
          );
          continue;
        }
        final ip = SavedArtifactAudit.text(row['ip']);
        if (ip.isEmpty || ip == 'unassigned' || ip == '0.0.0.0') continue;
        if (SavedArtifactAudit.text(row['name']).isEmpty) {
          checks.add(
            const _Observation.unknown(
              'An addressed raw port cannot be identified.',
            ),
          );
          continue;
        }
        if (!expectedKeys.contains(
          '$name:${SavedArtifactAudit.interfaceName(row['name'])}',
        )) {
          checks.add(
            _Observation(
              DeliveryStatus.mismatch,
              row,
              'The saved file contains an additional address outside the preserved snapshot.',
            ),
          );
        }
      }
    }
    return _combine(checks, 'Saved addressing');
  }

  static _Observation _address(Map? device, String iface, String expected) {
    if (device == null) {
      return const _Observation.mismatch(
        'The addressed device is absent from the saved file.',
      );
    }
    final rows = device['interfaces'];
    if (rows is! List) {
      return const _Observation.unknown(
        'Saved interface rows could not be read.',
      );
    }
    final found = rows
        .whereType<Map>()
        .where(
          (row) =>
              SavedArtifactAudit.interfaceName(row['name']) ==
              SavedArtifactAudit.interfaceName(iface),
        )
        .toList();
    if (found.isEmpty && device['interfacesComplete'] == true) {
      return const _Observation.mismatch(
        'The requested interface is absent from the saved file.',
      );
    }
    if (found.length != 1) {
      return const _Observation.unknown(
        'The saved port cannot be identified unambiguously.',
      );
    }
    final row = found.single;
    if (!row.containsKey('ip') ||
        row['ipObserved'] == false ||
        row['readable'] == false) {
      return const _Observation.unknown(
        'The saved port address is unreadable.',
      );
    }
    final ip = SavedArtifactAudit.text(row['ip']);
    final wanted = expected.split('/');
    if (wanted.first.isEmpty) {
      return const _Observation.unknown('The requested address is not bound.');
    }
    if (ip != wanted.first) {
      return _Observation(
        DeliveryStatus.mismatch,
        row,
        'The saved interface IP differs from the requested address.',
      );
    }
    if (wanted.length < 2) {
      return _Observation(
        DeliveryStatus.verified,
        row,
        'The requested IP was read from the saved interface.',
      );
    }
    final prefix = int.tryParse(wanted[1]);
    if (prefix == null || prefix < 0 || prefix > 32) {
      return const _Observation.unknown('The requested prefix is invalid.');
    }
    final mask = row['mask'] ?? row['subnet'];
    if (mask is! String || row['maskObserved'] == false) {
      return _Observation(
        DeliveryStatus.unverified,
        row,
        'The saved mask was not observed; an IP alone does not verify a CIDR.',
      );
    }
    if (mask.isEmpty) {
      return _Observation(
        DeliveryStatus.mismatch,
        row,
        'The saved interface has no subnet mask.',
      );
    }
    final actualPrefix = NetworkMath.prefixFromMask(mask);
    return _equal(
      actualPrefix == prefix,
      row,
      'Saved interface address and mask',
    );
  }

  static _Observation _subnet(
    List<Map> devices,
    Object? expected,
    bool contained,
    RequirementComparator comparator, {
    String? interface,
  }) {
    if (expected is! String) {
      return const _Observation.unknown('No subnet CIDR was bound.');
    }
    final wanted = _cidr(expected);
    if (wanted == null) {
      return const _Observation.unknown(
        'The requested subnet is not a valid IPv4 CIDR.',
      );
    }
    final values = <String>[];
    var unknown = false;
    var mismatch = false;
    for (final device in devices) {
      final rows = device['interfaces'];
      if (rows is! List || rows.isEmpty) {
        unknown = true;
        continue;
      }
      final relevantRows = rows
          .whereType<Map>()
          .where(
            (row) =>
                interface == null ||
                SavedArtifactAudit.interfaceName(row['name']) ==
                    SavedArtifactAudit.interfaceName(interface),
          )
          .toList();
      if (relevantRows.isEmpty ||
          (interface != null && relevantRows.length != 1)) {
        unknown = true;
      }
      if (rows.any((row) => row is! Map)) unknown = true;
      for (final row in relevantRows) {
        if (!row.containsKey('ip') || row['ipObserved'] == false) {
          unknown = true;
          continue;
        }
        final ip = SavedArtifactAudit.text(row['ip']);
        if (ip.isEmpty || ip == 'unassigned' || ip == '0.0.0.0') continue;
        final mask = row['mask'] ?? row['subnet'];
        if (mask is! String || row['maskObserved'] == false) {
          unknown = true;
          continue;
        }
        final prefix = NetworkMath.prefixFromMask(mask);
        if (prefix == null) {
          mismatch = true;
          continue;
        }
        final actual = _cidr('$ip/$prefix');
        if (actual == null) {
          mismatch = true;
          continue;
        }
        values.add('$ip/$prefix');
        final matches = contained
            ? actual.start >= wanted.start && actual.end <= wanted.end
            : actual.start == wanted.start && actual.end == wanted.end;
        mismatch =
            mismatch ||
            (comparator == RequirementComparator.forbidden
                ? matches
                : !matches);
      }
    }
    if (mismatch) {
      return _Observation(
        DeliveryStatus.mismatch,
        values,
        'A saved interface subnet differs from the request.',
      );
    }
    if (unknown || values.isEmpty) {
      return _Observation(
        DeliveryStatus.unverified,
        values,
        'Saved IP and mask observations do not cover the requested subnet.',
      );
    }
    return _Observation(
      DeliveryStatus.verified,
      values,
      'The requested subnet was checked against saved interface IPs and masks.',
    );
  }

  static ({int start, int end})? _cidr(String text) {
    final parts = text.split('/');
    if (parts.length != 2) return null;
    final prefix = int.tryParse(parts[1]);
    final octets = parts[0].split('.').map(int.tryParse).toList();
    if (prefix == null ||
        prefix < 0 ||
        prefix > 32 ||
        octets.length != 4 ||
        octets.any((n) => n == null || n < 0 || n > 255)) {
      return null;
    }
    var ip = 0;
    for (final octet in octets) {
      ip = (ip << 8) | octet!;
    }
    final mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
    final start = ip & mask;
    return (start: start, end: start | (0xffffffff ^ mask));
  }

  static _Observation _position(Map? device, Object? expected) {
    if (device == null) {
      return const _Observation.unknown(
        'The device position could not be read.',
      );
    }
    final position = device['position'];
    if (position is! Map ||
        expected is! Map ||
        position['x'] is! num ||
        position['y'] is! num ||
        expected['x'] is! num ||
        expected['y'] is! num) {
      return const _Observation.unknown(
        'Explicit saved and requested x/y positions are required.',
      );
    }
    return _equal(
      position['x'] == expected['x'] && position['y'] == expected['y'],
      position,
      'Saved device position',
    );
  }

  static _Observation _compareNumber(
    num actual,
    num expected,
    RequirementComparator comparator,
    String label,
  ) => _equal(
    switch (comparator) {
      RequirementComparator.atLeast => actual >= expected,
      RequirementComparator.atMost => actual <= expected,
      RequirementComparator.forbidden => actual == 0,
      _ => actual == expected,
    },
    actual,
    label,
  );

  static _Observation _equal(bool same, Object? value, String label) =>
      _Observation(
        same ? DeliveryStatus.verified : DeliveryStatus.mismatch,
        value,
        '$label ${same ? 'matches' : 'differs from'} the request.',
      );

  static _Observation _combine(List<_Observation> checks, String label) {
    if (checks.isEmpty) {
      return _Observation.unknown(
        '$label has no independently readable observations.',
      );
    }
    final status = checks.any((row) => row.status == DeliveryStatus.mismatch)
        ? DeliveryStatus.mismatch
        : checks.any((row) => row.status == DeliveryStatus.unverified)
        ? DeliveryStatus.unverified
        : DeliveryStatus.verified;
    return _Observation(
      status,
      checks.map((row) => row.value).toList(),
      '$label: ${status.name}. ${checks.where((row) => row.status != DeliveryStatus.verified).map((row) => row.explanation).join(' ')}'
          .trim(),
    );
  }
}

class _Observation {
  final DeliveryStatus status;
  final Object? value;
  final String explanation;
  const _Observation(this.status, this.value, this.explanation);
  const _Observation.unknown(this.explanation)
    : status = DeliveryStatus.unverified,
      value = null;
  const _Observation.mismatch(this.explanation)
    : status = DeliveryStatus.mismatch,
      value = null;
}
