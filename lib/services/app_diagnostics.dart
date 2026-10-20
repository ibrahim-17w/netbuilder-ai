import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'credential_redaction.dart';

/// The app's local, rotating error log.
///
/// Nothing here leaves the machine. The log exists so a tester can say what
/// happened after the window closed, and so the existing diagnostics export
/// can carry the app side of a failure alongside the sidecar journal. Every
/// line is passed through [CredentialRedaction] before it touches disk.
class AppDiagnostics {
  AppDiagnostics._({Directory? directory, this._maxBytes = 512 * 1024})
    : _directoryOverride = directory;

  /// A test instance with its own directory. Production uses [instance].
  @visibleForTesting
  factory AppDiagnostics.forTesting({
    required Directory directory,
    int maxBytes = 512 * 1024,
  }) => AppDiagnostics._(directory: directory, maxBytes: maxBytes);

  static final AppDiagnostics instance = AppDiagnostics._();

  static const _fileName = 'netbuilder.log';
  static const _oldFileCount = 2;

  final Directory? _directoryOverride;
  final int _maxBytes;
  Future<void> _writes = Future<void>.value();
  bool _installed = false;

  /// Whether the global handlers have been installed. Unit tests and
  /// standalone widgets leave this false, so startup failures do not create a
  /// log in the developer's real support directory.
  bool get installed => _installed;

  /// Capture framework errors and uncaught asynchronous errors.
  ///
  /// Call once after [WidgetsFlutterBinding.ensureInitialized] and before
  /// `runApp`. The previous Flutter error handler still runs, so debug builds
  /// keep their red console output.
  void install() {
    if (_installed) return;
    _installed = true;
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      previous?.call(details);
      unawaited(
        record('flutter', details.exceptionAsString(), stack: details.stack),
      );
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(record('uncaught', error, stack: stack));
      return true;
    };
  }

  /// Append one redacted event. Failures to log are deliberately swallowed:
  /// a full disk must not turn a diagnosable bug into a second crash.
  Future<void> record(String kind, Object error, {StackTrace? stack}) {
    _writes = _writes.then((_) => _append(kind, error, stack));
    return _writes;
  }

  Future<void> _append(String kind, Object error, StackTrace? stack) async {
    try {
      final file = await _logFile();
      await _rotateIfNeeded(file);
      final stamp = DateTime.now().toUtc().toIso8601String();
      final message = _clip(
        CredentialRedaction.redact('$error'),
        maxLength: 16 * 1024,
      );
      final trace = stack == null
          ? ''
          : '\n${_clip(CredentialRedaction.redact('$stack'), maxLength: 24 * 1024)}';
      await file.writeAsString(
        '[$stamp] $kind: $message$trace\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Logging must never be the reason the app fails.
    }
  }

  Future<void> _rotateIfNeeded(File file) async {
    if (!await file.exists()) return;
    if (await file.length() <= _maxBytes) return;
    final oldest = File('${file.path}.$_oldFileCount');
    if (await oldest.exists()) await _deleteQuietly(oldest);
    for (var index = _oldFileCount - 1; index >= 1; index--) {
      final from = File('${file.path}.$index');
      if (await from.exists()) {
        await _renameQuietly(from, File('${file.path}.${index + 1}'));
      }
    }
    await _renameQuietly(file, File('${file.path}.1'));
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }

  Future<void> _renameQuietly(File from, File to) async {
    try {
      await from.rename(to.path);
    } catch (_) {}
  }

  /// Read the newest log text for a diagnostics bundle. Oldest rotation first,
  /// then the current file, capped so a pathological log cannot make export
  /// unbounded.
  Future<String> exportText({int maxLength = 300 * 1024}) async {
    await _writes;
    try {
      final file = await _logFile();
      final parts = <String>[];
      for (var index = _oldFileCount; index >= 1; index--) {
        final old = File('${file.path}.$index');
        if (await old.exists()) parts.add(await old.readAsString());
      }
      if (await file.exists()) parts.add(await file.readAsString());
      final all = parts.join();
      return all.length <= maxLength
          ? all
          : all.substring(all.length - maxLength);
    } catch (_) {
      return '';
    }
  }

  /// The current log path, for the Settings/Memory diagnostics card.
  Future<String?> currentPath() async {
    try {
      return (await _logFile()).path;
    } catch (_) {
      return null;
    }
  }

  Future<File> _logFile() async {
    final directory = _directoryOverride ?? await _defaultDirectory();
    await directory.create(recursive: true);
    return File(p.join(directory.path, _fileName));
  }

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'netbuilder', 'logs'));
  }

  static String _clip(String text, {required int maxLength}) {
    return text.length <= maxLength
        ? text
        : '${text.substring(0, maxLength)}...';
  }
}
