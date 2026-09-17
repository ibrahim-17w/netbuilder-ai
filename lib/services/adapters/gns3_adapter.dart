import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../models/network_intent.dart';

/// Compiles intent -> GNS3 REST payload (create project + nodes + links).
/// GNS3 server API: http://127.0.0.1:3080/v2/*
class Gns3Adapter {
  /// Payload the app POSTs to the GNS3 server. Pure data, unit-testable.
  static Map<String, dynamic> projectPayload(NetworkIntent intent) => {
    'name': intent.projectName,
    'nodes': [
      for (final n in intent.nodes)
        {
          'name': n.name,
          'node_type': _gnsType(n.type),
          'template': _template(n),
          'properties': {if (n.mgmtIp != null) 'mgmt_ip': n.mgmtIp},
        },
    ],
    'links': [
      for (final l in intent.links)
        {
          'a': {'node': l.a, 'iface': l.aIf},
          'b': {'node': l.b, 'iface': l.bIf},
        },
    ],
    'configs': CiscoRendererShim.render(intent),
  };

  static String exportJson(NetworkIntent intent) =>
      const JsonEncoder.withIndent('  ').convert(projectPayload(intent));

  static String _gnsType(String t) {
    switch (t) {
      case 'router':
        return 'dynamips';
      case 'switch':
        return 'ethernet_switch';
      case 'pc':
        return 'vpcs';
      default:
        return 'dynamips';
    }
  }

  /// node.model holds the PT model (2911/1941/...). Translate to GNS3
  /// dynamips templates; PT ISRs have no 1:1 GNS3 image, c3725 is closest.
  static const _ptIsr = ['4331', '4321', '2911', '2901', '1941', '829', '1240'];
  static String _template(NetNode n) {
    final m = n.model;
    if (m != null) {
      if (_ptIsr.contains(m)) return 'c3725';
      if (m == '2960' || m == '2950' || m == '3560') {
        return 'Ethernet switch';
      }
      if (m == 'PC-PT' || m == 'VPCS') return 'VPCS';
      return m; // already a GNS3 template name
    }
    switch (n.type) {
      case 'router':
        return 'c3725';
      case 'switch':
        return 'Ethernet switch';
      case 'pc':
        return 'VPCS';
      default:
        return 'c3725';
    }
  }

