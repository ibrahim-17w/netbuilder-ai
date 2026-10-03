import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/conversation_titles.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Layer 3 of the memory: what survives a restart.
///
/// The store drives the real schema, not a stand-in, because the thing being
/// tested IS the storage: a title that is only in widget state, a summary that
/// is re-derived on every request, or a change log the chat cannot query are
/// exactly how "the assistant forgot" happens again.

ChatMessage _turn(String role, String text) => ChatMessage(
  role: role,
  text: text,
  createdAt: DateTime.now().toIso8601String(),
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<MemoryService> fresh() async {
    final dir = await Directory.systemTemp.createTemp('nb-store-test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/store.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  group('conversation records', () {
    test('a conversation keeps its title, project and summary', () async {
      final mem = await fresh();
      await mem.logChat(_turn('user', 'can PC1 reach Server0?'),
          conversation: 'chi');
      await mem.ensureConversation('chi', project: 'office-network.pkt');
      await mem.renameConversation('chi', 'PC1 Gateway Problem');
      await mem.setConversationSummary('chi', 'the user asked about PC1');

      final listed = (await mem.conversations()).single;
      expect(listed['id'], 'chi');
      expect(listed['title'], 'PC1 Gateway Problem');
      expect(listed['project'], 'office-network.pkt');
      expect(listed['summary'], 'the user asked about PC1');

      final meta = await mem.conversationMeta('chi');
      expect(meta!['title'], 'PC1 Gateway Problem');
      expect(await mem.conversationSummary('chi'), 'the user asked about PC1');
    });

    test('without a stored title the first thing said is the title', () async {
      final mem = await fresh();
      await mem.logChat(_turn('user', 'why is the trunk down?'),
          conversation: 'beta');
      expect((await mem.conversations()).single['title'],
          'why is the trunk down?');
    });

    test('a rename is not overwritten by a later automatic title', () async {
      final mem = await fresh();
      await mem.ensureConversation('chi', title: '');
      await mem.renameConversation('chi', 'My own name');
      await mem.ensureConversation('chi', title: 'Generated Title');
      expect((await mem.conversationMeta('chi'))!['title'], 'My own name');
    });

    test('search finds a chat by a device named mid-conversation', () async {
      final mem = await fresh();
      await mem.logChat(_turn('user', 'hello there'), conversation: 'alpha');
      await mem.logChat(_turn('user', 'R7 has no route to the core'),
          conversation: 'beta');

      final hits = await mem.conversations(query: 'R7');
      expect(hits.map((c) => c['id']).toList(), ['beta']);
      expect(await mem.conversations(query: 'nothing-like-this'), isEmpty);
      // A title search works too, without any message text matching.
      await mem.renameConversation('alpha', 'Office analysis');
      final byTitle = await mem.conversations(query: 'office');
      expect(byTitle.map((c) => c['id']).toList(), ['alpha']);
    });

    test('the sidebar can group by time', () async {
      final mem = await fresh();
      await mem.logChat(_turn('user', 'a question'), conversation: 'alpha');
      final chat = (await mem.conversations()).single;
      expect(chat['at'], isA<int>());
      expect(chat['at'], greaterThan(0));
    });

    test('deleting a conversation takes its state and its change log',
        () async {
      final mem = await fresh();
      await mem.logChat(_turn('user', 'x'), conversation: 'alpha');
      await mem.setSessionState('alpha', '{"project":"lab"}');
      await mem.logChange(
        conversation: 'alpha',
        device: 'R1',
        interface: 'g0/0',
        field: 'ipAddress',
        oldValue: '10.0.0.1/30',
        newValue: '10.0.0.9/30',
      );

      await mem.clearChat(conversation: 'alpha');
      expect(await mem.recentChat(conversation: 'alpha'), isEmpty);
      expect(await mem.conversationMeta('alpha'), isNull);
      expect(await mem.recentChanges(conversation: 'alpha'), isEmpty);
      expect(await mem.conversations(), isEmpty);
    });

    test('a corrupt state blob reads as an empty state, not a crash',
        () async {
      final mem = await fresh();
      await mem.setSessionState('alpha', '{not json');
      expect(await mem.sessionStateJson('alpha'), '{not json');
    });

    test('a store with no database is inert instead of throwing', () async {
      final mem = MemoryService();
      expect(await mem.conversationMeta('x'), isNull);
      expect(await mem.recentChanges(), isEmpty);
      expect(await mem.lastChange(), isNull);
      await mem.setSessionState('x', '{}');
      expect(await mem.conversations(), isEmpty);
    });
  });

  group('the change log makes undo a lookup', () {
    test('TEST 5: the newest change to a named device is found exactly',
        () async {
      final mem = await fresh();
      await mem.logChange(
        conversation: 'chi',
        device: 'R1',
        interface: 'g0/0',
        field: 'ipAddress',
        oldValue: '10.0.0.1/30',
        newValue: '10.0.0.2/30',
      );
      final id = await mem.logChange(
        conversation: 'chi',
        device: 'R1',
        interface: 'g0/0',
        field: 'ipAddress',
        oldValue: '10.0.0.2/30',
        newValue: '10.0.0.254/24',
      );
      await mem.logChange(
        conversation: 'chi',
        device: 'R2',
        interface: 'g0/0',
        field: 'ipAddress',
        oldValue: '10.0.1.1/30',
        newValue: '10.0.1.2/30',
      );

      final aboutR1 = await mem.lastChange(conversation: 'chi', device: 'R1');
      expect(aboutR1!['actionId'], id,
          reason: 'the newest change to R1, not the newest change overall');
      expect(aboutR1['oldValue'], '10.0.0.2/30');
      expect(aboutR1['newValue'], '10.0.0.254/24');
      expect(aboutR1['interface'], 'g0/0');

      // "undo that" with no device named means the most recent change.
      final last = await mem.lastChange(conversation: 'chi');
      expect(last!['device'], 'R2');
    });

    test('an undone change is not offered again', () async {
      final mem = await fresh();
      final first = await mem.logChange(
        conversation: 'chi',
        device: 'R1',
        field: 'ipAddress',
        oldValue: 'a',
        newValue: 'b',
      );
      await mem.logChange(
        conversation: 'chi',
        device: 'R1',
        field: 'ipAddress',
        oldValue: 'b',
        newValue: 'c',
      );
      await mem.markChangeUndone(first);
      final next = await mem.lastChange(conversation: 'chi', device: 'R1');
      expect(next!['newValue'], 'c');
      final restored = await mem.recentChanges(conversation: 'chi', device: 'R1');
      expect((restored.last['undoneAt'] ?? '').toString(), isNotEmpty);
    });

    test('changes are scoped to their conversation', () async {
      final mem = await fresh();
      await mem.logChange(
        conversation: 'alpha',
        device: 'R1',
        field: 'ipAddress',
        oldValue: 'a',
        newValue: 'b',
      );
      expect(await mem.lastChange(conversation: 'beta'), isNull);
      expect((await mem.lastChange(conversation: 'alpha'))!['device'], 'R1');
    });
  });

  group('generated titles say what the chat is about', () {
    test('a topic dominates', () {
      expect(ConversationTitles.generate('why is OSPF not forming?'),
          'OSPF Troubleshooting');
      expect(ConversationTitles.generate('the VLAN trunk is down'),
          'VLAN Troubleshooting');
    });

    test('a device and a topic together read like a problem', () {
      expect(
        ConversationTitles.generate('PC1 has the wrong default gateway'),
        'PC1 Gateway Problem',
      );
    });

    test('a named project is the subject', () {
      expect(
        ConversationTitles.generate('analyze office-network.pkt please'),
        contains('Network Analysis'),
      );
    });

    test('otherwise the user words are used, cut on a word boundary', () {
      final title = ConversationTitles.generate(
        'please explain how the branch router forwards traffic to the '
        'internet in this lab',
      );
      expect(title.length, lessThanOrEqualTo(60));
      expect(title, isNot(startsWith('please')));
      expect(title.endsWith('...'), isTrue);
    });

    test('a greeting does not become a title', () {
      expect(ConversationTitles.generate(''), 'New chat');
    });
  });
}
