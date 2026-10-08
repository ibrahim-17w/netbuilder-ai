import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/learned_answers_service.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/offline_assistant_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Learning from keyed-model answers, replayed offline: what is learnable,
/// what is rejected (refusals, computed-fact conflicts), how agreement
/// confirms an answer, how the best candidate is picked when the model has
/// said different things, and that the offline assistant replays the
/// learned answer for the same question.
void main() {
  group('what is a learnable question', () {
    test('questions are learnable', () {
      expect(LearnedAnswers.isLearnableQuestion('what is ip'), isTrue);
      expect(LearnedAnswers.isLearnableQuestion('What is a VLAN?'), isTrue);
      expect(LearnedAnswers.isLearnableQuestion('how does ospf work'), isTrue);
      expect(
        LearnedAnswers.isLearnableQuestion(
          'what is the difference between a router and a switch',
        ),
        isTrue,
      );
    });

    test('requests, commands and off-topic asks are not', () {
      expect(LearnedAnswers.isLearnableQuestion('2 routers and 4 PCs'),
          isFalse);
      expect(LearnedAnswers.isLearnableQuestion('add another switch'),
          isFalse);
      expect(LearnedAnswers.isLearnableQuestion('fix the plan'), isFalse);
      expect(LearnedAnswers.isLearnableQuestion('/skills'), isFalse);
      expect(LearnedAnswers.isLearnableQuestion('what is the weather today'),
          isFalse);
      expect(LearnedAnswers.isLearnableQuestion('build a lab'), isFalse);
    });
  });

  group('capture', () {
    LearnedAnswer candidate({
      String answer =
          'IP is the Internet Protocol - the addressing layer that gives '
          'every device an address and moves packets between them.',
    }) =>
      LearnedAnswer(
        qkey: LearnedAnswers.keyFor('what is ip'),
        question: 'what is ip',
        answer: answer,
        createdAt: '2026-01-01T00:00:00',
        lastSeenAt: '2026-01-01T00:00:00',
      );

    test('a good answer is learned', () {
      final c = LearnedAnswers.capture(
        question: 'what is ip',
        answer:
            'IP is the Internet Protocol - the addressing layer that gives '
            'every device an address and moves packets between them.',
        source: 'gemini',
        existing: const [],
      );
      expect(c.action, LearnedCapture.learned);
      expect(c.candidate!.qkey, 'what is ip');
    });

    test('refusals and error stubs are rejected', () {
      for (final bad in [
        "I'm sorry, I cannot help with that.",
        'As an AI language model, I cannot answer that question.',
        'short',
        '',
      ]) {
        final c = LearnedAnswers.capture(
          question: 'what is ip',
          answer: bad,
          source: 'gemini',
          existing: const [],
        );
        expect(c.action, LearnedCapture.rejected, reason: 'for: $bad');
      }
    });

    test('a computable fact conflict is rejected, an agreeing one is not',
        () {
      const q = 'how many usable hosts does 192.168.1.0/26 have';
      final right = LearnedAnswers.capture(
        question: q,
        answer: 'A /26 has 62 usable hosts: 64 total minus the network and '
            'broadcast addresses.',
        source: 'gemini',
        existing: const [],
      );
      expect(right.action, LearnedCapture.learned,
          reason: '62 matches the computed count');
      expect(right.candidate!.confirmed, isTrue,
          reason: 'a CIDR answer that survived the fact check is confirmed');
      final wrong = LearnedAnswers.capture(
        question: q,
        answer: 'A /26 has 126 usable hosts for your devices and addresses.',
        source: 'gemini',
        existing: const [],
      );
      expect(wrong.action, LearnedCapture.rejected,
          reason: '126 contradicts the computed 62');
    });

    test('agreement bumps the existing candidate instead of duplicating',
        () {
      final existing = [candidate()];
      final c = LearnedAnswers.capture(
        question: 'what is ip',
        answer:
            'IP, the Internet Protocol, is the addressing layer that gives '
            'every device an address and routes packets between them.',
        source: 'openai',
        existing: existing,
      );
      expect(c.action, LearnedCapture.agrees);
      expect(c.existingId, existing.first.id);
    });

    test('a contradicting answer becomes a separate candidate', () {
      final c = LearnedAnswers.capture(
        question: 'what is ip',
        answer:
            'IP stands for Internet Protocol, part of the TCP/IP suite '
            'defined in RFC 791, operating at the network layer.',
        source: 'openai',
        existing: [candidate()],
      );
      expect(c.action, LearnedCapture.learned);
    });
  });

  group('the smart pick', () {
    LearnedAnswer a({
      int id = 1,
      int seen = 1,
      bool confirmed = false,
      String lastSeen = '2026-01-01T00:00:00',
      String answer = 'answer a',
    }) => LearnedAnswer(
      id: id,
      qkey: 'q',
      question: 'q',
      answer: answer,
      seenCount: seen,
      confirmed: confirmed,
      createdAt: '2026-01-01T00:00:00',
      lastSeenAt: lastSeen,
    );

    test('confirmed beats unconfirmed', () {
      final best = LearnedAnswers.pickBest([
        a(id: 1, seen: 5),
        a(id: 2, confirmed: true),
      ]);
      expect(best!.id, 2);
    });

    test('agreement count beats recency among unconfirmed', () {
      final best = LearnedAnswers.pickBest([
        a(id: 1, seen: 3, lastSeen: '2026-01-01T00:00:00'),
        a(id: 2, seen: 1, lastSeen: '2026-02-01T00:00:00'),
      ]);
      expect(best!.id, 1);
    });

    test('recency breaks full ties', () {
      final best = LearnedAnswers.pickBest([
        a(id: 1, lastSeen: '2026-01-01T00:00:00'),
        a(id: 2, lastSeen: '2026-03-01T00:00:00'),
      ]);
      expect(best!.id, 2);
    });

    test('empty candidates stay null', () {
      expect(LearnedAnswers.pickBest(const []), isNull);
    });
  });

  group('agreement detection', () {
    test('the same knowledge in different words agrees', () {
      expect(
        LearnedAnswers.answersAgree(
          'OSPF is a link-state routing protocol that uses Dijkstra\'s '
          'shortest path first algorithm within an area.',
          'OSPF (Open Shortest Path First) is a link-state routing '
          'protocol; it computes routes with the shortest path first '
          'algorithm.',
        ),
        isTrue,
      );
    });

    test('different knowledge does not', () {
      expect(
        LearnedAnswers.answersAgree(
          'OSPF is a link-state routing protocol using areas and LSAs.',
          'A switch forwards frames by MAC address table lookups at '
          'layer two.',
        ),
        isFalse,
      );
    });
  });

  group('the store persists and replays learned answers', () {
    late MemoryService mem;
    late Directory dir;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('nb-learned-test');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/store.db');
      await MemoryService.createSchema(db);
      mem = MemoryService(injected: db);
    });

    test('learn, agree, pick, forget', () async {
      const q = 'what is a trunk port';
      final answer =
          'A trunk port carries multiple VLANs over one link - tag frames '
          'with 802.1Q on both ends, and configure it with switchport '
          'mode trunk.';
      await mem.learnAnswer(question: q, answer: answer, source: 'gemini');

      final first = await mem.bestLearnedAnswer(q);
      expect(first, isNotNull);
      expect(first!.confirmed, isFalse, reason: 'no CIDR, seen once');
      expect(first.answer, answer);

      // The model said the same thing again, differently worded: the
      // existing row is confirmed by agreement, not duplicated.
      await mem.learnAnswer(
        question: q,
        answer:
            'A trunk port carries multiple VLANs across a single link - '
            'tag the frames with 802.1Q on both ends, then set switchport '
            'mode trunk.',
        source: 'openai',
      );
      final second = await mem.bestLearnedAnswer(q);
      expect(second!.seenCount, 2);
      expect(second.confirmed, isTrue);

      // Case and punctuation land on the same key.
      final replay = await mem.bestLearnedAnswer('What is a trunk port?');
      expect(replay!.qkey, first.qkey);

      await mem.forgetLearnedAnswer(second.id);
      expect(await mem.bestLearnedAnswer(q), isNull);
    });

    test('rejections never reach the store', () async {
      await mem.learnAnswer(
        question: 'what is a wan',
        answer: "I'm sorry, I cannot help with that request.",
        source: 'gemini',
      );
      expect(await mem.bestLearnedAnswer('what is a wan'), isNull);
    });
  });

  group('the offline assistant replays a learned answer', () {
    test('same question, same answer - verbatim, no mode labels', () {
      final r = OfflineAssistantService.reply(
        rawText: 'what is ip',
        normalized: 'what is ip',
        target: 'packet-tracer',
        learnedAnswer: const LearnedAnswer(
          qkey: 'what is ip',
          question: 'what is ip',
          answer: 'IP is the Internet Protocol - the app learned this from '
              'your model key earlier.',
          source: 'gemini',
          createdAt: '2026-01-01T00:00:00',
          lastSeenAt: '2026-01-01T00:00:00',
        ),
      );
      expect(r.intent, 'learned');
      expect(r.text, contains('IP is the Internet Protocol'));
      // The replay is the answer, nothing else: no provenance line, no mode
      // label - that state lives in the top bar's AI pill.
      expect(r.text, isNot(contains('Learned earlier')));
      expect(r.text, isNot(contains('offline')));
    });

    test('without a learned answer nothing changes', () {
      final r = OfflineAssistantService.reply(
        rawText: 'what is ip',
        normalized: 'what is ip',
        target: 'packet-tracer',
      );
      expect(r.intent, isNot('learned'));
    });
  });
}
