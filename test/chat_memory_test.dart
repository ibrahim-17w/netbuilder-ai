import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/chat_service.dart';

class _CapturingClient extends http.BaseClient {
  Map<String, dynamic>? sent;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      sent = jsonDecode(request.body) as Map<String, dynamic>;
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': jsonEncode({'reply': 'you asked for the OSPF lab'}),
                    },
                  ],
                },
              },
            ],
          }),
        ),
      ),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  test(
    'a request made at the START of a long conversation still reaches the model',
    () async {
      const opening =
          'OPENING-ASK build a two-site OSPF lab with a serial WAN on '
          '10.1.1.0/30 and 192.168.1.0/24';
      final history = <ChatMessage>[
        const ChatMessage(role: 'user', text: opening),
        const ChatMessage(role: 'model', text: 'Understood: two sites, OSPF.'),
      ];
      // 60 further exchanges, each ~300 tokens: at the 40k budget the
      // request cannot carry the whole conversation word-for-word, so the
      // opening turns are compacted into memory. (Sized against the working
      // fraction of 0.9: 36k usable minus the ~14k fixed reserves.)
      for (var i = 0; i < 60; i++) {
        history.add(
          ChatMessage(role: 'user', text: 'filler question $i ${'x' * 1200}'),
        );
        history.add(
          ChatMessage(role: 'model', text: 'filler answer $i ${'y' * 1200}'),
        );
      }
      const pending = 'what did I ask you to build at the very beginning?';

      final client = _CapturingClient();
      final service = ChatService(client: client, contextTokens: 40000);
      final reply = await service.send(
        apiKey: 'k',
        model: 'gemini-3.8-flash',
        history: history,
        text: pending,
        systemContext: 'SYS',
      );

      expect(reply.text, contains('OSPF lab'));

      final systemInstruction = ((client.sent!['systemInstruction'] as Map)
          ['parts'] as List).first['text'] as String;
      // The whole point: the opening request is still in the request.
      expect(systemInstruction, contains('OPENING-ASK'));
      expect(systemInstruction, contains('Conversation memory'));

      final plan = service.lastPlan!;
      expect(plan.budgetTokens, 40000);
      expect(plan.turnsSummarized, greaterThan(0));
      expect(plan.tokensUsed, lessThanOrEqualTo(40000));

      // It never sends more turns than exist, and the newest turn is there.
      final contents = client.sent!['contents'] as List;
      expect(contents.length, lessThanOrEqualTo(history.length + 1));
      expect(contents.isNotEmpty, isTrue);
    },
  );

  test('a short conversation keeps every turn and adds no memory block',
      () async {
    final client = _CapturingClient();
    final service = ChatService(client: client);
    await service.send(
      apiKey: 'k',
      model: 'gemini-3.8-flash',
      history: [
        const ChatMessage(role: 'user', text: 'hi'),
        const ChatMessage(role: 'model', text: 'hello'),
      ],
      text: 'continue',
      systemContext: 'SYS',
    );
    final instruction = ((client.sent!['systemInstruction'] as Map)['parts']
        as List).first['text'] as String;
    expect(instruction, isNot(contains('Conversation memory')));
    expect(service.lastPlan!.turnsSummarized, 0);
    expect((client.sent!['contents'] as List).length, 3);
  });
}
