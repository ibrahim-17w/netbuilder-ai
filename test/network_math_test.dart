import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/network_math.dart';
import 'package:net_builder/services/network_tools.dart';

void main() {
  group('masks and wildcards', () {
    test('a dotted mask becomes its prefix', () {
      expect(NetworkMath.prefixFromMask('255.255.255.0'), 24);
      expect(NetworkMath.prefixFromMask('255.255.255.252'), 30);
      expect(NetworkMath.prefixFromMask('0.0.0.0'), 0);
      expect(NetworkMath.prefixFromMask('255.255.255.255'), 32);
    });

    test('a holey mask is rejected rather than guessed', () {
      // 255.0.255.0 has a 1 after a 0: a config error, not a /16.
      expect(NetworkMath.prefixFromMask('255.0.255.0'), isNull);
      expect(NetworkMath.prefixFromMask('nonsense'), isNull);
      expect(NetworkMath.wildcardFromMask('255.0.255.0'), '');
    });

    test('the ACL inverse mask is the complement', () {
      expect(NetworkMath.wildcardFromPrefix(24), '0.0.0.255');
      expect(NetworkMath.wildcardFromPrefix(30), '0.0.0.3');
      expect(NetworkMath.wildcardFromPrefix(0), '255.255.255.255');
      expect(NetworkMath.wildcardFromMask('255.255.255.192'), '0.0.0.63');
    });

    test('the binary view splits network bits from host bits', () {
      expect(
        NetworkMath.binary('192.168.1.0'),
        '11000000.10101000.00000001.00000000',
      );
      expect(
        NetworkMath.binaryMask(24),
        '11111111.11111111.11111111.00000000',
      );
      expect(NetworkMath.binary('not an address'), '');
    });
  });

  group('address scope', () {
    test('the special-purpose ranges are named', () {
      expect(NetworkMath.scope('10.0.0.1'), IpScope.rfc1918);
      expect(NetworkMath.scope('172.16.0.1'), IpScope.rfc1918);
      expect(NetworkMath.scope('192.168.255.254'), IpScope.rfc1918);
      expect(NetworkMath.scope('8.8.8.8'), IpScope.publicAddress);
      expect(NetworkMath.scope('127.0.0.1'), IpScope.loopback);
      expect(NetworkMath.scope('169.254.10.10'), IpScope.linkLocal);
      expect(NetworkMath.scope('100.64.1.1'), IpScope.carrierNat);
      expect(NetworkMath.scope('203.0.113.5'), IpScope.documentation);
      expect(NetworkMath.scope('224.0.0.9'), IpScope.multicast);
      expect(NetworkMath.isPrivate('10.1.2.3'), isTrue);
      expect(NetworkMath.isPrivate('1.1.1.1'), isFalse);
    });

    test('the classful class is reported for the lab exercises that ask', () {
      expect(NetworkMath.classfulClass('10.0.0.1'), 'A');
      expect(NetworkMath.classfulClass('172.16.0.1'), 'B');
      expect(NetworkMath.classfulClass('192.168.1.1'), 'C');
      expect(NetworkMath.classfulMask('10.0.0.1'), '255.0.0.0');
      expect(NetworkMath.classfulMask('192.168.1.1'), '255.255.255.0');
    });
  });

  group('prefix sizing', () {
    test('the smallest prefix that holds the hosts is chosen', () {
      expect(NetworkMath.prefixForHosts(1), 32);
      // Two hosts get a /30 rather than RFC 3021's /31, because Packet
      // Tracer and older gear reject a /31 on a link.
      expect(NetworkMath.prefixForHosts(2), 30);
      expect(NetworkMath.prefixForHosts(6), 29);
      expect(NetworkMath.prefixForHosts(14), 28);
      expect(NetworkMath.prefixForHosts(30), 27);
      expect(NetworkMath.prefixForHosts(60), 26);
      expect(NetworkMath.prefixForHosts(200), 24);
      expect(NetworkMath.prefixForHosts(254), 24);
      expect(NetworkMath.prefixForHosts(255), 23);
    });
  });

  group('splitting', () {
    test('a block is carved into equal subnets', () {
      expect(NetworkMath.split('10.0.0.0/23', 24), [
        '10.0.0.0/24',
        '10.0.1.0/24',
      ]);
      expect(NetworkMath.split('192.168.1.0/24', 26), [
        '192.168.1.0/26',
        '192.168.1.64/26',
        '192.168.1.128/26',
        '192.168.1.192/26',
      ]);
    });

    test('an impossible split is refused, not approximated', () {
      expect(NetworkMath.split('10.0.0.0/24', 20), isEmpty);
      expect(NetworkMath.split('10.0.0.0/24', 33), isEmpty);
      expect(NetworkMath.split('nonsense', 26), isEmpty);
      expect(NetworkMath.splitCount('10.0.0.0/24', 26), 4);
      expect(NetworkMath.splitCount('10.0.0.0/24', 20), 0);
    });
  });

  group('VLSM', () {
    test('requirements are allocated largest first, each the smallest fit', () {
      final plan = NetworkMath.vlsm('192.168.0.0/22', const [
        (name: 'head office', hosts: 200),
        (name: 'guest', hosts: 100),
        (name: 'branch', hosts: 60),
        (name: 'link', hosts: 2),
      ]);
      expect(plan.map((a) => a.network).toList(), [
        '192.168.0.0/24',
        '192.168.1.0/25',
        '192.168.1.128/26',
        '192.168.1.192/30',
      ]);
      expect(plan.first.usableHosts, 254);
      expect(plan.last.mask, '255.255.255.252');
      expect(plan.every((a) => a.note.isEmpty), isTrue);
    });

    test('a site that does not fit says so instead of vanishing', () {
      final plan = NetworkMath.vlsm('192.168.0.0/24', const [
        (name: 'big', hosts: 200),
        (name: 'bigger', hosts: 500),
      ]);
      expect(plan.first.name, 'bigger');
      expect(plan.first.network, isEmpty);
      expect(plan.first.note, contains('needs a /23'));
      expect(plan.last.network, '192.168.0.0/24');
    });

    test('allocations never overlap each other', () {
      final plan = NetworkMath.vlsm('10.0.0.0/24', const [
        (name: 'a', hosts: 50),
        (name: 'b', hosts: 50),
        (name: 'c', hosts: 20),
        (name: 'd', hosts: 10),
      ]);
      final networks = [
        for (final allocation in plan)
          if (allocation.network.isNotEmpty) allocation.network,
      ];
      expect(NetworkMath.overlappingPairs(networks), isEmpty);
    });

    test('an invalid base block produces nothing rather than nonsense', () {
      expect(NetworkMath.vlsm('not-a-network', const [
        (name: 'a', hosts: 10),
      ]), isEmpty);
      expect(NetworkMath.vlsm('10.0.0.0/24', const []), isEmpty);
    });
  });

  group('overlap detection', () {
    test('a subnet inside another overlaps it', () {
      expect(NetworkMath.overlaps('10.0.0.0/24', '10.0.0.128/25'), isTrue);
      expect(NetworkMath.overlaps('10.0.0.0/25', '10.0.0.128/25'), isFalse);
      expect(NetworkMath.overlaps('10.0.0.0/16', '10.0.1.0/24'), isTrue);
      expect(NetworkMath.overlaps('10.0.0.0/24', '10.0.1.0/24'), isFalse);
      expect(NetworkMath.overlaps('192.168.1.0/24', '192.168.1.0/24'), isTrue);
      expect(NetworkMath.overlaps('10.0.0.0/8', '0.0.0.0/0'), isTrue);
    });

    test('every colliding pair is reported once', () {
      final pairs = NetworkMath.overlappingPairs([
        '10.0.0.0/24',
        '10.0.0.0/25',
        '192.168.1.0/24',
      ]);
      expect(pairs, hasLength(1));
      expect(pairs.first.$1, '10.0.0.0/24');
      expect(pairs.first.$2, '10.0.0.0/25');
    });

    test('the network and broadcast addresses are identified', () {
      expect(NetworkMath.isReservedAddress('10.0.0.0/24', '10.0.0.0'), isTrue);
      expect(
        NetworkMath.isReservedAddress('10.0.0.0/24', '10.0.0.255'),
        isTrue,
      );
      expect(NetworkMath.isReservedAddress('10.0.0.0/24', '10.0.0.1'), isFalse);
      // A /31 has nothing reserved in it.
      expect(NetworkMath.isReservedAddress('10.0.0.0/31', '10.0.0.0'), isFalse);
    });
  });

  group('summarization', () {
    test('adjacent halves merge into one shorter prefix', () {
      expect(NetworkMath.summarize(['10.0.0.0/25', '10.0.0.128/25']), [
        '10.0.0.0/24',
      ]);
    });

    test('non-adjacent blocks stay separate', () {
      final result = NetworkMath.summarize(['10.0.0.0/25', '10.0.1.0/25']);
      expect(result, hasLength(2));
    });

    test('a full set collapses to the block it came from', () {
      final result = NetworkMath.summarize([
        for (final subnet in NetworkMath.split('192.168.4.0/24', 26)) subnet,
      ]);
      expect(result, ['192.168.4.0/24']);
    });

    test('duplicates collapse and invalid input is ignored', () {
      expect(
        NetworkMath.summarize(['10.0.0.0/24', '10.0.0.5/24', 'junk']),
        ['10.0.0.0/24'],
      );
      expect(NetworkMath.summarize(const []), isEmpty);
    });
  });

  group('ranges', () {
    test('a range becomes the fewest prefixes that cover it', () {
      expect(
        NetworkMath.rangeToCidrs('192.168.1.0', '192.168.1.255'),
        ['192.168.1.0/24'],
      );
      expect(NetworkMath.rangeToCidrs('10.0.0.1', '10.0.0.6'), [
        '10.0.0.1/32',
        '10.0.0.2/31',
        '10.0.0.4/31',
        '10.0.0.6/32',
      ]);
      expect(
        NetworkMath.rangeToCidrs('10.0.0.0', '10.0.3.255'),
        ['10.0.0.0/22'],
      );
    });

    test('the covered prefixes really do cover the range', () {
      final cidrs = NetworkMath.rangeToCidrs('10.1.2.3', '10.1.2.199');
      for (final ip in const ['10.1.2.3', '10.1.2.100', '10.1.2.199']) {
        expect(
          cidrs.any((cidr) => NetworkTools.contains(cidr, ip)),
          isTrue,
          reason: '$ip must be inside one of $cidrs',
        );
      }
      expect(
        cidrs.any((cidr) => NetworkTools.contains(cidr, '10.1.2.200')),
        isFalse,
        reason: 'nothing outside the range may be covered',
      );
    });

    test('an impossible range yields nothing', () {
      expect(NetworkMath.rangeToCidrs('10.0.0.9', '10.0.0.1'), isEmpty);
      expect(NetworkMath.rangeToCidrs('junk', '10.0.0.1'), isEmpty);
    });

    test('the host range of a subnet is the two ends', () {
      final range = NetworkMath.hostRange('192.168.1.0/24')!;
      expect(range.startIp, '192.168.1.1');
      expect(range.endIp, '192.168.1.254');
      expect(range.count, 254);
      expect(NetworkMath.hostRange('junk'), isNull);
    });
  });

  group('DNS names and neighbours', () {
    test('the reverse name is the address reversed', () {
      expect(
        NetworkMath.reverseDnsName('10.0.0.5'),
        '5.0.0.10.in-addr.arpa',
      );
      expect(
        NetworkMath.reverseDnsName('192.168.1.20/24'),
        '20.1.168.192.in-addr.arpa',
      );
      expect(NetworkMath.reverseDnsName('nonsense'), '');
    });

    test('the reverse zone follows the delegation point', () {
      expect(NetworkMath.reverseZone('192.168.1.0/24'), '1.168.192.in-addr.arpa');
      expect(NetworkMath.reverseZone('172.16.0.0/16'), '16.172.in-addr.arpa');
      expect(NetworkMath.reverseZone('10.0.0.0/25'), '0.0.10.in-addr.arpa');
    });

    test('the neighbouring blocks walk in the right direction', () {
      expect(NetworkMath.nextSubnet('192.168.1.0/24'), '192.168.2.0/24');
      expect(NetworkMath.previousSubnet('192.168.1.0/24'), '192.168.0.0/24');
      expect(NetworkMath.previousSubnet('0.0.0.0/24'), isNull);
      expect(NetworkMath.nextSubnet('255.255.255.0/24'), isNull);
    });

    test('two addresses share the prefix that covers both', () {
      expect(NetworkMath.coveringPrefix('10.0.0.5', '10.0.0.200'), '10.0.0.0/24');
      expect(
        NetworkMath.coveringPrefix('10.0.0.5', '10.0.1.200'),
        '10.0.0.0/23',
      );
      expect(
        NetworkMath.coveringPrefix('10.0.0.5', '10.9.1.200', prefix: 12),
        '10.0.0.0/12',
      );
      expect(NetworkMath.coveringPrefix('junk', '10.0.0.1'), isNull);
    });
  });

  group('the facts map', () {
    test('one CIDR answers everything a screen needs', () {
      final facts = NetworkMath.facts('192.168.1.130/26');
      expect(facts['ok'], isTrue);
      expect(facts['network'], '192.168.1.128');
      expect(facts['prefix'], 26);
      expect(facts['mask'], '255.255.255.192');
      expect(facts['wildcard'], '0.0.0.63');
      expect(facts['broadcast'], '192.168.1.191');
      expect(facts['firstHost'], '192.168.1.129');
      expect(facts['lastHost'], '192.168.1.190');
      expect(facts['usableHosts'], 62);
      expect(facts['scope'], contains('private'));
      expect(facts['reverseDns'], '130.1.168.192.in-addr.arpa');
    });

    test('an invalid CIDR is reported, not thrown', () {
      expect(NetworkMath.facts('300.1.1.1/24')['ok'], isFalse);
    });

    test('the one-line description names the addresses and the scope', () {
      final line = NetworkMath.describe('10.10.10.0/30');
      expect(line, contains('10.10.10.0/30'));
      expect(line, contains('255.255.255.252'));
      expect(line, contains('2 usable'));
      expect(NetworkMath.describe('junk'), contains('not a valid'));
    });
  });
}
