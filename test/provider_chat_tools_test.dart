import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/provider_chat_service.dart';
import 'package:net_builder/services/tool_runtime.dart';

ToolRuntime _runtime(
  List<Object?> geminiReplies, {
  List<http.Request>? log,
  bool engineDown = false,
}) {
  var index = 0;
  return ToolRuntime(
    config: const AiProviderConfig(
      kind: AiProviderKind.gemini,
      model: 'gemini-2.0-flash',
    ),
    geminiKey: 'k',
    sidecarBase: 'http://127.0.0.1:8765',
    capturePath: r'C:\ai\lab.pkt',
    client: MockClient((request) async {
      log?.add(request);
      final url = request.url.toString();
      if (url.endsWith('/tools/list')) {
        if (engineDown) return http.Response('nope', 500);
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
      final reply = geminiReplies[index < geminiReplies.length ? index : geminiReplies.length - 1];
      index++;
      return http.Response(jsonEncode(reply), 200);
    }),
  );
}

Map<String, dynamic> _askForTool() => {
  'candidates': [
    {
      'content': {
        'parts': [
          {
            'functionCall': {'name': 'get_devices', 'args': <String, dynamic>{}},
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> _say(String text) => {
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': text},
        ],
      },
    },
  ],
};

void main() {
  test('without a runtime, tools are off and the old path is used',
      () async {
    final service = ProviderChatService(
      config: AiProviderConfig(kind: AiProviderKind.gemini, model: 'm'),
    );
    expect(service.usesTools, isFalse);
    expect(service.toolRuntime, isNull);
  });

  test('with an engine that offers no tools, tools stay off', () async {
    final service = ProviderChatService(
      config: const AiProviderConfig(
        kind: AiProviderKind.gemini,
        model: 'gemini-2.0-flash',
      ),
      geminiKey: 'k',
    );
    service.toolRuntime = _runtime([], engineDown: true);
    expect(await service.toolRuntime!.load(), isFalse);
    expect(service.usesTools, isFalse);
  });

  test('with tools loaded, the turn shows what ran and then the answer',
      () async {
    final log = <http.Request>[];
    final service = ProviderChatService(
      config: const AiProviderConfig(
        kind: AiProviderKind.gemini,
        model: 'gemini-2.0-flash',
      ),
      geminiKey: 'k',
    );
    service.toolRuntime = _runtime(
      [_askForTool(), _say('R1 is the only device.')],
      log: log,
    );
    expect(await service.toolRuntime!.load(), isTrue);
    expect(service.usesTools, isTrue);

    final pieces = await service
        .streamWithTools(
          history: const [],
          text: 'what devices are there?',
          systemContext: 'you are a network engineer',
        )
        .toList();
    final whole = pieces.join();

    // the user sees the tool line, and the answer
    expect(whole, contains('\u25b8 Listing the devices...'));
    expect(whole, contains('R1 is the only device.'));

    // and the tool really ran against the engine
    expect(
      log.where((r) => r.url.toString().endsWith('/tools/call')),
      hasLength(1),
    );
    // the system prompt was carried to the model
    final providerCall = log.lastWhere(
      (r) => r.url.toString().contains('generateContent'),
    );
    expect(providerCall.body, contains('network engineer'));
  });

  test('a tool-loop provider failure surfaces as an error, not a blank reply',
      () async {
    final service = ProviderChatService(
      config: const AiProviderConfig(
        kind: AiProviderKind.gemini,
        model: 'gemini-2.0-flash',
      ),
      geminiKey: 'k',
    );
    final runtime = _runtime([_say('hi')]);
    service.toolRuntime = runtime;
    await runtime.load();

    // force the provider leg to fail
    service.toolRuntime = ToolRuntime(
      config: const AiProviderConfig(
        kind: AiProviderKind.gemini,
        model: 'gemini-2.0-flash',
      ),
      geminiKey: 'k',
      sidecarBase: 'http://127.0.0.1:8765',
      client: MockClient((request) async {
        if (request.url.toString().endsWith('/tools/list')) {
          return http.Response(jsonEncode({
            'tools': [
              {'name': 'get_devices', 'kind': 'read', 'summary': 'd', 'args': {}},
            ],
          }), 200);
        }
        return http.Response(
          jsonEncode({'error': {'message': 'Rate limited or out of quota'}}),
          429,
        );
      }),
    );
    await service.toolRuntime!.load();

    await expectLater(
      service
          .streamWithTools(
            history: const [],
            text: 'list them',
            systemContext: '',
          )
          .toList(),
      throwsA(predicate((e) =>
          e.toString().contains('Rate limited') ||
          e.toString().contains('quota'))),
    );
  });
}
