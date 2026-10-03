import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/chat_service.dart';
import 'package:net_builder/services/openai_chat_service.dart';

/// The reported failure was one 503 from the provider ending the whole turn in
/// the offline fallback ("The AI model is unavailable (HTTP 503: {}), so I am
/// answering offline"), so these tests pin the retry that stops a blip from
/// costing the user the answer they asked for.
void main() {
  group('what is worth retrying', () {
    test('rate limits and server trouble are', () {
      for (final code in const [429, 500, 502, 503, 504]) {
        expect(AiRetry.isTransient(code), isTrue, reason: '$code');
      }
    });

    test('a rejected key, model or request is not', () {
      for (final code in const [400, 401, 403, 404, 413, 422]) {
        expect(AiRetry.isTransient(code), isFalse, reason: '$code');
      }
    });
  });

  group('the retry itself', () {
    test('a transient failure is retried until it clears', () async {
      var sent = 0;
      final waits = <int>[];
      final response = await AiRetry.fetch<http.Response>(
        send: () async {
          sent++;
          return http.Response('{}', sent < 3 ? 503 : 200);
        },
        status: (r) => r.statusCode,
        wait: (attempt) async => waits.add(attempt),
      );
      expect(response.statusCode, 200);
      expect(sent, 3);
      expect(waits, [1, 2], reason: 'backed off before each retry');
    });

    test('it gives up after the bounded attempts and returns the failure',
        () async {
      var sent = 0;
      final response = await AiRetry.fetch<http.Response>(
        send: () async {
          sent++;
          return http.Response('{}', 503);
        },
        status: (r) => r.statusCode,
        wait: (_) async {},
      );
      expect(sent, AiRetry.maxAttempts);
      expect(response.statusCode, 503, reason: 'the caller still reports it');
    });

    test('a rejected request is handed back without a retry', () async {
      var sent = 0;
      final response = await AiRetry.fetch<http.Response>(
        send: () async {
          sent++;
          return http.Response('no', 404);
        },
        status: (r) => r.statusCode,
      );
      expect(sent, 1);
      expect(response.statusCode, 404);
    });
  });

  group('the chat turn survives a blip', () {
    test('the Gemini stream retries before the offline fallback', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls < 3) return http.Response('{}', 503);
        return http.Response(
          'data: ${jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Hello from the model'},
                  ],
                },
              },
            ],
          })}\n\n',
          200,
        );
      });
      final service = ChatService(client: client);
      final pieces = await service
          .stream(
            apiKey: 'test-key',
            model: 'gemini-2.5-flash',
            history: const <ChatMessage>[],
            text: 'hi',
            systemContext: 'you are a network assistant',
          )
          .toList();
      expect(calls, 3, reason: 'two 503s were retried, the third answer came');
      expect(pieces.join(), contains('Hello from the model'));
    });

    test('an OpenAI-compatible stream retries the same way', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls < 2) return http.Response('{}', 503);
        return http.Response(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'Hello from the gateway'},
              },
            ],
          })}\n\ndata: [DONE]\n\n',
          200,
        );
      });
      final service = OpenAiChatService(
        config: const AiProviderConfig(
          kind: AiProviderKind.openai,
          model: 'llama-3.3-70b-versatile',
          baseUrl: 'https://example.test/v1',
        ),
        apiKey: 'test-key',
        client: client,
      );
      final pieces = await service
          .stream(const [
            {'role': 'user', 'content': 'hi'},
          ])
          .toList();
      expect(calls, 2);
      expect(pieces.join(), contains('Hello from the gateway'));
    });
  });
}
