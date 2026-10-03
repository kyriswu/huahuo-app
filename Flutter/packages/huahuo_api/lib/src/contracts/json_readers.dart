int? optionalNonNegativeInt(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  return requiredNonNegativeInt(json, key);
}

double? optionalNonNegativeNumber(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  final value = json[key];
  if (value is! num || !value.isFinite || value < 0) {
    throw FormatException('$key must be a finite non-negative number');
  }
  return value.toDouble();
}

String? optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string when provided');
  }
  return value;
}

void requireNull(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] != null) {
    throw FormatException('$key must be present and null');
  }
}

bool requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

DateTime requiredDateTime(Map<String, Object?> json, String key) {
  final raw = requiredString(json, key);
  final value = DateTime.tryParse(raw);
  if (value == null) {
    throw FormatException('$key must be an RFC 3339 timestamp');
  }
  return value.toUtc();
}

int requiredNonNegativeInt(Map<String, Object?> json, String key) {
  final value = requiredInt(json, key);
  if (value < 0) throw FormatException('$key must be non-negative');
  return value;
}

int requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw FormatException('$key must be an integer');
  return value;
}

Map<String, Object?> requiredObject(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('$key must be an object');
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<Map<String, Object?>> requiredObjectList(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('$key must be a list');
  }
  return value
      .map((item) {
        if (item is! Map) {
          throw FormatException('$key items must be objects');
        }
        return item.map((key, value) => MapEntry(key.toString(), value));
      })
      .toList(growable: false);
}

String requiredString(
  Map<String, Object?> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException(
      '$key must be a${allowEmpty ? '' : ' non-empty'} string',
    );
  }
  return value;
}
