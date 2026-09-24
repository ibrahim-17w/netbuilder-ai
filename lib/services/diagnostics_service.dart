import 'dart:async';
import 'dart:io';

/// One local DNS answer.
class DnsLookup {
  final String host;
  final List<String> addresses;
  final int elapsedMs;
  final String error;

  const DnsLookup({
    required this.host,
    this.addresses = const [],
    this.elapsedMs = 0,
    this.error = '',
  });

  bool get ok => addresses.isNotEmpty;

  String get summary => ok
      ? '$host resolved to ${addresses.length} address(es) in ${elapsedMs}ms'
      : 'no answer for $host${error.isEmpty ? '' : ' ($error)'}';

  Map<String, dynamic> toMap() => {
    'host': host,
    'addresses': addresses,
    'elapsedMs': elapsedMs,
    'ok': ok,
    'error': error,
  };
}

/// One TCP reachability probe.
class PortProbe {
  final String host;
  final int port;
  final bool open;
  final int elapsedMs;
  final String service;
  final String error;

  const PortProbe({
    required this.host,
    required this.port,
    required this.open,
    this.elapsedMs = 0,
    this.service = '',
    this.error = '',
  });

  String get label => service.isEmpty ? '$port' : '$port ($service)';

  String get summary => open
      ? 'port $label on $host is open (${elapsedMs}ms)'
      : 'port $label on $host did not answer'
            '${error.isEmpty ? '' : ' - $error'}';
}

/// One HTTP probe: the answer a browser would get, without a browser.
class HttpProbe {
  final String url;
  final int status;
  final String server;
  final int elapsedMs;
  final String error;

  const HttpProbe({
    required this.url,
    this.status = 0,
    this.server = '',
    this.elapsedMs = 0,
    this.error = '',
  });

  bool get ok => status > 0;

  String get summary => ok
      ? 'HTTP $status from $url in ${elapsedMs}ms'
            '${server.isEmpty ? '' : ' - server: $server'}'
      : '$url did not answer${error.isEmpty ? '' : ' - $error'}';
}

/// The result of running a real command line tool (ping, traceroute, arp...).
class ShellResult {
  final String command;
  final int exitCode;
  final String output;
  final String error;

  const ShellResult({
    required this.command,
    this.exitCode = -1,
    this.output = '',
    this.error = '',
  });

  bool get ok => exitCode == 0 && output.trim().isNotEmpty;

  String get summary => ok ? output.trim() : (error.isEmpty ? 'no output' : error);

  Map<String, dynamic> toMap() => {
    'command': command,
    'exitCode': exitCode,
    'ok': ok,
    'output': output,
  };
}

/// What a `ping` reported, parsed. Pure, so the parsing is unit-tested
/// instead of being trusted because it once looked right on one machine.
class PingSummary {
  final String target;
  final int transmitted;
  final int received;
  final int minMs;
  final int avgMs;
  final int maxMs;

  const PingSummary({
    required this.target,
    required this.transmitted,
    required this.received,
    this.minMs = 0,
    this.avgMs = 0,
    this.maxMs = 0,
  });

  int get lost => transmitted - received;

  double get lossPercent =>
      transmitted == 0 ? 0 : (lost / transmitted) * 100;

  bool get ok => received > 0;

  String get summary => transmitted == 0
      ? 'no reply from $target'
      : '$received/$transmitted replies from $target'
            '${ok ? ' - $minMs/$avgMs/$maxMs ms min/avg/max' : ''}'
            '${lost > 0 ? ' - ${lossPercent.toStringAsFixed(0)}% loss' : ''}';

