import 'session_state.dart';

/// Names a conversation from the first thing the user asked.
///
/// Deliberately deterministic and offline: a title is needed the moment the
/// first answer lands, it must never be the reason a turn is slow, and a model
/// hallucinating a subject for the chat is worse than a plain one. The result
/// is short and specific - "PC1 Gateway Problem", "OSPF Troubleshooting",
/// "office-network Network Analysis" - because that is what a person scans a
/// list for. The user can always rename it.
class ConversationTitles {
  const ConversationTitles._();

  /// What the chat is about, when the wording says so. Order matters: the
  /// first match wins, so the more specific protocol names come before the
  /// broader ones.
  static const _topics = <String, String>{
    'ospf': 'OSPF',
    'eigrp': 'EIGRP',
    'bgp': 'BGP',
    'rip': 'RIP',
    'vlan': 'VLAN',
    'vlans': 'VLAN',
    'trunk': 'Trunking',
    'etherchannel': 'EtherChannel',
    'lacp': 'EtherChannel',
    'spanning-tree': 'Spanning-Tree',
    'spanning tree': 'Spanning-Tree',
    'stp': 'Spanning-Tree',
    'hsrp': 'HSRP',
    'acl': 'ACL',
    'nat': 'NAT',
    'dhcp': 'DHCP',
    'dns': 'DNS',
    'aaa': 'AAA',
    'tacacs': 'AAA',
    'radius': 'AAA',
    'ipsec': 'IPsec VPN',
    'vpn': 'VPN',
    'ssh': 'SSH',
    'telnet': 'Telnet',
    'ipv6': 'IPv6',
    'subnet': 'Subnetting',
    'gateway': 'Gateway',
    'ping': 'Connectivity',
    'unreachable': 'Connectivity',
    'traceroute': 'Connectivity',
    'wireless': 'Wireless',
    'firewall': 'Firewall',
  };

  /// The most useful title this first message can produce.
  static String generate(String firstMessage) {
    final raw = firstMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (raw.isEmpty) return 'New chat';

    final lower = raw.toLowerCase();
    final devices = SessionState.devicesIn(raw);
    final topic = _topicIn(lower);
    final project = _projectIn(raw);

    if (project != null) {
      return '$project Network Analysis';
    }
    if (topic != null && devices.isNotEmpty) {
      return '${devices.first} $topic Problem';
    }
    if (topic != null) return '$topic Troubleshooting';
    if (devices.isNotEmpty) {
      return devices.length == 1
          ? '${devices.first} Problem'
          : '${devices.take(2).join(' and ')} Problem';
    }
    return _fallback(raw);
  }

  static String? _topicIn(String lower) {
    String? best;
    var bestAt = 1 << 30;
    _topics.forEach((word, label) {
      final at = lower.indexOf(word);
      if (at >= 0 && at < bestAt) {
        bestAt = at;
        best = label;
      }
    });
    return best;
  }

  /// A `.pkt`/project name in the sentence, e.g. "analyze office-network.pkt".
  static String? _projectIn(String raw) {
    final match = RegExp(
      r'([A-Za-z0-9][A-Za-z0-9_.\- ]{1,40})\.pkt\b',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) return null;
    final name = match.group(1)!.trim();
    return name.isEmpty ? null : _title(name);
  }

  /// No structure to lean on: the user's own words, cut at a word boundary.
  static String _fallback(String raw) {
    var text = raw;
    for (final opener in const [
      'please ',
      'can you ',
      'could you ',
      'i want to ',
      'i need to ',
      'help me ',
      'tell me ',
      'show me ',
      'how do i ',
      'what is ',
      'what are ',
    ]) {
      if (text.toLowerCase().startsWith(opener)) {
        text = text.substring(opener.length);
        break;
      }
    }
    text = text.replaceAll(RegExp(r'[.?!]+$'), '').trim();
    if (text.length > 44) {
      final cut = text.substring(0, 44);
      final space = cut.lastIndexOf(' ');
      text = '${space > 20 ? cut.substring(0, space) : cut}...';
    }
    return _title(text);
  }

  static String _title(String text) {
    if (text.isEmpty) return 'New chat';
    return text[0].toUpperCase() + text.substring(1);
  }
}
