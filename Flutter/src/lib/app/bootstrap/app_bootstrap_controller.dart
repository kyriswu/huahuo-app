import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/secure_token_store.dart';
import '../../core/auth/session_store.dart';
import '../../features/auth/data/auth_api.dart';

enum AppBootstrapStatus { idle, restoring, ready, failed }

final class AppBootstrapState {
  const AppBootstrapState({required this.status, this.errorCode});

  const AppBootstrapState.idle()
    : status = AppBootstrapStatus.idle,
      errorCode = null;

  const AppBootstrapState.restoring()
    : status = AppBootstrapStatus.restoring,
      errorCode = null;

  const AppBootstrapState.ready()
    : status = AppBootstrapStatus.ready,
      errorCode = null;

  const AppBootstrapState.failed(this.errorCode)
    : status = AppBootstrapStatus.failed;

  final AppBootstrapStatus status;
  final String? errorCode;
}

final class AuthSessionRefreshCoordinator {
  AuthSessionRefreshCoordinator({
    required SecureTokenStore secureTokenStore,
    required SessionStore sessionStore,
    required AuthApiPort authApi,
    DateTime Function()? now,
    String Function()? correlationIdFactory,
  }) : _secureTokenStore = secureTokenStore,
       _sessionStore = sessionStore,
       _authApi = authApi,
       _now = now ?? DateTime.now,
       _correlationIdFactory = correlationIdFactory;

  final SecureTokenStore _secureTokenStore;
  final SessionStore _sessionStore;
  final AuthApiPort _authApi;
  final DateTime Function() _now;
  final String Function()? _correlationIdFactory;
  Future<AccessTokenRefreshDisposition>? _inFlight;

  Future<AccessTokenRefreshDisposition> refresh({
    required String rejectedAccessToken,
    required AppFailure failure,
  }) {
    final active = _inFlight;
    if (active != null) return active;
    final operation = _refresh(
      rejectedAccessToken: rejectedAccessToken,
      failure: failure,
    );
    _inFlight = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
  }

  Future<AccessTokenRefreshDisposition> _refresh({
    required String rejectedAccessToken,
    required AppFailure failure,
  }) async {
    final tokenResult = await _secureTokenStore.getTokens();
    final currentTokens = tokenResult.ok ? tokenResult.value : null;
    if (currentTokens == null || isLocalNumericAuthTokens(currentTokens)) {
      return AccessTokenRefreshDisposition.unavailable;
    }
    if (currentTokens.accessToken != rejectedAccessToken) {
      return AccessTokenRefreshDisposition.refreshed;
    }
    final hintResult = await _secureTokenStore.getRecoveryHint();
    if (!hintResult.ok) return AccessTokenRefreshDisposition.unavailable;

    final result = await _authApi.refreshAuthToken(
      refreshToken: currentTokens.refreshToken,
      correlationId:
          _correlationIdFactory?.call() ??
          'auth-refresh-${_now().toUtc().microsecondsSinceEpoch}',
    );
    if (!result.ok || result.value == null) {
      if (!_isRejectedRefresh(result)) {
        return AccessTokenRefreshDisposition.unavailable;
      }
      if (await _stillOwns(currentTokens) != true) {
        return AccessTokenRefreshDisposition.unavailable;
      }
      final cleared = await _secureTokenStore.clearTokens(
        SecureTokenClearReason.unauthorized,
      );
      if (!cleared.ok) return AccessTokenRefreshDisposition.unavailable;
      _sessionStore.restoreExpired(
        errorCode: result.error?.code ?? failure.code,
        restoredAt: _now().toUtc(),
      );
      return AccessTokenRefreshDisposition.rejected;
    }

    if (await _stillOwns(currentTokens) != true) {
      return AccessTokenRefreshDisposition.unavailable;
    }
    final saved = await _secureTokenStore.setTokens(
      result.value!.tokens,
      recoveryHint: hintResult.value,
    );
    return saved.ok
        ? AccessTokenRefreshDisposition.refreshed
        : AccessTokenRefreshDisposition.unavailable;
  }

  Future<bool?> _stillOwns(AuthTokens expected) async {
    final latestResult = await _secureTokenStore.getTokens();
    if (!latestResult.ok) return null;
    final latest = latestResult.value;
    if (latest == null || isLocalNumericAuthTokens(latest)) return false;
    return latest.accessToken == expected.accessToken &&
        latest.refreshToken == expected.refreshToken;
  }
}