  /// Understands the Windows, macOS and Linux ping formats, because the app
  /// ships on all three and the same button has to work on each.
  static PingSummary parse(String target, String raw) {
    final text = raw.replaceAll('\r\n', '\n');
    var transmitted = 0;
    var received = 0;

    // Windows: "Sent = 4, Received = 4, Lost = 0 (0% loss)"
    final win = RegExp(
      r'(?:Sent|Transmitted)\s*=\s*(\d+).*?Received\s*=\s*(\d+)',
      dotAll: true,
    ).firstMatch(text);
    // Linux/macOS: "4 packets transmitted, 4 received, 0% packet loss"
    final nix = RegExp(
      r'(\d+)\s+packets?\s+transmitted,\s*(\d+)\s+(?:packets\s+)?received',
    ).firstMatch(text);
    if (win != null) {
      transmitted = int.tryParse(win.group(1)!) ?? 0;
      received = int.tryParse(win.group(2)!) ?? 0;
    } else if (nix != null) {
      transmitted = int.tryParse(nix.group(1)!) ?? 0;
      received = int.tryParse(nix.group(2)!) ?? 0;
    }

    // Windows: "Minimum = 1ms, Maximum = 2ms, Average = 1ms"
    // Linux:   "rtt min/avg/max/mdev = 0.036/0.045/0.061/0.012 ms"
    var minMs = 0, avgMs = 0, maxMs = 0;
    final winTimes = RegExp(
      r'Minimum\s*=\s*(\d+)ms,\s*Maximum\s*=\s*(\d+)ms,\s*Average\s*=\s*(\d+)ms',
    ).firstMatch(text);
    final nixTimes = RegExp(
      r'=\s*([\d.]+)/([\d.]+)/([\d.]+)',
    ).firstMatch(text);
    if (winTimes != null) {
      minMs = int.tryParse(winTimes.group(1)!) ?? 0;
      maxMs = int.tryParse(winTimes.group(2)!) ?? 0;
      avgMs = int.tryParse(winTimes.group(3)!) ?? 0;
    } else if (nixTimes != null) {
      double d(String? s) => double.tryParse(s ?? '') ?? 0;
      minMs = d(nixTimes.group(1)).round();
      avgMs = d(nixTimes.group(2)).round();
      maxMs = d(nixTimes.group(3)).round();
    }

    // A single ping that only printed the reply line still counts.
    if (transmitted == 0 && RegExp(r'ttl[=\s]', caseSensitive: false).hasMatch(text)) {
      transmitted = 1;
      received = 1;
    }
    return PingSummary(
      target: target,
      transmitted: transmitted,
      received: received,
      minMs: minMs,
      avgMs: avgMs,
      maxMs: maxMs,
    );
  }
}

/// One row of `arp -a`.
class ArpEntry {
  final String address;
  final String mac;
  final String iface;
  final bool dynamic_;

  const ArpEntry({
    required this.address,
    required this.mac,
    this.iface = '',
    this.dynamic_ = true,
  });
}

/// A NIC this machine actually has, read from the OS rather than guessed.
class LocalInterface {
  final String name;
  final List<String> addresses;
  final String mac;

  const LocalInterface({
    required this.name,
    this.addresses = const [],
    this.mac = '',
  });

  String get summary =>
      '$name${mac.isEmpty ? '' : '  $mac'}\n    ${addresses.join(', ')}';
}

/// Live network checks, run from this machine.
///
/// Everything here is a real probe with a timeout - a DNS query, a TCP
/// connect, an HTTP request, or the operating system's own ping/traceroute/
/// arp tools. Nothing is sent to a third party: the app's privacy promise is
/// that the user's network stays the user's, so a diagnostic runs from their
/// machine to their target and nowhere else.
///
/// Shell-based checks are desktop only (a phone has no `ping` binary); the
/// socket and DNS checks work on every platform.
class DiagnosticsService {
  final Duration timeout;

  const DiagnosticsService({this.timeout = const Duration(seconds: 4)});

  /// Common service ports, in the order an engineer looks at them.
  static const commonPorts = <int, String>{
    20: 'ftp-data',
    21: 'ftp',
    22: 'ssh',
    23: 'telnet',
    25: 'smtp',
    53: 'dns',
    67: 'dhcp',
    69: 'tftp',
    80: 'http',
    110: 'pop3',
    123: 'ntp',
    143: 'imap',
    161: 'snmp',
    389: 'ldap',
    443: 'https',
    445: 'smb',
    514: 'syslog',
    587: 'smtp-submission',
    636: 'ldaps',
    1433: 'mssql',
    1521: 'oracle',
    3306: 'mysql',
    3389: 'rdp',
    5060: 'sip',
    5432: 'postgres',
    5900: 'vnc',
    8080: 'http-alt',
    8443: 'https-alt',
  };

  static bool get canRunShellTools {
    try {
      return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    } catch (_) {
      return false;
    }
  }

  /// Resolve a name (or an address, which resolves to itself). This is the
  /// first question of every "can I reach it" conversation, and it is the one
  /// that proves whether DNS - not routing - is the thing that is broken.
  Future<DnsLookup> lookup(String host) async {
    final name = host.trim();
    if (name.isEmpty) return const DnsLookup(host: '', error: 'no name given');
    final watch = Stopwatch()..start();
    try {
      final result = await InternetAddress.lookup(name).timeout(timeout);
      watch.stop();
      return DnsLookup(
        host: name,
        addresses: [
          for (final address in result)
            '${address.address} (IPv${address.type == InternetAddressType.IPv6 ? 6 : 4})',
        ],
        elapsedMs: watch.elapsedMilliseconds,
      );
    } catch (e) {
      watch.stop();
      return DnsLookup(
        host: name,
        elapsedMs: watch.elapsedMilliseconds,
        error: _reason(e),
      );
    }
  }

