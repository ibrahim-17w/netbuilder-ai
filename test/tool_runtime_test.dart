import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/generation_control.dart';
import 'package:net_builder/services/tool_protocol.dart';
import 'package:net_builder/services/tool_runtime.dart';

/// The engine's `GET /tools/list` reply.
Map<String, dynamic> get _catalogue => {
  'ok': true,
  'count': 2,
  'tools': [
    {'name': 'get_devices', 'kind': 'read', 'summary': 'devices', 'args': {}},
    {
      'name': 'set_gateway',
      'kind': 'modify',
      'summary': 'propose a gateway',
      'args': {'device': 'string', 'gateway': 'string'},
    },
  ],
};

/// A recording sidecar + provider, so every request can be asserted.
class _Backend {
  final List<http.Request> requests = [];
  Object? toolResult;
  int geminiSends = 0;

  http.Client get client => MockClient((request) async {
    requests.add(request);
    final url = request.url.toString();

    if (url.endsWith('/tools/list')) {
      return http.Response(jsonEncode(_catalogue), 200);
    }
    if (url.endsWith('/tools/call')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['name'] == 'set_gateway') {
        // A modify tool: proposal only, nothing applied.
        return http.Response(
          jsonEncode({
            'ok': true,
            'result': {
              'kind': 'modify',
              'requiresApproval': true,
              'proposal': {
                'tool': 'set_gateway',
                'device': body['args']['device'],
                'gateway': body['args']['gateway'],
              },
            },
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'ok': true,
          'result': {'devices': ['R1', 'SW1'], 'requested': body['name']},
        }),
        200,
      );
    }
    if (url.contains('generativelanguage')) {
      geminiSends++;
      // First round: the model asks for a tool. Then it answers with text.
      final parts = geminiSends == 1
          ? [
              {
                'functionCall': {
                  'name': 'get_devices',
                  'args': <String, dynamic>{},
                },
              },
            ]
          : [
              {'text': 'The devices are R1 and SW1.'},
            ];
      return http.Response(jsonEncode({
        'candidates': [
          {'content': {'parts': parts}},
        ],
      }), 200);
    }
    if (url.endsWith('/chat/completions')) {
      return http.Response(jsonEncode({
        'choices': [
          {
            'message': {
              'content': 'The devices are R1 and SW1.',
            },
          },
        ],
      }), 200);
    }
    return http.Response('{"ok":false,"error":"unexpected"}', 404);
  });
}

ToolRuntime _runtime(
  _Backend backend, {
  bool gemini = false,
  String? base,
  String Function()? baseProvider,
}) =>
    ToolRuntime(
      config: AiProviderConfig(
        kind: gemini ? AiProviderKind.gemini : AiProviderKind.openai,
        model: gemini ? 'gemini-2.0-flash' : 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
      ),
      geminiKey: 'gm-key',
      openaiKey: 'oa-key',
      sidecarBase: base ?? 'http://127.0.0.1:8765/',
      baseProvider: baseProvider,
      capturePath: r'C:\ai\labs\lab1.pkt',
      client: backend.client,
    );

/// A transport that behaves like the real one when the user presses stop: the
/// in-flight request fails instead of pretending the cancel never happened.
class _AbortableClient extends http.BaseClient {
  _AbortableClient(this.trigger);

  final Future<void> trigger;
  int sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    final completer = Completer<http.StreamedResponse>();
    unawaited(trigger.then((_) {
      if (completer.isCompleted) return;
      completer.completeError(
        http.RequestAbortedException(Uri.parse('http://127.0.0.1:8765')),
      );
    }));
    return completer.future;
  }
}

/// The tools the engine offers, as it answers `GET /tools/list`.
const List<Map<String, dynamic>> _oneTool = [
  {'name': 'get_devices', 'kind': 'read', 'summary': 'd', 'args': {}},
];

