import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/generation_control.dart';
import 'package:net_builder/services/provider_chat_service.dart';
import 'package:net_builder/services/tool_runtime.dart';

ToolRuntime _runtime(
  List<Object?> replies, {
  bool down = false,
  List<http.Request>? log,
  String Function(String body)? answer,
}) {
  var index = 0;
  return ToolRuntime(
    config: const AiProviderConfig(
      kind: AiProviderKind.openai,
      model: 'gpt-4o-mini',
      baseUrl: 'https://api.example.com/v1',
    ),
    openaiKey: 'k',
    sidecarBase: 'http://127.0.0.1:5005',
    client: MockClient((request) async {
      final url = request.url.toString();
      if (url.endsWith('/tools/list')) {
        if (down) return http.Response('nope', 500);
        return http.Response(jsonEncode({
          'tools': [
            {'name': 'get_devices', 'kind': 'read', 'summary': 'd', 'args': {}},
          ],
        }), 200);
      }
      if (url.endsWith('/tools/call')) {
        return http.Response(
          jsonEncode({'ok': true, 'result': {'devices': ['R1']}}),
          200,
        );
      }
      log?.add(request);
      if (answer != null) {
        return http.Response(
          'data: ${jsonEncode(_say(answer(request.body)))}\n\n'
          'data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      final reply = replies[index < replies.length ? index : replies.length - 1];
      index++;
      return http.Response(jsonEncode(reply), 200);
    }),
  );
}

/// A 1x1 PNG written to disk, so the attachment is a real file.
Future<ChatImage> _shot() async {
  final dir = await Directory.systemTemp.createTemp('toolconv-img');
  final file = File('${dir.path}/shot.png');
  await file.writeAsBytes(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ));
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return ChatImage(path: file.path, name: 'shot.png', mimeType: 'image/png');
}

Map<String, dynamic> _toolCall() => {
  'choices': [
    {
      'message': {
        'tool_calls': [
          {
            'id': 'c1',
            'function': {'name': 'get_devices', 'arguments': '{}'},
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> _say(String text) => {
  'choices': [
    {
      'message': {'content': text},
    },
  ],
};

void main() {
  test('executeToolConversation yields the conversation, not just text',
      () async {
    final service = ProviderChatService(
      config: const AiProviderConfig(
        kind: AiProviderKind.openai,
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
      ),
      openaiKey: 'k',
    );
    service.toolRuntime = _runtime([_toolCall(), _say('There is one device, R1.')]);

    final events = await service
        .executeToolConversation(
          history: const [],
          text: 'what devices are there?',
          systemContext: 'network engineer',
        )
        .toList();

    expect(events.map((e) => e.kind).toList(), ['status', 'result', 'final']);
    expect(events.first.call!.name, 'get_devices');
    expect((events[1].data as Map)['devices'], ['R1']);
    expect(events.last.text, 'There is one device, R1.');
  });

  test('with no engine, tools are off so the plain path is used', () async {
    final service = ProviderChatService(
      config: const AiProviderConfig(
        kind: AiProviderKind.openai,
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
      ),
      openaiKey: 'k',
    );
    service.toolRuntime = _runtime(const [], down: true);

    expect(await service.toolRuntime!.ensureLoaded(), isFalse);
    expect(service.usesTools, isFalse,
        reason: 'the loop must stand down and let the existing path answer');
  });

  group('the tool path is the same conversation as the plain path', () {
    ProviderChatService serviceFor(
      ToolRuntime runtime, {
      int? contextTokens,
    }) =>
        ProviderChatService(
          config: const AiProviderConfig(
            kind: AiProviderKind.openai,
            model: 'gpt-4o-mini',
            baseUrl: 'https://api.example.com/v1',
          ),
          openaiKey: 'k',
          contextTokens: contextTokens,
          // The same transport as the tool runtime: otherwise the fallback
          // path would answer over a real network while the loop is faked.
          client: runtime.client,
        )..toolRuntime = runtime;

    test('every block the planner built reaches the model through the loop',
        () async {
      final log = <http.Request>[];
      final service = serviceFor(
        _runtime([_toolCall(), _say('R1 is the only device.')], log: log),
        contextTokens: 3000,
      );

      await service
          .executeToolConversation(
            history: [
              // Distinct filler per turn, so "was it resent in full?" is
              // answerable per turn rather than by counting characters.
              for (var i = 0; i < 8; i++)
                ChatMessage(
                  role: 'user',
                  text: 'turn $i '
                      '${String.fromCharCode(97 + i) * 3000}',
                ),
            ],
            text: 'what is on the network right now?',
            systemContext: 'you are a network engineer',
            networkContext: '## Live network\nR1 (router, 10.0.0.1)\nSW1',
            sessionState: '## Session state\nfocus device: R1',
            memories: '## Recalled memory\nThe user wants OSPF, not RIP.',
            storedSummary: 'Earlier: the user asked for 10 PCs and 2 routers.',
          )
          .toList();

      final providerCall = log.lastWhere(
        (r) => r.url.toString().endsWith('/chat/completions'),
      );
      final body = providerCall.body;
      expect(body, contains('you are a network engineer'));
      expect(body, contains('10.0.0.1'),
          reason: 'the live network is what the tools are about');
      expect(body, contains('focus device: R1'),
          reason: 'the structured state answers "what about its gateway?"');
      expect(body, contains('OSPF, not RIP'),
          reason: 'recalled memory used to be recalled and then dropped');
      expect(body, contains('10 PCs and 2 routers'),
          reason: 'the saved summary replaces the turns that did not fit');
      expect(body, contains('turn 7'),
          reason: 'the newest turns are sent word-for-word');
      // Compacted, not deleted: the asks are quoted in the summary, but a
      // compacted turn is never resent in full. Before the merge, the freshly
      // compacted turns were dropped instead, which is how the app forgot
      // something the user had said two or three messages earlier.
      expect(body, contains('h' * 200), reason: 'the kept turn is whole');
      expect(body, isNot(contains('a' * 200)),
          reason: 'a compacted turn is summarised, never resent in full');
      expect(body, contains('turn 0 '),
          reason: 'and the compacted turns are still represented');
      expect(service.lastPlan, isNotNull);
      expect(service.lastPlan!.turnsSummarized, greaterThan(0));
      expect(service.lastPlan!.recentTurns, isNotEmpty);
    });

    test('a screenshot on this turn rides along with the tool loop', () async {
      final shot = await _shot();
      final log = <http.Request>[];
      final service = serviceFor(
        _runtime([_toolCall(), _say('The screen shows SW1 down.')], log: log),
      );

      await service
          .executeToolConversation(
            history: const [],
            text: 'what is wrong here?',
            systemContext: 'sys',
            attachments: [shot],
          )
          .toList();

      final providerCall = log.lastWhere(
        (r) => r.url.toString().endsWith('/chat/completions'),
      );
      final messages =
          (jsonDecode(providerCall.body) as Map)['messages'] as List;
      final picture = [
        for (final message in messages)
          if (message['content'] is List) message['content'] as List,
      ];
      expect(picture, hasLength(1),
          reason: 'a vision turn used to reach the tool loop as text');
      final parts = List<Map<String, dynamic>>.from(picture.single);
      expect(parts.any((p) => p['type'] == 'image_url'), isTrue);
      expect(parts.any((p) => p['type'] == 'text'), isTrue);
    });

    test('with the engine down, the fallback carries the same blocks',
        () async {
      final log = <http.Request>[];
      final service = serviceFor(_runtime(
        const [],
        down: true,
        log: log,
        answer: (_) => 'R1 is the only device.',
      ));

      final pieces = await service
          .streamWithTools(
            history: const [],
            text: 'what is on the network?',
            systemContext: 'sys',
            networkContext: '## Live network\nR1 (router, 10.0.0.1)',
            sessionState: '## Session state\nfocus device: R1',
            memories: '## Recalled memory\nThe user wants OSPF, not RIP.',
          )
          .toList();

      expect(pieces.join(), contains('R1 is the only device.'));
      final body = log.single.body;
      expect(body, contains('10.0.0.1'));
      expect(body, contains('focus device: R1'));
      expect(body, contains('OSPF, not RIP'));
    });

    test('stopping a tool turn is a cancellation, not a provider failure',
        () async {
      final log = <http.Request>[];
      final service = serviceFor(
        _runtime([_toolCall(), _say('too late')], log: log),
      );
      final control = GenerationControl()..begin();
      control.cancel();

      await expectLater(
        service.executeToolConversation(
          history: const [],
          text: 'what is on the network?',
          systemContext: 'sys',
          abortTrigger: control.abortTrigger,
          abortProbe: () => control.cancelled,
        ).toList(),
        throwsA(isA<AbortedException>()),
      );
      expect(
        log.where((r) => r.url.toString().endsWith('/chat/completions')),
        isEmpty,
        reason: 'a cancelled turn is not answered by a fallback request',
      );
    });
  });
}
