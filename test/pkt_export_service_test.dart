import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/pkt/on_device_pkt_builder.dart';
import 'package:net_builder/services/pkt/pkt_export_service.dart';

/// Where a built .pkt actually lands on a phone.
///
/// The bug this covers: the on-device build wrote into the app-private
/// documents directory and never looked at the folder chosen in Settings, so
/// on Android - where no file manager can browse app-private storage - the
/// file was saved somewhere the user could never find it, while the app
/// reported a successful build.
///
/// So the tests here are about LOCATION and HONESTY:
///
/// * a chosen folder is where the file goes, manifest included;
/// * a folder that cannot be written to is refused with a reason rather than
///   stored and silently ignored;
/// * when there is no folder, the system save dialog is the only way out, and
///   the app reports where it really wrote - or says it was cancelled.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nb-export');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File write(String name, [String body = 'x']) =>
      File('${tmp.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync(body);

  test('no folder chosen is reported as exactly that', () async {
    final folder = await PktExportService.resolveFolder('   ');
    expect(folder.dir, isNull);
    expect(folder.why, contains('no folder'));
  });

  test('a folder that does not exist yet is created and used', () async {
    final path = '${tmp.path}${Platform.pathSeparator}new';
    final folder = await PktExportService.resolveFolder(path);
    expect(folder.why, '');
    expect(folder.dir!.existsSync(), isTrue);
    // And it is genuinely writable - that is what resolveFolder checks.
    final probe = File('${folder.dir!.path}${Platform.pathSeparator}probe');
    probe.writeAsStringSync('ok');
    expect(probe.existsSync(), isTrue);
  });

  test('a path that is a file, not a folder, is refused with the reason',
      () async {
    final file = write('not-a-folder');
    final folder = await PktExportService.resolveFolder(file.path);
    expect(folder.dir, isNull);
    expect(folder.why, isNotEmpty);
  });

  test('a copy does not silently overwrite a different lab', () async {
    final source = write('lab.pkt', 'first');
    final target = Directory('${tmp.path}${Platform.pathSeparator}out')
      ..createSync();
    final existing = File('${target.path}${Platform.pathSeparator}lab.pkt')
      ..writeAsStringSync('a different lab');
    final out = await PktExportService.copyInto(source, target);
    expect(out.path, isNot(existing.path));
    expect(existing.readAsStringSync(), 'a different lab',
        reason: 'the other lab must survive untouched');
    expect(out.readAsStringSync(), 'first');
  });

  test('the save dialog path reports the folder it really wrote to',
      () async {
    final file = write('netbuilder-1.pkt', 'pkt bytes');
    final manifest = write('netbuilder-1.pkt.netbuilder.json', '{}');
    final asked = <String>[];
    final result = await PktExportService.saveToChosenFolder(
      file,
      companion: manifest,
      saveBytes: ({
        required String fileName,
        required Uint8List bytes,
        String? type,
        String? dialogTitle,
      }) async {
        asked.add(fileName);
        // What the plugin does: write the bytes where the user pointed, and
        // report back a path.
        final out = File('${tmp.path}${Platform.pathSeparator}$fileName');
        out.writeAsBytesSync(bytes);
        return out.path;
      },
    );
    expect(result.prompted, isTrue);
    expect(result.path, isNotEmpty);
    expect(File(result.path).readAsStringSync(), 'pkt bytes');
    expect(asked, ['netbuilder-1.pkt', 'netbuilder-1.pkt.netbuilder.json'],
        reason: 'the manifest must go out too - it is what identifies the file');
    expect(result.companionPath, isNotNull);
  });

  test('a cancelled dialog reports no path at all', () async {
    final file = write('netbuilder-2.pkt', 'pkt bytes');
    final result = await PktExportService.saveToChosenFolder(
      file,
      saveBytes: ({
        required String fileName,
        required Uint8List bytes,
        String? type,
        String? dialogTitle,
      }) async =>
          null,
    );
    expect(result.cancelled, isTrue);
    expect(result.path, isEmpty,
        reason: 'a cancelled save must not report a location');
    expect(result.message, contains('still on this device'));
  });

  test('a failed save says so instead of claiming a location', () async {
    final file = write('netbuilder-3.pkt', 'pkt bytes');
    final result = await PktExportService.saveToChosenFolder(
      file,
      saveBytes: ({
        required String fileName,
        required Uint8List bytes,
        String? type,
        String? dialogTitle,
      }) async =>
          throw StateError('no space left'),
    );
    expect(result.path, isEmpty);
    expect(result.message, contains('no space left'));
  });

  test('a phone build lands in the chosen folder, manifest included',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final chosen = Directory('${tmp.path}${Platform.pathSeparator}chosen')
      ..createSync();
    final privateDir = Directory('${tmp.path}${Platform.pathSeparator}private')
      ..createSync();
    final intent = NetworkIntent.parseSimple('lab', '1 router and 1 PC');
    final built = await OnDevicePktBuilder.buildFromPlan(
      plan: PacketTracerAdapter.autopilotPlan(intent),
      appDir: () async => privateDir,
      outDir: () async => chosen,
      filename: 'lab.pkt',
    );
    expect(built, isNotNull);
    expect(built!.file.parent.path, chosen.path,
        reason: 'the chosen folder IS the destination');
    expect(built.file.existsSync(), isTrue);
    expect(built.manifest.existsSync(), isTrue);
    expect(built.manifest.parent.path, chosen.path);
    // Nothing was left behind in app-private storage.
    expect(
      Directory('${privateDir.path}${Platform.pathSeparator}pkt')
          .existsSync(),
      isFalse,
    );
    final manifest = jsonDecode(built.manifest.readAsStringSync());
    expect(manifest['generator'], 'on-device');
  });
}
