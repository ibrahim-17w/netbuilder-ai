import 'dart:convert';
import '../models/network_intent.dart';

/// Defense at every persistence and export boundary, including legacy rows.
class StoredPrivacy {
  static final _secretField = RegExp(
    r'^(?:.*password|.*secret|.*psk|.*token|authorization|apiKey)$',
    caseSensitive: false,
  );
  static dynamic redact(dynamic value, [String key = '']) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key: redact(entry.value, entry.key.toString()),
      };
    }
    if (value is List) return [for (final v in value) redact(v)];
    if (value is! String) return value;
    if (_secretField.hasMatch(key)) {
      return value.isEmpty ? value : NetworkIntent.redacted;
    }
    if (key.endsWith('Json') ||
        value.startsWith('{') ||
        value.startsWith('[')) {
      try {
        return jsonEncode(redact(jsonDecode(value)));
      } catch (_) {}
    }
    return NetworkIntent.redactSecrets(value);
  }

  static Map<String, dynamic> row(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(redact(value) as Map);
}
