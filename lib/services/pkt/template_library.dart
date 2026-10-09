/// The offline .pkt template library, bundled as assets.
///
/// A phone has no Packet Tracer and no sidecar, and the device blocks a save
/// is made of cannot be invented: every model carries a module and port tree
/// only Packet Tracer knows. So the app ships the library the sidecar's
/// extractor (`sidecar/pkt_template_build.py`) built from real Packet Tracer
/// saves: one known-good `<DEVICE>` block per model, the interface names
/// Packet Tracer derives for it, one `<LINK>` block per cable kind, and the
/// global skeleton the topology is written into.
///
/// This is the same library `sidecar/pkt_builder.py` builds from - the
/// manifest is read as-is, blocks are loaded lazily per file and cached, so a
/// build only pays for the models it actually clones.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'pkt_codec.dart';

/// One interface of a model, as the manifest recorded it.
class PktTemplatePort {
  /// Position among the block's own `<PORT>` elements, in document order.
  /// `_patch_port` addresses a port by this index.
  final int index;

  /// Packet Tracer's element type, e.g. 'eCopperFastEthernet'.
  final String type;

  /// The cable-capable family: 'fastethernet', 'gigabitethernet', 'ethernet',
  /// 'serial', 'fiber', 'wireless' - '' when the type is not one we name.
  final String family;

  /// The name Packet Tracer shows, e.g. 'FastEthernet0/1'. Empty when the
  /// source save could not prove it; such a port is never cabled.
  final String name;

  const PktTemplatePort({
    required this.index,
    required this.type,
    required this.family,
    required this.name,
  });

  static PktTemplatePort fromJson(Map<String, dynamic> json) =>
      PktTemplatePort(
        index: (json['index'] as num?)?.toInt() ?? 0,
        type: '${json['type'] ?? ''}',
        family: '${json['family'] ?? ''}',
        name: '${json['name'] ?? ''}',
      );
}

/// One device model the library can clone.
class PktTemplateDevice {
  /// The library key, e.g. '2960-24TT' or '1941+HWIC-2T'.
  final String key;

  /// The hardware model, e.g. '1941'.
  final String model;

  /// Packet Tracer's kind text, e.g. 'Router', 'Switch', 'Server'.
  final String kind;

  /// Modules fitted to this device (HWIC-2T, PT-HOST-NM-1CFE, ...).
  final List<String> modules;

  final List<PktTemplatePort> ports;

  final bool hasConfig;
  final bool hasPhysical;

  /// Manifest-relative block path, e.g. 'devices/2960-24TT.xml'.
  final String file;

  const PktTemplateDevice({
    required this.key,
    required this.model,
    required this.kind,
    required this.modules,
    required this.ports,
    required this.hasConfig,
    required this.hasPhysical,
    required this.file,
  });

  static PktTemplateDevice fromJson(Map<String, dynamic> json) =>
      PktTemplateDevice(
        key: '${json['key'] ?? ''}',
        model: '${json['model'] ?? ''}',
        kind: '${json['kind'] ?? ''}',
        modules: [
          for (final m in (json['modules'] as List?) ?? const <dynamic>[]) '$m',
        ],
        ports: [
          for (final p in (json['ports'] as List?) ?? const <dynamic>[])
            if (p is Map<String, dynamic>)
              PktTemplatePort.fromJson(p)
            else if (p is Map)
              PktTemplatePort.fromJson(Map<String, dynamic>.from(p)),
        ],
        hasConfig: json['hasConfig'] == true,
        hasPhysical: json['hasPhysical'] == true,
        file: '${json['file'] ?? ''}',
      );

  /// This model with its cableable ports given names, for use by the BUILD.
  ///
  /// WHY THIS IS NOT `ports` ITSELF: `selectVariant` judges every candidate
  /// against the ports Packet Tracer actually wrote, and its last tie-break
  /// is "fewest ports". Naming the library's ports at load time made a
  /// 1-port Meraki-Server look like a host for `f0` where a 2-port Server-PT
  /// had always been chosen, and the generated file came out with the Meraki
  /// model - a template with no DHCP and no AAA panels in it, so every server
  /// in a plan was silently unconfigured. Selection must keep reading the
  /// library as it was harvested; only a model that has already WON needs a
  /// name to put in a `<LINK>`.
  ///
  /// The reason any of this is needed: `AccessPoint-PT-A`'s Ethernet port
  /// carries no `<NAME>` in any Packet Tracer save (it is named from the host
  /// module and never written out), so the manifest recorded it empty and no
  /// cable could ever reference it - the access point was placed in the
  /// workspace floating, cabled to nothing. 34 models were in that state.
  PktTemplateDevice withNamedPorts() {
    final taken = <String>{
      for (final p in ports)
        if (p.name.isNotEmpty) p.name,
    };
    final out = <PktTemplatePort>[];
    for (final p in ports) {
      if (p.name.isNotEmpty) {
        out.add(p);
        continue;
      }
      final name = _conventionalPortName(p.family, taken);
      // Only a name we actually produced reserves a slot, so two unnamed
      // ports of the same family get FastEthernet0 and FastEthernet1 rather
      // than the same name twice.
      if (name.isNotEmpty) taken.add(name);
      out.add(
        PktTemplatePort(
          index: p.index,
          type: p.type,
          family: p.family,
          name: name,
        ),
      );
    }
    return PktTemplateDevice(
      key: key,
      model: model,
      kind: kind,
      modules: modules,
      ports: out,
      hasConfig: hasConfig,
      hasPhysical: hasPhysical,
      file: file,
    );
  }
}

