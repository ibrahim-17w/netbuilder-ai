import '../models/network_intent.dart';

/// A device from the standing plan, explained from the plan itself.
///
/// "What does SW1 do?" is a help question whose answer is entirely local:
/// the device's type and model, the interfaces the plan addressed, the
/// cables it carries, the services it was given, and the read-only commands
/// that show the same facts on the real device. No model, no file, no
/// mutation - the question is answered and the plan is untouched.
class PlanDeviceExplainer {
  const PlanDeviceExplainer._();

  /// True when [text] names a device of [plan] as its subject.
  static String? namedDevice(String text, NetworkIntent plan) {
    final t = text.toLowerCase();
    for (final node in plan.nodes) {
      final name = node.name.toLowerCase();
      if (name.length < 2) continue;
      if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(t)) {
        return node.name;
      }
    }
    return null;
  }

  static String explain(NetworkIntent plan, String deviceName) {
    final node = plan.nodes.firstWhere(
      (n) => n.name.toLowerCase() == deviceName.toLowerCase(),
      orElse: () => throw ArgumentError('$deviceName is not in this plan'),
    );
    final kind = deviceKindOf(node.type);
    final b = StringBuffer()
      ..writeln(
        '**${node.name}** is the plan\'s '
        '${_kindName(node.type)}'
        '${node.model == null || node.model!.isEmpty ? '' : ' (${node.model})'}.',
      );

    // What the plan told this device to be.
    final roles = node.services.toList();
    if (roles.isNotEmpty) {
      b.writeln(
        'It carries ${roles.length} service role(s): '
        '${roles.join(', ')}.',
      );
    }

    // Addressing: every interface the plan gave an address.
    final addrs = plan.addressing
        .where((a) => a.node.toLowerCase() == node.name.toLowerCase())
        .toList();
    if (addrs.isNotEmpty) {
      b.writeln();
      b.writeln('Its addresses:');
      for (final a in addrs) {
        b.writeln('- `${a.iface}`: ${a.ipCidr}');
      }
    }

    // Cabling: who this device is wired to, on which ports.
    final links = plan.links
        .where(
          (l) =>
              l.a.toLowerCase() == node.name.toLowerCase() ||
              l.b.toLowerCase() == node.name.toLowerCase(),
        )
        .toList();
    b.writeln();
    if (links.isEmpty) {
      b.writeln(
        kind?.wireless ?? false
            ? 'No cables: it joins the network wirelessly.'
            : 'No cable reaches it in this plan - on the canvas it would stand '
                  'alone.',
      );
    } else {
      b.writeln('Its cables:');
      for (final l in links) {
        final mine = l.a.toLowerCase() == node.name.toLowerCase();
        final other = mine ? l.b : l.a;
        final myPort = mine ? l.aIf : l.bIf;
        final otherPort = mine ? l.bIf : l.aIf;
        b.writeln(
          '- `$myPort` <-> $other `$otherPort`'
          '${l.isSerial ? ' (serial WAN)' : ''}',
        );
      }
    }

    // The read-only commands that show these same facts on the device.
    b.writeln();
    b.writeln('See it for yourself (read-only):');
    b.writeln(
      '- `show ip interface brief` - every interface, its address and '
      'its state.',
    );
    if (node.type == 'router') {
      b.writeln(
        '- `show ip route` - the networks it knows, and how it learned '
        'them.',
      );
    }
    if (node.type == 'switch') {
      b.writeln('- `show vlan brief` - the VLANs and the ports in each.');
      b.writeln(
        '- `show cdp neighbors` - the devices on the other end of its '
        'cables.',
      );
    }
    if (roles.isNotEmpty) {
      b.writeln(
        '- Its service panels (Services tab) hold the '
        '${roles.join('/')} settings.',
      );
    }
    return b.toString().trimRight();
  }

  static String _kindName(String type) {
    const names = {
      'router': 'router',
      'switch': 'switch',
      'pc': 'PC',
      'server': 'server',
      'firewall': 'firewall (ASA)',
      'wireless': 'access point',
      'wireless-router': 'wireless router',
      'cloud': 'ISP/cloud connection',
      'modem': 'modem',
      'printer': 'printer',
      'phone': 'IP phone',
      'laptop': 'laptop',
      'tablet': 'tablet',
      'smartphone': 'smartphone',
      'tv': 'smart TV',
      'wlc': 'wireless LAN controller',
    };
    return names[type] ?? type;
  }
}
