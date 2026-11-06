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

  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage();

  /// Swapped for an in-memory stand-in in tests; the app uses
  /// [_defaultStorage].
  ///
  /// A setter, not a bare field: reassigning must invalidate the snapshot
  /// below. `const FlutterSecureStorage()` is canonicalized, so tests that
  /// reassign the same const instance never change its identity and the
  /// identity check in [_ensureCache] would keep serving the previous
  /// backend's keys.
  static FlutterSecureStorage _storage = _defaultStorage;
  @visibleForTesting
  static FlutterSecureStorage get storage => _storage;
  @visibleForTesting
  static set storage(FlutterSecureStorage value) {
    _storage = value;
    _cacheOwner = null;
    _cache = const {};
  }

  /// One decrypted snapshot of the keystore, shared per [storage] instance.
  ///
  /// The Windows backend keeps the WHOLE key map in a single DPAPI blob that
  /// is decrypted on every read and re-encrypted on every write, so a start
  /// up that reads a few hundred keys (migration walks every project and
  /// slot) costs one full-file decrypt each - seconds, once the map has any
  /// size to it. The app is the only writer of this file, so a per-process
  /// snapshot read once and maintained on write is exact. Swapping [storage]
  /// (tests) changes the identity, which reloads it.
  static FlutterSecureStorage? _cacheOwner;
  static Map<String, String?> _cache = const {};

  static Future<Map<String, String?>?> _ensureCache() async {
    if (identical(_cacheOwner, storage)) return _cache;
    try {
      // A mutable copy with nullable values: a delete records a null
      // tombstone instead of removing the entry, so the snapshot keeps the
      // distinction between "absent" and "deleted this session".
      _cache = Map<String, String?>.from(await _storage.readAll());
    } catch (_) {
      // A backend without readAll (or a failed one) still works, just
      // without the shared snapshot: reads go to the plugin per key.
      _cache = const {};
      _cacheOwner = storage;
      return null;
    }
    _cacheOwner = storage;
    return _cache;
  }

  static Future<String?> _read(String key) async {
    final cache = await _ensureCache();
    if (cache == null) return _storage.read(key: key);
    return cache[key];
  }

  /// Read straight from the backend, skipping the snapshot. The write
  /// verification in [store], [protectText] and [migrateLegacy] must use
  /// this: the snapshot records a write before the backend confirms it, so
  /// a cache hit would make every failed write look persisted - exactly
  /// the failure the verification exists to catch.
  static Future<String?> _readBackend(String key) => _storage.read(key: key);

  static Future<void> _write(String key, String value) async {
    final cache = await _ensureCache();
    await _storage.write(key: key, value: value);
    cache?[key] = value;
  }

  static Future<void> _delete(String key) async {
    final cache = await _ensureCache();
    await _storage.delete(key: key);
    cache?[key] = null;
  }

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
        await _delete('${key}_$slot');
      } else {
        await _write('${key}_$slot', value);
        if (await _readBackend('${key}_$slot') != value) {
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
      final value = await _read('${key}_$slot');
      if (value != null && value.isNotEmpty) out[slot] = value;
    }
    return out;
  }

  /// Remove all secrets for a project (used when a build record is deleted).
  static Future<void> purge(String project) async {
    final key = _projectKey(project);
    for (final slot in _slots) {
      await _delete('${key}_$slot');
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
      if ((await _read('${_legacyKey(project)}_$slot') ?? '').isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// Preserve a secret-bearing source in the keychain before redacting it.
  /// This also recovers credentials from legacy transcripts safely.
  ///
  /// The accumulator is bounded on purpose. It used to append forever, and a
  /// project that had been rebuilt across months accumulated a megabyte of
  /// pasted transcripts - which the single-blob keystore then decrypted on
  /// every one of the hundreds of reads a startup performs, timing out the
  /// memory loader. Newest wins: [recoverRedactedSecrets] searches this text
  /// for a credential's value, and the credential a current build carries is
  /// the one its newest source described.
  static Future<void> protectText(String project, String text) async {
    final key = '${_projectKey(project)}_brief';
    final previous = await _read(key) ?? '';
    if (previous.split('\n\n').contains(text)) return;
    var value = previous.isEmpty ? text : '$previous\n\n$text';
    value = _capBrief(value);
    await _write(key, value);
    if (await _readBackend(key) != value) {
      throw StateError('Credentials could not be saved securely.');
    }
  }

  /// Trim an overgrown accumulator from the FRONT (the oldest sources) and
  /// back to a paragraph boundary, so what survives is whole texts.
  static String _capBrief(String value) {
    if (value.length <= maxBriefChars) return value;
    var capped = value.substring(value.length - maxBriefChars);
    final cut = capped.indexOf('\n\n');
    if (cut >= 0 && cut < capped.length - 2) capped = capped.substring(cut + 2);
    return capped;
  }

  /// A stored brief may not exceed this many characters. 64k holds many
  /// complete briefs side by side; the megabyte-plus blobs the unbounded
  /// version produced held nothing a current build could still recover.
  static const int maxBriefChars = 65536;

  /// Rewrite every stored brief that outgrew [maxBriefChars] (stores written
  /// before the cap existed). Returns how many were trimmed. Called once per
  /// startup from the memory migration.
  static Future<int> normalizeBriefs() async {
    await _ensureCache();
    final oversized = [
      for (final entry in _cache.entries)
        if (entry.key.endsWith('_brief') &&
            entry.value != null &&
            entry.value!.length > maxBriefChars)
          entry.key,
    ];
    for (final key in oversized) {
      final capped = _capBrief(_cache[key]!);
      await _write(key, capped);
    }
    return oversized.length;
  }

  /// Only the database can establish whether a legacy name was unambiguous.
  static Future<void> migrateLegacy(String project) async {
    final legacy = _legacyKey(project);
    final current = _projectKey(project);
    for (final slot in _slots) {
      final existing = await _read('${current}_$slot');
      final old = await _read('${legacy}_$slot');
      if (existing == null && old != null) {
        await _write('${current}_$slot', old);
        if (await _readBackend('${current}_$slot') != old) {
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
