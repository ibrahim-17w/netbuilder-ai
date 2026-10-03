/// Building .pkt files on the device - the path a phone has to take.
///
/// The desktop build talks to the Python sidecar over HTTP. A phone has no
/// sidecar, no Python and usually no reachable PC, so on Android this is the
/// only route to a .pkt: read a seed save the user already has, clone the
/// device templates out of it, and write the file locally.
///
/// Everything here is local file IO and pure Dart. No network, no server.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/network_intent.dart';
import 'pkt_builder.dart';
import 'pkt_codec.dart';
import 'seed_library.dart';

/// A build that finished, and where the file landed.
class OnDeviceBuild {
  final File file;

  /// The save document, kept so the app can audit or re-save it.
  final String xml;

  final Map<String, String> refIds;
  final List<String> warnings;

  /// The audit companion written next to the file, matching what the sidecar
  /// writes on the desktop so the two routes produce the same artefacts.
  final File manifest;

  const OnDeviceBuild({
    required this.file,
    required this.xml,
    required this.refIds,
    required this.warnings,
    required this.manifest,
  });
}

/// Why an on-device build could not run.
enum OnDeviceFailure {
  /// No seed save has been imported yet.
  noSeed,

  /// The seed is not a Packet Tracer save this codec can read.
  unreadableSeed,

  /// The seed has no devices to clone.
  emptySeed,
}

class OnDeviceBuildError implements Exception {
  final OnDeviceFailure reason;
  final String message;
  const OnDeviceBuildError(this.reason, this.message);
  @override
  String toString() => message;
}

/// Builds .pkt files on the device from a seed save.
class OnDevicePktBuilder {
  const OnDevicePktBuilder._();

  /// Where the imported seed lives inside [appDir].
  ///
  /// One fixed name, so re-importing replaces the previous seed rather than
  /// accumulating them - and so a rebuild after an app restart finds it
  /// without asking again.
  static File seedFileIn(Directory appDir) =>
      File('${appDir.path}${Platform.pathSeparator}netbuilder-seed.pkt');

  /// Where built labs are written inside [appDir].
  ///
  /// The app's own documents directory, which on Android is app-private and
  /// needs no runtime permission. The user gets the file out through the
  /// share sheet, not by browsing the filesystem.
  static Directory outDirIn(Directory appDir) => Directory(
        '${appDir.path}${Platform.pathSeparator}pkt',
      );

  /// The seed already imported into [appDir], or null if there is none.
  ///
  /// A seed that has gone unreadable is treated as no seed: carrying on with
  /// a half-understood save would build labs from templates the app cannot
  /// actually describe.
  static SeedLibrary? loadSeed(Directory appDir) {
    final file = seedFileIn(appDir);
    if (!file.existsSync()) return null;
    try {
      final library = importSeed(file);
      if (library.isEmpty) return null;
      return library;
    } on OnDeviceBuildError {
      return null;
    }
  }

  /// Copy a user-picked save into [appDir] as the seed, and report what it
  /// can supply.
  static SeedLibrary installSeed(File picked, Directory appDir) {
    final library = importSeed(picked);
    final target = seedFileIn(appDir);
    if (!appDir.existsSync()) appDir.createSync(recursive: true);
    picked.copySync(target.path);
    return library;
  }

  /// Read a seed save and report what it can supply.
  ///
  /// The user does this once. It is the step that replaces the whole template
  /// library on a machine that cannot run the extractor.
  static SeedLibrary importSeed(File seedFile) {
    if (!seedFile.existsSync()) {
      throw OnDeviceBuildError(
        OnDeviceFailure.unreadableSeed,
        'No seed file at ${seedFile.path}.',
      );
    }
    final bytes = seedFile.readAsBytesSync();
    late SeedLibrary library;
    try {
      library = SeedLibrary.fromPkt(bytes);
    } on PktFormatError catch (e) {
      throw OnDeviceBuildError(
        OnDeviceFailure.unreadableSeed,
        'That file is not a Packet Tracer save this app can read: $e',
      );
    }
    if (library.isEmpty) {
      throw const OnDeviceBuildError(
        OnDeviceFailure.emptySeed,
        'That save contains no devices, so there is nothing to build from. '
        'Import a save that has at least one router or switch in it.',
      );
    }
    return library;
  }

