import 'package:huahuo_api/huahuo_api.dart';
import '../../../core/auth/secure_token_store.dart';
import '../../../core/auth/session_store.dart';

const currentUserAgreementVersion = '2026-08-20';
const currentPrivacyPolicyVersion = '2026-08-20';

final class AuthApiResult<T> {
  const AuthApiResult._({
    required this.ok,
    this.value,
    this.error,
    this.traceId,
    this.status,
    this.authExpired = false,
    this.retryAfterSeconds,
  });

  factory AuthApiResult.success({
    required T value,
    required int status,
    String? traceId,
  }) {
    return AuthApiResult<T>._(
      ok: true,
      value: value,
      status: status,
      traceId: traceId,
    );
  }

  factory AuthApiResult.failure({
    required AppFailure error,
    String? traceId,
    int? status,
    bool authExpired = false,
    int? retryAfterSeconds,
  }) {
    return AuthApiResult<T>._(
      ok: false,
      error: error,
      traceId: traceId,
      status: status,
      authExpired: authExpired,
      retryAfterSeconds: retryAfterSeconds,
    );
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
  final String? traceId;
  final int? status;
  final bool authExpired;
  final int? retryAfterSeconds;
}

final class SendSmsCodeResponse {
  const SendSmsCodeResponse({
    required this.smsRequestId,
    required this.cooldownSeconds,
  });

  final String smsRequestId;
  final int cooldownSeconds;
}

sealed class _SendSmsCodePayload {
  const _SendSmsCodePayload();
}

final class _SendSmsCodeTicket extends _SendSmsCodePayload {
  const _SendSmsCodeTicket(this.response);

  final SendSmsCodeResponse response;
}

final class _SendSmsCodeFailure extends _SendSmsCodePayload {
  const _SendSmsCodeFailure({required this.error, this.retryAfterSeconds});

  final AppFailure error;
  final int? retryAfterSeconds;
}

final class SmsLoginRequest {
  const SmsLoginRequest({
    required this.phone,
    required this.smsRequestId,
    required this.code,
    required this.deviceId,
    required this.agreementAccepted,
    required this.clientVersion,
    this.timeZone = 'UTC',
    this.agreementVersion = currentUserAgreementVersion,
    this.privacyVersion = currentPrivacyPolicyVersion,
  });

  final String phone;
  final String smsRequestId;
  final String code;
  final String deviceId;
  final bool agreementAccepted;
  final String agreementVersion;
  final String privacyVersion;
  final String clientVersion;
  final String? timeZone;

  Map<String, Object?> toJson() {
    final requestTimeZone = timeZone?.trim();
    return <String, Object?>{
      'phone': phone,
      'smsRequestId': smsRequestId,
      'smsCode': code,
      'deviceId': deviceId,
      'agreementAccepted': agreementAccepted,
      'agreementVersion': agreementVersion,
      'privacyVersion': privacyVersion,
      'clientVersion': clientVersion,
      if (requestTimeZone != null && requestTimeZone.isNotEmpty)
        'timeZone': requestTimeZone,
    };
  }
}

final class SmsLoginResponse {
  const SmsLoginResponse({
    required this.tokens,
    required this.user,
    required this.workspaceStatus,
    this.tokenType,
    this.firstLogin = false,
    this.onboardingRequired = false,
    this.basicPositioningCompleted,
    this.positioningStatus,
    this.positioningProgress,
    this.defaultContentLineId,
    this.smsBypassMatched,
    this.smsBypassRuleId,
  });

  final String? tokenType;
  final AuthTokens tokens;
  final SessionUser user;
  final bool firstLogin;
  final bool onboardingRequired;
  final bool? basicPositioningCompleted;
  final SessionPositioningStatus? positioningStatus;
  final SessionPositioningProgress? positioningProgress;
  final SessionWorkspaceStatus workspaceStatus;
  final String? defaultContentLineId;
  final bool? smsBypassMatched;
  final String? smsBypassRuleId;
}

final class RefreshTokenResponse {
  const RefreshTokenResponse({
    required this.tokens,
    this.tokenType,
    this.accessTokenExpiresAt,
    this.expiresIn,
    this.rotated,
  });

