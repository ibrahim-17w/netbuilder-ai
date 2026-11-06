import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/design_brief.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/design_brief_service.dart';
import 'package:net_builder/services/planner_memory_service.dart';

import 'fixtures.dart';

void main() {
  test('explicit routing beats a remembered protocol', () {
    const rememberedPreferences = {'routing': 'ospf'};
    final parsed = NetworkIntent.parseSimple(
      'office',
      '2 routers, 2 switches, 4 PCs, use EIGRP',
    );

    final result = PlannerMemoryService.apply(
      parsed,
      rules: const ['always use OSPF'],
      preferences: rememberedPreferences,
      instruction: '2 routers, 2 switches, 4 PCs, use EIGRP',
    );

    expect(result.routing, 'eigrp');
    final brief = DesignBriefService.briefForTurn(
      normalizedText: '2 routers, 2 switches, 4 PCs, use EIGRP',
      parsedPlan: result,
    ).brief;
    expect(brief.value(DesignBrief.routing), 'eigrp');
    final configs = CiscoAdapter.render(result);
    final routerConfigs = [
      for (final node in result.nodes)
        if (node.type == 'router') configs[node.name]!,
    ];
    expect(
      routerConfigs.every((config) => config.contains('router eigrp 10')),
      isTrue,
    );
    expect(
      routerConfigs.any((config) => config.contains('router ospf 1')),
      isFalse,
    );
    expect(rememberedPreferences['routing'], 'ospf');
  });

  test('an unrelated follow-up preserves the project explicit choice', () {
    const originalInstruction = '2 routers, 2 switches, 4 PCs, use EIGRP';
    const learned = {'routing': 'ospf'};
    final original = PlannerMemoryService.apply(
      NetworkIntent.parseSimple('P1', originalInstruction),
      preferences: learned,
      instruction: originalInstruction,
    );
    final followUpText = 'add a printer';
    final parsedFollowUp = PlannerMemoryService.apply(
      NetworkIntent.parseSimple('P1', followUpText),
      preferences: learned,
      instruction: followUpText,
    );
    final outcome = NetworkIntent.followUp(
      previous: original,
      previousBrief: originalInstruction,
      brief: followUpText,
      parsed: parsedFollowUp,
      project: 'P1',
    );

    expect(original.routing, 'eigrp');
    expect(outcome.plan.routing, 'eigrp');
    expect(outcome.plan.nodes.where((node) => node.type == 'pc').length, 4);
    expect(
      outcome.plan.nodes.where((node) => node.type == 'printer'),
      hasLength(1),
    );

    final otherProjectText = '2 routers, 2 switches, 4 PCs';
    final otherProject = PlannerMemoryService.apply(
      NetworkIntent.parseSimple('P2', otherProjectText),
      preferences: learned,
      instruction: otherProjectText,
    );
    expect(otherProject.routing, 'ospf');
  });

  test('a rejected routing protocol still blocks a learned replacement', () {
    expect(
      PlannerMemoryService.explicitFieldsIn('do not use OSPF'),
      contains('routing'),
    );
  });

  test('an unrelated learned value still fills an unspecified field', () {
    final parsed = NetworkIntent.parseSimple(
      'office',
      '2 routers, 2 switches, 4 PCs, use EIGRP',
    );

    final result = PlannerMemoryService.apply(
      parsed,
      preferences: const {'switch_model': '3560'},
      instruction: '2 routers, 2 switches, 4 PCs, use EIGRP',
    );

    expect(result.routing, 'eigrp');
    expect(
      result.nodes
          .where((node) => node.type == 'switch')
          .every((node) => node.model == '3560'),
      isTrue,
    );
  });

  test('explicit models and subnets are protected independently', () {
    final instruction =
        '2 routers with model 2911, 2 switches, LANs in 10.8.0.0/24';
    expect(
      PlannerMemoryService.explicitFieldsIn(instruction),
      contains('router_model'),
    );
    final parsed = NetworkIntent.parseSimple('office', instruction);
    final result = PlannerMemoryService.apply(
      parsed,
      preferences: const {
        'router_model': '4331',
        'base_subnet': '10.88.0.0/24',
      },
      instruction: instruction,
    );
    expect(
      result.nodes
          .where((node) => node.type == 'router')
          .every((node) => node.model == '2911'),
      isTrue,
      reason: result.nodes
          .where((node) => node.type == 'router')
          .map((node) => '${node.name}:${node.model}')
          .join(', '),
    );
    expect(result.addressing, parsed.addressing);
  });

  test(
    'scoped explicit model and subnet protect only their device and LAN',
    () {
      final base = basePlan(project: 'P1');
      final scoped = base.copyWith(
        nodes: [
          for (final node in base.nodes)
            if (node.name == 'R2')
              NetNode(
                name: node.name,
                type: node.type,
                model: node.model,
                exactModel: false,
                mgmtIp: node.mgmtIp,
                services: node.services,
                serviceRules: node.serviceRules,
              )
            else
              node,
        ],
        addressing: [
          for (final address in base.addressing)
            if (address.node == 'R1' && address.iface == 'g0/0')
              const InterfaceAddr(
                node: 'R1',
                iface: 'g0/0',
                ipCidr: '192.168.80.1/24',
              )
            else if (RegExp(r'^PC[1-5]$').hasMatch(address.node) ||
                address.node == 'SRV1')
              InterfaceAddr(
                node: address.node,
                iface: address.iface,
                ipCidr: '192.168.80.${address.ipCidr.split('.').last}',
              )
            else
              address,
        ],
      );
      const instruction = 'R1 model 2911, R1 LAN 192.168.80.0/24';

      final result = PlannerMemoryService.apply(
        scoped,
        preferences: const {
          'router_model': '4331',
          'base_subnet': '10.88.0.0/24',
        },
        instruction: instruction,
      );

      expect(
        result.nodes.firstWhere((node) => node.name == 'R1').model,
        '2911',
      );
      expect(
        result.nodes.firstWhere((node) => node.name == 'R1').exactModel,
        isTrue,
      );
      expect(
        result.nodes.firstWhere((node) => node.name == 'R2').model,
        '4331',
      );
      expect(
        result.addressing
            .firstWhere(
              (address) => address.node == 'R1' && address.iface == 'g0/0',
            )
            .ipCidr,
        '192.168.80.1/24',
      );
      expect(
        result.addressing
            .firstWhere(
              (address) => address.node == 'R2' && address.iface == 'g0/0',
            )
            .ipCidr,
        '10.88.20.1/24',
      );
    },
  );

  test('a learned preference still applies when the user left it open', () {
    final parsed = NetworkIntent.parseSimple(
      'office',
      '2 routers, 2 switches, 4 PCs',
    );

    final result = PlannerMemoryService.apply(
      parsed,
      rules: const ['always use OSPF'],
      instruction: '2 routers, 2 switches, 4 PCs',
    );

    expect(result.routing, 'ospf');
  });

  test('a DNS exclusion blocks a learned DNS addition', () {
    const instruction = '1 router, 1 switch, one server, do not add DNS';
    expect(
      PlannerMemoryService.explicitFieldsIn(instruction),
      contains('dns_excluded'),
    );
    final parsed = NetworkIntent.parseSimple('office', instruction);
    final result = PlannerMemoryService.apply(
      parsed,
      rules: const ['always add a DNS server'],
      instruction: instruction,
    );
    expect(
      result.nodes
          .where((node) => node.type == 'server')
          .every((node) => !node.services.contains('dns')),
      isTrue,
    );
  });

  test('a DNS exclusion applies even when no preference is stored', () {
    const instruction = '1 router, 1 switch, one server, do not add DNS';
    final parsed = NetworkIntent.parseSimple('office', instruction);
    final result = PlannerMemoryService.apply(parsed, instruction: instruction);

    expect(
      result.nodes
          .where((node) => node.type == 'server')
          .every((node) => !node.services.contains('dns')),
      isTrue,
    );
  });
}
