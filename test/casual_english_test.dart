import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/casual_english.dart';

void main() {
  group('casual English normalizer', () {
    test('expands shorthand without losing the numbers', () {
      expect(
        CasualEnglish.normalize('u wanna 2 routers'),
        contains('you want to 2 routers'),
      );
      expect(CasualEnglish.normalize('i dont know what to do'),
          contains('i do not know'));
    });

    test('fixes common device typos', () {
      final n = CasualEnglish.normalize('swtich and 2 routrs');
      expect(n, contains('switch'));
      expect(n, contains('routers'));
    });

    test('never damages data tokens', () {
      expect(CasualEnglish.normalize('lan 192.168.1.0/24'),
          contains('192.168.1.0/24'));
      expect(CasualEnglish.normalize('2 routers'), contains('2 routers'));
      expect(CasualEnglish.normalize('password LabAdmin2026'),
          contains('LabAdmin2026'));
      // A mixed-case word with no digits is treated as deliberate (a secret).
      expect(CasualEnglish.normalize('key SecretPass'), contains('SecretPass'));
    });

    test('drops filler with no plan meaning', () {
      expect(CasualEnglish.normalize('make it normal'), isEmpty);
      final n = CasualEnglish.normalize('2 routers and other stuff');
      expect(n, contains('2 routers'));
      expect(n, isNot(contains('other stuff')));
    });
  });

  group('canonical: full names and fault phrases to table tokens', () {
    // Every short form here appears in an actual trigger list of
    // offline_knowledge.dart - that is the admission rule for the map.
    const names = {
      'rapid spanning tree protocol': 'rstp',
      'spanning tree protocol': 'stp',
      'border gateway protocol': 'bgp',
      'open shortest path first': 'ospf',
      'enhanced interior gateway routing protocol': 'eigrp',
      'dynamic host configuration protocol': 'dhcp',
      'domain name system': 'dns',
      'domain name server': 'dns',
      'virtual local area network': 'vlan',
      'virtual lan': 'vlan',
      'address resolution protocol': 'arp',
      'trivial file transfer protocol': 'tftp',
      'file transfer protocol': 'ftp',
      'simple network management protocol': 'snmp',
      'hot standby router protocol': 'hsrp',
      'virtual router redundancy protocol': 'vrrp',
      'network time protocol': 'ntp',
      'secure shell': 'ssh',
      'wi-fi': 'wifi',
      'wi fi': 'wifi',
    };

    test('every full name becomes exactly the short form', () {
      names.forEach((from, to) {
        expect(CasualEnglish.canonical(from), to, reason: '"$from"');
      });
    });

    test('longest phrase wins: the rapid and trivial forms are not cut', () {
      // If "spanning tree protocol" ran first inside the rapid variant the
      // text would read "rapid stp" and the whole-word RSTP trigger would
      // never fire; same seam for the file transfer family.
      expect(CasualEnglish.canonical('rapid spanning tree protocol'), 'rstp');
      expect(CasualEnglish.canonical('trivial file transfer protocol'), 'tftp');
      expect(
        CasualEnglish.canonical('the rapid spanning tree protocol converged'),
        'the rstp converged',
      );
    });

    test('casual fault phrases map onto real trigger text', () {
      expect(CasualEnglish.canonical('broadcast storm'), 'rapid spanning tree');
      expect(CasualEnglish.canonical('rogue dhcp'), 'dhcp snooping');
      expect(CasualEnglish.canonical('mac flapping'), 'mac address table');
      expect(CasualEnglish.canonical('no internet access'), 'no connectivity');
      expect(CasualEnglish.canonical('no internet'), 'no connectivity');
      expect(CasualEnglish.canonical('never gets an ip'), '169.254');
      // 'not get an ip' covers does not / did not / will not get an ip.
      expect(
        CasualEnglish.canonical('does not get an ip'),
        contains('169.254'),
      );
      expect(CasualEnglish.canonical('no ip address'), '169.254');
      expect(CasualEnglish.canonical('cable shows red'), 'red link');
      expect(CasualEnglish.canonical('link shows red'), 'red link');
      expect(CasualEnglish.canonical('connect to wifi'), 'connect to the wifi');
      expect(
        CasualEnglish.canonical('connect to wi-fi'),
        'connect to the wifi',
      );
      expect(CasualEnglish.canonical('join wifi'), 'join the wifi');
      expect(CasualEnglish.canonical('secure wifi'), 'secure the wifi');
    });

    test('canonical is idempotent', () {
      const samples = [
        'there is a broadcast storm in my switch',
        'the pc does not get an ip address',
        'how does the border gateway protocol work',
        'connect the laptop to wi-fi and secure wifi',
        'a rogue dhcp server appeared',
      ];
      for (final s in samples) {
        final once = CasualEnglish.canonical(s);
        expect(CasualEnglish.canonical(once), once, reason: s);
      }
    });

    test('addresses and numbers pass through byte for byte', () {
      const s = 'broadcast of 192.168.10.5/26 and 10.0.0.1';
      expect(CasualEnglish.canonical(s), s);
      final mixed = CasualEnglish.canonical(
        'the pc does not get an ip address on 192.168.1.0/24',
      );
      expect(mixed, contains('192.168.1.0/24'));
      expect(mixed, contains('169.254'));
    });

    test('text with nothing to rewrite is returned exactly', () {
      expect(CasualEnglish.canonical('hello there'), 'hello there');
      // The DHCPv6 battery phrasing is already short: canonical must not
      // touch it, or the entry would stop matching.
      expect(
        CasualEnglish.canonical('how do i set up dhcp for ipv6'),
        'how do i set up dhcp for ipv6',
      );
      expect(CasualEnglish.canonical(''), '');
    });

    test('a rewrite never lands inside a word', () {
      // 'not get an ip' must not match inside "cannot get an ip" - the word
      // boundary keeps the negation of the negation out of the rewrite.
      expect(
        CasualEnglish.canonical('cannot get an ip address'),
        'cannot get an ip address',
      );
    });

    test('concept-owned tokens: safe no-op at the table, routed by the chain', () {
      // No knowledge entry triggers on the bare token, so emitting it is
      // harmless there; the concept chain reads it ("nat" -> the NAT
      // walkthrough). UDP and ICMP stay untouched - no hook anywhere.
      expect(CasualEnglish.canonical('network address translation'), 'nat');
      expect(CasualEnglish.canonical('port address translation'), 'pat');
      expect(CasualEnglish.canonical('access control list'), 'acl');
      expect(CasualEnglish.canonical('quality of service'), 'qos');
      expect(CasualEnglish.canonical('transmission control protocol'), 'tcp');
      expect(
        CasualEnglish.canonical('user datagram protocol'),
        'user datagram protocol',
      );
    });

    test('plurals rewrite whole', () {
      expect(CasualEnglish.canonical('access control lists'), 'acl');
      expect(CasualEnglish.canonical('virtual lans'), 'vlan');
      // The plural marker must not eat a real word: a key never ends in s.
      expect(CasualEnglish.canonical('how do access control lists work'),
          'how do acl work');
    });
  });
}
