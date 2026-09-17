import '../../models/network_intent.dart';

/// Compiles universal intent -> Cisco IOS running-config per device.
class CiscoAdapter {
  /// Device kinds with an IOS-style CLI in Packet Tracer.  Everything else
  /// (PC/server/laptop/printer via Desktop > IP Configuration, ASA and
  /// wireless devices via their own GUI) is configured another way, and
  /// typing IOS at it would only open tabs and land random clicks.
  static const Set<String> cliTypes = {'router', 'switch'};

  static Map<String, String> render(NetworkIntent intent) {
    final out = <String, String>{};
    for (final n in intent.nodes) {
      if (!cliTypes.contains(n.type)) continue;
      final sb = StringBuffer();
      sb.writeln('hostname ${n.name}');
      sb.writeln('no ip domain-lookup');
      sb.writeln('service password-encryption');
      sb.writeln('!');
      final addrs = intent.addressing.where((a) => a.node == n.name).toList();
      for (final a in addrs) {
        sb.writeln('interface ${a.iface}');
        sb.writeln(' description to-${_peerOf(intent, n.name, a.iface)}');
        sb.writeln(
          ' ip address ${_netHost(a.ipCidr)} ${_mask(_prefix(a.ipCidr))}',
        );
        if (isDceSerial(intent, n.name, a.iface)) {
          // Packet Tracer rejects a serial interface without a clock rate on
          // the DCE end (and rejects one WITH it on the DTE end), so this
          // must agree with the cable the executor picks.
          sb.writeln(' clock rate 64000');
        }
        sb.writeln(' no shutdown');
        sb.writeln('exit');
      }
      if (n.type == 'switch') {
        for (final v in intent.vlans) {
          sb.writeln('vlan $v');
          sb.writeln(' name VLAN$v');
          sb.writeln('exit');
        }
      }
      if (n.type == 'router' && intent.routing == 'ospf') {
        sb.writeln('router ospf 1');
        for (final a in addrs) {
          // proper network + wildcard from the SUBNET, not the host IP
          sb.writeln(
            ' network ${_netBase(a.ipCidr)} ${_wildcard(_prefix(a.ipCidr))} area 0',
          );
        }
        sb.writeln('exit');
      }
      _renderSecurity(sb, intent, n);
      sb.writeln('end');
      sb.writeln('write memory');
      out[n.name] = sb.toString();
    }
    return out;
  }

