import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/network_intent.dart';

/// A reusable piece of a network: devices, their internal cables, addresses,
/// and relative positions. Blocks stay on this device and sync across the
/// app's Android and Windows surfaces through shared preferences.
class NetworkBlock {
  final String name;
  final List<NetNode> nodes;
  final List<NetLink> links;
  final List<InterfaceAddr> addressing;
  final Map<String, Offset?> layout;

  const NetworkBlock({
    required this.name,
    required this.nodes,
    required this.links,
    required this.addressing,
    required this.layout,
  });

  factory NetworkBlock.fromSelection({
    required String name,
    required NetworkIntent intent,
    required Set<String> selected,
  }) {
    final points = <String, Offset>{
      for (final key in selected)
        if (intent.layout[key] case final Offset point) key: point,
    };
    final minX = points.values.isEmpty
        ? 0.0
        : points.values.map((p) => p.dx).reduce((a, b) => a < b ? a : b);
    final minY = points.values.isEmpty
        ? 0.0
        : points.values.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
    return NetworkBlock(
      name: name.trim(),
      nodes: intent.nodes.where((n) => selected.contains(n.name)).toList(),
      links: intent.links
          .where((l) => selected.contains(l.a) && selected.contains(l.b))
          .toList(),
      addressing: intent.addressing
          .where((a) => selected.contains(a.node))
          .toList(),
      layout: {
        for (final entry in points.entries)
          entry.key: entry.value - Offset(minX, minY),
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'nodes': nodes.map((n) => n.toJson(includeSecrets: false)).toList(),
    'links': links.map((l) => l.toJson()).toList(),
    'addressing': addressing.map((a) => a.toJson()).toList(),
    'layout': {
      for (final entry in layout.entries)
        if (entry.value case final Offset point)
          entry.key: {'x': point.dx, 'y': point.dy},
    },
  };

  factory NetworkBlock.fromJson(Map<String, dynamic> raw) => NetworkBlock(
    name: '${raw['name'] ?? 'Network block'}',
    nodes: ((raw['nodes'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => NetNode.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    links: ((raw['links'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => NetLink.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    addressing: ((raw['addressing'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => InterfaceAddr.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    layout: {
      for (final entry
          in ((raw['layout'] as Map?) ?? const <dynamic, dynamic>{}).entries)
        if (entry.value is Map)
          entry.key.toString(): Offset(
            ((entry.value as Map)['x'] as num?)?.toDouble() ?? 0,
            ((entry.value as Map)['y'] as num?)?.toDouble() ?? 0,
          ),
    },
  );
}

class BlockImportResult {
  final NetworkIntent intent;
  final int clearedAddressCount;

  const BlockImportResult(this.intent, this.clearedAddressCount);
}

class NetworkBlockService {
  const NetworkBlockService._();

  static const _key = 'net_builder.network_blocks.v1';

  static Future<List<NetworkBlock>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => NetworkBlock.fromJson(Map<String, dynamic>.from(e)))
          .where((block) => block.nodes.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(NetworkBlock block) async {
    final blocks = await load();
    final next = [
      for (final saved in blocks)
        if (saved.name.toLowerCase() != block.name.toLowerCase()) saved,
      block,
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(next.map((b) => b.toJson()).toList()),
    );
  }

  static Future<void> delete(String name) async {
    final blocks = await load();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(
        blocks
            .where((block) => block.name != name)
            .map((block) => block.toJson())
            .toList(),
      ),
    );
  }

  /// Adds a block with unique device names and offsets its drawing. Existing
  /// addresses are kept where they do not conflict; conflicting entries are
  /// cleared for the user to assign again.
  static BlockImportResult addTo(
    NetworkIntent intent,
    NetworkBlock block, {
    Map<String, Offset?>? currentLayout,
  }) {
    final names = <String, String>{};
    final reserved = intent.nodes.map((n) => n.name.toLowerCase()).toSet();
    for (final node in block.nodes) {
      var candidate = node.name;
      var copy = 2;
      while (reserved.contains(candidate.toLowerCase())) {
        candidate = '${node.name} copy $copy';
        copy++;
      }
      reserved.add(candidate.toLowerCase());
      names[node.name] = candidate;
    }

    final baseLayout = <String, Offset?>{...(currentLayout ?? intent.layout)};
    final existingPoints = baseLayout.values.whereType<Offset>().toList();
    final blockPoints = block.layout.values.whereType<Offset>().toList();
    final minX = blockPoints.isEmpty
        ? 0.0
        : blockPoints.map((p) => p.dx).reduce((a, b) => a < b ? a : b);
    final minY = blockPoints.isEmpty
        ? 0.0
        : blockPoints.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
    final maxX = existingPoints.isEmpty
        ? 0.0
        : existingPoints.map((p) => p.dx).reduce((a, b) => a > b ? a : b);
    final dx = existingPoints.isEmpty ? 160.0 : maxX + 180 - minX;
    final dy = existingPoints.isEmpty
        ? 100.0
        : existingPoints.map((p) => p.dy).reduce((a, b) => a > b ? a : b) +
              100 -
              minY;

    String addressKey(String value) => value.split('/').first.toLowerCase();
    final usedAddresses = <String>{
      for (final address in intent.addressing)
        if (address.ipCidr.isNotEmpty) addressKey(address.ipCidr),
      for (final address in intent.addressing)
        if (address.ip6Cidr?.isNotEmpty == true) addressKey(address.ip6Cidr!),
    };
    var cleared = 0;
    final addedAddresses = <InterfaceAddr>[];
    for (final address in block.addressing) {
      final ip = address.ipCidr.isEmpty ? '' : addressKey(address.ipCidr);
      final ip6 = address.ip6Cidr?.isNotEmpty == true
          ? addressKey(address.ip6Cidr!)
          : '';
      final conflict =
          (ip.isNotEmpty && usedAddresses.contains(ip)) ||
          (ip6.isNotEmpty && usedAddresses.contains(ip6));
      if (conflict) cleared++;
      final nextAddress = InterfaceAddr(
        node: names[address.node] ?? address.node,
        iface: address.iface,
        ipCidr: conflict ? '' : address.ipCidr,
        ip6Cidr: conflict ? null : address.ip6Cidr,
      );
      addedAddresses.add(nextAddress);
      if (!conflict) {
        if (ip.isNotEmpty) usedAddresses.add(ip);
        if (ip6.isNotEmpty) usedAddresses.add(ip6);
      }
    }

    final addedNodes = [
      for (final node in block.nodes)
        NetNode.fromJson({...node.toJson(), 'name': names[node.name]}),
    ];
    final addedLinks = [
      for (final link in block.links)
        NetLink.fromJson({
          ...link.toJson(),
          'a': names[link.a] ?? link.a,
          'b': names[link.b] ?? link.b,
          if (link.dce == link.a) 'dce': names[link.a] ?? link.a,
          if (link.dce == link.b) 'dce': names[link.b] ?? link.b,
        }),
    ];
    final translated = <String, Offset?>{
      for (final entry in block.layout.entries)
        if (entry.value case final Offset point)
          (names[entry.key] ?? entry.key): point + Offset(dx, dy),
    };
    return BlockImportResult(
      intent.copyWith(
        nodes: [...intent.nodes, ...addedNodes],
        links: [...intent.links, ...addedLinks],
        addressing: [...intent.addressing, ...addedAddresses],
        layout: {...baseLayout, ...translated},
      ),
      cleared,
    );
  }
}
