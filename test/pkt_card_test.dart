import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';

/// Seeds the chat with a capture-analysis message, so the Approve / Reject /
/// Modify controls on a fix card can be checked at the UI level.
class _SeededMemory extends MemoryService {
  @override
  bool get ready => true;

  @override
  Future<List<ChatMessage>> recentChat({
    int limit = 60,
    String conversation = '',
  }) async => [
    ChatMessage(
      role: 'model',
      text: 'Capture decrypted and audited offline. 1 finding.',
      actions: [
        ChatAction(
          kind: 'pkt_fix',
          summary:
              'GigabitEthernet0/1 has ip address in its config but the saved '
              'port carries no IP',
          payload: {
            'path': r'C:\labs\cafe.pkt',
            'name': 'cafe.pkt',
            'device': 'R1',
            'id': 'R1:offline:1',
            'severity': 'high',
            'text': 'saved port carries no IP',
            'fix_cli': ['interface GigabitEthernet0/1', 'no shutdown'],
          },
        ),
        ChatAction(
          kind: 'ledger',
          summary: 'Show the audit ledger',
          payload: const {},
        ),
      ],
      createdAt: DateTime(2026, 9, 21).toIso8601String(),
    ),
  ];
}

class _FakeSettings extends SettingsService {
  @override
  Future<String?> getApiKey() async => '';
  @override
  Future<String?> getOpenAiKey() async => '';
}

void main() {
  testWidgets('a fix card offers Approve, Reject and Modify', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: _FakeSettings()),
          ChangeNotifierProvider<MemoryService>.value(value: _SeededMemory()),
        ],
        child: const MaterialApp(home: Scaffold(body: ChatScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Modify'), findsOneWidget);
    expect(find.text('Approve'), findsNWidgets(2));
    expect(find.textContaining('GigabitEthernet0/1'), findsWidgets);
  });
}
