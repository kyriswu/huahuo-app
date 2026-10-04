import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';

const liveGatewaySessionPath = 'api/v1/realtime-asr/sessions';

/// An in-memory Tencent STS session for the official mobile realtime SDK.
///
/// The compatibility type name is retained for existing callers. It must never
/// be logged, serialized, cached, or used outside the immediate native SDK
/// startup path.
final class LiveAsrSessionCredential {
  LiveAsrSessionCredential({
    required this.sessionId,
    required this.appId,
    required this.projectId,
    required String tmpSecretId,
    required String tmpSecretKey,
    required String token,
    required DateTime expiresAt,
  }) : _tmpSecretId = _safeTemporaryCredentialValue(tmpSecretId),
       _tmpSecretKey = _safeTemporaryCredentialValue(tmpSecretKey),
       _token = _safeTemporaryCredentialValue(token),
       expiresAt = expiresAt.toUtc() {
    if (!_safeOpaqueId(sessionId) ||
        appId <= 0 ||
        appId > 0x7fffffff ||
        projectId < 0 ||
        projectId > 0x7fffffff ||
        _tmpSecretId == null ||
        _tmpSecretKey == null ||
        _token == null) {
      throw ArgumentError('invalid Tencent realtime ASR session');
    }
  }

  final String sessionId;
  final int appId;
  final int projectId;
  final String? _tmpSecretId;
  final String? _tmpSecretKey;
  final String? _token;
  final DateTime expiresAt;

  String get tmpSecretId => _tmpSecretId!;
  String get tmpSecretKey => _tmpSecretKey!;
  String get token => _token!;

  bool expiresWithin(Duration window, {DateTime? now}) {
    return !expiresAt.isAfter((now ?? DateTime.now()).toUtc().add(window));
  }

  Map<String, Object> toNativeStartArguments() => <String, Object>{
    'sessionId': sessionId,
    'appId': appId,
    'projectId': projectId,
    'tmpSecretId': tmpSecretId,
    'tmpSecretKey': tmpSecretKey,
    'token': token,
    'expiresAt': expiresAt.toIso8601String(),
  };

  @override
  String toString() => 'LiveAsrSessionCredential([REDACTED])';
}

abstract interface class LiveTranscriptionCredentialPort {
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  });
}

abstract interface class LiveTranscriptionSessionCompletionPort {
  Future<void> completeSession(String sessionId);
}

