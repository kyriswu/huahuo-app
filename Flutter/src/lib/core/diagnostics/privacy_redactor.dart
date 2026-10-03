final class PrivacyRedactor {
  const PrivacyRedactor();

  Map<String, Object> redactMetadata(Map<String, Object?> metadata) {
    final output = <String, Object>{};
    for (final entry in metadata.entries) {
      if (_unsafeKeyPatterns.any((pattern) => pattern.hasMatch(entry.key))) {
        continue;
      }
      final value = entry.value;
      if (value is String || value is num || value is bool) {
        output[entry.key] = redactScalar(value as Object);
      }
    }
    return Map<String, Object>.unmodifiable(output);
  }

  Object redactScalar(Object value) {
    if (value is! String) {
      return value;
    }
    if (_unsafeValuePatterns.any((pattern) => pattern.hasMatch(value))) {
      return 'redacted';
    }
    return value.length > 120 ? '${value.substring(0, 117)}...' : value;
  }

  String safeSummary(String value) {
    if (_unsafeValuePatterns.any((pattern) => pattern.hasMatch(value))) {
      return 'Application operation failed';
    }
    return value.length > 160 ? value.substring(0, 160) : value;
  }

  String sanitizeCorrelationId(String value) {
    if (_unsafeValuePatterns.any((pattern) => pattern.hasMatch(value))) {
      return 'redacted-correlation';
    }
    final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9_:-]'), '');
    if (sanitized.isEmpty) {
      return 'app';
    }
    return sanitized.length > 96 ? sanitized.substring(0, 96) : sanitized;
  }

  ({String safeSummary, String developerSummary}) mapErrorToDiagnosticSummary(
    Object error,
  ) {
    final text = error.toString();
    return (
      safeSummary: safeSummary(text),
      developerSummary: error.runtimeType.toString(),
    );
  }
}

const privacyRedactor = PrivacyRedactor();

final _unsafeKeyPatterns = <RegExp>[
  RegExp('token', caseSensitive: false),
  RegExp('verification', caseSensitive: false),
  RegExp('sms.*code', caseSensitive: false),
  RegExp('password', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
  RegExp('path', caseSensitive: false),
  RegExp('real.*path', caseSensitive: false),
  RegExp('skill', caseSensitive: false),
  RegExp('transcript', caseSensitive: false),
  RegExp('chat', caseSensitive: false),
  RegExp('raw.*text', caseSensitive: false),
  RegExp('profile', caseSensitive: false),
  RegExp('audio', caseSensitive: false),
  RegExp('provider', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('api.*key', caseSensitive: false),
  RegExp('openclaw', caseSensitive: false),
  RegExp('runtime', caseSensitive: false),
  RegExp('session.*key', caseSensitive: false),
  RegExp('workspace', caseSensitive: false),
  RegExp('binding', caseSensitive: false),
];

final _unsafeValuePatterns = <RegExp>[
  RegExp('access-token', caseSensitive: false),
  RegExp('refresh-token', caseSensitive: false),
  RegExp('provider.*key', caseSensitive: false),
  RegExp('wifi.*password', caseSensitive: false),
  RegExp('file://', caseSensitive: false),
  RegExp(r'[A-Za-z]:\\'),
  RegExp('/Users/', caseSensitive: false),
  RegExp('/home/huahuo-runtime/', caseSensitive: false),
  RegExp('/home/data/huahuo/(runtime|workspaces)/', caseSensitive: false),
  RegExp('runtime:tenant:', caseSensitive: false),
  RegExp('openclaw', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('api.*key', caseSensitive: false),
  RegExp('HTTP 500', caseSensitive: false),
  RegExp('SOCKET_ECONNRESET', caseSensitive: false),
  RegExp('Native Module Error', caseSensitive: false),
  RegExp('GATT_ERROR', caseSensitive: false),
  RegExp('CRC_FAIL', caseSensitive: false),
  RegExp('data_lenght', caseSensitive: false),
  RegExp('E5E4', caseSensitive: false),
];
