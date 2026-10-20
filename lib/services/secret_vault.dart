import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

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
    'enableSecret',
    'serviceSecrets',
    'brief',
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
  static Future<void> store(String project, Map<String, String> secrets) async {
    final key = _projectKey(project);
    for (final slot in _slots) {
      final value = secrets[slot] ?? '';
      if (value.isEmpty) {
        await storage.delete(key: '${key}_$slot');
      } else {
        await storage.write(key: '${key}_$slot', value: value);
        if (await storage.read(key: '${key}_$slot') != value) {
          throw StateError('Project credentials could not be saved securely.');
        }
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
    final security = intentJson['security'] is Map
        ? intentJson['security'] as Map
        : const {};
    final out = <String, String>{};
    for (final slot in _slots.where((s) => s != 'vpnPreSharedKey')) {
      final value = security[slot];
      if (value is String && value.isNotEmpty) out[slot] = value;
    }
    final psk = security['vpnPreSharedKey'];
    if (psk is String && psk.isNotEmpty) out['vpnPreSharedKey'] = psk;
    final serviceSecrets = <String, dynamic>{};
    for (final node in (intentJson['nodes'] as List?) ?? const []) {
      if (node is! Map) continue;
      final found = _secretTree(node['serviceRules']);
      if (found is Map && found.isNotEmpty) {
        serviceSecrets['${node['name']}'] = found;
      }
    }
    if (serviceSecrets.isNotEmpty) {
      out['serviceSecrets'] = jsonEncode(serviceSecrets);
    }
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
    secrets.forEach((key, value) {
      if (key != 'serviceSecrets' &&
          key != 'brief' &&
          (slot[key] == null || slot[key] == '[redacted]')) {
        slot[key] = value;
      }
    });
    if (secrets['serviceSecrets'] != null) {
      final serviceSecrets = jsonDecode(secrets['serviceSecrets']!) as Map;
      out['nodes'] = [
        for (final raw in (intentJson['nodes'] as List?) ?? const [])
          if (raw is Map)
            {
              ...raw,
              if (serviceSecrets.containsKey(raw['name']))
                'serviceRules': _mergeTree(
                  raw['serviceRules'],
                  serviceSecrets[raw['name']],
                ),
            },
      ];
    }
    return out;
  }

  static String _projectKey(String project) =>
      '${_prefix}v2_${sha256.convert(utf8.encode(project.trim().toLowerCase()))}';

  static String _legacyKey(String project) =>
      '$_prefix${project.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_')}';

  static Future<bool> hasLegacyCredentials(String project) async {
    for (final slot in _slots) {
      if ((await storage.read(key: '${_legacyKey(project)}_$slot') ?? '')
          .isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// Preserve a secret-bearing source in the keychain before redacting it.
  /// This also recovers credentials from legacy transcripts safely.
  static Future<void> protectText(String project, String text) async {
    final key = '${_projectKey(project)}_brief';
    final previous = await storage.read(key: key) ?? '';
    if (previous.split('\n\n').contains(text)) return;
    final value = previous.isEmpty ? text : '$previous\n\n$text';
    await storage.write(key: key, value: value);
    if (await storage.read(key: key) != value) {
      throw StateError('Credentials could not be saved securely.');
    }
  }

  /// Only the database can establish whether a legacy name was unambiguous.
  static Future<void> migrateLegacy(String project) async {
    final legacy = _legacyKey(project);
    final current = _projectKey(project);
    for (final slot in _slots) {
      final existing = await storage.read(key: '${current}_$slot');
      final old = await storage.read(key: '${legacy}_$slot');
      if (existing == null && old != null) {
        await storage.write(key: '${current}_$slot', value: old);
        if (await storage.read(key: '${current}_$slot') != old) {
          throw StateError(
            'Project credentials could not be migrated securely.',
          );
        }
      }
    }
  }

  static dynamic _secretTree(dynamic value) {
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final child = _secretTree(entry.value);
        if (RegExp(
              r'(password|secret|psk|token)',
              caseSensitive: false,
            ).hasMatch(key) &&
            entry.value != null &&
            entry.value != '[redacted]') {
          out[key] = entry.value;
        } else if (child is Map && child.isNotEmpty ||
            child is List && child.isNotEmpty) {
          out[key] = child;
        }
      }
      return out;
    }
    if (value is List) {
      final children = [for (final v in value) _secretTree(v)];
      return children.any(
            (v) => v is Map && v.isNotEmpty || v is List && v.isNotEmpty,
          )
          ? children
          : [];
    }
    return null;
  }

  static dynamic _mergeTree(dynamic plain, dynamic secrets) {
    if (secrets is Map) {
      return {
        if (plain is Map) ...plain,
        for (final entry in secrets.entries)
          entry.key: _mergeTree(
            plain is Map ? plain[entry.key] : null,
            entry.value,
          ),
      };
    }
    if (secrets is List) {
      return [
        for (var i = 0; i < secrets.length; i++)
          _mergeTree(
            plain is List && i < plain.length ? plain[i] : null,
            secrets[i],
          ),
      ];
    }
    return secrets ?? plain;
  }
}