  final String? tokenType;
  final AuthTokens tokens;
  final DateTime? accessTokenExpiresAt;
  final int? expiresIn;
  final bool? rotated;
}

final class UpdateUserTimeZoneResponse {
  const UpdateUserTimeZoneResponse({required this.timeZone});

  final String timeZone;
}

final class _CreativePositioningStatusPage {
  const _CreativePositioningStatusPage({this.defaultPositioning});

  final SessionContentLine? defaultPositioning;
}

abstract interface class AuthApiPort {
  Future<AuthApiResult<SendSmsCodeResponse>> sendSmsCode({
    required String phone,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  });

  Future<AuthApiResult<SmsLoginResponse>> login({
    required SmsLoginRequest request,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  });

  Future<AuthApiResult<RefreshTokenResponse>> refreshAuthToken({
    required String refreshToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  });

  Future<AuthApiResult<SessionUserStatus>> getUserStatus({
    String? accessToken,
    String? correlationId,
  });
}

abstract interface class UserTimeZoneApiPort {
  Future<AuthApiResult<UpdateUserTimeZoneResponse>> updateUserTimeZone({
    required String timeZone,
    required String accessToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  });
}

final class AuthApi implements AuthApiPort, UserTimeZoneApiPort {
  // ignore: prefer_initializing_formals
  const AuthApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;
  AuthClient get _authClient => AuthClient(_apiClient);

