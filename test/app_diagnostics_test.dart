import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/app_diagnostics.dart';

void main() {
  late Directory directory;
  late AppDiagnostics diagnostics;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('netbuilder_diag_');
    diagnostics = AppDiagnostics.forTesting(
      directory: directory,
      maxBytes: 200,
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('writes redacted events and exports the latest text', () async {
    await diagnostics.record(
      'uncaught',
      StateError('request failed token=supersecret123'),
    );

    final text = await diagnostics.exportText();
    expect(text, contains('uncaught'));
    expect(text, contains('<redacted>'));
    expect(text, isNot(contains('supersecret123')));
  });

  test('rotates the log and keeps bounded files', () async {
    for (var i = 0; i < 12; i++) {
      await diagnostics.record('test', 'event $i ${'x' * 80}');
    }

    final current = File(
      '${directory.path}${Platform.pathSeparator}netbuilder.log',
    );
    expect(current.existsSync(), isTrue);
    expect(
      File('${current.path}.1').existsSync(),
      isTrue,
      reason: 'the old log should be rotated, not truncated',
    );
    expect(
      File('${current.path}.2').existsSync(),
      isTrue,
      reason: 'rotation keeps two previous files',
    );
  });

  test('currentPath points at the local log', () async {
    await diagnostics.record('test', 'hello');
    final path = await diagnostics.currentPath();
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
  });
}