/// The conventional Packet Tracer name for an interface the source never
/// named, per family - numbered from 0 and skipping names already in use, so
/// a port that leaves one module port bare never collides with the ones it
/// does name.
String _conventionalPortName(String family, Set<String> taken) {
  const prefixes = <String, String>{
    'fastethernet': 'FastEthernet',
    'gigabitethernet': 'GigabitEthernet',
    'ethernet': 'Ethernet',
    'serial': 'Serial',
    'fiber': 'Fiber',
    'wireless': 'Wireless',
  };
  final prefix = prefixes[family];
  if (prefix == null) return '';
  var n = 0;
  while (taken.contains('$prefix$n')) {
    n++;
  }
  return '$prefix$n';
}

/// One cable kind the library can clone.
class PktTemplateLink {
  final String key;

  /// The medium, e.g. 'eCopper', 'eSerial', 'eFiber'.
  final String type;

  /// The cable, e.g. 'eStraightThrough', 'eCrossOver', 'eSerial'.
  final String cable;

  /// Manifest-relative block path, e.g. 'links/eCopper-eCrossOver.xml'.
  final String file;

  const PktTemplateLink({
    required this.key,
    required this.type,
    required this.cable,
    required this.file,
  });

  static PktTemplateLink fromJson(Map<String, dynamic> json) =>
      PktTemplateLink(
        key: '${json['key'] ?? ''}',
        type: '${json['type'] ?? ''}',
        cable: '${json['cable'] ?? ''}',
        file: '${json['file'] ?? ''}',
      );
}

/// The library as a whole: manifest records plus lazily loaded blocks.
class PktTemplateLibrary {
  /// The Packet Tracer version the library was extracted from, e.g.
  /// '9.0.0.0810'. Written into the generated save's `<VERSION>`.
  final String version;

  /// The emptied save document every topology is written into.
  final String skeleton;

  final List<PktTemplateDevice> devices;
  final List<PktTemplateLink> links;

  final String assetRoot;
  final Map<String, String> _blockCache = {};

  PktTemplateLibrary({
    required this.version,
    required this.skeleton,
    required this.devices,
    required this.links,
    required this.assetRoot,
  });

  static const _bundledRoot = 'sidecar/pkt_templates';
  static PktTemplateLibrary? _bundled;

  /// Load the bundled library. Throws [PktBuildFailure] when the assets are
  /// missing or unreadable - the caller reports that rather than building
  /// from a half-understood library.
  static Future<PktTemplateLibrary> loadBundled() async {
    final cached = _bundled;
    if (cached != null) return cached;
    final library = await _load(_bundledRoot);
    _bundled = library;
    return library;
  }

  /// Test hook: drop the cached bundled library.
  static void resetCacheForTests() => _bundled = null;

  static Future<PktTemplateLibrary> _load(String root) async {
    Map<String, dynamic> manifest;
    try {
      final raw = await rootBundle.loadString('$root/manifest.json');
      manifest = json.decode(raw) as Map<String, dynamic>;
    } catch (e) {
      throw PktBuildFailure(
        'the bundled template library could not be read ($e), so there is '
        'no known-good device block to clone.',
      );
    }
    String skeleton;
    try {
      skeleton = await rootBundle.loadString('$root/skeleton.xml');
    } catch (e) {
      throw PktBuildFailure('the template skeleton could not be read: $e');
    }
    final devices = <PktTemplateDevice>[];
    for (final entry in (manifest['devices'] as List?) ?? const <dynamic>[]) {
      if (entry is Map) {
        devices.add(
          PktTemplateDevice.fromJson(Map<String, dynamic>.from(entry)),
        );
      }
    }
    final links = <PktTemplateLink>[];
    for (final entry in (manifest['links'] as List?) ?? const <dynamic>[]) {
      if (entry is Map) {
        links.add(PktTemplateLink.fromJson(Map<String, dynamic>.from(entry)));
      }
    }
    if (devices.isEmpty) {
      throw const PktBuildFailure(
        'the bundled template library lists no device models.',
      );
    }
    return PktTemplateLibrary(
      version: '${manifest['version'] ?? ''}',
      skeleton: xmlSafeText(skeleton),
      devices: devices,
      links: links,
      assetRoot: root,
    );
  }

  /// A device block by manifest-relative path, loaded once and sanitized.
  /// The sidecar's loader applies `xml_safe` on read and so does this: a
  /// control character that is legal inside a Packet Tracer save but not in
  /// XML 1.0 would make the block unparseable for everything downstream.
  Future<String> blockFor(String relative) async {
    if (relative.isEmpty) return '';
    final cached = _blockCache[relative];
    if (cached != null) return cached;
    String raw;
    try {
      raw = await rootBundle.loadString('$assetRoot/$relative');
    } catch (e) {
      throw PktBuildFailure(
        'template block $relative is missing from the library ($e)',
      );
    }
    final block = xmlSafeText(raw);
    _blockCache[relative] = block;
    return block;
  }

  /// The device record with [key], if the library has it.
  PktTemplateDevice? deviceByKey(String key) {
    for (final d in devices) {
      if (d.key == key) return d;
    }
    return null;
  }
}

/// Sanitize a whole block or document read from the library: control
/// characters that Packet Tracer tolerates inside its own saves are not legal
/// XML 1.0, and one of them makes the block unparseable downstream.
String xmlSafeText(String text) =>
    utf8.decode(xmlSafe(Uint8List.fromList(utf8.encode(text))),
        allowMalformed: true);

/// The library cannot produce a file. Port of `pkt_builder.BuildError`.
class PktBuildFailure implements Exception {
  final String message;
  const PktBuildFailure(this.message);
  @override
  String toString() => message;
}
