import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/lab_catalog.dart';

/// A guided lab grade is the app's own evidence: every check reads fields
/// the planner actually writes, so a pass is earned, never guessed.
void main() {
  test('the catalog has three labs with unique ids', () {
    expect(LabCatalog.all.length, 3);
    expect(
      LabCatalog.all.map((l) => l.id).toSet().length,
      LabCatalog.all.length,
    );
  });

  group('the VLAN+DHCP lab grades a real plan', () {
    final lab = LabCatalog.byId('vlan-dhcp')!;

    test('a complete plan passes every step', () {
      final plan = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs in vlan 10 and vlan 20 with a dhcp server',
      );
      final progress = LabGrader.grade(lab, plan);
      final failed = progress.results
          .where((r) => !r.ok)
          .map((r) => '${r.step.title}: ${r.remedy}')
          .join('\n');
      expect(progress.complete, isTrue, reason: failed);
    });

    test('a plan without DHCP names the remedy', () {
      final plan = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs in vlan 10 and vlan 20',
      );
      final progress = LabGrader.grade(lab, plan);
      expect(progress.complete, isFalse);
      final dhcp = progress.results.firstWhere(
        (r) => r.step.title == 'DHCP server',
      );
      expect(dhcp.ok, isFalse);
      expect(dhcp.remedy, contains('dhcp server'));
      expect(progress.nextStep, isNotNull);
    });

    test('a plan missing a VLAN fails only its own step', () {
      final plan = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs in vlan 10 with a dhcp server',
      );
      final progress = LabGrader.grade(lab, plan);
      final vlan20 = progress.results.firstWhere(
        (r) => r.step.title == 'Second VLAN',
      );
      expect(vlan20.ok, isFalse);
      expect(vlan20.remedy, contains('VLAN 20'));
    });
  });

  group('the OSPF lab grades the WAN shape', () {
    final lab = LabCatalog.byId('ospf-wan')!;

    test('two routers with a link and OSPF pass', () {
      final plan = NetworkIntent.parseSimple(
        'p',
        '2 routers 2 switches 2 pcs connected with ospf',
      );
      final progress = LabGrader.grade(lab, plan);
      final failed = progress.results
          .where((r) => !r.ok)
          .map((r) => '${r.step.title}: ${r.remedy}')
          .join('\n');
      expect(progress.complete, isTrue, reason: failed);
    });

    test('static routing fails the OSPF step with the fix phrase', () {
      final plan = NetworkIntent.parseSimple('p', '2 routers 2 switches 2 pcs');
      final progress = LabGrader.grade(lab, plan);
      final ospf = progress.results.firstWhere(
        (r) => r.step.check is RoutingIs,
      );
      expect(ospf.ok, isFalse);
      expect(ospf.remedy, contains('use ospf'));
    });

    test('a missing router-router link fails the transit step', () {
      final plan = NetworkIntent.parseSimple(
        'p',
        '2 routers 1 switch 2 pcs with ospf',
      );
      // The parser may or may not wire the routers together for this brief;
      // force the case by dropping any router-router link.
      final noTransit = NetworkIntent(
        projectName: plan.projectName,
        nodes: plan.nodes,
        links: plan.links
            .where((l) => !(l.a.startsWith('R') && l.b.startsWith('R')))
            .toList(),
        vlans: plan.vlans,
        routing: plan.routing,
      );
      final progress = LabGrader.grade(lab, noTransit);
      final transit = progress.results.firstWhere(
        (r) => r.step.check is LinkBetween,
      );
      expect(transit.ok, isFalse);
      expect(transit.remedy, contains('router'));
    });
  });

  group('the secure-management lab grades security intent', () {
    final lab = LabCatalog.byId('secure-mgmt')!;

    test('AAA server plus port security pass', () {
      final plan = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs with a aaa server and port security',
      );
      final progress = LabGrader.grade(lab, plan);
      final failed = progress.results
          .where((r) => !r.ok)
          .map((r) => '${r.step.title}: ${r.remedy}')
          .join('\n');
      expect(progress.complete, isTrue, reason: failed);
    });

    test('a plan without the security request names the phrase', () {
      final plan = NetworkIntent.parseSimple(
        'p',
        '1 router 1 switch 2 pcs with a aaa server',
      );
      final progress = LabGrader.grade(lab, plan);
      final portSec = progress.results.firstWhere(
        (r) =>
            r.step.check is SecurityRequested &&
            r.step.title == 'Port security',
      );
      expect(portSec.ok, isFalse);
      expect(portSec.remedy, contains('port security'));
    });
  });

  test('the markdown shows a checked list and the next step', () {
    final lab = LabCatalog.byId('ospf-wan')!;
    final plan = NetworkIntent.parseSimple('p', '2 routers 2 switches 2 pcs');
    final md = LabGrader.grade(lab, plan).toMarkdown();
    expect(md, contains('[x]'));
    expect(md, contains('[ ]'));
    expect(md, contains('Next:'));
  });

  group('LabRequest.read', () {
    test('list, start, check and stop are recognized', () {
      expect(LabRequest.read('/lab')!.action, LabAction.list);
      expect(LabRequest.read('labs')!.action, LabAction.list);
      final start = LabRequest.read('start the ospf lab')!;
      expect(start.action, LabAction.start);
      expect(start.lab!.id, 'ospf-wan');
      expect(LabRequest.read('check my lab')!.action, LabAction.check);
      expect(LabRequest.read('stop the lab')!.action, LabAction.stop);
    });

    test('lab names resolve by topic word', () {
      expect(LabRequest.read('start the vlan lab')!.lab!.id, 'vlan-dhcp');
      expect(
        LabRequest.read('begin the secure management lab')!.lab!.id,
        'secure-mgmt',
      );
    });

    test('start with no name returns start with a null lab', () {
      final r = LabRequest.read('start the lab')!;
      expect(r.action, LabAction.start);
      expect(r.lab, isNull);
    });

    test('ordinary messages are not lab requests', () {
      const no = [
        'build the .pkt',
        'add a vlan 30 lab switch',
        'how do VLANs work?',
        'stop',
        'check the router',
      ];
      for (final text in no) {
        expect(LabRequest.read(text), isNull, reason: text);
      }
    });
  });
}
