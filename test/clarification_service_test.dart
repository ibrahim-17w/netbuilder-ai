import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:net_builder/models/design_brief.dart';
import 'package:net_builder/models/environment_profile.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/clarification_service.dart';
import 'package:net_builder/services/memory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<MemoryService> fresh() async {
    final dir = await Directory.systemTemp.createTemp('nb-clarify-test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/c.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  NetworkIntent plan({int routers = 0, int servers = 0}) {
    final nodes = <NetNode>[
      for (var i = 0; i < routers; i++)
        NetNode(name: 'R${i + 1}', type: 'router'),
      for (var i = 0; i < servers; i++)
        NetNode(name: 'SRV${i + 1}', type: 'server'),
    ];
    return NetworkIntent(projectName: 'lab', nodes: nodes);
  }

  group('neededFor', () {
    test('scale is always asked while it is missing', () {
      final qs = ClarificationService.neededFor(
        brief: const DesignBrief(),
        rememberedQuestionIds: const {},
      );
      expect(qs.map((q) => q.id), contains('scale'));
    });

    test('routing is asked only with 2+ routers in the plan', () {
      final one = ClarificationService.neededFor(
        brief: const DesignBrief(),
        plan: plan(routers: 1),
        rememberedQuestionIds: const {},
      );
      expect(one.map((q) => q.id), isNot(contains('routing')));

      final two = ClarificationService.neededFor(
        brief: const DesignBrief(),
        plan: plan(routers: 2),
        rememberedQuestionIds: const {},
      );
      expect(two.map((q) => q.id), contains('routing'));
    });

    test('segmentation is asked with a server or a separating venue', () {
      final withServer = ClarificationService.neededFor(
        brief: const DesignBrief(),
        plan: plan(servers: 1),
        rememberedQuestionIds: const {},
      );
      expect(withServer.map((q) => q.id), contains('segmentation'));

      final officeVenue = ClarificationService.neededFor(
        brief: const DesignBrief(),
        profile: const EnvironmentProfile(venue: 'office'),
        rememberedQuestionIds: const {},
      );
      expect(officeVenue.map((q) => q.id), contains('segmentation'));

      final homeNoServer = ClarificationService.neededFor(
        brief: const DesignBrief(),
        plan: plan(),
        profile: const EnvironmentProfile(venue: 'home'),
        rememberedQuestionIds: const {},
      );
      expect(homeNoServer.map((q) => q.id), isNot(contains('segmentation')));
    });

    test('filled slots and remembered ids are never asked again', () {
      final brief = const DesignBrief().withFact(
        DesignBrief.scale,
        const BriefFact(value: '40', display: '40 users'),
      );
      final qs = ClarificationService.neededFor(
        brief: brief,
        plan: plan(routers: 2),
        rememberedQuestionIds: const {'routing'},
      );
      expect(qs.map((q) => q.id), isNot(contains('scale')));
      expect(qs.map((q) => q.id), isNot(contains('routing')));
    });

    test('at most two questions, critical ones first', () {
      final qs = ClarificationService.neededFor(
        brief: const DesignBrief(),
        plan: plan(routers: 2, servers: 1),
        profile: const EnvironmentProfile(venue: 'office'),
        rememberedQuestionIds: const {},
      );
      expect(qs.length, 2);
      expect(qs.first.id, 'scale');
      expect(qs.last.id, 'routing');
    });
  });

  group('resolveAnswer', () {
    test('quick replies map exactly, case-insensitively', () {
      final fact = ClarificationService.resolveAnswer(
        ClarificationService.routingQuestion,
        'ospf',
      );
      expect(fact!.value, 'ospf');
      expect(fact.display, 'OSPF');

      final titled = ClarificationService.resolveAnswer(
        ClarificationService.routingQuestion,
        'Static routes',
      );
      expect(titled!.value, 'static');
    });

    test('free text resolves by keyword', () {
      expect(
        ClarificationService.resolveAnswer(
          ClarificationService.scaleQuestion,
          'about 40 users',
        )!.value,
        '40',
      );
      expect(
        ClarificationService.resolveAnswer(
          ClarificationService.segmentationQuestion,
          'just one flat network',
        )!.value,
        'none',
      );
      expect(
        ClarificationService.resolveAnswer(
          ClarificationService.segmentationQuestion,
          'split into VLANs',
        )!.value,
        'vlans',
      );
    });

    test('negations and gibberish are rejected, not guessed', () {
      expect(
        ClarificationService.resolveAnswer(
          ClarificationService.routingQuestion,
          'not static',
        ),
        isNull,
      );
      expect(
        ClarificationService.resolveAnswer(
          ClarificationService.scaleQuestion,
          'lots',
        ),
        isNull,
      );
      expect(
        ClarificationService.resolveAnswer(
          ClarificationService.routingQuestion,
          '',
        ),
        isNull,
      );
    });
  });

  group('remembered answers through the store', () {
    test('venue-specific answer wins over a global one', () async {
      final mem = await fresh();
      await mem.rememberClarification('routing', 'static');
      await mem.rememberClarification(
        'routing',
        'ospf',
        venue: 'office',
        scale: 40,
      );
      final office = await ClarificationService.rememberedAnswer(
        questionId: 'routing',
        profile: const EnvironmentProfile(venue: 'office', scale: 40),
        mem: mem,
      );
      expect(office!.value, 'ospf');
      expect(office.origin, BriefSource.remembered);
      expect(office.source, 'remembered from an earlier answer');

      final home = await ClarificationService.rememberedAnswer(
        questionId: 'routing',
        profile: const EnvironmentProfile(venue: 'home'),
        mem: mem,
      );
      expect(home!.value, 'static',
          reason: 'no home answer exists, so the global one applies');
    });

    test('a different venue with no global answer applies nothing', () async {
      final mem = await fresh();
      await mem.rememberClarification('routing', 'ospf', venue: 'office');
      final home = await ClarificationService.rememberedAnswer(
        questionId: 'routing',
        profile: const EnvironmentProfile(venue: 'home'),
        mem: mem,
      );
      expect(home, isNull);
    });

    test('an unresolvable stored answer is not replayed', () async {
      final mem = await fresh();
      await dbInsert(mem, questionId: 'routing', answer: 'the fast one');
      final answer = await ClarificationService.rememberedAnswer(
        questionId: 'routing',
        profile: const EnvironmentProfile(venue: 'office'),
        mem: mem,
      );
      expect(answer, isNull);
    });

    test('forget removes the answer', () async {
      final mem = await fresh();
      await mem.rememberClarification('routing', 'ospf');
      final rows = await mem.clarificationAnswers();
      expect(rows, isNotEmpty);
      await mem.forgetClarification((rows.first['id'] as num).toInt());
      expect(
        await mem.answerForClarification('routing', null),
        isNull,
      );
    });
  });

  group('export and clearAll', () {
    test('export carries clarification answers with schema version 4',
        () async {
      final mem = await fresh();
      await mem.rememberClarification('scale', '40', venue: 'office');
      final doc =
          jsonDecode(await mem.exportJson()) as Map<String, dynamic>;
      expect(doc['schemaVersion'], 4);
      final rows = (doc['clarificationAnswers'] as List)
          .cast<Map<String, dynamic>>();
      expect(rows, hasLength(1));
      expect(rows.first['question_id'], 'scale');
      expect(rows.first['venue'], 'office');
    });

    test('clearAll forgets clarifications too', () async {
      final mem = await fresh();
      await mem.rememberClarification('scale', '40');
      await mem.clearAll();
      expect(await mem.clarificationAnswers(), isEmpty);
    });
  });
}

/// The store's insert is exposed through [MemoryService.rememberClarification];
/// a raw insert is needed only for the unresolvable-answer case.
Future<void> dbInsert(
  MemoryService mem, {
  required String questionId,
  required String answer,
}) async {
  await (mem.injected!).insert('clarification_answer', {
    'question_id': questionId,
    'answer': answer,
    'venue': '',
    'scale': 0,
    'created_at': DateTime.now().toIso8601String(),
  });
}
