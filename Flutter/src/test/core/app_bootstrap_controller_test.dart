import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_bootstrap_controller.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/auth/data/auth_api.dart';

void main() {
  group('AppBootstrapController', () {
    test(
      'historical local numeric marker is cleared into phone login',
      () async {
        final fixture = _fixture(
          initialCredential: _credential(
            localNumericAuthTokens.accessToken,
            localNumericAuthTokens.refreshToken,
          ),
        );

        await fixture.controller.restore();

        expect(fixture.controller.state.status, AppBootstrapStatus.ready);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.anonymous,
        );
        expect(fixture.sessionStore.state.user, isNull);
        expect(fixture.driver.readCalls, 1);
        expect(fixture.driver.credential, isNull);
        expect(fixture.authApi.statusCalls, 0);
        expect(fixture.authApi.refreshCalls, 0);
      },
    );

    test('failed restore can reset stored session to phone login', () async {
      final fixture = _fixture(
        initialCredential: _credential('access-token', 'refresh-token'),
      );
      fixture.controller.markRestoreFailed('SESSION_RESTORE_FAILED');

      await fixture.controller.resetToLogin();

      expect(fixture.controller.state.status, AppBootstrapStatus.ready);
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
      expect(fixture.driver.credential, isNull);
    });

    test('phone-login reset escapes a failed token clear', () async {
      final fixture = _fixture(
        initialCredential: _credential('access-token', 'refresh-token'),
        clearTokens: false,
      );
      fixture.controller.markRestoreFailed('SESSION_RESTORE_FAILED');

      await fixture.controller.resetToLogin();

      expect(fixture.controller.state.status, AppBootstrapStatus.ready);
      expect(fixture.driver.credential, isNotNull);
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
    });

    test('no stored token becomes anonymous ready session', () async {
      final fixture = _fixture();

      await fixture.controller.restore();

      expect(fixture.controller.state.status, AppBootstrapStatus.ready);
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
      expect(fixture.authApi.statusCalls, 0);
    });

    test(
      'secure token read failure preserves a retryable restore state',
      () async {
        final fixture = _fixture(
          initialCredential: _credential('access', 'refresh'),
          throwOnTokenRead: true,
        );

        await fixture.controller.restore();

        expect(fixture.controller.state.status, AppBootstrapStatus.failed);
        expect(fixture.controller.state.errorCode, 'SECURE_TOKEN_READ_FAILED');
        expect(fixture.driver.credential, isNotNull);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.anonymous,
        );
        expect(fixture.authApi.statusCalls, 0);
      },
    );

    test('restore re-entry is ignored while restoring', () async {
      final tokenRead = Completer<SecureTokenCredential?>();
      final fixture = _fixture(tokenRead: tokenRead);

      final pending = fixture.controller.restore();
      expect(fixture.controller.state.status, AppBootstrapStatus.restoring);

      await fixture.controller.restore();
      expect(fixture.driver.readCalls, 1);
      expect(fixture.controller.state.status, AppBootstrapStatus.restoring);

      tokenRead.complete(null);
      await pending;

      expect(fixture.driver.readCalls, 1);
      expect(fixture.controller.state.status, AppBootstrapStatus.ready);
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
    });

    test('restore timeout fails instead of staying on splash', () async {
      final tokenRead = Completer<SecureTokenCredential?>();
      final fixture = _fixture(
        tokenRead: tokenRead,
        restoreTimeout: const Duration(milliseconds: 1),
      );

      await fixture.controller.restore();

      expect(fixture.controller.state.status, AppBootstrapStatus.failed);
      expect(fixture.controller.state.errorCode, 'SESSION_RESTORE_TIMEOUT');
      expect(fixture.driver.readCalls, 1);
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
    });

    test('watchdog timeout can fail idle restore state', () {
      final fixture = _fixture();

      fixture.controller.markRestoreTimedOut();

      expect(fixture.controller.state.status, AppBootstrapStatus.failed);
      expect(fixture.controller.state.errorCode, 'SESSION_RESTORE_TIMEOUT');
      expect(fixture.driver.readCalls, 0);
    });

    test('splash trigger failure can publish safe failed state', () {
      final fixture = _fixture();

      fixture.controller.markRestoreFailed('SESSION_RESTORE_TRIGGER_FAILED');

      expect(fixture.controller.state.status, AppBootstrapStatus.failed);
      expect(
        fixture.controller.state.errorCode,
        'SESSION_RESTORE_TRIGGER_FAILED',
      );
      expect(fixture.driver.readCalls, 0);
    });

    test('stored token calls me status before entering V3 route', () async {
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
      );

      await fixture.controller.restore();

      expect(fixture.authApi.statusCalls, 1);
      expect(
        fixture.sessionStore.state.authState,
        SessionAuthState.authenticated,
      );
      expect(fixture.sessionStore.selectRoute().type, SessionRouteType.v3);
      expect(fixture.authApi.statusAccessTokens, <String?>['access']);
    });

    test(
      'cold workspace-not-ready restores the secured recovery route',
      () async {
        final fixture = _fixture(
          initialCredential: _recoveryCredential(),
          statusResults: <AuthApiResult<SessionUserStatus>>[
            AuthApiResult<SessionUserStatus>.failure(
              error: const AppFailure(
                code: 'WORKSPACE_NOT_READY',
                category: AppFailureCategory.api,
                message: 'workspace is not ready',
                userMessageKey: 'workspace.notReady',
                isRetryable: true,
              ),
              status: 409,
            ),
          ],
        );

        await fixture.controller.restore();

        expect(fixture.controller.state.status, AppBootstrapStatus.ready);
        expect(fixture.driver.credential, isNotNull);
        expect(
          fixture.sessionStore.selectRoute().type,
          SessionRouteType.workspaceRetry,
        );
      },
    );

    test(
      'foreground refresh updates positioning and routes workspace recovery',
      () async {
        final fixture = _fixture(
          initialCredential: _credential('access', 'refresh'),
          statusResults: <AuthApiResult<SessionUserStatus>>[
            AuthApiResult<SessionUserStatus>.success(
              value: _status(),
              status: 200,
            ),
            AuthApiResult<SessionUserStatus>.failure(
              error: const AppFailure(
                code: 'WORKSPACE_NOT_READY',
                category: AppFailureCategory.api,
                message: 'workspace is not ready',
                userMessageKey: 'workspace.notReady',
                isRetryable: true,
              ),
              status: 409,
            ),
          ],
        );

        await fixture.controller.restore();
        await fixture.controller.refreshStatus();

        expect(fixture.authApi.statusCalls, 2);
        expect(fixture.driver.credential, isNotNull);
        expect(
          fixture.sessionStore.selectRoute().type,
          SessionRouteType.workspaceRetry,
        );
      },
    );

    test('concurrent foreground refreshes share one status read', () async {
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        statusResults: <AuthApiResult<SessionUserStatus>>[
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
        ],
      );
      await fixture.controller.restore();
      final gate = Completer<void>();
      fixture.authApi.statusGate = gate;

      final first = fixture.controller.refreshStatus();
      final second = fixture.controller.refreshStatus();
      await Future<void>.delayed(Duration.zero);

      expect(fixture.authApi.statusCalls, 2);
      gate.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(fixture.authApi.statusCalls, 2);
    });

    test('fresh ready status suppresses an immediate repeat', () async {
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        statusResults: <AuthApiResult<SessionUserStatus>>[
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
        ],
      );

      await fixture.controller.restore();
      await fixture.controller.refreshStatus();
      await fixture.controller.refreshStatus();

      expect(fixture.authApi.statusCalls, 2);
    });

    test('workspace recovery status is not freshness cached', () async {
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        statusResults: <AuthApiResult<SessionUserStatus>>[
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
          AuthApiResult<SessionUserStatus>.failure(
            error: const AppFailure(
              code: 'WORKSPACE_NOT_READY',
              category: AppFailureCategory.api,
              message: 'workspace is not ready',
              userMessageKey: 'workspace.notReady',
              isRetryable: true,
            ),
            status: 409,
          ),
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
        ],
      );

      await fixture.controller.restore();
      await fixture.controller.refreshStatus();
      await fixture.controller.refreshStatus();

      expect(fixture.authApi.statusCalls, 3);
    });

    test('missing server time zone is repaired before entering V3', () async {
      final timeZoneApi = _FakeUserTimeZoneApi();
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        userTimeZone: 'Asia/Shanghai',
        userTimeZoneApi: timeZoneApi,
        statusResults: <AuthApiResult<SessionUserStatus>>[
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
        ],
      );

      await fixture.controller.restore();

      expect(timeZoneApi.timeZones, <String>['Asia/Shanghai']);
      expect(timeZoneApi.accessTokens, <String>['access']);
      expect(timeZoneApi.idempotency.single?.operation, 'update-me-timezone');
      expect(timeZoneApi.idempotency.single?.businessEntityId, 'user-1');
      expect(timeZoneApi.idempotency.single?.scene, 'session-restore');
      expect(
        fixture.sessionStore.state.authState,
        SessionAuthState.authenticated,
      );
      expect(fixture.sessionStore.selectRoute().type, SessionRouteType.v3);
    });

    test('matching server time zone skips the repair mutation', () async {
      final timeZoneApi = _FakeUserTimeZoneApi();
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        userTimeZone: 'Asia/Shanghai',
        userTimeZoneApi: timeZoneApi,
        statusResults: <AuthApiResult<SessionUserStatus>>[
          AuthApiResult<SessionUserStatus>.success(
            value: _status(timeZone: 'Asia/Shanghai'),
            status: 200,
          ),
        ],
      );

      await fixture.controller.restore();

      expect(timeZoneApi.timeZones, isEmpty);
      expect(
        fixture.sessionStore.state.authState,
        SessionAuthState.authenticated,
      );
    });

    test(
      'fallback client zone does not overwrite a known server zone',
      () async {
        final timeZoneApi = _FakeUserTimeZoneApi();
        final fixture = _fixture(
          initialCredential: _credential('access', 'refresh'),
          userTimeZone: 'UTC',
          userTimeZoneIsFallback: true,
          userTimeZoneApi: timeZoneApi,
          statusResults: <AuthApiResult<SessionUserStatus>>[
            AuthApiResult<SessionUserStatus>.success(
              value: _status(timeZone: 'Asia/Shanghai'),
              status: 200,
            ),
          ],
        );

        await fixture.controller.restore();

        expect(timeZoneApi.timeZones, isEmpty);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.authenticated,
        );
      },
    );

    test('time zone repair failure blocks entry into V3', () async {
      final timeZoneApi = _FakeUserTimeZoneApi(
        result: AuthApiResult<UpdateUserTimeZoneResponse>.failure(
          error: const AppFailure(
            code: 'USER_TIMEZONE_UPDATE_FAILED',
            category: AppFailureCategory.auth,
            message: 'time zone update failed',
            userMessageKey: 'auth.timeZone.updateFailed',
          ),
          status: 503,
        ),
      );
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        userTimeZone: 'Asia/Shanghai',
        userTimeZoneApi: timeZoneApi,
      );

      await fixture.controller.restore();

      expect(fixture.controller.state.status, AppBootstrapStatus.failed);
      expect(fixture.controller.state.errorCode, 'USER_TIMEZONE_UPDATE_FAILED');
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
      expect(fixture.sessionStore.selectRoute().type, SessionRouteType.auth);
    });

    test(
      'status 401 clears stale credentials and returns to phone login',
      () async {
        final fixture = _fixture(
          initialCredential: _credential('old-access', 'old-refresh'),
          statusResults: <AuthApiResult<SessionUserStatus>>[
            AuthApiResult<SessionUserStatus>.failure(
              error: const AppFailure(
                code: 'AUTH_SESSION_EXPIRED',
                category: AppFailureCategory.auth,
                message: 'expired',
                userMessageKey: 'auth.expired',
              ),
              authExpired: true,
              status: 401,
            ),
          ],
        );

        await fixture.controller.restore();

        expect(fixture.controller.state.status, AppBootstrapStatus.ready);
        expect(fixture.controller.state.errorCode, isNull);
        expect(fixture.authApi.statusCalls, 1);
        expect(fixture.authApi.refreshCalls, 1);
        expect(fixture.driver.credential, isNull);
        expect(fixture.sessionStore.state.authState, SessionAuthState.expired);
        expect(fixture.sessionStore.selectRoute().type, SessionRouteType.auth);
      },
    );

    test(
      'generic unauthorized keeps credentials and remains retryable',
      () async {
        final fixture = _fixture(
          initialCredential: _credential('old-access', 'old-refresh'),
          refreshResult: AuthApiResult<RefreshTokenResponse>.failure(
            error: const AppFailure(
              code: 'AUTH_UPSTREAM_UNAVAILABLE',
              category: AppFailureCategory.network,
              message: 'refresh unavailable',
              userMessageKey: 'auth.restore.unavailable',
              isRetryable: true,
            ),
            status: 503,
          ),
          statusResults: <AuthApiResult<SessionUserStatus>>[
            AuthApiResult<SessionUserStatus>.failure(
              error: const AppFailure(
                code: 'UNAUTHORIZED',
                category: AppFailureCategory.auth,
                message: 'rejected',
                userMessageKey: 'auth.expired',
              ),
              status: 401,
            ),
          ],
        );

        await fixture.controller.restore();

        expect(fixture.controller.state.status, AppBootstrapStatus.failed);
        expect(fixture.controller.state.errorCode, 'UNAUTHORIZED');
        expect(fixture.authApi.refreshCalls, 1);
        expect(fixture.driver.credential, isNotNull);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.anonymous,
        );
      },
    );

    test('foreground unauthorized clears the active stale session', () async {
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        statusResults: <AuthApiResult<SessionUserStatus>>[
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
          AuthApiResult<SessionUserStatus>.failure(
            error: const AppFailure(
              code: 'TOKEN_EXPIRED',
              category: AppFailureCategory.auth,
              message: 'expired',
              userMessageKey: 'auth.expired',
            ),
            authExpired: true,
            status: 401,
          ),
        ],
      );

      await fixture.controller.restore();
      await fixture.controller.refreshStatus();

      expect(fixture.controller.state.status, AppBootstrapStatus.ready);
      expect(fixture.driver.credential, isNull);
      expect(fixture.authApi.refreshCalls, 1);
      expect(fixture.sessionStore.state.authState, SessionAuthState.expired);
    });

    test('cold restore rotates an expired token and retries status', () async {
      final fixture = _fixture(
        initialCredential: _recoveryCredential(),
        statusResults: <AuthApiResult<SessionUserStatus>>[
          _unauthorizedStatus(),
          AuthApiResult<SessionUserStatus>.success(
            value: _status(),
            status: 200,
          ),
        ],
        refreshResult: _successfulRefresh(),
      );

      await fixture.controller.restore();

      expect(fixture.controller.state.status, AppBootstrapStatus.ready);
      expect(fixture.authApi.refreshCalls, 1);
      expect(fixture.authApi.statusAccessTokens, <String?>[
        'access',
        'rotated-access',
      ]);
      expect(
        fixture.sessionStore.state.authState,
        SessionAuthState.authenticated,
      );
      final storedTokens = await fixture.tokenStore.getTokens();
      expect(storedTokens.value?.accessToken, 'rotated-access');
      expect(storedTokens.value?.refreshToken, 'rotated-refresh');
      final storedHint = await fixture.tokenStore.getRecoveryHint();
      expect(storedHint.value?.userId, 'user-1');
    });

    test(
      'foreground status refresh rotates the token without logout',
      () async {
        final fixture = _fixture(
          initialCredential: _credential('access', 'refresh'),
          statusResults: <AuthApiResult<SessionUserStatus>>[
            AuthApiResult<SessionUserStatus>.success(
              value: _status(),
              status: 200,
            ),
            _unauthorizedStatus(),
            AuthApiResult<SessionUserStatus>.success(
              value: _status(),
              status: 200,
            ),
          ],
          refreshResult: _successfulRefresh(),
        );

        await fixture.controller.restore();
        await fixture.controller.refreshStatus();

        expect(fixture.authApi.refreshCalls, 1);
        expect(fixture.authApi.statusAccessTokens, <String?>[
          'access',
          'access',
          'rotated-access',
        ]);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.authenticated,
        );
      },
    );

    test('concurrent token rejections share one refresh request', () async {
      final pendingRefresh = Completer<AuthApiResult<RefreshTokenResponse>>();
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        refreshFuture: pendingRefresh.future,
      );
      const failure = AppFailure(
        code: 'UNAUTHORIZED',
        category: AppFailureCategory.auth,
        message: 'expired',
        userMessageKey: 'auth.expired',
      );

      final first = fixture.sessionRefresh.refresh(
        rejectedAccessToken: 'access',
        failure: failure,
      );
      final second = fixture.sessionRefresh.refresh(
        rejectedAccessToken: 'access',
        failure: failure,
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.authApi.refreshCalls, 1);
      pendingRefresh.complete(_successfulRefresh());

      expect(
        await Future.wait(<Future<AccessTokenRefreshDisposition>>[
          first,
          second,
        ]),
        everyElement(AccessTokenRefreshDisposition.refreshed),
      );
      expect(fixture.authApi.refreshCalls, 1);
    });

    test('late refresh cannot restore credentials after logout', () async {
      final pendingRefresh = Completer<AuthApiResult<RefreshTokenResponse>>();
      final fixture = _fixture(
        initialCredential: _credential('access', 'refresh'),
        refreshFuture: pendingRefresh.future,
      );
      const failure = AppFailure(
        code: 'UNAUTHORIZED',
        category: AppFailureCategory.auth,
        message: 'expired',
        userMessageKey: 'auth.expired',
      );

      final refresh = fixture.sessionRefresh.refresh(
        rejectedAccessToken: 'access',
        failure: failure,
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.authApi.refreshCalls, 1);
      final cleared = await fixture.tokenStore.clearTokens(
        SecureTokenClearReason.logout,
      );
      expect(cleared.ok, isTrue);
      pendingRefresh.complete(_successfulRefresh());

      expect(await refresh, AccessTokenRefreshDisposition.unavailable);
      expect(fixture.driver.credential, isNull);
    });

    test(
      'non-expiry auth status failure keeps token and fails restore',
      () async {
        final fixture = _fixture(
          initialCredential: _credential('access', 'refresh'),
          statusResults: <AuthApiResult<SessionUserStatus>>[
            AuthApiResult<SessionUserStatus>.failure(
              error: const AppFailure(
                code: 'AUTH_UPSTREAM_UNAVAILABLE',
                category: AppFailureCategory.auth,
                message: 'upstream unavailable',
                userMessageKey: 'auth.restore.unavailable',
                isRetryable: true,
              ),
              status: 503,
            ),
          ],
        );

        await fixture.controller.restore();

        expect(fixture.controller.state.status, AppBootstrapStatus.failed);
        expect(fixture.controller.state.errorCode, 'AUTH_UPSTREAM_UNAVAILABLE');
        expect(fixture.authApi.refreshCalls, 0);
        expect(fixture.driver.credential, isNotNull);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.anonymous,
        );
      },
    );
  });
}

