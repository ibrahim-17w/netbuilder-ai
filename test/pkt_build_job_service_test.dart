import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:net_builder/services/pkt/on_device_pkt_builder.dart';
import 'package:net_builder/services/pkt_build_job_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('completed build history survives a service restart', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('pkt-job-history-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}lab.pkt');
    final manifest = File('${file.path}.netbuilder.json');
    await file.writeAsBytes([1, 2, 3]);
    await manifest.writeAsString('{}');

    final jobs = PktBuildJobService.createForTesting();
    await jobs.start(
      project: 'Office network',
      build: (_) async => OnDeviceBuild(
        file: file,
        xml: '<PACKETTRACER5/>',
        refIds: const {},
        warnings: const [],
        manifest: manifest,
        report: const {'deviceCount': 4, 'linkCount': 3},
      ),
    );
    await jobs.flushForTesting();

    final restored = PktBuildJobService.createForTesting();
    await restored.loadHistory();
    expect(restored.history, hasLength(1));
    expect(restored.history.single.project, 'Office network');
    expect(restored.history.single.deviceCount, 4);
    expect(restored.history.single.linkCount, 3);
    expect(restored.history.single.filePath, file.path);
    expect(restored.status, PktBuildJobStatus.ready);
    expect(restored.result?.file.path, file.path);

    restored.markSaved('D:/Labs/lab.pkt');
    await restored.flushForTesting();
    restored.dismiss();
    await restored.flushForTesting();

    final afterDismiss = PktBuildJobService.createForTesting();
    await afterDismiss.loadHistory();
    expect(afterDismiss.status, PktBuildJobStatus.idle);
    expect(afterDismiss.history.single.status, PktBuildJobStatus.saved);
    expect(afterDismiss.history.single.savedLocation, 'D:/Labs/lab.pkt');
  });
}