  static void _renderSecurity(
    StringBuffer sb,
    NetworkIntent intent,
    NetNode device,
  ) {
    final s = intent.security;
    if (!s.requested) return;

    if (device.type == 'switch') {
      if (s.portSecurity) {
        sb.writeln(
          '! Port security: one MAC per user port, shutdown on violation',
        );
        sb.writeln('interface range f0/2 - 24');
        sb.writeln(' switchport mode access');
        sb.writeln(' switchport port-security');
        sb.writeln(' switchport port-security maximum 1');
        sb.writeln(' switchport port-security violation shutdown');
        if (s.dhcpSnooping) {
          sb.writeln(' ip dhcp snooping limit rate 10');
        }
        sb.writeln('exit');
      }
      if (s.dhcpSnooping) {
        sb.writeln('! DHCP snooping; the router uplink is trusted');
        sb.writeln('ip dhcp snooping');
        sb.writeln('ip dhcp snooping vlan 1');
        sb.writeln('interface ${s.dhcpTrustedInterface ?? 'f0/1'}');
        sb.writeln(' ip dhcp snooping trust');
        sb.writeln('exit');
      }
      return;
    }
    if (device.type != 'router') return;

    final lan = intent.addressing
        .where(
          (a) => a.node == device.name && a.iface.toLowerCase().contains('g'),
        )
        .toList();
    final dhcpIp = _findNodeIp(intent, 'DHCP1');
    if (dhcpIp != null && lan.isNotEmpty) {
      for (final a in lan) {
        sb.writeln('interface ${a.iface}');
        sb.writeln(' ip helper-address $dhcpIp');
        sb.writeln('exit');
      }
    }

    if (s.aaa && device.name == (s.aaaRouter ?? device.name)) {
      final aaaIp = _findNodeIp(intent, s.aaaServer ?? '');
      if (aaaIp != null) {
        sb.writeln('aaa new-model');
        // Packet Tracer's 2911 image accepts the legacy TACACS+ syntax more
        // consistently than the newer named-server form.
        sb.writeln('tacacs-server host $aaaIp');
        if (s.aaaPassword != null && s.aaaPassword!.isNotEmpty) {
          sb.writeln('tacacs-server key ${s.aaaPassword}');
        }
        sb.writeln('aaa authentication login default group tacacs+ local');
        sb.writeln('aaa authorization exec default group tacacs+ local');
      }
      if (s.telnet) {
        sb.writeln('line vty 0 4');
        sb.writeln(' login authentication default');
        sb.writeln(' transport input telnet');
        sb.writeln('exit');
      }
      if (s.managerIp != null) {
        sb.writeln('time-range OFFICE_HOURS');
        sb.writeln(' periodic weekdays ${_hours(s.officeHours)}');
        sb.writeln('exit');
        sb.writeln('ip access-list standard VTY_MANAGER_ONLY');
        sb.writeln(' permit host ${s.managerIp} time-range OFFICE_HOURS');
        sb.writeln(' deny any');
        sb.writeln('exit');
        sb.writeln('line vty 0 4');
        sb.writeln(' access-class VTY_MANAGER_ONLY in');
        sb.writeln('exit');
      }
    }

    if (s.extendedAcl &&
        device.name == 'BR_Router' &&
        s.branchNetwork != null &&
        s.protectedServerIp != null) {
      final branch = _networkAndWildcard(s.branchNetwork!);
      sb.writeln('ip access-list extended BRANCH_TO_HQ');
      if (s.allowedWebServerIp != null) {
        sb.writeln(
          ' permit tcp ${branch.$1} ${branch.$2} host ${s.allowedWebServerIp} eq 80',
        );
      }
      sb.writeln(
        ' deny ip ${branch.$1} ${branch.$2} host ${s.protectedServerIp}',
      );
      sb.writeln(' permit ip any any');
      sb.writeln('exit');
      sb.writeln('interface s0/0/0');
      sb.writeln(' ip access-group BRANCH_TO_HQ out');
      sb.writeln('exit');
    }

    if (s.ipsecVpn &&
        s.vpnPeerA != null &&
        s.vpnPeerB != null &&
        s.vpnLocalNetwork != null &&
        s.vpnRemoteNetwork != null) {
      final local = _networkAndWildcard(s.vpnLocalNetwork!);
      final remote = _networkAndWildcard(s.vpnRemoteNetwork!);
      final peer = device.name == 'HQ_Router' ? s.vpnPeerB : s.vpnPeerA;
      final sideLocal = device.name == 'HQ_Router' ? local : remote;
      final sideRemote = device.name == 'HQ_Router' ? remote : local;
      sb.writeln('! Site-to-site IPSec');
      sb.writeln('crypto isakmp policy 10');
      sb.writeln(' encr ${s.vpnEncryption ?? 'aes'}');
      sb.writeln(' hash ${s.vpnHash ?? 'sha'}');
      sb.writeln(' authentication pre-share');
      sb.writeln(' group 5');
      sb.writeln('exit');
      if (s.vpnPreSharedKey != null && s.vpnPreSharedKey!.isNotEmpty) {
        sb.writeln('crypto isakmp key ${s.vpnPreSharedKey} address $peer');
      } else {
        sb.writeln(
          '! IPSec pre-shared key not supplied; tunnel is intentionally incomplete',
        );
      }
      sb.writeln(
        'crypto ipsec transform-set SITE_VPN_SET esp-aes esp-sha-hmac',
      );
      sb.writeln('exit');
      sb.writeln('ip access-list extended SITE_VPN_TRAFFIC');
      sb.writeln(
        ' permit ip ${sideLocal.$1} ${sideLocal.$2} ${sideRemote.$1} ${sideRemote.$2}',
      );
      sb.writeln('exit');
      if (s.vpnPreSharedKey != null && s.vpnPreSharedKey!.isNotEmpty) {
        sb.writeln('crypto map SITE_VPN 10 ipsec-isakmp');
        sb.writeln(' set peer $peer');
        sb.writeln(' set transform-set SITE_VPN_SET');
        sb.writeln(' match address SITE_VPN_TRAFFIC');
        sb.writeln('exit');
        sb.writeln('interface s0/0/0');
        sb.writeln(' crypto map SITE_VPN');
        sb.writeln('exit');
      }
      sb.writeln(
        'ip route ${sideRemote.$1} ${_maskFromWildcard(sideRemote.$2)} $peer',
      );
    }
  }

