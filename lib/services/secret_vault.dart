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

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Write every secret the intent carries for [project].  An empty value
  /// clears the slot, so re-saving a project after removing a password
  /// cannot leave a stale key behind.
  static Future<void> store(
    String project,
    Map<String, String> secrets,
  ) async {
    final key = _projectKey(project);
    for (final entry in secrets.entries) {
      if (entry.value.isEmpty) {
        await _storage.delete(key: '${key}_${entry.key}');
      } else {
        await _storage.write(key: '${key}_${entry.key}', value: entry.value);
      }
    }
  }

  /// Read every secret stored for [project].  Missing entries come back
  /// absent, not empty, so callers can distinguish "never set" from "set
  /// to blank".
  static Future<Map<String, String>> load(String project) async {
    final out = <String, String>{};
    for (final name in const ['aaaPassword', 'vpnPreSharedKey']) {
      final value = await _storage.read(key: '${_projectKey(project)}_$name');
      if (value != null && value.isNotEmpty) out[name] = value;
    }
    return out;
  }

  /// Remove all secrets for a project (used when a build record is deleted).
  static Future<void> purge(String project) async {
    for (final name in const ['aaaPassword', 'vpnPreSharedKey']) {
      await _storage.delete(key: '${_projectKey(project)}_$name');
    }
  }

  /// Extract the secret fields from an intent JSON map.  Kept next to the
  /// vault so the writer and reader cannot drift apart.
  static Map<String, String> extract(Map<String, dynamic> intentJson) {
    final security = intentJson['security'];
    if (security is! Map) return const {};
    final out = <String, String>{};
    final aaa = security['aaaPassword'];
    if (aaa is String && aaa.isNotEmpty) out['aaaPassword'] = aaa;
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
