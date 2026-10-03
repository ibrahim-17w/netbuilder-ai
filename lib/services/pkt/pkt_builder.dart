/// Builds a real Packet Tracer save, on the device, with no sidecar.
///
/// The save format is not something that can be invented: every device model
/// carries a module and port tree that only Packet Tracer knows. So the app
/// clones those blocks out of a save the user already has ([SeedLibrary]),
/// renames them, gives them fresh identities, places them on the canvas and
/// writes the result back through the on-device codec.
///
/// Everything the app does not understand - options, scenarios, the
/// geographic view, the filters - is carried over from the seed untouched.
/// Rewriting what we did not have to is how a save gets corrupted.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'pkt_codec.dart';
import 'seed_library.dart';

/// One device to place in the lab.
class PktDeviceSpec {
  final String name;
  final String type;
  final String model;

  /// Canvas position in the logical workspace.
  final num x;
  final num y;

  const PktDeviceSpec({
    required this.name,
    required this.type,
    this.model = '',
    this.x = 0,
    this.y = 0,
  });
}

/// One cable between two already-placed devices.
class PktLinkSpec {
  final String fromDevice;
  final String fromPort;
  final String toDevice;
  final String toPort;

  /// 'eSerial' for a WAN cable, 'eCopperCross' for a straight-through run.
  final String type;

  /// True when this end is the clock source for a serial link.
  final bool dceAtFrom;

  const PktLinkSpec({
    required this.fromDevice,
    required this.fromPort,
    required this.toDevice,
    required this.toPort,
    this.type = 'eCopperCross',
    this.dceAtFrom = false,
  });
}

/// The result of a build, and everything that could not be done.
class PktBuildResult {
  final Uint8List bytes;

  /// The save document before encryption, kept for verification and for the
  /// report the user reads next to the file.
  final String xml;

  /// Device name -> the save reference id it was given, so links and reports
  /// can talk about the same device.
  final Map<String, String> refIds;

  /// Things the seed could not supply. Never silently dropped: a lab missing
  /// a switch is a lab that does not do what the user asked.
  final List<String> warnings;

  const PktBuildResult({
    required this.bytes,
    required this.xml,
    required this.refIds,
    required this.warnings,
  });
}

/// Compiles a plan into a Packet Tracer save.
class PktBuilder {
  const PktBuilder._();

  /// Build a .pkt from [devices] (and optionally [links]) using [seed].
  ///
  /// Throws [PktFormatError] when the seed cannot be read at all. Individual
  /// devices the seed cannot supply are reported in [PktBuildResult.warnings]
  /// rather than throwing, because one unsupported model should not cost the
  /// user the other nineteen devices.
  static PktBuildResult build({
    required SeedLibrary seed,
    required List<PktDeviceSpec> devices,
    List<PktLinkSpec> links = const <PktLinkSpec>[],
  }) {
    if (seed.isEmpty) {
      throw const PktFormatError(
        'the seed save has no devices to clone, so there is nothing to build '
        'from. Open a real Packet Tracer save and import it first.',
      );
    }
    final warnings = <String>[];
    final refIds = <String, String>{};
    final blocks = <String>[];

    // Ref ids must be unique inside the document or Packet Tracer binds the
    // cable to the wrong box. Seeded from the plan (not the clock) so the
    // same plan always produces the same file.
    var refCounter = 1;
    final taken = <String>{};
    for (final m in RegExp(r'save-ref-id:(\d+)').allMatches(seed.document)) {
      taken.add(m.group(1)!);
    }
    String nextRefId() {
      while (taken.contains('$refCounter')) {
        refCounter++;
      }
      final id = '$refCounter';
      taken.add(id);
      refCounter++;
      return id;
    }

    for (final spec in devices) {
      final template =
          seed.templateFor(spec.type, model: spec.model.isEmpty ? null : spec.model);
      if (template == null) {
        warnings.add(
          'No template for ${spec.name}: the seed save has no '
          '${spec.type}${spec.model.isEmpty ? '' : ' ${spec.model}'}. '
          'Import a save that contains one.',
        );
        continue;
      }
      final ref = nextRefId();
      refIds[spec.name] = ref;
      blocks.add(
        _cloneDevice(
          template.xml,
          name: spec.name,
          refId: ref,
          x: spec.x,
          y: spec.y,
        ),
      );
    }

    final linkXml = _buildLinks(seed, links, refIds, warnings);
    var document = _replaceSection(seed.document, 'DEVICES', blocks.join());
    document = _replaceSection(document, 'LINKS', linkXml);

    // Control characters make a save unopenable, and a pasted config or a
    // harvested block can carry one.
    final safe = xmlSafe(Uint8List.fromList(utf8.encode(document)));
    final finalXml = utf8.decode(safe);

    return PktBuildResult(
      bytes: encryptPkt(finalXml),
      xml: finalXml,
      refIds: refIds,
      warnings: warnings,
    );
  }

  /// Rename, re-identify and place one cloned device block.
  ///
  /// The `<NAME>` that is rewritten is the one inside `<ENGINE>`, not any
  /// other: a device block also names things in its own configuration, and
  /// rewriting those would rename the wrong thing.
  static String _cloneDevice(
    String block, {
    required String name,
    required String refId,
    required num x,
    required num y,
  }) {
    var out = block;
    final engineStart = out.indexOf('<ENGINE>');
    final engineEnd = out.indexOf('</ENGINE>');
    if (engineStart >= 0 && engineEnd > engineStart) {
      final engine = out.substring(engineStart, engineEnd);
      final renamed = engine.replaceAllMapped(
        RegExp(r'<NAME\b[^>]*>.*?</NAME>', dotAll: true),
        (_) => '<NAME translate="true">${_escapeXml(name)}</NAME>',
      );
      out = out.substring(0, engineStart) + renamed +
          out.substring(engineEnd);
    }
    out = out.replaceAll(
      RegExp(r'<SAVE_REF_ID>[^<]*</SAVE_REF_ID>'),
      '<SAVE_REF_ID>save-ref-id:$refId</SAVE_REF_ID>',
    );
    out = _placeLogical(out, x, y);
    return out;
  }

