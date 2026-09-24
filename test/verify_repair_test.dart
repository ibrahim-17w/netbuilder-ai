import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/services/autopilot_service.dart';

void main() {
  test('verifyRepair asks the tool layer and returns its verdict', () async {
    http.Request? sent;
    final engine = AutopilotService(
      base: 'http://127.0.0.1:5005',
      c: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'ok': true,
            'result': {
              'verdict': 'fixed',
              'verified': true,
              'summary': 'Verified: the re-audit no longer reports PC1:x.',
              'resolved': [
                {'id': 'PC1:x'},
              ],
              'stillBroken': <dynamic>[],
              'introduced': <dynamic>[],
            },
          }),
          200,
        );
      }),
    );

    final result = await engine.verifyRepair(
      before: {
        'devices': [
          {'name': 'PC1', 'findings': [{'id': 'PC1:x'}]},
        ],
      },
      after: {
        'devices': [
          {'name': 'PC1', 'findings': <dynamic>[]},
        ],
      },
      fixes: [
        {'id': 'PC1:x'},
      ],
    );

    expect(result['verdict'], 'fixed');
    expect(result['verified'], isTrue);

    final body = jsonDecode(sent!.body) as Map<String, dynamic>;
    expect(sent!.url.path, '/tools/call');
    expect(body['name'], 'verify_repair');
    expect(body['args']['fixes'], [
      {'id': 'PC1:x'},
    ]);
    // both audits travelled to the engine
    expect(body['args']['before']['devices'], hasLength(1));
    expect(body['args']['after']['devices'], hasLength(1));
  });

  test('an unreadable reply yields an empty map, never a false pass', () async {
    final engine = AutopilotService(
      base: 'http://127.0.0.1:5005',
      c: MockClient((_) async => http.Response(jsonEncode({'ok': true}), 200)),
    );
    final result = await engine.verifyRepair(
      before: const {},
      after: const {},
      fixes: const [],
    );
    expect(result, isEmpty);
    expect(result['verified'], isNull);
  });
}
