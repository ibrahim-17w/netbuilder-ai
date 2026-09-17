import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:net_builder/services/gemini_service.dart';

class _FakeClient extends http.BaseClient {
  final String responseBody;
  _FakeClient(this.responseBody);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(responseBody)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  test('Gemini response is parsed as a structured network intent', () async {
    final plan = {
      'projectName': 'plain-english-lab',
      'nodes': [
        {'name': 'R1', 'type': 'router', 'model': '2911'},
        {'name': 'SW1', 'type': 'switch', 'model': '2960'},
      ],
      'links': [
        {'a': 'R1', 'aIf': 'g0/0', 'b': 'SW1', 'bIf': 'f0/1'},
      ],
      'addressing': [
        {'node': 'R1', 'iface': 'g0/0', 'ipCidr': '192.168.1.1/24'},
      ],
      'routing': 'ospf',
      'assumptions': ['Use area 0'],
      'questions': ['Should the switch use a management VLAN?'],
      'confidence': 0.9,
    };
    final response = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': jsonEncode(plan)},
            ],
          },
        },
      ],
    });

    final result = await GeminiService(client: _FakeClient(response))
        .generateIntent(
          apiKey: 'test',
          model: 'test-model',
          instruction: 'make a small OSPF lab',
          contextBlock: '',
          target: 'gns3',
          offlineCandidate: {'projectName': 'fallback'},
        );

    expect(result.projectName, 'plain-english-lab');
    expect(result.nodes.length, 2);
    expect(result.routing, 'ospf');
    expect(
      result.questions,
      contains('Should the switch use a management VLAN?'),
    );
    expect(result.confidence, closeTo(0.9, 0.001));
  });
}
