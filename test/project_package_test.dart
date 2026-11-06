import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/plan_version_service.dart';
import 'package:net_builder/services/project_checks.dart';
import 'package:net_builder/services/project_package.dart';
import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final plan = NetworkIntent.parseSimple('portable', '1 router 1 switch 2 pcs');
  late MemoryService memory;
  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('nb-package-');
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/db');
    await MemoryService.createSchema(db);
    memory = MemoryService(injected: db);
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });
  });
  test(
    'export and import preserve design and checks without verified status',
    () async {
      final c = ProjectChecks.create(
        plan,
        plan.nodes.first.name,
        plan.nodes.last.name,
      );
      final bytes = ProjectPackage.encode(
        plan,
        checks: [c],
        artifacts: {
          'report.txt': Uint8List.fromList(utf8.encode('Design report')),
        },
      );
      final preview = ProjectPackage.inspect(bytes);
      expect(preview.plan.revision, plan.revision);
      expect(preview.artifacts.keys, ['report.txt']);
      final a = await ProjectPackage.import(bytes, memory);
      final b = await ProjectPackage.import(bytes, memory);
      expect(a.success, isFalse);
      expect(a.status, 'planned');
      expect(a.projectKey, isNot(b.projectKey));
      expect(a.projectName, isNot(b.projectName));
      final check = (await ProjectChecks(memory, a.projectKey).load()).single;
      expect(check.id, isNot(c.id));
      expect(check.status, 'unverified');
      expect(check.evidence, isEmpty);
      expect((await ProjectPackage.savedArtifacts(memory, a.projectKey)).keys, [
        'report.txt',
      ]);
      expect(
        await PlanVersionService.timeline(memory, projectKey: a.projectKey),
        hasLength(1),
      );
    },
  );
  test(
    'malformed, unsupported, corrupt, oversized and unsafe files write nothing',
    () async {
      expect(
        () => ProjectPackage.inspect(Uint8List.fromList([1, 2])),
        throwsFormatException,
      );
      expect(
        () => ProjectPackage.inspect(Uint8List(ProjectPackage.maxBytes + 1)),
        throwsFormatException,
      );
      final original =
          jsonDecode(utf8.decode(ProjectPackage.encode(plan))) as Map;
      original['version'] = 99;
      expect(
        () => ProjectPackage.inspect(
          Uint8List.fromList(utf8.encode(jsonEncode(original))),
        ),
        throwsFormatException,
      );
      for (final name in [
        '../report.txt',
        r'C:\escape.txt',
        'a/b.txt',
        '..\\a.txt',
        'report.exe',
      ]) {
        expect(
          () => ProjectPackage.encode(plan, artifacts: {name: Uint8List(1)}),
          throwsFormatException,
        );
      }
      final tampered =
          jsonDecode(utf8.decode(ProjectPackage.encode(plan))) as Map;
      tampered['payload']['plan']['projectName'] = 'changed';
      await expectLater(
        ProjectPackage.import(
          Uint8List.fromList(utf8.encode(jsonEncode(tampered))),
          memory,
        ),
        throwsFormatException,
      );
      expect(await memory.recentBuilds(), isEmpty);
    },
  );
  test(
    'attachment checksum is validated even if manifest hash is recalculated',
    () {
      final data =
          jsonDecode(
                utf8.decode(
                  ProjectPackage.encode(
                    plan,
                    artifacts: {'report.txt': Uint8List(2)},
                  ),
                ),
              )
              as Map;
      data['payload']['artifacts'][0]['data'] = base64Encode([1, 2]);
      data['sha256'] = sha256
          .convert(utf8.encode(jsonEncode(data['payload'])))
          .toString();
      expect(
        () => ProjectPackage.inspect(
          Uint8List.fromList(utf8.encode(jsonEncode(data))),
        ),
        throwsFormatException,
      );
    },
  );
  test('optional bundled pkt is generated locally and decrypts', () async {
    final record = BuildRecord(
      projectName: plan.projectName,
      instruction: '',
      intentJson: jsonEncode(plan.toPlannerJson()),
      target: 'packet-tracer',
      createdAt: DateTime.now(),
    );
    final bytes = await ProjectPackage.export(record, memory, includePkt: true);
    final preview = ProjectPackage.inspect(bytes);
    expect(
      utf8.decode(decryptPkt(preview.artifacts['design.pkt']!)),
      contains('<PACKETTRACER5'),
    );
    expect(
      preview.artifacts.keys,
      containsAll(['configuration.txt', 'report.txt', 'design.pkt']),
    );
  });

  test('a failed companion save rolls back the entire import', () async {
    await memory.injected!.execute(
      "CREATE TRIGGER refuse_package BEFORE INSERT ON prefs WHEN NEW.k LIKE 'project-package:%' BEGIN SELECT RAISE(ABORT, 'forced test failure'); END",
    );
    final bytes = ProjectPackage.encode(
      plan,
      checks: [
        ProjectChecks.create(plan, plan.nodes.first.name, plan.nodes.last.name),
      ],
    );
    await expectLater(ProjectPackage.import(bytes, memory), throwsA(anything));
    expect(await memory.recentBuilds(), isEmpty);
    expect(await memory.allPrefs(), isEmpty);
  });

  test('exports omit credentials from both design and decoded reports', () async {
    final secretPlan = NetworkIntent.fromJson({
      ...plan.toJson(),
      'security': {
        'aaa': true,
        'aaaPassword': 'SourceOnly123',
        'vpnPreSharedKey': 'SourceOnly456',
      },
    });
    final row = BuildRecord(
      projectName: secretPlan.projectName,
      instruction: '',
      intentJson: jsonEncode(secretPlan.toJson()),
      target: 'packet-tracer',
      createdAt: DateTime.now(),
    );
    final bytes = await ProjectPackage.export(row, memory);
    final preview = ProjectPackage.inspect(bytes);
    final allText =
        '${utf8.decode(bytes)} ${preview.artifacts.values.map(utf8.decode).join(' ')}';
    expect(allText, isNot(contains('SourceOnly')));
  });
}