  /// The reverse lookup: an address back to a name, which is what a PTR
  /// record is for.
  Future<DnsLookup> reverseLookup(String address) async {
    final host = address.split('/').first.trim();
    final watch = Stopwatch()..start();
    try {
      final resolved = await InternetAddress(host).reverse().timeout(timeout);
      watch.stop();
      return DnsLookup(host: host, addresses: [resolved.host], elapsedMs: watch.elapsedMilliseconds);
    } catch (e) {
      watch.stop();
      return DnsLookup(
        host: host,
        elapsedMs: watch.elapsedMilliseconds,
        error: _reason(e),
      );
    }
  }

  /// Is one TCP port answering? A refused connection and a filtered one are
  /// different faults, so the error text is kept rather than flattened.
  Future<PortProbe> checkPort(String host, int port, {String service = ''}) async {
    final target = host.trim();
    final watch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(target, port, timeout: timeout);
      watch.stop();
      return PortProbe(
        host: target,
        port: port,
        open: true,
        elapsedMs: watch.elapsedMilliseconds,
        service: service.isEmpty ? (commonPorts[port] ?? '') : service,
      );
    } catch (e) {
      watch.stop();
      return PortProbe(
        host: target,
        port: port,
        open: false,
        elapsedMs: watch.elapsedMilliseconds,
        service: service.isEmpty ? (commonPorts[port] ?? '') : service,
        error: _reason(e),
      );
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// Probe several ports at once. Concurrency is capped so a probe of a real
  /// device does not look like a flood.
  Future<List<PortProbe>> checkPorts(
    String host,
    List<int> ports, {
    int concurrency = 8,
  }) async {
    final out = <PortProbe>[];
    for (var i = 0; i < ports.length; i += concurrency) {
      final batch = ports.skip(i).take(concurrency);
      final results = await Future.wait([
        for (final port in batch) checkPort(host, port),
      ]);
      out.addAll(results);
    }
    out.sort((a, b) => a.port.compareTo(b.port));
    return out;
  }

  /// The well-known ports, in one pass - "what is this device actually
  /// offering?" answered in a few seconds instead of one port at a time.
  Future<List<PortProbe>> scanCommonPorts(String host) =>
      checkPorts(host, commonPorts.keys.toList());

  /// An HTTP(S) probe: status line, server header and time. Uses GET so a
  /// server that refuses HEAD still answers, and never follows a redirect
  /// into a private address.
  Future<HttpProbe> checkHttp(String url) async {
    final raw = url.trim();
    final normalized = raw.startsWith('http://') || raw.startsWith('https://')
        ? raw
        : 'http://$raw';
    final watch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(normalized)).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      watch.stop();
      return HttpProbe(
        url: normalized,
        status: response.statusCode,
        server: (response.headers.value('server') ?? '').toString(),
        elapsedMs: watch.elapsedMilliseconds,
      );
    } catch (e) {
      watch.stop();
      return HttpProbe(
        url: normalized,
        elapsedMs: watch.elapsedMilliseconds,
        error: _reason(e),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// ICMP reachability using the operating system's own ping. Unsupported on
  /// a phone, which is reported as an error rather than as "down".
  Future<PingSummary> ping(String host, {int count = 4}) async {
    final result = await _shell(_pingCommand(host.trim(), count));
    return PingSummary.parse(host.trim(), result.output);
  }

  /// The path a packet takes, hop by hop.
  Future<ShellResult> traceroute(String host, {int maxHops = 15}) =>
      _shell(_traceCommand(host.trim(), maxHops));

  /// This machine's own interfaces - name, MAC and every address on them.
  /// Pure Dart, so it works on a phone too, and it is the fastest way to
  /// answer "what address is this PC on?".
  Future<List<LocalInterface>> localInterfaces() async {
    try {
      final list = await NetworkInterface.list(
        includeLoopback: true,
        includeLinkLocal: true,
      );
      // dart:io does not expose a NIC's MAC address, so the hardware field
      // stays empty here and the ARP table is where a MAC is read from.
      return [
        for (final iface in list)
          LocalInterface(
            name: iface.name,
            addresses: [
              for (final address in iface.addresses)
                '${address.address}/'
                    '${address.type == InternetAddressType.IPv6 ? 'v6' : 'v4'}',
            ],
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The ARP table, parsed. Every address the machine has actually talked to
  /// on the local segment, which is what a duplicate-address hunt starts
  /// from.
  Future<List<ArpEntry>> arpTable() async {
    final result = await _shell(_arpCommand());
    return parseArp(result.output);
  }

  /// The route table as the operating system prints it. Deliberately not
  /// parsed into a model: every OS shapes it differently, and a wrong parse
  /// is worse than the real text.
  Future<ShellResult> routeTable() => _shell(_routeCommand());

  /// The connections this machine currently has open.
  Future<ShellResult> activeConnections() => _shell(_netstatCommand());

  static List<ArpEntry> parseArp(String raw) {
    final out = <ArpEntry>[];
    final mac = RegExp(
      r'([0-9a-f]{2}[:-]){5}[0-9a-f]{2}',
      caseSensitive: false,
    );
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      // Windows prints "Interface: 192.168.1.10 --- 0xb" as a heading; the
      // address in it is the local NIC, not a neighbour.
      if (line.trimLeft().toLowerCase().startsWith('interface:')) continue;
      final ip = RegExp(r'(\d{1,3}\.){3}\d{1,3}').firstMatch(line);
      if (ip == null) continue;
      final address = ip.group(0)!;
      if (address == '0.0.0.0' ||
          address.startsWith('224.') ||
          address.startsWith('239.') ||
          address == '255.255.255.255') {
        continue; // broadcast/multicast rows are noise here
      }
      final hardware = mac.firstMatch(line);
      final hardwareText = hardware == null
          ? ''
          : hardware.group(0)!.toLowerCase().replaceAll('-', ':');
      // A subnet broadcast shows up as a real address with an all-ff MAC.
      if (hardwareText == 'ff:ff:ff:ff:ff:ff') continue;
      final iface = RegExp(r'(?:on|interface:)\s+([\w./:-]+)')
          .firstMatch(line)
          ?.group(1);
      out.add(
        ArpEntry(
          address: address,
          mac: hardwareText.isEmpty ? '(incomplete)' : hardwareText,
          iface: iface ?? '',
          dynamic_: !line.contains('static'),
        ),
      );
    }
    return out;
  }

  /// Start a program and collect it, with a hard timeout so a probe can never
  /// hang the screen that asked for it.
  Future<ShellResult> _shell(String command) async {
    if (!canRunShellTools) {
      return ShellResult(
        command: command,
        error: 'needs a desktop: a phone has no ping/traceroute binary',
      );
    }
    try {
      final result = await _run(command).timeout(timeout * 4);
      final stdout = result.stdout.toString();
      final stderr = result.stderr.toString();
      return ShellResult(
        command: command,
        exitCode: result.exitCode,
        output: stdout,
        error: stderr.trim(),
      );
    } catch (e) {
      return ShellResult(command: command, error: _reason(e));
    }
  }

  static Future<ProcessResult> _run(String command) {
    if (Platform.isWindows) {
      return Process.run('cmd', ['/c', command]);
    }
    return Process.run('/bin/sh', ['-c', command]);
  }

  static String _pingCommand(String host, int count) => Platform.isWindows
      ? 'ping -n $count $host'
      : 'ping -c $count $host';

  static String _traceCommand(String host, int maxHops) => Platform.isWindows
      ? 'tracert -h $maxHops -w 1000 $host'
      : 'traceroute -m $maxHops $host';

  static String _arpCommand() => Platform.isWindows ? 'arp -a' : 'arp -an';

  static String _routeCommand() => Platform.isWindows
      ? 'route print -4'
      : 'netstat -rn';

  static String _netstatCommand() => Platform.isWindows
      ? 'netstat -ano'
      : 'netstat -an';

  /// The failure in the user's words: a timeout, a refused connection and an
  /// unknown host are three different problems with three different fixes.
  static String _reason(Object error) {
    final text = error.toString();
    if (error is TimeoutException) return 'timed out';
    if (error is SocketException) {
      final os = error.osError?.message ?? '';
      if (os.toLowerCase().contains('refused')) return 'connection refused';
      if (os.toLowerCase().contains('unreachable')) return 'unreachable';
      if (os.toLowerCase().contains('failed host lookup')) {
        return 'name did not resolve';
      }
      return os.isEmpty ? 'socket error' : os;
    }
    if (error is FormatException) return 'not a valid address';
    return text;
  }
}
