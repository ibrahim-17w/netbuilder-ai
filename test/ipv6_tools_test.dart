import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/ipv6_tools.dart';

void main() {
  group('parse and canonical forms', () {
    test('expand fills every group and compression gap', () {
      expect(
        Ipv6Tools.expand('2001:db8::1'),
        '2001:0db8:0000:0000:0000:0000:0000:0001',
      );
      expect(
        Ipv6Tools.expand('fe80::a:bb:c:d'),
        'fe80:0000:0000:0000:000a:00bb:000c:000d',
      );
      expect(
        Ipv6Tools.expand('::ffff:192.168.1.1'),
        '0000:0000:0000:0000:0000:ffff:c0a8:0101',
      );
    });

    test('compress follows RFC 5952: longest zero run, leftmost on a tie', () {
      expect(Ipv6Tools.compress('2001:0db8:0000:0000:0000:0000:0000:0001'),
          '2001:db8::1');
      // Two equal runs: the leftmost is compressed.
      expect(Ipv6Tools.compress('1:0:0:2:0:0:3:4'), '1::2:0:0:3:4');
      // A single zero group is NOT compressed.
      expect(Ipv6Tools.compress('1:2:3:4:5:6:7:0'), '1:2:3:4:5:6:7:0');
      // The longest run wins over the leftmost.
      expect(Ipv6Tools.compress('1:0:2:0:0:0:3:4'), '1:0:2::3:4');
    });

    test('round trip: compress(expand(x)) is stable', () {
      for (final raw in ['2001:db8::1', '::1', '::', 'fe80::1', '::ffff:10.0.0.7']) {
        expect(Ipv6Tools.compress(Ipv6Tools.expand(raw)!),
            Ipv6Tools.compress(raw));
      }
    });

    test('rejects malformed input instead of guessing', () {
      for (final bad in [
        '',
        '192.168.1.1',
        '2001:::1',
        'g001::1',
        '2001:db8:::1:2:3:4:5:6:7:8:9',
        '12345::',
        'fe80::1::2',
      ]) {
        expect(Ipv6Tools.parse(bad), isNull, reason: '$bad must not parse');
      }
    });

    test('a zone id is ignored for arithmetic', () {
      expect(Ipv6Tools.compress('fe80::1%12'), 'fe80::1');
    });
  });

  group('classification', () {
    test('every special address names itself', () {
      expect(Ipv6Tools.classify('::'), 'unspecified (::)');
      expect(Ipv6Tools.classify('::1'), 'loopback (::1)');
      expect(Ipv6Tools.classify('ff02::1'), 'multicast (ff00::/8)');
      expect(
        Ipv6Tools.classify('::ffff:192.168.1.1'),
        'IPv4-mapped (::ffff:0:0/96)',
      );
      expect(
        Ipv6Tools.classify('fd00:ab::1'),
        'unique-local (fc00::/7)',
      );
      expect(Ipv6Tools.classify('fe80::1'), 'link-local (fe80::/10)');
      expect(Ipv6Tools.classify('2001:db8::1'), 'documentation (2001:db8::/32)');
      expect(
        Ipv6Tools.classify('2606:4700::1111'),
        'global unicast (2000::/3)',
      );
    });
  });

  group('EUI-64 and derived addresses', () {
    test('the interface identifier splices ff:fe and flips the U/L bit', () {
      // 00 -> 02: the universal/local bit (0x02) flips on.
      expect(
        Ipv6Tools.eui64('00:1a:2b:3c:4d:5e')!.map((b) => b.toRadixString(16)),
        ['2', '1a', '2b', 'ff', 'fe', '3c', '4d', '5e'],
      );
      // 02 -> 00: an already-local MAC flips back.
      expect(Ipv6Tools.eui64('02:1a:2b:3c:4d:5e')![0], 0x00);
    });

    test('the SLAAC address and the link-local both use the identifier', () {
      expect(
        Ipv6Tools.eui64Address('00:1a:2b:3c:4d:5e', '2001:db8:1:2::/64'),
        '2001:db8:1:2:21a:2bff:fe3c:4d5e',
      );
      expect(
        Ipv6Tools.linkLocalFromMac('00:1a:2b:3c:4d:5e'),
        'fe80::21a:2bff:fe3c:4d5e',
      );
    });

    test('EUI-64 needs a /64 prefix', () {
      expect(Ipv6Tools.eui64Address('00:1a:2b:3c:4d:5e', '2001:db8::/48'),
          isNull);
    });

    test('a bad MAC is refused', () {
      expect(Ipv6Tools.eui64('00:1a:2b:3c:4d'), isNull);
      expect(Ipv6Tools.eui64('zz:1a:2b:3c:4d:5e'), isNull);
    });

    test('solicited-node keeps the last 24 bits', () {
      expect(
        Ipv6Tools.solicitedNode('2001:db8:1:2:21a:2bff:fe3c:4d5e'),
        'ff02::1:ff3c:4d5e',
      );
    });
  });

  group('prefix math and splitting', () {
    test('a /64 reports its size in /64 subnets and addresses', () {
      final info = Ipv6Tools.prefixInfo('2001:db8:1:2::/64')!;
      expect(info['prefix'], '/64');
      expect(info['network'], '2001:db8:1:2::');
      expect(info['total addresses'], '18446744073709551616');
      expect(info['/64 subnets'], '1');
    });

    test('a /48 covers 65536 /64 subnets', () {
      final info = Ipv6Tools.prefixInfo('2001:db8:1::/48')!;
      expect(info['total addresses'],
          '1208925819614629174706176');
      expect(info['/64 subnets'], '65536');
    });

    test('splitting a /48 on /64 yields sequential children', () {
      final children = Ipv6Tools.split('2001:db8:1::/48', 64, count: 3)!;
      expect(children, [
        '2001:db8:1::/64',
        '2001:db8:1:1::/64',
        '2001:db8:1:2::/64',
      ]);
    });

    test('splitting refuses a bigger prefix and overflow counts', () {
      expect(Ipv6Tools.split('2001:db8:1::/64', 48), isNull);
      expect(Ipv6Tools.split('2001:db8::/32', 64, count: 0), isNull);
      // A count larger than the space is capped, not a lie.
      expect(
        Ipv6Tools.split('2001:db8:1::/64', 65, count: 100)!.length,
        2,
      );
    });
  });
}
