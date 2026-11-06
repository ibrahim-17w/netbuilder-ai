import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/network_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a balanced plan reports every switch within its ports', () {
    final plan = NetworkIntent.parseSimple(
      'office',
      '1 router, 2 switches and 12 PCs',
    );
    final rows = NetworkTools.portBudget(plan);
    expect(rows, isNotEmpty);
    for (final r in rows) {
      expect(r['known'], isTrue, reason: '${r['name']} model is known');
      expect(r['overCapacity'], isFalse, reason: '${r['name']} is balanced');
      expect(r['used'], lessThanOrEqualTo(r['total'] as int));
    }
    // Every cable the plan carries touches exactly one switch here (the
    // router side is not a budget row), so the used sum equals the links.
    final usedTotal = rows.fold<int>(0, (sum, r) => sum + r['used'] as int);
    expect(usedTotal, plan.links.length);
  });

  test('an overfilled switch is named and flagged', () {
    // 8 servers used to land on SW1; 23 endpoints on one switch is past the
    // 2960's 24 ports once the uplink is counted.
    final plan = NetworkIntent.parseSimple(
      'office',
      '1 router, 1 switch, 22 PCs and 3 servers',
    );
    final rows = NetworkTools.portBudget(plan);
    expect(rows.single['overCapacity'], isTrue);
    expect(rows.single['used'], greaterThan(rows.single['total'] as int));
  });

  test('a switch model the catalog does not know is marked unknown', () {
    final plan = NetworkIntent.parseSimple('office', '1 router and 1 switch');
    final exotic = plan.copyWith(
      nodes: [
        for (final n in plan.nodes)
          if (n.type == 'switch')
            NetNode(name: n.name, type: n.type, model: 'NOT-A-MODEL')
          else
            n,
      ],
    );
    final rows = NetworkTools.portBudget(exotic);
    expect(rows.single['known'], isFalse);
    expect(rows.single['total'], 0);
    // An unknown model never claims a violation it cannot compute.
    expect(rows.single['overCapacity'], isFalse);
  });
}
