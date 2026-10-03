import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/diagnostics_service.dart';

void main() {
  group('ping parsing', () {
    test('the Windows format is understood', () {
      const raw = '''

Pinging 1.1.1.1 with 32 bytes of data:
Reply from 1.1.1.1: bytes=32 time=8ms TTL=57
Reply from 1.1.1.1: bytes=32 time=7ms TTL=57
Reply from 1.1.1.1: bytes=32 time=9ms TTL=57
Reply from 1.1.1.1: bytes=32 time=8ms TTL=57

Ping statistics for 1.1.1.1:
    Packets: Sent = 4, Received = 4, Lost = 0 (0% loss),
Approximate round trip times in milli-seconds:
    Minimum = 7ms, Maximum = 9ms, Average = 8ms
''';
      final summary = PingSummary.parse('1.1.1.1', raw);
      expect(summary.transmitted, 4);
      expect(summary.received, 4);
      expect(summary.lost, 0);
      expect(summary.minMs, 7);
      expect(summary.avgMs, 8);
      expect(summary.maxMs, 9);
      expect(summary.ok, isTrue);
      expect(summary.summary, contains('4/4 replies'));
    });

    test('the Linux and macOS format is understood', () {
      const raw = '''
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=12.4 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=117 time=11.9 ms

--- 8.8.8.8 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 11.901/12.150/12.400/0.249 ms
''';
      final summary = PingSummary.parse('8.8.8.8', raw);
      expect(summary.transmitted, 2);
      expect(summary.received, 2);
      expect(summary.lossPercent, 0);
      expect(summary.minMs, 12);
      expect(summary.avgMs, 12);
      expect(summary.maxMs, 12);
    });

    test('packet loss is reported as a percentage', () {
      const raw = '''
3 packets transmitted, 1 received, 66% packet loss, time 2003ms
''';
      final summary = PingSummary.parse('10.0.0.1', raw);
      expect(summary.transmitted, 3);
      expect(summary.received, 1);
      expect(summary.lost, 2);
      expect(summary.lossPercent, closeTo(66.6, 0.7));
      expect(summary.summary, contains('% loss'));
    });

    test('a silent host is a zero, not a crash', () {
      const raw = '''
PING 10.255.255.1 (10.255.255.1): 56 data bytes

--- 10.255.255.1 ping statistics ---
3 packets transmitted, 0 packets received, 100.0% packet loss
''';
      final summary = PingSummary.parse('10.255.255.1', raw);
      expect(summary.ok, isFalse);
      expect(summary.received, 0);
      expect(summary.summary, contains('0/3'));
    });

    test('unrecognised output yields an honest empty summary', () {
      final summary = PingSummary.parse('host', 'command not found');
      expect(summary.transmitted, 0);
      expect(summary.ok, isFalse);
      expect(summary.summary, contains('no reply'));
    });
  });

  group('arp parsing', () {
    test('Windows rows become address, hardware and interface', () {
      const raw = '''
Interface: 192.168.1.10 --- 0xb
  Internet Address      Physical Address      Type
  192.168.1.1           c0-3f-0e-11-22-33     dynamic
  192.168.1.20          00-1a-2b-3c-4d-5e     static
  192.168.1.255         ff-ff-ff-ff-ff-ff     static
''';
      final entries = DiagnosticsService.parseArp(raw);
      // The broadcast row is noise, so three rows become two.
      expect(entries, hasLength(2));
      expect(entries.first.address, '192.168.1.1');
      expect(entries.first.mac, 'c0:3f:0e:11:22:33');
      expect(entries.first.dynamic_, isTrue);
      expect(entries.last.dynamic_, isFalse);
    });

    test('unix rows are read too, and an incomplete entry is named', () {
      const raw = '''
? (192.168.1.1) at c0:3f:0e:11:22:33 on en0 ifscope [ethernet]
? (192.168.1.31) at (incomplete) on en0 ifscope [ethernet]
''';
      final entries = DiagnosticsService.parseArp(raw);
      expect(entries, hasLength(2));
      expect(entries.first.mac, 'c0:3f:0e:11:22:33');
      expect(entries.first.iface, 'en0');
      expect(entries.last.mac, '(incomplete)');
    });

    test('a table with no devices is empty rather than full of junk', () {
      expect(DiagnosticsService.parseArp(''), isEmpty);
      expect(DiagnosticsService.parseArp('No ARP Entries Found.'), isEmpty);
    });
  });

  group('a target is never read as shell syntax', () {
    test('the names an engineer actually types are accepted', () {
      expect(DiagnosticsService.normalizeHost('example.com'), 'example.com');
      expect(DiagnosticsService.normalizeHost('  10.0.0.1  '), '10.0.0.1');
      expect(DiagnosticsService.normalizeHost('router-1_lab'), 'router-1_lab');
      expect(DiagnosticsService.normalizeHost('fe80::1'), 'fe80::1');
      expect(DiagnosticsService.normalizeHost('8.8.8.8'), '8.8.8.8');
    });

    test('punctuation, whitespace, options and control bytes are refused', () {
      // Each of these is a target a shell would do something else with. The
      // point of the list is not that they fail today: it is that a value like
      // this never reaches a program at all, so there is no quoting to get
      // wrong.
      for (final bad in <String>[
        'example.com & calc',
        'host; rm -rf /',
        'a | tee b',
        r'example.com > out.txt',
        r'example.com `id`',
        r'example.com $(id)',
        r'example.com && curl evil.test',
        r'C:\Windows\System32\cmd.exe',
        r'example.com" & calc & "',
        'example.com\ncalc',
        'example.com\r\nHost: x',
        'example.com\t-x',
        '   ',
        '',
        // An option, not a host: `ping -f` is a flood ping.
        '-f',
        '-w 1000',
        'a' * 300,
      ]) {
        expect(
          DiagnosticsService.normalizeHost(bad),
          isNull,
          reason: 'refused before anything is started: $bad',
        );
      }
    });

    test('an injection payload in the host executes nothing', () async {
      const service = DiagnosticsService();
      final marker = File(
        '${Directory.systemTemp.path}'
        '/nb-diag-injection-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(() {
        if (marker.existsSync()) marker.deleteSync();
      });
      // Exactly what the old `cmd /c` / `sh -c` path would have run: the
      // payload, then a second command that writes a file.
      final payload = Platform.isWindows
          ? 'example.com & echo injected>"${marker.path}"'
          : 'example.com; echo injected >"${marker.path}"';

      final ping = await service.ping(payload);
      expect(ping.transmitted, 0);
      expect(ping.received, 0);
      expect(ping.error, isNotEmpty);
      expect(ping.summary, contains('no ping was run'));

      final trace = await service.traceroute(payload);
      expect(trace.exitCode, -1, reason: 'no process was started');
      expect(trace.output, isEmpty);
      expect(trace.error, contains('not a host name'));

      expect(marker.existsSync(), isFalse,
          reason: 'the second command never ran, because there was no shell');
    });

    test('the socket and DNS probes refuse the same targets', () async {
      const service = DiagnosticsService(timeout: Duration(seconds: 2));
      const payload = 'example.com & calc';

      final dns = await service.lookup(payload);
      expect(dns.addresses, isEmpty);
      expect(dns.error, contains('not a host name'));

      final port = await service.checkPort(payload, 22);
      expect(port.open, isFalse);
      expect(port.error, contains('not a host name'));

      final reverse = await service.reverseLookup('2001:db8::1 & calc');
      expect(reverse.addresses, isEmpty);
      expect(reverse.error, contains('not a host name'));
    });

    test('a real target is still probed normally', () async {
      const service = DiagnosticsService(timeout: Duration(seconds: 2));
      final dns = await service.lookup('localhost');
      expect(dns.ok, isTrue);
      expect(dns.addresses, isNotEmpty);

      // Whether the port answers is not the assertion; that the probe ran
      // against the host and not against a rejected name is.
      final port = await service.checkPort('127.0.0.1', 9);
      expect(port.host, '127.0.0.1');
      expect(port.error, isNot(contains('not a host name')));

      expect(await service.localInterfaces(), isNotEmpty);
    });
  });

  group('the service itself', () {
    test('the well-known ports are the ones a lab actually exposes', () {
      expect(DiagnosticsService.commonPorts[22], 'ssh');
      expect(DiagnosticsService.commonPorts[80], 'http');
      expect(DiagnosticsService.commonPorts[443], 'https');
      expect(DiagnosticsService.commonPorts[3389], 'rdp');
      expect(DiagnosticsService.commonPorts.length, greaterThan(20));
    });

    test('shell-based checks are gated to desktop platforms', () {
      // The test runs on a desktop host, so the tools are available here;
      // on a phone the same getter is false and the probes report that
      // instead of pretending the target is down.
      expect(DiagnosticsService.canRunShellTools, isTrue);
    });

    test('a probe result explains itself in one line', () {
      const probe = PortProbe(
        host: '10.0.0.1',
        port: 22,
        open: true,
        elapsedMs: 12,
        service: 'ssh',
      );
      expect(probe.label, '22 (ssh)');
      expect(probe.summary, contains('is open'));
      const closed = PortProbe(
        host: '10.0.0.1',
        port: 23,
        open: false,
        error: 'connection refused',
        service: 'telnet',
      );
      expect(closed.summary, contains('connection refused'));
    });

    test('a DNS answer says whether it resolved', () {
      const lookup = DnsLookup(host: 'example.com', addresses: ['93.184.216.34']);
      expect(lookup.ok, isTrue);
      expect(lookup.summary, contains('1 address'));
      const failed = DnsLookup(host: 'nope.invalid', error: 'name did not resolve');
      expect(failed.ok, isFalse);
      expect(failed.summary, contains('no answer'));
    });

    test('an HTTP result carries the status and server', () {
      const probe = HttpProbe(
        url: 'http://10.0.0.1',
        status: 200,
        server: 'nginx',
        elapsedMs: 30,
      );
      expect(probe.ok, isTrue);
      expect(probe.summary, contains('HTTP 200'));
      expect(probe.summary, contains('nginx'));
    });
  });
}
