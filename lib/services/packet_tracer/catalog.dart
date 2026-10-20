import 'dart:convert';

import 'catalog_data.dart';

String ptIdentity(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

String ptPortName(String value) {
  final raw = value.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
  final match = RegExp(r'^([a-z]+)(\d.*)?$').firstMatch(raw);
  if (match == null) return raw;
  const aliases = {
    'f': 'fastethernet',
    'fa': 'fastethernet',
    'fe': 'fastethernet',
    'g': 'gigabitethernet',
    'gi': 'gigabitethernet',
    'ge': 'gigabitethernet',
    'e': 'ethernet',
    'eth': 'ethernet',
    's': 'serial',
    'se': 'serial',
    'ser': 'serial',
    'te': 'tengigabitethernet',
    'ten': 'tengigabitethernet',
    'con': 'console',
    'aux': 'auxiliary',
    'coax': 'coaxial',
  };
  return '${aliases[match[1]] ?? match[1]}${match[2] ?? ''}';
}

/// Infer a medium only from a known PT port type, never an arbitrary name.
String ptPortMedium(String type) {
  final t = type.toLowerCase();
  if (t.contains('fiber')) return 'fiber';
  if (t == 'easync') return 'async';
  if (t.contains('serial')) return 'serial';
  if (t.contains('coax')) return 'coaxial';
  if (t.contains('modem')) return 'modem';
  if (t.contains('usb')) return 'usb';
  if (t.contains('customio') || t.contains('digital') || t.contains('analog')) {
    return 'io';
  }
  if (t.contains('rs232')) return 'rs232';
  if (t.contains('console')) return 'console';
  if (t.contains('copper') || t.contains('ethernet')) return 'copper';
  return '';
}

class PtPort {
  final String name;
  final String type;
  final String family;
  final bool inferred;
  const PtPort(this.name, this.type, this.family, {this.inferred = false});
  String get medium => ptPortMedium(type);
}

class PtHardwareVariant {
  final String key;
  final List<String> modules;
  final List<PtPort> ports;
  final bool configurable;
  PtHardwareVariant(Map<String, dynamic> raw)
    : key = '${raw['key']}',
      modules = List<String>.from(raw['modules'] ?? const []),
      configurable = raw['hasConfig'] == true,
      ports = _ports(raw['ports'] as List? ?? const []);

  static List<PtPort> _ports(List entries) {
    final taken = <String>{
      for (final p in entries)
        if ('${p['name'] ?? ''}'.isNotEmpty) '${p['name']}',
    };
    final result = <PtPort>[];
    for (final p in entries) {
      var name = '${p['name'] ?? ''}';
      final family = '${p['family'] ?? ''}';
      final inferred = name.isEmpty;
      if (name.isEmpty) {
        const prefixes = {
          'fastethernet': 'FastEthernet',
          'gigabitethernet': 'GigabitEthernet',
          'ethernet': 'Ethernet',
          'serial': 'Serial',
          'fiber': 'Fiber',
          'wireless': 'Wireless',
        };
        final prefix = prefixes[family];
        if (prefix != null) {
          var i = 0;
          while (taken.contains('$prefix$i')) {
            i++;
          }
          name = '$prefix$i';
          taken.add(name);
        }
      }
      // An unnamed connector is deliberately not offered as a usable port.
      if (name.isNotEmpty) {
        result.add(
          PtPort(name, '${p['type'] ?? ''}', family, inferred: inferred),
        );
      }
    }
    return List.unmodifiable(result);
  }
}

class PtDevice {
  final String model;
  final String type;
  final String kind;
  final List<String> aliases;
  final List<PtHardwareVariant> variants;
  PtDevice(Map<String, dynamic> raw)
    : model = '${raw['model']}',
      type = '${raw['type']}',
      kind = '${raw['kind']}',
      aliases = List<String>.unmodifiable(raw['aliases'] ?? const []),
      variants = List.unmodifiable(
        (raw['variants'] as List).map(
          (e) => PtHardwareVariant(Map<String, dynamic>.from(e)),
        ),
      );
  bool get placeable => variants.isNotEmpty;
  bool get connectable =>
      variants.any((v) => v.ports.any((p) => p.medium.isNotEmpty));
  bool get configurable => variants.any((v) => v.configurable);
  String get supportLabel =>
      placeable ? 'Buildable template' : 'Recognized only';
  List<PtPort> get ports {
    final byName = <String, PtPort>{};
    for (final v in variants) {
      for (final p in v.ports) {
        byName.putIfAbsent(ptPortName(p.name), () => p);
      }
    }
    return byName.values.toList();
  }
}

/// What the bundled Packet Tracer data can actually say about one model.
/// Recognition, local build templates, and live verification are separate
/// capabilities; a name match alone is never presented as a successful build.
class PtDeviceCompatibility {
  final String catalogVersion;
  final String installedVersion;
  final bool recognized;
  final bool buildable;
  final bool configurable;
  final bool liveVerificationRecorded;

  const PtDeviceCompatibility({
    required this.catalogVersion,
    required this.installedVersion,
    required this.recognized,
    required this.buildable,
    required this.configurable,
    this.liveVerificationRecorded = false,
  });

  bool get versionNeedsReview {
    final installed = _majorMinor(installedVersion);
    final catalog = _majorMinor(catalogVersion);
    return installed != null && catalog != null && installed != catalog;
  }

  String get recognitionLabel => recognized ? 'Recognized' : 'Unknown model';
  String get buildLabel => buildable
      ? 'Build template available'
      : 'Cannot build from bundled templates';
  String get verifyLabel => !configurable
      ? 'No CLI configuration template'
      : liveVerificationRecorded
      ? 'Live verification recorded'
      : 'Live verification not recorded';

  String get versionNote {
    if (installedVersion.trim().isEmpty) {
      return 'Catalog source: Packet Tracer $catalogVersion. Installed version not set.';
    }
    if (versionNeedsReview) {
      return 'Catalog source is Packet Tracer $catalogVersion; installed version is $installedVersion. Compatibility needs a live check.';
    }
    return 'Catalog and installed version: Packet Tracer $installedVersion.';
  }

  static String? _majorMinor(String value) {
    final match = RegExp(r'^(\d+)\.(\d+)').firstMatch(value.trim());
    return match == null ? null : '${match.group(1)}.${match.group(2)}';
  }
}

class PtCable {
  final String id;
  final String label;
  final List<String> aliases;
  final String medium;
  final String variant;
  final List<String> families;
  final bool templateAvailable;
  PtCable(Map<String, dynamic> raw)
    : id = '${raw['id']}',
      label = '${raw['label']}',
      aliases = List<String>.from(raw['aliases']),
      medium = '${raw['medium']}',
      variant = '${raw['variant']}',
      families = List<String>.from(raw['families']),
      templateAvailable = raw['templateAvailable'] == true;
  bool accepts(PtPort port) => families.contains(port.medium);
  String? mismatch(
    PtPort a,
    PtPort b, {
    Iterable<String> modulesA = const [],
    Iterable<String> modulesB = const [],
  }) {
    if (!accepts(a) || !accepts(b)) {
      return '$label cannot connect ${a.name} (${a.type}) to ${b.name} (${b.type}).';
    }
    if (id == 'console' && a.medium == b.medium) {
      return 'Console needs one RS232 end and one Console end.';
    }
    if (id == 'octal' && a.medium == b.medium) {
      return 'Octal needs one asynchronous end and one Console end.';
    }
    if (medium == 'eFiber') {
      bool single(Iterable<String> modules) => modules.any(
        (m) => const ['GLC-LH-SMD', 'GLC-LX-SM-RGD'].contains(m.toUpperCase()),
      );
      final aSingle = single(modulesA), bSingle = single(modulesB);
      if (aSingle != bSingle) {
        return 'The two fiber modules use different optical modes. Choose matching modules.';
      }
      if (id == 'fiber-single' && !aSingle) {
        return 'Single-mode fiber requires single-mode modules at both ends.';
      }
      if (id == 'fiber-multi' && aSingle) {
        return 'These modules require single-mode fiber.';
      }
    }
    return null;
  }
}

/// The synchronous, indexed vocabulary used by the planner, editor and builder.
class PacketTracerCatalog {
  static final instance = PacketTracerCatalog._();
  late final String version;
  late final List<PtDevice> devices;
  late final List<PtCable> cables;
  final Map<String, PtDevice> _models = {};
  final Map<String, PtCable> _cables = {};
  PacketTracerCatalog._() {
    final raw = jsonDecode(ptCatalogJson) as Map<String, dynamic>;
    version = '${raw['version']}';
    devices = List.unmodifiable(
      (raw['devices'] as List).map(
        (e) => PtDevice(Map<String, dynamic>.from(e)),
      ),
    );
    cables = List.unmodifiable(
      (raw['cables'] as List).map((e) => PtCable(Map<String, dynamic>.from(e))),
    );
    for (final device in devices) {
      for (final name in [device.model, ...device.aliases]) {
        _models.putIfAbsent(ptIdentity(name), () => device);
      }
    }
    for (final cable in cables) {
      for (final name in [cable.id, cable.label, ...cable.aliases]) {
        _cables[ptIdentity(name)] = cable;
      }
    }
  }

  PtDeviceCompatibility compatibility(
    String model, {
    String installedVersion = '',
  }) {
    final device = this.device(model);
    return PtDeviceCompatibility(
      catalogVersion: version,
      installedVersion: installedVersion,
      recognized: device != null,
      buildable: device?.placeable ?? false,
      configurable: device?.configurable ?? false,
    );
  }

  PtDevice? device(String name) => _models[ptIdentity(name)];
  PtCable? cable(String? name) => name == null || name.trim().isEmpty
      ? _cables['copper']
      : _cables[ptIdentity(name)];
  List<PtDevice> search(
    String query, {
    String? type,
    bool availableOnly = false,
  }) {
    final q = ptIdentity(query);
    return devices
        .where(
          (d) =>
              (type == null || d.type == type) &&
              (!availableOnly || d.placeable) &&
              [
                d.model,
                d.kind,
                d.type,
                ...d.aliases,
              ].any((s) => ptIdentity(s).contains(q)),
        )
        .toList();
  }

  List<({int start, int end, PtCable cable})> cablesIn(String text) {
    final found = <({int start, int end, PtCable cable})>[];
    for (final cable in cables) {
      for (final alias in [cable.id, ...cable.aliases]) {
        final pattern = RegExp(
          '(?<![a-z0-9])${RegExp.escape(alias)}(?![a-z0-9])',
          caseSensitive: false,
        );
        for (final m in pattern.allMatches(text)) {
          found.add((start: m.start, end: m.end, cable: cable));
        }
      }
    }
    found.sort((a, b) => (b.end - b.start).compareTo(a.end - a.start));
    final unique = <({int start, int end, PtCable cable})>[];
    for (final match in found) {
      if (!unique.any((m) => match.start < m.end && match.end > m.start)) {
        unique.add(match);
      }
    }
    unique.sort((a, b) => a.start.compareTo(b.start));
    return unique;
  }
}
