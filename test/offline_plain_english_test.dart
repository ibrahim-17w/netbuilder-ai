import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';

/// Wordings added to the keyless wording bridge. Each one used to fall through
/// the deterministic parser even though it is plain English.
void main() {
  group('keyless planner: plain-English wordings', () {
    test('"a pair of" and "half a dozen" are read as quantities', () {
      final pair = NetworkIntent.parseSimple(
        'p',
        'a pair of routers and a pair of switches',
      );
      expect(pair.nodes.where((n) => n.type == 'router').length, 2);
      expect(pair.nodes.where((n) => n.type == 'switch').length, 2);
      expect(NetworkIntent.bridgeBrief('half a dozen pcs'), contains('6'));
    });

    test('"point to point" asks for a serial WAN between two routers', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '2 routers 2 switches 4 pcs with a point to point link',
      );
      expect(intent.links.any((l) => l.isSerial), isTrue);
    });

    test('"guest wifi" builds a wireless network', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 3 pcs and guest wifi',
      );
      expect(intent.nodes.any((n) => n.type == 'wireless'), isTrue);
    });

    test('a TACACS+ server is read as the AAA service', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        'a TACACS+ server for centralized authentication',
      );
      final server = intent.nodes.firstWhere((n) => n.type == 'server');
      expect(server.services, contains('aaa'));
    });

    test('"VLAN 10 and 20" lists both VLANs', () {
      final intent = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 4 pcs with VLAN 10 and 20',
      );
      expect(intent.vlans, containsAll(<int>[10, 20]));
    });
  });
}
