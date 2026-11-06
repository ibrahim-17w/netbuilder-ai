import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/models/plan_operation.dart';
import 'package:net_builder/services/request_understanding/request_coordinator.dart';

import 'fixtures.dart';

void main() {
  test('A15 the coordinator uses the stable total-reduction policy', () {
    const brief = '2 routers, 2 switches, 10 PCs, 2 servers';
    const request = 'make it 5 PCs';
    final base = NetworkIntent.parseSimple('P1', brief);
    final legacy = NetworkIntent.followUp(
      previous: base,
      previousBrief: brief,
      brief: request,
      parsed: NetworkIntent.parseSimple('chat', request),
      project: 'chat',
    );

    final outcome = RequestCoordinator.coordinate(
      text: request,
      turnId: 'turn-15',
      conversationId: 'P1',
      projectId: 'P1',
      target: 'gns3',
      base: base,
      legacyCandidate: legacy.plan,
      legacyBrief: request,
    );

    expect(
      outcome.isBlocked,
      isFalse,
      reason: outcome.interpretation.issues
          .map((issue) => '${issue.code}: ${issue.message}')
          .join('\n'),
    );
    expect(
      outcome.candidate!.nodes
          .where((node) => node.type == 'pc')
          .map((node) => node.name),
      ['PC1', 'PC2', 'PC3', 'PC4', 'PC5'],
    );
    expect(
      outcome.changeSet?.operations.single.kind,
      PlanOperationKind.setDeviceCount,
    );
    expect(base.nodes.where((node) => node.type == 'pc'), hasLength(10));
  });

  test('A36 Arabic site edit keeps HQ intact and edits only branch two', () {
    final original = basePlan();
    final base = original.copyWith(
      nodes: [
        for (final node in original.nodes)
          NetNode(
            name: node.name,
            type: node.type,
            model: node.model,
            exactModel: node.exactModel,
            modules: node.modules,
            mgmtIp: node.mgmtIp,
            siteId:
                node.name == 'R1' ||
                    node.name == 'SW1' ||
                    node.name == 'SRV1' ||
                    (node.name.startsWith('PC') &&
                        (int.tryParse(node.name.substring(2)) ?? 99) <= 5)
                ? 'hq'
                : 'branch#2',
            services: node.services,
            serviceRules: node.serviceRules,
          ),
      ],
    );
    const request = 'ضيف ٣ PCs عالفرع التاني وخلي HQ متل ما هو';

    final outcome = RequestCoordinator.coordinate(
      text: request,
      turnId: 'turn-36',
      conversationId: 'P1',
      projectId: 'P1',
      target: 'gns3',
      base: base,
      legacyCandidate: null,
      legacyBrief: request,
    );

    expect(
      outcome.isBlocked,
      isFalse,
      reason: outcome.interpretation.issues
          .map((issue) => '${issue.code}: ${issue.message}')
          .join('\n'),
    );
    final added = outcome.candidate!.nodes
        .where((node) => ['PC11', 'PC12', 'PC13'].contains(node.name))
        .toList();
    expect(added, hasLength(3));
    expect(added.every((node) => node.siteId == 'branch#2'), isTrue);
    expect(
      outcome.candidate!.nodes
          .where((node) => node.siteId == 'hq')
          .map((node) => node.toJson()),
      base.nodes
          .where((node) => node.siteId == 'hq')
          .map((node) => node.toJson()),
    );
    expect(
      outcome.candidate!.addressing.where(
        (row) => added.any((node) => node.name == row.node),
      ),
      hasLength(3),
    );
    expect(base.nodes, hasLength(original.nodes.length));
  });

  test(
    'A41 coordinator assigns services to the named and unique other server',
    () {
      final original = NetworkIntent.parseSimple(
        'P1',
        '2 routers, 2 switches, 10 PCs, 2 servers',
      );
      final base = original.copyWith(
        nodes: [
          for (final node in original.nodes)
            if (node.type == 'server')
              NetNode(
                name: node.name,
                type: node.type,
                model: node.model,
                exactModel: node.exactModel,
                modules: node.modules,
              )
            else
              node,
        ],
      );
      const request = 'make SRV1 DHCP and another server DNS';
      final parsed = NetworkIntent.parseSimple('P1', request);
      final legacy = NetworkIntent.followUp(
        previous: base,
        previousBrief: '2 routers, 2 switches, 10 PCs, 2 servers',
        brief: request,
        parsed: parsed,
        project: 'P1',
      );
      final outcome = RequestCoordinator.coordinate(
        text: request,
        turnId: 'turn-41',
        conversationId: 'P1',
        projectId: 'P1',
        target: 'gns3',
        base: base,
        legacyCandidate: legacy.plan,
        legacyBrief: request,
      );

      expect(
        outcome.isBlocked,
        isFalse,
        reason:
            '${outcome.interpretation.issues.map((issue) => '${issue.code}: ${issue.message}').join('\n')}\nlegacy: ${legacy.plan.toPlannerJson()}',
      );
      expect(outcome.disposition.name, 'commit');
      expect(
        outcome.candidate!.nodes
            .where((node) => node.type == 'server')
            .map((node) => node.name),
        ['SRV1', 'SRV2'],
      );
      expect(_node(outcome.candidate!, 'SRV1').services, ['dhcp']);
      expect(_node(outcome.candidate!, 'SRV2').services, ['dns']);
      expect(
        base.nodes
            .where((node) => node.type == 'server')
            .every((node) => node.services.isEmpty),
        isTrue,
      );
    },
  );

  test('A42 coordinator applies a grounded rename as one candidate', () {
    final base = basePlan();
    const request = 'rename R1 to Edge1';

    final outcome = RequestCoordinator.coordinate(
      text: request,
      turnId: 'turn-42',
      conversationId: 'P1',
      projectId: 'P1',
      target: 'gns3',
      base: base,
      legacyCandidate: null,
      legacyBrief: request,
    );

    expect(
      outcome.isBlocked,
      isFalse,
      reason: '${outcome.interpretation.issues}',
    );
    expect(outcome.disposition.name, 'commit');
    expect(
      outcome.changeSet!.operations.single.kind,
      PlanOperationKind.renameDevice,
    );
    expect(
      outcome.candidate!.nodes.any((node) => node.name == 'Edge1'),
      isTrue,
    );
    expect(
      outcome.candidate!.links.where(
        (link) => link.a == 'Edge1' || link.b == 'Edge1',
      ),
      hasLength(2),
    );
    expect(
      outcome.candidate!.addressing.where((row) => row.node == 'Edge1'),
      hasLength(2),
    );
  });

  test('A50 coordinator holds a printer addition when SRV9 is unresolved', () {
    final base = basePlan();
    const request = 'add a printer and change only SRV9 to DNS';

    final outcome = RequestCoordinator.coordinate(
      text: request,
      turnId: 'turn-50',
      conversationId: 'P1',
      projectId: 'P1',
      target: 'gns3',
      base: base,
      legacyCandidate: null,
      legacyBrief: request,
    );

    expect(outcome.isBlocked, isTrue);
    expect(outcome.candidate, isNull);
    expect(outcome.changeSet, isNull);
    expect(
      outcome.interpretation.operations.map((operation) => operation.kind),
      containsAll([
        PlanOperationKind.addDevices,
        PlanOperationKind.assignService,
      ]),
    );
    expect(base.nodes.any((node) => node.type == 'printer'), isFalse);
    expect(base.nodes.where((node) => node.type == 'server'), hasLength(2));
  });
}

NetNode _node(NetworkIntent plan, String name) =>
    plan.nodes.singleWhere((node) => node.name == name);
