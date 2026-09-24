import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/tool_loop.dart';

/// A scripted provider: each call returns the next canned reply.
class _Scripted {
  _Scripted(this.replies);
  final List<Object?> replies;
  int sends = 0;
  List<List<Map<String, dynamic>>> seen = [];

  Future<Object?> send(List<Map<String, dynamic>> messages) async {
    // Keep a deep-ish copy so we can assert what the model was told.
    seen.add([for (final m in messages) Map<String, dynamic>.from(m)]);
    final reply = replies[sends < replies.length ? sends : replies.length - 1];
    sends++;
    return reply;
  }
}

Map<String, dynamic> _geminiCall(String name, Map<String, dynamic> args) => {
  'candidates': [
    {
      'content': {
        'parts': [
          {
            'functionCall': {'name': name, 'args': args},
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> _geminiText(String text) => {
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

String _text(Object? decoded) {
  if (decoded is! Map) return '';
  final candidates = decoded['candidates'];
  if (candidates is! List || candidates.isEmpty) return '';
  final content = (candidates.first as Map)['content'];
  final parts = (content is Map) ? content['parts'] : null;
  if (parts is! List) return '';
  final b = StringBuffer();
  for (final part in parts) {
    if (part is Map && part['text'] is String) b.write(part['text']);
  }
  return b.toString();
}

void main() {
  test('no tool call: one send, straight to the final answer', () async {
    final scripted = _Scripted([_geminiText('PC2 is on the wrong subnet.')]);
    final loop = ToolLoop(
      send: scripted.send,
      execute: (_) async => fail('no tool should be executed'),
      extractText: _text,
    );
    final events = await loop.run(const [
      {'role': 'user', 'content': 'why?'},
    ]).toList();
    expect(events, hasLength(1));
    expect(events.single.kind, 'final');
    expect(events.single.text, 'PC2 is on the wrong subnet.');
    expect(scripted.sends, 1);
  });

  test('two rounds of tools, then the answer - and the model is fed the '
      'results', () async {
    final scripted = _Scripted([
      _geminiCall('get_devices', {}),
      _geminiCall('check_gateway', {'device': 'PC1'}),
      _geminiText('The gateway on PC1 is outside its subnet.'),
    ]);
    final executed = <String>[];
    final loop = ToolLoop(
      send: scripted.send,
      execute: (call) async {
        executed.add(call.name);
        return {'tool': call.name, 'ok': true};
      },
      extractText: _text,
    );

    final events = await loop.run(const [
      {'role': 'user', 'content': 'why can not PC1 reach the server?'},
    ]).toList();

    expect(executed, ['get_devices', 'check_gateway']);
    final kinds = events.map((e) => e.kind).toList();
    expect(kinds, ['status', 'result', 'status', 'result', 'final']);
    expect(events.first.text, 'Listing the devices...');
    expect(events[2].text, 'Validating the default gateway (PC1)...');
    expect(events.last.text, contains('outside its subnet'));

    // The third send must carry the assistant's calls AND both tool results.
    final lastMessages = scripted.seen.last;
    expect(lastMessages.any((m) => m['role'] == 'assistant'), isTrue);
    expect(
      lastMessages.where((m) => m['role'] == 'tool').length,
      2,
      reason: 'both tool results must be sent back to the model',
    );
  });

  test('a runaway model is stopped at the cap and told so', () async {
    // Always asks for another tool.
    final scripted = _Scripted([_geminiCall('get_devices', {})]);
    var calls = 0;
    final loop = ToolLoop(
      send: scripted.send,
      execute: (_) async {
        calls++;
        return {'ok': true};
      },
      extractText: _text,
      maxIterations: 3,
    );
    final events = await loop.run(const [
      {'role': 'user', 'content': 'go'},
    ]).toList();

    expect(calls, 3, reason: 'exactly maxIterations tool rounds, not more');
    expect(scripted.sends, 3);
    expect(events.last.kind, 'limit');
    expect(events.last.text, contains('avoid a loop'));
  });

  test('a failing tool is reported to the model instead of killing the turn',
      () async {
    final scripted = _Scripted([
      _geminiCall('get_device', {'device': 'GHOST'}),
      _geminiText('That device is not in the capture.'),
    ]);
    final loop = ToolLoop(
      send: scripted.send,
      execute: (_) async => throw Exception('there is no device GHOST'),
      extractText: _text,
    );
    final events = await loop.run(const [
      {'role': 'user', 'content': 'check GHOST'},
    ]).toList();

    expect(events.map((e) => e.kind).toList(), ['status', 'result', 'final']);
    expect(events[1].text, contains('no device GHOST'));
    final toolMessage = scripted.seen.last
        .firstWhere((m) => m['role'] == 'tool');
    expect(toolMessage['content'].toString(), contains('GHOST'));
    expect(events.last.kind, 'final');
  });

  test('a provider failure ends the turn with the reason, not a crash',
      () async {
    final loop = ToolLoop(
      send: (_) async => throw Exception('Rate limited or out of quota (429)'),
      execute: (_) async => null,
      extractText: _text,
    );
    final events = await loop.run(const [
      {'role': 'user', 'content': 'hi'},
    ]).toList();
    expect(events.single.kind, 'error');
    expect(events.single.text, contains('Rate limited'));
  });
}
