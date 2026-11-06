import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';

import 'fixtures.dart';

void main() {
  test('an explanation turn leaves the complete plan snapshot unchanged', () {
    final original = basePlan();
    final outcome = NetworkIntent.followUp(
      previous: original,
      previousBrief:
          '2 routers, 2 switches, 10 PCs, 2 servers; use static routing',
      brief: 'why is OSPF better than static routing?',
      parsed: NetworkIntent.parseSimple(
        'P1',
        'why is OSPF better than static routing?',
      ),
      project: 'P1',
    );

    expect(semanticSnapshot(outcome.plan), semanticSnapshot(original));
    expect(outcome.brief, contains('10 PCs'));
  });
}
