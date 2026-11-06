import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/gns3_adapter.dart';

void main() {
  test(
    'push instantiates nodes from GNS3 2.x template_id keys and wires links',
    () async {
      final calls = <String>[];
      final templateBodies = <String, dynamic>{};
      Future<http.Response> handler(http.Request request) async {
        calls.add('${request.method} ${request.url.path}');
        final path = request.url.path;
        if (request.method == 'POST' && path == '/v2/projects') {
          return http.Response(
            jsonEncode({'project_id': 'proj-1'}),
            201,
          );
        }
        if (request.method == 'GET' && path == '/v2/templates') {
          // GNS3 2.2 answers templates with `template_id`, never `id`.
          return http.Response(
            jsonEncode([
              {'template_id': 't-eth', 'name': 'Ethernet switch'},
              {'template_id': 't-vpcs', 'name': 'VPCS'},
            ]),
            200,
          );
        }
        if (request.method == 'POST' &&
            path.startsWith('/v2/projects/proj-1/templates/')) {
          final id = path.split('/').last;
          templateBodies[id] = jsonDecode(request.body) as Map;
          if (id == 'null') {
            // The exact regression this test pins: a null template id means
            // the adapter lost the template's identity.
            return http.Response(
              jsonEncode({'message': "Template null doesn't exist"}),
              404,
            );
          }
          if ((jsonDecode(request.body) as Map)['compute_id'] == null) {
            // The second regression this file pins: GNS3 2.2 answers
            // 404 "Compute ID None doesn't exist" when the instantiation
            // body carries no compute id.
            return http.Response(
              jsonEncode({'message': "Compute ID None doesn't exist"}),
              404,
            );
          }
          return http.Response(
            jsonEncode({'node_id': 'node-$id', 'name': 'x'}),
            201,
          );
        }
        if (request.method == 'POST' && path == '/v2/projects/proj-1/links') {
          return http.Response(jsonEncode({'link_id': 'l1'}), 201);
        }
        return http.Response('unexpected: $request', 500);
      }

      final report = await Gns3Adapter.push(
        NetworkIntent(
          projectName: 'gns3-lan-test',
          nodes: const [
            NetNode(name: 'SW1', type: 'switch', model: '2960'),
            NetNode(name: 'PC1', type: 'pc', model: 'PC-PT'),
            NetNode(name: 'PC2', type: 'pc', model: 'PC-PT'),
          ],
          links: const [
            NetLink(a: 'SW1', aIf: 'Fa0/1', b: 'PC1', bIf: 'Fa0'),
            NetLink(a: 'SW1', aIf: 'Fa0/2', b: 'PC2', bIf: 'Fa0'),
          ],
        ),
        endpoint: 'http://127.0.0.1:3080',
        user: 'admin',
        pass: 'secret',
        client: MockClient(handler),
      );

      expect(
        calls.where((c) => c.contains('/templates/null')),
        isEmpty,
        reason: 'no node may be instantiated from a null template id',
      );
      expect(
        calls.where((c) => c.endsWith('/templates/t-eth')).length,
        1,
        reason: 'the switch instantiates once, from the 2.x template_id',
      );
      expect(
        calls.where((c) => c.endsWith('/templates/t-vpcs')).length,
        2,
      );
      expect(calls.where((c) => c.endsWith('/links')).length, 2);
      expect(report, contains('3/3 nodes'));
      expect(report, contains('2/2 links'));
      expect(report, isNot(contains('FAIL')));
      expect(report, isNot(contains('SKIP')));
      expect(templateBodies['t-eth']!['compute_id'], 'local');
      expect(templateBodies['t-vpcs']!['compute_id'], 'local');
    },
  );

  test(
    'a template the server does not have is reported as SKIP, not pushed null',
    () async {
      Future<http.Response> handler(http.Request request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path == '/v2/projects') {
          return http.Response(jsonEncode({'project_id': 'proj-1'}), 201);
        }
        if (request.method == 'GET' && path == '/v2/templates') {
          return http.Response(jsonEncode(const []), 200);
        }
        return http.Response('unexpected: $request', 500);
      }

      final report = await Gns3Adapter.push(
        NetworkIntent(
          projectName: 'no-router-images',
          nodes: const [NetNode(name: 'R1', type: 'router', model: '2911')],
          links: const [],
        ),
        endpoint: 'http://127.0.0.1:3080',
        user: 'admin',
        pass: 'secret',
        client: MockClient(handler),
      );
      expect(report, contains('SKIP R1'));
      expect(report, contains('no GNS3 template matching "c3725"'));
    },
  );
  test(
    'testConnection reports the server version and fails closed on 401',
    () async {
      Future<http.Response> ok(http.Request request) async {
        expect(request.url.path, '/v2/version');
        expect(
          request.headers['Authorization'],
          'Basic ${base64Encode(utf8.encode('admin:secret'))}',
          reason: 'GNS3 2.2+ requires HTTP auth on every call',
        );
        return http.Response(jsonEncode({'version': '2.2.61', 'local': true}), 200);
      }

      final version = await Gns3Adapter.testConnection(
        'http://127.0.0.1:3080',
        user: 'admin',
        pass: 'secret',
        client: MockClient(ok),
      );
      expect(version, '2.2.61');

      Future<http.Response> denied(http.Request request) async =>
          http.Response('Invalid HTTP authentication', 401);

      await expectLater(
        Gns3Adapter.testConnection(
          'http://127.0.0.1:3080',
          user: 'admin',
          pass: 'wrong',
          client: MockClient(denied),
        ),
        throwsA(
          isA<Gns3ApiException>().having(
            (e) => e.status,
            'status',
            401,
          ),
        ),
      );
    },
  );
}