  /// 'g0/0' -> (adapter 0, port 0); 'f0/2' -> (0, 2); 's1/0' -> (1, 0).
  static (int, int) portOf(String iface) {
    final m = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(iface);
    if (m == null) return (0, 0);
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  /// Push the whole topology to a GNS3 2.x server.
  ///
  /// Why 401 happened: GNS3 2.2+ ships with HTTP authentication enabled
  /// (user 'admin'), and the app sent NO Authorization header. Now Basic
  /// auth is attached from Settings. The push then:
  ///   1. creates (or reuses by name) the project
  ///   2. instantiates each node from a server TEMPLATE matched by name
  ///      ('c3725' / 'Ethernet switch' / 'VPCS' must exist server-side)
  ///   3. wires links with adapter/port numbers parsed from the ifaces
  /// Returns a human-readable report; throws on fatal errors (401 etc).
  static Future<String> push(
    NetworkIntent intent, {
    required String endpoint,
    String user = '',
    String pass = '',
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    String basic() {
      final raw = base64Encode(utf8.encode('$user:$pass'));
      return 'Basic $raw';
    }

    Future<dynamic> call(String method, String path, {Object? body}) async {
      final uri = Uri.parse('$base/v2$path');
      final req = http.Request(method, uri)
        ..headers['Authorization'] = basic()
        ..headers['Content-Type'] = 'application/json';
      if (body != null) req.body = jsonEncode(body);
      final res = await http.Response.fromStream(
        await c.send(req),
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        throw Gns3ApiException(res.statusCode, res.body);
      }
      return res.body.isEmpty ? null : jsonDecode(res.body);
    }

    // 1) project: create, or reuse on conflict (same-name project exists)
    dynamic proj;
    try {
      proj = await call(
        'POST',
        '/projects',
        body: {'name': intent.projectName},
      );
    } on Gns3ApiException catch (e) {
      if (e.status != 409) rethrow;
      final list = await call('GET', '/projects') as List;
      proj = list.firstWhere(
        (p) => p['name'] == intent.projectName,
        orElse: () => throw Gns3ApiException(
          409,
          'project exists but was not found in /projects',
        ),
      );
    }
    final pid = proj['project_id'] as String;

    // 2) templates on the server -> map every node to a template id
    final templates = await call('GET', '/templates') as List;
    final report = StringBuffer();
    final nodeIds = <String, String>{};
    for (final n in intent.nodes) {
      final want = _template(n);
      dynamic tpl;
      for (final t in templates) {
        final name = (t['name'] ?? '').toString().toLowerCase();
        if (name == want.toLowerCase()) {
          tpl = t;
          break;
        }
      }
      tpl ??= templates.firstWhere(
        (t) => (t['name'] ?? '').toString().toLowerCase().contains(
          want.toLowerCase().split(' ').first,
        ),
        orElse: () => null,
      );
      if (tpl == null) {
        report.writeln(
          'SKIP ${n.name}: no GNS3 template matching "$want" on the server',
        );
        continue;
      }
      try {
        final node = await call(
          'POST',
          '/projects/$pid/templates/${tpl['id']}',
          body: {'name': n.name, 'x': 0, 'y': 0},
        );
        nodeIds[n.name] = node['node_id'] as String;
        report.writeln('OK node ${n.name} from template "${tpl['name']}"');
      } on Gns3ApiException catch (e) {
        if (e.status == 409) {
          // node with this name already exists in the project: reuse it
          final nodes = await call('GET', '/projects/$pid/nodes') as List;
          final existing = nodes.firstWhere(
            (x) => x['name'] == n.name,
            orElse: () => null,
          );
          if (existing != null) {
            nodeIds[n.name] = existing['node_id'] as String;
            report.writeln('REUSE existing node ${n.name}');
            continue;
          }
        }
        report.writeln('FAIL node ${n.name}: ${e.message}');
      }
    }

    // 3) links between created nodes
    var wired = 0;
    for (final l in intent.links) {
      final aId = nodeIds[l.a];
      final bId = nodeIds[l.b];
      if (aId == null || bId == null) {
        report.writeln(
          'SKIP link ${l.a}:${l.aIf}<->${l.b}:${l.bIf} '
          '(missing node)',
        );
        continue;
      }
      final (aa, ap) = portOf(l.aIf);
      final (ba, bp) = portOf(l.bIf);
      try {
        await call(
          'POST',
          '/projects/$pid/links',
          body: {
            'nodes': [
              {
                'node_id': aId,
                'adapter_number': aa,
                'port_number': ap,
                'label': {'text': l.aIf, 'x': -12, 'y': -12},
              },
              {
                'node_id': bId,
                'adapter_number': ba,
                'port_number': bp,
                'label': {'text': l.bIf, 'x': 12, 'y': -12},
              },
            ],
          },
        );
        wired++;
        report.writeln('OK link ${l.a}:${l.aIf} <-> ${l.b}:${l.bIf}');
      } on Gns3ApiException catch (e) {
        report.writeln(
          'FAIL link ${l.a}:${l.aIf}<->${l.b}:${l.bIf}: ${e.message}',
        );
      }
    }
    return 'Project "${intent.projectName}" ($pid): '
        '${nodeIds.length}/${intent.nodes.length} nodes, '
        '$wired/${intent.links.length} links.\n$report';
  }
}

class Gns3ApiException implements Exception {
  final int status;
  final String message;
  Gns3ApiException(this.status, this.message);
  @override
  String toString() => 'GNS3 $status: $message';
}

/// Tiny shim so gns3 adapter doesn't import cisco_adapter directly in tests
/// if file layout changes; delegates at runtime via dynamic import avoidance.
/// We duplicate the 3-line call here by re-exporting logic through a function
/// implemented in cisco_adapter (kept in sync manually, tested).
class CiscoRendererShim {
  static Map<String, String> render(NetworkIntent intent) {
    // Intentionally duplicated minimal rendering to keep adapter dependency-free.
    // Full fidelity lives in CiscoAdapter; this covers GNS3 export smoke tests.
    final out = <String, String>{};
    for (final n in intent.nodes) {
      final sb = StringBuffer()..writeln('hostname ${n.name}');
      for (final a in intent.addressing.where((e) => e.node == n.name)) {
        sb.writeln('interface ${a.iface}');
        sb.writeln(' ip address ${a.ipCidr}');
        sb.writeln(' no shutdown');
      }
      out[n.name] = sb.toString();
    }
    return out;
  }
}
