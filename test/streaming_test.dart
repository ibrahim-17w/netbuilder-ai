import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:net_builder/services/chat_service.dart';

/// A fake SSE transport: the bytes are handed over in the exact pieces we
/// choose, so a line split across chunks is exercised for real.
class _SseClient extends http.BaseClient {
  _SseClient(this.pieces);
  final List<String> pieces;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(pieces.map(utf8.encode)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

String _sse(String text) {
  final payload = jsonEncode({
    'candidates': [
      {
        'content': {
          'parts': [
            {'text': text},
          ],
        },
      },
    ],
  });
  return 'data: $payload\n\n';
}

void main() {
  test('the SSE parser reads the text and ignores the terminator', () {
    final raw = '${_sse('Hel')}${_sse('lo')}data: [DONE]\n\n';
    expect(ChatService.sseText(raw), 'Hello');
  });

  test('a chunk that splits a line mid-payload is buffered, not lost',
      () async {
    final body = _sse('{"reply":"Hello from the model"}');
    final cut = body.length ~/ 2;
    final client = _SseClient([body.substring(0, cut), body.substring(cut)]);
    final service = ChatService(client: client);

    final pieces = await service
        .stream(
          apiKey: 'k',
          model: 'gemini-3.8-flash',
          history: const [],
          text: 'hi',
          systemContext: 'SYS',
        )
        .toList();

    // Whatever the split, the whole answer arrives exactly once.
    expect(pieces.join(), '{"reply":"Hello from the model"}');
    expect(service.lastPlan, isNotNull);
  });

  test('stream() surfaces a failure instead of returning nothing', () async {
    final client = _SseClient(const []);
    final service = ChatService(client: client);
    await expectLater(
      service
          .stream(
            apiKey: '',
            model: 'm',
            history: const [],
            text: 'hi',
            systemContext: 'SYS',
          )
          .toList(),
      throwsA(isA<Exception>()),
    );
  });
}