({
  AppBootstrapController controller,
  SessionStore sessionStore,
  _FakeAuthApi authApi,
  _FakeSecureTokenDriver driver,
  SecureTokenStore tokenStore,
  AuthSessionRefreshCoordinator sessionRefresh,
})
_fixture({
  SecureTokenCredential? initialCredential,
  bool writeTokens = true,
  bool clearTokens = true,
  bool throwOnTokenRead = false,
  Completer<SecureTokenCredential?>? tokenRead,
  List<AuthApiResult<SessionUserStatus>>? statusResults,
  AuthApiResult<RefreshTokenResponse>? refreshResult,
  Future<AuthApiResult<RefreshTokenResponse>>? refreshFuture,
  Duration restoreTimeout = const Duration(seconds: 12),
  String userTimeZone = 'UTC',
  bool userTimeZoneIsFallback = false,
  UserTimeZoneApiPort? userTimeZoneApi,
  DateTime Function()? now,
  Duration statusRefreshFreshness = const Duration(seconds: 30),
}) {
  final driver = _FakeSecureTokenDriver(
    credential: initialCredential,
    writeTokens: writeTokens,
    clearTokens: clearTokens,
    throwOnRead: throwOnTokenRead,
    tokenRead: tokenRead,
  );
  final tokenStore = SecureTokenStore(driver: driver);
  final sessionStore = SessionStore(secureTokenStore: tokenStore);
  final authApi = _FakeAuthApi(
    statusResults: statusResults,
    refreshResult: refreshResult,
    refreshFuture: refreshFuture,
  );
  final clock = now ?? () => DateTime.utc(2026, 1, 1);
  final sessionRefresh = AuthSessionRefreshCoordinator(
    secureTokenStore: tokenStore,
    sessionStore: sessionStore,
    authApi: authApi,
    now: clock,
    correlationIdFactory: () => 'trace-refresh',
  );
  final controller = AppBootstrapController(
    secureTokenStore: tokenStore,
    sessionStore: sessionStore,
    authApi: authApi,
    sessionRefresh: sessionRefresh,
    userTimeZone: userTimeZone,
    userTimeZoneIsFallback: userTimeZoneIsFallback,
    userTimeZoneApi: userTimeZoneApi,
    now: clock,
    correlationIdFactory: () => 'trace-bootstrap',
    restoreTimeout: restoreTimeout,
    statusRefreshFreshness: statusRefreshFreshness,
  );
  return (
    controller: controller,
    sessionStore: sessionStore,
    authApi: authApi,
    driver: driver,
    tokenStore: tokenStore,
    sessionRefresh: sessionRefresh,
  );
}

