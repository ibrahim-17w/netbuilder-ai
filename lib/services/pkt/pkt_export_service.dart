import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Where a built .pkt ended up, and what the app can honestly say about it.
class PktExport {
  /// The path the user can look for. Empty when they cancelled the picker.
  final String path;

  /// True when the file went into the folder chosen in Settings, with no
  /// prompt. False when the system folder picker was shown.
  final bool inConfiguredFolder;

  final bool prompted;
  final bool cancelled;

  /// The companion manifest, when one went out with it.
  final String? companionPath;

  /// One sentence, written for the user and shown verbatim.
  final String message;

  const PktExport({
    this.path = '',
    this.inConfiguredFolder = false,
    this.prompted = false,
    this.cancelled = false,
    this.companionPath,
    required this.message,
  });
}

/// Getting a built .pkt out of the app's own storage.
///
/// A phone build used to land in the app-private documents directory and stop
/// there, with the only way out a share sheet. That is not "saving it": the
/// user picks a folder in Settings and expects files to appear there, and on
/// Android they cannot browse app-private storage at all, so a file saved
/// "somewhere" is a file they will never find.
///
/// Two ways out, in the order a user would expect:
///
/// 1. the folder chosen in Settings, written to directly - no prompt, which is
///    what "saves to the selected folder" has to mean;
/// 2. otherwise the system's own save dialog (`ACTION_CREATE_DOCUMENT` on
///    Android), which writes through the content resolver and is therefore the
///    only write that works under scoped storage. The user chooses the folder
///    and the real file lands there.
///
/// What this service will NOT do is report a location it did not write to. A
/// path is returned only when the file is really there.
class PktExportService {
  const PktExportService._();

  /// The configured output folder, when it is one the app can actually write
  /// to. Null for an unset, missing or read-only folder - and the reason is
  /// why, so callers can say something true instead of silently falling back.
  static Future<({Directory? dir, String why})> resolveFolder(
    String outputDir,
  ) async {
    final path = outputDir.trim();
    if (path.isEmpty) {
      return (dir: null, why: 'no folder has been chosen yet');
    }
    final dir = Directory(path);
    try {
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      return (dir: null, why: 'the folder "$path" cannot be created ($e)');
    }
    // Writability is checked, not assumed: on Android a picked SAF tree
    // often resolves to a path that exists and cannot be written, which is
    // exactly how a "save to the selected folder" setting silently stops
    // working. Probe with a real write rather than trusting the path.
    final probe = File('${dir.path}${Platform.pathSeparator}'
        '.netbuilder-write-test');
    try {
      probe.writeAsStringSync('ok', flush: true);
      await probe.delete();
    } catch (e) {
      return (dir: null, why: 'the folder "$path" is not writable ($e)');
    }
    return (dir: dir, why: '');
  }

  /// Copy [file] into [target] under its own name, refusing to overwrite a
  /// different lab. Returns the file written.
  static Future<File> copyInto(File file, Directory target) async {
    if (!target.existsSync()) await target.create(recursive: true);
    var out = File('${target.path}${Platform.pathSeparator}'
        '${file.uri.pathSegments.last}');
    if (out.existsSync() && await out.length() != await file.length()) {
      var n = 2;
      while (out.existsSync() && n < 50) {
        out = File('${target.path}${Platform.pathSeparator}'
            '${_stem(file.uri.pathSegments.last)}-$n'
            '${_ext(file.uri.pathSegments.last)}');
        n++;
      }
    }
    await out.writeAsBytes(await file.readAsBytes(), flush: true);
    return out;
  }

  /// Put [file] somewhere the user can browse themselves.
  ///
  /// [saveBytes] is the seam the tests replace; on a device it is
  /// [FilePicker.platform.saveFile], whose Android implementation shows the
  /// system save dialog and writes through the content resolver.
  static Future<PktExport> saveToChosenFolder(
    File file, {
    File? companion,
    String? suggestedName,
    Future<String?> Function({
      required String fileName,
      required Uint8List bytes,
      String? type,
      String? dialogTitle,
    })? saveBytes,
  }) async {
    final saver = saveBytes ?? _platformSave;
    final name = suggestedName ?? file.uri.pathSegments.last;
    try {
      final saved = await saver(
        fileName: name,
        bytes: await file.readAsBytes(),
        type: _ext(name).isEmpty ? null : _ext(name),
        dialogTitle: 'Save $name',
      );
      if (saved == null || saved.trim().isEmpty) {
        return const PktExport(
          cancelled: true,
          prompted: true,
          message: 'Cancelled - the file is unchanged, still on this device.',
        );
      }
      String? manifestPath;
      if (companion != null && companion.existsSync()) {
        // The manifest is what tells a generated file apart from a real save,
        // so it goes out too - but a cancelled second dialog must never undo
        // a .pkt the user already saved.
        final companionSaved = await saver(
          fileName: companion.uri.pathSegments.last,
          bytes: await companion.readAsBytes(),
          type: '.json',
          dialogTitle: 'Save the companion manifest too?',
        );
        manifestPath = companionSaved?.trim().isEmpty ?? true
            ? null
            : companionSaved;
      }
      return PktExport(
        path: saved,
        prompted: true,
        companionPath: manifestPath,
        message: 'Saved to $saved'
            '${manifestPath == null ? '' : ' (manifest alongside it)'}.',
      );
    } catch (e) {
      return PktExport(
        cancelled: true,
        prompted: true,
        message: 'Could not save it: $e. The file is still on this device.',
      );
    }
  }

  static Future<String?> _platformSave({
    required String fileName,
    required Uint8List bytes,
    String? type,
    String? dialogTitle,
  }) =>
      FilePicker.platform.saveFile(
        fileName: fileName,
        bytes: bytes,
        // The extension is carried by the file name; `FileType.any` keeps the
        // system dialog from filtering out .pkt on devices that only know
        // common types.
        type: FileType.any,
        dialogTitle: dialogTitle,
      );

  static String _stem(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }
}