final class AppBootstrapController extends ChangeNotifier {
  AppBootstrapController({
    required SecureTokenStore secureTokenStore,
    required SessionStore sessionStore,
    required AuthApiPort authApi,
    AuthSessionRefreshCoordinator? sessionRefresh,
    this.userTimeZone = 'UTC',
    this.userTimeZoneIsFallback = false,
    UserTimeZoneApiPort? userTimeZoneApi,
    DateTime Function()? now,
    String Function()? correlationIdFactory,
    Duration restoreTimeout = const Duration(seconds: 12),
    Duration statusRefreshFreshness = const Duration(seconds: 30),
  }) : _secureTokenStore = secureTokenStore,
       _sessionStore = sessionStore,
       _authApi = authApi,
       _sessionRefresh = sessionRefresh,
       _userTimeZoneApi = userTimeZoneApi,
       _now = now,
       _correlationIdFactory = correlationIdFactory,
       _restoreTimeout = restoreTimeout,
       _statusRefreshFreshness = statusRefreshFreshness;

  final SecureTokenStore _secureTokenStore;
  final SessionStore _sessionStore;
  final AuthApiPort _authApi;
  final AuthSessionRefreshCoordinator? _sessionRefresh;
  final UserTimeZoneApiPort? _userTimeZoneApi;
  final String userTimeZone;
  final bool userTimeZoneIsFallback;
  final DateTime Function()? _now;
  final String Function()? _correlationIdFactory;
  final Duration _restoreTimeout;
  final Duration _statusRefreshFreshness;

  AppBootstrapState _state = const AppBootstrapState.idle();
  Future<void>? _statusRefreshInFlight;
  DateTime? _lastSuccessfulStatusRefreshAt;
  String? _lastSuccessfulStatusRefreshUserId;
  bool _disposed = false;

  AppBootstrapState get state => _state;

  void markRestoreTimedOut() {
    markRestoreFailed('SESSION_RESTORE_TIMEOUT');
  }

  void markRestoreFailed(String errorCode) {
    if (_state.status == AppBootstrapStatus.idle ||
        _state.status == AppBootstrapStatus.restoring) {
      _setState(AppBootstrapState.failed(_safeErrorCode(errorCode)));
    }
  }

  Future<void> resetToLogin() async {
    if (_state.status == AppBootstrapStatus.restoring) {
      return;
    }
    _setState(const AppBootstrapState.restoring());
    final cleared = await _secureTokenStore.clearTokens(
      SecureTokenClearReason.logout,
    );
    if (!cleared.ok) {
      debugPrint(
        '[Bootstrap] phone-login reset could not clear old credential '
        'code=${_safeErrorCode(cleared.error?.code ?? 'SECURE_TOKEN_CLEAR_FAILED')}',
      );
    }
    _sessionStore.restoreAnonymous(restoredAt: _currentTime());
    _setState(const AppBootstrapState.ready());
  }

  Future<void> restore() async {
    if (_state.status == AppBootstrapStatus.restoring) {
      return;
    }
    _setState(const AppBootstrapState.restoring());
    try {
      await _restoreInner().timeout(_restoreTimeout);
    } on TimeoutException {
      _setState(const AppBootstrapState.failed('SESSION_RESTORE_TIMEOUT'));
    }
  }

  Future<void> refreshStatus() {
    if (_state.status != AppBootstrapStatus.ready ||
        _sessionStore.state.authState != SessionAuthState.authenticated) {
      return Future<void>.value();
    }
    final active = _statusRefreshInFlight;
    if (active != null) return active;
    final refreshedAt = _lastSuccessfulStatusRefreshAt;
    final currentUserId = _sessionStore.state.user?.userId;
    final age = refreshedAt == null
        ? null
        : _currentTime().difference(refreshedAt);
    if (_sessionStore.state.workspaceStatus == SessionWorkspaceStatus.ready &&
        currentUserId != null &&
        currentUserId == _lastSuccessfulStatusRefreshUserId &&
        _statusRefreshFreshness > Duration.zero &&
        age != null &&
        !age.isNegative &&
        age < _statusRefreshFreshness) {
      return Future<void>.value();
    }
    final refresh = _refreshStatus();
    _statusRefreshInFlight = refresh;
    unawaited(
      refresh.then<void>(
        (_) => _clearStatusRefresh(refresh),
        onError: (Object _, StackTrace __) => _clearStatusRefresh(refresh),
      ),
    );
    return refresh;
  }

