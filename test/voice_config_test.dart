import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';

void main() {
  _cmeAppendsToMainConfig();
  test('CME telephony config lands on the gateway router', () {
    const intent = NetworkIntent(
      projectName: 'voice-lab',
      nodes: [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'CME1', type: 'server', services: ['cme']),
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

void _cmeAppendsToMainConfig() {
  test('the CME block appends to the main config instead of replacing it', () {
    // The plan's configs map used to spread voiceConfig LAST, so its "R1"
    // key replaced the main config wholesale: a plan with phones + a CME
    // server built a router whose saved config was the telephony block
    // alone - no addresses, no OSPF, no gateways.
    final intent = NetworkIntent(
      projectName: 'voice-append',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'CME1', type: 'server', services: ['cme']),
        NetNode(name: 'PH1', type: 'phone'),
        NetNode(name: 'PH2', type: 'phone'),
      ],
      links: const [
        NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'f0/1'),
        NetLink(a: 'PH1', aIf: 'port1', b: 'SW1', bIf: 'f0/3'),
        NetLink(a: 'PH2', aIf: 'port1', b: 'SW1', bIf: 'f0/4'),
      ],
      addressing: const [
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.10.1/24'),
        InterfaceAddr(node: 'CME1', iface: 'f0', ipCidr: '192.168.10.10/24'),
      ],
    );
    final main = CiscoAdapter.render(intent)['R1']!;
    expect(main, contains('ip address 192.168.10.1'));
    expect(main, isNot(contains('telephony-service')));

    // The merge the plan uses: main configs first, firewalls, then voice
    // APPENDED per key - the exact shape PacketTracerAdapter.builds.
    final configs = {...CiscoAdapter.render(intent)};
    CiscoAdapter.voiceConfig(intent).forEach((router, cme) {
      configs[router] = configs.containsKey(router)
          ? '${configs[router]!}\n$cme'
          : cme;
    });
    final merged = configs['R1']!;
    expect(merged, contains('ip address 192.168.10.1'));
    expect(merged, contains('telephony-service'));
    expect(
      merged.indexOf('ip address 192.168.10.1'),
      lessThan(merged.indexOf('telephony-service')),
    );
  });
}
