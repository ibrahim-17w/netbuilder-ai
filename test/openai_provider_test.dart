import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/openai_chat_service.dart';
import 'package:net_builder/services/provider_chat_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/services/tool_runtime.dart';

/// A fake OpenAI-compatible endpoint. It records the request so the tests can
/// assert what was actually sent (URL, auth header, model, stream flag).
class _FakeEndpoint extends http.BaseClient {
  _FakeEndpoint({this.status = 200, this.body = '', this.pieces = const []});
  final int status;
  final String body;
  final List<String> pieces;
  http.BaseRequest? last;
  String? lastBody;
  Map<String, String>? lastHeaders;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    last = request;
    lastHeaders = request.headers;
    var isStream = false;
    if (request is http.Request) {
      lastBody = request.body;
      isStream = request.body.contains('"stream":true');
    }
    final payload = isStream
        ? pieces.map(utf8.encode).toList()
        : <List<int>>[utf8.encode(body)];
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(payload),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}

AiProviderConfig _cfg({
  String model = 'llama-3.3-70b-versatile',
  String base = 'https://api.groq.com/openai/v1',
  String org = '',
  Map<String, String> headers = const {},
}) => AiProviderConfig(
  kind: AiProviderKind.openai,
  model: model,
  baseUrl: base,
  organization: org,
  extraHeaders: headers,
);

String _ok(String content) => jsonEncode({
  'choices': [
    {
      'message': {'content': content},
    },
  ],
});

String _chunk(String delta) => 'data: ${jsonEncode({
  'choices': [
    {
      'delta': {'content': delta},
    },
  ],
})}\n\n';

