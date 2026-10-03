enum AppFailureCategory {
  auth,
  permission,
  quota,
  network,
  api,
  storage,
  compatibility,
}

final class AppFailure {
  const AppFailure({
    required this.code,
    required this.category,
    required this.message,
    required this.userMessageKey,
    this.isRetryable = false,
    this.recoveryActions = const <String>[],
    this.details = const <String, Object?>{},
    this.metadata = const <String, Object?>{},
    this.cause,
  });

  final String code;
  final AppFailureCategory category;
  final String message;
  final String userMessageKey;
  final bool isRetryable;
  final List<String> recoveryActions;
  final Map<String, Object?> details;
  final Map<String, Object?> metadata;
  final Object? cause;

  AppFailure copyWith({
    String? code,
    AppFailureCategory? category,
    String? message,
    String? userMessageKey,
    bool? isRetryable,
    List<String>? recoveryActions,
    Map<String, Object?>? details,
    Map<String, Object?>? metadata,
    Object? cause,
  }) {
    return AppFailure(
      code: code ?? this.code,
      category: category ?? this.category,
      message: message ?? this.message,
      userMessageKey: userMessageKey ?? this.userMessageKey,
      isRetryable: isRetryable ?? this.isRetryable,
      recoveryActions: recoveryActions ?? this.recoveryActions,
      details: details ?? this.details,
      metadata: metadata ?? this.metadata,
      cause: cause ?? this.cause,
    );
  }
}

final class ApiEnvelopeResult<T> {
  const ApiEnvelopeResult._({
    required this.ok,
    this.data,
    this.error,
    this.traceId,
  });

  factory ApiEnvelopeResult.success(T data, {String? traceId}) {
    return ApiEnvelopeResult<T>._(ok: true, data: data, traceId: traceId);
  }

  factory ApiEnvelopeResult.failure(AppFailure error, {String? traceId}) {
    return ApiEnvelopeResult<T>._(ok: false, error: error, traceId: traceId);
  }

  final bool ok;
  final T? data;
  final AppFailure? error;
  final String? traceId;
}

final class PageResult<T> {
  const PageResult({required this.items, this.nextCursor});

  final List<T> items;
  final String? nextCursor;
}

typedef DataParser<T> = T? Function(Object? value);

ApiEnvelopeResult<T> parseApiEnvelope<T>(
  Object? raw,
  DataParser<T> parseData, {
  required String endpointId,
  required String correlationId,
  bool allowLegacyDirectData = false,
}) {
  final object = asObjectMap(raw);
  if (object == null) {
    return ApiEnvelopeResult<T>.failure(
      malformedEnvelopeError(
        endpointId: endpointId,
        correlationId: correlationId,
        reason: 'notObject',
      ),
    );
  }

  final traceId = safeTraceId(object['traceId']);
  final success = object['success'];

  if (success == false) {
    return ApiEnvelopeResult<T>.failure(
      parseApiError(
        object['error'],
        endpointId: endpointId,
        correlationId: correlationId,
        fallbackTraceId: traceId,
      ),
      traceId: traceId,
    );
  }

  if (success != true) {
    if (allowLegacyDirectData) {
      final directData = parseData(raw);
      if (directData != null) {
        return ApiEnvelopeResult<T>.success(directData, traceId: traceId);
      }
    }
    return ApiEnvelopeResult<T>.failure(
      malformedEnvelopeError(
        endpointId: endpointId,
        correlationId: correlationId,
        reason: 'missingSuccess',
        traceId: traceId,
      ),
      traceId: traceId,
    );
  }

  if (!object.containsKey('data')) {
    return ApiEnvelopeResult<T>.failure(
      malformedEnvelopeError(
        endpointId: endpointId,
        correlationId: correlationId,
        reason: 'missingData',
        traceId: traceId,
      ),
      traceId: traceId,
    );
  }

  final data = parseData(object['data']);
  if (data == null) {
    return ApiEnvelopeResult<T>.failure(
      malformedEnvelopeError(
        endpointId: endpointId,
        correlationId: correlationId,
        reason: 'invalidData',
        traceId: traceId,
      ),
      traceId: traceId,
    );
  }

  return ApiEnvelopeResult<T>.success(data, traceId: traceId);
}

