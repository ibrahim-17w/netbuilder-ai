import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/autopilot_service.dart';

void main() {
  test('the build action is one the card renderer will keep', () {
    expect(ChatAction.supported, contains('pkt_generate'));
    // It compiles a file offline; it does not type into Packet Tracer, so the
    // card must not carry the "this touches Packet Tracer" warning.
    const action = ChatAction(
      kind: 'pkt_generate',
      summary: 'Build a .pkt from this plan',
      payload: <String, dynamic>{},
    );
    expect(action.touchesPacketTracer, isFalse);
  });

  test('the keyless planner produces a plan the generator can compile',
      () async {
    // No API key is involved anywhere in this path: this is exactly what
    // happens when the user has never entered one.
    final intent = NetworkIntent.parseSimple('chat', '2 routers and 4 switches');
    final plan = PacketTracerAdapter.autopilotPlan(intent);

    expect(plan.containsKey('project'), isTrue);
    final steps = plan['steps'];
    expect(steps, isA<List>());
    expect((steps as List), isNotEmpty,
        reason: 'a plan with no steps would generate an empty file');
  });

  test('a generator failure is a thrown message, not a silent success',
      () async {
    final svc = AutopilotService(
      base: 'http://127.0.0.1:5005',
      c: MockClient((_) async => http.Response(
            jsonEncode({'ok': false, 'error': 'no device library found'}),
            200,
          )),
    );

    await expectLater(
      svc.pktGenerate({'project': 'x', 'steps': <dynamic>[]}),
      throwsA(predicate((e) => e.toString().contains('no device library'))),
    );
  });

  test('a sidecar that is down is unhealthy, and the hint says how to start it',
      () async {
    final svc = AutopilotService(
      base: 'http://127.0.0.1:5005',
      c: MockClient((_) async => throw Exception('connection refused')),
    );

    // This is the branch `_compilePkt` takes, and it answers with the hint
    // rather than an exception.
    expect(await svc.healthy, isFalse);
    expect(AutopilotService.startHint, contains('Sidecar not running'));
    expect(AutopilotService.startHint, contains('5005'));
  });
}
