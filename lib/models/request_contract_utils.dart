import 'dart:collection';
import 'dart:convert';

Map<String, dynamic> strictJsonObject(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object.');
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$label keys must be strings.');
    }
    out[entry.key as String] = entry.value;
  }
  return out;
}

void rejectUnknownFields(
  Map<String, dynamic> json,
  Set<String> allowed,
  String label,
) {
  final unknown = json.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException(
      '$label contains unknown field(s): ${unknown.join(', ')}.',
    );
  }
}

int readSchemaVersion(
  Map<String, dynamic> json, {
  required String label,
  int absentVersion = 1,
  int currentVersion = 1,
}) {
  final raw = json['schemaVersion'];
  final version = raw == null
      ? absentVersion
      : raw is int
      ? raw
      : throw FormatException('$label schemaVersion must be an integer.');
  if (version != currentVersion) {
    throw FormatException(
      'Unsupported $label schemaVersion $version; supported version is '
      '$currentVersion.',
    );
  }
  return version;
}

String readString(
  Map<String, dynamic> json,
  String key, {
  String? defaultValue,
  bool allowEmpty = true,
}) {
  final raw = json[key];
  if (raw == null && defaultValue != null) return defaultValue;
  if (raw is! String) throw FormatException('$key must be a string.');
  if (!allowEmpty && raw.trim().isEmpty) {
    throw FormatException('$key must not be empty.');
  }
  return raw;
}

int readInt(
  Map<String, dynamic> json,
  String key, {
  int? defaultValue,
  int? minimum,
  int? maximum,
}) {
  final raw = json[key];
  if (raw == null && defaultValue != null) return defaultValue;
  if (raw is! int) throw FormatException('$key must be an integer.');
  if (minimum != null && raw < minimum) {
    throw FormatException('$key must be at least $minimum.');
  }
  if (maximum != null && raw > maximum) {
    throw FormatException('$key must be at most $maximum.');
  }
  return raw;
}

bool readBool(Map<String, dynamic> json, String key, {bool? defaultValue}) {
  final raw = json[key];
  if (raw == null && defaultValue != null) return defaultValue;
  if (raw is! bool) throw FormatException('$key must be a boolean.');
  return raw;
}

T readEnum<T extends Enum>(
  Object? raw,
  Iterable<T> values,
  String label, {
  T? defaultValue,
}) {
  if (raw == null && defaultValue != null) return defaultValue;
  if (raw is! String) throw FormatException('$label must be a string enum.');
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw FormatException('Unknown $label "$raw".');
}

List<String> readStringList(
  Object? raw,
  String label, {
  bool allowEmptyItems = false,
}) {
  if (raw is! List) throw FormatException('$label must be a list.');
  final out = <String>[];
  for (final item in raw) {
    if (item is! String || (!allowEmptyItems && item.trim().isEmpty)) {
      throw FormatException('$label must contain non-empty strings.');
    }
    out.add(item);
  }
  return List.unmodifiable(out);
}

Object? freezeJsonValue(Object? value, {String label = 'value'}) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((item) => freezeJsonValue(item, label: label)),
    );
  }
  if (value is Map) {
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('$label object keys must be strings.');
      }
      out[entry.key as String] = freezeJsonValue(entry.value, label: label);
    }
    return Map<String, Object?>.unmodifiable(out);
  }
  throw FormatException('$label must contain JSON values only.');
}

Map<String, Object?> freezeJsonMap(
  Map<String, Object?> value, {
  String label = 'value',
}) {
  final frozen = freezeJsonValue(value, label: label);
  return Map<String, Object?>.unmodifiable(frozen! as Map<String, Object?>);
}

Object? mutableJsonCopy(Object? value) {
  if (value is List) return value.map(mutableJsonCopy).toList();
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key as String: mutableJsonCopy(entry.value),
    };
  }
  return value;
}

Object? _canonicalJson(Object? value) {
  if (value is List) return value.map(_canonicalJson).toList();
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      sorted[entry.key as String] = _canonicalJson(entry.value);
    }
    return sorted;
  }
  return value;
}

bool jsonValueEquals(Object? a, Object? b) =>
    jsonEncode(_canonicalJson(a)) == jsonEncode(_canonicalJson(b));

int jsonValueHash(Object? value) => jsonEncode(_canonicalJson(value)).hashCode;
