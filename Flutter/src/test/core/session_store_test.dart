import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';

void main() {
  group('SessionStore', () {
    test('local numeric identity exposes the demo person nickname', () {
      final status = localNumericAuthUserStatus();

      expect(status.user.displayName, '老周不劝你');
      expect(status.user.userId, 'local-numeric-user');
      expect(status.workspace.workspaceId, 'local-numeric-workspace');
    });

    test('token write failure leaves route at auth', () async {
      final session = SessionStore(
        secureTokenStore: SecureTokenStore(
          driver: _FakeSecureTokenDriver(writeResult: false),
        ),
      );

      final result = await session.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'SECURE_TOKEN_WRITE_FAILED');
      expect(session.state.authState, SessionAuthState.anonymous);
      expect(session.selectRoute().type, SessionRouteType.auth);
    });

    test('workspace sync failure routes to workspace retry', () async {
      final session = _successfulSession();

      await session.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(workspaceStatus: SessionWorkspaceStatus.syncFailed),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      expect(session.selectRoute().type, SessionRouteType.workspaceRetry);
    });

    test(
      'workspace creation routes to workspace retry before onboarding',
      () async {
        final session = _successfulSession();

        await session.applyLoginSuccess(
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: _snapshot(
            workspaceStatus: SessionWorkspaceStatus.creating,
            onboardingRequired: true,
          ),
          updatedAt: DateTime.utc(2026, 1, 1),
        );

        expect(session.selectRoute().type, SessionRouteType.workspaceRetry);
      },
    );

    test('secure recovery hint restores only the workspace retry route', () {
      final session = _successfulSession();

      final restored = session.restoreWorkspaceRecovery(
        hint: const AuthSessionRecoveryHint(
          userId: 'user-1',
          maskedPhoneNumber: '138****8000',
          workspaceStatus: 'sync_failed',
          onboardingRequired: false,
          basicPositioningCompleted: false,
          positioningStatus: 'in_progress',
          coldStartPercent: 65,
        ),
        restoredAt: DateTime.utc(2026, 1, 1),
      );

      expect(restored, isTrue);
      expect(session.state.authState, SessionAuthState.authenticated);
      expect(session.selectRoute().type, SessionRouteType.workspaceRetry);
      expect(session.state.positioningProgress?.coldStartPercent, 65);
      expect(session.state.firstLoginThisSession, isFalse);
    });

    test(
      'first login enters onboarding while retaining the server fact',
      () async {
        final session = _successfulSession();

        await session.applyLoginSuccess(
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: _snapshot(onboardingRequired: true),
          firstLoginThisSession: true,
          updatedAt: DateTime.utc(2026, 1, 1),
        );

        expect(session.selectRoute().type, SessionRouteType.onboarding);
        expect(session.state.onboardingRequired, isTrue);
      },
    );

    test(
      'explicit basic positioning marker overrides legacy onboarding state',
      () async {
        final session = _successfulSession();
        await session.applyLoginSuccess(
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: _snapshot(
            onboardingRequired: false,
            basicPositioningCompleted: false,
            positioningStatus: SessionPositioningStatus.inProgress,
            positioningProgress: const SessionPositioningProgress(
              coldStartPercent: 65,
              completedPercent: 24,
            ),
          ),
          firstLoginThisSession: true,
          updatedAt: DateTime.utc(2026, 1, 1),
        );

        expect(session.state.requiresInitialPositioning, isTrue);
        expect(session.selectRoute().type, SessionRouteType.onboarding);
        expect(session.state.positioningProgress?.coldStartPercent, 65);
      },
    );

    test(
      'explicit server onboarding completion overrides stale positioning progress',
      () {
        final session = _successfulSession();
        session.restoreFromUserStatus(
          status: _statusWithWorkspace(
            onboardingRequired: false,
            basicPositioningCompleted: false,
            positioningStatus: SessionPositioningStatus.inProgress,
            includeDefaultContentLine: false,
          ),
          restoredAt: DateTime.utc(2026, 8, 16),
        );

        expect(session.state.onboardingDecisionIsAuthoritative, isTrue);
        expect(session.state.requiresInitialPositioning, isFalse);
        expect(session.selectRoute().type, SessionRouteType.v3);
      },
    );

    test(
      'workspace default positioning ID releases stale positioning progress',
      () {
        final session = _successfulSession();
        session.restoreFromUserStatus(
          status: _statusWithWorkspace(
            basicPositioningCompleted: false,
            positioningStatus: SessionPositioningStatus.inProgress,
            defaultContentLineId: 'positioning-1',
            includeDefaultContentLine: false,
          ),
          restoredAt: DateTime.utc(2026, 8, 16),
        );

        expect(session.state.onboardingDecisionIsAuthoritative, isFalse);
        expect(session.state.hasConfirmedInitialPositioning, isTrue);
        expect(session.state.requiresInitialPositioning, isFalse);
        expect(session.selectRoute().type, SessionRouteType.v3);
      },
    );

    test('verified attempt completion survives a stale status refresh', () {
      final session = _successfulSession();
      session.restoreFromUserStatus(
        status: _statusWithWorkspace(
          basicPositioningCompleted: false,
          positioningStatus: SessionPositioningStatus.inProgress,
          includeDefaultContentLine: false,
        ),
        restoredAt: DateTime.utc(2026, 8, 16),
      );

      expect(
        session.applyInitialPositioningAttemptCompletion(
          completedAt: DateTime.utc(2026, 8, 15),
        ),
        isTrue,
      );
      session.refreshUserStatus(
        status: _statusWithWorkspace(
          basicPositioningCompleted: false,
          positioningStatus: SessionPositioningStatus.inProgress,
          includeDefaultContentLine: false,
        ),
        updatedAt: DateTime.utc(2026, 8, 16, 1),
      );

      expect(session.state.requiresInitialPositioning, isFalse);
      expect(session.selectRoute().type, SessionRouteType.v3);
    });

    test('completed positioning never flashes stale onboarding on refresh', () {
      final session = _successfulSession();
      session.restoreFromUserStatus(
        status: _statusWithWorkspace(
          onboardingRequired: false,
          basicPositioningCompleted: true,
          positioningStatus: SessionPositioningStatus.completed,
          includeDefaultContentLine: false,
        ),
        restoredAt: DateTime.utc(2026, 8, 25),
      );

      session.refreshUserStatus(
        status: _statusWithWorkspace(
          onboardingRequired: true,
          basicPositioningCompleted: false,
          positioningStatus: SessionPositioningStatus.inProgress,
          includeDefaultContentLine: false,
        ),
        updatedAt: DateTime.utc(2026, 8, 25, 1),
      );

      expect(session.state.onboardingRequired, isFalse);
      expect(session.state.basicPositioningCompleted, isTrue);
      expect(
        session.state.positioningStatus,
        SessionPositioningStatus.completed,
      );
      expect(session.selectRoute().type, SessionRouteType.v3);
    });

    test(
      'verified attempt completion requires an authenticated ready workspace',
      () async {
        final anonymous = _successfulSession();
        expect(
          anonymous.applyInitialPositioningAttemptCompletion(
            completedAt: DateTime.utc(2026, 8, 15),
          ),
          isFalse,
        );

        final syncing = _successfulSession();
        await syncing.applyLoginSuccess(
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: _snapshot(
            onboardingRequired: true,
            workspaceStatus: SessionWorkspaceStatus.syncFailed,
          ),
          updatedAt: DateTime.utc(2026, 8, 16),
        );
        expect(
          syncing.applyInitialPositioningAttemptCompletion(
            completedAt: DateTime.utc(2026, 8, 15),
          ),
          isFalse,
        );

        final ready = _successfulSession();
        ready.restoreFromUserStatus(
          status: _statusWithWorkspace(
            onboardingRequired: true,
            basicPositioningCompleted: false,
            positioningStatus: SessionPositioningStatus.inProgress,
          ),
          restoredAt: DateTime.utc(2026, 8, 16),
        );
        expect(
          ready.applyInitialPositioningAttemptCompletion(
            completedAt: DateTime.utc(2026, 8, 15),
          ),
          isTrue,
        );
        expect(ready.state.defaultContentLine?.contentLineId, 'line-1');
        expect(ready.state.requiresInitialPositioning, isFalse);
      },
    );

    test(
      'restored unfinished positioning remains a fact without replaying onboarding',
      () {
        final session = _successfulSession();
        session.restoreFromUserStatus(
          status: _statusWithWorkspace(
            onboardingRequired: true,
            basicPositioningCompleted: false,
            isPlaceholder: false,
          ),
          restoredAt: DateTime.utc(2026, 8, 11),
        );

        expect(session.state.hasConfirmedInitialPositioning, isTrue);
        expect(session.state.requiresInitialPositioning, isTrue);
        expect(session.state.requiresFirstLoginOnboarding, isFalse);
        expect(session.selectRoute().type, SessionRouteType.v3);
      },
    );

    test(
      'completed positioning status releases onboarding despite stale basic marker',
      () {
        final session = _successfulSession();
        session.restoreFromUserStatus(
          status: _statusWithWorkspace(
            onboardingRequired: true,
            basicPositioningCompleted: false,
            positioningStatus: SessionPositioningStatus.completed,
            isPlaceholder: true,
          ),
          restoredAt: DateTime.utc(2026, 8, 16),
        );

        expect(session.state.requiresInitialPositioning, isFalse);
        expect(session.selectRoute().type, SessionRouteType.v3);
      },
    );

    test(
      'confirmed onboarding completion sets the default content line',
      () async {
        final session = _successfulSession();
        await session.applyLoginSuccess(
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: _snapshot(onboardingRequired: true),
          updatedAt: DateTime.utc(2026, 1, 1),
        );

        final completed = session.completeOnboarding(
          defaultContentLine: const SessionContentLine(
            contentLineId: 'line-1',
            name: 'Retail voice',
          ),
          completedAt: DateTime.utc(2026, 1, 2),
        );

        expect(completed, isTrue);
        expect(session.state.onboardingRequired, isFalse);
        expect(session.state.defaultContentLine?.contentLineId, 'line-1');
        expect(session.selectRoute().type, SessionRouteType.v3);
      },
    );

    test(
      'restored status keeps positioning facts without replaying onboarding',
      () {
        final explicit = _successfulSession();
        explicit.restoreFromUserStatus(
          status: _statusWithWorkspace(onboardingRequired: true),
          restoredAt: DateTime.utc(2026, 1, 1),
        );
        expect(explicit.selectRoute().type, SessionRouteType.v3);
        expect(explicit.state.onboardingRequired, isTrue);
        expect(explicit.state.requiresFirstLoginOnboarding, isFalse);

        final placeholder = _successfulSession();
        placeholder.restoreFromUserStatus(
          status: _statusWithWorkspace(isPlaceholder: true),
          restoredAt: DateTime.utc(2026, 1, 1),
        );
        expect(placeholder.selectRoute().type, SessionRouteType.v3);
        expect(placeholder.state.onboardingRequired, isTrue);
        expect(placeholder.state.requiresFirstLoginOnboarding, isFalse);

        final overridden = _successfulSession();
        overridden.restoreFromUserStatus(
          status: _statusWithWorkspace(
            onboardingRequired: false,
            isPlaceholder: true,
          ),
          restoredAt: DateTime.utc(2026, 1, 1),
        );
        expect(overridden.selectRoute().type, SessionRouteType.v3);
      },
    );

    test(
      'partial user status preserves an existing onboarding requirement',
      () async {
        final session = _successfulSession();
        await session.applyLoginSuccess(
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: _snapshot(onboardingRequired: true),
          updatedAt: DateTime.utc(2026, 1, 1),
        );

        session.refreshUserStatus(
          status: _statusWithWorkspace(includeDefaultContentLine: false),
          updatedAt: DateTime.utc(2026, 1, 2),
        );

        expect(session.state.onboardingRequired, isTrue);
      },
    );

    test('onboarding completion cannot release an unrelated session', () async {
      final anonymous = _successfulSession();
      expect(
        anonymous.completeOnboarding(
          defaultContentLine: const SessionContentLine(
            contentLineId: 'line-1',
            name: 'Retail',
          ),
          completedAt: DateTime.utc(2026, 1, 1),
        ),
        isFalse,
      );

      final ready = _successfulSession();
      await ready.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(onboardingRequired: false),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      expect(
        ready.completeOnboarding(
          defaultContentLine: const SessionContentLine(
            contentLineId: 'line-1',
            name: 'Retail',
          ),
          completedAt: DateTime.utc(2026, 1, 1),
        ),
        isFalse,
      );

      final syncing = _successfulSession();
      await syncing.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(
          onboardingRequired: true,
          workspaceStatus: SessionWorkspaceStatus.syncFailed,
        ),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      expect(
        syncing.completeOnboarding(
          defaultContentLine: const SessionContentLine(
            contentLineId: 'line-1',
            name: 'Retail',
          ),
          completedAt: DateTime.utc(2026, 1, 1),
        ),
        isFalse,
      );
    });

    test('ready authenticated session routes to V3', () async {
      final session = _successfulSession();

      await session.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      expect(session.selectRoute().type, SessionRouteType.v3);
    });

    test(
      'first-login fact survives same-account refresh and clears on account change',
      () async {
        final fixture = _successfulFixture();
        await fixture.session.applyLoginSuccess(
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: _snapshot(onboardingRequired: true),
          firstLoginThisSession: true,
          updatedAt: DateTime.utc(2026, 1, 1),
        );

        expect(fixture.session.state.firstLoginThisSession, isTrue);
        expect(fixture.session.state.requiresFirstLoginOnboarding, isTrue);
        expect(
          fixture.driver.credential?.password,
          isNot(contains('firstLogin')),
        );

        fixture.session.refreshUserStatus(
          status: _statusWithWorkspace(
            onboardingRequired: true,
            includeDefaultContentLine: false,
          ),
          updatedAt: DateTime.utc(2026, 1, 2),
        );
        expect(fixture.session.state.firstLoginThisSession, isTrue);

        fixture.session.refreshUserStatus(
          status: _statusWithWorkspace(
            userId: 'user-2',
            onboardingRequired: true,
            includeDefaultContentLine: false,
          ),
          updatedAt: DateTime.utc(2026, 1, 3),
        );
        expect(fixture.session.state.firstLoginThisSession, isFalse);
        expect(fixture.session.state.requiresFirstLoginOnboarding, isFalse);
      },
    );

    test('restored and logged-out sessions never replay first login', () async {
      final session = _successfulSession();
      await session.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(onboardingRequired: true),
        firstLoginThisSession: true,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      expect(session.state.firstLoginThisSession, isTrue);

      session.restoreFromUserStatus(
        status: _statusWithWorkspace(
          onboardingRequired: true,
          includeDefaultContentLine: false,
        ),
        restoredAt: DateTime.utc(2026, 1, 2),
      );
      expect(session.state.firstLoginThisSession, isFalse);

      await session.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(),
        firstLoginThisSession: true,
        updatedAt: DateTime.utc(2026, 1, 3),
      );
      await session.logout(loggedOutAt: DateTime.utc(2026, 1, 4));
      expect(session.state.firstLoginThisSession, isFalse);
    });

    test('auth expiry notification retains the active session', () async {
      final fixture = _successfulFixture();
      await fixture.session.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      expect(fixture.driver.credential, isNotNull);

      await fixture.session.handleAuthExpired(
        error: const AppFailure(
          code: 'AUTH_SESSION_EXPIRED',
          category: AppFailureCategory.auth,
          message: 'expired',
          userMessageKey: 'auth.expired',
        ),
        occurredAt: DateTime.utc(2026, 1, 2),
      );

      expect(fixture.driver.credential, isNotNull);
      expect(fixture.session.state.authState, SessionAuthState.authenticated);
      expect(fixture.session.state.lastAuthErrorCode, 'AUTH_SESSION_EXPIRED');
      expect(fixture.session.selectRoute().type, SessionRouteType.v3);
    });

    test('runtime unauthorized retains tokens and current route', () async {
      final fixture = _successfulFixture();
      await fixture.session.applyLoginSuccess(
        tokens: const AuthTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
        ),
        snapshot: _snapshot(),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      await fixture.session.handleAuthExpired(
        error: const AppFailure(
          code: 'UNAUTHORIZED',
          category: AppFailureCategory.auth,
          message: 'unauthorized',
          userMessageKey: 'auth.unauthorized',
        ),
        occurredAt: DateTime.utc(2026, 1, 2),
      );

      expect(fixture.driver.credential, isNotNull);
      expect(fixture.session.state.authState, SessionAuthState.authenticated);
      expect(fixture.session.state.lastAuthErrorCode, 'AUTH_SESSION_EXPIRED');
      expect(fixture.session.selectRoute().type, SessionRouteType.v3);
    });

    test(
      'auth expiry notification does not try to clear secure tokens',
      () async {
        final fixture = _successfulFixture(clearResult: false);
        await fixture.session.applyLoginSuccess(
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: _snapshot(),
          updatedAt: DateTime.utc(2026, 1, 1),
        );

        expect(fixture.driver.credential, isNotNull);

        await fixture.session.handleAuthExpired(
          error: const AppFailure(
            code: 'AUTH_SESSION_EXPIRED',
            category: AppFailureCategory.auth,
            message: 'expired',
            userMessageKey: 'auth.expired',
          ),
          occurredAt: DateTime.utc(2026, 1, 2),
        );

        expect(fixture.driver.credential, isNotNull);
        expect(fixture.session.state.authState, SessionAuthState.authenticated);
        expect(fixture.session.state.lastAuthErrorCode, 'AUTH_SESSION_EXPIRED');
        expect(fixture.session.selectRoute().type, SessionRouteType.v3);
      },
    );

    test('copyWith preserves auth error unless explicitly cleared', () {
      final state = SessionState.anonymous().copyWith(
        authState: SessionAuthState.expired,
        lastAuthErrorCode: 'AUTH_SESSION_EXPIRED',
      );

      expect(
        state.copyWith(updatedAt: DateTime.utc(2026, 1, 1)).lastAuthErrorCode,
        'AUTH_SESSION_EXPIRED',
      );
      expect(state.copyWith(lastAuthErrorCode: null).lastAuthErrorCode, isNull);
    });
  });
}