  @override
  Future<AuthApiResult<SendSmsCodeResponse>> sendSmsCode({
    required String phone,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    final result = await _authClient.requestSmsCode<_SendSmsCodePayload>(
      phone: phone,
      correlationId: correlationId,
      idempotency: idempotency,
      parseData: _parseSendSmsCodePayload,
    );
    if (!result.ok) {
      final error = _normalizeSendSmsCodeFailure(result.error!);
      return AuthApiResult<SendSmsCodeResponse>.failure(
        error: error,
        traceId: result.traceId,
        status: result.status,
        authExpired: result.authExpired,
        retryAfterSeconds: result.retryAfterSeconds,
      );
    }
    final payload = result.data!;
    return switch (payload) {
      _SendSmsCodeTicket(:final response) =>
        AuthApiResult<SendSmsCodeResponse>.success(
          value: response,
          status: result.status ?? 200,
          traceId: result.traceId,
        ),
      _SendSmsCodeFailure(:final error, :final retryAfterSeconds) =>
        AuthApiResult<SendSmsCodeResponse>.failure(
          error: error,
          traceId: result.traceId,
          status: result.status,
          retryAfterSeconds: retryAfterSeconds,
        ),
    };
  }

  @override
  Future<AuthApiResult<SmsLoginResponse>> login({
    required SmsLoginRequest request,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    final result = await _authClient.login<SmsLoginResponse>(
      body: request.toJson(),
      correlationId: correlationId,
      idempotency: idempotency,
      parseData: parseSmsLoginResponse,
    );
    return _toAuthApiResult(result);
  }

  @override
  Future<AuthApiResult<RefreshTokenResponse>> refreshAuthToken({
    required String refreshToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    final result = await _authClient.refresh<RefreshTokenResponse>(
      refreshToken: refreshToken,
      correlationId: correlationId,
      idempotency: idempotency,
      parseData: parseRefreshTokenResponse,
    );
    return _toAuthApiResult(result);
  }

  @override
  Future<AuthApiResult<SessionUserStatus>> getUserStatus({
    String? accessToken,
    String? correlationId,
  }) async {
    final statusResult = await _authClient.getUserStatus<SessionUserStatus>(
      accessToken: accessToken,
      correlationId: correlationId,
      parseData: parseUserStatusResponse,
    );
    final status = statusResult.data;
    if (!statusResult.ok ||
        status == null ||
        !_needsCreativePositioningStatusRead(status)) {
      return _toAuthApiResult(statusResult);
    }

    final positioningResult = await _apiClient
        .request<_CreativePositioningStatusPage>(
          ApiRequestOptions<_CreativePositioningStatusPage>(
            endpointId: 'creativePositionings',
            accessTokenOverride: accessToken,
            parseData: _parseCreativePositioningStatusPage,
          ),
        );
    final defaultPositioning = positioningResult.data?.defaultPositioning;
    if (!positioningResult.ok || defaultPositioning == null) {
      return _toAuthApiResult(statusResult);
    }
    return AuthApiResult<SessionUserStatus>.success(
      value: _withDefaultPositioning(status, defaultPositioning),
      status: statusResult.status ?? 200,
      traceId: statusResult.traceId,
    );
  }

  @override
  Future<AuthApiResult<UpdateUserTimeZoneResponse>> updateUserTimeZone({
    required String timeZone,
    required String accessToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    final result = await _authClient
        .updateUserTimeZone<UpdateUserTimeZoneResponse>(
          timeZone: timeZone,
          accessToken: accessToken,
          correlationId: correlationId,
          idempotency: idempotency,
          parseData: parseUpdateUserTimeZoneResponse,
        );
    return _toAuthApiResult(result);
  }
}

SendSmsCodeResponse? parseSendSmsCodeResponse(Object? value) {
  final object = asObjectMap(value);
  if (object == null) {
    return null;
  }
  final smsRequestId = asNonEmptyString(object['smsRequestId']);
  final cooldownSeconds = _nonNegativeInt(object['cooldownSeconds']) ?? 60;
  if (smsRequestId == null || !_isSafeIdentifier(smsRequestId)) {
    return null;
  }
  return SendSmsCodeResponse(
    smsRequestId: smsRequestId,
    cooldownSeconds: cooldownSeconds,
  );
}

_SendSmsCodePayload? _parseSendSmsCodePayload(Object? value) {
  final ticket = parseSendSmsCodeResponse(value);
  if (ticket != null) {
    return _SendSmsCodeTicket(ticket);
  }
  return _parseSendSmsCodeFailure(value);
}

_SendSmsCodeFailure? _parseSendSmsCodeFailure(Object? value) {
  final object = asObjectMap(value);
  if (object == null || _containsSensitiveValue(object)) {
    return null;
  }
  final status = asNonEmptyString(object['status']);
  final errorCode =
      asNonEmptyString(object['errorCode']) ?? asNonEmptyString(object['code']);
  final retryable = object['retryable'] is bool
      ? object['retryable']! as bool
      : null;
  final cooldownSeconds = _nonNegativeInt(object['cooldownSeconds']);

  if (status == 'sent') {
    return _SendSmsCodeFailure(
      error: const AppFailure(
        code: 'SMS_REQUEST_ID_MISSING',
        category: AppFailureCategory.auth,
        message: 'SMS code request did not return a request ticket',
        userMessageKey: 'api.error.SMS_REQUEST_ID_MISSING',
        isRetryable: true,
        recoveryActions: <String>['retry', 'contactSupport'],
      ),
      retryAfterSeconds: cooldownSeconds,
    );
  }

  if (errorCode == null || !_isSafeIdentifier(errorCode) || retryable == null) {
    return null;
  }
  final normalizedCode = _normalizeSendSmsCodeErrorCode(errorCode);
  return _SendSmsCodeFailure(
    error: AppFailure(
      code: normalizedCode,
      category: AppFailureCategory.auth,
      message:
          safeUserFacingMessage(object['userMessage']) ??
          'SMS code request failed',
      userMessageKey: 'api.error.$normalizedCode',
      isRetryable: retryable,
      recoveryActions: retryable
          ? const <String>['retry']
          : const <String>['contactSupport'],
    ),
    retryAfterSeconds: cooldownSeconds,
  );
}

SmsLoginResponse? parseSmsLoginResponse(Object? value) {
  final object = asObjectMap(value);
  if (object == null) {
    return null;
  }
  final tokenType = asNonEmptyString(object['tokenType']);
  final accessToken = asNonEmptyString(object['accessToken']);
  final refreshToken = asNonEmptyString(object['refreshToken']);
  final user = _parseSafeUser(object['user']);
  final rawFirstLogin = object['firstLogin'] ?? object['isNewUser'];
  final rawOnboardingRequired = object['onboardingRequired'];
  if (_hasInvalidOptionalBoolean(object['firstLogin']) ||
      _hasInvalidOptionalBoolean(object['isNewUser']) ||
      (rawOnboardingRequired != null && rawOnboardingRequired is! bool)) {
    return null;
  }
  final firstLogin = rawFirstLogin as bool? ?? false;
  final onboardingRequired = rawOnboardingRequired as bool? ?? false;
  final statusProjection = asObjectMap(object['userStatus']);
  final basicPositioningCompleted = _optionalBoolean(
    object['basicPositioningCompleted'] ??
        statusProjection?['basicPositioningCompleted'],
  );
  final positioningStatus = _parsePositioningStatus(
    object['positioningStatus'] ?? statusProjection?['positioningStatus'],
  );
  final positioningProgress = _parsePositioningProgress(
    object['positioningProgress'] ?? statusProjection?['positioningProgress'],
  );
  final workspace = _parseLoginWorkspace(object['workspace']);
  final smsBypassMatched = object['smsBypassMatched'] is bool
      ? object['smsBypassMatched']! as bool
      : null;
  final smsBypassRuleId = asNonEmptyString(object['smsBypassRuleId']);

  if ((tokenType != null && tokenType != 'Bearer') ||
      accessToken == null ||
      refreshToken == null ||
      user == null ||
      workspace == null ||
      _hasInvalidOptionalBoolean(
        object['basicPositioningCompleted'] ??
            statusProjection?['basicPositioningCompleted'],
      ) ||
      _hasInvalidPositioningStatus(
        object['positioningStatus'] ?? statusProjection?['positioningStatus'],
      ) ||
      _hasInvalidPositioningProgress(
        object['positioningProgress'] ??
            statusProjection?['positioningProgress'],
      ) ||
      (smsBypassRuleId != null && !_isSafeIdentifier(smsBypassRuleId))) {
    return null;
  }

  return SmsLoginResponse(
    tokenType: tokenType,
    tokens: AuthTokens(accessToken: accessToken, refreshToken: refreshToken),
    user: user,
    firstLogin: firstLogin,
    onboardingRequired: onboardingRequired,
    basicPositioningCompleted: basicPositioningCompleted,
    positioningStatus: positioningStatus,
    positioningProgress: positioningProgress,
    workspaceStatus: workspace.status,
    defaultContentLineId: workspace.defaultContentLineId,
    smsBypassMatched: smsBypassMatched,
    smsBypassRuleId: smsBypassRuleId,
  );
}

RefreshTokenResponse? parseRefreshTokenResponse(Object? value) {
  final object = asObjectMap(value);
  if (object == null) {
    return null;
  }
  final tokenType = asNonEmptyString(object['tokenType']);
  final accessToken = asNonEmptyString(object['accessToken']);
  final refreshToken = asNonEmptyString(object['refreshToken']);
  final expiresAt = asNonEmptyString(object['accessTokenExpiresAt']);
  final expiresIn = _nonNegativeInt(object['expiresIn']);
  final rotated = object['rotated'] is bool ? object['rotated']! as bool : null;

  if ((tokenType != null && tokenType != 'Bearer') ||
      accessToken == null ||
      refreshToken == null ||
      (expiresAt != null && DateTime.tryParse(expiresAt) == null)) {
    return null;
  }

  return RefreshTokenResponse(
    tokenType: tokenType,
    tokens: AuthTokens(accessToken: accessToken, refreshToken: refreshToken),
    accessTokenExpiresAt: expiresAt == null ? null : DateTime.parse(expiresAt),
    expiresIn: expiresIn,
    rotated: rotated,
  );
}

UpdateUserTimeZoneResponse? parseUpdateUserTimeZoneResponse(Object? value) {
  final object = asObjectMap(value);
  final timeZone = object == null ? null : asNonEmptyString(object['timeZone']);
  if (timeZone == null || !_isSafeIanaTimeZone(timeZone)) {
    return null;
  }
  return UpdateUserTimeZoneResponse(timeZone: timeZone);
}

SessionUserStatus? parseUserStatusResponse(Object? value) {
  final object = asObjectMap(value);
  if (object == null || _containsSensitiveValue(object)) {
    return null;
  }
  final user = _parseSafeUser(object['user']);
  final workspace = _parseWorkspace(object['workspace']);
  final workspaceObject = asObjectMap(object['workspace']);
  final defaultContentLine =
      _parseContentLine(object['defaultContentLine']) ??
      _parseContentLine(
        workspaceObject?['creativePositioning'] ??
            workspaceObject?['contentLine'],
      );
  final onboardingRequired = object['onboardingRequired'];
  final runningTaskCount = _nonNegativeInt(object['runningTaskCount']);
  final timeZone = _parseServerTimeZone(object['timeZone']);
  final basicPositioningCompleted = _optionalBoolean(
    object['basicPositioningCompleted'],
  );
  final positioningStatus = _parsePositioningStatus(
    object['positioningStatus'],
  );
  final positioningProgress = _parsePositioningProgress(
    object['positioningProgress'],
  );
  if (user == null ||
      workspace == null ||
      runningTaskCount == null ||
      _hasInvalidOptionalBoolean(object['basicPositioningCompleted']) ||
      _hasInvalidPositioningStatus(object['positioningStatus']) ||
      _hasInvalidPositioningProgress(object['positioningProgress']) ||
      (onboardingRequired != null && onboardingRequired is! bool)) {
    return null;
  }
  return SessionUserStatus(
    user: user,
    workspace: workspace,
    defaultContentLine: defaultContentLine,
    onboardingRequired: onboardingRequired as bool?,
    basicPositioningCompleted: basicPositioningCompleted,
    positioningStatus: positioningStatus,
    positioningProgress: positioningProgress,
    runningTaskCount: runningTaskCount,
    timeZone: timeZone,
  );
}

bool _needsCreativePositioningStatusRead(SessionUserStatus status) {
  return status.workspace.status == SessionWorkspaceStatus.ready &&
      status.defaultContentLine == null &&
      status.workspace.defaultContentLineId == null &&
      status.basicPositioningCompleted != true;
}

_CreativePositioningStatusPage? _parseCreativePositioningStatusPage(
  Object? value,
) {
  if (_containsSensitiveValue(value)) return null;
  final root = asObjectMap(value);
  final rawItems = root?['items'];
  if (rawItems is! List) return null;

  SessionContentLine? defaultPositioning;
  for (final rawItem in rawItems) {
    final item = asObjectMap(rawItem);
    if (item == null) return null;
    final positioning = _parseContentLine(item);
    final status = item['status'];
    final isDefault = item['isDefault'];
    final isPlaceholder = item['isPlaceholder'];
    if (positioning == null ||
        (status != 'active' && status != 'inactive') ||
        isDefault is! bool ||
        isPlaceholder is! bool) {
      return null;
    }
    if (status == 'active' && isDefault && !isPlaceholder) {
      defaultPositioning = positioning;
    }
  }
  return _CreativePositioningStatusPage(defaultPositioning: defaultPositioning);
}

SessionUserStatus _withDefaultPositioning(
  SessionUserStatus status,
  SessionContentLine defaultPositioning,
) {
  return SessionUserStatus(
    user: status.user,
    workspace: status.workspace,
    defaultContentLine: defaultPositioning,
    onboardingRequired: status.onboardingRequired,
    basicPositioningCompleted: status.basicPositioningCompleted,
    positioningStatus: status.positioningStatus,
    positioningProgress: status.positioningProgress,
    runningTaskCount: status.runningTaskCount,
    timeZone: status.timeZone,
  );
}

SafeAuthSessionSnapshot loginResponseToSessionSnapshot(
  SmsLoginResponse response,
  DateTime now,
) {
  return SafeAuthSessionSnapshot(
    user: response.user,
    expiresAt: now.toUtc().add(const Duration(days: 1)),
    workspaceStatus: response.workspaceStatus,
    onboardingRequired: response.basicPositioningCompleted == null
        ? response.onboardingRequired
        : !response.basicPositioningCompleted!,
    basicPositioningCompleted: response.basicPositioningCompleted,
    positioningStatus: response.positioningStatus,
    positioningProgress: response.positioningProgress,
    needsWorkspaceRetry:
        response.workspaceStatus == SessionWorkspaceStatus.syncFailed,
    defaultContentLine: response.defaultContentLineId == null
        ? null
        : SessionContentLine(
            contentLineId: response.defaultContentLineId!,
            name: response.defaultContentLineId!,
          ),
  );
}

SafeAuthSessionSnapshot userStatusToSessionSnapshot(
  SessionUserStatus status,
  DateTime restoredAt, {
  bool onboardingRequiredFallback = false,
}) {
  return SafeAuthSessionSnapshot(
    user: status.user,
    expiresAt: restoredAt.toUtc().add(const Duration(days: 1)),
    workspaceStatus: status.workspace.status,
    onboardingRequired: _onboardingRequiredFromStatus(
      status,
      fallback: onboardingRequiredFallback,
    ),
    basicPositioningCompleted: status.basicPositioningCompleted,
    positioningStatus: status.positioningStatus,
    positioningProgress: status.positioningProgress,
    needsWorkspaceRetry:
        status.workspace.status == SessionWorkspaceStatus.syncFailed,
    defaultContentLine: status.defaultContentLine,
  );
}

bool _onboardingRequiredFromStatus(
  SessionUserStatus status, {
  required bool fallback,
}) {
  final explicit = status.onboardingRequired;
  if (explicit != null) return explicit;
  final defaultContentLine = status.defaultContentLine;
  if (defaultContentLine == null) return fallback;
  return status.workspace.status == SessionWorkspaceStatus.ready &&
      (defaultContentLine.isPlaceholder ?? false);
}

AuthApiResult<T> _toAuthApiResult<T>(ApiResult<T> result) {
  if (result.ok) {
    return AuthApiResult<T>.success(
      value: result.data as T,
      status: result.status ?? 200,
      traceId: result.traceId,
    );
  }
  return AuthApiResult<T>.failure(
    error: result.error!,
    traceId: result.traceId,
    status: result.status,
    authExpired: result.authExpired,
    retryAfterSeconds: result.retryAfterSeconds,
  );
}

SessionUser? _parseSafeUser(Object? value) {
  final object = asObjectMap(value);
  if (object == null || _containsSensitiveValue(object)) {
    return null;
  }
  final userId = asNonEmptyString(object['userId']);
  final displayName = asNonEmptyString(object['displayName']);
  final maskedPhone =
      asNonEmptyString(object['phoneMasked']) ??
      asNonEmptyString(object['maskedPhoneNumber']) ??
      _maskCanonicalPhoneHash(object['phoneHash']);
  if (userId == null ||
      !_isSafeIdentifier(userId) ||
      maskedPhone == null ||
      !_isMaskedUserReference(maskedPhone) ||
      (displayName != null && displayName.trim().isEmpty)) {
    return null;
  }
  return SessionUser(
    userId: userId,
    displayName: displayName,
    maskedPhoneNumber: maskedPhone,
  );
}

String? _maskCanonicalPhoneHash(Object? value) {
  final hash = asNonEmptyString(value);
  if (hash == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
    return null;
  }
  return '${hash.substring(0, 4)}***${hash.substring(hash.length - 4)}';
}

({SessionWorkspaceStatus status, String? defaultContentLineId})?
_parseLoginWorkspace(Object? value) {
  final object = asObjectMap(value);
  if (object == null) {
    return null;
  }
  final status = _parseWorkspaceStatus(object['status']);
  final defaultContentLineId = asNonEmptyString(
    object['defaultContentLineId'] ?? object['defaultCreativePositioningId'],
  );
  if (status == null ||
      (defaultContentLineId != null &&
          !_isSafeIdentifier(defaultContentLineId))) {
    return null;
  }
  return (status: status, defaultContentLineId: defaultContentLineId);
}

SessionWorkspace? _parseWorkspace(Object? value) {
  final object = asObjectMap(value);
  if (object == null || _containsSensitiveValue(object)) {
    return null;
  }
  final status = _parseWorkspaceStatus(object['status']);
  final workspaceId = asNonEmptyString(object['workspaceId']);
  final defaultContentLineId = asNonEmptyString(
    object['defaultContentLineId'] ?? object['defaultCreativePositioningId'],
  );
  final lastSyncedAt = asNonEmptyString(object['lastSyncedAt']);
  if (status == null ||
      (workspaceId != null && !_isSafeIdentifier(workspaceId)) ||
      (defaultContentLineId != null &&
          !_isSafeIdentifier(defaultContentLineId)) ||
      (lastSyncedAt != null && DateTime.tryParse(lastSyncedAt) == null)) {
    return null;
  }
  return SessionWorkspace(
    status: status,
    workspaceId: workspaceId,
    defaultContentLineId: defaultContentLineId,
    lastSyncedAt: lastSyncedAt == null ? null : DateTime.parse(lastSyncedAt),
  );
}

SessionContentLine? _parseContentLine(Object? value) {
  if (value == null) {
    return null;
  }
  final object = asObjectMap(value);
  if (object == null || _containsSensitiveValue(object)) {
    return null;
  }
  final contentLineId = asNonEmptyString(
    object['contentLineId'] ?? object['creativePositioningId'],
  );
  final name = asNonEmptyString(object['name']);
  final isPlaceholder = object['isPlaceholder'];
  if (contentLineId == null ||
      !_isSafeIdentifier(contentLineId) ||
      name == null ||
      (isPlaceholder != null && isPlaceholder is! bool)) {
    return null;
  }
  return SessionContentLine(
    contentLineId: contentLineId,
    name: name,
    isPlaceholder: isPlaceholder as bool?,
  );
}

SessionWorkspaceStatus? _parseWorkspaceStatus(Object? value) {
  switch (value) {
    case 'ready':
      return SessionWorkspaceStatus.ready;
    case 'creating':
      return SessionWorkspaceStatus.creating;
    case 'sync_failed':
      return SessionWorkspaceStatus.syncFailed;
  }
  return null;
}

bool? _optionalBoolean(Object? value) => value is bool ? value : null;

bool _hasInvalidOptionalBoolean(Object? value) =>
    value != null && value is! bool;

SessionPositioningStatus? _parsePositioningStatus(Object? value) {
  return switch (value) {
    'not_started' => SessionPositioningStatus.notStarted,
    'in_progress' => SessionPositioningStatus.inProgress,
    'completed' => SessionPositioningStatus.completed,
    _ => null,
  };
}

bool _hasInvalidPositioningStatus(Object? value) =>
    value != null && _parsePositioningStatus(value) == null;

SessionPositioningProgress? _parsePositioningProgress(Object? value) {
  if (value == null) return null;
  final object = asObjectMap(value);
  if (object == null) return null;
  final coldStartPercent = _percentage(object['coldStartPercent']);
  final coldStartCompleted = _optionalBoolean(object['coldStartCompleted']);
  final completedPercent = _percentage(object['completedPercent']);
  if (_hasInvalidPercentage(object['coldStartPercent']) ||
      _hasInvalidOptionalBoolean(object['coldStartCompleted']) ||
      _hasInvalidPercentage(object['completedPercent'])) {
    return null;
  }
  return SessionPositioningProgress(
    coldStartPercent: coldStartPercent,
    coldStartCompleted: coldStartCompleted,
    completedPercent: completedPercent,
  );
}

bool _hasInvalidPositioningProgress(Object? value) =>
    value != null && _parsePositioningProgress(value) == null;

int? _percentage(Object? value) {
  final parsed = _nonNegativeInt(value);
  return parsed != null && parsed <= 100 ? parsed : null;
}

bool _hasInvalidPercentage(Object? value) =>
    value != null && _percentage(value) == null;

int? _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) {
    return value;
  }
  if (value is num && value.isFinite && value >= 0) {
    return value.round();
  }
  return null;
}

String _normalizeSendSmsCodeErrorCode(String errorCode) {
  switch (errorCode) {
    case 'SMS_PROVIDER_RATE_LIMITED':
      return 'SMS_RATE_LIMITED';
    case 'SMS_PHONE_INVALID':
      return 'PHONE_INVALID';
    case 'SMS_PROVIDER_TIMEOUT':
    case 'SMS_PROVIDER_AUTH_FAILED':
    case 'SMS_INTERNAL_ERROR':
      return 'SMS_PROVIDER_FAILED';
    default:
      return errorCode;
  }
}

AppFailure _normalizeSendSmsCodeFailure(AppFailure failure) {
  final normalizedCode = _normalizeSendSmsCodeErrorCode(failure.code);
  if (normalizedCode == failure.code) {
    return failure;
  }
  return failure.copyWith(
    code: normalizedCode,
    userMessageKey: 'api.error.$normalizedCode',
  );
}

bool _isSafeIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(value) &&
      !_containsSensitiveValue(value);
}

bool _isSafeIanaTimeZone(String value) {
  return value == 'UTC' ||
      RegExp(
        r'^[A-Za-z][A-Za-z0-9_+\-]*/[A-Za-z0-9_+\-]+(?:/[A-Za-z0-9_+\-]+)*$',
      ).hasMatch(value);
}

String? _parseServerTimeZone(Object? value) {
  // Backend zoneinfo can canonicalize valid aliases such as GMT or CET.
  final timeZone = asNonEmptyString(value)?.trim();
  if (timeZone == null ||
      timeZone.isEmpty ||
      timeZone == 'Local' ||
      timeZone.length > 64 ||
      !RegExp(r'^[A-Za-z0-9_+/\-]+$').hasMatch(timeZone)) {
    return null;
  }
  return timeZone;
}

bool _isMaskedUserReference(String value) {
  final trimmed = value.trim();
  final synthetic = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]{0,15}\*{3,4}[A-Za-z0-9_-]{1,16}$',
  );
  return trimmed == value &&
      value.length <= 40 &&
      (RegExp(r'^\d{3}\*{4}\d{4}$').hasMatch(value) ||
          RegExp(r'^[a-f0-9]{4}\*{3}[a-f0-9]{4}$').hasMatch(value) ||
          synthetic.hasMatch(value) ||
          value == '***' ||
          value == 'hash***');
}