  /// Turn an intent into device and link specs laid out on a grid.
  ///
  /// The grid is not decoration: Packet Tracer stacks devices at the same
  /// coordinates and the result looks like a pile, which is unreadable.
  static ({List<PktDeviceSpec> devices, List<PktLinkSpec> links}) specsFor(
    NetworkIntent intent, {
    double originX = 240,
    double originY = 200,
    double gapX = 200,
    double gapY = 140,
  }) {
    final devices = <PktDeviceSpec>[];
    for (var i = 0; i < intent.nodes.length; i++) {
      final node = intent.nodes[i];
      final column = i % 4;
      final row = i ~/ 4;
      devices.add(
        PktDeviceSpec(
          name: node.name,
          type: node.type,
          model: _modelFor(node.model),
          x: originX + column * gapX,
          y: originY + row * gapY,
        ),
      );
    }
    final byName = {for (final d in devices) d.name: d};
    final links = <PktLinkSpec>[];
    for (final link in intent.links) {
      final a = byName[link.a];
      final b = byName[link.b];
      if (a == null || b == null) continue;
      links.add(
        PktLinkSpec(
          fromDevice: a.name,
          // Packet Tracer's port names are per-model; FastEthernet0 is the
          // one every model in the seed library actually has.
          fromPort: link.aIf.isEmpty ? 'FastEthernet0' : link.aIf,
          toDevice: b.name,
          toPort: link.bIf.isEmpty ? 'FastEthernet0' : link.bIf,
          type: link.cable?.toLowerCase().contains('serial') ?? false
              ? 'eSerial'
              : 'eCopperCross',
          dceAtFrom: (link.dce ?? '').trim().isNotEmpty,
        ),
      );
    }
    return (devices: devices, links: links);
  }

  /// Build a .pkt from [intent] using [seed] and write it into [outDir].
  ///
  /// Returns null when the intent has no devices at all - there is nothing to
  /// build, and inventing a lab here is exactly the failure this whole path
  /// exists to avoid.
  static OnDeviceBuild? build({
    required NetworkIntent intent,
    required SeedLibrary seed,
    required Directory outDir,
    String filename = 'lab.pkt',
  }) {
    if (intent.nodes.isEmpty) return null;
    final planned = specsFor(intent);
    final result = PktBuilder.build(
      seed: seed,
      devices: planned.devices,
      links: planned.links,
    );
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final file = File('${outDir.path}${Platform.pathSeparator}$filename');
    file.writeAsBytesSync(result.bytes, flush: true);

    // The manifest is what tells a generated file apart from a real
    // Packet Tracer save, so it must be written wherever the file is.
    final manifest = File('${file.path}.netbuilder.json');
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'generator': 'on-device',
        'source': 'dart',
        'file': file.uri.pathSegments.last,
        'devices': result.refIds.length,
        'links': planned.links.length,
        'refIds': result.refIds,
        'warnings': result.warnings,
      }),
      flush: true,
    );

    return OnDeviceBuild(
      file: file,
      xml: result.xml,
      refIds: result.refIds,
      warnings: result.warnings,
      manifest: manifest,
    );
  }

  /// Read a built file back and describe it, using the same audit the
  /// verification step needs on either platform.
  static PktAudit audit(Uint8List bytes) {
    final xml = String.fromCharCodes(decryptPkt(bytes));
    final lib = SeedLibrary.fromXml(xml);
    final names = <String>[
      for (final m in RegExp(
        r'<NAME translate="true">([^<]*)</NAME>',
      ).allMatches(xml))
        m.group(1)!,
    ];
    return PktAudit(
      devices: lib.devices.length,
      kinds: lib.kinds,
      links: RegExp(r'<LINK>').allMatches(xml).length,
      names: names,
    );
  }

  /// Packet Tracer model names as the seed library files them.
  static String _modelFor(String? model) {
    final m = (model ?? '').trim();
    if (m.isEmpty) return '';
    // "2811" and "Cisco 2811" must find the same template.
    final digits = RegExp(r'\d{3,4}[A-Za-z0-9\-]*').firstMatch(m);
    return digits?.group(0) ?? m;
  }
}

/// What is inside a built file, read back through the codec.
class PktAudit {
  final int devices;
  final Set<String> kinds;
  final int links;
  final List<String> names;

  const PktAudit({
    required this.devices,
    required this.kinds,
    required this.links,
    required this.names,
  });
}