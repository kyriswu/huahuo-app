import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_auth_port.dart';

const _fallbackDesktopAuthRuntime = DesktopAuthRuntime(
  deviceId: 'desktop-unknown',
  clientVersion: '0.1.0',
  timeZone: 'UTC',
);

final _safeProfileResourceId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

abstract interface class DesktopTokenStore {
  Future<String?> readAccessToken();

  Future<String?> readRefreshToken();

  Future<DesktopAuthAccount?> readCachedAccount();

  Future<void> write(SharedAuthTokens tokens);

  Future<void> writeCachedAccount(DesktopAuthAccount account);

  Future<void> clear();

  Future<void> clearAccessToken();
}

final class SecureDesktopTokenStore implements DesktopTokenStore {
  const SecureDesktopTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'huahuo.desktop.access-token';
  static const _refreshTokenKey = 'huahuo.desktop.refresh-token';
  static const _accountSnapshotKey = 'huahuo.desktop.account-snapshot';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readAccessToken() => _readNonEmpty(_accessTokenKey);

  @override
  Future<String?> readRefreshToken() => _readNonEmpty(_refreshTokenKey);

  @override
  Future<DesktopAuthAccount?> readCachedAccount() async {
    final raw = await _storage.read(key: _accountSnapshotKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      final account = _parseCachedAccount(decoded);
      if (account != null) return account;
    } on Object {
      // A malformed local cache must never block a valid token restore.
    }
    await _storage.delete(key: _accountSnapshotKey);
    return null;
  }

  @override
  Future<void> write(SharedAuthTokens tokens) async {
    await _storage.write(key: _accessTokenKey, value: tokens.accessToken);
    try {
      await _storage.write(key: _refreshTokenKey, value: tokens.refreshToken);
    } on Object {
      await clear();
      rethrow;
    }
  }

  @override
  Future<void> writeCachedAccount(DesktopAuthAccount account) => _storage.write(
    key: _accountSnapshotKey,
    value: jsonEncode(_encodeCachedAccount(account)),
  );

  @override
  Future<void> clear() async {
    await Future.wait(<Future<void>>[
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _accountSnapshotKey),
    ]);
  }

  @override
  Future<void> clearAccessToken() => _storage.delete(key: _accessTokenKey);

  Future<String?> _readNonEmpty(String key) async {
    final value = await _storage.read(key: key);
    if (value == null) return null;
    if (value.isEmpty) {
      await _storage.delete(key: key);
      return null;
    }
    return value;
  }
}

final class RemoteDesktopAuthPort implements DesktopAuthPort {
  const RemoteDesktopAuthPort(
    this._apiClient,
    this._tokenStore, {
    this.runtime = _fallbackDesktopAuthRuntime,
  });

  final ApiClient _apiClient;
  final DesktopTokenStore _tokenStore;
  final DesktopAuthRuntime runtime;
  AuthClient get _authClient => AuthClient(_apiClient);

  @override
  Future<DesktopServiceResult<DesktopSmsChallenge>> requestSmsCode(
    String phone,
  ) async {
    final normalized = phone.trim();
    if (normalized.isEmpty) {
      return const DesktopServiceResult<DesktopSmsChallenge>.failure(
        code: 'PHONE_INVALID',
        message: '请输入手机号',
      );
    }
    final result = await _authClient.requestSmsCode<SharedSmsCodeReceipt>(
      phone: normalized,
      idempotency: IdempotencyRequestContext(
        operation: 'desktop.auth.sms-code',
        localDraftId: normalized,
      ),
      parseData: (value) => _parseObject(value, SharedSmsCodeReceipt.fromJson),
    );
    if (!result.ok) return _failure(result);
    final receipt = result.data!;
    return DesktopServiceResult<DesktopSmsChallenge>.success(
      DesktopSmsChallenge(
        smsRequestId: receipt.smsRequestId,
        cooldownSeconds: receipt.cooldownSeconds,
      ),
    );
  }

