/// Decoder observations shared by the preflight and requirement checkers.
/// Missing fields stay missing: generator reports and plan defaults do not
/// belong in this adapter.
class SavedArtifactAudit {
  final Map<String, dynamic> raw;

  const SavedArtifactAudit(this.raw);

  List<Map> get devices => [
    for (final row
        in raw['devices'] is List ? raw['devices'] as List : const [])
      if (row is Map) row,
  ];

  bool get hasDeviceInventory {
    if (raw['inventoryComplete'] == false || raw['unreadable'] == true) {
      return false;
    }
    final rows = raw['devices'];
    if (rows is! List || rows.any((row) => row is! Map)) return false;
    final names = devices
        .map((row) => text(row['name']).toLowerCase())
        .toList();
    if (names.any((name) => name.isEmpty) ||
        names.toSet().length != names.length) {
      return false;
    }
    final summary = raw['summary'];
    final count =
        raw['deviceCount'] ?? (summary is Map ? summary['devices'] : null);
    return count == null || (count is num && count == rows.length);
  }

  Map? device(String name) {
    final matches = devices
        .where(
          (row) => text(row['name']).toLowerCase() == name.trim().toLowerCase(),
        )
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  /// A legacy string is an observed enabled role, not proof that all other
  /// roles are off. An explicit false record is different from an unreadable
  /// or absent enabled flag. Conflicting rows are inconclusive.
  static Map<String, bool?> serviceStates(Map device) {
    final result = <String, bool?>{};
    void add(String role, bool? state) {
      final key = role.trim().toLowerCase();
      if (key.isEmpty) return;
      if (result.containsKey(key) && result[key] != state) {
        result[key] = null;
      } else {
        result[key] = state;
      }
    }

    final explicit = device['serviceStates'];
    if (explicit is Map) {
      for (final entry in explicit.entries) {
        add('${entry.key}', observedBool(entry.value));
      }
    }
    final services = device['services'];
    if (services is List) {
      for (final row in services) {
        if (row is String) {
          add(row, true);
        } else if (row is Map) {
          add(
            text(row['service'] ?? row['name']),
            observedBool(row['enabled']),
          );
        }
      }
    }
    return result;
  }

  static bool? observedBool(Object? value) {
    if (value == true || value == 1 || value == '1' || value == 'true') {
      return true;
    }
    if (value == false || value == 0 || value == '0' || value == 'false') {
      return false;
    }
    return null;
  }

  /// Includes the engine's per-device structured diagnostics and on-device
  /// top-level string findings. No diagnostic disappears because of its shape.
  List<String> get findings {
    final out = <String>{};
    void collect(Object? value, String owner) {
      if (value is String && value.trim().isNotEmpty) {
        out.add('${owner.isEmpty ? '' : '$owner: '}${value.trim()}');
      } else if (value is List) {
        for (final row in value) {
          collect(row, owner);
        }
      } else if (value is Map) {
        final message =
            value['text'] ?? value['message'] ?? value['explanation'];
        if (message is String && message.trim().isNotEmpty) {
          collect(message, owner);
        } else if (value['findings'] == null) {
          final label = value['kind'] ?? value['id'];
          if (label is String) collect(label, owner);
        }
        if (value['findings'] != null) collect(value['findings'], owner);
      }
    }

    collect(raw['findings'], '');
    for (final row in devices) {
      collect(row['findings'], text(row['name']));
    }
    return out.toList();
  }

  List<Map> get links => [
    for (final row in raw['links'] is List ? raw['links'] as List : const [])
      if (row is Map) row,
  ];

  bool get hasLinkInventory {
    final rows = raw['links'];
    if (rows is! List || rows.any((row) => row is! Map)) return false;
    final summary = raw['summary'];
    final count =
        raw['linkCount'] ?? (summary is Map ? summary['links'] : null);
    if (count != null && (count is! num || count != rows.length)) return false;
    if (rows.isEmpty && count != 0) return false;
    return links.every(
      (row) =>
          ['a', 'aIf', 'b', 'bIf'].every((key) => text(row[key]).isNotEmpty),
    );
  }

  static String text(Object? value) => value is String ? value.trim() : '';

  static String deviceKind(Object? value) {
    final kind = text(value).toLowerCase().replaceAll(RegExp(r'[ _-]+'), '');
    return switch (kind) {
      'routers' => 'router',
      'switches' || 'multilayerswitch' || 'multilayerswitches' => 'switch',
      'pcs' ||
      'pcpt' ||
      'pcclient' ||
      'computer' ||
      'computers' ||
      'workstation' => 'pc',
      'servers' || 'serverpt' => 'server',
      'laptops' || 'laptoppt' => 'laptop',
      'accesspointpt' || 'accesspoints' || 'ap' => 'accesspoint',
      'firewalls' || 'firewallpt' => 'firewall',
      _ => kind,
    };
  }

  static String interfaceName(Object? value) {
    final name = text(value).toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final aliases = <String, String>{
      'gi': 'gigabitethernet',
      'g': 'gigabitethernet',
      'fa': 'fastethernet',
      'f': 'fastethernet',
      'eth': 'ethernet',
      'e': 'ethernet',
      'se': 'serial',
      's': 'serial',
      'vl': 'vlan',
    };
    final match = RegExp(r'^([a-z]+)(\d.*)$').firstMatch(name);
    if (match == null) return name;
    return '${aliases[match.group(1)] ?? match.group(1)}${match.group(2)}';
  }
}
