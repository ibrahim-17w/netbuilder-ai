import '../models/network_intent.dart';
import 'adapters/packet_tracer_adapter.dart';
import 'nlu/lexicon.dart';

/// The plan as a human build guide - no `.pkt` written, no engine called.
///
/// The same [PacketTracerAdapter.autopilotPlan] payload the compiler receives
/// is read here, so the instructions cannot quietly describe a different
/// topology from the one a build would produce. This is the "tell me how to
/// build it" path: every device, every cable, the CLI the plan carries, the
/// server roles, the desktop addresses, and an ordered verification list.
class BuildGuide {
  const BuildGuide._();

  static const _serviceLabels = <String, String>{
    'dhcp': 'DHCP',
    'dhcpv6': 'DHCPv6',
    'dns': 'DNS',
    'http': 'HTTP',
    'https': 'HTTPS',
    'aaa': 'AAA',
    'email': 'Email',
    'ftp': 'FTP',
    'ntp': 'NTP',
    'tftp': 'TFTP',
    'syslog': 'Syslog',
    'iot': 'IoT registration',
    'snmp': 'SNMP',
    'vm': 'Voicemail',
    'cme': 'Call Manager Express',
    'radiuseap': 'RADIUS EAP',
    'prp': 'PRP',
  };

  /// Markdown for the standing plan. Pure: no file, no provider, no UI.
  ///
  /// [target] picks the dialect: `packet-tracer` (the default) speaks the
  /// canvas - place, cable, Desktop panels; a real-hardware target
  /// (`cisco-ssh`, anything else) speaks console and rack: the same devices,
  /// addresses and configs, but physical cabling and console access instead
  /// of palette clicks, and the Packet-Tracer-only manual notes (ASA inside
  /// the .pkt, offline-only kinds) do not apply and are left out.
  static String markdown(
    NetworkIntent intent, {
    String target = 'packet-tracer',
  }) {
    final realHardware = target.trim().toLowerCase() != 'packet-tracer' &&
        target.trim().toLowerCase() != 'packet_tracer' &&
        target.trim().toLowerCase() != 'pt';
    final plan = PacketTracerAdapter.autopilotPlan(intent);
    final steps = (plan['steps'] as List?) ?? const [];
    Map<String, dynamic> step(String action) => steps
        .whereType<Map>()
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['action'] == action, orElse: () => const {});

    final createNodes = step('create_nodes');
    final createLinks = step('create_links');
    final configs = ((step('paste_cli')['configs'] as Map?) ?? const {})
        .cast<String, dynamic>();
    final pcs = ((step('config_pcs')['pcs'] as Map?) ?? const {})
        .cast<String, dynamic>();
    final servers = ((step('config_servers')['servers'] as Map?) ?? const {})
        .cast<String, dynamic>();
    final nodes = ((createNodes['nodes'] as List?) ?? const [])
        .whereType<Map>()
        .map((n) => n.cast<String, dynamic>())
        .toList();
    final links = ((createLinks['links'] as List?) ?? const [])
        .whereType<Map>()
        .map((l) => l.cast<String, dynamic>())
        .toList();

    final project = intent.projectName.trim().isEmpty
        ? 'network'
        : intent.projectName.trim();
    final out = StringBuffer()
      ..writeln('# Build guide - $project')
      ..writeln()
      ..writeln(
        realHardware
            ? 'Follow these steps on the real equipment: console or SSH to '
                  'each device, apply the configs, and verify from a host. '
                  'Nothing is compiled here; ask me to **build the .pkt** '
                  'when you want the simulator file.'
            : 'Follow these steps in Packet Tracer. Nothing is compiled here '
                  'and no .pkt is written; ask me to **build the .pkt** when '
                  'you want the file.',
      )
      ..writeln()
      ..writeln(
        'Plan: ${nodes.length} device(s), ${links.length} cable(s), routing '
        '`${intent.routing}`'
        '${realHardware ? ', target real hardware' : ', target Packet Tracer'}.',
      );

