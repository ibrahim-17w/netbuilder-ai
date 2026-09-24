import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/services/ai_provider.dart';
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

ToolRuntime _runtime(_Backend backend, {bool gemini = false}) => ToolRuntime(
  config: AiProviderConfig(
    kind: gemini ? AiProviderKind.gemini : AiProviderKind.openai,
    model: gemini ? 'gemini-2.0-flash' : 'gpt-4o-mini',
    baseUrl: 'https://api.example.com/v1',
  ),
  geminiKey: 'gm-key',
  openaiKey: 'oa-key',
  sidecarBase: 'http://127.0.0.1:8765/',
  capturePath: r'C:\ai\labs\lab1.pkt',
  client: backend.client,
);

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
}
