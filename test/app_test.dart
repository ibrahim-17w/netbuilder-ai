import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/adapters/gns3_adapter.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/adapters/terraform_adapter.dart';
import 'package:net_builder/services/privacy_search_service.dart';
import 'package:net_builder/services/rule_packs_service.dart';
import 'package:net_builder/services/validator_service.dart';

void main() {
  test('parseSimple builds routers/switches + ospf', () {
    final i = NetworkIntent.parseSimple(
      'office',
      '2 routers 1 switch with OSPF on 192.168.1.0/24',
    );
    expect(i.nodes.length, 3);
    expect(i.routing, 'ospf');
    expect(i.addressing.isNotEmpty, true);
  });

  test('instruction picks best PT model, explicit wins', () {
    final d = NetworkIntent.parseSimple('a', '2 routers ospf');
    expect(d.nodes.firstWhere((n) => n.type == 'router').model, '2911');
    final e = NetworkIntent.parseSimple('a', '1 router bgp enterprise');
    expect(e.nodes.firstWhere((n) => n.type == 'router').model, '4331');
    final f = NetworkIntent.parseSimple('a', '1 router use 1941 small lab');
    expect(f.nodes.firstWhere((n) => n.type == 'router').model, '1941');
    final g = NetworkIntent.parseSimple('g', '2 routers 1 switch');
    final p = Gns3Adapter.projectPayload(g);
    final templates = (p['nodes'] as List)
        .map((n) => (n as Map)['template'])
        .toList();
    expect(templates.contains('c3725'), true); // PT 2911 -> GNS3 c3725
  });

  test('hardware model numbers are not mistaken for device counts', () {
    final i = NetworkIntent.parseSimple(
      'verified-learning-lab',
      'R1 and R2 are Cisco 2911 routers. '
          'SW1 and SW2 are Cisco 2960 switches. '
          'PC1 and PC2 are connected to the switches. '
          'SRV1 is a server.',
    );
    expect(i.nodes.where((n) => n.type == 'router').length, 2);
    expect(i.nodes.where((n) => n.type == 'switch').length, 2);
    expect(i.nodes.where((n) => n.type == 'pc').length, 2);
    expect(i.nodes.where((n) => n.type == 'server').length, 1);
    expect(
      i.nodes.map((n) => n.name),
      containsAll(['R1', 'R2', 'SW1', 'SW2', 'PC1', 'PC2', 'SRV1']),
    );
  });

  test('Packet Tracer blocks implausibly large plans', () {
    final nodes = [
      for (var i = 1; i <= 51; i++) NetNode(name: 'R$i', type: 'router'),
    ];
    final issues = ValidatorService.validate(
      NetworkIntent(projectName: 'too-large', nodes: nodes),
      target: 'packet-tracer',
    );
    expect(ValidatorService.hasErrors(issues), true);
    expect(issues.any((i) => i.message.contains('more than 50')), true);
  });

  test('validator catches duplicate IP', () {
    final i = NetworkIntent(
      projectName: 't',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'R2', type: 'router'),
      ],
      addressing: const [
        InterfaceAddr(node: 'R1', iface: 'f0/0', ipCidr: '192.168.1.1/24'),
        InterfaceAddr(node: 'R2', iface: 'f0/0', ipCidr: '192.168.1.1/24'),
      ],
    );
    final issues = ValidatorService.validate(i);
    expect(ValidatorService.hasErrors(issues), true);
  });

  test(
    'validator catches unsafe Packet Tracer references before execution',
    () {
      final i = NetworkIntent(
        projectName: 'unsafe-links',
        nodes: const [
          NetNode(name: 'R1', type: 'router'),
          // A kind the catalog does not know: firewalls ARE buildable now
          // (placeable + cableable), so this test needs a type that is not.
          NetNode(name: 'FW1', type: 'load-balancer'),
          NetNode(name: 'PC1', type: 'pc'),
          NetNode(name: 'SW1', type: 'switch', services: ['dns']),
        ],
        links: const [
          NetLink(a: 'R1', aIf: 'g0/0', b: 'PC1', bIf: 'f0'),
          NetLink(a: 'R1', aIf: 'g0/0', b: 'FW1', bIf: 'g0/0'),
        ],
        addressing: const [
          InterfaceAddr(node: 'MISSING', iface: 'g0/0', ipCidr: '10.0.0.1/33'),
        ],
      );
      final issues = ValidatorService.validate(i, target: 'packet-tracer');
      expect(ValidatorService.hasErrors(issues), true);
      expect(issues.any((x) => x.message.contains('unknown node')), true);
      expect(issues.any((x) => x.message.contains('invalid IP')), true);
      expect(issues.any((x) => x.message.contains('used by 2 links')), true);
      expect(issues.any((x) => x.message.contains('cannot build FW1')), true);
      expect(issues.any((x) => x.message.contains('not a server')), true);

      // A firewall IS buildable now (it has a palette path and a cable):
      // the check above fires for the unknown type, not for ASA devices.
      final firewall = NetworkIntent(
        projectName: 'fw-ok',
        nodes: const [
          NetNode(name: 'R1', type: 'router'),
          NetNode(name: 'FW1', type: 'firewall', model: '5506'),
        ],
        links: const [NetLink(a: 'R1', aIf: 'g0/2', b: 'FW1', bIf: 'g1/1')],
        addressing: const [
          InterfaceAddr(node: 'R1', iface: 'g0/2', ipCidr: '10.0.0.1/30'),
        ],
      );
      expect(
        ValidatorService.validate(firewall, target: 'packet-tracer').any(
          (x) => x.message.contains('cannot build'),
        ),
        isFalse,
      );
    },
  );

  test('validator blocks malformed server rules before execution', () {
    final i = NetworkIntent(
      projectName: 'bad-service-rules',
      nodes: const [
        NetNode(
          name: 'SRV1',
          type: 'server',
          services: ['dns', 'ftp'],
          serviceRules: {
            'dns': {
              'records': [
                {'name': 'bad.lab', 'address': 'not-an-ip'},
              ],
            },
            'ftp': {
              'users': [
                {'username': 'alice'},
              ],
            },
          },
        ),
      ],
    );
    final issues = ValidatorService.validate(i, target: 'packet-tracer');
    expect(ValidatorService.hasErrors(issues), isTrue);
    expect(issues.any((x) => x.message.contains('invalid DNS record')), isTrue);
    expect(
      issues.any((x) => x.message.contains('missing username or password')),
      isTrue,
    );
  });

  test('validator accepts multiple hosts in one LAN', () {
    final i = NetworkIntent(
      projectName: 'valid-lan',
      nodes: const [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'PC1', type: 'pc'),
        NetNode(name: 'PC2', type: 'pc'),
      ],
      addressing: const [
        InterfaceAddr(node: 'R1', iface: 'g0/0', ipCidr: '192.168.10.1/24'),
        InterfaceAddr(node: 'PC1', iface: 'f0', ipCidr: '192.168.10.10/24'),
        InterfaceAddr(node: 'PC2', iface: 'f0', ipCidr: '192.168.10.11/24'),
      ],
    );
    expect(
      ValidatorService.hasErrors(
        ValidatorService.validate(i, target: 'packet-tracer'),
      ),
      false,
    );
  });

  test('validator clean on parsed intent', () {
    final i = NetworkIntent.parseSimple('a', '1 router 1 switch');
    expect(
      ValidatorService.hasErrors(ValidatorService.validate(i, target: 'gns3')),
      false,
    );
  });

  test('cisco render contains hostname + ospf', () {
    final i = NetworkIntent.parseSimple('x', '1 router with OSPF');
    final cfgs = CiscoAdapter.render(i);
    expect(cfgs['R1']!.contains('hostname R1'), true);
    expect(cfgs['R1']!.contains('router ospf 1'), true);
  });

  test('gns3 payload has nodes/links', () {
    final i = NetworkIntent.parseSimple('g', '2 routers 1 switch');
    final p = Gns3Adapter.projectPayload(i);
    expect((p['nodes'] as List).length, 3);
    expect(p['name'], 'g');
  });

  test('pt autopilot plan requires open window', () {
    final i = NetworkIntent.parseSimple('p', '1 router 1 switch');
    final plan = PacketTracerAdapter.autopilotPlan(i);
    expect((plan['requirement'] as String).contains('uninterrupted'), true);
    expect(
      (plan['steps'] as List).length,
      5,
    ); // nodes, links, cli, pcs, servers
  });

  test('terraform renders vpc', () {
    final i = NetworkIntent.parseSimple('c', '2 routers');
    expect(TerraformAdapter.renderAwsVpc(i).contains('aws_vpc'), true);
  });

  test('redact strips secrets, buildQuery is generic', () {
    const raw = 'hostname CORP-R1\npassword hunter2\nip 10.1.2.3/24';
    final r = PrivacySearchService.redact(raw);
    expect(r.contains('hunter2'), false);
    expect(r.contains('CORP-R1'), false);
    final q = PrivacySearchService.buildQuery(
      errorText: 'OSPF authentication mismatch on R1',
      target: 'gns3',
    );
    expect(q.contains('ospf'), true);
    expect(q.contains('10.1.2.3'), false);
  });

  test('rule packs context block contains target rules', () {
    final ctx = RulePacksService.contextBlock(
      target: 'gns3',
      pastBuildSummaries: ['office [gns3] OK: 2 routers'],
      learnedRules: ['Prefer OSPF area 0'],
      preferences: {'default_subnet': '10.0.0.0/16'},
    );
    expect(ctx.contains('gns3'), true);
    expect(ctx.contains('Prefer OSPF'), true);
  });

  test('intent keeps explainability metadata through JSON round-trip', () {
    final original = NetworkIntent(
      projectName: 'explainable',
      nodes: const [NetNode(name: 'R1', type: 'router', model: '2911')],
      assumptions: const ['Use OSPF area 0'],
      questions: const ['Which WAN provider should be used?'],
      confidence: 0.82,
      planningSource: 'gemini',
    );
    final restored = NetworkIntent.fromJson(original.toJson());
    expect(restored.assumptions, original.assumptions);
    expect(restored.questions, original.questions);
    expect(restored.confidence, closeTo(0.82, 0.001));
    expect(restored.planningSource, 'gemini');
  });
}
