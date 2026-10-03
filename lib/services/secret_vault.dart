import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Project secrets (AAA keys, VPN pre-shared keys, wireless PSKs) live in
/// the OS keychain - never in prefs, the database, or an exported intent.
///
/// The build record stores the portable intent WITHOUT secrets
/// (`intent.toJson(includeSecrets: false)`); this vault holds the only copy,
/// keyed by project name, and `BuildArtifactService.restore` re-injects it
/// when the user reopens the project.  Secrets travel to the adapters
/// exactly as they did before - only where they are AT REST changes.
class SecretVault {
  static const _prefix = 'project_secret_';

  /// Every secret slot a project has. One list for the writer, the reader and
  /// the purger, so a slot cannot be written but never read back.
  static const _slots = [
    'aaaPassword',
    'aaaAccountPassword',
    'vpnPreSharedKey',
  ];

  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Swapped for an in-memory stand-in in tests; the app uses
  /// [_defaultStorage].
  @visibleForTesting
  static FlutterSecureStorage storage = _defaultStorage;

  /// Write the project's COMPLETE secret set: every slot in [_slots] is either
  /// written or removed, whatever [secrets] contains.
  ///
  /// Writing only the entries it was given left a removed password in the
  /// keychain forever - the user deleted it from the brief, the intent no
  /// longer carried it, and nothing in the app could overwrite it because
  /// there was no longer a value to write.  Treating the argument as the whole
  /// truth is what makes a re-save a re-save.  An empty value clears the slot.
  static Future<void> store(
    String project,
    Map<String, String> secrets,
  ) async {
    final key = _projectKey(project);
    for (final slot in _slots) {
      final value = secrets[slot] ?? '';
      if (value.isEmpty) {
        await storage.delete(key: '${key}_$slot');
      } else {
        await storage.write(key: '${key}_$slot', value: value);
      }
    }
  }

  /// Read every secret stored for [project].  Missing entries come back
  /// absent, not empty, so callers can distinguish "never set" from "set
  /// to blank".
  static Future<Map<String, String>> load(String project) async {
    final out = <String, String>{};
    final key = _projectKey(project);
    for (final slot in _slots) {
      final value = await storage.read(key: '${key}_$slot');
      if (value != null && value.isNotEmpty) out[slot] = value;
    }
    return out;
  }

  /// Remove all secrets for a project (used when a build record is deleted).
  static Future<void> purge(String project) async {
    final key = _projectKey(project);
    for (final slot in _slots) {
      await storage.delete(key: '${key}_$slot');
    }
  }

  /// Extract the secret fields from an intent JSON map.  Kept next to the
  /// vault so the writer and reader cannot drift apart.
  static Map<String, String> extract(Map<String, dynamic> intentJson) {
    final security = intentJson['security'];
    if (security is! Map) return const {};
    final out = <String, String>{};
    for (final slot in _slots.where((s) => s != 'vpnPreSharedKey')) {
      final value = security[slot];
      if (value is String && value.isNotEmpty) out[slot] = value;
    }
    final psk = security['vpnPreSharedKey'];
    if (psk is String && psk.isNotEmpty) out['vpnPreSharedKey'] = psk;
    return out;
  }

  /// Apply loaded secrets back onto an intent JSON map (returns a copy).
  static Map<String, dynamic> inject(
    Map<String, dynamic> intentJson,
    Map<String, String> secrets,
  ) {
    if (secrets.isEmpty) return intentJson;
    final out = Map<String, dynamic>.from(intentJson);
    final security = out['security'];
    out['security'] = Map<String, dynamic>.from(
      security is Map ? security : const {},
    );
    final slot = out['security'] as Map<String, dynamic>;
    secrets.forEach((key, value) => slot.putIfAbsent(key, () => value));
    return out;
  }

  static String _projectKey(String project) =>
      '$_prefix${project.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_')}';
}