    // 1. Devices -----------------------------------------------------------
    out
      ..writeln()
      ..writeln(
        realHardware
            ? '## 1. Rack and console the devices (${nodes.length})'
            : '## 1. Place the devices (${nodes.length})',
      )
      ..writeln();
    if (realHardware) {
      out.writeln(
        'The model column is the Packet Tracer equivalent - on real hardware '
        'any device of the same class (ISR router, Catalyst access switch) '
        'takes the same configuration.',
      );
      out.writeln();
    }
    if (nodes.isEmpty) {
      out.writeln('_The plan has no devices._');
    } else {
      out
        ..writeln('| Name | Type | Model | Notes |')
        ..writeln('| --- | --- | --- | --- |');
      for (final node in nodes) {
        final name = '${node['name'] ?? ''}';
        final type = '${node['type'] ?? ''}';
        final model = '${node['model'] ?? ''}';
        final notes = <String>[
          if (servers[name] != null) 'services: ${_roles(servers[name])}',
          // The two PT-specific notes below are meaningless on real hardware:
          // an ASA IS its own device there, and nothing is offline-only.
          if (!realHardware && offlineOnlyDeviceKinds.contains(type))
            'offline .pkt only; live autopilot cannot place it yet',
          if (!realHardware && type == 'firewall' && configs[name] != null)
            'ASA config is in the .pkt; it is not typed into a live session',
          if (deviceKindOf(type)?.wireless ?? false) 'joins wirelessly',
        ];
        out.writeln('| $name | $type | $model | ${_cell(notes.join('; '))} |');
      }
    }

    // 2. Cabling -----------------------------------------------------------
    out
      ..writeln()
      ..writeln(
        realHardware
            ? '## 2. Cable the links (${links.length})'
            : '## 2. Cable and associate (${links.length})',
      )
      ..writeln();
    if (links.isEmpty) {
      out.writeln(
        'No copper cables are defined. Wireless clients associate with the '
        'access point.',
      );
    } else {
      out
        ..writeln('| From | Port | To | Port | Cable |')
        ..writeln('| --- | --- | --- | --- | --- |');
      for (final link in links) {
        out.writeln(
          '| ${link['a'] ?? ''} | ${link['aIf'] ?? ''} | ${link['b'] ?? ''} '
          '| ${link['bIf'] ?? ''} | ${link['cable'] ?? 'auto'} |',
        );
      }
    }
    final wireless = nodes
        .where((n) => deviceKindOf('${n['type'] ?? ''}')?.wireless ?? false)
        .map((n) => '${n['name'] ?? ''}')
        .toList();
    if (wireless.isNotEmpty) {
      out.writeln();
      out.writeln(
        'Wireless clients (${wireless.join(', ')}) join the SSID broadcast by '
        'the access point. No cable is used.',
      );
    }

    // 3. Configuration -----------------------------------------------------
    out
      ..writeln()
      ..writeln('## 3. Configure')
      ..writeln();
    if (configs.isNotEmpty) {
      out.writeln('### Routers, switches and gateways');
      out.writeln();
      for (final entry in configs.entries) {
        final text = '${entry.value}'.trimRight();
        if (text.trim().isEmpty) continue;
        out
          ..writeln('#### ${entry.key}')
          ..writeln()
          ..writeln('```text')
          ..writeln(text)
          ..writeln('```')
          ..writeln();
      }
    }
    if (servers.isNotEmpty) {
      out.writeln('### Servers');
      out.writeln();
      for (final entry in servers.entries) {
        final name = entry.key;
        final services =
            ((entry.value as Map?)?['services'] as Map?) ?? const {};
        out
          ..writeln('#### $name')
          ..writeln();
        for (final role in services.keys) {
          final params = services[role];
          for (final line in _serviceLines('$role', params)) {
            out.writeln(line);
          }
        }
        out.writeln();
      }
    }
    final addressed = pcs.entries
        .where((e) => (e.value as Map?)?.isNotEmpty ?? false)
        .toList();
    if (addressed.isNotEmpty) {
      out
        ..writeln('### Desktop IP configuration')
        ..writeln()
        ..writeln('| Device | IP | Mask | Gateway |')
        ..writeln('| --- | --- | --- | --- |');
      for (final entry in addressed) {
        final cfg = (entry.value as Map?) ?? const {};
        out.writeln(
          '| ${entry.key} | ${cfg['ip'] ?? ''} | ${cfg['mask'] ?? ''} '
          '| ${cfg['gw'] ?? ''} |',
        );
      }
      out.writeln();
    }