  Future<void> _refreshStatus() async {
    final tokenResult = await _secureTokenStore.getTokens();
    final tokens = tokenResult.ok ? tokenResult.value : null;
    if (tokens == null || isLocalNumericAuthTokens(tokens)) return;
    final read = await _readUserStatusWithRefresh('foreground', tokens);
    final statusResult = read.result;
    if (read.refreshDisposition == AccessTokenRefreshDisposition.rejected) {
      return;
    }
    if (statusResult?.ok == true) {
      final timeZoneError = await _synchronizeUserTimeZone(
        status: statusResult!.value!,
        accessToken: read.tokens.accessToken,
      );
      if (timeZoneError == null) {
        _sessionStore.refreshUserStatus(
          status: statusResult.value!,
          updatedAt: _currentTime(),
        );
        _lastSuccessfulStatusRefreshAt = _currentTime();
        _lastSuccessfulStatusRefreshUserId = statusResult.value!.user.userId;
      }
      return;
    }
    if (statusResult?.error?.code == 'WORKSPACE_NOT_READY') {
      _sessionStore.requireWorkspaceRecovery(updatedAt: _currentTime());
      return;
    }
    if (statusResult != null &&
        read.refreshDisposition != AccessTokenRefreshDisposition.unavailable &&
        (read.refreshDisposition == AccessTokenRefreshDisposition.refreshed
            ? _isAccessTokenRejection(statusResult)
            : _isTerminalAuthFailure(statusResult))) {
      await _restoreAnonymousAfterRejectedSession(updatedAt: _currentTime());
    }
  }

  void _clearStatusRefresh(Future<void> refresh) {
    if (identical(_statusRefreshInFlight, refresh)) {
      _statusRefreshInFlight = null;
    }
  }

  Future<void> _restoreInner() async {
    final restoredAt = _currentTime();
    final tokenResult = await _secureTokenStore.getTokens();
    if (!tokenResult.ok) {
      _setState(
        AppBootstrapState.failed(_safeErrorCode(tokenResult.error!.code)),
      );
      return;
    }
    final tokens = tokenResult.value;
    if (tokens == null) {
      _sessionStore.restoreAnonymous(restoredAt: restoredAt);
      _setState(const AppBootstrapState.ready());
      return;
    }
    if (isLocalNumericAuthTokens(tokens)) {
      final cleared = await _secureTokenStore.clearTokens(
        SecureTokenClearReason.logout,
      );
      if (!cleared.ok) {
        _setState(
          AppBootstrapState.failed(_safeErrorCode(cleared.error!.code)),
        );
        return;
      }
      _sessionStore.restoreAnonymous(restoredAt: restoredAt);
      _setState(const AppBootstrapState.ready());
      return;
    }

    final read = await _readUserStatusWithRefresh('status', tokens);
    final statusResult = read.result;
    if (read.refreshDisposition == AccessTokenRefreshDisposition.rejected) {
      _setState(const AppBootstrapState.ready());
      return;
    }
    if (statusResult == null) {
      _setState(const AppBootstrapState.failed('SESSION_RESTORE_FAILED'));
      return;
    }
    if (statusResult.ok) {
      await _restoreAuthenticatedStatus(
        status: statusResult.value!,
        accessToken: read.tokens.accessToken,
        restoredAt: restoredAt,
      );
      return;
    }
    if (statusResult.error?.code == 'WORKSPACE_NOT_READY') {
      final hintResult = await _secureTokenStore.getRecoveryHint();
      final hint = hintResult.ok ? hintResult.value : null;
      if (hint != null &&
          _sessionStore.restoreWorkspaceRecovery(
            hint: hint,
            restoredAt: restoredAt,
          )) {
        _setState(const AppBootstrapState.ready());
        return;
      }
    }
    if (read.refreshDisposition != AccessTokenRefreshDisposition.unavailable &&
        (read.refreshDisposition == AccessTokenRefreshDisposition.refreshed
            ? _isAccessTokenRejection(statusResult)
            : _isTerminalAuthFailure(statusResult))) {
      await _restoreAnonymousAfterRejectedSession(updatedAt: restoredAt);
      return;
    }
    _setState(
      AppBootstrapState.failed(
        _safeErrorCode(statusResult.error?.code ?? 'SESSION_RESTORE_FAILED'),
      ),
    );
  }