  @override
  Future<DesktopServiceResult<DesktopAuthAccount>> signIn({
    required String phone,
    required String smsRequestId,
    required String code,
    required bool agreementAccepted,
  }) async {
    final result = await _authClient.login<SharedAuthSession>(
      body: <String, Object?>{
        'phone': phone.trim(),
        'smsRequestId': smsRequestId,
        'smsCode': code.trim(),
        'agreementAccepted': agreementAccepted,
        'agreementVersion': runtime.agreementVersion,
        'privacyVersion': runtime.privacyVersion,
        'clientVersion': runtime.clientVersion,
        'deviceId': runtime.deviceId,
        'timeZone': runtime.timeZone,
      },
      idempotency: IdempotencyRequestContext(
        operation: 'desktop.auth.login',
        localDraftId: smsRequestId,
      ),
      parseData: (value) => _parseObject(value, SharedAuthSession.fromJson),
    );
    if (!result.ok) return _failure(result);
    try {
      await _tokenStore.write(result.data!.tokens);
    } on Object {
      return const DesktopServiceResult<DesktopAuthAccount>.failure(
        code: 'SECURE_TOKEN_WRITE_FAILED',
        message: '登录成功，但无法安全保存会话',
      );
    }
    final status = await _loadAccount(result.data!.tokens.accessToken);
    if (!status.isSuccess) return _failureFromService(status);
    await _rememberAccount(status.data!);
    return DesktopServiceResult<DesktopAuthAccount>.success(status.data!);
  }

  @override
  Future<DesktopServiceResult<DesktopAuthAccount?>> restoreSession() async {
    String? accessToken;
    String? refreshToken;
    DesktopAuthAccount? cachedAccount;
    try {
      accessToken = await _tokenStore.readAccessToken();
      refreshToken = await _tokenStore.readRefreshToken();
      cachedAccount = await _tokenStore.readCachedAccount();
    } on Object {
      return const DesktopServiceResult<DesktopAuthAccount?>.failure(
        code: 'SECURE_TOKEN_READ_FAILED',
        message: '无法读取安全会话',
      );
    }
    if (accessToken == null && refreshToken == null) {
      if (cachedAccount != null) await _tokenStore.clear();
      return const DesktopServiceResult<DesktopAuthAccount?>.success(null);
    }
    if (accessToken != null) {
      final status = await _loadAccount(accessToken);
      if (status.isSuccess) {
        await _rememberAccount(status.data!);
        return DesktopServiceResult<DesktopAuthAccount?>.success(status.data);
      }
      if (!_isExplicitSessionExpiry(status.code)) {
        if (cachedAccount != null) {
          return DesktopServiceResult<DesktopAuthAccount?>.success(
            cachedAccount,
          );
        }
        return _failureFromService(status);
      }
      await _tokenStore.clearAccessToken();
    }
    if (refreshToken == null) {
      await _tokenStore.clear();
      return const DesktopServiceResult<DesktopAuthAccount?>.failure(
        code: 'AUTH_SESSION_EXPIRED',
        message: '安全会话已过期，请重新登录',
      );
    }
    final refreshed = await _authClient.refresh<SharedAuthTokens>(
      refreshToken: refreshToken,
      parseData: (value) => _parseObject(value, SharedAuthTokens.fromJson),
    );
    if (!refreshed.ok) {
      if (_isExplicitSessionExpiry(refreshed.error?.code)) {
        await _tokenStore.clear();
      } else if (cachedAccount != null) {
        return DesktopServiceResult<DesktopAuthAccount?>.success(cachedAccount);
      }
      return _failure(refreshed);
    }
    try {
      await _tokenStore.write(refreshed.data!);
    } on Object {
      return const DesktopServiceResult<DesktopAuthAccount?>.failure(
        code: 'SECURE_TOKEN_WRITE_FAILED',
        message: '会话已刷新，但无法安全保存',
      );
    }
    final status = await _loadAccount(refreshed.data!.accessToken);
    if (!status.isSuccess) {
      if (_isExplicitSessionExpiry(status.code)) {
        await _tokenStore.clear();
        return _failureFromService(status);
      }
      if (cachedAccount != null) {
        return DesktopServiceResult<DesktopAuthAccount?>.success(cachedAccount);
      }
      return _failureFromService(status);
    }
    await _rememberAccount(status.data!);
    return DesktopServiceResult<DesktopAuthAccount?>.success(status.data);
  }

  @override
  Future<DesktopServiceResult<void>> retryWorkspaceCreation() async {
    final result = await _apiClient.request<Object?>(
      ApiRequestOptions<Object?>(
        endpointId: 'workspaceRetryCreate',
        body: const <String, Object?>{},
        idempotency: const IdempotencyRequestContext(
          operation: 'desktop.workspace.retry-create',
          scene: 'workspace-recovery',
        ),
        parseData: (value) => value,
      ),
    );
    if (!result.ok) return _failure<void>(result);
    return const DesktopServiceResult<void>.success(null);
  }

