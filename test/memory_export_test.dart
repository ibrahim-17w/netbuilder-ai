import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/build_attempt.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What "export everything the app remembers" has to mean.
///
/// The old export kept the newest 500 chat turns and nothing about which chat
/// they belonged to, no title, no summary, no session state and no change log.
/// A file like that restores into an app that has forgotten everything it
/// established, so the tests below check the whole shape of a backup, not just
/// that some JSON came out.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<MemoryService> fresh() async {
    final dir = await Directory.systemTemp.createTemp('nb-export-test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/export.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  ChatMessage turn(String role, String text) => ChatMessage(
    role: role,
    text: text,
    createdAt: DateTime.now().toIso8601String(),
  );

  Future<Map<String, dynamic>> backup(MemoryService mem) async =>
      jsonDecode(await mem.exportJson()) as Map<String, dynamic>;

  List<Map<String, dynamic>> rows(Object? list) =>
      (list as List).cast<Map<String, dynamic>>();

  test('a conversation with a summary, state and changes survives a round trip',
      () async {
    final mem = await fresh();
    await mem.logChat(turn('user', 'R1 has no route to 10.1.1.2'),
        conversation: 'chi');
    await mem.logChat(turn('model', 'the static route points at the old gateway'),
        conversation: 'chi');
    await mem.ensureConversation('chi', project: 'office.pkt');
    await mem.renameConversation('chi', 'R1 Route Problem');
    await mem.setConversationSummary('chi', 'the user is fixing R1 routing',
        upToId: 1);
    await mem.setSessionState('chi', '{"project":"office.pkt","turns":2}');
    final changeId = await mem.logChange(
      conversation: 'chi',
      device: 'R1',
      interface: 'g0/0',
      field: 'ipAddress',
      oldValue: '10.0.0.1/30',
      newValue: '10.0.0.2/30',
      source: 'pkt_fix',
    );

    final json = await backup(mem);
    expect(json['schemaVersion'], MemoryService.exportSchemaVersion);

    final conversation = rows(json['conversations']).single;
    expect(conversation['id'], 'chi');
    expect(conversation['title'], 'R1 Route Problem');
    expect(conversation['project'], 'office.pkt');
    expect(conversation['summary'], 'the user is fixing R1 routing');
    expect(conversation['summaryUpToId'], 1);
    expect(jsonDecode(conversation['stateJson'] as String),
        {'project': 'office.pkt', 'turns': 2});

    // The transcript without its conversation is a list of anonymous lines:
    // nothing could file turn 2 under turn 1's chat.
    final chat = rows(json['chat']);
    expect(chat, hasLength(2));
    expect(chat.first['conversation'], 'chi');
    expect(chat.first['role'], 'user');
    expect(chat.first['text'], 'R1 has no route to 10.1.1.2');
    expect(chat.last['text'], 'the static route points at the old gateway');
    expect(chat.first['images'], isEmpty);
    expect(chat.first['executed'], isEmpty);

    // "Undo that" reads this log, both values, so a restore can still undo.
    final change = rows(json['changes']).single;
    expect(change['actionId'], changeId);
    expect(change['conversation'], 'chi');
    expect(change['device'], 'R1');
    expect(change['interface'], 'g0/0');
    expect(change['oldValue'], '10.0.0.1/30');
    expect(change['newValue'], '10.0.0.2/30');
    expect(change['source'], 'pkt_fix');
  });

  test('an undone change keeps its undo flag', () async {
    final mem = await fresh();
    final first = await mem.logChange(
      conversation: 'chi',
      device: 'R1',
      field: 'ipAddress',
      oldValue: 'a',
      newValue: 'b',
    );
    await mem.markChangeUndone(first);

    final change = rows((await backup(mem))['changes']).single;
    expect(change['undoneAt'], isNotEmpty,
        reason: 'without it a restore would offer the same edit again');
  });

  test('the whole transcript is exported, not the newest 500 turns', () async {
    final mem = await fresh();
    for (var i = 0; i < 520; i++) {
      await mem.logChat(turn('user', 'turn $i'), conversation: 'chi');
    }

    final chat = rows((await backup(mem))['chat']);
    expect(chat, hasLength(520));
    expect(chat.first['text'], 'turn 0',
        reason: 'the oldest turn is what the first half of a backup is for');
    expect(chat.last['text'], 'turn 519');
  });

  test('builds, attempts, rules and preferences are in there', () async {
    final mem = await fresh();
    final now = DateTime.now();
    final buildId = await mem.logBuild(
      BuildRecord(
        projectName: 'lab',
        instruction: '1 router 1 switch',
        intentJson: '{}',
        target: 'packet-tracer',
        success: false,
        status: 'failed',
        error: 'no module',
        createdAt: now,
      ),
    );
    final attemptId = await mem.logAttempt(
      BuildAttempt(
        buildId: buildId,
        projectName: 'lab',
        instruction: '1 router 1 switch',
        intentJson: '{}',
        target: 'packet-tracer',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await mem.updateAttempt(
      id: attemptId,
      status: 'failed',
      failureKind: 'missing_module',
      failureDetail: 'serial module not installed',
    );
    await mem.addRule('Prefer static routing on small labs');
    await mem.setPref('target', 'packet-tracer');

    final json = await backup(mem);
    expect(rows(json['builds']).single['id'], buildId);
    final attempt = rows(json['attempts']).single;
    expect(attempt['buildId'], buildId,
        reason: 'an attempt detached from its build explains nothing');
    expect(attempt['failureKind'], 'missing_module');
    expect(attempt['failureDetail'], 'serial module not installed');
    expect(rows(json['rules']).single['ruleText'],
        'Prefer static routing on small labs');
    expect(json['prefs'], {'target': 'packet-tracer'});
  });

  test('every table is present even when nothing was ever written', () async {
    final json = await backup(await fresh());
    expect(
      json.keys,
      containsAll([
        'schemaVersion',
        'exportedAt',
        'builds',
        'attempts',
        'rules',
        'prefs',
        'conversations',
        'chat',
        'changes',
      ]),
    );
    expect(rows(json['chat']), isEmpty);
    expect(rows(json['conversations']), isEmpty);
  });

  test('a store with no database exports an empty document, not a throw',
      () async {
    final json = jsonDecode(await MemoryService().exportJson());
    expect(json['schemaVersion'], MemoryService.exportSchemaVersion);
    expect(json['chat'], isEmpty);
    expect(json['conversations'], isEmpty);
  });
}