void main() {
  test('a non-streaming call hits <base>/chat/completions with the model',
      () async {
    final fake = _FakeEndpoint(body: _ok('ready'));
    final service = OpenAiChatService(
      config: _cfg(org: 'org-1', headers: {'X-Title': 'netbuilder'}),
      apiKey: 'sk-test',
      client: fake,
    );
    final text = await service.complete(const [
      {'role': 'user', 'content': 'ping'},
    ]);

    expect(text, 'ready');
    expect(fake.last!.url.toString(),
        'https://api.groq.com/openai/v1/chat/completions');
    expect(fake.lastHeaders!['Authorization'], 'Bearer sk-test');
    expect(fake.lastHeaders!['OpenAI-Organization'], 'org-1');
    expect(fake.lastHeaders!['X-Title'], 'netbuilder');
    expect(fake.lastBody, contains('llama-3.3-70b-versatile'));
  });

  test('streaming yields the answer as it arrives, even split mid-line',
      () async {
    final fullBody = '${_chunk('Two-')}${_chunk('site OSPF')}data: [DONE]\n\n';
    final cut = fullBody.length ~/ 2;
    final fake = _FakeEndpoint(
      pieces: [fullBody.substring(0, cut), fullBody.substring(cut)],
    );
    final service = OpenAiChatService(
      config: _cfg(),
      apiKey: 'sk-test',
      client: fake,
    );
    final pieces = await service
        .stream(const [
          {'role': 'user', 'content': 'hi'},
        ])
        .toList();

    expect(pieces.join(), 'Two-site OSPF');
    expect(fake.lastBody, contains('"stream":true'));
  });

  group('every failure says what to fix', () {
    Future<String> failure(int status, {String model = 'm'}) async {
      final service = OpenAiChatService(
        config: _cfg(model: model),
        apiKey: 'sk-bad',
        client: _FakeEndpoint(status: status, body: '{"error":"nope"}'),
      );
      try {
        await service.complete(const [
          {'role': 'user', 'content': 'ping'},
        ]);
        return 'NO ERROR';
      } catch (e) {
        return e.toString().replaceFirst('Exception: ', '');
      }
    }

    test('401 -> the key was rejected', () async {
      expect(await failure(401), contains('API key was rejected'));
    });
    test('403 -> the key may not use this model', () async {
      expect(await failure(403), contains('not allowed to use'));
    });
    test('404 -> base URL or model id is wrong, and names /v1', () async {
      final message = await failure(404, model: 'ghost-model');
      expect(message, contains('ghost-model'));
      expect(message, contains('/v1'));
    });
    test('429 -> rate limited, and mentions free tiers', () async {
      expect(await failure(429), contains('Rate limited'));
    });
    test('503 -> provider trouble, offline still works', () async {
      expect(await failure(503), contains('offline planner still works'));
    });
  });

  test('a missing key is called out, but a LOCAL server needs none', () async {
    final remote = OpenAiChatService(
      config: _cfg(),
      apiKey: '',
      client: _FakeEndpoint(body: _ok('x')),
    );
    await expectLater(
      remote.complete(const [
        {'role': 'user', 'content': 'ping'},
      ]),
      throwsA(predicate((e) => e.toString().contains('No API key'))),
    );

    final localFake = _FakeEndpoint(body: _ok('local ok'));
    final local = OpenAiChatService(
      config: _cfg(base: 'http://127.0.0.1:11434/v1'),
      apiKey: '',
      client: localFake,
    );
    expect(
      await local.complete(const [
        {'role': 'user', 'content': 'ping'},
      ]),
      'local ok',
    );
    expect(localFake.lastHeaders!.containsKey('Authorization'), isFalse);
  });

  test('a malformed base URL is named, not guessed', () {
    expect(AiErrors.badBaseUrl(''), contains('No base URL'));
    expect(AiErrors.badBaseUrl('http://'), isNotEmpty);
    expect(AiErrors.badBaseUrl('https://api.groq.com/openai/v1'), isEmpty);
  });

  test('the model is never hardcoded: the config supplies it', () async {
    final fake = _FakeEndpoint(body: _ok('ok'));
    final service = OpenAiChatService(
      config: _cfg(model: 'some-brand-new-2027-model'),
      apiKey: 'k',
      client: fake,
    );
    await service.complete(const [
      {'role': 'user', 'content': 'hi'},
    ]);
    expect(fake.lastBody, contains('some-brand-new-2027-model'));
  });

  test('the default Gemini model is a real current one', () {
    expect(AiProviderConfig.defaultGeminiModel, 'gemini-2.5-flash');
    expect(AiProviderConfig.geminiSuggestions, contains('gemini-2.5-pro'));
  });

  test('headers are parsed from the textarea shape', () {
    final parsed = SettingsService.parseHeaders('X-Title: mine\nX-Beta: 1\nbadline');
    expect(parsed['X-Title'], 'mine');
    expect(parsed['X-Beta'], '1');
    expect(parsed.length, 2);
  });

  group('the OpenAI path obeys the same context budget as Gemini', () {
    ChatMessage turn(String role, String text) =>
        ChatMessage(role: role, text: text);

    List<String> sentRoles(List<Map<String, String>> messages) =>
        messages.map((m) => m['role']!).toList();

    test('a compacted memory block is appended to the system prompt', () {
      final service = ProviderChatService(
        config: _cfg(),
        openaiKey: 'k',
        // ~30k tokens: above the fixed per-request reserves, so the
        // difference is history - and 20 big turns do not all fit.
        contextTokens: 30000,
      );
      final history = [
        for (var i = 0; i < 10; i++) ...[
          turn('user', 'ask $i ${'x' * 3600}'),
          turn('model', 'reply $i ${'y' * 3600}'),
        ],
      ];
      final messages = service.openAiMessages(
        history: history,
        text: 'remind me what i asked first',
        systemContext: 'you are a network engineer',
      );
      final system = messages.first['content']!;
      expect(system, startsWith('you are a network engineer'));
      expect(system, contains('ORIGINAL request'),
          reason: 'the dropped turns are summarized into memory');
      expect(system, contains('ask 0'));
      // Only what fits is sent word-for-word (the pending turn is last).
      final kept = messages.skip(1).toList();
      expect(kept.length, lessThan(history.length + 1));
      expect(sentRoles(kept).first, anyOf('user', 'assistant'));
      expect(kept.last['content'], contains('remind me'),
          reason: 'the pending turn is sent last');
      // And the newest history turn survives just before it.
      expect(kept[kept.length - 2]['content'], contains('reply 9'));
    });

    test('a small conversation is sent whole, with no memory block', () {
      final service = ProviderChatService(
        config: _cfg(),
        openaiKey: 'k',
        contextTokens: 262144,
      );
      final history = [
        turn('user', 'hello there'),
        turn('model', 'hi! what are we building?'),
      ];
      final messages = service.openAiMessages(
        history: history,
        text: 'and 10 pcs',
        systemContext: 'sys',
      );
      expect(messages.first['content'], 'sys');
      expect(messages.length, 4); // system + 2 history + pending
      expect(messages[1]['content'], 'hello there');
    });

    test('a tool-loop turn carries the memory block too', () async {
      final requests = <http.Request>[];
      final service = ProviderChatService(
        config: const AiProviderConfig(
          kind: AiProviderKind.gemini,
          model: 'gemini-2.0-flash',
        ),
        geminiKey: 'k',
        contextTokens: 3000,
      );
      service.toolRuntime = ToolRuntime(
        config: const AiProviderConfig(
          kind: AiProviderKind.gemini,
          model: 'gemini-2.0-flash',
        ),
        geminiKey: 'k',
        sidecarBase: 'http://127.0.0.1:8765',
        client: MockClient((request) async {
          final url = request.url.toString();
          if (url.endsWith('/tools/list')) {
            return http.Response(jsonEncode({
              'tools': [
                {
                  'name': 'get_devices',
                  'kind': 'read',
                  'summary': 'd',
                  'args': <String, dynamic>{},
                },
              ],
            }), 200);
          }
          requests.add(request);
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'done'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(await service.toolRuntime!.load(), isTrue);

      final history = [
        for (var i = 0; i < 10; i++)
          turn('user', 'ask $i ${'x' * 1800}'),
      ];
      await service
          .streamWithTools(
            history: history,
            text: 'remind me',
            systemContext: 'you are a network engineer',
          )
          .toList();

      // The provider call the loop made carries the compacted memory of the
      // turns that did not fit - the tool path must not skip the budget.
      final providerCall = requests.lastWhere(
        (r) => r.url.toString().contains('generateContent'),
      );
      expect(providerCall.body, contains('you are a network engineer'));
      expect(providerCall.body, contains('ORIGINAL request'));
    });
  });
}