  Future<AuthApiResult<SessionUserStatus>?> _readUserStatus(
    String suffix, {
    required String accessToken,
  }) async {
    try {
      return await _authApi.getUserStatus(
        accessToken: accessToken,
        correlationId: _correlationId('session-restore-$suffix'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<
    ({
      AuthTokens tokens,
      AuthApiResult<SessionUserStatus>? result,
      AccessTokenRefreshDisposition? refreshDisposition,
    })
  >
  _readUserStatusWithRefresh(String suffix, AuthTokens tokens) async {
    final initial = await _readUserStatus(
      suffix,
      accessToken: tokens.accessToken,
    );
    final refresh = _sessionRefresh;
    if (initial == null ||
        refresh == null ||
        !_isAccessTokenRejection(initial) ||
        initial.error == null) {
      return (tokens: tokens, result: initial, refreshDisposition: null);
    }
    final disposition = await refresh.refresh(
      rejectedAccessToken: tokens.accessToken,
      failure: initial.error!,
    );
    if (disposition != AccessTokenRefreshDisposition.refreshed) {
      return (tokens: tokens, result: initial, refreshDisposition: disposition);
    }
    final tokenResult = await _secureTokenStore.getTokens();
    final refreshedTokens = tokenResult.ok ? tokenResult.value : null;
    if (refreshedTokens == null || isLocalNumericAuthTokens(refreshedTokens)) {
      return (
        tokens: tokens,
        result: null,
        refreshDisposition: AccessTokenRefreshDisposition.unavailable,
      );
    }
    return (
      tokens: refreshedTokens,
      result: await _readUserStatus(
        '$suffix-refreshed',
        accessToken: refreshedTokens.accessToken,
      ),
      refreshDisposition: disposition,
    );
  }

  Future<void> _restoreAnonymousAfterRejectedSession({
    required DateTime updatedAt,
  }) async {
    final cleared = await _secureTokenStore.clearTokens(
      SecureTokenClearReason.unauthorized,
    );
    if (!cleared.ok) {
      _setState(AppBootstrapState.failed(_safeErrorCode(cleared.error!.code)));
      return;
    }
    _sessionStore.restoreAnonymous(restoredAt: updatedAt);
    _setState(const AppBootstrapState.ready());
  }

  Future<void> _restoreAuthenticatedStatus({
    required SessionUserStatus status,
    required String accessToken,
    required DateTime restoredAt,
  }) async {
    final timeZoneError = await _synchronizeUserTimeZone(
      status: status,
      accessToken: accessToken,
    );
    if (timeZoneError != null) {
      _setState(AppBootstrapState.failed(timeZoneError));
      return;
    }
    _sessionStore.restoreFromUserStatus(status: status, restoredAt: restoredAt);
    _setState(const AppBootstrapState.ready());
  }

  Future<String?> _synchronizeUserTimeZone({
    required SessionUserStatus status,
    required String accessToken,
  }) async {
    final desiredTimeZone = userTimeZone;
    if (status.timeZone == desiredTimeZone) return null;
    if (userTimeZoneIsFallback && status.timeZone != null) return null;
    final api = _userTimeZoneApi;
    if (api == null) return null;
    try {
      final result = await api.updateUserTimeZone(
        timeZone: desiredTimeZone,
        accessToken: accessToken,
        correlationId: _correlationId('session-restore-timezone'),
        idempotency: IdempotencyRequestContext(
          operation: 'update-me-timezone',
          businessEntityId: status.user.userId,
          scene: 'session-restore',
        ),
      );
      if (!result.ok) {
        return _safeErrorCode(
          result.error?.code ?? 'USER_TIMEZONE_UNAVAILABLE',
        );
      }
      if (result.value?.timeZone != desiredTimeZone) {
        return 'USER_TIMEZONE_UNAVAILABLE';
      }
      return null;
    } catch (_) {
      return 'USER_TIMEZONE_UNAVAILABLE';
    }
  }

  DateTime _currentTime() => (_now ?? DateTime.now)().toUtc();

  String _correlationId(String scene) {
    return _correlationIdFactory?.call() ??
        '$scene-${_currentTime().millisecondsSinceEpoch}';
  }

  void _setState(AppBootstrapState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String _safeErrorCode(String code) {
  return RegExp(r'^[A-Z0-9_]{2,64}$').hasMatch(code)
      ? code
      : 'SESSION_RESTORE_FAILED';
}

bool _isTerminalAuthFailure(AuthApiResult<SessionUserStatus> result) {
  // Only a public, explicit main-session expiry may clear secure credentials.
  // A bare 401 or generic UNAUTHORIZED can originate from a proxy, a stale
  // secondary authority, or a transient compatibility issue.
  return const <String>{
    'AUTH_SESSION_EXPIRED',
    'TOKEN_EXPIRED',
  }.contains(result.error?.code.trim());
}

bool _isAccessTokenRejection<T>(AuthApiResult<T> result) =>
    result.status == 401 ||
    const <String>{
      'AUTH_SESSION_EXPIRED',
      'TOKEN_EXPIRED',
      'UNAUTHORIZED',
      'AUTH_UNAUTHORIZED',
    }.contains(result.error?.code.trim());

bool _isRejectedRefresh(AuthApiResult<RefreshTokenResponse> result) =>
    result.status == 401 ||
    const <String>{
      'AUTH_SESSION_EXPIRED',
      'TOKEN_EXPIRED',
      'UNAUTHORIZED',
      'AUTH_UNAUTHORIZED',
      'ACCOUNT_BLOCKED',
    }.contains(result.error?.code.trim());
