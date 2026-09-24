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
      // IPv6: unicast-routing plus spelled-out addresses on router
      // interfaces; endpoints get SLAAC from the advertisements these
      // lines trigger, so only router interfaces need configured addresses.
      final hasV6 = addrs.any((a) => a.ip6Cidr != null);
      if (n.type == 'router' && hasV6) {
        sb.writeln('ipv6 unicast-routing');
        for (final a in addrs.where((a) => a.ip6Cidr != null)) {
          sb.writeln('interface ${a.iface}');
          sb.writeln(' ipv6 address ${a.ip6Cidr}');
          sb.writeln(' ipv6 enable');
          if (intent.routing == 'ospf') {
            sb.writeln(' ipv6 ospf 1 area 0');
          }
          sb.writeln('exit');
        }
        if (intent.routing == 'ospf') {
          sb.writeln('ipv6 router ospf 1');
          sb.writeln(' router-id ${_netHost(addrs.first.ipCidr)}');
          sb.writeln('exit');
        }
      }
      if (n.type == 'router') {
        _renderStaticRoutes(sb, intent, n);
        // A firewall on the WAN edge is the LAN's default way out: without
        // a default route through it the ASA sits in path but carries no
        // traffic and the internet access a brief asked for is dead.  This
        // runs for EVERY router, security request or not - which is why it
        // lives here and not inside _renderSecurity.
        final fwPeer = _firewallTransit(intent, n.name);
        if (fwPeer != null && (intent.routing == 'static')) {
          sb.writeln('ip route 0.0.0.0 0.0.0.0 ${fwPeer.$2}');
        }
        _renderEdgeNat(sb, intent, n);
      }
      // Switches get the layer-2 half of this (port security, snooping),
      // routers the AAA/ACL/VPN half - so the call stays outside the
      // router guard above.
      _renderSecurity(sb, intent, n);
      sb.writeln('end');
      sb.writeln('write memory');
      out[n.name] = sb.toString();
    }
    return out;
  }

  /// Static routing between the routers of a multi-router plan.
  ///
  /// A two-site plan with no routing protocol gets each router an address on
  /// its own LAN and on the transit link and nothing else, so the PCs are
  /// addressed correctly and still cannot reach the far site.  One route per
  /// remote LAN, via the transit address of the router that owns it, is what
  /// makes "2 routers 2 switches ... and 4 pcs" a network rather than two
  /// islands.  When a routing protocol was asked for, the protocol block
  /// already covers this and nothing is written here.
  static void _renderStaticRoutes(
    StringBuffer sb,
    NetworkIntent intent,
    NetNode device,
  ) {
    if (intent.routing != 'static' && intent.routing != 'none') return;
    // The IPSec block below writes the route to the remote VPN LAN itself.
    if (intent.security.requested && intent.security.ipsecVpn) return;

    bool isRouter(String name) =>
        intent.nodes.any((n) => n.name == name && n.type == 'router');
    String? ipOn(String node, String iface) {
      for (final a in intent.addressing) {
        if (a.node != node) continue;
        if (_normIface(a.iface) != _normIface(iface)) continue;
        final ip = a.ipCidr.split('/').first;
        if (ip != '0.0.0.0') return ip;
      }
      return null;
    }

    // Directly reachable routers and the address on the far end of the wire.
    final nextHop = <String, String>{};
    for (final l in intent.links) {
      if (!isRouter(l.a) || !isRouter(l.b)) continue;
      final peer = l.a == device.name ? l.b : (l.b == device.name ? l.a : null);
      if (peer == null) continue;
      final hop = ipOn(peer, l.a == device.name ? l.bIf : l.aIf);
      if (hop != null) nextHop[peer] = hop;
    }
    if (nextHop.isEmpty) return;

    // Routers further along the transit chain are reached through the same
    // first hop: R1 : R2 : R3 means R1 reaches R3's LAN via R2's near address.
    final reachable = <String, String>{...nextHop};
    final queue = [...nextHop.keys];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final l in intent.links) {
        if (!isRouter(l.a) || !isRouter(l.b)) continue;
        final other = l.a == current ? l.b : (l.b == current ? l.a : null);
        if (other == null || other == device.name) continue;
        if (reachable.containsKey(other)) continue;
        reachable[other] = nextHop[current]!;
        queue.add(other);
      }
    }

    // A router's LAN subnets are its addresses that are not on a transit
    // (router-to-router) link; its transit address is the next hop, not a
    // destination.
    bool onTransitLink(String node, String iface) => intent.links.any((l) {
      if (!isRouter(l.a) || !isRouter(l.b)) return false;
      final spec = l.a == node ? l.aIf : (l.b == node ? l.bIf : null);
      return spec != null && _normIface(spec) == _normIface(iface);
    });

    final emitted = <String>{};
    final routes = <String>[];
    for (final remote in reachable.keys) {
      for (final a in intent.addressing) {
        if (a.node != remote) continue;
        if (onTransitLink(remote, a.iface)) continue;
        final parts = a.ipCidr.split('/');
        final prefix = int.tryParse(parts.length > 1 ? parts[1] : '24') ?? 24;
        final network = _netBase(a.ipCidr);
        final mask = _mask(prefix);
        if (!emitted.add('$network/$mask')) continue;
        routes.add(' $network $mask ${reachable[remote]}');
      }
    }
    if (routes.isEmpty) return;
    sb.writeln('! Static routing: one route per remote LAN');
    for (final r in routes) {
      sb.writeln('ip route$r');
    }
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
        final isRadius = s.aaaProtocol.trim().toLowerCase().startsWith(
          'radius',
        );
        // The legacy one-line server syntax is what PT's ISR images accept;
        // the newer `aaa server` named form is often rejected.  The key MUST
        // match the server-side AAA client entry, and PacketTracerAdapter
        // defaults that key to 'cisco' when the user supplied none - so the
        // router side defaults to the same value rather than omitting the
        // key (a keyless router cannot authenticate against a keyed server).
        final key = (s.aaaPassword != null && s.aaaPassword!.isNotEmpty)
            ? s.aaaPassword!
            : 'cisco';
        sb.writeln('aaa new-model');
        if (isRadius) {
          sb.writeln('radius-server host $aaaIp key $key');
          sb.writeln('aaa authentication login default group radius local');
          sb.writeln('aaa authorization exec default group radius local');
        } else {
          sb.writeln('tacacs-server host $aaaIp');
          sb.writeln('tacacs-server key $key');
          sb.writeln('aaa authentication login default group tacacs+ local');
          sb.writeln('aaa authorization exec default group tacacs+ local');
        }
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

    if (s.extendedAcl && s.protectedServerIp != null) {
      if (device.name == 'BR_Router' && s.branchNetwork != null) {
        // The security-lab profile names the ACL and interface explicitly.
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
      } else {
        // Generic plans: guard the protected server on every router that
        // has a WAN (router-to-router) interface.  Each remote LAN is the
        // source, web access is kept when an allowed web server is named.
        final wanIfaces = intent.addressing
            .where((a) => a.node == device.name)
            .where((a) => _onTransitLink(intent, device.name, a.iface))
            .toList();
        final remoteLans = <(String, String)>[];
        for (final a in intent.addressing) {
          final owner = intent.nodes.firstWhere(
            (n) => n.name == a.node,
            orElse: () => const NetNode(name: '', type: ''),
          );
          if (owner.type != 'router' || owner.name == device.name) continue;
          if (_onTransitLink(intent, a.node, a.iface)) continue;
          final entry = _networkAndWildcard(a.ipCidr);
          if (!remoteLans.contains(entry)) remoteLans.add(entry);
        }
        if (wanIfaces.isNotEmpty && remoteLans.isNotEmpty) {
          sb.writeln('ip access-list extended PROTECTED_SERVER');
          for (final (net, wild) in remoteLans) {
            if (s.allowedWebServerIp != null) {
              sb.writeln(
                ' permit tcp $net $wild host ${s.allowedWebServerIp} eq 80',
              );
            }
            sb.writeln(' deny ip $net $wild host ${s.protectedServerIp}');
          }
          sb.writeln(' permit ip any any');
          sb.writeln('exit');
          for (final a in wanIfaces) {
            sb.writeln('interface ${a.iface}');
            sb.writeln(' ip access-group PROTECTED_SERVER out');
            sb.writeln('exit');
          }
        }
      }
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
      // Packet Tracer ships the IPsec feature set, but an ISR image only
      // accepts the crypto commands once the Security Technology package is
      // licensed.  These are `!` comments, so the live executor never types
      // them; they are the note that makes the block usable by hand, and they
      // travel inside the generated .pkt's running config.
      sb.writeln('! Site-to-site IPSec');
      sb.writeln('! Packet Tracer needs the Security Technology package for the');
      sb.writeln('! crypto commands below. Enable it once, then reload:');
      sb.writeln('!   license boot module c2900 technology-package securityk9');
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

  /// The firewall on this device's WAN edge and its address, or null.
  ///
  /// Returns (firewallName, firewallIP): the address the router must reach
  /// to send traffic through the ASA.
  static (String, String)? _firewallTransit(
    NetworkIntent intent,
    String router,
  ) {
    for (final l in intent.links) {
      final other = l.a == router ? l.b : (l.b == router ? l.a : null);
      if (other == null) continue;
      final isFw = intent.nodes.any(
        (n) => n.name == other && n.type == 'firewall',
      );
      if (!isFw) continue;
      for (final a in intent.addressing) {
        if (a.node == other && a.ipCidr.split('/').first != '0.0.0.0') {
          return (other, a.ipCidr.split('/').first);
        }
      }
    }
    return null;
  }

  /// True when this node+interface sits on a router-to-router link.
  static bool _onTransitLink(NetworkIntent intent, String node, String iface) {
    for (final l in intent.links) {
      final aIsRouter = intent.nodes.any(
        (n) => n.name == l.a && n.type == 'router',
      );
      final bIsRouter = intent.nodes.any(
        (n) => n.name == l.b && n.type == 'router',
      );
      if (!aIsRouter || !bIsRouter) continue;
      final spec = l.a == node ? l.aIf : (l.b == node ? l.bIf : null);
      if (spec != null && _normIface(spec) == _normIface(iface)) return true;
    }
    return false;
  }

  /// ASA running-config for every firewall node (PT's ISA-3000 image).
  ///
  /// ASA syntax is NOT IOS - that is why firewalls are outside `cliTypes` -
  /// but the generated .pkt stores this text in the device the same way the
  /// IOS configs are stored, so the firewall is genuinely configured in the
  /// file the user opens.  Inside faces the neighbour router (the transit
  /// subnet the parser addressed), outside faces the cloud/upstream when one
  /// was linked.
  static Map<String, String> firewallConfigs(NetworkIntent intent) {
    final out = <String, String>{};
    for (final fw in intent.nodes.where((n) => n.type == 'firewall')) {
      final sb = StringBuffer();
      sb.writeln('hostname ${fw.name}');
      sb.writeln('!');
      String? insideIp;
      String? insideMask;
      String? insideIface;
      String? routerName;
      var outsideWritten = false;
      for (final l in intent.links) {
        if (l.a != fw.name && l.b != fw.name) continue;
        final other = l.a == fw.name ? l.b : l.a;
        final otherIsRouter = intent.nodes.any(
          (n) => n.name == other && n.type == 'router',
        );
        final fwIf = l.a == fw.name ? l.aIf : l.bIf;
        final addr = intent.addressing.firstWhere(
          (a) => a.node == fw.name &&
              _normIface(a.iface) == _normIface(fwIf),
          orElse: () => const InterfaceAddr(
            node: '',
            iface: '',
            ipCidr: '0.0.0.0/24',
          ),
        );
        if (otherIsRouter && addr.ipCidr != '0.0.0.0/24') {
          insideIface = _fullAsaIface(fwIf);
          insideIp = addr.ipCidr.split('/').first;
          insideMask = _mask(_prefix(addr.ipCidr));
          routerName = other;
        } else if (!otherIsRouter && !outsideWritten) {
          // Everything that is not the inside router is the untrusted side
          // (a cloud/modem upstream, or another firewall leg).
          outsideWritten = true;
          sb.writeln('interface ${_fullAsaIface(fwIf)}');
          sb.writeln(' nameif outside');
          sb.writeln(' security-level 0');
          sb.writeln(' ip address 172.16.2.1 255.255.255.252');
          sb.writeln(' no shutdown');
          sb.writeln('exit');
          sb.writeln('route outside 0.0.0.0 0.0.0.0 172.16.2.2 1');
        }
      }
      if (insideIface != null) {
        sb.writeln('interface $insideIface');
        sb.writeln(' nameif inside');
        sb.writeln(' security-level 100');
        sb.writeln(' ip address $insideIp $insideMask');
        sb.writeln(' no shutdown');
        sb.writeln('exit');
        // Every LAN the neighbour router serves is reached through it.
        for (final a in intent.addressing) {
          final owner = intent.nodes.firstWhere(
            (n) => n.name == a.node,
            orElse: () => const NetNode(name: '', type: ''),
          );
          if (owner.name != routerName) continue;
          if (_onTransitLink(intent, a.node, a.iface)) continue;
          final net = _netBase(a.ipCidr);
          final mask = _mask(_prefix(a.ipCidr));
          sb.writeln('route inside $net $mask ${_routerSideOf(intent, fw.name)}');
        }
      }
      // Named access policy from the plan's security intent, mirroring the
      // router-side PROTECTED_SERVER ACL but in ASA syntax: inside users may
      // reach the web server, everything else to the protected host drops.
      final s = intent.security;
      if (s.extendedAcl && s.protectedServerIp != null) {
        sb.writeln('access-list INSIDE_POLICY extended permit tcp any host ${s.allowedWebServerIp ?? s.protectedServerIp} eq www');
        if (s.allowedWebServerIp != null &&
            s.allowedWebServerIp != s.protectedServerIp) {
          sb.writeln('access-list INSIDE_POLICY extended deny ip any host ${s.protectedServerIp}');
        }
        sb.writeln('access-list INSIDE_POLICY extended permit ip any any');
        sb.writeln('access-group INSIDE_POLICY in interface inside');
      }
      if (s.managerIp != null) {
        sb.writeln('access-list MGMT_ONLY extended permit ip host ${s.managerIp} any');
        sb.writeln('access-list MGMT_ONLY extended deny ip any any');
        sb.writeln('access-group MGMT_ONLY in interface outside');
      }

      // NAT: hide the inside LANs behind the ASA's outside address when an
      // upstream exists and the plan asked for extended policy (proxy for
      // "this edge does address translation").
      if (outsideWritten && s.extendedAcl) {
        final nets = <String>{};
        for (final a in intent.addressing) {
          final owner = intent.nodes.firstWhere(
            (n) => n.name == a.node,
            orElse: () => const NetNode(name: '', type: ''),
          );
          if (owner.type != 'router') continue;
          if (_onTransitLink(intent, a.node, a.iface)) continue;
          nets.add(_netBase(a.ipCidr));
        }
        if (nets.isNotEmpty) {
          sb.writeln('object network INSIDE_LANS');
          for (final net in nets) {
            sb.writeln(' subnet $net ${_mask(_prefix('$net/24'))}');
          }
          sb.writeln(' nat (inside,outside) dynamic interface');
          sb.writeln('exit');
        }
      }

      // Inspections so return traffic (DNS, ICMP) passes the ASA statefully.
      sb.writeln('class-map inspection_default');
      sb.writeln(' match default-inspection-traffic');
      sb.writeln('exit');
      sb.writeln('policy-map global_policy');
      sb.writeln(' class inspection_default');
      sb.writeln('  inspect dns preset_dns_map');
      sb.writeln('  inspect icmp');
      sb.writeln('exit');
      sb.writeln('service-policy global_policy global');
      sb.writeln('end');
      sb.writeln('write memory');
      out[fw.name] = sb.toString();
    }
    return out;
  }

  /// Cisco Unified CME config for the voice gateway router.  Phones are
  /// type 'phone' (7960); each gets an ephone-dn (line) with a directory
  /// number and an ephone bound to its MAC-pattern slot.  PT's 7960
  /// registers against `ip source-address` when its TFTP points here.
  static Map<String, String> voiceConfig(NetworkIntent intent) {
    final phones = intent.nodes
        .where((n) => n.type == 'phone')
        .toList();
    if (phones.isEmpty) return {};

    // The gateway is the router with the CME-carrying server on its LAN (or
    // simply the first router when the plan did not name one).
    String? gateway;
    for (final n in intent.nodes) {
      if (n.type != 'server' || !n.services.contains('cme')) continue;
      // A server on the same LAN segment as a router: its gateway is the
      // router's LAN address (see endpointIpConfig's gw walk).
      for (final l in intent.links) {
        if (l.a != n.name && l.b != n.name) continue;
        final mid = l.a == n.name ? l.b : l.a;
        for (final l2 in intent.links) {
          if (l2.a != mid && l2.b != mid) continue;
          final other = l2.a == mid ? l2.b : l2.a;
          final isRouter = intent.nodes.any(
            (x) => x.name == other && x.type == 'router',
          );
          if (isRouter) {
            gateway = other;
            break;
          }
        }
        if (gateway != null) break;
      }
      if (gateway != null) break;
    }
    gateway ??= intent.nodes.firstWhere(
      (n) => n.type == 'router',
      orElse: () => const NetNode(name: '', type: ''),
    ).name;
    if (gateway.isEmpty) return {};

    // Phones hang off a switch that hangs off the gateway; find the switch
    // so the voice VLAN can be attached to the right router interface.
    final gwName = gateway;
    final gwIface = intent.addressing
        .where((a) => a.node == gwName)
        .where((a) => !_onTransitLink(intent, gwName, a.iface))
        .map((a) => a.iface)
        .toList();

    final sb = StringBuffer();
    sb.writeln('! Cisco Unified CME: telephony service for ${phones.length} phone(s)');
    sb.writeln('telephony-service');
    sb.writeln(' max-ephones ${phones.length}');
    sb.writeln(' max-dn ${phones.length}');
    final srcIp = intent.addressing
        .where((a) => a.node == gwName)
        .map((a) => a.ipCidr.split('/').first)
        .where((ip) => ip != '0.0.0.0')
        .toList();
    sb.writeln(' ip source-address ${srcIp.isNotEmpty ? srcIp.first : '10.0.0.1'} port 2000');
    sb.writeln(' auto assign 1 to ${phones.length}');
    sb.writeln('exit');
    for (var i = 0; i < phones.length; i++) {
      final dn = 2001 + i;
      sb.writeln('ephone-dn $i');
      sb.writeln(' number $dn');
      sb.writeln('exit');
      sb.writeln('ephone ${i + 1}');
      sb.writeln(' mac-address ${_macForSeed(intent, phones[i].name)}');
      sb.writeln(' button 1:${i + 1}');
      sb.writeln('exit');
    }
    if (gwIface.isNotEmpty) {
      sb.writeln('interface ${gwIface.first}');
      sb.writeln(' auto assign 1 to ${phones.length}');
      sb.writeln('exit');
    }
    return {gateway: sb.toString()};
  }

  /// Deterministic fake MAC for an ephone binding (PT accepts any
  /// well-formed one; the executor's placed phone re-registers anyway).
  static String _macForSeed(NetworkIntent intent, String name) {
    var h = 0x04F2A1; // arbitrary prefix
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0xFFFFFF;
    }
    final s = h.toRadixString(16).padLeft(6, '0').toUpperCase();
    return '${s.substring(0, 4)}.${s.substring(4)}.${s.substring(0, 2)}11';
  }

  /// Edge NAT (PAT) on a router that sits between the LAN and an upstream
  /// (cloud/modem/server link on the same subnet).  The edge interface is
  /// 'outside', every LAN interface 'inside' - the classic overload setup -
  /// so private LANs reach the internet through one public address.
  static void _renderEdgeNat(
    StringBuffer sb,
    NetworkIntent intent,
    NetNode device,
  ) {
    // An edge interface is one whose peer is not a router (cloud, modem,
    // server, switch on a WAN handoff).  Transit to other routers is not an
    // edge, and a firewall transit is already NATed by the ASA itself.
    String? outsideIface;
    for (final a in intent.addressing.where((a) => a.node == device.name)) {
      for (final l in intent.links) {
        if (l.a != device.name && l.b != device.name) continue;
        final spec = l.a == device.name ? l.aIf : l.bIf;
        if (_normIface(spec) != _normIface(a.iface)) continue;
        final other = l.a == device.name ? l.b : l.a;
        final peerType = intent.nodes
            .firstWhere(
              (n) => n.name == other,
              orElse: () => const NetNode(name: '', type: ''),
            )
            .type;
        if (peerType == 'cloud' || peerType == 'modem') {
          outsideIface = a.iface;
        }
      }
    }
    final outside = outsideIface;
    if (outside == null) return;

    final lanIfaces = intent.addressing
        .where((a) => a.node == device.name)
        .where((a) => _normIface(a.iface) != _normIface(outside))
        .map((a) => a.iface)
        .toList();
    if (lanIfaces.isEmpty) return;

    sb.writeln('! Edge NAT: share the upstream address across the LAN');
    // One ACL can carry several permit lines - combine the LANs instead of
    // stacking lists, which IOS rejects on a single overload statement.
    final aclName = 'NAT_LANS';
    sb.writeln('ip access-list standard $aclName');
    for (final iface in lanIfaces) {
      final addr = intent.addressing.firstWhere(
        (a) => a.node == device.name && a.iface == iface,
      );
      final (net, wild) = _networkAndWildcard(addr.ipCidr);
      sb.writeln(' permit $net $wild');
    }
    sb.writeln('exit');
    sb.writeln('ip nat inside source list $aclName interface ${_normIface(outside)} overload');
    for (final iface in lanIfaces) {
      sb.writeln('interface $iface');
      sb.writeln(' ip nat inside');
      sb.writeln('exit');
    }
    sb.writeln('interface $outside');
    sb.writeln(' ip nat outside');
    sb.writeln('exit');
  }

  /// The neighbour router's address on the firewall transit.
  static String _routerSideOf(NetworkIntent intent, String fw) {
    for (final l in intent.links) {
      if (l.a != fw && l.b != fw) continue;
      final other = l.a == fw ? l.b : l.a;
      for (final a in intent.addressing) {
        if (a.node == other && a.ipCidr.split('/').first != '0.0.0.0') {
          return a.ipCidr.split('/').first;
        }
      }
    }
    return '0.0.0.0';
  }

  /// 'g1/1' -> 'GigabitEthernet1/1': the ASA spells interfaces in full.
  static String _fullAsaIface(String spec) {
    final t = spec.toLowerCase().trim();
    if (t.startsWith('g')) return 'GigabitEthernet${t.substring(1)}';
    if (t.startsWith('e')) return 'Ethernet${t.substring(1)}';
    return spec;
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
