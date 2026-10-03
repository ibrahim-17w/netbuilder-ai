/// What a Packet Tracer save can teach the app.
///
/// A .pkt save contains fully-formed device blocks: the module and port trees
/// that Packet Tracer needs in order to open the file. Those blocks are the
/// one part of the format that cannot be invented - they are the shape of
/// each hardware model. So the app learns them from a save the USER already
/// has, on their own device, the same way the desktop extractor learns them
/// from saves on the PC.
///
/// Nothing Cisco-authored is shipped in the app, and no sidecar is needed:
/// the user picks one .pkt once and the app can clone from it offline
/// forever. That is what makes building .pkt files possible on a phone.
library;

import 'dart:convert';

import 'pkt_codec.dart';

/// One device inside a seed save.
class SeedDevice {
  /// The `<NAME>` value, which is what the user sees in Packet Tracer.
  final String name;

  /// 'Router', 'Switch', 'Pc', 'Server' and so on.
  final String type;

  /// The hardware model, e.g. '2811'. Empty when the save does not name one.
  final String model;

  /// Packet Tracer's own display string for the model, e.g. '2811 IOS15'.
  final String customModel;

  /// The complete `<DEVICE>...</DEVICE>` block, byte for byte.
  final String xml;

  /// The key this device is filed under in the library, e.g. 'Router/2811'.
  String get key => '$type/$model';

  const SeedDevice({
    required this.name,
    required this.type,
    required this.model,
    required this.customModel,
    required this.xml,
  });
}

/// The devices a seed save can supply, indexed for cloning.
class SeedLibrary {
  final List<SeedDevice> devices;

  /// The document the devices were taken from, kept whole so a rebuilt save
  /// can reuse everything the app does not understand (options, canvas
  /// geometry, scenarios) instead of inventing it.
  final String document;

  const SeedLibrary({required this.devices, required this.document});

  /// Read a .pkt container and index the devices inside it.
  ///
  /// Throws [PktFormatError] when the file is not a save this codec reads.
  factory SeedLibrary.fromPkt(List<int> bytes) =>
      SeedLibrary.fromXml(utf8.decode(decryptPkt(bytes), allowMalformed: true));

  /// Index the devices in an already-decrypted save document.
  factory SeedLibrary.fromXml(String xml) {
    final devices = <SeedDevice>[];
    final blocks = _deviceBlocks(xml);
    for (final block in blocks) {
      final type = _tagValue(block, 'TYPE', engineOnly: true);
      if (type == null) continue;
      final customModel = _attribute(_typeTag(block), 'customModel');
      final model = _attribute(_typeTag(block), 'model');
      devices.add(
        SeedDevice(
          name: _tagValue(block, 'NAME') ?? '',
          type: type,
          model: model ?? '',
          customModel: customModel ?? '',
          xml: block,
        ),
      );
    }
    return SeedLibrary(devices: devices, document: xml);
  }

  bool get isEmpty => devices.isEmpty;

  /// How many devices of each model the seed can supply.
  ///
  /// Two saves of a 2811 mean the app can build two 2811s with confidence;
  /// one means it can build one and would be guessing beyond that.
  Map<String, int> get inventory {
    final counts = <String, int>{};
    for (final d in devices) {
      counts[d.key] = (counts[d.key] ?? 0) + 1;
    }
    return counts;
  }

  /// The kinds of device the seed covers, e.g. 'Router', 'Switch', 'Pc'.
  Set<String> get kinds => {for (final d in devices) d.type};

  /// A device block to clone, preferring an exact model match.
  ///
  /// Returns null when the seed cannot supply that model - the caller must
  /// report that rather than substitute something that looks close, because a
  /// lab with the wrong hardware silently does not teach the right thing.
  SeedDevice? templateFor(String type, {String? model}) {
    final wantedType = type.trim().toLowerCase();
    final wantedModel = (model ?? '').trim();
    if (wantedModel.isNotEmpty) {
      for (final d in devices) {
        if (d.type.trim().toLowerCase() == wantedType && d.model == wantedModel) {
          return d;
        }
      }
      return null;
    }
    for (final d in devices) {
      if (d.type.trim().toLowerCase() == wantedType) return d;
    }
    return null;
  }

