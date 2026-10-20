import 'dart:ui' show Offset;

import '../models/network_intent.dart';
import 'packet_tracer/catalog.dart';

class AutoWireResult {
  final NetworkIntent intent;
  final List<NetLink> added;
  final List<String> notConnected;

  const AutoWireResult({
    required this.intent,
    required this.added,
    required this.notConnected,
  });
}

/// Applies a device name/address edit without dropping interface-level data.
/// The first IPv4 row is treated as the primary address shown in the editor;
/// every other IPv4/IPv6 row remains attached to its interface.
class TopologyEditService {
  const TopologyEditService._();

  static NetworkIntent editDevice({
    required NetworkIntent intent,
    required String oldName,
    required String newName,
    required String primaryIpv4,
    required String fallbackInterface,
  }) {
    final node = intent.nodes.where((n) => n.name == oldName).firstOrNull;
    if (node == null) throw ArgumentError.value(oldName, 'oldName');

    final selectedAddress = intent.addressing.indexWhere(
      (address) => address.node == oldName,
    );
    final nodes = intent.nodes
        .map(
          (n) => n.name != oldName
              ? n
              : NetNode(
                  name: newName,
                  type: n.type,
                  model: n.model,
                  exactModel: n.exactModel,
                  modules: n.modules,
                  mgmtIp: n.mgmtIp,
                  services: n.services,
                  serviceRules: n.serviceRules,
                ),
        )
        .toList();
    final links = intent.links
        .map(
          (link) => NetLink(
            a: link.a == oldName ? newName : link.a,
            aIf: link.aIf,
            b: link.b == oldName ? newName : link.b,
            bIf: link.bIf,
            cable: link.cable,
            exactPorts: link.exactPorts,
            dce: link.dce == oldName ? newName : link.dce,
          ),
        )
        .toList();

    final addresses = <InterfaceAddr>[];
    for (var i = 0; i < intent.addressing.length; i++) {
      final address = intent.addressing[i];
      if (address.node != oldName) {
        addresses.add(address);
      } else if (i != selectedAddress || primaryIpv4.isNotEmpty) {
        addresses.add(
          InterfaceAddr(
            node: newName,
            iface: address.iface,
            ipCidr: i == selectedAddress ? primaryIpv4 : address.ipCidr,
            ip6Cidr: address.ip6Cidr,
          ),
        );
      }
    }
    if (selectedAddress < 0 && primaryIpv4.isNotEmpty) {
      addresses.add(
        InterfaceAddr(
          node: newName,
          iface: fallbackInterface,
          ipCidr: primaryIpv4,
        ),
      );
    }

    final layout = Map<String, Offset?>.from(intent.layout);
    if (newName != oldName && layout.containsKey(oldName)) {
      layout[newName] = layout.remove(oldName);
    }
    final securityJson = intent.security.toJson();
    for (final field in const [
      'aaaServer',
      'aaaRouter',
      'vpnPeerA',
      'vpnPeerB',
    ]) {
      if (securityJson[field] == oldName) securityJson[field] = newName;
    }

    return intent.copyWith(
      nodes: nodes,
      links: links,
      addressing: addresses,
      layout: layout,
      security: SecurityIntent.fromJson(securityJson),
    );
  }

  static Map<String, Offset?> moveGroup({
    required Map<String, Offset?> layout,
    required Set<String> selected,
    required Offset delta,
  }) => {
    for (final entry in layout.entries)
      entry.key: selected.contains(entry.key) && entry.value != null
          ? entry.value! + delta
          : entry.value,
  };

