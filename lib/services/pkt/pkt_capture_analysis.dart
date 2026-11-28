import 'dart:io';
import 'dart:typed_data';

import 'on_device_pkt_builder.dart';
import 'pkt_codec.dart';

/// What a capture is, and what is inside it, with no engine at all.
///
/// The chat asks two things of a picked file before it says anything: what
/// format is this, and what does the saved network contain. On a desktop the
/// Python sidecar answers both. A phone has no sidecar, but it does carry the
/// same codec that reads and writes .pkt, so the second path lives here - the
/// one the phone uses, and the one a desktop falls back to when the engine is
/// not running.
///
/// The rules mirror the sidecar's `/pkt/identify` and `/pkt/audit`: a file is
/// called a save only after it decodes, and anything else gets a plain
/// explanation instead of a decrypt error.
class PktCaptureAnalysis {
  const PktCaptureAnalysis._();

  /// The same ceiling the export and the sidecar use, so a phone is never
  /// asked to hold a file two other parts of the app already refuse.
  static const int maxBytes = 80 * 1024 * 1024;

  static const List<int> _pcapMagicLe = [0xD4, 0xC3, 0xB2, 0xA1];
  static const List<int> _pcapMagicBe = [0xA1, 0xB2, 0xC3, 0xD4];
  static const List<int> _pcapMagicNsLe = [0x4D, 0x3C, 0xB2, 0xA1];
  static const List<int> _pcapMagicNsBe = [0xA1, 0xB2, 0x3C, 0x4D];
  static const List<int> _pcapngMagic = [0x0A, 0x0D, 0x0D, 0x0A];

  /// Identify a file on disk. Never throws for a wrong format: an unreadable
  /// or missing file comes back with [isPkt] false and a sentence saying so.
  static Future<Map<String, dynamic>> identify(
    String path, {
    String name = '',
  }) async {
    final label = name.trim().isEmpty ? _baseName(path) : name.trim();
    final file = File(path);
    try {
      if (!await file.exists()) {
        return _notPkt(
          'missing',
          '`$label` is not on this device any more. Pick it again from the folder it was saved in.',
        );
      }
      final length = await file.length();
      if (length == 0) {
        return _notPkt('empty', '`$label` is empty (0 bytes), so there is nothing to read.');
      }
      if (length > maxBytes) {
        return _notPkt(
          'too-large',
          '`$label` is ${_size(length)}; this reader stops at ${_size(maxBytes)}.',
        );
      }
      return identifyBytes(await file.readAsBytes(), name: label);
    } on FileSystemException catch (e) {
      return _notPkt(
        'unreadable',
        '`$label` could not be opened${e.osError == null ? '' : ' (${e.osError!.message})'}. Move it somewhere this app can read and try again.',
      );
    }
  }

  /// Identify bytes already in memory. A save is recognised by decoding it,
  /// not by its name or size: a renamed text file must not be called a .pkt.
  static Map<String, dynamic> identifyBytes(List<int> bytes, {String name = ''}) {
    final label = name.trim().isEmpty ? 'that file' : name.trim();
    final kind = _formatOf(bytes);
    if (kind == 'pkt') {
      return {
        'isPkt': true,
        'kind': kind,
        'message': '',
        'size': bytes.length,
      };
    }
    return _notPkt(kind, _unsupported(kind, label));
  }

  /// The on-device audit, on a background isolate: the same report shape the
  /// sidecar returns, so the chat does not need a second code path.
  static Future<Map<String, dynamic>> audit(
    String path, {
    String project = '',
  }) async {
    final file = File(path);
    final length = await file.length();
    if (length == 0 || length > maxBytes) {
      throw PktFormatError(
        length == 0
            ? 'that file is empty (0 bytes)'
            : 'that file is ${_size(length)}, over the ${_size(maxBytes)} limit',
      );
    }
    return OnDevicePktBuilder.auditReportInBackground(
      Uint8List.fromList(await file.readAsBytes()),
      path: path,
      project: project,
    );
  }

  static Map<String, dynamic> _notPkt(String kind, String message) => {
    'isPkt': false,
    'kind': kind,
    'message': message,
  };

  static String _formatOf(List<int> bytes) {
    if (_startsWith(bytes, _pcapngMagic) ||
        _startsWith(bytes, _pcapMagicLe) ||
        _startsWith(bytes, _pcapMagicBe) ||
        _startsWith(bytes, _pcapMagicNsLe) ||
        _startsWith(bytes, _pcapMagicNsBe)) {
      return _startsWith(bytes, _pcapngMagic) ? 'pcapng' : 'pcap';
    }
    // A .pka activity is a zip archive, not a save this codec reads.
    if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) return 'zip';
    final xmlLooking = _hasXmlPrefix(bytes);
    try {
      decryptPkt(bytes);
      return 'pkt';
    } on PktFormatError {
      return xmlLooking ? 'xml' : 'unknown';
    }
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _hasXmlPrefix(List<int> bytes) {
    for (var i = 0; i < bytes.length && i < 64; i++) {
      final b = bytes[i];
      if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0xEF ||
          b == 0xBB || b == 0xBF) {
        continue;
      }
      return b == 0x3C;
    }
    return false;
  }

  /// The in-chat explanation for a file this app cannot audit, matching the
  /// sidecar's wording so the same file gets the same answer on both.
  static String _unsupported(String kind, String label) {
    switch (kind) {
      case 'pcap':
        return '`$label` is a classic **.pcap** capture, not a Packet Tracer save. '
            'This reader works on .pkt saves (decrypt, audit, edit); packet '
            'captures need Wireshark or `tshark`. If the lab matters, save '
            'it from Packet Tracer as .pkt and analyze that.';
      case 'pcapng':
        return '`$label` is a **.pcapng** capture, not a Packet Tracer save. '
            'This reader works on .pkt saves; .pcapng parsing is not '
            'implemented.';
      case 'xml':
        return '`$label` is plain XML, not an encrypted save. If it is a '
            'decrypted .pkt, open it in Packet Tracer and save it again as '
            '.pkt so the app can audit the real file.';
      case 'zip':
        return '`$label` looks like a zipped Packet Tracer activity (.pka) '
            'rather than a .pkt save. Open it in Packet Tracer and use '
            'File > Save As to write a .pkt, then analyze that.';
      case 'empty':
        return '`$label` is empty (0 bytes), so there is nothing to read.';
      default:
        return '`$label` is not a Packet Tracer save this app can read. '
            'Expected a .pkt file saved by Packet Tracer.';
    }
  }

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes bytes';
  }

  static String _baseName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? path : parts.last;
  }
}