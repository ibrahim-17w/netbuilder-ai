import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/chat_service.dart';

/// Captures the request body so the tests can assert what actually left the
/// machine (history roles, inline images, system instruction).
class _CapturingClient extends http.BaseClient {
  final String responseBody;
  final int statusCode;
  Map<String, dynamic>? sent;

  _CapturingClient(this.responseBody, {this.statusCode = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      sent = jsonDecode(request.body) as Map<String, dynamic>;
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(responseBody)),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  }
}

String _reply({String text = '', List<dynamic> actions = const []}) =>
    jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'text': jsonEncode({
                  'reply': text,
                  'actions': actions,
                  'questions': const <String>[],
                }),
              },
            ],
          },
        },
      ],
    });

void main() {
  group('reply parsing', () {
    test('reads the structured shape', () {
      final parsed = ChatService.parseReply(
        jsonEncode({
          'reply': 'The pool base is outside the subnet.',
          'actions': [
            {
              'kind': 'save_rule',
              'rule': 'Pool bases must sit inside the gateway subnet',
              'targets': 'packet-tracer',
            },
          ],
          'questions': ['Which subnet should DHCP serve?'],
        }),
      );
      expect(parsed.text, contains('pool base'));
      expect(parsed.actions, hasLength(1));
      expect(parsed.actions.first.kind, 'save_rule');
      expect(parsed.questions, ['Which subnet should DHCP serve?']);
    });

    test('reads a fenced JSON answer', () {
      final parsed = ChatService.parseReply(
        '```json\n${jsonEncode({'reply': 'ok'})}\n```',
      );
      expect(parsed.text, 'ok');
    });

    test('falls back to prose instead of erroring', () {
      final parsed = ChatService.parseReply(
        'I cannot tell from that screenshot - crop it tighter.',
      );
      expect(parsed.text, contains('crop it tighter'));
      expect(parsed.actions, isEmpty);
    });

    test('finds a JSON object embedded in prose', () {
      final parsed = ChatService.parseReply(
        'Sure: {"reply":"done","actions":[],"questions":[]}',
      );
      expect(parsed.text, 'done');
    });
  });

  group('action filtering', () {
    test('drops action kinds the app cannot execute', () {
      final actions = ChatAction.parseList([
        {'kind': 'save_rule', 'rule': 'r'},
        {'kind': 'rm_rf_slash'},
        {'kind': 'run_control', 'command': 'stop'},
        'not a map',
      ]);
      expect(actions.map((a) => a.kind), ['save_rule', 'run_control']);
    });

    test('only the packet-tracer touching kinds are flagged', () {
      expect(
        ChatAction(kind: 'paste_cli', payload: {}).touchesPacketTracer,
        isTrue,
      );
      expect(
        ChatAction(kind: 'run_control', payload: {}).touchesPacketTracer,
        isTrue,
      );
      expect(
        ChatAction(kind: 'config_pcs', payload: {}).touchesPacketTracer,
        isTrue,
      );
      expect(
        ChatAction(kind: 'save_rule', payload: {}).touchesPacketTracer,
        isFalse,
      );
      expect(
        ChatAction(kind: 'save_preference', payload: {}).touchesPacketTracer,
        isFalse,
      );
    });

    test('labels name the devices an action would touch', () {
      final action = ChatAction(
        kind: 'paste_cli',
        payload: {
          'configs': {'R1': 'ip route 0.0.0.0 0.0.0.0 10.1.1.2'},
        },
      );
      expect(action.label, contains('R1'));
    });
  });

  group('message persistence', () {
    test('round-trips images, actions and executed state', () {
      final message = ChatMessage(
        id: 7,
        role: 'model',
        text: 'Try the second port.',
        images: const [
          ChatImage(path: r'C:\tmp\before.png', name: 'before.png', bytes: 2048),
        ],
        actions: const [
          ChatAction(
            kind: 'paste_cli',
            payload: {
              'configs': {'R1': 'interface g0/2'},
            },
          ),
        ],
        executed: const ['0'],
        createdAt: '2026-09-18T10:00:00',
      );
      final restored = ChatMessage.fromMap(message.toMap());
      expect(restored.id, 7);
      expect(restored.text, 'Try the second port.');
      expect(restored.images.single.name, 'before.png');
      expect(restored.images.single.sizeLabel, '2KB');
      expect(restored.actions.single.kind, 'paste_cli');
      expect(restored.executed, ['0']);
      expect(restored.isUser, isFalse);
    });

    test('survives corrupt JSON columns', () {
      final restored = ChatMessage.fromMap({
        'id': 1,
        'role': 'user',
        'text': 'hi',
        'imagesJson': 'not json',
        'actionsJson': '{',
        'executedJson': '[]',
        'createdAt': '',
      });
      expect(restored.text, 'hi');
      expect(restored.images, isEmpty);
      expect(restored.actions, isEmpty);
    });

    test('a user turn maps to the user role and a model turn to model', () {
      expect(
        ChatMessage(role: 'user', text: 'a').toGeminiTurn()['role'],
        'user',
      );
      expect(
        ChatMessage(role: 'model', text: 'b').toGeminiTurn()['role'],
        'model',
      );
    });
  });

  group('system context', () {
    String context({
      List<String> blockers = const [],
      List<String> unsupported = const [],
      String live = '',
    }) => ChatService.systemContext(
      target: 'packet-tracer',
      rulePacks: '- [ser-1] A router-to-router WAN needs a serial cable',
      learnedRules: ['Prefer /30 on WAN links'],
      preferences: {'naming': 'HQ_ prefix'},
      knownBlockers: blockers,
      unsupportedCapabilities: unsupported,
      liveState: live,
    );

    test('carries the app knowledge and the action contract', () {
      final text = context();
      expect(text, contains('serial cable'));
      expect(text, contains('Prefer /30 on WAN links'));
      expect(text, contains('naming=HQ_ prefix'));
      expect(text, contains('You cannot act directly'));
      expect(text, contains('save_rule'));
      expect(text, contains('paste_cli'));
      expect(text, contains('STRICT JSON only'));
    });

    test('carries blockers and proven Packet Tracer gaps', () {
      final text = context(
        blockers: ['- [cli_context_blocked] live CLI prompt was not proven'],
        unsupported: ['- crypto map on 2911 (not implemented)'],
      );
      expect(text, contains('Known blockers from previous runs'));
      expect(text, contains('live CLI prompt was not proven'));
      expect(text, contains('Packet Tracer cannot do these'));
      expect(text, contains('crypto map'));
    });

    test('only mentions live state when it was actually read', () {
      expect(context(), isNot(contains('Live run state')));
      expect(
        context(live: 'phase: verification\nerrors unrecovered=3'),
        contains('errors unrecovered=3'),
      );
    });

    test('forbids inventing credentials', () {
      expect(context(), contains('Never invent credentials'));
    });
  });

  group('sending', () {
    test('attaches the current turn images as inlineData', () async {
      final dir = await Directory.systemTemp.createTemp('chat-test');
      final file = File('${dir.path}/shot.png');
      await file.writeAsBytes(const [1, 2, 3, 4]);

      final client = _CapturingClient(_reply(text: 'I can see the canvas.'));
      final reply = await ChatService(client: client).send(
        apiKey: 'test-key',
        model: 'gemini-3.8-flash',
        history: [ChatMessage(role: 'user', text: 'earlier turn')],
        text: 'what is wrong here?',
        systemContext: 'SYS',
        attachments: [ChatImage(path: file.path, name: 'shot.png')],
      );

      expect(reply.text, 'I can see the canvas.');
      final contents = client.sent!['contents'] as List;
      // history turn + current turn with text and the image
      expect(contents, hasLength(2));
      final parts =
          (contents.last as Map)['parts'] as List;
      expect(parts.first['text'], 'what is wrong here?');
      final inline = (parts.last as Map)['inlineData'] as Map;
      expect(inline['mimeType'], 'image/png');
      expect(inline['data'], isNotEmpty);
      expect(
        (client.sent!['systemInstruction'] as Map)['parts'],
        isNotEmpty,
      );
      await dir.delete(recursive: true);
    });

    test('an empty key fails with a readable message, not a crash', () async {
      await expectLater(
        ChatService(client: _CapturingClient(_reply(text: 'x'))).send(
          apiKey: '   ',
          model: 'gemini-3.8-flash',
          history: const [],
          text: 'hi',
          systemContext: 'SYS',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('No Gemini API key'),
          ),
        ),
      );
    });

    test('a 404 model name is explained', () async {
      await expectLater(
        ChatService(
          client: _CapturingClient('{"error":"nope"}', statusCode: 404),
        ).send(
          apiKey: 'k',
          model: 'gemini-2.0-flash',
          history: const [],
          text: 'hi',
          systemContext: 'SYS',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('gemini-2.0-flash'),
          ),
        ),
      );
    });
  });
}
