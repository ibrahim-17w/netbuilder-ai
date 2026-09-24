import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The sidebar lists chats, so the store has to keep them apart. The storage
/// tests drive the real database schema, not a stand-in.

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
    // A temp file, not ":memory:": sqflite returns the same cached database
    // for a repeated in-memory path, so a second test would try to create the
    // schema on a database that already has it.
    final dir = await Directory.systemTemp.createTemp('nb-chat-test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // A leftover temp directory is not worth failing a test over.
      }
    });
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/chat.db');
    await MemoryService.createSchema(db);
    return MemoryService(injected: db);
  }

  test('each conversation keeps its own transcript', () async {
    final memory = await fresh();
    await memory.logChat(_turn('user', 'first chat question'),
        conversation: 'alpha');
    await memory.logChat(_turn('model', 'first chat answer'),
        conversation: 'alpha');
    await memory.logChat(_turn('user', 'second chat question'),
        conversation: 'beta');

    final alpha = await memory.recentChat(conversation: 'alpha');
    final beta = await memory.recentChat(conversation: 'beta');

    expect(alpha.map((m) => m.text).toList(),
        ['first chat question', 'first chat answer']);
    expect(beta.map((m) => m.text).toList(), ['second chat question']);
  });

  test('the sidebar list groups by conversation, newest first', () async {
    final memory = await fresh();
    await memory.logChat(_turn('user', 'older chat'), conversation: 'alpha');
    await memory.logChat(_turn('user', 'newer chat'), conversation: 'beta');

    final chats = await memory.conversations();
    expect(chats.map((c) => c['id']).toList(), ['beta', 'alpha'],
        reason: 'the most recently used chat comes first');
    expect(chats.first['title'], 'newer chat',
        reason: 'a chat is recognised by what the user first said');
    expect(chats.first['messages'], 1);
  });

  test('a long first message is shortened for the list', () async {
    final memory = await fresh();
    await memory.logChat(_turn('user', 'x' * 200), conversation: 'alpha');
    final title = (await memory.conversations()).single['title'] as String;
    expect(title.length, lessThanOrEqualTo(63));
    expect(title.endsWith('...'), isTrue);
  });

  test('an unnamed conversation is filed under default', () async {
    final memory = await fresh();
    await memory.logChat(_turn('user', 'no name given'));

    final chats = await memory.conversations();
    expect(chats.single['id'], 'default');
    expect(await memory.recentChat(conversation: 'default'), hasLength(1));
  });

  test('the whole log is still readable when no conversation is named',
      () async {
    final memory = await fresh();
    await memory.logChat(_turn('user', 'a'), conversation: 'alpha');
    await memory.logChat(_turn('user', 'b'), conversation: 'beta');
    expect(await memory.recentChat(), hasLength(2));
  });

  test('an empty store lists no chats rather than inventing one', () async {
    final memory = await fresh();
    expect(await memory.conversations(), isEmpty);
  });

  // NOTE: there is deliberately no widget test that opens the sidebar here.
  // Doing so surfaced a pre-existing horizontal overflow inside the drawer
  // ("A RenderFlex overflowed by 257 pixels on the right"), which is a real
  // layout bug a user would see as striped bars. It is recorded in
  // packaging/UI-REDESIGN-2026-09-22.md rather than hidden by a passing test.
}
