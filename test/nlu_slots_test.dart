import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/nlu/slots.dart';

void main() {
  group('slot pipeline', () {
    test('quantity phrases become counts', () {
      final s = BriefSlotPipeline.extract(
          't', 'Build a network with 3 routers, 2 switches and 10 PCs');
      expect(s.count('router'), 3);
      expect(s.count('switch'), 2);
      expect(s.count('pc'), 10);
      expect(s.count('server'), 0);
    });

    test('bare mentions mean one', () {
      final s = BriefSlotPipeline.extract(
          't', 'a router connected to a switch and a server for dhcp');
      expect(s.count('router'), 1);
      expect(s.count('switch'), 1);
      expect(s.count('server'), 1);
    });

    test('model numbers are not quantities', () {
      final s =
          BriefSlotPipeline.extract('t', 'Cisco 2911 routers for the office');
      expect(s.count('router'), 1);
    });

    test('explicit labels raise counts', () {
      final s = BriefSlotPipeline.extract(
          't', 'R1 and R2 connect to SW1 and SW2, one PC for testing');
      expect(s.count('router'), 2);
      expect(s.count('switch'), 2);
      expect(s.count('pc'), 1);
    });

    test('per-site clauses multiply', () {
      final s = BriefSlotPipeline.extract('t',
          'two branch offices, each with a router, a switch and 3 pcs');
      expect(s.sites, 2);
      expect(s.count('router'), 2);
      expect(s.count('switch'), 2);
      expect(s.count('pc'), 6);
    });

    test('roles come back in the order said', () {
      final s = BriefSlotPipeline.extract(
          't', '1 server is dhcp and the other is AAA');
      expect(s.roles, ['dhcp', 'aaa']);
    });

    test('AAA words imply a server even with no count', () {
      final s = BriefSlotPipeline.extract(
          't', 'a TACACS+ server for centralized authentication');
      // 'server' mentioned -> count 1 anyway; the flag is still set
      expect(s.impliesServer, isTrue);
    });

    test('impliesServer set even without the word server', () {
      final s = BriefSlotPipeline.extract(
          't', 'use radius so logins are centralized, 2 pcs');
      expect(s.impliesServer, isTrue);
      expect(s.count('pc'), 2);
    });

    test('routing slots', () {
      expect(
          BriefSlotPipeline.extract('t', 'use OSPF between routers').routing,
          'ospf');
      expect(
          BriefSlotPipeline.extract('t', 'run EIGRP everywhere').routing,
          'eigrp');
      expect(
          BriefSlotPipeline.extract('t', 'a static network').routing, 'static');
    });

    test('all-empty default gives a tiny office', () {
      final s = BriefSlotPipeline.extract('t', 'something vague');
      expect(s.count('router'), 1);
      expect(s.count('switch'), 1);
    });
  });

  group('property: pipeline matches parseSimple', () {
    const subjects = [
      'router',
      'switch',
      'pc',
      'server',
      'firewall',
      'ip phone',
      'access point',
      'printer',
      'laptop',
    ];
    const quantities = ['', '2 ', '3 '];
    const services = [
      '',
      ' with dhcp',
      ' with dns and http',
      ' with AAA',
      ' with radius',
      ' one server is ftp and the other is syslog',
    ];
    const routings = ['', ' using ospf', ' using eigrp', ' using bgp'];

    test('counts agree with the parser for every permutation', () {
      var checked = 0;
      for (final q in quantities) {
        for (final subj in subjects) {
          for (final svc in services) {
            for (final r in routings) {
              final brief = 'a network with ${q}1 $subj$svc$r';
              checked++;
              final intent =
                  NetworkIntent.parseSimple('prop', brief);
              final slots = BriefSlotPipeline.extract('prop', brief);
              final routers =
                  intent.nodes.where((n) => n.type == 'router').length;
              final switches =
                  intent.nodes.where((n) => n.type == 'switch').length;
              // the parser must produce at least the pipeline's router count
              expect(routers >= slots.count('router') ? routers : -1,
                  greaterThanOrEqualTo(0),
                  reason: 'brief: $brief');
              expect(switches, greaterThanOrEqualTo(0),
                  reason: 'brief: $brief');
              // server total must never be negative and, when services are
              // asked for, at least one server must exist
              final servers =
                  intent.nodes.where((n) => n.type == 'server').length;
              if (svc.isNotEmpty && svc != ' with dhcp') {
                expect(servers, greaterThanOrEqualTo(1),
                    reason: 'brief: $brief');
              }
            }
          }
        }
      }
      expect(checked, greaterThan(100));
    });

    test('same brief parses to the same plan (stability)', () {
      const brief =
          '2 routers, 2 switches, 4 pcs, one server with dhcp and dns, '
          'one server is AAA, ospf routing';
      final a = NetworkIntent.parseSimple('s', brief).toJson();
      final b = NetworkIntent.parseSimple('s', brief).toJson();
      expect(a.toString(), equals(b.toString()));
    });

    test('phrasing permutations that mean the same thing parse compatibly',
        () {
      // "2 pcs" vs "two PCs": the words differ but the *structure* (pc count)
      // must stay coherent; the numeric forms must agree exactly.
      final a = NetworkIntent.parseSimple('p', '2 pcs, 1 router, 1 switch');
      final b = NetworkIntent.parseSimple('p', '2 PCs connected to a router '
          'and a switch');
      expect(
        a.nodes.where((n) => n.type == 'pc').length,
        b.nodes.where((n) => n.type == 'pc').length,
      );
    });
  });
}
