import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/chat_service.dart';
import 'package:net_builder/services/context_report.dart';
import 'package:net_builder/services/generation_control.dart';
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

/// A transport the test drives by hand, so "the user pressed stop halfway
/// through" and "the provider went quiet" are real events here.
class _HandDrivenClient extends http.BaseClient {
  _HandDrivenClient(this.pieces);
  final Stream<List<int>> pieces;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) lastBody = request.body;
    return http.StreamedResponse(
      pieces,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

/// A transport that accepts the connection and then says nothing at all.
class _SilentClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
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

/// A 1x1 PNG, written to disk so the attachment path is a real file.
Future<ChatImage> _shot({String name = 'shot.png'}) async {
  final dir = await Directory.systemTemp.createTemp('openai-img');
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
      'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    ),
  );
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return ChatImage(path: file.path, name: name, mimeType: 'image/png');
}

/// Every message in [body] that carries an image, as its decoded content.
List<List<Map<String, dynamic>>> _imageTurns(String body) {
  final messages = (jsonDecode(body) as Map)['messages'] as List;
  return [
    for (final message in messages)
      if (message['content'] is List)
        List<Map<String, dynamic>>.from(message['content'] as List)
  ].where((parts) => parts.any((p) => p['type'] == 'image_url')).toList();
}

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
        // 12k tokens against 20 turns of ~900 tokens each: the reserves are
        // honest (the system prompt is measured, not guessed), so the budget
        // has to be genuinely smaller than the conversation for anything to
        // be compacted - which is exactly what this pins.
        contextTokens: 12000,
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

  group('images on the OpenAI-compatible path', () {
    // The Gemini path has sent inlineData for the current turn for a long
    // time; the OpenAI path dropped the attachments entirely, so a screenshot
    // worked on one provider and was invisible on the other.

    test('a turn with an image sends image_url parts, on the current turn '
        'only', () async {
      final shot = await _shot();
      final service = ProviderChatService(config: _cfg(), openaiKey: 'k');
      final messages = await service.openAiRichMessages(
        history: [
          ChatMessage(role: 'user', text: 'check PC1'),
          ChatMessage(role: 'model', text: 'PC1 is fine'),
        ],
        text: 'what is wrong here?',
        systemContext: 'you are a network engineer',
        attachments: [shot],
      );

      // History is still plain text: replaying every old screenshot would
      // multiply the request for no benefit.
      expect(messages[1]['content'], 'check PC1');
      expect(messages[2]['content'], isA<String>());

      final parts = messages.last['content'] as List;
      expect((parts.first as Map)['type'], 'text');
      expect((parts.first as Map)['text'], 'what is wrong here?');
      final image = parts.last as Map;
      expect(image['type'], 'image_url');
      final url = (image['image_url'] as Map)['url'] as String;
      expect(url, startsWith('data:image/png;base64,'));
      expect(url.length, greaterThan('data:image/png;base64,'.length));
    });

    test('an image-only turn still sends text to sit next to the picture',
        () async {
      final shot = await _shot();
      final service = ProviderChatService(config: _cfg(), openaiKey: 'k');
      final messages = await service.openAiRichMessages(
        history: const [],
        text: '   ',
        systemContext: 'sys',
        attachments: [shot],
      );
      final parts = messages.last['content'] as List;
      expect((parts.first as Map)['type'], 'text');
      expect((parts.first as Map)['text'], '(look at the attached image)');
    });

    test('a text-only turn keeps the plain string shape', () async {
      final service = ProviderChatService(config: _cfg(), openaiKey: 'k');
      final messages = await service.openAiRichMessages(
        history: const [],
        text: 'why?',
        systemContext: 'sys',
      );
      expect(messages.last['content'], 'why?');
    });

    test('the per-turn image cap is the same one Gemini uses', () async {
      final shots = [
        for (var i = 0; i < ChatService.maxImagesPerTurn + 2; i++)
          await _shot(name: 'shot$i.png'),
      ];
      final service = ProviderChatService(config: _cfg(), openaiKey: 'k');
      final messages = await service.openAiRichMessages(
        history: const [],
        text: 'look',
        systemContext: 'sys',
        attachments: shots,
      );
      final parts = messages.last['content'] as List;
      expect(
        parts.where((p) => p['type'] == 'image_url').length,
        ChatService.maxImagesPerTurn,
      );
    });

    test('stream() puts the images on the wire', () async {
      final shot = await _shot();
      final fake = _FakeEndpoint(
        pieces: ['${_chunk('I can see the canvas.')}data: [DONE]\n\n'],
      );
      final service = ProviderChatService(
        config: _cfg(),
        openaiKey: 'sk-test',
        client: fake,
      );
      final pieces = await service
          .stream(
            history: const [],
            text: 'what is wrong here?',
            systemContext: 'sys',
            attachments: [shot],
          )
          .toList();

      expect(pieces.join(), 'I can see the canvas.');
      expect(_imageTurns(fake.lastBody!), hasLength(1));
      expect(fake.lastBody, contains('"stream":true'));
    });

    test('the request log reports the cost, never the picture', () async {
      final shot = await _shot();
      RequestLog.clear();
      final fake = _FakeEndpoint(
        pieces: ['${_chunk('I can see the canvas.')}data: [DONE]\n\n'],
      );
      final service = ProviderChatService(
        config: _cfg(),
        openaiKey: 'sk-test',
        client: fake,
      );
      await service
          .stream(
            history: const [],
            text: 'what is wrong here?',
            systemContext: 'sys',
            attachments: [shot],
          )
          .toList();

      final report = RequestLog.last!;
      expect(report.toText(), contains('1 attachment(s)'));
      final logged = jsonEncode(report.toJson());
      expect(logged, isNot(contains('base64')));
      expect(logged, isNot(contains('data:image')));
    });
  });

  group('a cancelled turn is not a provider failure', () {
    test('pressing stop mid-answer raises AbortedException', () async {
      final control = GenerationControl()..begin();
      final controller = StreamController<List<int>>();
      addTearDown(controller.close);
      final service = OpenAiChatService(
        config: _cfg(),
        apiKey: 'sk-test',
        client: _HandDrivenClient(controller.stream),
      );

      final collected = <String>[];
      final run = () async {
        await for (final piece in service.streamMessages(
          const [
            {'role': 'user', 'content': 'hi'},
          ],
          abortTrigger: control.abortTrigger,
        )) {
          collected.add(piece);
          if (collected.length == 1) control.cancel();
        }
      }();

      controller.add(utf8.encode(_chunk('one')));
      await pumpEventQueue();
      controller.add(utf8.encode(_chunk('two')));
      controller.close();

      await expectLater(run, throwsA(isA<AbortedException>()));
      expect(collected, ['one'],
          reason: 'the answer stops where the user stopped it');
    });

    test('a turn stopped before it starts never reaches the provider',
        () async {
      final control = GenerationControl()..begin();
      control.cancel();
      final fake = _FakeEndpoint(pieces: [_chunk('never mind')]);
      final service = OpenAiChatService(
        config: _cfg(),
        apiKey: 'sk-test',
        client: fake,
      );
      await expectLater(
        service
            .streamMessages(
              const [
                {'role': 'user', 'content': 'hi'},
              ],
              abortTrigger: control.abortTrigger,
              // A cancel that happened before this request existed is only
              // visible synchronously, which is what the chat passes too.
              abortProbe: () => control.cancelled,
            )
            .toList(),
        throwsA(isA<AbortedException>()),
      );
      expect(fake.last, isNull, reason: 'nothing was sent at all');
    });
  });

  group('a provider that stops talking is stopped', () {
    test('headers never arrive', () async {
      final service = OpenAiChatService(
        config: _cfg(),
        apiKey: 'sk-test',
        client: _SilentClient(),
      );
      await expectLater(
        service
            .streamMessages(
              const [
                {'role': 'user', 'content': 'hi'},
              ],
              firstByteTimeout: const Duration(milliseconds: 60),
            )
            .toList(),
        throwsA(predicate((e) => e.toString().contains('timed out'))),
      );
    });

    test('the stream goes quiet halfway', () async {
      final controller = StreamController<List<int>>();
      addTearDown(controller.close);
      final service = OpenAiChatService(
        config: _cfg(),
        apiKey: 'sk-test',
        client: _HandDrivenClient(controller.stream),
      );
      final run = service
          .streamMessages(
            const [
              {'role': 'user', 'content': 'hi'},
            ],
            idleTimeout: const Duration(milliseconds: 80),
            totalTimeout: const Duration(seconds: 30),
          )
          .toList();
      controller.add(utf8.encode(_chunk('half an answer')));
      await expectLater(
        run,
        throwsA(predicate((e) => e.toString().contains('timed out'))),
      );
    });

    test('the stream never ends', () async {
      final chatter = Stream<List<int>>.periodic(
        const Duration(milliseconds: 20),
        (_) => utf8.encode(_chunk('.')),
      );
      final service = OpenAiChatService(
        config: _cfg(),
        apiKey: 'sk-test',
        client: _HandDrivenClient(chatter),
      );
      await expectLater(
        service
            .streamMessages(
              const [
                {'role': 'user', 'content': 'hi'},
              ],
              idleTimeout: const Duration(seconds: 30),
              totalTimeout: const Duration(milliseconds: 120),
            )
            .toList(),
        throwsA(predicate((e) => e.toString().contains('timed out'))),
      );
    });

    test('the defaults are the ones the chat promises', () {
      expect(StreamDeadlines.firstByte, const Duration(seconds: 60));
      expect(StreamDeadlines.idle, const Duration(seconds: 45));
      expect(StreamDeadlines.total, const Duration(minutes: 5));
      expect(StreamDeadlines.toolCall, const Duration(seconds: 30));
    });
  });
}
