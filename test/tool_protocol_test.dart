import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/tool_protocol.dart';

/// The catalogue as `GET /tools/list` reports it.
final _engineReply = {
  'ok': true,
  'count': 3,
  'tools': [
    {'name': 'get_devices', 'kind': 'read', 'summary': 'devices', 'args': {}},
    {
      'name': 'check_gateway',
      'kind': 'read',
      'summary': 'gateway validity',
      'args': {'device': 'string'},
    },
    {
      'name': 'set_gateway',
      'kind': 'modify',
      'summary': 'propose a gateway',
      'args': {'device': 'string', 'gateway': 'string'},
    },
  ],
};

void main() {
  test('the catalogue is read from the engine reply', () {
    final tools = ToolProtocol.catalogue(_engineReply);
    expect(tools, hasLength(3));
    expect(tools.first['name'], 'get_devices');
  });

  test('Gemini declarations use upper-case schema types', () {
    final decls = ToolProtocol.geminiDeclarations(
      ToolProtocol.catalogue(_engineReply),
    );
    expect(decls, hasLength(1));
    final list = decls.first['functionDeclarations'] as List;
    expect(list, hasLength(3));
    final gateway = list.firstWhere((d) => d['name'] == 'check_gateway');
    expect(gateway['parameters']['type'], 'OBJECT');
    expect(gateway['parameters']['properties']['device']['type'], 'STRING');
    // the read/modify distinction reaches the model
    expect(gateway['description'], contains('READ-ONLY'));
    final setter = list.firstWhere((d) => d['name'] == 'set_gateway');
    expect(setter['description'], contains('requires the user'));
  });

  test('OpenAI declarations use the function wrapper', () {
    final decls = ToolProtocol.openAiDeclarations(
      ToolProtocol.catalogue(_engineReply),
    );
    expect(decls, hasLength(3));
    expect(decls.first['type'], 'function');
    final fn = decls.first['function'] as Map;
    expect(fn['name'], 'get_devices');
    expect(fn['parameters']['type'], 'object');
  });

  test('Gemini function calls are parsed', () {
    final calls = ToolProtocol.parseCalls({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'functionCall': {
                  'name': 'check_gateway',
                  'args': {'device': 'PC1'},
                },
              },
              {'text': 'thinking out loud'},
              {
                'functionCall': {'name': 'get_devices', 'args': {}},
              },
            ],
          },
        },
      ],
    });
    expect(calls, hasLength(2));
    expect(calls.first.name, 'check_gateway');
    expect(calls.first.args['device'], 'PC1');
    expect(calls.last.name, 'get_devices');
  });

  test('OpenAI tool calls are parsed, including JSON-string arguments', () {
    final calls = ToolProtocol.parseCalls({
      'choices': [
        {
          'message': {
            'tool_calls': [
              {
                'id': 'call_1',
                'function': {
                  'name': 'set_gateway',
                  'arguments': '{"device":"R1","gateway":"10.0.0.1"}',
                },
              },
            ],
          },
        },
      ],
    });
    expect(calls, hasLength(1));
    expect(calls.first.name, 'set_gateway');
    expect(calls.first.args['gateway'], '10.0.0.1');
  });

  test('malformed provider payloads are skipped, not fatal', () {
    expect(ToolProtocol.parseCalls(null), isEmpty);
    expect(ToolProtocol.parseCalls({'candidates': 'nonsense'}), isEmpty);
    expect(
      ToolProtocol.parseCalls({
        'choices': [
          {
            'message': {
              'tool_calls': [
                {'id': 'x', 'function': {'arguments': 'not json'}},
              ],
            },
          },
        ],
      }),
      isEmpty,
    );
  });

  test('the result message carries the engine answer back', () {
    const call = ToolCall(id: 'call_1', name: 'get_devices', args: {});
    final message = ToolProtocol.resultMessage(call, {'devices': ['R1']});
    expect(message['role'], 'tool');
    expect(message['tool_call_id'], 'call_1');
    expect(jsonDecode(message['content'] as String)['devices'], ['R1']);
  });

  test('the assistant turn echoes the calls for the next round', () {
    const calls = [
      ToolCall(id: 'a', name: 'get_devices', args: {}),
      ToolCall(id: 'b', name: 'check_gateway', args: {'device': 'PC1'}),
    ];
    final turn = ToolProtocol.assistantTurn(calls);
    final list = turn['tool_calls'] as List;
    expect(list, hasLength(2));
    expect((list.first as Map)['function']['name'], 'get_devices');
    expect(
      jsonDecode((list.last as Map)['function']['arguments'] as String)['device'],
      'PC1',
    );
  });

  test('status lines are human, and never raw reasoning', () {
    expect(
      ToolProtocol.statusLine(
        const ToolCall(id: 'a', name: 'check_connectivity', args: {'source': 'PC1'}),
      ),
      'Testing connectivity (PC1)...',
    );
    expect(
      ToolProtocol.statusLine(
        const ToolCall(id: 'a', name: 'analyze_network', args: {}),
      ),
      'Analyzing the network...',
    );
  });
}