SessionStore _successfulSession() {
  return _successfulFixture().session;
}

({SessionStore session, _FakeSecureTokenDriver driver}) _successfulFixture({
  bool clearResult = true,
}) {
  final driver = _FakeSecureTokenDriver(clearResult: clearResult);
  final session = SessionStore(
    secureTokenStore: SecureTokenStore(driver: driver),
  );
  return (session: session, driver: driver);
}

SafeAuthSessionSnapshot _snapshot({
  bool onboardingRequired = false,
  bool? basicPositioningCompleted,
  SessionPositioningStatus? positioningStatus,
  SessionPositioningProgress? positioningProgress,
  SessionWorkspaceStatus workspaceStatus = SessionWorkspaceStatus.ready,
}) {
  return SafeAuthSessionSnapshot(
    user: const SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
    expiresAt: DateTime.utc(2027, 1, 1),
    workspaceStatus: workspaceStatus,
    onboardingRequired: onboardingRequired,
    basicPositioningCompleted: basicPositioningCompleted,
    positioningStatus: positioningStatus,
    positioningProgress: positioningProgress,
  );
}

SessionUserStatus _statusWithWorkspace({
  String userId = 'user-1',
  bool? onboardingRequired,
  bool? basicPositioningCompleted,
  SessionPositioningStatus? positioningStatus,
  bool? isPlaceholder,
  String? defaultContentLineId,
  bool includeDefaultContentLine = true,
}) {
  return SessionUserStatus(
    user: SessionUser(userId: userId, maskedPhoneNumber: '138****8000'),
    workspace: SessionWorkspace(
      status: SessionWorkspaceStatus.ready,
      workspaceId: 'workspace-1',
      defaultContentLineId: defaultContentLineId,
    ),
    defaultContentLine: includeDefaultContentLine
        ? SessionContentLine(
            contentLineId: 'line-1',
            name: 'Default line',
            isPlaceholder: isPlaceholder,
          )
        : null,
    onboardingRequired: onboardingRequired,
    basicPositioningCompleted: basicPositioningCompleted,
    positioningStatus: positioningStatus,
    runningTaskCount: 0,
  );
}

final class _FakeSecureTokenDriver implements SecureTokenDriver {
  _FakeSecureTokenDriver({this.writeResult = true, this.clearResult = true});

  bool writeResult;
  bool clearResult;
  SecureTokenCredential? credential;

  @override
  SecureTokenCredential? read({required String service}) => credential;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) {
    if (writeResult) {
      credential = SecureTokenCredential(
        username: username,
        password: password,
      );
    }
    return writeResult;
  }

  @override
  bool clear({required String service}) {
    if (clearResult) {
      credential = null;
    }
    return clearResult;
  }
}
