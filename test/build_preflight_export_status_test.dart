import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/build_preflight.dart';

/// The build message must say what the generator actually exported. These
/// tests pin the difference between "a file exists" and "the file is the
/// plan" - the exact gap that let a partial export read as a success.
void main() {
  test('a complete export says every planned device and cable is present', () {
    final lines = BuildPreflight.exportStatus({
      'status': 'VALID',
      'complete': true,
      'deviceCount': 6,
      'plannedDevices': 6,
      'linkCount': 5,
      'plannedLinks': 5,
      'missingDevices': <dynamic>[],
      'missingLinks': <dynamic>[],
      'modelSubstitutions': <dynamic>[],
      'interfaceRemappings': <dynamic>[],
      'verification': {
        'ok': true,
        'deviceCountOnDisk': 6,
        'linkCountOnDisk': 5,
      },
    });

    expect(lines, hasLength(2));
    expect(lines.first, contains('Export status: VALID'));
    expect(lines.first, contains('6/6 device(s), 5/5 cable(s)'));
    expect(lines.last, contains('matches the build'));
    expect(lines.join('\n'), isNot(contains('missing')));
  });

  test('an incomplete export names what is missing and distrusts the file', () {
    final lines = BuildPreflight.exportStatus({
      'status': 'EXPORT_INCOMPLETE',
      'complete': false,
      'deviceCount': 4,
      'plannedDevices': 6,
      'linkCount': 3,
      'plannedLinks': 5,
      'missingDevices': [
        {'name': 'HOLO1', 'reason': 'no template for holo'},
        {'name': 'PDU1', 'reason': 'no template for pdu'},
      ],
      'missingLinks': [
        {'a': 'R1', 'b': 'HOLO1'},
      ],
    });

    final text = lines.join('\n');
    expect(text, contains('EXPORT_INCOMPLETE'));
    expect(text, contains('the file is not the plan'));
    expect(text, contains('4/6 device(s), 3/5 cable(s)'));
    expect(text, contains('HOLO1 (no template for holo)'));
    expect(text, contains('PDU1'));
    expect(text, contains('R1-HOLO1'));
  });

  test('a substituted model is reported as a difference from the plan', () {
    final lines = BuildPreflight.exportStatus({
      'status': 'VALID_WITH_WARNINGS',
      'complete': true,
      'deviceCount': 2,
      'plannedDevices': 2,
      'linkCount': 1,
      'plannedLinks': 1,
      'modelSubstitutions': [
        {'device': 'R1', 'requested': '7200', 'used': '2911'},
      ],
    });

    final text = lines.join('\n');
    expect(text, contains('VALID_WITH_WARNINGS'));
    expect(text, contains('R1: 7200 -> 2911'));
    expect(text, contains('different model'));
  });

  test('an unreported status is said out loud, not assumed complete', () {
    final lines = BuildPreflight.exportStatus({
      'deviceCount': 3,
      'linkCount': 2,
    });

    expect(lines, hasLength(1));
    expect(lines.single, contains('Export status: not reported'));
    expect(lines.single, contains('3 device(s), 2 cable(s)'));
  });

  test('an empty report adds nothing to the message', () {
    expect(BuildPreflight.exportStatus(const <String, dynamic>{}), isEmpty);
  });
}