  @override
  Future<DesktopServiceResult<DesktopUserProfile>> loadProfile() async {
    final result = await _apiClient.request<DesktopUserProfile>(
      const ApiRequestOptions<DesktopUserProfile>(
        endpointId: 'meProfile',
        parseData: _parseProfile,
      ),
    );
    return result.ok && result.data != null
        ? DesktopServiceResult<DesktopUserProfile>.success(result.data!)
        : _failure(result);
  }

  @override
  Future<DesktopServiceResult<DesktopUserProfile>> updateProfile({
    required String displayName,
  }) async {
    final normalized = displayName.trim();
    if (!_isValidDisplayName(normalized)) {
      return const DesktopServiceResult<DesktopUserProfile>.failure(
        code: 'PROFILE_DISPLAY_NAME_INVALID',
        message: '请输入 1 到 64 个字符的昵称',
      );
    }
    final result = await _apiClient.request<DesktopUserProfile>(
      ApiRequestOptions<DesktopUserProfile>(
        endpointId: 'updateMeProfile',
        body: <String, Object?>{'displayName': normalized},
        idempotency: IdempotencyRequestContext(
          operation: 'desktop.profile.update',
          localDraftId:
              '$normalized-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        ),
        parseData: _parseProfile,
      ),
    );
    return result.ok && result.data != null
        ? DesktopServiceResult<DesktopUserProfile>.success(result.data!)
        : _failure(result);
  }

  Future<DesktopServiceResult<DesktopAuthAccount>> _loadAccount(
    String accessToken,
  ) async {
    final status = await _authClient.getUserStatus<DesktopAuthAccount>(
      accessToken: accessToken,
      parseData: _parseAccountStatus,
    );
    if (!status.ok) return _failure(status);
    return DesktopServiceResult<DesktopAuthAccount>.success(status.data!);
  }

  Future<void> _rememberAccount(DesktopAuthAccount account) async {
    try {
      await _tokenStore.writeCachedAccount(account);
    } on Object {
      // A cache write is not an authorization failure for the active session.
    }
  }

  @override
  Future<DesktopServiceResult<void>> signOut() async {
    try {
      await _tokenStore.clear();
      return const DesktopServiceResult<void>.success(null);
    } on Object {
      return const DesktopServiceResult<void>.failure(
        code: 'SECURE_TOKEN_CLEAR_FAILED',
        message: '无法清除本机会话',
      );
    }
  }
}

final class UnavailableDesktopAuthPort implements DesktopAuthPort {
  const UnavailableDesktopAuthPort();

  @override
  Future<DesktopServiceResult<DesktopAuthAccount?>> restoreSession() async =>
      const DesktopServiceResult<DesktopAuthAccount?>.unavailable(
        code: 'DESKTOP_AUTH_UNAVAILABLE',
        message: '未配置后端，账号登录暂不可用',
      );

  @override
  Future<DesktopServiceResult<DesktopSmsChallenge>> requestSmsCode(
    String phone,
  ) async => const DesktopServiceResult<DesktopSmsChallenge>.unavailable(
    code: 'DESKTOP_AUTH_UNAVAILABLE',
    message: '未配置后端，无法发送验证码',
  );

  @override
  Future<DesktopServiceResult<DesktopAuthAccount>> signIn({
    required String phone,
    required String smsRequestId,
    required String code,
    required bool agreementAccepted,
  }) async => const DesktopServiceResult<DesktopAuthAccount>.unavailable(
    code: 'DESKTOP_AUTH_UNAVAILABLE',
    message: '未配置后端，账号登录暂不可用',
  );

  @override
  Future<DesktopServiceResult<DesktopUserProfile>> loadProfile() async =>
      const DesktopServiceResult<DesktopUserProfile>.unavailable(
        code: 'DESKTOP_AUTH_UNAVAILABLE',
        message: '未配置后端，无法读取个人资料',
      );

  @override
  Future<DesktopServiceResult<DesktopUserProfile>> updateProfile({
    required String displayName,
  }) async => const DesktopServiceResult<DesktopUserProfile>.unavailable(
    code: 'DESKTOP_AUTH_UNAVAILABLE',
    message: '未配置后端，无法保存个人资料',
  );

  @override
  Future<DesktopServiceResult<void>> retryWorkspaceCreation() async =>
      const DesktopServiceResult<void>.unavailable(
        code: 'DESKTOP_AUTH_UNAVAILABLE',
        message: '未配置后端，无法重新初始化 Workspace',
      );

