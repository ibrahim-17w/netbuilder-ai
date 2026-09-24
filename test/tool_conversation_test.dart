import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/provider_chat_service.dart';
import 'package:net_builder/services/tool_runtime.dart';

ToolRuntime _runtime(List<Object?> replies, {bool down = false}) {
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
      final reply = replies[index < replies.length ? index : replies.length - 1];
      index++;
      return http.Response(jsonEncode(reply), 200);
    }),
  );
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
}
