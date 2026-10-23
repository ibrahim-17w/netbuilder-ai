import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/build_guide.dart';

void main() {
  NetNode node(
    String name,
    String type,
    String model, {
    List<String> services = const [],
    Map<String, dynamic> rules = const {},
  }) =>
      NetNode(
        name: name,
        type: type,
        model: model,
        services: services,
        serviceRules: rules,
      );

  test('the guide lists devices, cables, configs and server roles', () {
    final intent = NetworkIntent(
      projectName: 'office',
      routing: 'ospf',
      nodes: [
        node('R1', 'router', '4331'),
        node('SW1', 'switch', '2960'),
        node('PC1', 'pc', 'PC-PT'),
        node(
          'DNS1',
          'server',
          'Server-PT',
          services: ['dns', 'http'],
          rules: {
            'dns': {
              'records': [
                {'name': 'web.lab', 'address': '192.168.1.53'},
              ],
            },
          },
        ),
        node('SNIFF1', 'sniffer', 'Sniffer'),
        node('FW1', 'firewall', '5506'),
      ],
      links: const [
        NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
        NetLink(a: 'SW1', aIf: 'f0/2', b: 'PC1', bIf: 'f0'),
        NetLink(a: 'SW1', aIf: 'f0/3', b: 'DNS1', bIf: 'f0'),
        NetLink(a: 'SW1', aIf: 'f0/4', b: 'SNIFF1', bIf: 'ethernet0'),
        NetLink(a: 'R1', aIf: 'g0/1', b: 'FW1', bIf: 'g1/1'),
      ],
      addressing: const [
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.1.1/24'),
        InterfaceAddr(node: 'PC1', iface: 'f0', ipCidr: '192.168.1.10/24'),
        InterfaceAddr(node: 'DNS1', iface: 'f0', ipCidr: '192.168.1.53/24'),
        InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '10.0.0.1/30'),
        InterfaceAddr(node: 'FW1', iface: 'g1/1', ipCidr: '10.0.0.2/30'),
      ],
    );

    final guide = BuildGuide.markdown(intent);

    expect(guide, contains('# Build guide - office'));
    expect(guide, contains('## 1. Place the devices (6)'));
    expect(guide, contains('| SNIFF1 | sniffer | Sniffer |'));
    expect(guide, contains('## 2. Cable and associate (5)'));
    expect(guide, contains('| SW1 | f0/4 | SNIFF1 | ethernet0 |'));
    expect(guide, contains('## 3. Configure'));
    expect(guide, contains('### Servers'));
    expect(guide, contains('**DNS**'));
    expect(guide, contains('web.lab -> 192.168.1.53'));
    expect(guide, contains('**HTTP**'));
    expect(guide, contains('### Desktop IP configuration'));
    expect(guide, contains('| PC1 | 192.168.1.10 |'));
    expect(guide, contains('## 4. Check it works'));
    expect(guide, contains('## 5. What is manual'));
    expect(guide, contains('offline .pkt only'));
    expect(guide, contains('ASA configuration is stored inside the generated'));
    // The guide is instructions only: it never claims a file was written.
    expect(guide, contains('no .pkt is written'));
  });

  test('a plan with no servers or links still gets usable steps', () {
    final guide = BuildGuide.markdown(
      const NetworkIntent(
        projectName: 'empty-ish',
        nodes: [NetNode(name: 'R1', type: 'router', model: '4331')],
      ),
    );
    expect(guide, contains('## 1. Place the devices (1)'));
    expect(guide, contains('No copper cables are defined'));
    expect(guide, contains('## 4. Check it works'));
    expect(guide, contains('show ip route'));
  });
}
