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
import '../network_math.dart';
import 'pkt_builder.dart';
import 'pkt_codec.dart';
import 'pkt_engine_builder.dart';
import 'seed_library.dart';
import 'template_library.dart';

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

  /// The generator's own record of what it wrote - device entries with the
  /// ports each planned interface landed on, the layout actually used, the
  /// planned vs built counts. Null for the legacy seed route, which does not
  /// resolve ports. Shape matches `/pkt/generate`'s `report` so the chat's
  /// verification step treats both routes alike.
  final Map<String, dynamic>? report;

  const OnDeviceBuild({
    required this.file,
    required this.xml,
    required this.refIds,
    required this.warnings,
    required this.manifest,
    this.report,
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

  /// Where built labs are written inside [appDir] when the caller names no
  /// folder of its own.
  ///
  /// The app's own documents directory, which on Android is app-private and
  /// needs no runtime permission - but which is also somewhere the user cannot
  /// browse. It is a working fallback, not a destination: callers that know of
  /// a folder the user chose should pass [buildFromPlan]'s `outDir` instead.
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

  /// Compile [plan] - exactly what `PacketTracerAdapter.autopilotPlan`
  /// produces - into a .pkt using the bundled template library, and write it
  /// into this device's output directory.
  ///
  /// This is the phone's full-parity route: the same variant selection, port
  /// resolution, running configs, end-device IP settings, server Services
  /// panels and physical-workspace rebuild the PC engine does, ported to
  /// Dart in [pkt_engine_builder.dart]. Returns null when the plan carries
  /// no devices at all.
  static Future<OnDeviceBuild?> buildFromPlan({
    required Map<String, dynamic> plan,
    required Future<Directory> Function() appDir,
    String filename = 'lab.pkt',
    String project = '',
    /// Where to write the finished lab, when the caller knows of a folder the
    /// user can browse. Falls back to [appDir]'s private `pkt` directory -
    /// which on Android is somewhere no file manager can see.
    Future<Directory> Function()? outDir,
  }) async {
    var planned = 0;
    for (final step in (plan['steps'] as List?) ?? const <dynamic>[]) {
      if (step is Map && step['action'] == 'create_nodes') {
        planned = ((step['nodes'] as List?) ?? const []).length;
      }
    }
    if (planned == 0) return null;
    // Everything above runs without touching the platform: a plan with no
    // devices is answered before any plugin call, and the library build is
    // pure Dart over bundled assets. The directory is resolved only when
    // there is a file to write into it.
    final library = await PktTemplateLibrary.loadBundled();
    final built = await buildPkt(
      plan: plan,
      library: library,
      project: project,
    );
    final out = outDir == null ? outDirIn(await appDir()) : await outDir();
    if (!out.existsSync()) out.createSync(recursive: true);
    final file = File('${out.path}${Platform.pathSeparator}$filename');
    // Atomic write, the way the sidecar does it: a torn file must never be
    // mistaken for a save.
    final tmp = File('${file.path}.tmp');
    tmp.writeAsBytesSync(encryptPkt(built.xml), flush: true);
    tmp.renameSync(file.path);

    final refIds = {
      for (final e in built.refIds.entries) e.key: '${e.value}',
    };
    // The manifest is what tells a generated file apart from a real
    // Packet Tracer save, so it must be written wherever the file is.
    final manifest = File('${file.path}.netbuilder.json');
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'generator': 'on-device',
        'source': 'dart-template-library',
        'file': file.uri.pathSegments.last,
        'devices': built.deviceCount,
        'links': built.linkCount,
        'plannedDevices': built.plannedDevices,
        'plannedLinks': built.plannedLinks,
        'refIds': refIds,
        'warnings': built.warnings,
      }),
      flush: true,
    );

    return OnDeviceBuild(
      file: file,
      xml: built.xml,
      refIds: refIds,
      warnings: built.warnings,
      manifest: manifest,
      report: {
        'path': file.path,
        'name': file.uri.pathSegments.last,
        'version': built.version,
        'deviceCount': built.deviceCount,
        'linkCount': built.linkCount,
        'plannedDevices': built.plannedDevices,
        'plannedLinks': built.plannedLinks,
        'devices': built.devices,
        'links': built.links,
        'warnings': built.warnings,
        'layout': built.layout,
        'generator': 'on-device',
      },
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

  /// Read a .pkt back and describe it the way the engine's `/pkt/audit`
  /// does, so the chat's plan-vs-file verification runs without a special
  /// case for on-device builds. Only `devices` (name/type/model per entry)
  /// is load-bearing for that check; the rest is the honest report the chat
  /// message shows.
  static Map<String, dynamic> auditReport(
    Uint8List bytes, {
    String path = '',
    String project = '',
  }) {
    final doc = utf8.decode(decryptPkt(bytes), allowMalformed: true);
    final devices = <Map<String, dynamic>>[];
    final refNames = <String, String>{};
    final servicesEnabled = <String>[];
    for (final block in SeedLibrary.deviceBlocksOf(doc)) {
      final device = SeedLibrary.deviceFromBlock(block);
      if (device == null) continue;
      final ref = RegExp(r'<SAVE_REF_ID>save-ref-id:([^<]+)</SAVE_REF_ID>')
          .firstMatch(block)
          ?.group(1);
      if (ref != null) refNames[ref] = device.name;
      final configMatch = RegExp(
        r'<RUNNINGCONFIG(?:\s[^>]*)?>.*?</RUNNINGCONFIG>',
        dotAll: true,
      ).firstMatch(block);
      final configLines = configMatch == null
          ? 0
          : RegExp(r'<LINE>').allMatches(configMatch.group(0)!).length;
      final enabled = _enabledServices(block);
      servicesEnabled.addAll(enabled.map((s) => '${device.name}:$s'));
      devices.add({
        'name': device.name,
        'type': device.type,
        'model': device.model,
        'interfaces': <Map<String, dynamic>>[],
        'config_lines': configLines,
        'findings': <String>[],
        'services': enabled,
        'probes': <String>[],
        'ipcfg': _ipConfigOf(configMatch?.group(0) ?? ''),
      });
    }
    final links = <Map<String, dynamic>>[];
    final linkBlockRe = RegExp(r'<LINK>.*?</LINK>', dotAll: true);
    for (final match in linkBlockRe.allMatches(doc)) {
      final block = match.group(0)!;
      final fromRef =
          RegExp(r'<FROM>save-ref-id:([^<]+)</FROM>').firstMatch(block)?.group(1);
      final toRef =
          RegExp(r'<TO>save-ref-id:([^<]+)</TO>').firstMatch(block)?.group(1);
      final typeTags = RegExp(r'<TYPE>([^<]*)</TYPE>')
          .allMatches(block)
          .map((m) => m.group(1)!)
          .toList();
      links.add({
        'a': refNames[fromRef ?? ''] ?? (fromRef ?? ''),
        'aIf': firstPortAfter(block, '<FROM>'),
        'b': refNames[toRef ?? ''] ?? (toRef ?? ''),
        'bIf': firstPortAfter(block, '<TO>'),
        'medium': typeTags.isNotEmpty ? typeTags.first : '',
        'cable': typeTags.length > 1 ? typeTags.last : '',
      });
    }
    final findings = _semanticFindings(devices, links);
    return {
      'mode': 'on-device',
      'generated': DateTime.now().toUtc().toIso8601String(),
      'path': path,
      'project': project,
      'devices': devices,
      'linkCount': links.length,
      'links': links,
      'findings': findings,
      'summary': {
        'devices': devices.length,
        'links': links.length,
        'servicesEnabled': servicesEnabled.length,
        'findings': findings.length,
        'high': findings.length,
      },
      'note': 'audited on this device by the same codec that wrote it',
    };
  }

  /// The addresses this device's own config block declares, as CIDRs.
  ///
  /// The audit used to report `'ipcfg': {}` for every device, which meant the
  /// file carried no addressing at all and no duplicate address could ever be
  /// detected - the check reported clean because it had nothing to look at.
  /// Reading the address lines out of the same block the codec just wrote is
  /// what makes the duplicate-address finding possible.
  static Map<String, dynamic> _ipConfigOf(String config) {
    final found = <String>[];
    for (final m in RegExp(
      r'ip\s+address\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d{1,3}(?:\.\d{1,3}){3})',
      caseSensitive: false,
    ).allMatches(config)) {
      // Configs store dotted masks (Packet Tracer replays `ip address A B`),
      // so the prefix is derived from the mask. prefixFromMask counts the
      // contiguous 1-bits, which covers every mask /0 through /32; the old
      // table here only knew /16, /24 and /32, so a lab subnetted the way
      // labs actually are - /25 to /30 - had its addresses vanish from this
      // audit and two interfaces could share one without a finding. A mask
      // with no prefix form (discontiguous, e.g. 255.0.255.0) is left out
      // rather than reported with an invented one.
      final prefix = NetworkMath.prefixFromMask(m.group(2)!);
      if (prefix == null) continue;
      final cidr = '${m.group(1)!}/$prefix';
      if (!found.contains(cidr)) found.add(cidr);
    }
    return <String, dynamic>{'addresses': found};
  }

  /// The defect CLASSES this file carries, in the same words the repair pass
  /// uses, so a finding from the builder and a finding from the repair pass
  /// can be compared rather than translated.
  static List<String> _semanticFindings(
    List<Map<String, dynamic>> devices,
    List<Map<String, dynamic>> links,
  ) {
    final out = <String>[];

    // Duplicate interface address: two devices claiming one address.
    final claimed = <String, String>{};
    for (final d in devices) {
      final cfg = d['ipcfg'];
      final addrs = cfg is Map ? cfg['addresses'] : null;
      if (addrs is! List) continue;
      for (final a in addrs) {
        final ip = '$a'.split('/').first.trim();
        if (ip.isEmpty) continue;
        final first = claimed[ip];
        if (first == null) {
          claimed[ip] = '${d['name']}';
        } else if (first != '${d['name']}') {
          out.add(
            'duplicate_interface_address: $ip is claimed by both $first and '
            '${d['name']}',
          );
        }
      }
    }

    // Uncabled device: present in the file, connected to nothing.
    final cabled = <String>{};
    for (final l in links) {
      for (final end in ['a', 'b']) {
        final name = '${l[end] ?? ''}'.trim();
        if (name.isNotEmpty) cabled.add(name);
      }
    }
    final loose = <String>[];
    for (final d in devices) {
      final name = '${d['name']}'.trim();
      if (name.isEmpty || cabled.contains(name)) continue;
      // Cloud and standalone endpoints legitimately carry no cable, so only
      // infrastructure that must be wired is reported as uncabled.
      final type = '${d['type']}'.toLowerCase();
      if (type == 'cloud' || type == 'wireless' || type == 'access-point') {
        continue;
      }
      loose.add(name);
    }
    if (loose.isNotEmpty) {
      out.add('uncabled_device: ${loose.join(', ')} carry no cable');
    }
    return out;
  }

  /// The `<PORT>` text directly after [marker] in a link block - the port
  /// the FROM or TO end is cabled on. Each end owns the port that follows
  /// its reference.
  static String firstPortAfter(String block, String marker) {
    final at = block.indexOf(marker);
    if (at < 0) return '';
    final match =
        RegExp(r'<PORT>([^<]*)</PORT>').firstMatch(block.substring(at));
    return match?.group(1) ?? '';
  }

  /// The Services-tab roles a device block carries in the enabled state.
  static List<String> _enabledServices(String block) {    final enabled = <String>[];
    void check(String role, RegExp pattern) {
      if (pattern.hasMatch(block)) enabled.add(role);
    }

    check('dhcp', RegExp(r'<DHCP_SERVER>\s*<ENABLED>1'));
    check('dns', RegExp(r'<DNS_SERVER><ENABLED>1'));
    check('http', RegExp(r'<HTTP_SERVER><ENABLED>1'));
    check('https', RegExp(r'<HTTPSENABLED>1'));
    check('aaa', RegExp(r'<ACS_SERVER><ENABLED>1'));
    check('ftp', RegExp(r'<FTP_SERVER><ENABLED>1'));
    check('email', RegExp(r'<SMTP_ENABLED>1'));
    check('syslog', RegExp(r'<SYSLOG_SERVER><ENABLED>1'));
    check('ntp', RegExp(r'<NTP_SERVER><ENABLED>1'));
    check('tftp', RegExp(r'<TFTP_SERVER><ENABLED>1'));
    return enabled;
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