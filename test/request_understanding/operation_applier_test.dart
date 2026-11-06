import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/models/plan_operation.dart';
import 'package:net_builder/models/request_requirement.dart';
import 'package:net_builder/services/request_understanding/operation_applier.dart';

import 'fixtures.dart';

void main() {
  group('typed plan edits preserve unrelated state', () {
    test('build revision includes the chosen drawing and positions', () {
      final base = basePlan();
      final relaidOut = base.copyWith(notes: [...base.notes, 'layout: wide']);
      final repositioned = base.copyWith(layout: const {'R1': Offset(100, 80)});

      expect(relaidOut.revision, base.revision);
      expect(repositioned.revision, base.revision);
      expect(relaidOut.buildRevision, isNot(base.buildRevision));
      expect(repositioned.buildRevision, isNot(base.buildRevision));
    });

    test('A18 explicit repeated sites persist ownership on each device', () {
      final plan = NetworkIntent.parseSimple(
        'A18',
        '3 branches, each with 1 router, 1 switch, 10 PCs; one server at HQ',
      );
      final reopened = NetworkIntent.fromJson(plan.toJson());

      expect(
        reopened.nodes
            .where((node) => node.type == 'router')
            .map((node) => node.siteId),
        ['branch#1', 'branch#2', 'branch#3'],
      );
      expect(
        reopened.nodes
            .where((node) => node.type == 'switch')
            .map((node) => node.siteId),
        ['branch#1', 'branch#2', 'branch#3'],
      );
      expect(
        reopened.nodes
            .where((node) => node.type == 'pc')
            .map((node) => node.siteId),
        [
          ...List.filled(10, 'branch#1'),
          ...List.filled(10, 'branch#2'),
          ...List.filled(10, 'branch#3'),
        ],
      );
      expect(
        reopened.nodes.where((node) => node.type == 'server').single.siteId,
        'hq',
      );
    });

    test('A15 lowers the total with deterministic dependency cleanup', () {
      final base = basePlan();
      final operation = _operation(
        base,
        'set-five-pcs',
        PlanOperationKind.setDeviceCount,
        const {'kind': 'pc', 'total': 5},
      );

      final first = _apply(base, [operation]);
      final retry = _apply(base, [operation]);

      expect(first.canCommit, isTrue, reason: '${first.issues}');
      expect(_count(first.candidate!, 'pc'), 5);
      expect(
        first.candidate!.nodes
            .where((node) => node.type == 'pc')
            .map((node) => node.name),
        ['PC1', 'PC2', 'PC3', 'PC4', 'PC5'],
      );
      expect(
        first.candidate!.nodes
            .where((node) => node.type != 'pc')
            .map((node) => node.toJson()),
        base.nodes
            .where((node) => node.type != 'pc')
            .map((node) => node.toJson()),
      );
      expect(first.candidate!.addressing, hasLength(11));
      expect(
        first.candidate!.addressing.any((row) => row.node == 'PC10'),
        isFalse,
      );
      expect(
        first.candidate!.links.any(
          (link) => link.a == 'PC10' || link.b == 'PC10',
        ),
        isFalse,
      );
      expect(first.changeSet!.incidentalChanges, isNotEmpty);
      expect(
        semanticSnapshot(retry.candidate!),
        semanticSnapshot(first.candidate!),
      );
      expect(base.nodes.where((node) => node.type == 'pc'), hasLength(10));
    });

    test('A15 preserves a specifically protected PC while reducing totals', () {
      final base = basePlan();
      final preserve = _operation(
        base,
        'protect-pc10',
        PlanOperationKind.preserve,
        const {
          'properties': ['device'],
        },
        scope: const RequirementScope(
          kind: RequirementScopeKind.device,
          scopeId: 'PC10',
        ),
      );
      final lower = _operation(
        base,
        'set-five-pcs',
        PlanOperationKind.setDeviceCount,
        const {'kind': 'pc', 'total': 5},
      );

      final result = _apply(base, [lower, preserve]);

      expect(
        result.canCommit,
        isTrue,
        reason: result.issues
            .map((issue) => '${issue.code}: ${issue.message}')
            .join('\n'),
      );
      expect(
        result.candidate!.nodes
            .where((node) => node.type == 'pc')
            .map((node) => node.name),
        ['PC1', 'PC2', 'PC3', 'PC4', 'PC10'],
      );
    });

    test('A15 refuses a reduction larger than the unprotected inventory', () {
      final base = basePlan();
      final preserve = _operation(
        base,
        'protect-all-pcs',
        PlanOperationKind.preserve,
        const {
          'properties': ['inventory'],
        },
      );
      final lower = _operation(
        base,
        'set-five-pcs',
        PlanOperationKind.setDeviceCount,
        const {'kind': 'pc', 'total': 5},
      );

      final result = _apply(base, [lower, preserve]);

      expect(result.canCommit, isFalse);
      expect(result.candidate, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        contains('count_reduction_conflicts_with_locked_devices'),
      );
      expect(_count(base, 'pc'), 10);
    });

    test('A36 adds PCs only to the explicitly selected second branch', () {
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
      final operation = _operation(
        base,
        'add-branch-pcs',
        PlanOperationKind.addDevices,
        const {'kind': 'pc', 'count': 3},
        scope: const RequirementScope(
          kind: RequirementScopeKind.site,
          scopeId: 'second branch',
        ),
      );

      final result = _apply(base, [operation]);

      expect(
        result.canCommit,
        isTrue,
        reason: result.issues
            .map((issue) => '${issue.code}: ${issue.message}')
            .join('\n'),
      );
      final added = result.candidate!.nodes
          .where(
            (node) =>
                node.name == 'PC11' ||
                node.name == 'PC12' ||
                node.name == 'PC13',
          )
          .toList();
      expect(added, hasLength(3));
      expect(added.every((node) => node.siteId == 'branch#2'), isTrue);
      expect(
        result.candidate!.links.where(
          (link) =>
              (link.a == 'SW2' && added.any((node) => node.name == link.b)) ||
              (link.b == 'SW2' && added.any((node) => node.name == link.a)),
        ),
        hasLength(3),
      );
      expect(
        result.candidate!.addressing.where(
          (row) => added.any((node) => node.name == row.node),
        ),
        hasLength(3),
      );
      expect(
        result.candidate!.nodes
            .where((node) => node.siteId == 'hq' && node.type == 'pc')
            .map((node) => node.name),
        base.nodes
            .where((node) => node.siteId == 'hq' && node.type == 'pc')
            .map((node) => node.name),
      );
      expect(
        result.changeSet!.incidentalChanges,
        contains(
          'Connected PC11 to SW2 at branch#2 and assigned 192.168.20.10/24.',
        ),
      );
      expect(base.nodes, hasLength(original.nodes.length));
      expect(base.links, hasLength(original.links.length));
    });

    test('A36 a generic branch name is held when two branches match', () {
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
                  ? 'branch#1'
                  : 'branch#2',
              services: node.services,
              serviceRules: node.serviceRules,
            ),
        ],
      );
      final operation = _operation(
        base,
        'add-ambiguous-branch-pc',
        PlanOperationKind.addDevices,
        const {'kind': 'pc', 'count': 1},
        scope: const RequirementScope(
          kind: RequirementScopeKind.site,
          scopeId: 'branch',
        ),
      );

      final result = _apply(base, [operation]);

      expect(result.canCommit, isFalse);
      expect(result.candidate, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        contains('site_scope_ambiguous'),
      );
      expect(semanticSnapshot(result.heldCandidate), semanticSnapshot(base));
    });

    test('A19 removing one named PC cleans only its dependent rows', () {
      final base = basePlan();
      final beforeOtherAddresses = base.addressing
          .where((row) => row.node != 'PC10')
          .map((row) => row.toJson())
          .toList();
      final beforeOtherLinks = base.links
          .where((link) => link.a != 'PC10' && link.b != 'PC10')
          .map((link) => link.toJson())
          .toList();
      final operation = _operation(
        base,
        'remove-pc10',
        PlanOperationKind.removeDevices,
        const {
          'deviceIds': ['PC10'],
        },
      );

      final result = _apply(base, [operation]);

      expect(result.canCommit, isTrue, reason: '${result.issues}');
      expect(
        result.candidate!.nodes.any((node) => node.name == 'PC10'),
        isFalse,
      );
      expect(
        result.candidate!.nodes.map((node) => node.name),
        base.nodes
            .where((node) => node.name != 'PC10')
            .map((node) => node.name),
      );
      expect(
        result.candidate!.addressing.map((row) => row.toJson()).toList(),
        beforeOtherAddresses,
      );
      expect(
        result.candidate!.links.map((link) => link.toJson()).toList(),
        beforeOtherLinks,
      );
      expect(base.nodes.any((node) => node.name == 'PC10'), isTrue);
    });

    test('A20 changes routing without altering inventory or wiring', () {
      final base = basePlan();
      final operation = _operation(
        base,
        'use-eigrp',
        PlanOperationKind.setRouting,
        const {'protocol': 'eigrp'},
      );

      final result = _apply(base, [operation]);

      expect(result.canCommit, isTrue, reason: '${result.issues}');
      expect(result.candidate!.routing, 'eigrp');
      expect(
        result.candidate!.nodes.map((node) => node.toJson()),
        base.nodes.map((node) => node.toJson()),
      );
      expect(
        result.candidate!.links.map((link) => link.toJson()),
        base.links.map((link) => link.toJson()),
      );
      expect(
        result.candidate!.addressing.map((row) => row.toJson()),
        base.addressing.map((row) => row.toJson()),
      );
    });

    test('A21 and A41 assign services only to named existing servers', () {
      final original = basePlan();
      final base = original.copyWith(
        nodes: [
          for (final node in original.nodes)
            if (node.name == 'SRV1' || node.name == 'SRV2')
              NetNode(name: node.name, type: node.type)
            else
              node,
        ],
      );
      final operations = [
        _operation(
          base,
          'srv1-dhcp',
          PlanOperationKind.assignService,
          const {'deviceId': 'SRV1', 'service': 'dhcp'},
          scope: const RequirementScope(
            kind: RequirementScopeKind.service,
            scopeId: 'dhcp',
          ),
        ),
        _operation(
          base,
          'srv2-dns',
          PlanOperationKind.assignService,
          const {'deviceId': 'SRV2', 'service': 'dns'},
          scope: const RequirementScope(
            kind: RequirementScopeKind.service,
            scopeId: 'dns',
          ),
        ),
      ];

      final result = _apply(base, operations);

      expect(result.canCommit, isTrue, reason: '${result.issues}');
      expect(_count(result.candidate!, 'server'), 2);
      expect(_node(result.candidate!, 'SRV1').services, ['dhcp']);
      expect(_node(result.candidate!, 'SRV2').services, ['dns']);
      expect(
        result.candidate!.nodes.map((node) => node.name),
        base.nodes.map((node) => node.name),
      );
    });

    test('A42 rename updates references while preserving device data', () {
      final base = basePlan();
      final originalRouter = _node(base, 'R1');
      final operation = _operation(
        base,
        'rename-r1',
        PlanOperationKind.renameDevice,
        const {'deviceId': 'R1', 'newName': 'Edge1'},
      );

      final result = _apply(base, [operation]);

      expect(result.canCommit, isTrue, reason: '${result.issues}');
      expect(result.candidate!.nodes.any((node) => node.name == 'R1'), isFalse);
      expect(
        _node(result.candidate!, 'Edge1').toJson(),
        NetNode(
          name: 'Edge1',
          type: originalRouter.type,
          model: originalRouter.model,
          exactModel: originalRouter.exactModel,
          modules: originalRouter.modules,
          mgmtIp: originalRouter.mgmtIp,
          services: originalRouter.services,
          serviceRules: originalRouter.serviceRules,
        ).toJson(),
      );
      expect(
        result.candidate!.links.any((link) => link.a == 'R1' || link.b == 'R1'),
        isFalse,
      );
      expect(
        result.candidate!.links.any(
          (link) => link.a == 'Edge1' || link.b == 'Edge1',
        ),
        isTrue,
      );
      expect(
        result.candidate!.addressing.where((row) => row.node == 'Edge1'),
        hasLength(2),
      );
      expect(
        result.candidate!.addressing.any((row) => row.node == 'R1'),
        isFalse,
      );
      expect(base.nodes.any((node) => node.name == 'R1'), isTrue);
    });

    test('A50 an unresolved service holds the earlier addition atomically', () {
      final base = basePlan();
      final addPrinter = _operation(
        base,
        'add-printer',
        PlanOperationKind.addDevices,
        const {'kind': 'printer', 'count': 1},
      );
      final missingServer = _operation(
        base,
        'configure-srv9',
        PlanOperationKind.assignService,
        const {'deviceId': 'SRV9', 'service': 'dns'},
        scope: const RequirementScope(
          kind: RequirementScopeKind.service,
          scopeId: 'dns',
        ),
      );

      final result = _apply(base, [addPrinter, missingServer]);

      expect(result.canCommit, isFalse);
      expect(result.candidate, isNull);
      expect(
        result.heldCandidate.nodes.any((node) => node.type == 'printer'),
        isTrue,
      );
      expect(
        result.issues.map((issue) => issue.code),
        contains('device_not_found'),
      );
      expect(base.nodes.any((node) => node.type == 'printer'), isFalse);
      expect(_count(base, 'server'), 2);
    });
  });
}

PlanOperation _operation(
  NetworkIntent base,
  String id,
  PlanOperationKind kind,
  Map<String, Object?> payload, {
  RequirementScope? scope,
}) => PlanOperation(
  operationId: id,
  kind: kind,
  requirementIds: ['req-$id'],
  projectId: base.projectName,
  baseRevision: base.revision,
  scope: scope ?? RequirementScope.project(base.projectName),
  payload: payload,
);

OperationApplicationResult _apply(
  NetworkIntent base,
  List<PlanOperation> operations,
) => OperationApplier.apply(
  base: base,
  projectId: base.projectName,
  baseRevision: base.revision,
  operations: operations,
  target: 'gns3',
);

int _count(NetworkIntent plan, String type) =>
    plan.nodes.where((node) => node.type.toLowerCase() == type).length;

NetNode _node(NetworkIntent plan, String name) =>
    plan.nodes.singleWhere((node) => node.name == name);