SecureTokenCredential _credential(String accessToken, String refreshToken) {
  return SecureTokenCredential(
    username: 'session',
    password: '{"accessToken":"$accessToken","refreshToken":"$refreshToken"}',
  );
}

SecureTokenCredential _recoveryCredential() {
  return const SecureTokenCredential(
    username: 'session',
    password:
        '{"accessToken":"access","refreshToken":"refresh","recoveryHint":{"userId":"user-1","maskedPhoneNumber":"138****8000","workspaceStatus":"sync_failed","onboardingRequired":false,"basicPositioningCompleted":false,"positioningStatus":"in_progress","coldStartPercent":65}}',
  );
}

SessionUserStatus _status({String? timeZone}) {
  return SessionUserStatus(
    user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
    workspace: const SessionWorkspace(status: SessionWorkspaceStatus.ready),
    runningTaskCount: 0,
    timeZone: timeZone,
  );
}

AuthApiResult<SessionUserStatus> _unauthorizedStatus() {
  return AuthApiResult<SessionUserStatus>.failure(
    error: const AppFailure(
      code: 'UNAUTHORIZED',
      category: AppFailureCategory.auth,
      message: 'expired',
      userMessageKey: 'auth.expired',
    ),
    status: 401,
  );
}

AuthApiResult<RefreshTokenResponse> _successfulRefresh() {
  return AuthApiResult<RefreshTokenResponse>.success(
    value: const RefreshTokenResponse(
      tokens: AuthTokens(
        accessToken: 'rotated-access',
        refreshToken: 'rotated-refresh',
      ),
      expiresIn: 7200,
      rotated: true,
    ),
    status: 200,
  );
}