  /// Set the canvas position inside `<WORKSPACE><LOGICAL>`.
  ///
  /// The physical workspace is the decorative geographic view and is left
  /// alone: it is not where devices are drawn.
  static String _placeLogical(String block, num x, num y) {
    final ws = block.indexOf('<WORKSPACE>');
    if (ws < 0) return block;
    final logical = block.indexOf('<LOGICAL>', ws);
    if (logical < 0) return block;
    final close = block.indexOf('</LOGICAL>', logical);
    if (close < 0) return block;
    final inner = block.substring(logical, close);
    var replaced = inner.replaceAllMapped(
      RegExp(r'<X>-?\d+(?:\.\d+)?</X>'),
      (_) => '<X>${_num(x)}</X>',
    );
    replaced = replaced.replaceAllMapped(
      RegExp(r'<Y>-?\d+(?:\.\d+)?</Y>'),
      (_) => '<Y>${_num(y)}</Y>',
    );
    return block.substring(0, logical) + replaced + block.substring(close);
  }

  /// Build the `<LINKS>` content, cloning the seed's cable block.
  ///
  /// A cable block is verbose and version-specific, so it is cloned from the
  /// seed and retargeted rather than synthesised. When the seed has no cable
  /// to copy, the link is reported instead of guessed.
  static String _buildLinks(
    SeedLibrary seed,
    List<PktLinkSpec> links,
    Map<String, String> refIds,
    List<String> warnings,
  ) {
    if (links.isEmpty) return '';
    final template = _seedLinkBlock(seed.document);
    if (template == null) {
      warnings.add(
        'The seed save has no cable to copy, so ${links.length} link(s) were '
        'left out. Import a save that has at least one cable.',
      );
      return '';
    }
    final out = <String>[];
    for (final link in links) {
      final from = refIds[link.fromDevice];
      final to = refIds[link.toDevice];
      if (from == null || to == null) {
        warnings.add(
          'Link ${link.fromDevice}:${link.fromPort} - '
          '${link.toDevice}:${link.toPort} skipped: one end was not built.',
        );
        continue;
      }
      final dceRef = link.dceAtFrom ? from : to;
      final dcePort = link.dceAtFrom ? link.fromPort : link.toPort;
      var block = template
          .replaceAll(
            RegExp(r'<TYPE>[^<]*</TYPE>'),
            '<TYPE>${_escapeXml(link.type)}</TYPE>',
          )
          .replaceAll(
            RegExp(r'<FROM>[^<]*</FROM>'),
            '<FROM>save-ref-id:$from</FROM>',
          )
          .replaceAll(
            RegExp(r'<TO>[^<]*</TO>'),
            '<TO>save-ref-id:$to</TO>',
          );
      // Each end owns the <PORT> that follows its reference. Retargeting by
      // position (rather than replacing every PORT) is what keeps the two
      // ends from swapping each other's port.
      block = _replaceFirstPortAfter(block, '<FROM>', link.fromPort);
      block = _replaceFirstPortAfter(block, '<TO>', link.toPort);
      block = block
          .replaceAll(
            RegExp(r'<DCEDEV>[^<]*</DCEDEV>'),
            '<DCEDEV>save-ref-id:$dceRef</DCEDEV>',
          )
          .replaceAll(
            RegExp(r'<DCEPORT>[^<]*</DCEPORT>'),
            '<DCEPORT>${_escapeXml(dcePort)}</DCEPORT>',
          );
      out.add(block);
    }
    return out.join();
  }

  /// The first `<LINK>...</LINK>` block in a document, or null.
  static String? _seedLinkBlock(String document) {
    const open = '<LINK>';
    const close = '</LINK>';
    final start = document.indexOf(open);
    if (start < 0) return null;
    final end = document.indexOf(close, start);
    if (end < 0) return null;
    return document.substring(start, end + close.length);
  }

  /// Replace the first `<PORT>` that follows [marker] with [port].
  static String _replaceFirstPortAfter(
    String block,
    String marker,
    String port,
  ) {
    final markerAt = block.indexOf(marker);
    if (markerAt < 0) return block;
    final match =
        RegExp(r'<PORT>[^<]*</PORT>').firstMatch(block.substring(markerAt));
    if (match == null) return block;
    final at = markerAt + match.start;
    return block.replaceRange(
      at,
      at + match.group(0)!.length,
      '<PORT>${_escapeXml(port)}</PORT>',
    );
  }

  /// Replace the contents of a top-level section, keeping the tags.
  ///
  /// If the section is missing it is created inside `<NETWORK>`, so a save
  /// that has never had a cable still gets a valid `<LINKS></LINKS>`.
  static String _replaceSection(String document, String tag, String content) {
    final open = '<$tag>';
    final close = '</$tag>';
    final start = document.indexOf(open);
    final end = document.indexOf(close, start >= 0 ? start : 0);
    if (start >= 0 && end > start) {
      return document.substring(0, start + open.length) +
          content +
          document.substring(end);
    }
    final network = document.indexOf('<NETWORK>');
    if (network < 0) return document;
    final at = document.indexOf('</NETWORK>', network);
    if (at < 0) return document;
    return '${document.substring(0, at)}$open$content$close'
        '${document.substring(at)}';
  }

  static String _num(num v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static String _escapeXml(String value) => const HtmlEscape(HtmlEscapeMode.attribute)
      .convert(value)
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"');
}