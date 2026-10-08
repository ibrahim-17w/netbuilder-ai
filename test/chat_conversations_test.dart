import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/widgets/settings_drawer.dart';
import 'package:provider/provider.dart';
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

  // The sidebar is the whole settings surface, so it has to open on the
  // smallest phone the app still supports. A drawer wider than its own
  // buttons paints yellow-and-black overflow bars across them.
  testWidgets('the drawer opens on a 320dp phone without overflowing',
      (tester) async {
    final settings = SettingsService();
    // The provider buttons only exist for the OpenAI-compatible provider,
    // which is not the default one.
    await settings.setProviderName('openai');
    tester.view.physicalSize = const Size(320, 4096);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MemoryService>(create: (_) => MemoryService()),
        ],
        child: const MaterialApp(
          home: Scaffold(drawer: SettingsDrawer(), body: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    // Only a row that is actually laid out can overflow, and a ListView
    // lays its children out in order - so the surface has to be tall enough
    // to build the last one, or the rows below the fold would go unchecked.
    expect(find.textContaining('/budget <tokens>'), findsOneWidget,
        reason: 'the test surface holds the entire drawer');

    expect(find.widgetWithText(FilledButton, 'Save provider'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Test connection'),
        findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Choose folder'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save folder'), findsOneWidget);

    // An overflow reaches the test as an exception, not as a wrong number.
    expect(tester.takeException(), isNull,
        reason: 'a drawer row is wider than the drawer itself');
  });
}