final class _FakeUserTimeZoneApi implements UserTimeZoneApiPort {
  _FakeUserTimeZoneApi({this.result});

  final AuthApiResult<UpdateUserTimeZoneResponse>? result;
  final timeZones = <String>[];
  final accessTokens = <String>[];
  final idempotency = <IdempotencyRequestContext?>[];

  @override
  Future<AuthApiResult<UpdateUserTimeZoneResponse>> updateUserTimeZone({
    required String timeZone,
    required String accessToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    timeZones.add(timeZone);
    accessTokens.add(accessToken);
    this.idempotency.add(idempotency);
    return result ??
        AuthApiResult<UpdateUserTimeZoneResponse>.success(
          value: UpdateUserTimeZoneResponse(timeZone: timeZone),
          status: 200,
        );
  }
}

final class _FakeAuthApi implements AuthApiPort {
  _FakeAuthApi({
    List<AuthApiResult<SessionUserStatus>>? statusResults,
    AuthApiResult<RefreshTokenResponse>? refreshResult,
    Future<AuthApiResult<RefreshTokenResponse>>? refreshFuture,
  }) : _statusResults = List<AuthApiResult<SessionUserStatus>>.from(
         statusResults ??
             <AuthApiResult<SessionUserStatus>>[
               AuthApiResult<SessionUserStatus>.success(
                 value: _status(),
                 status: 200,
               ),
             ],
       ),
       _refreshResult = refreshResult,
       _refreshFuture = refreshFuture;

