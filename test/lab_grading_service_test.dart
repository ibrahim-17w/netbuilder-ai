import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/lab_grading_service.dart';

void main() {
  test('a DHCP note does not satisfy the generated-pool check', () {
    final plan = NetworkIntent(
      projectName: 'office',
      vlans: const [10, 20],
      notes: const ['Remember to configure DHCP'],
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'DHCP1', type: 'server', services: ['dhcp']),
      ],
      links: const [NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'g0/1')],
    );

    final grade = LabGradingService.grade('office-vlans-dhcp', plan);
    final dhcp = grade.singleWhere(
      (check) => check.label == 'Configure DHCP pools',
    );
    expect(dhcp.passed, isFalse);
  });

  test(
    'DHCP check passes only when generated pools match both VLAN interfaces',
    () {
      final plan = NetworkIntent(
        projectName: 'office',
        vlans: const [10, 20],
        nodes: const [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'SW1', type: 'switch'),
          NetNode(name: 'DHCP1', type: 'server', services: ['dhcp']),
        ],
        links: const [NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'g0/1')],
        addressing: const [
          InterfaceAddr(
            node: 'R1',
            iface: 'g0/0.10',
            ipCidr: '192.168.10.1/24',
          ),
          InterfaceAddr(
            node: 'R1',
            iface: 'g0/0.20',
            ipCidr: '192.168.20.1/24',
          ),
          InterfaceAddr(node: 'DHCP1', iface: 'f0', ipCidr: '192.168.10.2/24'),
        ],
      );

      final grade = LabGradingService.grade('office-vlans-dhcp', plan);
      expect(
        grade
            .singleWhere((check) => check.label == 'Configure DHCP pools')
            .passed,
        isTrue,
      );
    },
  );

  test('DNS and HTTP require enabled services and a connected client path', () {
    NetworkIntent plan({required bool services, required bool cables}) =>
        NetworkIntent(
          projectName: 'services',
          nodes: [
            const NetNode(name: 'PC1', type: 'pc'),
            const NetNode(name: 'SW1', type: 'switch'),
            NetNode(
              name: 'DNS1',
              type: 'server',
              services: services ? const ['dns'] : const [],
            ),
            NetNode(
              name: 'WEB1',
              type: 'server',
              services: services ? const ['http'] : const [],
            ),
          ],
          links: cables
              ? const [
                  NetLink(a: 'PC1', aIf: 'f0', b: 'SW1', bIf: 'f0/1'),
                  NetLink(a: 'DNS1', aIf: 'f0', b: 'SW1', bIf: 'f0/2'),
                  NetLink(a: 'WEB1', aIf: 'f0', b: 'SW1', bIf: 'f0/3'),
                ]
              : const [],
          addressing: const [
            InterfaceAddr(node: 'DNS1', iface: 'f0', ipCidr: '192.168.1.10/24'),
            InterfaceAddr(node: 'WEB1', iface: 'f0', ipCidr: '192.168.1.20/24'),
          ],
        );

    final good = LabGradingService.grade(
      'dns-web-services',
      plan(services: true, cables: true),
    );
    expect(good.every((check) => check.passed), isTrue);
    final disconnected = LabGradingService.grade(
      'dns-web-services',
      plan(services: true, cables: false),
    );
    expect(
      disconnected
          .singleWhere((check) => check.label == 'Connect client and servers')
          .passed,
      isFalse,
    );
    final absent = LabGradingService.grade(
      'dns-web-services',
      plan(services: false, cables: true),
    );
    expect(
      absent.singleWhere((check) => check.label == 'Enable HTTP').passed,
      isFalse,
    );
  });

  test('OSPF lab validates an addressed transit subnet and two local LANs', () {
    NetworkIntent plan(String secondTransitIp) => NetworkIntent(
      projectName: 'ospf',
      routing: 'ospf',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'R2', type: 'router'),
        NetNode(name: 'SW1', type: 'switch'),
        NetNode(name: 'SW2', type: 'switch'),
        NetNode(name: 'PC1', type: 'pc'),
        NetNode(name: 'PC2', type: 'pc'),
      ],
      links: const [
        NetLink(a: 'R1', aIf: 'g0/1', b: 'R2', bIf: 'g0/1'),
        NetLink(a: 'R1', aIf: 'g0/0', b: 'SW1', bIf: 'g0/1'),
        NetLink(a: 'SW1', aIf: 'f0/1', b: 'PC1', bIf: 'f0'),
        NetLink(a: 'R2', aIf: 'g0/0', b: 'SW2', bIf: 'g0/1'),
        NetLink(a: 'SW2', aIf: 'f0/1', b: 'PC2', bIf: 'f0'),
      ],
      addressing: [
        const InterfaceAddr(node: 'R1', iface: 'g0/1', ipCidr: '10.0.0.1/30'),
        InterfaceAddr(node: 'R2', iface: 'g0/1', ipCidr: '$secondTransitIp/30'),
        const InterfaceAddr(
          node: 'R1',
          iface: 'g0/0',
          ipCidr: '192.168.10.1/24',
        ),
        const InterfaceAddr(
          node: 'PC1',
          iface: 'f0',
          ipCidr: '192.168.10.2/24',
        ),
        const InterfaceAddr(
          node: 'R2',
          iface: 'g0/0',
          ipCidr: '192.168.20.1/24',
        ),
        const InterfaceAddr(
          node: 'PC2',
          iface: 'f0',
          ipCidr: '192.168.20.2/24',
        ),
      ],
    );

    final valid = LabGradingService.grade('two-routers-ospf', plan('10.0.0.2'));
    expect(valid.every((check) => check.passed), isTrue);
    final invalid = LabGradingService.grade(
      'two-routers-ospf',
      plan('10.0.1.2'),
    );
    expect(
      invalid
          .singleWhere(
            (check) => check.label == 'Configure the router transit link',
          )
          .passed,
      isFalse,
    );
  });
}