  /// Wires the selected devices as one connected tree, choosing exact free
  /// ports and the first compatible Packet Tracer cable template for each hop.
  /// Devices the catalog cannot connect remain listed in [notConnected].
  static AutoWireResult autoWire(NetworkIntent intent, Set<String> selected) {
    final names = intent.nodes
        .where((node) => selected.contains(node.name))
        .map((node) => node.name)
        .toList();
    if (names.length < 2) {
      return AutoWireResult(
        intent: intent,
        added: const [],
        notConnected: names,
      );
    }

    final byName = {for (final node in intent.nodes) node.name: node};
    final added = <NetLink>[];
    final connected = <String>{names.first};
    while (connected.length < names.length) {
      var linked = false;
      for (final a in connected.toList()) {
        for (final b in names.where((name) => !connected.contains(name))) {
          if (_alreadyConnected(intent.links + added, a, b)) continue;
          final nodeA = byName[a], nodeB = byName[b];
          if (nodeA == null || nodeB == null) continue;
          for (final cable in _cableOrder(nodeA, nodeB)) {
            final portsA = _freePorts(intent, added, nodeA, cable);
            final portsB = _freePorts(intent, added, nodeB, cable);
            NetLink? chosen;
            for (final portA in portsA) {
              for (final portB in portsB) {
                if (cable.mismatch(
                      portA,
                      portB,
                      modulesA: nodeA.modules,
                      modulesB: nodeB.modules,
                    ) !=
                    null) {
                  continue;
                }
                chosen = NetLink(
                  a: a,
                  aIf: portA.name,
                  b: b,
                  bIf: portB.name,
                  cable: cable.id,
                  exactPorts: true,
                  dce: cable.id.startsWith('serial') ? 'a' : null,
                );
                break;
              }
              if (chosen != null) break;
            }
            if (chosen != null) {
              added.add(chosen);
              connected.add(b);
              linked = true;
              break;
            }
          }
          if (linked) break;
        }
        if (linked) break;
      }
      if (!linked) break;
    }

    return AutoWireResult(
      intent: added.isEmpty ? intent : intent.copyWith(links: [...intent.links, ...added]),
      added: List.unmodifiable(added),
      notConnected: names.where((name) => !connected.contains(name)).toList(),
    );
  }

  static bool _alreadyConnected(List<NetLink> links, String a, String b) =>
      links.any(
        (link) =>
            (link.a == a && link.b == b) || (link.a == b && link.b == a),
      );

  static List<PtCable> _cableOrder(NetNode a, NetNode b) {
    final catalog = PacketTracerCatalog.instance;
    final needsCross = NetLink.pairNeedsCrossover(a.type, b.type);
    final preferred = needsCross ? 'copper-cross' : 'copper';
    final other = needsCross ? 'copper' : 'copper-cross';
    final order = <String>[
      preferred,
      other,
      'fiber',
      'fiber-multi',
      'fiber-single',
      'serial-dce',
      'serial',
      'serial-dte',
      'coaxial',
      'phone',
      'usb',
      'ioe',
      'octal',
    ];
    return [
      for (final id in order)
        if (catalog.cable(id) case final PtCable cable)
          if (cable.templateAvailable) cable,
    ];
  }

  static List<PtPort> _freePorts(
    NetworkIntent intent,
    List<NetLink> added,
    NetNode node,
    PtCable cable,
  ) {
    final catalog = PacketTracerCatalog.instance;
    final device = catalog.device(node.model ?? node.type);
    if (device == null) return const [];
    final occupied = <String>{};
    for (final link in [...intent.links, ...added]) {
      if (link.a == node.name) occupied.add(ptPortName(link.aIf));
      if (link.b == node.name) occupied.add(ptPortName(link.bIf));
    }
    final ports = <String, PtPort>{};
    for (final variant in device.variants) {
      if (node.modules.isNotEmpty &&
          !node.modules.every(variant.modules.contains)) {
        continue;
      }
      for (final port in variant.ports) {
        final normalized = ptPortName(port.name);
        if (cable.accepts(port) && !occupied.contains(normalized)) {
          ports.putIfAbsent(normalized, () => port);
        }
      }
    }
    return ports.values.toList();
  }
}