  @override
  Future<DesktopServiceResult<void>> signOut() async =>
      const DesktopServiceResult<void>.success(null);
}

T? _parseObject<T>(
  Object? value,
  T Function(Map<String, Object?> json) parser,
) {
  final json = asObjectMap(value);
  return json == null ? null : parser(json);
}

DesktopAuthAccount? _parseAccountStatus(Object? value) {
  final json = asObjectMap(value);
  final userJson = asObjectMap(json?['user']);
  final workspaceJson = asObjectMap(json?['workspace']);
  if (json == null || userJson == null || workspaceJson == null) return null;
  final user = SharedUser.fromJson(userJson);
  final workspaceStatus = workspaceJson['status'];
  final workspaceId = workspaceJson['workspaceId'];
  if (workspaceStatus is! String || workspaceStatus.isEmpty) return null;
  if (workspaceId != null && (workspaceId is! String || workspaceId.isEmpty)) {
    return null;
  }
  return DesktopAuthAccount(
    userId: user.userId,
    displayName: user.displayName ?? '花火创作者',
    workspaceStatus: workspaceStatus,
    workspaceId: workspaceId as String?,
  );
}

DesktopUserProfile? _parseProfile(Object? value) {
  final data = asObjectMap(value);
  final profile = data == null ? null : asObjectMap(data['profile']) ?? data;
  if (profile == null) return null;
  final rawDisplayName = profile['displayName'];
  if (rawDisplayName is! String) return null;
  final displayName = rawDisplayName.trim();
  if (!_isValidDisplayName(displayName)) return null;
  final rawAvatarResourceId = profile['avatarResourceId'];
  if (rawAvatarResourceId != null &&
      (rawAvatarResourceId is! String ||
          !_safeProfileResourceId.hasMatch(rawAvatarResourceId))) {
    return null;
  }
  return DesktopUserProfile(
    displayName: displayName,
    avatarResourceId: rawAvatarResourceId as String?,
  );
}

bool _isValidDisplayName(String value) =>
    value.isNotEmpty &&
    value.runes.length <= 64 &&
    !value.runes.any(_isControl);

bool _isControl(int rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f);

bool _isExplicitSessionExpiry(String? code) =>
    code == 'AUTH_SESSION_EXPIRED' || code == 'TOKEN_EXPIRED';

Map<String, Object?> _encodeCachedAccount(DesktopAuthAccount account) =>
    <String, Object?>{
      'userId': account.userId,
      'displayName': account.displayName,
      'workspaceStatus': account.workspaceStatus,
      if (account.workspaceId != null) 'workspaceId': account.workspaceId,
    };

DesktopAuthAccount? _parseCachedAccount(Object? value) {
  final json = asObjectMap(value);
  if (json == null) return null;
  final userId = json['userId'];
  final displayName = json['displayName'];
  final workspaceStatus = json['workspaceStatus'];
  final workspaceId = json['workspaceId'];
  if (userId is! String ||
      !_safeProfileResourceId.hasMatch(userId) ||
      displayName is! String ||
      !_isValidDisplayName(displayName.trim()) ||
      workspaceStatus is! String ||
      !RegExp(r'^[a-z][a-z_]{1,63}$').hasMatch(workspaceStatus) ||
      (workspaceId != null &&
          (workspaceId is! String ||
              !_safeProfileResourceId.hasMatch(workspaceId)))) {
    return null;
  }
  return DesktopAuthAccount(
    userId: userId,
    displayName: displayName.trim(),
    workspaceStatus: workspaceStatus,
    workspaceId: workspaceId as String?,
  );
}

DesktopServiceResult<T> _failureFromService<T>(
  DesktopServiceResult<Object?> result,
) {
  if (result.isUnavailable) {
    return DesktopServiceResult<T>.unavailable(
      code: result.code,
      message: result.message,
    );
  }
  return DesktopServiceResult<T>.failure(
    code: result.code,
    message: result.message,
    retryable: result.retryable,
  );
}

DesktopServiceResult<T> _failure<T>(ApiResult<Object?> result) {
  final error = result.error;
  return DesktopServiceResult<T>.failure(
    code: error?.code ?? 'DESKTOP_API_FAILED',
    message: error?.message ?? '服务请求失败',
    retryable: error?.isRetryable ?? false,
  );
}
