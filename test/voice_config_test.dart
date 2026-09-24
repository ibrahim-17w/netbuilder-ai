import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';

void main() {
  test('CME telephony config lands on the gateway router', () {
    const intent = NetworkIntent(
      projectName: 'voice-lab',
      nodes: [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(
          name: 'CME1',
          type: 'server',
          services: ['cme'],
        ),
        NetNode(name: 'PH1', type: 'phone'),
        NetNode(name: 'PH2', type: 'phone'),
      ],
      links: [
        NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
        NetLink(a: 'CME1', aIf: 'f0', b: 'SW1', bIf: 'f0/2'),
        NetLink(a: 'PH1', aIf: 'port1', b: 'SW1', bIf: 'f0/3'),
        NetLink(a: 'PH2', aIf: 'port1', b: 'SW1', bIf: 'f0/4'),
      ],
      addressing: [
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.10.1/24'),
        InterfaceAddr(node: 'CME1', iface: 'f0', ipCidr: '192.168.10.10/24'),
      ],
    );
    final cfgs = CiscoAdapter.voiceConfig(intent);
    expect(cfgs.containsKey('R1'), isTrue);
    final cfg = cfgs['R1']!;
    expect(cfg, contains('telephony-service'));
    expect(cfg, contains(' max-ephones 2'));
    expect(cfg, contains(' ip source-address 192.168.10.1 port 2000'));
    expect(cfg, contains('ephone-dn 0'));
    expect(cfg, contains(' number 2001'));
    expect(cfg, contains(' number 2002'));
  });

  test('no phones means no voice config', () {
    const intent = NetworkIntent(
      projectName: 'no-voice',
      nodes: [NetNode(name: 'R1', type: 'router')],
      addressing: [
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.10.1/24'),
      ],
    );
    expect(CiscoAdapter.voiceConfig(intent), isEmpty);
  });
}
