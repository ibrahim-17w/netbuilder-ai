import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The bearer token this app and the engine it launches share.
///
/// The sidecar is loopback-only, but loopback is not trusted: a page in the
/// user's browser can POST to 127.0.0.1, and the engine clicks and types.
/// The server refuses cross-origin requests and a foreign `Host`; the token
/// is the second lock, for anything else running on this machine.
///
/// It is persisted, not generated per launch. A launch is not the unit that
/// has to agree: if the app is restarted while the engine it started is still
/// running, the engine holds the token from the earlier launch. A fresh token
/// would then be a 401 on every route until the engine was restarted.
///
/// Every failure is a soft failure. No writable directory means no token,
/// which leaves the Origin/Host guard in place rather than making the app
/// unable to talk to its own engine.
class EngineToken {
  EngineToken._();

  static const _fileName = '.engine_token';
  static const _length = 32; // bytes, rendered as 64 hex characters

  static final RegExp _shape = RegExp(r'^[0-9a-f]{64}$');

  static String? _cached;
  static Future<String>? _loading;

  /// Where the token lives. Injectable so a test never touches the real
  /// application-support directory.
  @visibleForTesting
  static Future<Directory> Function() directoryResolver =
      getApplicationSupportDirectory;

  /// The token when it is already loaded; empty means "not loaded yet" and
  /// also "there is none". Call [ensure] before depending on either.
  static String get current => _cached ?? '';

  /// Read the persisted token, creating it on first use.
  static Future<String> ensure() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  static Future<String> _load() async {
    try {
      final dir = await directoryResolver();
      final file = File(p.join(dir.path, _fileName));
      if (await file.exists()) {
        final saved = (await file.readAsString()).trim();
        if (_shape.hasMatch(saved)) return _cached = saved;
      }
      final token = _newToken();
      await file.parent.create(recursive: true);
      await file.writeAsString(token, flush: true);
      return _cached = token;
    } catch (_) {
      // Missing plugin in a widget test, a read-only install, a profile that
      // cannot be written: the app still works, just without the token.
      return _cached = '';
    }
  }

  static String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(_length, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @visibleForTesting
  static void resetForTest() {
    _cached = null;
    _loading = null;
  }
}