  /// True when this interface is the clocking (DCE) end of a serial link.
  ///
  /// The rule is the executor's own: the link's `dce` hint wins, otherwise
  /// the 'a' endpoint clocks.  Keeping the two in one decision is what makes
  /// "the DCE side carries `clock rate`" true on both sides of the wire.
  static bool isDceSerial(NetworkIntent intent, String node, String iface) {
    for (final l in intent.links) {
      if (!l.isSerial) continue;
      final onA = l.a == node && _normIface(l.aIf) == _normIface(iface);
      final onB = l.b == node && _normIface(l.bIf) == _normIface(iface);
      if (!onA && !onB) continue;
      return l.dceEnd == (onA ? 'a' : 'b');
    }
    return false;
  }

  /// 'GigabitEthernet0/1' and 'g0/1' are the same interface, and so are
  /// 'Serial0/0/0' and 's0/0/0' - the plan and the config disagree on the
  /// long form all the time.
  static String _normIface(String spec) {
    var t = spec.toLowerCase().replaceAll(' ', '');
    for (final full in const [
      'gigabitethernet',
      'fastethernet',
      'serial',
      'ethernet',
    ]) {
      if (t.startsWith(full)) return '${full[0]}${t.substring(full.length)}';
    }
    return t;
  }

  static String? _findNodeIp(NetworkIntent intent, String node) {
    for (final a in intent.addressing) {
      if (a.node == node) return a.ipCidr.split('/').first;
    }
    return null;
  }

  static String _hours(String? value) {
    final m = RegExp(
      r'(\d{1,2}:\d{2})-(\d{1,2}:\d{2})',
    ).firstMatch(value ?? '');
    return m == null ? '08:00 to 17:00' : '${m.group(1)} to ${m.group(2)}';
  }

  static (String, String) _networkAndWildcard(String cidr) {
    final prefix = _prefix(cidr);
    return (_netBase(cidr), _wildcard(prefix));
  }

  static String _maskFromWildcard(String wildcard) {
    final octets = wildcard.split('.').map((e) => 255 - int.parse(e));
    return octets.join('.');
  }

  static String _peerOf(NetworkIntent intent, String node, String iface) {
    for (final l in intent.links) {
      if (l.a == node && l.aIf == iface) return l.b;
      if (l.b == node && l.bIf == iface) return l.a;
    }
    return 'net';
  }

  static int _prefix(String cidr) {
    final p = cidr.split('/');
    return p.length > 1 ? (int.tryParse(p[1]) ?? 24) : 24;
  }

  static String _netHost(String cidr) => cidr.split('/')[0];

  static String _netBase(String cidr) {
    final prefixLen = _prefix(cidr);
    final parts = cidr
        .split('/')[0]
        .split('.')
        .map((s) => int.parse(s))
        .toList();
    final ip32 =
        (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
    final mask = prefixLen == 0 ? 0 : (0xFFFFFFFF << (32 - prefixLen));
    final net = ip32 & mask;
    return '${(net >> 24) & 255}.${(net >> 16) & 255}.${(net >> 8) & 255}.${net & 255}';
  }

  static String _mask(int prefix) => _bits(_fullMask(prefix));

  static String _wildcard(int prefix) => _bits(~_fullMask(prefix));

  static int _fullMask(int prefix) =>
      prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix));

  static String _bits(int v) =>
      '${(v >> 24) & 255}.${(v >> 16) & 255}.${(v >> 8) & 255}.${v & 255}';
}