bool _containsSensitiveValue(Object? value) {
  if (value == null) {
    return false;
  }
  if (value is String) {
    return _sensitiveValuePatterns.any((pattern) => pattern.hasMatch(value));
  }
  if (value is Iterable) {
    return value.any(_containsSensitiveValue);
  }
  if (value is Map) {
    return value.entries.any(
      (entry) =>
          _sensitiveKeyPatterns.any(
            (pattern) => pattern.hasMatch(entry.key.toString()),
          ) ||
          _containsSensitiveValue(entry.value),
    );
  }
  return false;
}

final _sensitiveKeyPatterns = <RegExp>[
  RegExp('token', caseSensitive: false),
  RegExp('authorization', caseSensitive: false),
  RegExp('password', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
  RegExp('push.*token', caseSensitive: false),
  RegExp('raw.*phone', caseSensitive: false),
  RegExp('transcript', caseSensitive: false),
  RegExp('chat.*text', caseSensitive: false),
  RegExp('profile', caseSensitive: false),
  RegExp('markdown', caseSensitive: false),
  RegExp('provider.*debug', caseSensitive: false),
  RegExp('internal.*error', caseSensitive: false),
  RegExp('local.*path', caseSensitive: false),
  RegExp('server.*path', caseSensitive: false),
  RegExp('real.*path', caseSensitive: false),
  RegExp(r'^path$', caseSensitive: false),
  RegExp('payload', caseSensitive: false),
  RegExp('details', caseSensitive: false),
];

final _sensitiveValuePatterns = <RegExp>[
  RegExp('^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'\\Users\\', caseSensitive: false),
  RegExp('/Users/[^/]+', caseSensitive: false),
  RegExp('^https?://', caseSensitive: false),
  RegExp('access-token', caseSensitive: false),
  RegExp('refresh-token', caseSensitive: false),
  RegExp('authorization', caseSensitive: false),
  RegExp('password', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
  RegExp('HTTP 500'),
  RegExp('Native Module Error'),
  RegExp('GATT_ERROR'),
  RegExp('CRC_FAIL'),
];