  /// Every model the seed has, for the picker to show.
  List<({String type, String model, int available})> get catalogue => [
        for (final entry in inventory.entries)
          (
            type: entry.key.split('/').first,
            model: entry.key.split('/').length > 1
                ? entry.key.split('/')[1]
                : '',
            available: entry.value,
          ),
      ]..sort((a, b) {
          final byType = a.type.compareTo(b.type);
          return byType != 0 ? byType : a.model.compareTo(b.model);
        });

  // --- scanning -----------------------------------------------------------

  /// Every top-level `<DEVICE>...</DEVICE>` block in the document.
  ///
  /// Depth-aware rather than a plain substring search: a device block
  /// contains nested `<MODULE>` and `<PORT>` elements, and a scan that just
  /// looked for the next `</DEVICE>` would still be correct only by luck of
  /// the format. Counting tags makes it correct by construction.
  static List<String> _deviceBlocks(String xml) {
    const open = '<DEVICE>';
    const close = '</DEVICE>';
    final blocks = <String>[];
    var index = 0;
    while (true) {
      final start = xml.indexOf(open, index);
      if (start < 0) break;
      var depth = 0;
      var cursor = start;
      int? end;
      while (cursor < xml.length) {
        final nextOpen = xml.indexOf(open, cursor);
        final nextClose = xml.indexOf(close, cursor);
        if (nextClose < 0) break;
        if (nextOpen >= 0 && nextOpen < nextClose) {
          depth++;
          cursor = nextOpen + open.length;
        } else {
          depth--;
          cursor = nextClose + close.length;
          if (depth == 0) {
            end = cursor;
            break;
          }
        }
      }
      if (end == null) break;
      blocks.add(xml.substring(start, end));
      index = end;
    }
    return blocks;
  }

  /// The `<TYPE>` tag inside a device block, as a whole tag string.
  ///
  /// Only the engine's own type counts: `<TYPE>` also appears deep inside the
  /// module tree (`eNonRemovableModule`), and reading one of those would file
  /// every router as a module.
  static String _typeTag(String block) {
    final engine = block.indexOf('<ENGINE>');
    if (engine < 0) return block;
    final end = block.indexOf('</ENGINE>', engine);
    final scope = block.substring(engine, end < 0 ? block.length : end);
    final match = RegExp(r'<TYPE\b[^>]*>').firstMatch(scope);
    return match == null ? '' : match.group(0)!;
  }

  static String? _tagValue(String block, String tag, {bool engineOnly = false}) {
    final scope = engineOnly ? _engineScope(block) : block;
    final match =
        RegExp('<$tag[^>]*>(.*?)</$tag>', dotAll: true).firstMatch(scope);
    if (match == null) return null;
    final value = match.group(1)!.trim();
    return value.isEmpty ? null : value;
  }

  static String _engineScope(String block) {
    final engine = block.indexOf('<ENGINE>');
    if (engine < 0) return block;
    final end = block.indexOf('</ENGINE>', engine);
    return block.substring(engine, end < 0 ? block.length : end);
  }

  static String? _attribute(String tag, String name) {
    final match =
        RegExp('$name="([^"]*)"').firstMatch(tag);
    return match?.group(1);
  }

  /// The first `<TYPE>` element's own text, with the tags removed.
  static String? _typeText(String block) {
    final tag = _typeTag(block);
    final open = tag.indexOf('>');
    if (open < 0) return null;
    final end = block.indexOf('</TYPE>', open);
    if (end < 0) return null;
    final value = block.substring(open + 1, end).trim();
    return value.isEmpty ? null : value;
  }
}

/// Read a device's kind ('Router', 'Pc', ...) out of its block.
///
/// Exposed for the assembler, which needs the same rule the extractor used:
/// the ENGINE's type, never a module type nested below it.
String? seedDeviceTypeOf(String deviceXml) => SeedLibrary._typeText(deviceXml);