    // 4. Verify ------------------------------------------------------------
    out
      ..writeln('## 4. Check it works')
      ..writeln();
    out.writeln('- [ ] Every device above exists, with the model shown.');
    if (links.isNotEmpty) {
      out.writeln(
        '- [ ] Every cable in the table is connected, with green '
        'link lights at both ends.',
      );
    }
    if (intent.routing != 'none') {
      final routers = nodes
          .where((n) => n['type'] == 'router' || n['type'] == 'firewall')
          .map((n) => '${n['name'] ?? ''}')
          .take(3)
          .join(', ');
      if (routers.isNotEmpty) {
        out.writeln(
          '- [ ] On $routers, `show ip route` lists every LAN in '
          'this plan.',
        );
      }
    }
    if (addressed.isNotEmpty) {
      final pcsWithGw = addressed
          .where((e) => ((e.value as Map?)?['gw'] ?? '') != '')
          .map((e) => e.key)
          .take(3)
          .join(', ');
      if (pcsWithGw.isNotEmpty) {
        out.writeln(
          '- [ ] From $pcsWithGw, ping the gateway and the far side '
          'of the network.',
        );
      }
    }
    if (servers.isNotEmpty) {
      final roles = <String>{
        for (final entry in servers.entries)
          ...(((entry.value as Map?)?['services'] as Map?)?.keys ?? const [])
              .map((k) => '$k'),
      };
      if (roles.contains('dhcp')) {
        out.writeln(
          '- [ ] Renew DHCP on a client and confirm it receives an '
          'address from the pool.',
        );
      }
      if (roles.contains('dns')) {
        out.writeln(
          '- [ ] From a PC, `nslookup <name>` resolves through the '
          'DNS server.',
        );
      }
      if (roles.contains('http') || roles.contains('https')) {
        out.writeln('- [ ] Open the web server IP in the PC browser.');
      }
      if (roles.contains('ftp')) {
        out.writeln('- [ ] Log in to the FTP server from a PC.');
      }
      if (roles.contains('email')) {
        out.writeln('- [ ] Send a test mail between two configured users.');
      }
      if (roles.contains('aaa')) {
        out.writeln('- [ ] SSH to a network device with an AAA account.');
      }
    }

