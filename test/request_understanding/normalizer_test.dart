import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/plan_operation.dart';
import 'package:net_builder/models/request_interpretation.dart';
import 'package:net_builder/models/request_requirement.dart';
import 'package:net_builder/services/request_understanding/normalizer.dart';

import 'fixtures.dart';

void main() {
  RequestInterpretation adapt(String text) =>
      RequestInterpretationAdapter.adapt(
        originalText: text,
        projectName: 'P1',
        turnId: 'turn-1',
        conversationId: 'P1',
        projectId: 'P1',
        basePlanRevision: basePlan().revision,
        messageId: 'message-1',
      );

  Requirement onlyRequirement(
    RequestInterpretation result, {
    required String subject,
    required String property,
  }) => result.requirements.singleWhere(
    (requirement) =>
        requirement.subject == subject && requirement.property == property,
  );

  test('A14 addition is an increment with original-source evidence', () {
    const text = 'Please add five PCs';
    final result = adapt(text);
    final quantity = onlyRequirement(
      result,
      subject: 'pc',
      property: 'device_count',
    );

    expect(quantity.value, 5);
    expect(quantity.quantityRole, QuantityRole.increment);
    expect(quantity.sourceSpans, hasLength(1));
    quantity.sourceSpans.single.validateAgainst(text);
    expect(
      text.substring(
        quantity.sourceSpans.single.start,
        quantity.sourceSpans.single.end,
      ),
      contains('five PCs'),
    );
    expect(result.operations, hasLength(1));
    expect(result.operations.single.kind, PlanOperationKind.addDevices);
    expect(result.operations.single.payload['count'], 5);
  });

  test('A15 set-total wording stays distinct from an addition', () {
    final result = adapt('make it five PCs');
    final quantity = onlyRequirement(
      result,
      subject: 'pc',
      property: 'device_count',
    );

    expect(quantity.value, 5);
    expect(quantity.quantityRole, QuantityRole.total);
    expect(result.operations.single.kind, PlanOperationKind.setDeviceCount);
    expect(result.operations.single.payload['total'], 5);
  });

  test('A16 lower bounds never become a destructive total operation', () {
    final result = adapt('at least 10 PCs');
    final quantity = onlyRequirement(
      result,
      subject: 'pc',
      property: 'device_count',
    );

    expect(quantity.comparator, RequirementComparator.atLeast);
    expect(quantity.quantityRole, QuantityRole.minimum);
    expect(result.operations, isEmpty);
  });

  test('A19 removal names exactly the requested device', () {
    const text = 'remove PC10 only';
    final result = adapt(text);
    final removal = result.operations.single;

    expect(removal.kind, PlanOperationKind.removeDevices);
    expect(removal.payload['deviceIds'], ['PC10']);
    expect(removal.sourceSpans, isNotEmpty);
    removal.sourceSpans.first.validateAgainst(text);
    expect(
      text.substring(
        removal.sourceSpans.first.start,
        removal.sourceSpans.first.end,
      ),
      contains('PC10'),
    );
  });

  test('A54 Arabic removal keeps the named device and original excerpt', () {
    const text = 'شيل PC10 بس، ولا تغيّر عناوين الباقي';
    final result = adapt(text);
    final removal = result.operations.single;

    expect(removal.kind, PlanOperationKind.removeDevices);
    expect(removal.payload['deviceIds'], ['PC10']);
    final evidence = removal.sourceSpans.first;
    evidence.validateAgainst(text);
    expect(text.substring(evidence.start, evidence.end), contains('PC10'));
  });

  test('A18 per-site quantities retain separate scopes', () {
    final result = adapt(
      '3 branches, each with 1 router, 1 switch, 10 PCs; one server at HQ',
    );
    for (final kind in ['router', 'switch', 'pc']) {
      final sites = result.requirements
          .where(
            (requirement) =>
                requirement.property == 'device_count' &&
                requirement.subject == kind,
          )
          .map((requirement) => requirement.scope.scopeId)
          .toSet();
      expect(sites, {'branch#1', 'branch#2', 'branch#3'}, reason: kind);
    }
    expect(
      result.requirements.any(
        (requirement) =>
            requirement.subject == 'server' &&
            requirement.scope.scopeId == 'hq',
      ),
      isTrue,
      reason: result.requirements
          .map((item) => item.toJson())
          .toList()
          .toString(),
    );
  });

  test('A20 negated routing is forbidden while the correction is selected', () {
    final result = adapt('do not use OSPF; use EIGRP instead');
    final routing = result.requirements
        .where((requirement) => requirement.property == 'routing_protocol')
        .toList();

    expect(
      routing.map((requirement) => (requirement.value, requirement.comparator)),
      containsAll([
        ('ospf', RequirementComparator.forbidden),
        ('eigrp', RequirementComparator.equals),
      ]),
    );
    expect(result.operations, hasLength(1));
    expect(result.operations.single.payload['protocol'], 'eigrp');
  });

  test(
    'A21 a named DHCP assignment does not turn excluded DNS into an edit',
    () {
      const text = 'do not add a DNS server; put DHCP on SRV1 only';
      final result = adapt(text);
      final assignments = result.operations
          .where(
            (operation) => operation.kind == PlanOperationKind.assignService,
          )
          .toList();

      expect(assignments, hasLength(1));
      expect(assignments.single.payload['deviceId'], 'SRV1');
      expect(assignments.single.payload['service'], 'dhcp');
      expect(
        result.requirements.any(
          (requirement) =>
              requirement.property == 'excluded_service' &&
              requirement.value == 'dns' &&
              requirement.comparator == RequirementComparator.forbidden,
        ),
        isTrue,
      );
    },
  );

  test('A41 another server resolves as a separate explicit service target', () {
    final result = adapt('make SRV1 DHCP and another server DNS');
    final assignments = result.operations
        .where((operation) => operation.kind == PlanOperationKind.assignService)
        .toList();

    expect(assignments, hasLength(2), reason: '${result.operations}');
    expect(
      assignments.map(
        (operation) =>
            (operation.payload['deviceId'], operation.payload['service']),
      ),
      containsAll([('SRV1', 'dhcp'), ('another server', 'dns')]),
    );
    for (final operation in assignments) {
      operation.sourceSpans.single.validateAgainst(
        'make SRV1 DHCP and another server DNS',
      );
    }
  });

  test('A42 rename creates a single exact reference update', () {
    const text = 'rename R1 to Edge1';
    final result = adapt(text);
    final rename = result.operations.single;

    expect(rename.kind, PlanOperationKind.renameDevice);
    expect(rename.payload, {'deviceId': 'R1', 'newName': 'Edge1'});
    expect(
      result.requirements.where(
        (requirement) =>
            requirement.property == 'device_name' &&
            requirement.scope.scopeId == 'R1',
      ),
      hasLength(1),
      reason: 'the old name is a target, not a conflicting desired name',
    );
  });

  test('A50 retains both edits even when a named server target is missing', () {
    final result = adapt('add a printer and change only SRV9 to DNS');
    expect(
      result.operations.map((operation) => operation.kind),
      containsAll([
        PlanOperationKind.addDevices,
        PlanOperationKind.assignService,
      ]),
      reason: '${result.operations}',
    );
    final service = result.operations.singleWhere(
      (operation) => operation.kind == PlanOperationKind.assignService,
    );
    expect(service.payload['deviceId'], 'SRV9');
    expect(service.payload['service'], 'dns');
  });

  test(
    'A22 named inventory and exact technical tokens retain source spans',
    () {
      const text = '''
R1 (2911) connects g0/0 to SW1 (2960) f0/1.
R10 connects g0/1 to SW2 f0/2; keep 192.168.10.0/24.
''';
      final result = adapt(text);
      final names = result.requirements
          .where((requirement) => requirement.property == 'device_name')
          .map((requirement) => requirement.value)
          .toSet();

      expect(names, containsAll(['R1', 'R10', 'SW1', 'SW2']));
      for (final requirement in result.requirements) {
        for (final source in requirement.sourceSpans) {
          source.validateAgainst(text);
        }
      }
      final normalized = RequestNormalizer.normalize(text).normalizedText;
      expect(normalized, contains('g0/0'));
      expect(normalized, contains('f0/1'));
      expect(normalized, contains('192.168.10.0/24'));
    },
  );

  test('A23 an OSPF token inside a quoted SSID is not routing intent', () {
    const text = 'Create an AP with SSID "Office OSPF"; no dynamic routing';
    final normalized = RequestNormalizer.normalize(text);
    final ospfToken = normalized.normalizedText.indexOf('OSPF');
    expect(ospfToken, greaterThanOrEqualTo(0));
    expect(
      normalized.overlapsOpaqueSource(
        start: ospfToken,
        end: ospfToken + 'OSPF'.length,
      ),
      isTrue,
    );
    final result = adapt(text);
    expect(
      result.requirements.where(
        (requirement) => requirement.property == 'routing_protocol',
      ),
      isEmpty,
      reason: result.requirements
          .map((item) => item.toJson())
          .toList()
          .toString(),
    );
  });

  test('A35 Arabic digits and service negation remain explicit', () {
    final result = adapt('بدّي شبكة فيها ٢ راوتر و٢ سويتش و١٠ أجهزة، بدون DNS');

    expect(
      result.requirements.any(
        (requirement) =>
            requirement.subject == 'router' && requirement.value == 2,
      ),
      isTrue,
      reason: result.requirements
          .map((item) => item.toJson())
          .toList()
          .toString(),
    );
    expect(
      result.requirements.any(
        (requirement) =>
            requirement.subject == 'switch' && requirement.value == 2,
      ),
      isTrue,
    );
    expect(
      result.requirements.any(
        (requirement) =>
            requirement.property == 'excluded_service' &&
            requirement.value == 'dns' &&
            requirement.comparator == RequirementComparator.forbidden,
      ),
      isTrue,
    );
  });

  test('A36 an Arabic branch addition keeps its branch scope', () {
    const text = 'ضيف ٣ PCs عالفرع التاني وخلي HQ متل ما هو';
    final result = adapt(text);
    expect(
      result.requirements.any(
        (requirement) =>
            requirement.subject == 'pc' &&
            requirement.value == 3 &&
            requirement.quantityRole == QuantityRole.increment &&
            requirement.scope.kind == RequirementScopeKind.site,
      ),
      isTrue,
      reason: result.requirements
          .map((item) => item.toJson())
          .toList()
          .toString(),
    );
    final add = result.operations.singleWhere(
      (operation) => operation.kind == PlanOperationKind.addDevices,
    );
    expect(add.scope.scopeId, 'second branch');
    final preserve = result.operations.singleWhere(
      (operation) => operation.kind == PlanOperationKind.preserve,
    );
    expect(preserve.scope.kind, RequirementScopeKind.site);
    expect(preserve.scope.scopeId, 'hq');
    expect(preserve.sourceSpans.single.excerpt, contains('خلي HQ متل ما هو'));
  });

  test('A40 contradictory routing choices remain separately represented', () {
    final result = adapt('use OSPF and EIGRP as the only routing protocol');
    final routing = result.requirements
        .where((requirement) => requirement.property == 'routing_protocol')
        .map((requirement) => requirement.value)
        .toSet();

    expect(routing, containsAll(['ospf', 'eigrp']));
    expect(
      result.operations.map((operation) => operation.payload['protocol']),
      containsAll(['ospf', 'eigrp']),
    );
  });
}