AppFailure parseApiError(
  Object? raw, {
  required String endpointId,
  required String correlationId,
  String? fallbackTraceId,
}) {
  final object = asObjectMap(raw);
  if (object == null) {
    return malformedEnvelopeError(
      endpointId: endpointId,
      correlationId: correlationId,
      reason: 'missingError',
      traceId: fallbackTraceId,
    );
  }

  final code = asNonEmptyString(object['code']) ?? 'API_BUSINESS_ERROR';
  final userMessage = safeUserFacingMessage(object['userMessage']);
  final message =
      userMessage ??
      safeUserFacingMessage(object['message']) ??
      'API operation failed';
  final userMessageKey =
      asNonEmptyString(object['userMessageKey']) ?? 'api.error.$code';
  final retryable = object['retryable'] is bool
      ? object['retryable']! as bool
      : false;
  final traceId = safeTraceId(object['traceId']) ?? fallbackTraceId;
  final parsedDetails = asObjectMap(object['details']);

  return AppFailure(
    code: code,
    category: classifyFailureCategory(code),
    message: message,
    userMessageKey: userMessageKey,
    isRetryable: retryable,
    recoveryActions: retryable
        ? const <String>['retry']
        : const <String>['none'],
    details: parsedDetails == null
        ? const <String, Object?>{}
        : Map<String, Object?>.unmodifiable(parsedDetails),
    metadata: <String, Object?>{
      'endpointId': endpointId,
      'correlationId': correlationId,
      if (traceId != null) 'traceId': traceId,
    },
  );
}

PageResult<T>? parsePageResult<T>(Object? raw, DataParser<T> parseItem) {
  final object = asObjectMap(raw);
  final items = object?['items'];
  if (object == null || items is! List<Object?>) {
    return null;
  }

  final parsedItems = <T>[];
  for (final item in items) {
    final parsed = parseItem(item);
    if (parsed == null) {
      return null;
    }
    parsedItems.add(parsed);
  }

  return PageResult<T>(
    items: List<T>.unmodifiable(parsedItems),
    nextCursor: asNonEmptyString(object['nextCursor']),
  );
}

Map<String, Object?>? normalizeUnknownFields(Object? raw, List<String> keys) {
  final object = asObjectMap(raw);
  if (object == null) {
    return null;
  }
  return <String, Object?>{
    for (final key in keys)
      if (object.containsKey(key)) key: object[key],
  };
}

Map<String, Object?>? asObjectMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      return null;
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String? asNonEmptyString(Object? value) {
  return value is String && value.isNotEmpty ? value : null;
}

String? safeTraceId(Object? value) {
  final traceId = asNonEmptyString(value);
  if (traceId == null) {
    return null;
  }
  return RegExp(r'^[A-Za-z0-9._:-]{6,96}$').hasMatch(traceId) ? traceId : null;
}

String? safeUserFacingMessage(Object? value) {
  final message = asNonEmptyString(value)?.trim();
  if (message == null || message.isEmpty) {
    return null;
  }
  if (_unsafeMessagePatterns.any((pattern) => pattern.hasMatch(message))) {
    return null;
  }
  return message.length > 160 ? message.substring(0, 160) : message;
}

AppFailure malformedEnvelopeError({
  required String endpointId,
  required String correlationId,
  required String reason,
  String? traceId,
}) {
  return AppFailure(
    code: 'API_MALFORMED_ENVELOPE',
    category: AppFailureCategory.compatibility,
    message: 'API response format is not supported',
    userMessageKey: 'api.error.malformedEnvelope',
    isRetryable: true,
    recoveryActions: const <String>['retry'],
    metadata: <String, Object?>{
      'endpointId': endpointId,
      'correlationId': correlationId,
      'reason': reason,
      if (traceId != null) 'traceId': traceId,
    },
  );
}

AppFailureCategory classifyFailureCategory(String code) {
  if (code == 'UNAUTHORIZED' ||
      code == 'TOKEN_EXPIRED' ||
      code == 'AUTH_SESSION_EXPIRED') {
    return AppFailureCategory.auth;
  }
  if (code == 'FORBIDDEN' ||
      code == 'WORKSPACE_FORBIDDEN' ||
      code == 'PERMISSION_DENIED') {
    return AppFailureCategory.permission;
  }
  if (code.contains('QUOTA')) {
    return AppFailureCategory.quota;
  }
  return AppFailureCategory.api;
}

bool isAuthExpiredFailure(AppFailure failure) {
  return failure.code == 'UNAUTHORIZED' ||
      failure.code == 'TOKEN_EXPIRED' ||
      failure.code == 'AUTH_SESSION_EXPIRED';
}

final _unsafeMessagePatterns = <RegExp>[
  RegExp('access.*token', caseSensitive: false),
  RegExp('refresh.*token', caseSensitive: false),
  RegExp('provider.*key', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('api.*key', caseSensitive: false),
  RegExp('workspace', caseSensitive: false),
  RegExp('runtime', caseSensitive: false),
  RegExp('openclaw', caseSensitive: false),
  RegExp('session', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp('file://', caseSensitive: false),
  RegExp('/Users/'),
  RegExp('/home/huahuo-runtime', caseSensitive: false),
  RegExp('/home/data/huahuo', caseSensitive: false),
  RegExp('HTTP 500', caseSensitive: false),
  RegExp('SOCKET_ECONNRESET', caseSensitive: false),
  RegExp('Native Module Error', caseSensitive: false),
  RegExp('GATT_ERROR', caseSensitive: false),
  RegExp('CRC_FAIL', caseSensitive: false),
];