    // 5. Limits ------------------------------------------------------------
    final notes = <String>[
      // Both PT-specific notes below are meaningless on real hardware.
      if (!realHardware && nodes.any((n) => n['type'] == 'firewall'))
        'Firewall: the ASA configuration is stored inside the generated .pkt. '
            'A live Packet Tracer session is never typed into for ASA '
            'devices; apply it by opening the file or configure it by hand.',
      if (!realHardware &&
          nodes.any(
            (n) => offlineOnlyDeviceKinds.contains('${n['type'] ?? ''}'),
          ))
        'Offline-only devices (${nodes.where((n) => offlineOnlyDeviceKinds.contains('${n['type'] ?? ''}')).map((n) => '${n['name'] ?? ''}').join(', ')}) '
            'are written into the .pkt, but the live autopilot does not place '
            'them yet. Place them by hand for a live run.',
      if (intent.assumptions.any((a) => a.trim().isNotEmpty))
        'Assumptions the planner made: ${intent.assumptions.where((a) => a.trim().isNotEmpty).take(3).join(' ')}',
    ];
    if (notes.isNotEmpty) {
      out
        ..writeln()
        ..writeln('## 5. What is manual')
        ..writeln();
      for (final note in notes) {
        out.writeln('- $note');
      }
    }
    return '${out.toString().trimRight()}\n';
  }

  static String _roles(dynamic serverEntry) {
    final services = ((serverEntry as Map?)?['services'] as Map?) ?? const {};
    return services.keys.map((k) => _serviceLabels['$k'] ?? '$k').join(', ');
  }

  /// The file name an exported guide saves as - the brief's own words when
  /// they name a network, the same naming rule the .pkt builds use, so a
  /// guide and its file sort together in a folder.
  static String guideFileName(NetworkIntent intent) {
    final slug = intent.projectName.trim().isEmpty
        ? 'network'
        : intent.projectName.trim().toLowerCase();
    final safe = slug.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final trimmed = safe.replaceAll(RegExp(r'^-+|-+$'), '');
    return 'guide-${trimmed.isEmpty ? 'network' : trimmed}.md';
  }

  static String _cell(String text) => text.replaceAll('|', r'\|');

  static List<String> _serviceLines(String role, dynamic params) {
    final label = _serviceLabels[role] ?? role.toUpperCase();
    final map = params is Map ? params : const {};
    switch (role) {
      case 'dhcp':
      case 'dhcpv6':
        final pools = (map['pools'] as List?) ?? const [];
        if (pools.isEmpty) return ['- **$label** - enabled.'];
        final lines = <String>['- **$label** - ${pools.length} pool(s):'];
        for (final pool in pools.take(6)) {
          final p = pool is Map ? pool : const {};
          final start = '${p['startIp'] ?? p['prefix'] ?? ''}';
          final mask = '${p['mask'] ?? p['prefixLength'] ?? ''}';
          final parts = <String>[
            if (start.isNotEmpty)
              'range starts $start${mask.isEmpty ? '' : ' / $mask'}',
            if ('${p['gateway'] ?? ''}'.isNotEmpty) 'gateway ${p['gateway']}',
            if ('${p['dnsServer'] ?? ''}'.isNotEmpty) 'DNS ${p['dnsServer']}',
            if ('${p['maxUsers'] ?? ''}'.isNotEmpty)
              'max ${p['maxUsers']} users',
          ];
          lines.add(
            '  - ${p['poolName'] ?? 'pool'}: ${parts.isEmpty ? 'configured' : parts.join(', ')}.',
          );
        }
        return lines;
      case 'dns':
        final records = (map['records'] as List?) ?? const [];
        if (records.isEmpty) {
          return ['- **DNS** - enabled; add records in the DNS tab.'];
        }
        final shown = records
            .take(6)
            .map((r) {
              final record = r is Map ? r : const {};
              return '${record['name'] ?? '?'} -> ${record['address'] ?? '?'}';
            })
            .join(', ');
        return [
          '- **DNS** - ${records.length} record(s): $shown'
              '${records.length > 6 ? ' and ${records.length - 6} more' : ''}.',
        ];
      case 'http':
        return [
          '- **HTTP** - enabled; the default page is served from this '
              'server.',
        ];
      case 'aaa':
        final users = (map['users'] as List?) ?? const [];
        return [
          '- **AAA** - ${users.isEmpty ? 'enabled' : '${users.length} '
                    'account(s)'}.',
        ];
      case 'email':
        final domain = '${map['domain'] ?? ''}';
        return [
          '- **Email** - enabled${domain.isEmpty ? '' : ' for $domain'}; '
              'add users in the Email tab.',
        ];
      case 'ftp':
        final users = (map['users'] as List?) ?? const [];
        return [
          '- **FTP** - ${users.isEmpty ? 'enabled' : '${users.length} '
                    'account(s)'}.',
        ];
      default:
        return ['- **$label** - enabled.'];
    }
  }
}
