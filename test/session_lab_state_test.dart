import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/lab_catalog.dart';
import 'package:net_builder/services/session_state.dart';

/// Lab progress rides the session state, so a conversation reopened
/// tomorrow is still working through the same checklist - and the grade
/// itself is always recomputed from the standing plan, never replayed.
void main() {
  test('the active lab id survives an encode/decode round trip', () {
    final state = SessionState()..labJson = '{"lab":"ospf-wan"}';
    final restored = SessionState.decode(state.encode());
    expect(restored.labJson, '{"lab":"ospf-wan"}');
    expect(LabCatalog.byId(labIdOf(restored)!)!.id, 'ospf-wan');
  });

  test('an empty lab field decodes clean', () {
    final restored = SessionState.decode(SessionState().encode());
    expect(restored.labJson, '');
    expect(labIdOf(restored), isNull);
  });

  test('corrupt lab json is not a crash - the lab is simply gone', () {
    final state = SessionState()..labJson = '{not json';
    final restored = SessionState.decode(state.encode());
    expect(labIdOf(restored), isNull);
  });

  test('guide checklist ticks survive the round trip', () {
    final state = SessionState()
      ..guideChecksJson =
          '{"rev-1":["Every device above exists, with the model shown."]}';
    final restored = SessionState.decode(state.encode());
    expect(restored.guideChecksJson, contains('rev-1'));
    expect(restored.guideChecksJson, contains('Every device above exists'));
  });

  test('an empty guide checks field decodes clean', () {
    final restored = SessionState.decode(SessionState().encode());
    expect(restored.guideChecksJson, '');
  });
}

/// The same decode the chat screen uses to find the running lab.
String? labIdOf(SessionState state) {
  if (state.labJson.trim().isEmpty) return null;
  try {
    final v = jsonDecode(state.labJson);
    if (v is Map && '${v['lab'] ?? ''}'.trim().isNotEmpty) {
      return '${v['lab']}';
    }
  } catch (_) {}
  return null;
}