void main() {
  test('load() reads the engine catalogue and exposes it to the model',
      () async {
    final backend = _Backend();
    final runtime = _runtime(backend);
    expect(runtime.available, isFalse, reason: 'nothing loaded yet');

    expect(await runtime.load(), isTrue);
    expect(runtime.available, isTrue);
    expect(runtime.tools.map((t) => t['name']).toList(),
        ['get_devices', 'set_gateway']);
    expect(backend.requests.single.url.toString(),
        'http://127.0.0.1:8765/tools/list');
  });

  test('load() degrades cleanly when the sidecar is down', () async {
    final runtime = ToolRuntime(
      config: AiProviderConfig(
        kind: AiProviderKind.openai,
        model: 'm',
        baseUrl: 'https://api.example.com/v1',
      ),
      sidecarBase: 'http://127.0.0.1:1',
      client: MockClient((_) async => throw Exception('refused')),
    );
    expect(await runtime.load(), isFalse);
    expect(runtime.available, isFalse,
        reason: 'the chat must be able to fall back');
  });

  test('execute() posts the call to the tool layer with the capture',
      () async {
    final backend = _Backend();
    final runtime = _runtime(backend);
    await runtime.load();

    final result = await runtime.execute(
      const ToolCall(id: '1', name: 'get_devices', args: {}),
    );
    final sent = backend.requests.last;
    expect(sent.url.toString(), 'http://127.0.0.1:8765/tools/call');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['name'], 'get_devices');
    expect(body['path'], r'C:\ai\labs\lab1.pkt');
    expect((result as Map)['devices'], ['R1', 'SW1']);
  });

  test('a modify tool comes back as an unapplied proposal', () async {
    final backend = _Backend();
    final runtime = _runtime(backend);
    await runtime.load();

    final result = await runtime.execute(
      const ToolCall(
        id: '1',
        name: 'set_gateway',
        args: {'device': 'R1', 'gateway': '10.0.0.1'},
      ),
    ) as Map;
    expect(result['kind'], 'modify');
    expect(result['requiresApproval'], isTrue);
    expect(result['proposal']['gateway'], '10.0.0.1');

    // Nothing in the request asked the engine to apply anything.
    final body = jsonDecode(backend.requests.last.body).toString();
    expect(body.contains('apply'), isFalse);
    expect(body.contains('write'), isFalse);
  });

  test('an engine error becomes a tool failure, not a silent success',
      () async {
    final runtime = ToolRuntime(
      config: AiProviderConfig(
        kind: AiProviderKind.openai,
        model: 'm',
        baseUrl: 'https://api.example.com/v1',
      ),
      sidecarBase: 'http://127.0.0.1:8765',
      client: MockClient((_) async => http.Response(
            jsonEncode({'ok': false, 'error': 'there is no device GHOST'}),
            400,
          )),
    );
    await expectLater(
      runtime.execute(const ToolCall(id: '1', name: 'get_device', args: {})),
      throwsA(predicate(
          (e) => e.toString().contains('no device GHOST'))),
    );
  });

  test('the OpenAI request carries the tools and the key', () async {
    final backend = _Backend();
    final runtime = _runtime(backend);
    await runtime.load();
    await runtime.send([
      {'role': 'system', 'content': 'you are a network engineer'},
      {'role': 'user', 'content': 'what devices are there?'},
    ]);

    final sent = backend.requests.last;
    expect(sent.url.toString(), 'https://api.example.com/v1/chat/completions');
    expect(sent.headers['Authorization'], 'Bearer oa-key');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['model'], 'gpt-4o-mini');
    final names = (body['tools'] as List)
        .map((t) => (t as Map)['function']['name'])
        .toList();
    expect(names, ['get_devices', 'set_gateway']);
    expect(
      (body['messages'] as List).first['role'],
      'system',
    );
  });

  test('the Gemini request carries functionDeclarations and the key', () async {
    final backend = _Backend();
    final runtime = _runtime(backend, gemini: true);
    await runtime.load();
    await runtime.send([
      {'role': 'user', 'content': 'what devices are there?'},
    ]);

    final sent = backend.requests.last;
    expect(sent.url.toString(), contains('gemini-2.0-flash:generateContent'));
    expect(sent.headers['x-goog-api-key'], 'gm-key');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    final decls = (body['tools'] as List).first['functionDeclarations'] as List;
    expect(decls.map((d) => d['name']).toList(),
        ['get_devices', 'set_gateway']);
    expect((body['contents'] as List).first['role'], 'user');
  });

  test('the loop, the protocol and the tool layer work together',
      () async {
    final backend = _Backend();
    final runtime = _runtime(backend, gemini: true);
    await runtime.load();

    final events = await runtime.loop().run([
      {'role': 'user', 'content': 'list the devices'},
    ]).toList();

    final kinds = events.map((e) => e.kind).toList();
    expect(kinds, ['status', 'result', 'final']);
    expect(events.first.text, 'Listing the devices...');
    expect((events[1].data as Map)['devices'], ['R1', 'SW1']);
    expect(events.last.text, 'The devices are R1 and SW1.');

    // exactly one provider round-trip per turn, one tool call
    final calls = backend.requests
        .where((r) => r.url.toString().endsWith('/tools/call'))
        .toList();
    final sends = backend.requests
        .where((r) => r.url.toString().contains('generateContent'))
        .toList();
    expect(calls, hasLength(1));
    expect(sends, hasLength(2), reason: 'one to ask, one to answer');
  });

  test('text extraction works for both providers', () async {
    final runtime = _runtime(_Backend());
    expect(
      runtime.extractText({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'hello '},
                {'text': 'world'},
              ],
            },
          },
        ],
      }),
      'hello world',
    );
    expect(
      runtime.extractText({
        'choices': [
          {
            'message': {'content': 'hi there'},
          },
        ],
      }),
      'hi there',
    );
    expect(runtime.extractText(null), '');
  });

  group('the catalogue is loaded once per endpoint, and re-read when it moves',
      () {
    test('the engine is asked once, not on every turn', () async {
      final backend = _Backend();
      final runtime = _runtime(backend);

      expect(await runtime.ensureLoaded(), isTrue);
      expect(await runtime.ensureLoaded(), isTrue);
      expect(await runtime.ensureLoaded(), isTrue);

      expect(
        backend.requests.where((r) => r.url.toString().endsWith('/tools/list')),
        hasLength(1),
        reason: 'the chat may ask on every turn; the answer is remembered',
      );
    });

    test('a failed attempt is NOT remembered', () async {
      var sidecarUp = false;
      var asks = 0;
      final runtime = ToolRuntime(
        config: const AiProviderConfig(
          kind: AiProviderKind.openai,
          model: 'gpt-4o-mini',
          baseUrl: 'https://api.example.com/v1',
        ),
        sidecarBase: 'http://127.0.0.1:8765',
        client: MockClient((request) async {
          if (request.url.toString().endsWith('/tools/list')) {
            asks++;
            if (!sidecarUp) return http.Response('still starting', 500);
            return http.Response(jsonEncode(_catalogue), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      expect(await runtime.ensureLoaded(), isFalse);
      expect(runtime.available, isFalse);
      sidecarUp = true;
      expect(await runtime.ensureLoaded(), isTrue,
          reason: 'a sidecar that was still booting must not be written off '
              'for the whole session');
      expect(asks, 2);
    });

    test('a different endpoint is a different engine, so tools are re-read',
        () async {
      final backend = _Backend();
      var base = 'http://127.0.0.1:8765';
      final runtime = _runtime(backend, baseProvider: () => base);

      expect(await runtime.ensureLoaded(), isTrue);
      expect(await runtime.ensureLoaded(), isTrue);

      // The sidecar came back on another port.
      base = 'http://127.0.0.1:9999';
      expect(runtime.toolCacheKey, contains('gpt-4o-mini'));
      expect(runtime.toolCacheKey, contains('9999'));
      expect(await runtime.ensureLoaded(), isTrue);

      final ports = backend.requests
          .where((r) => r.url.toString().endsWith('/tools/list'))
          .map((r) => r.url.port)
          .toList();
      expect(ports, [8765, 9999],
          reason: 'a cached list from the old port must not answer for the new '
              'one');
    });

    test('the base is resolved at call time, not captured at construction',
        () async {
      final backend = _Backend();
      // sidecarBase is the address Settings had when the chat was built (and is
      // dead here); the resolver is where the engine actually is now.
      final runtime = _runtime(
        backend,
        base: 'http://127.0.0.1:1',
        baseProvider: () => 'http://127.0.0.1:8765///',
      );

      expect(await runtime.ensureLoaded(), isTrue);
      expect(backend.requests.single.url.toString(),
          'http://127.0.0.1:8765/tools/list',
          reason: 'the resolver wins, and trailing slashes are normalised');
    });
  });

  test('a tool turn is authenticated exactly like a plain one', () async {
    final backend = _Backend();
    final runtime = ToolRuntime(
      config: const AiProviderConfig(
        kind: AiProviderKind.openai,
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.example.com/v1',
        organization: 'org-1',
        project: 'proj-1',
        extraHeaders: {'X-Title': 'netbuilder'},
      ),
      openaiKey: 'oa-key',
      sidecarBase: 'http://127.0.0.1:8765',
      client: backend.client,
    );
    expect(await runtime.ensureLoaded(), isTrue);
    await runtime.send(const [
      {'role': 'user', 'content': 'list them'},
    ]);

    final sent = backend.requests.last;
    expect(sent.headers['Authorization'], 'Bearer oa-key');
    expect(sent.headers['OpenAI-Organization'], 'org-1');
    expect(sent.headers['OpenAI-Project'], 'proj-1');
    expect(sent.headers['X-Title'], 'netbuilder',
        reason: 'a gateway header that the plain path sends and the tool loop '
            'dropped answered 401 on tool turns only');
  });

  group('no leg of the loop can hang the turn', () {
    test('a tool call that never answers is cut off', () async {
      final hung = Completer<http.Response>();
      final runtime = ToolRuntime(
        config: const AiProviderConfig(
          kind: AiProviderKind.openai,
          model: 'gpt-4o-mini',
          baseUrl: 'https://api.example.com/v1',
        ),
        sidecarBase: 'http://127.0.0.1:8765',
        toolTimeout: const Duration(milliseconds: 80),
        client: MockClient((request) async {
          if (request.url.toString().endsWith('/tools/list')) {
            return http.Response(jsonEncode({'tools': _oneTool}), 200);
          }
          return hung.future; // the engine accepted, and then went quiet
        }),
      );
      expect(await runtime.ensureLoaded(), isTrue);

      await expectLater(
        runtime.execute(const ToolCall(id: '1', name: 'get_devices', args: {})),
        throwsA(predicate((e) => e.toString().contains('timed out'))),
      );
    });

    test('a provider that accepts the connection and then says nothing is '
        'cut off', () async {
      final hung = Completer<http.Response>();
      final runtime = ToolRuntime(
        config: const AiProviderConfig(
          kind: AiProviderKind.openai,
          model: 'gpt-4o-mini',
          baseUrl: 'https://api.example.com/v1',
        ),
        openaiKey: 'k',
        sidecarBase: 'http://127.0.0.1:8765',
        providerTimeout: const Duration(milliseconds: 80),
        client: MockClient((request) async {
          if (request.url.toString().endsWith('/tools/list')) {
            return http.Response(jsonEncode({'tools': _oneTool}), 200);
          }
          return hung.future;
        }),
      );
      expect(await runtime.ensureLoaded(), isTrue);

      await expectLater(
        runtime.send(const [
          {'role': 'user', 'content': 'list them'},
        ]),
        throwsA(predicate((e) => e.toString().contains('timed out'))),
      );
    });

    test('an engine that is not there at all cannot leave tools on', () async {
      final runtime = ToolRuntime(
        config: const AiProviderConfig(
          kind: AiProviderKind.openai,
          model: 'gpt-4o-mini',
          baseUrl: 'https://api.example.com/v1',
        ),
        sidecarBase: '',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(await runtime.ensureLoaded(), isFalse);
      expect(runtime.available, isFalse);
    });
  });

  group('stop reaches every leg of the loop', () {
    test('a turn stopped mid-flight is cancelled, not reported as a failure',
        () async {
      final control = GenerationControl()..begin();
      final client = _AbortableClient(control.abortTrigger!);
      final runtime = ToolRuntime(
        config: const AiProviderConfig(
          kind: AiProviderKind.gemini,
          model: 'gemini-2.0-flash',
        ),
        geminiKey: 'k',
        sidecarBase: 'http://127.0.0.1:8765',
        client: client,
      );

      final kinds = <String>[];
      Object? error;
      final run = () async {
        await for (final event
            in runtime.loop(abortTrigger: control.abortTrigger).run(const [
          {'role': 'user', 'content': 'list the devices'},
        ])) {
          kinds.add(event.kind);
        }
      }();
      await pumpEventQueue();
      control.cancel();

      await expectLater(run, throwsA(isA<AbortedException>()));
      expect(error, isNull);
      expect(kinds, isNot(contains('error')),
          reason: 'the user pressing stop is not the provider failing');
      expect(kinds, isNot(contains('final')));
    });

    test('a turn stopped before it starts never reaches the provider',
        () async {
      final backend = _Backend();
      final runtime = _runtime(backend, gemini: true);
      final control = GenerationControl()..begin();
      control.cancel();
      await pumpEventQueue();

      await expectLater(
        runtime
            .loop(
              abortTrigger: control.abortTrigger,
              abortProbe: () => control.cancelled,
            )
            .run(const [
          {'role': 'user', 'content': 'list them'},
        ]).toList(),
        throwsA(isA<AbortedException>()),
      );
      expect(
        backend.requests.where((r) => r.url.toString().contains('generateContent')),
        isEmpty,
      );
    });
  });

  test('a screenshot survives the tool loop as an image, not as text', () async {
    final backend = _Backend();
    final runtime = _runtime(backend, gemini: true);
    expect(await runtime.ensureLoaded(), isTrue);

    await runtime.send([
      const {'role': 'user', 'content': 'what is wrong on this screen?'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'what is wrong here?'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,AAABBB'},
          },
        ],
      },
    ]);

    final sent = backend.requests.last;
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    final contents = body['contents'] as List;
    final parts = (contents.last as Map)['parts'] as List;
    final inline = parts.where((p) => (p as Map).containsKey('inlineData'));
    expect(inline, hasLength(1),
        reason: 'the data URL is split back into mime type and bytes');
    expect(
      ((inline.single as Map)['inlineData'] as Map)['data'],
      'AAABBB',
    );
    expect(sent.body, isNot(contains('image_url')),
        reason: 'a flattened content array arrives as a literal '
            '"[{type: image_url...}]" string, so the model is told it can see '
            'a picture it never receives');
  });
}
