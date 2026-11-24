import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/network_intent.dart';
import '../models/request_requirement.dart';

/// A reusable piece of a network: devices, their internal cables, addresses,
/// and relative positions. Blocks stay on this device and sync across the
/// app's Android and Windows surfaces through shared preferences.
class NetworkBlock {
  final String name;
  final List<NetNode> nodes;
  final List<NetLink> links;
  final List<InterfaceAddr> addressing;
  final Map<String, Offset?> layout;
  final AttachmentSource? source;
  final List<Requirement> observedRequirements;

  const NetworkBlock({
    required this.name,
    required this.nodes,
    required this.links,
    required this.addressing,
    required this.layout,
    this.source,
    this.observedRequirements = const [],
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
    if (source != null) 'source': source!.toMap(),
    if (observedRequirements.isNotEmpty)
      'observedRequirements': observedRequirements
          .map((r) => r.toJson())
          .toList(),
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
    source: raw['source'] is Map
        ? AttachmentSource.fromMap(
            Map<String, dynamic>.from(raw['source'] as Map),
          )
        : null,
    observedRequirements: [
      for (final item in raw['observedRequirements'] as List? ?? const [])
        Requirement.fromJson(item),
    ],
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
  final Map<String, String> nameMapping;

  /// Original addresses removed because they collided with the target project.
  /// They are evidence of a conflict, NOT currently configured addresses.
  final List<InterfaceAddr> clearedAddresses;
  final List<Requirement> importedRequirements;
  final List<String> unresolvedDetails;

  const BlockImportResult(
    this.intent,
    this.clearedAddressCount, {
    this.nameMapping = const {},
    this.clearedAddresses = const [],
    this.importedRequirements = const [],
    this.unresolvedDetails = const [],
  });
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
    String turnId = '',
    String? projectId,
  }) {
    final names = <String, String>{};
    final blockNames = block.nodes
        .map((node) => node.name.toLowerCase())
        .toList();
    if (blockNames.toSet().length != blockNames.length ||
        blockNames.any((name) => name.trim().isEmpty)) {
      throw const FormatException(
        'A block must have distinct, non-empty source device names.',
      );
    }
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
    final clearedAddresses = <InterfaceAddr>[];
    final addedAddresses = <InterfaceAddr>[];
    for (final address in block.addressing) {
      final ip = address.ipCidr.isEmpty ? '' : addressKey(address.ipCidr);
      final ip6 = address.ip6Cidr?.isNotEmpty == true
          ? addressKey(address.ip6Cidr!)
          : '';
      final conflict =
          (ip.isNotEmpty && usedAddresses.contains(ip)) ||
          (ip6.isNotEmpty && usedAddresses.contains(ip6));
      if (conflict) {
        cleared++;
        clearedAddresses.add(address);
      }
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
      nameMapping: Map.unmodifiable(names),
      clearedAddresses: List.unmodifiable(clearedAddresses),
      importedRequirements: _remapRequirements(
        block.observedRequirements,
        names,
        clearedAddresses,
        projectId: projectId ?? intent.projectName,
        turnId: turnId,
      ),
      unresolvedDetails: [
        if (block.source == null && block.observedRequirements.isEmpty)
          'Legacy block has no source provenance; reconstructed defaults are not imported evidence.',
        for (final entry in names.entries)
          if (entry.key != entry.value)
            'Imported device ${entry.key} was renamed to ${entry.value}.',
        for (final address in clearedAddresses)
          '${names[address.node] ?? address.node}/${address.iface}: conflicting source addresses were cleared; assign them before building.',
      ],
    );
  }

  static List<Requirement> _remapRequirements(
    List<Requirement> requirements,
    Map<String, String> names,
    List<InterfaceAddr> cleared, {
    required String projectId,
    required String turnId,
  }) {
    String remapIdentity(String value) {
      if (names.containsKey(value)) return names[value]!;
      // Name-aware scopes use a slash boundary; never substring-replace R1 in
      // R10 or an address, SSID, model, credential or prose excerpt.
      final keys = names.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      var result = value;
      for (final name in keys) {
        if (result.startsWith('$name/')) {
          result = '${names[name]}${result.substring(name.length)}';
          break;
        }
      }
      for (final name in keys) {
        result = result.replaceAll('-$name/', '-${names[name]}/');
      }
      return result;
    }

    bool addressWasCleared(Requirement requirement) {
      if (!requirement.property.toLowerCase().contains('address') &&
          !requirement.property.toLowerCase().contains('cidr')) {
        return false;
      }
      return cleared.any(
        (address) =>
            requirement.scope.scopeId == '${address.node}/${address.iface}' ||
            (requirement.scope.scopeId == address.node ||
                requirement.subject == address.node),
      );
    }

    return List.unmodifiable([
      for (final requirement in requirements)
        requirement.copyWith(
          id: '${requirement.id}@block-${turnId.isEmpty ? projectId : turnId}-${names.values.join('|')}',
          origin: RequirementOrigin.imported,
          sourceTurnId: turnId,
          subject: names[requirement.subject] ?? requirement.subject,
          scope: requirement.scope.kind == RequirementScopeKind.project
              ? RequirementScope.project(projectId)
              : RequirementScope(
                  kind: requirement.scope.kind,
                  scopeId: remapIdentity(requirement.scope.scopeId),
                ),
          value:
              const {
                    'device_name',
                    'device_presence',
                  }.contains(requirement.property) &&
                  requirement.value is String
              ? names[requirement.value] ?? requirement.value
              : requirement.value,
          clearValue: addressWasCleared(requirement),
          state: addressWasCleared(requirement)
              ? RequirementState.unresolved
              : requirement.state,
          // Preserve original excerpt/hash; only current scopes/values move.
          sourceSpans: [
            for (final span in requirement.sourceSpans)
              SourceSpan(
                messageId: span.messageId,
                start: span.start,
                end: span.end,
                excerpt: span.excerpt,
                attachment: addressWasCleared(requirement)
                    ? span.attachment?.copyWith(
                        uncertainty: 'source_address_cleared_on_import',
                        incomplete: true,
                      )
                    : span.attachment,
              ),
          ],
        ),
    ]);
  }
}
