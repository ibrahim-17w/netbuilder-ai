import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/network_tools.dart';

void main() {
  group('subnet maths is exact', () {
    test('/24', () {
      final info = NetworkTools.subnet('192.168.1.37/24')!;
      expect(info.network, '192.168.1.0');
      expect(info.broadcast, '192.168.1.255');
      expect(info.firstHost, '192.168.1.1');
      expect(info.lastHost, '192.168.1.254');
      expect(info.mask, '255.255.255.0');
      expect(info.usableHosts, 254);
    });

    test('/30 transit link', () {
      final info = NetworkTools.subnet('10.1.1.2/30')!;
      expect(info.network, '10.1.1.0');
      expect(info.broadcast, '10.1.1.3');
      expect(info.mask, '255.255.255.252');
      expect(info.usableHosts, 2);
    });

    test('/31 and /32 are handled without inventing host counts', () {
      expect(NetworkTools.subnet('10.0.0.0/31')!.usableHosts, 2);
      expect(NetworkTools.subnet('10.0.0.7/32')!.usableHosts, 1);
    });

    test('rubbish in, null out - never a guess', () {
      expect(NetworkTools.subnet('300.1.1.1/24'), isNull);
      expect(NetworkTools.subnet('10.0.0.1/33'), isNull);
      expect(NetworkTools.subnet('nonsense'), isNull);
    });
  });

  group('same-subnet and membership', () {
    test('same subnet', () {
      expect(NetworkTools.sameSubnet('192.168.1.10/24', '192.168.1.20/24'),
          isTrue);
    });
    test('different subnet', () {
      expect(NetworkTools.sameSubnet('192.168.1.10/24', '192.168.2.10/24'),
          isFalse);
    });
    test('same address, different mask - not the same subnet', () {
      expect(NetworkTools.sameSubnet('10.0.0.1/24', '10.0.0.1/16'), isFalse);
    });
    test('membership', () {
      expect(NetworkTools.contains('10.0.0.0/22', '10.0.1.5'), isTrue);
      expect(NetworkTools.contains('10.0.0.0/22', '10.0.4.5'), isFalse);
    });
  });

  group('gateway checks', () {
    test('a good gateway', () {
      final r = NetworkTools.checkGateway(
        hostCidr: '192.168.1.10/24',
        gateway: '192.168.1.1',
      );
      expect(r['ok'], isTrue);
    });
    test('a gateway outside the subnet is a fault', () {
      final r = NetworkTools.checkGateway(
        hostCidr: '192.168.1.10/24',
        gateway: '192.168.2.1',
      );
      expect(r['ok'], isFalse);
      expect(r['reason'], contains('outside'));
    });
    test('network and broadcast addresses are refused', () {
      expect(
        NetworkTools.checkGateway(
          hostCidr: '10.0.0.5/24',
          gateway: '10.0.0.0',
        )['ok'],
        isFalse,
      );
      expect(
        NetworkTools.checkGateway(
          hostCidr: '10.0.0.5/24',
          gateway: '10.0.0.255',
        )['ok'],
        isFalse,
      );
    });
    test('a host naming itself as gateway is refused', () {
      expect(
        NetworkTools.checkGateway(
          hostCidr: '10.0.0.5/24',
          gateway: '10.0.0.5',
        )['ok'],
        isFalse,
      );
    });
  });

  test('duplicate addresses are found', () {
    final dupes = NetworkTools.duplicateAddresses([
      {'node': 'PC1', 'iface': 'f0', 'ipCidr': '192.168.1.10/24'},
      {'node': 'PC2', 'iface': 'f0', 'ipCidr': '192.168.1.10/24'},
      {'node': 'PC3', 'iface': 'f0', 'ipCidr': '192.168.1.11/24'},
    ]);
    expect(dupes.length, 1);
    expect(dupes.first['address'], '192.168.1.10');
    expect((dupes.first['usedBy'] as List).length, 2);
  });

  test('the model context is structured, never raw .pkt bytes', () {
    final context = NetworkTools.buildContext({
      'devices': [
        {
          'name': 'R1',
          'type': 'router',
          'model': '2911',
          'interfaces': [
            {'node': 'R1', 'iface': 'g0/0', 'ipCidr': '10.0.0.1/24'},
          ],
          'findings': [
            {'id': 'x', 'severity': 'high', 'text': 'shutdown'},
          ],
        },
      ],
      'links': [
        {'a': 'R1', 'b': 'SW1'},
      ],
    });
    expect(context['devices'], isA<List>());
    expect(context['interfaces'], isA<List>());
    expect(context['findings'], isA<List>());
    expect(context.keys, containsAll(
        ['devices', 'interfaces', 'links', 'vlans', 'routes', 'services']));
    expect(context.toString(), isNot(contains('PACKETTRACER')));
  });

  test('a huge capture is trimmed and says so', () {
    final interfaces = [
      for (var i = 0; i < 4000; i++)
        {'node': 'N$i', 'iface': 'f0', 'ipCidr': '10.$i.0.1/24'},
    ];
    final context = NetworkTools.buildContext({
      'devices': [
        {'name': 'BIG', 'type': 'switch', 'interfaces': interfaces},
      ],
    }, maxChars: 4000);
    expect(context['truncated'], isTrue);
    expect(context['interfaces'], hasLength(80));
  });
}