  final List<AuthApiResult<SessionUserStatus>> _statusResults;
  final AuthApiResult<RefreshTokenResponse>? _refreshResult;
  final Future<AuthApiResult<RefreshTokenResponse>>? _refreshFuture;
  final statusAccessTokens = <String?>[];
  final refreshIdempotency = <IdempotencyRequestContext?>[];
  var statusCalls = 0;
  var refreshCalls = 0;
  Completer<void>? statusGate;

  @override
  Future<AuthApiResult<SessionUserStatus>> getUserStatus({
    String? accessToken,
    String? correlationId,
  }) async {
    statusCalls += 1;
    statusAccessTokens.add(accessToken);
    final gate = statusGate;
    if (gate != null) await gate.future;
    return _statusResults.removeAt(0);
  }

  @override
  Future<AuthApiResult<RefreshTokenResponse>> refreshAuthToken({
    required String refreshToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    refreshCalls += 1;
    refreshIdempotency.add(idempotency);
    final pending = _refreshFuture;
    if (pending != null) return pending;
    return _refreshResult ??
        AuthApiResult<RefreshTokenResponse>.failure(
          error: const AppFailure(
            code: 'TOKEN_EXPIRED',
            category: AppFailureCategory.auth,
            message: 'expired',
            userMessageKey: 'auth.expired',
          ),
          authExpired: true,
          status: 401,
        );
  }

  @override
  Future<AuthApiResult<SmsLoginResponse>> login({
    required SmsLoginRequest request,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    return AuthApiResult<SmsLoginResponse>.failure(
      error: const AppFailure(
        code: 'NOT_USED',
        category: AppFailureCategory.auth,
        message: 'not used',
        userMessageKey: 'not.used',
      ),
    );
  }

  @override
  Future<AuthApiResult<SendSmsCodeResponse>> sendSmsCode({
    required String phone,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    return AuthApiResult<SendSmsCodeResponse>.failure(
      error: const AppFailure(
        code: 'NOT_USED',
        category: AppFailureCategory.auth,
        message: 'not used',
        userMessageKey: 'not.used',
      ),
    );
  }
}

final class _FakeSecureTokenDriver implements SecureTokenDriver {
  _FakeSecureTokenDriver({
    this.credential,
    required this.writeTokens,
    required this.clearTokens,
    this.throwOnRead = false,
    this.tokenRead,
  });

  SecureTokenCredential? credential;
  final bool writeTokens;
  final bool clearTokens;
  final bool throwOnRead;
  final Completer<SecureTokenCredential?>? tokenRead;
  var readCalls = 0;

  @override
  Future<SecureTokenCredential?> read({required String service}) async {
    readCalls += 1;
    if (throwOnRead) throw StateError('secure token read failed');
    final pending = tokenRead;
    if (pending != null) {
      return await pending.future;
    }
    return credential;
  }

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) {
    if (writeTokens) {
      credential = SecureTokenCredential(
        username: username,
        password: password,
      );
    }
    return writeTokens;
  }

  @override
  bool clear({required String service}) {
    if (clearTokens) {
      credential = null;
    }
    return clearTokens;
  }
}