final class LiveTranscriptionApi
    implements
        LiveTranscriptionCredentialPort,
        LiveTranscriptionSessionCompletionPort {
  LiveTranscriptionApi({
    required this.apiClient,
    this.backendBaseUrl,
    AccessTokenProvider? applicationToken,
  }) : _applicationToken = applicationToken ?? apiClient.config.getAccessToken;

  final ApiClient apiClient;
  final Uri? backendBaseUrl;
  final AccessTokenProvider? _applicationToken;

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async {
    final safeProfileId = _safeOptionalVoiceprintProfileId(voiceprintProfileId);
    if (voiceprintProfileId != null && safeProfileId == null) {
      return _failure('LIVE_ASR_VOICEPRINT_PROFILE_INVALID');
    }
    final baseUrl = backendBaseUrl;
    if (baseUrl == null) return _failure('LIVE_ASR_BACKEND_NOT_READY');
    if (!_safeLiveAsrBaseUrl(baseUrl)) {
      return _failure('ASR_CREDENTIAL_HTTPS_REQUIRED');
    }

    String? token;
    try {
      token = _safeBearerToken(await _applicationToken?.call());
    } catch (_) {
      return ApiResult<LiveAsrSessionCredential>.failure(
        error: _failureForCode(
          'AUTH_TOKEN_READ_FAILED',
          category: AppFailureCategory.auth,
          retryable: true,
          recoveryActions: const <String>['retry', 'login'],
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    if (token == null) {
      final failure = _failureForCode(
        'AUTH_SESSION_EXPIRED',
        category: AppFailureCategory.auth,
        retryable: true,
        recoveryActions: const <String>['login'],
      );
      return ApiResult<LiveAsrSessionCredential>.failure(
        error: failure,
        authExpired: true,
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }

    final traceId =
        apiClient.config.traceIdFactory?.call() ??
        'live-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final idempotencyKey = _liveSessionIdempotencyKey(traceId);
    try {
      _debugLiveCredential(stage: 'requesting', traceId: traceId);
      final response = await apiClient.transport
          .send(
            ApiTransportRequest(
              url: _liveSessionUri(baseUrl),
              method: 'POST',
              headers: <String, String>{
                ...buildCommonHeaders(apiClient.config, traceId),
                'Authorization': 'Bearer $token',
                'X-Idempotency-Key': idempotencyKey,
              },
              body: jsonEncode(<String, Object?>{
                if (safeProfileId != null) 'voiceprintProfileId': safeProfileId,
              }),
            ),
          )
          .timeout(apiClient.config.requestTimeout);
      if (!response.ok) {
        _debugLiveCredential(
          stage: 'http_failure',
          traceId: traceId,
          status: response.status,
        );
        final failure = _responseFailure(response, traceId: traceId);
        return ApiResult<LiveAsrSessionCredential>.failure(
          error: failure,
          status: response.status,
          traceId: traceId,
          authExpired: false,
          idempotencyStore: SubmissionKeyStore.empty,
        );
      }

      final credential = parseLiveAsrSessionCredential(
        _responseData(response.body),
      );
      if (credential == null) {
        _debugLiveCredential(
          stage: 'response_invalid',
          traceId: traceId,
          status: response.status,
        );
        return ApiResult<LiveAsrSessionCredential>.failure(
          error: _failureForCode('LIVE_ASR_SESSION_RESPONSE_INVALID'),
          status: response.status,
          traceId: traceId,
          idempotencyStore: SubmissionKeyStore.empty,
        );
      }
      _debugLiveCredential(
        stage: 'success',
        traceId: traceId,
        status: response.status,
      );
      return ApiResult<LiveAsrSessionCredential>.success(
        data: credential,
        status: response.status,
        traceId: traceId,
        idempotencyStore: SubmissionKeyStore.empty,
      );
    } catch (cause) {
      _debugLiveCredential(
        stage: 'network_failure',
        traceId: traceId,
        causeType: cause.runtimeType.toString(),
      );
      return ApiResult<LiveAsrSessionCredential>.failure(
        error: _failureForCode(
          'LIVE_ASR_SESSION_NETWORK_FAILED',
          category: AppFailureCategory.network,
          retryable: true,
        ),
        traceId: traceId,
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
  }

  ApiResult<LiveAsrSessionCredential> _failure(String code) {
    return ApiResult<LiveAsrSessionCredential>.failure(
      error: liveTranscriptionApiFailure(code),
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<void> completeSession(String sessionId) async {
    if (!_safeOpaqueId(sessionId)) return;
    final baseUrl = backendBaseUrl;
    if (baseUrl == null || !_safeLiveAsrBaseUrl(baseUrl)) return;

    String? token;
    try {
      token = _safeBearerToken(await _applicationToken?.call());
    } catch (_) {
      return;
    }
    if (token == null) return;

    final traceId =
        apiClient.config.traceIdFactory?.call() ??
        'live-complete-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    try {
      _debugLiveCredential(stage: 'completion_requesting', traceId: traceId);
      final response = await apiClient.transport
          .send(
            ApiTransportRequest(
              url: _liveSessionCompletionUri(baseUrl, sessionId),
              method: 'POST',
              headers: <String, String>{
                ...buildCommonHeaders(apiClient.config, traceId),
                'Authorization': 'Bearer $token',
                'X-Idempotency-Key': _liveSessionIdempotencyKey(traceId),
              },
            ),
          )
          .timeout(apiClient.config.requestTimeout);
      _debugLiveCredential(
        stage: response.ok ? 'completion_success' : 'completion_http_failure',
        traceId: traceId,
        status: response.status,
      );
    } catch (cause) {
      _debugLiveCredential(
        stage: 'completion_network_failure',
        traceId: traceId,
        causeType: cause.runtimeType.toString(),
      );
    }
  }
}

void _debugLiveCredential({
  required String stage,
  required String traceId,
  int? status,
  String? causeType,
}) {
  if (!kDebugMode) return;
  debugPrint(
    '[LiveAsrCredential] stage=$stage trace=$traceId'
    '${status == null ? '' : ' status=$status'}'
    '${causeType == null ? '' : ' cause=$causeType'}',
  );
}

String _liveSessionIdempotencyKey(String traceId) {
  final safeTrace = traceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final boundedTrace = safeTrace.length > 72
      ? safeTrace.substring(0, 72)
      : safeTrace;
  final suffix = DateTime.now().toUtc().microsecondsSinceEpoch;
  return 'realtime-asr-$boundedTrace-$suffix';
}

LiveAsrSessionCredential? parseLiveAsrSessionCredential(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final temporary = asObjectMap(object['temporaryCredential']);
  final sessionId = object['sessionId'];
  final appId = _boundedInt(object['appId']);
  final projectId = _boundedInt(object['projectId']);
  final expiresAt = DateTime.tryParse('${object['expiresAt'] ?? ''}')?.toUtc();
  final tmpSecretId = temporary?['tmpSecretId'];
  final tmpSecretKey = temporary?['tmpSecretKey'];
  final token = temporary?['token'];
  if (sessionId is! String ||
      appId == null ||
      projectId == null ||
      tmpSecretId is! String ||
      tmpSecretKey is! String ||
      token is! String ||
      expiresAt == null ||
      !expiresAt.isAfter(DateTime.now().toUtc())) {
    return null;
  }
  try {
    return LiveAsrSessionCredential(
      sessionId: sessionId,
      appId: appId,
      projectId: projectId,
      tmpSecretId: tmpSecretId,
      tmpSecretKey: tmpSecretKey,
      token: token,
      expiresAt: expiresAt,
    );
  } on ArgumentError {
    return null;
  }
}

AppFailure liveTranscriptionApiFailure(String code) {
  return _failureForCode(
    code,
    category:
        code == 'ASR_CREDENTIAL_HTTPS_REQUIRED' ||
            code == 'LIVE_ASR_BACKEND_NOT_READY'
        ? AppFailureCategory.compatibility
        : AppFailureCategory.api,
    retryable:
        code != 'ASR_CREDENTIAL_HTTPS_REQUIRED' &&
        code != 'LIVE_ASR_BACKEND_NOT_READY' &&
        code != 'LIVE_ASR_VOICEPRINT_PROFILE_INVALID',
    recoveryActions:
        code == 'ASR_CREDENTIAL_HTTPS_REQUIRED' ||
            code == 'LIVE_ASR_BACKEND_NOT_READY'
        ? const <String>['none']
        : const <String>['retry'],
  );
}

Object? _responseData(Object? raw) {
  final object = asObjectMap(raw);
  if (object == null) return null;
  if (object['success'] == true) return object['data'];
  return object;
}

AppFailure _responseFailure(
  ApiTransportResponse response, {
  required String traceId,
}) {
  final object = asObjectMap(response.body);
  final error = asObjectMap(object?['error']);
  final rawCode = error?['code'];
  final code =
      rawCode is String && RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(rawCode)
      ? rawCode
      : response.status == 401
      ? 'AUTH_SESSION_EXPIRED'
      : response.status == 429
      ? 'LIVE_ASR_SESSION_RATE_LIMITED'
      : response.status >= 500
      ? 'LIVE_ASR_SESSION_SERVER_UNAVAILABLE'
      : 'LIVE_ASR_SESSION_REQUEST_FAILED';
  return _failureForCode(
    code,
    category: response.status == 401
        ? AppFailureCategory.auth
        : AppFailureCategory.api,
    retryable:
        response.status == 401 ||
        response.status == 429 ||
        response.status >= 500,
    recoveryActions: response.status == 401
        ? const <String>['login']
        : const <String>['retry'],
    metadata: <String, Object?>{
      'endpointId': 'tencentRealtimeAsrSession',
      'correlationId': traceId,
      'status': response.status,
    },
  );
}

AppFailure _failureForCode(
  String code, {
  AppFailureCategory category = AppFailureCategory.api,
  bool retryable = false,
  List<String> recoveryActions = const <String>['retry'],
  Map<String, Object?> metadata = const <String, Object?>{},
}) {
  return AppFailure(
    code: code,
    category: category,
    message: 'Live transcription session operation failed',
    userMessageKey: 'liveTranscription.error.$code',
    isRetryable: retryable,
    recoveryActions: recoveryActions,
    metadata: metadata,
  );
}

Uri _liveSessionUri(Uri baseUrl) {
  final normalized = baseUrl.toString().endsWith('/')
      ? baseUrl
      : Uri.parse('${baseUrl.toString()}/');
  return normalized.resolve(liveGatewaySessionPath);
}

Uri _liveSessionCompletionUri(Uri baseUrl, String sessionId) {
  final sessionUri = _liveSessionUri(baseUrl);
  final normalized = sessionUri.path.endsWith('/')
      ? sessionUri.path.substring(0, sessionUri.path.length - 1)
      : sessionUri.path;
  return sessionUri.replace(path: '$normalized/$sessionId/complete');
}

bool _safeLiveAsrBaseUrl(Uri value) {
  if (value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.query.isNotEmpty ||
      value.fragment.isNotEmpty) {
    return false;
  }
  return value.scheme.toLowerCase() == 'https';
}

bool _safeOpaqueId(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$').hasMatch(value);

String? _safeTemporaryCredentialValue(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 8192) return null;
  if (normalized.codeUnits.any((unit) => unit < 0x21 || unit == 0x7f)) {
    return null;
  }
  return normalized;
}

String? _safeBearerToken(String? value) {
  final token = value?.trim();
  if (token == null || token.isEmpty || token.length > 8192) return null;
  if (token.codeUnits.any((unit) => unit < 0x21 || unit == 0x7f)) return null;
  return token;
}

String? _safeOptionalVoiceprintProfileId(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{1,127}$').hasMatch(normalized)
      ? normalized
      : null;
}

int? _boundedInt(Object? value) {
  if (value is! int || value < 0 || value > 0x7fffffff) return null;
  return value;
}
