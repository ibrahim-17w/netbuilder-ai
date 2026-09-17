import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/build_artifact_service.dart';

void main() {
  test('restores a saved plan and recompiles its target export', () {
    final intent = NetworkIntent.parseSimple(
      'saved-lab',
      '1 router 1 switch with OSPF on 192.168.10.0/24',
    );
    final record = BuildRecord(
      id: 7,
      projectName: 'saved-lab',
      instruction: '1 router 1 switch with OSPF on 192.168.10.0/24',
      intentJson: jsonEncode(intent.toJson()),
      target: 'packet-tracer',
      status: 'planned',
      success: false,
      createdAt: DateTime(2026, 9, 12),
    );

    final restored = BuildArtifactService.restore(record);

    expect(restored.record, same(record));
    expect(restored.intent.projectName, 'saved-lab');
    expect(restored.intent.nodes.length, 2);
    expect(restored.configText, contains('=== R1 ==='));
    expect(restored.configText, contains('hostname R1'));
  });

  test('uses the history name when an older plan omitted projectName', () {
    final record = BuildRecord(
      projectName: 'legacy-lab',
      instruction: 'legacy plan',
      intentJson: jsonEncode({'nodes': []}),
      target: 'gns3',
      createdAt: DateTime(2026, 9, 12),
    );

    final restored = BuildArtifactService.restore(record);

    expect(restored.intent.projectName, 'legacy-lab');
    expect(restored.configText, contains('legacy-lab'));
  });

  test('rejects an empty saved plan instead of opening a blank detail', () {
    final record = BuildRecord(
      projectName: 'broken',
      instruction: 'broken plan',
      intentJson: 'not-json',
      target: 'gns3',
      createdAt: DateTime(2026, 9, 12),
    );

    expect(
      () => BuildArtifactService.restore(record),
      throwsA(isA<FormatException>()),
    );
  });
}
