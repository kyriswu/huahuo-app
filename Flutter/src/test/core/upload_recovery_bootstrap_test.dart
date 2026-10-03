import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_bootstrap_controller.dart';
import 'package:huahuoai_app/app/bootstrap/upload_recovery_bootstrap.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/auth/data/auth_api.dart';

void main() {
  group('UploadRecoveryBootstrap', () {
    test(
      'runs once per successfully recovered account and Workspace scope',
      () async {
        final harness = _Harness();
        var calls = 0;
        final recovery = UploadRecoveryBootstrap(
          bootstrapController: harness.bootstrap,
          sessionStore: harness.session,
          recoverDrafts: () async {
            calls += 1;
          },
        );
        addTearDown(recovery.dispose);

        recovery.start();
        expect(calls, 0);

        await harness.bootstrap.restore();
        expect(harness.bootstrap.state.status, AppBootstrapStatus.ready);
        expect(calls, 0);

        await harness.authenticate('user-1');
        await _flush();
        expect(calls, 1);

        harness.session.refreshUserStatus(
          status: _userStatus('user-1'),
          updatedAt: _now(),
        );
        await _flush();
        expect(calls, 1);

        harness.session.refreshUserStatus(
          status: _userStatus('user-1', workspaceId: 'workspace-2'),
          updatedAt: _now(),
        );
        await _flush();
        expect(calls, 2);

        await harness.authenticate('user-2');
        await _flush();
        expect(calls, 3);
      },
    );

    test(
      'contains failure and retries on a later state notification',
      () async {
        final harness = _Harness();
        var calls = 0;
        final recovery = UploadRecoveryBootstrap(
          bootstrapController: harness.bootstrap,
          sessionStore: harness.session,
          recoverDrafts: () async {
            calls += 1;
            if (calls == 1) throw StateError('offline');
          },
        );
        addTearDown(recovery.dispose);

        recovery.start();
        await harness.bootstrap.restore();
        await harness.authenticate('user-1');
        await _flush();
        expect(calls, 1);

        harness.session.refreshUserStatus(
          status: _userStatus('user-1'),
          updatedAt: _now(),
        );
        await _flush();
        expect(calls, 2);

        harness.session.refreshUserStatus(
          status: _userStatus('user-1'),
          updatedAt: _now(),
        );
        await _flush();
        expect(calls, 2);
      },
    );
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

DateTime _now() => DateTime.utc(2026, 7, 10, 12);

SessionUserStatus _userStatus(
  String userId, {
  String workspaceId = 'workspace-1',
}) {
  return SessionUserStatus(
    user: SessionUser(userId: userId, maskedPhoneNumber: '138****0000'),
    workspace: SessionWorkspace(
      status: SessionWorkspaceStatus.ready,
      workspaceId: workspaceId,
    ),
  );
}

final class _Harness {
  _Harness() {
    final driver = _MemorySecureTokenDriver();
    secureTokenStore = SecureTokenStore(driver: driver);
    session = SessionStore(secureTokenStore: secureTokenStore);
    bootstrap = AppBootstrapController(
      secureTokenStore: secureTokenStore,
      sessionStore: session,
      authApi: const _UnusedAuthApi(),
    );
  }

  late final SecureTokenStore secureTokenStore;
  late final SessionStore session;
  late final AppBootstrapController bootstrap;

  Future<void> authenticate(String userId) async {
    final result = await session.applyLoginSuccess(
      tokens: AuthTokens(
        accessToken: 'access-$userId',
        refreshToken: 'refresh-$userId',
      ),
      snapshot: SafeAuthSessionSnapshot(
        user: SessionUser(userId: userId, maskedPhoneNumber: '138****0000'),
        expiresAt: _now().add(const Duration(days: 1)),
        workspaceStatus: SessionWorkspaceStatus.ready,
      ),
      updatedAt: _now(),
    );
    expect(result.ok, isTrue);
    session.refreshUserStatus(status: _userStatus(userId), updatedAt: _now());
  }
}

final class _MemorySecureTokenDriver implements SecureTokenDriver {
  SecureTokenCredential? credential;

  @override
  SecureTokenCredential? read({required String service}) => credential;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) {
    credential = SecureTokenCredential(username: username, password: password);
    return true;
  }

  @override
  bool clear({required String service}) {
    credential = null;
    return true;
  }
}

final class _UnusedAuthApi implements AuthApiPort {
  const _UnusedAuthApi();

  @override
  Future<AuthApiResult<SessionUserStatus>> getUserStatus({
    String? accessToken,
    String? correlationId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AuthApiResult<SmsLoginResponse>> login({
    required SmsLoginRequest request,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AuthApiResult<RefreshTokenResponse>> refreshAuthToken({
    required String refreshToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AuthApiResult<SendSmsCodeResponse>> sendSmsCode({
    required String phone,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) {
    throw UnimplementedError();
  }
}
