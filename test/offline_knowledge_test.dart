import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/offline_knowledge.dart';

/// Direct unit tests for the offline knowledge table: every new corpus
/// entry must answer its trigger phrasings (including casual ones) with the
/// expected key strings, and the pre-existing entries plus the build-ask
/// guard must keep behaving.
///
/// These call [OfflineKnowledge.answerFor] directly - the service-level
/// battery lives in `test/offline_intelligence_test.dart`.
void main() {
  String? ask(String q) => OfflineKnowledge.answerFor(q);

  group('cdp and lldp neighbor discovery', () {
    test('trigger: show cdp neighbors', () {
      final a = ask('show cdp neighbors');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('show cdp neighbors'));
    });

    test('casual: how do I see my neighbors with cdp', () {
      final a = ask('how do I see my neighbors with cdp');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('lldp'));
    });
  });

  group('snmp', () {
    test('trigger: how do I configure snmp on a router', () {
      final a = ask('how do I configure snmp on a router');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('snmp-server community'));
    });

    test('casual: monitor a switch with snmp', () {
      final a = ask('monitor a switch with snmp');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('show snmp'));
    });
  });

  group('rstp', () {
    test('trigger: how do I enable rstp on a switch', () {
      final a = ask('how do I enable rstp on a switch');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('rapid-pvst'));
    });

    test('casual: what is rapid spanning tree', () {
      final a = ask('what is rapid spanning tree');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('portfast'));
    });
  });

  group('dhcpv6', () {
    test('trigger: how do I configure dhcpv6 on a router', () {
      final a = ask('how do I configure dhcpv6 on a router');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('ipv6 dhcp pool'));
    });

    test('casual: what is stateless dhcpv6', () {
      final a = ask('what is stateless dhcpv6');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('other-config-flag'));
    });
  });

  group('ppp', () {
    test('trigger: how do I configure ppp authentication with chap', () {
      final a = ask('how do I configure ppp authentication with chap');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('encapsulation ppp'));
    });

    test('casual: encapsulation ppp between two routers', () {
      final a = ask('encapsulation ppp between two routers');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('lcp open'));
    });
  });

  group('regression: existing entries still answer', () {
    test('ssh steps', () {
      final a = ask('how do I configure ssh on a switch');
      expect(a, isNotNull);
      expect(a!.toLowerCase(), contains('crypto key generate rsa'));
    });

    test('port security steps', () {
      final a = ask('how do I enable port security on a switch');
      expect(a, isNotNull);
      expect(a!.toLowerCase(), contains('port-security'));
    });

    test('static route syntax', () {
      final a = ask('static route syntax');
      expect(a, isNotNull);
      expect(a!.toLowerCase(), contains('ip route'));
    });

    test('wildcard mask computed', () {
      final a = ask('what is the wildcard mask for /27');
      expect(a, isNotNull);
      expect(a, contains('0.0.0.31'));
    });

    test('cannot ping checklist', () {
      final a = ask('cannot ping the gateway');
      expect(a, isNotNull);
      expect(a!.toLowerCase(), contains('show ip interface brief'));
    });
  });

  group('build asks stay with the planner', () {
    test('a build request returns null', () {
      expect(ask('build a 2 router lab'), isNull);
    });

    test('a greeting returns null', () {
      expect(ask('hello there'), isNull);
    });
  });

  group('canonical: full protocol names reach the table', () {
    test('hot standby router protocol -> hsrp entry', () {
      final a = ask('how does the hot standby router protocol work');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('standby 10 ip'));
    });

    test('virtual router redundancy protocol -> the same hsrp entry', () {
      final a = ask('what is the virtual router redundancy protocol');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('vrrp 10 ip'));
    });

    test('simple network management protocol -> snmp entry', () {
      final a = ask('how do I configure the simple network management protocol');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('snmp-server community'));
    });

    test('address resolution protocol -> arp entry', () {
      final a = ask('what is the address resolution protocol');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('who has 192.168.1.1'));
    });

    test('open shortest path first authentication -> ospf auth entry', () {
      final a = ask('how do I configure open shortest path first authentication');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('message-digest-key'));
    });

    test('dynamic host configuration protocol for ipv6 -> dhcpv6 entry', () {
      final a =
          ask('how do I set up dynamic host configuration protocol for ipv6');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('ipv6 dhcp pool'));
    });

    test('dynamic host configuration protocol relay -> dhcp relay entry', () {
      final a = ask('dynamic host configuration protocol relay across subnets');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('ip helper-address'));
    });

    test('virtual lan routing -> inter-vlan entry', () {
      final a = ask('how does virtual lan routing work');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('svi'));
    });

    test('reverse domain name system -> reverse dns entry', () {
      final a = ask('what is a reverse domain name system lookup');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('in-addr.arpa'));
    });

    test('file transfer protocol server -> server panels entry', () {
      final a = ask('what is a file transfer protocol server');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('services tab'));
    });

    test('trivial file transfer protocol server -> the same entry', () {
      final a = ask('what is a trivial file transfer protocol server');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('tftp'));
    });

    test('spanning tree protocol root -> stp root entry', () {
      final a = ask('spanning tree protocol root selection');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('root primary'));
    });

    test('choosing the border gateway protocol -> routing choice entry', () {
      final a = ask('when should I choose the border gateway protocol');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('autonomous systems'));
    });

    test('enhanced interior gateway routing protocol or ospf -> the trade-off',
        () {
      final a = ask('enhanced interior gateway routing protocol or ospf');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('unequal-cost'));
    });

    test('a bare bgp / dhcp explainer stays out of this table', () {
      // "how does the border gateway protocol work" canonicalizes to
      // "...bgp work", and no entry triggers on a bare 'bgp' or 'dhcp' -
      // those explainers belong to the concept layer above this table.
      // Asserting the truthful null pins that seam.
      expect(ask('how does the border gateway protocol work'), isNull);
      expect(ask('how does the dynamic host configuration protocol work'), isNull);
    });
  });

  group('canonical: casual fault phrasings reach real entries', () {
    test('broadcast storm -> rstp entry', () {
      final a = ask('there is a broadcast storm in my switch');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('rapid-pvst'));
    });

    test('the pc does not get an ip address -> ipconfig entry', () {
      final a = ask('the pc does not get an ip address');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('169.254'));
      expect(a.toLowerCase(), contains('dhcp never answered'));
    });

    test('my pc never gets an ip address -> the same entry', () {
      final a = ask('my pc never gets an ip address');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('dhcp never answered'));
    });

    test('cable shows red -> red link entry', () {
      final a = ask('the cable shows red between the two switches');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('crossover'));
    });

    test('no internet access -> connectivity ladder', () {
      final a = ask('no internet access from my pc');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('show ip interface brief'));
    });

    test('rogue dhcp server -> dhcp snooping entry', () {
      final a = ask('a rogue dhcp server is handing out addresses');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('ip dhcp snooping'));
    });

    test('mac flapping -> mac table entry', () {
      final a = ask('mac flapping between two ports');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('show mac'));
    });

    test('wifi spellings both reach the wireless answers', () {
      expect(
        ask('how do I connect to wifi')!.toLowerCase(),
        contains('pc wireless'),
      );
      expect(
        ask('how do I connect a laptop to wi-fi')!.toLowerCase(),
        contains('ssid'),
      );
      expect(
        ask('how do I secure wifi')!.toLowerCase(),
        contains('wpa2-personal'),
      );
    });
  });

  group('canonical keeps the planner boundary exact', () {
    test('dhcp for ipv6 is never rewritten and still reaches dhcpv6', () {
      final a = ask('how do I set up dhcp for ipv6');
      expect(a, isNotNull, reason: 'must answer offline');
      expect(a!.toLowerCase(), contains('ipv6 dhcp pool'));
    });

    test('a build ask in full-name clothing still goes to the planner', () {
      expect(
        ask('build a network with a dynamic host configuration protocol server'),
        isNull,
      );
    });
  });

  group('the breadth entries answer their own topics', () {
    test('router ntp client', () {
      final a = ask('how do I configure ntp on my router')!;
      expect(a, contains('ntp server'));
      expect(a, contains('show ntp status'));
    });

    test('ntp on the SERVER keeps hitting the services panel', () {
      final a = ask('enable ntp on the server')!;
      expect(a, contains('Services tab'));
    });

    test('syslog shipping', () {
      expect(
        ask('how do I send logs to a syslog collector')!,
        contains('logging host'),
      );
      expect(
        ask('configure logging on the switch')!,
        contains('show logging'),
      );
    });

    test('banner and local line passwords', () {
      final a = ask('how do I set a console password and a banner')!;
      expect(a, contains('line console 0'));
      expect(a, contains('service password-encryption'));
    });

    test('portfast and bpduguard survive the stp concept boundary', () {
      final a = ask('which ports need portfast with bpduguard')!;
      expect(a, contains('spanning-tree portfast'));
      expect(a, contains('P2p Edge'));
    });

    test('login block-for lockout', () {
      final a = ask('how do I lock out repeated failed logins')!;
      expect(a, contains('login block-for 120 attempts 3 within 60'));
    });

    test('protected port isolation', () {
      final a =
          ask('how do I isolate hosts on the same switch from each other')!;
      expect(a, contains('switchport protected'));
    });
  });
}
