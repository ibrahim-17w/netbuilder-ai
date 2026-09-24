import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/build_artifact_service.dart';
import 'package:net_builder/services/chat_service.dart';
import 'package:net_builder/services/gemini_service.dart';
import 'package:net_builder/services/planner_suggestions_service.dart';
import 'package:net_builder/services/validator_service.dart';

/// An HTTP client that fails the test if anything ever uses it. The whole
/// point of the offline path is that it needs no key and no network, so a
/// request leaving the device has to be an immediate, loud failure.
class _ExplodingClient extends http.BaseClient {
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    throw StateError('network was used on the offline path');
  }
}

void main() {
  group('the offline path needs no Gemini API key', () {
    test('plans, validates and renders with no key anywhere', () {
      final intent = NetworkIntent.parseSimple(
        'nokey',
        'office network with 2 routers 1 switch 4 pcs, use ospf',
      );
      expect(intent.nodes, isNotEmpty);
      expect(intent.planningSource, 'local');

      final issues = ValidatorService.validate(intent, target: 'pt');
      expect(
        issues.where((i) => i.severity == 'error'),
        isEmpty,
        reason: 'the keyless plan must be executable without a model',
      );

      final config = BuildArtifactService.renderLocal(intent, 'pt');
      expect(config.trim(), isNotEmpty);
      expect(config, contains('router ospf 1'));
    });

    test('Planning is deterministic: the same brief plans the same way', () {
      const brief = 'branch office with 2 routers 2 switches 1 server 6 pcs';
      final a = NetworkIntent.parseSimple('det', brief);
      final b = NetworkIntent.parseSimple('det', brief);
      expect(a.nodes.map((n) => '${n.name}:${n.type}').join(','),
          b.nodes.map((n) => '${n.name}:${n.type}').join(','));
      expect(a.links.length, b.links.length);
      expect(a.addressing.map((x) => x.ipCidr).join(','),
          b.addressing.map((x) => x.ipCidr).join(','));
    });

    test('chat with an empty key fails closed and never hits the network',
        () async {
      final client = _ExplodingClient();
      final chat = ChatService(client: client);
      await expectLater(
        chat.send(
          apiKey: '',
          model: 'gemini-3.8-flash',
          history: const [],
          text: 'what should I build?',
          systemContext: 'ctx',
        ),
        throwsA(isA<Exception>()),
      );
      expect(client.calls, 0, reason: 'no request may leave the device');
    });

    test('GeminiService reports an empty key instead of throwing', () async {
      final err =
          await GeminiService().testKey(apiKey: '   ', model: 'gemini-3.8-flash');
      expect(err, isNotNull);
    });

    test('a thin brief still yields user-facing suggestions, not a crash', () {
      final intent = NetworkIntent.parseSimple('thin', 'just a server and 3 pcs');
      expect(intent.nodes, isNotEmpty);
      final suggestions = PlannerSuggestionsService.forIntent(intent, target: 'pt');
      expect(suggestions, isNotEmpty);
    });

    test('an empty plan is answered with a concrete how-to-fix suggestion', () {
      const empty = NetworkIntent(projectName: 'nothing');
      final suggestions = PlannerSuggestionsService.forIntent(empty);
      expect(
        suggestions.any((s) => s.toLowerCase().contains('no devices')),
        isTrue,
      );
    });
  });
}
