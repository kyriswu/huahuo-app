import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/auth/application/auth_controller.dart';
import 'package:huahuoai_app/features/auth/data/auth_api.dart';

void main() {
  group('AuthController', () {
    test('invalid phone is rejected locally', () async {
      final fixture = _controller();

      fixture.controller.setPhone('123');
      await fixture.controller.sendSmsCode();

      expect(fixture.controller.state.lastErrorCode, 'AUTH_PHONE_INVALID');
      expect(fixture.api.sentSmsRequests, isEmpty);
    });

    test('invalid SMS code is rejected locally', () async {
      final fixture = _controller();

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('123');
      fixture.controller.setAgreementAccepted(true);
      await fixture.controller.login();

      expect(fixture.controller.state.lastErrorCode, 'AUTH_SMS_CODE_INVALID');
      expect(fixture.api.loginRequests, isEmpty);
    });

    test('missing agreement is rejected locally', () async {
      final fixture = _controller();

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      await fixture.controller.login();

      expect(fixture.controller.state.lastErrorCode, 'AUTH_AGREEMENT_REQUIRED');
      expect(fixture.api.loginRequests, isEmpty);
    });

    test('missing smsRequestId is rejected before remote login', () async {
      final fixture = _controller();

      fixture.controller.setPhone('13812348000');
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      await fixture.controller.login();

      expect(
        fixture.controller.state.lastErrorCode,
        'AUTH_SMS_REQUEST_MISSING',
      );
      expect(fixture.api.loginRequests, isEmpty);
    });

    test('send SMS stores server smsRequestId and cooldown', () async {
      final fixture = _controller();

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();

      expect(fixture.controller.state.smsRequestId, 'sms-1');
      expect(
        fixture.controller.state.cooldownSecondsRemaining(
          DateTime.utc(2026, 1, 1),
        ),
        75,
      );
    });

    test('normalized equivalent phone edit preserves smsRequestId', () async {
      final fixture = _controller();

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      final cooldownUntil = fixture.controller.state.cooldownUntil;

      fixture.controller.setPhone('138 1234 8000');

      expect(fixture.controller.state.phone, '13812348000');
      expect(fixture.controller.state.smsRequestId, 'sms-1');
      expect(fixture.controller.state.cooldownUntil, cooldownUntil);
    });

    test('send SMS applies minimum cooldown for short server value', () async {
      final fixture = _controller(smsCooldownSeconds: 0);

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();

      expect(
        fixture.controller.state.cooldownSecondsRemaining(
          DateTime.utc(2026, 1, 1),
        ),
        60,
      );
    });

    test('send SMS cooldown starts from accepted response time', () async {
      var now = DateTime.utc(2026, 1, 1);
      final smsCompleter = Completer<AuthApiResult<SendSmsCodeResponse>>();
      final fixture = _controller(smsCompleter: smsCompleter, now: () => now);

      fixture.controller.setPhone('13812348000');
      final pending = fixture.controller.sendSmsCode();
      now = now.add(const Duration(seconds: 10));
      smsCompleter.complete(
        AuthApiResult<SendSmsCodeResponse>.success(
          value: const SendSmsCodeResponse(
            smsRequestId: 'sms-1',
            cooldownSeconds: 75,
          ),
          status: 200,
        ),
      );
      await pending;

      expect(fixture.controller.state.cooldownSecondsRemaining(now), 75);
    });

    test('auth requests pass operation-scoped idempotency contexts', () async {
      final fixture = _controller();

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      await fixture.controller.login();

      expect(fixture.api.sentSmsIdempotency.single?.operation, 'auth-sms-code');
      expect(
        fixture.api.sentSmsIdempotency.single?.businessEntityId,
        '138****8000',
      );
      expect(fixture.api.sentSmsIdempotency.single?.scene, 'login');
      expect(fixture.api.loginIdempotency.single?.operation, 'auth-login');
      expect(
        fixture.api.loginIdempotency.single?.businessEntityId,
        '138****8000',
      );
      expect(fixture.api.loginIdempotency.single?.scene, 'login');
      expect(fixture.api.loginRequests.single.timeZone, 'Asia/Shanghai');
    });

    test('fallback time zone is omitted from the login request', () async {
      final fixture = _controller(
        userTimeZone: 'UTC',
        userTimeZoneIsFallback: true,
      );

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      await fixture.controller.login();

      expect(fixture.api.loginRequests.single.timeZone, isNull);
      expect(fixture.api.statusAccessTokens, <String?>['access']);
      expect(fixture.api.updatedTimeZones, <String>['UTC']);
      expect(fixture.api.timeZoneAccessTokens, <String>['access']);
      expect(
        fixture.api.timeZoneIdempotency.single?.scene,
        'login-timezone-repair',
      );
      expect(
        fixture.sessionStore.state.authState,
        SessionAuthState.authenticated,
      );
      expect(fixture.sessionStore.state.workspace?.workspaceId, 'workspace-1');
    });

    test(
      'fallback time zone preserves an existing server IANA value',
      () async {
        final fixture = _controller(
          userTimeZone: 'UTC',
          userTimeZoneIsFallback: true,
          userStatusResult: AuthApiResult<SessionUserStatus>.success(
            value: const SessionUserStatus(
              user: SessionUser(
                userId: 'user-1',
                maskedPhoneNumber: '138****8000',
              ),
              workspace: SessionWorkspace(
                status: SessionWorkspaceStatus.ready,
                workspaceId: 'workspace-1',
              ),
              timeZone: 'Asia/Shanghai',
            ),
            status: 200,
          ),
        );

        fixture.controller.setPhone('13812348000');
        await fixture.controller.sendSmsCode();
        fixture.controller.setCode('112233');
        fixture.controller.setAgreementAccepted(true);
        await fixture.controller.login();

        expect(fixture.api.updatedTimeZones, isEmpty);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.authenticated,
        );
      },
    );

    test('stale SMS response after phone change is discarded', () async {
      final smsCompleter = Completer<AuthApiResult<SendSmsCodeResponse>>();
      final fixture = _controller(smsCompleter: smsCompleter);

      fixture.controller.setPhone('13812348000');
      final pending = fixture.controller.sendSmsCode();
      expect(fixture.controller.state.status, AuthSubmissionStatus.sendingCode);

      fixture.controller.setPhone('13912348000');
      expect(fixture.controller.state.status, AuthSubmissionStatus.idle);
      smsCompleter.complete(
        AuthApiResult<SendSmsCodeResponse>.success(
          value: const SendSmsCodeResponse(
            smsRequestId: 'sms-old-phone',
            cooldownSeconds: 75,
          ),
          status: 200,
        ),
      );
      await pending;

      expect(fixture.controller.state.phone, '13912348000');
      expect(fixture.controller.state.status, AuthSubmissionStatus.idle);
      expect(fixture.controller.state.smsRequestId, isNull);
      expect(fixture.controller.state.cooldownUntil, isNull);
    });

    test('duplicate send SMS is rejected while sending', () async {
      final smsCompleter = Completer<AuthApiResult<SendSmsCodeResponse>>();
      final fixture = _controller(smsCompleter: smsCompleter);

      fixture.controller.setPhone('13812348000');
      final pending = fixture.controller.sendSmsCode();
      expect(fixture.controller.state.status, AuthSubmissionStatus.sendingCode);

      await fixture.controller.sendSmsCode();

      expect(fixture.controller.state.status, AuthSubmissionStatus.sendingCode);
      expect(fixture.controller.state.lastErrorCode, 'AUTH_SMS_IN_PROGRESS');
      expect(fixture.api.sentSmsRequests, <String>['13812348000']);

      smsCompleter.complete(
        AuthApiResult<SendSmsCodeResponse>.success(
          value: const SendSmsCodeResponse(
            smsRequestId: 'sms-1',
            cooldownSeconds: 75,
          ),
          status: 200,
        ),
      );
      await pending;
    });

    test('send SMS exception resets loading state', () async {
      final fixture = _controller(throwOnSms: true);

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();

      expect(fixture.controller.state.status, AuthSubmissionStatus.idle);
      expect(fixture.controller.state.lastErrorCode, 'AUTH_SMS_REQUEST_FAILED');
      expect(fixture.controller.state.smsRequestId, isNull);
    });

    test('login success writes session through SessionStore', () async {
      final fixture = _controller(
        loginResponse: _loginResponse(firstLogin: true),
      );

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      await fixture.controller.login();

      expect(
        fixture.sessionStore.state.authState,
        SessionAuthState.authenticated,
      );
      expect(fixture.api.statusAccessTokens, <String?>['access']);
      expect(fixture.sessionStore.state.workspace?.workspaceId, 'workspace-1');
      expect(fixture.sessionStore.state.firstLoginThisSession, isTrue);
      expect(fixture.sessionStore.selectRoute().type, SessionRouteType.v3);
    });

    test(
      'login rejects a status validation failure before persisting tokens',
      () async {
        final fixture = _controller(
          loginResponse: _loginResponse(firstLogin: true),
          userStatusResult: AuthApiResult<SessionUserStatus>.failure(
            error: const AppFailure(
              code: 'TOKEN_EXPIRED',
              category: AppFailureCategory.auth,
              message: 'token rejected by main authority',
              userMessageKey: 'auth.expired',
            ),
            status: 401,
          ),
        );

        fixture.controller.setPhone('13812348000');
        await fixture.controller.sendSmsCode();
        fixture.controller.setCode('112233');
        fixture.controller.setAgreementAccepted(true);
        await fixture.controller.login();

        expect(fixture.controller.state.lastErrorCode, 'TOKEN_EXPIRED');
        expect(fixture.api.statusAccessTokens, <String?>['access']);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.anonymous,
        );
        expect(fixture.sessionStore.state.firstLoginThisSession, isFalse);
        expect(fixture.driver.credential, isNull);
      },
    );

    test(
      'login rejects a status validation exception before persisting tokens',
      () async {
        final fixture = _controller(throwOnStatus: true);

        fixture.controller.setPhone('13812348000');
        await fixture.controller.sendSmsCode();
        fixture.controller.setCode('112233');
        fixture.controller.setAgreementAccepted(true);
        await fixture.controller.login();

        expect(
          fixture.controller.state.lastErrorCode,
          'AUTH_SESSION_VALIDATION_FAILED',
        );
        expect(fixture.api.statusAccessTokens, <String?>['access']);
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.anonymous,
        );
        expect(fixture.driver.credential, isNull);
      },
    );

    test('verified sync-failed workspace enters the recovery route', () async {
      final fixture = _controller(
        userStatusResult: AuthApiResult<SessionUserStatus>.success(
          value: const SessionUserStatus(
            user: SessionUser(
              userId: 'user-1',
              maskedPhoneNumber: '138****8000',
            ),
            workspace: SessionWorkspace(
              status: SessionWorkspaceStatus.syncFailed,
              workspaceId: 'workspace-1',
            ),
          ),
          status: 200,
        ),
      );

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      await fixture.controller.login();

      expect(fixture.controller.state.lastErrorCode, isNull);
      expect(fixture.driver.credential, isNotNull);
      expect(
        fixture.sessionStore.selectRoute().type,
        SessionRouteType.workspaceRetry,
      );
    });

    test(
      'login rejects a mismatched verified user before persisting tokens',
      () async {
        final fixture = _controller(
          userStatusResult: AuthApiResult<SessionUserStatus>.success(
            value: const SessionUserStatus(
              user: SessionUser(
                userId: 'user-2',
                maskedPhoneNumber: '139****8000',
              ),
              workspace: SessionWorkspace(
                status: SessionWorkspaceStatus.ready,
                workspaceId: 'workspace-2',
              ),
            ),
            status: 200,
          ),
        );

        fixture.controller.setPhone('13812348000');
        await fixture.controller.sendSmsCode();
        fixture.controller.setCode('112233');
        fixture.controller.setAgreementAccepted(true);
        await fixture.controller.login();

        expect(
          fixture.controller.state.lastErrorCode,
          'AUTH_SESSION_IDENTITY_MISMATCH',
        );
        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.anonymous,
        );
        expect(fixture.driver.credential, isNull);
      },
    );

    test('stale login response after draft change is discarded', () async {
      final loginCompleter = Completer<AuthApiResult<SmsLoginResponse>>();
      final fixture = _controller(loginCompleter: loginCompleter);

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      final pending = fixture.controller.login();
      expect(fixture.controller.state.status, AuthSubmissionStatus.loggingIn);

      fixture.controller.setCode('445566');
      expect(fixture.controller.state.status, AuthSubmissionStatus.idle);
      loginCompleter.complete(
        AuthApiResult<SmsLoginResponse>.success(
          value: const SmsLoginResponse(
            tokens: AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
            user: SessionUser(
              userId: 'user-1',
              maskedPhoneNumber: '138****8000',
            ),
            workspaceStatus: SessionWorkspaceStatus.ready,
          ),
          status: 200,
        ),
      );
      await pending;

      expect(fixture.controller.state.code, '445566');
      expect(fixture.controller.state.status, AuthSubmissionStatus.idle);
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
      expect(fixture.api.loginRequests.single.code, '112233');
    });

    test(
      'draft edits are rejected while token persistence is committing',
      () async {
        final tokenWrite = Completer<bool>();
        final fixture = _controller(tokenWrite: tokenWrite);

        fixture.controller.setPhone('13812348000');
        await fixture.controller.sendSmsCode();
        fixture.controller.setCode('112233');
        fixture.controller.setAgreementAccepted(true);
        final pending = fixture.controller.login();
        await Future<void>.delayed(Duration.zero);

        expect(
          fixture.controller.state.status,
          AuthSubmissionStatus.committingLogin,
        );

        fixture.controller.setCode('445566');
        fixture.controller.setAgreementAccepted(false);

        expect(fixture.controller.state.code, '112233');
        expect(fixture.controller.state.agreementAccepted, isTrue);
        expect(
          fixture.controller.state.status,
          AuthSubmissionStatus.committingLogin,
        );
        expect(
          fixture.controller.state.lastErrorCode,
          'AUTH_LOGIN_IN_PROGRESS',
        );

        tokenWrite.complete(true);
        await pending;

        expect(
          fixture.sessionStore.state.authState,
          SessionAuthState.authenticated,
        );
      },
    );

    test('send SMS is rejected while login is submitting', () async {
      final loginCompleter = Completer<AuthApiResult<SmsLoginResponse>>();
      final fixture = _controller(loginCompleter: loginCompleter);

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      final pending = fixture.controller.login();
      expect(fixture.controller.state.status, AuthSubmissionStatus.loggingIn);

      await fixture.controller.sendSmsCode();

      expect(fixture.controller.state.status, AuthSubmissionStatus.loggingIn);
      expect(fixture.controller.state.lastErrorCode, 'AUTH_LOGIN_IN_PROGRESS');
      expect(fixture.api.sentSmsRequests, <String>['13812348000']);

      loginCompleter.complete(
        AuthApiResult<SmsLoginResponse>.failure(
          error: const AppFailure(
            code: 'AUTH_SESSION_EXPIRED',
            category: AppFailureCategory.auth,
            message: 'expired',
            userMessageKey: 'auth.expired',
          ),
        ),
      );
      await pending;
    });

    test('duplicate login is rejected while login is submitting', () async {
      final loginCompleter = Completer<AuthApiResult<SmsLoginResponse>>();
      final fixture = _controller(loginCompleter: loginCompleter);

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      final pending = fixture.controller.login();
      expect(fixture.controller.state.status, AuthSubmissionStatus.loggingIn);

      await fixture.controller.login();

      expect(fixture.controller.state.status, AuthSubmissionStatus.loggingIn);
      expect(fixture.controller.state.lastErrorCode, 'AUTH_LOGIN_IN_PROGRESS');
      expect(fixture.api.loginRequests, hasLength(1));

      loginCompleter.complete(
        AuthApiResult<SmsLoginResponse>.failure(
          error: const AppFailure(
            code: 'AUTH_SESSION_EXPIRED',
            category: AppFailureCategory.auth,
            message: 'expired',
            userMessageKey: 'auth.expired',
          ),
        ),
      );
      await pending;
    });

    test('login exception resets loading state', () async {
      final fixture = _controller(throwOnLogin: true);

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      await fixture.controller.login();

      expect(fixture.controller.state.status, AuthSubmissionStatus.idle);
      expect(
        fixture.controller.state.lastErrorCode,
        'AUTH_LOGIN_REQUEST_FAILED',
      );
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
    });

    test('token write failure stays unauthenticated', () async {
      final fixture = _controller(writeTokens: false);

      fixture.controller.setPhone('13812348000');
      await fixture.controller.sendSmsCode();
      fixture.controller.setCode('112233');
      fixture.controller.setAgreementAccepted(true);
      await fixture.controller.login();

      expect(
        fixture.controller.state.lastErrorCode,
        'SECURE_TOKEN_WRITE_FAILED',
      );
      expect(fixture.sessionStore.state.authState, SessionAuthState.anonymous);
      expect(fixture.sessionStore.selectRoute().type, SessionRouteType.auth);
    });
  });
}

SmsLoginResponse _loginResponse({bool firstLogin = false}) {
  return SmsLoginResponse(
    tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    user: const SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
    workspaceStatus: SessionWorkspaceStatus.ready,
    firstLogin: firstLogin,
  );
}

({
  AuthController controller,
  SessionStore sessionStore,
  _FakeAuthApi api,
  _FakeSecureTokenDriver driver,
})
_controller({
  bool writeTokens = true,
  int smsCooldownSeconds = 75,
  bool throwOnSms = false,
  bool throwOnLogin = false,
  bool throwOnStatus = false,
  Completer<AuthApiResult<SendSmsCodeResponse>>? smsCompleter,
  Completer<AuthApiResult<SmsLoginResponse>>? loginCompleter,
  AuthApiResult<SessionUserStatus>? userStatusResult,
  SmsLoginResponse? loginResponse,
  DateTime Function()? now,
  Completer<bool>? tokenWrite,
  String userTimeZone = 'Asia/Shanghai',
  bool userTimeZoneIsFallback = false,
}) {
  final driver = _FakeSecureTokenDriver(
    writeTokens: writeTokens,
    tokenWrite: tokenWrite,
  );
  final tokenStore = SecureTokenStore(driver: driver);
  final sessionStore = SessionStore(secureTokenStore: tokenStore);
  final api = _FakeAuthApi(
    smsCooldownSeconds: smsCooldownSeconds,
    throwOnSms: throwOnSms,
    throwOnLogin: throwOnLogin,
    throwOnStatus: throwOnStatus,
    smsCompleter: smsCompleter,
    loginCompleter: loginCompleter,
    userStatusResult: userStatusResult,
    loginResponse: loginResponse,
  );
  final controller = AuthController(
    authApi: api,
    sessionStore: sessionStore,
    deviceId: 'device-1',
    clientVersion: '0.1.0',
    userTimeZone: userTimeZone,
    userTimeZoneIsFallback: userTimeZoneIsFallback,
    userTimeZoneApi: api,
    now: now ?? () => DateTime.utc(2026, 1, 1),
    correlationIdFactory: () => 'trace-auth',
  );
  return (
    controller: controller,
    sessionStore: sessionStore,
    api: api,
    driver: driver,
  );
}

final class _FakeAuthApi implements AuthApiPort, UserTimeZoneApiPort {
  _FakeAuthApi({
    required this.smsCooldownSeconds,
    this.throwOnSms = false,
    this.throwOnLogin = false,
    this.throwOnStatus = false,
    this.smsCompleter,
    this.loginCompleter,
    this.userStatusResult,
    this.loginResponse,
  });

  final int smsCooldownSeconds;
  final bool throwOnSms;
  final bool throwOnLogin;
  final bool throwOnStatus;
  final Completer<AuthApiResult<SendSmsCodeResponse>>? smsCompleter;
  final Completer<AuthApiResult<SmsLoginResponse>>? loginCompleter;
  final AuthApiResult<SessionUserStatus>? userStatusResult;
  final SmsLoginResponse? loginResponse;
  final sentSmsRequests = <String>[];
  final sentSmsIdempotency = <IdempotencyRequestContext?>[];
  final loginRequests = <SmsLoginRequest>[];
  final loginIdempotency = <IdempotencyRequestContext?>[];
  final statusAccessTokens = <String?>[];
  final updatedTimeZones = <String>[];
  final timeZoneAccessTokens = <String>[];
  final timeZoneIdempotency = <IdempotencyRequestContext?>[];

  @override
  Future<AuthApiResult<SendSmsCodeResponse>> sendSmsCode({
    required String phone,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    if (throwOnSms) {
      throw StateError('sms transport failed');
    }
    sentSmsRequests.add(phone);
    sentSmsIdempotency.add(idempotency);
    final pending = smsCompleter;
    if (pending != null) {
      return await pending.future;
    }
    return AuthApiResult<SendSmsCodeResponse>.success(
      value: SendSmsCodeResponse(
        smsRequestId: 'sms-1',
        cooldownSeconds: smsCooldownSeconds,
      ),
      status: 200,
    );
  }

  @override
  Future<AuthApiResult<SmsLoginResponse>> login({
    required SmsLoginRequest request,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    if (throwOnLogin) {
      throw StateError('login transport failed');
    }
    loginRequests.add(request);
    loginIdempotency.add(idempotency);
    final pending = loginCompleter;
    if (pending != null) {
      return await pending.future;
    }
    return AuthApiResult<SmsLoginResponse>.success(
      value:
          loginResponse ??
          const SmsLoginResponse(
            tokens: AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
            user: SessionUser(
              userId: 'user-1',
              maskedPhoneNumber: '138****8000',
            ),
            workspaceStatus: SessionWorkspaceStatus.ready,
          ),
      status: 200,
    );
  }

  @override
  Future<AuthApiResult<RefreshTokenResponse>> refreshAuthToken({
    required String refreshToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    return AuthApiResult<RefreshTokenResponse>.failure(
      error: const AppFailure(
        code: 'NOT_USED',
        category: AppFailureCategory.auth,
        message: 'not used',
        userMessageKey: 'not.used',
      ),
    );
  }

  @override
  Future<AuthApiResult<SessionUserStatus>> getUserStatus({
    String? accessToken,
    String? correlationId,
  }) async {
    statusAccessTokens.add(accessToken);
    if (throwOnStatus) {
      throw StateError('status transport failed');
    }
    return userStatusResult ??
        AuthApiResult<SessionUserStatus>.success(
          value: const SessionUserStatus(
            user: SessionUser(
              userId: 'user-1',
              maskedPhoneNumber: '138****8000',
            ),
            workspace: SessionWorkspace(
              status: SessionWorkspaceStatus.ready,
              workspaceId: 'workspace-1',
            ),
          ),
          status: 200,
          traceId: 'trace-status',
        );
  }

  @override
  Future<AuthApiResult<UpdateUserTimeZoneResponse>> updateUserTimeZone({
    required String timeZone,
    required String accessToken,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) async {
    updatedTimeZones.add(timeZone);
    timeZoneAccessTokens.add(accessToken);
    timeZoneIdempotency.add(idempotency);
    return AuthApiResult<UpdateUserTimeZoneResponse>.success(
      value: UpdateUserTimeZoneResponse(timeZone: timeZone),
      status: 200,
    );
  }
}

final class _FakeSecureTokenDriver implements SecureTokenDriver {
  _FakeSecureTokenDriver({required this.writeTokens, this.tokenWrite});

  final bool writeTokens;
  final Completer<bool>? tokenWrite;
  SecureTokenCredential? credential;

  @override
  SecureTokenCredential? read({required String service}) => credential;

  @override
  FutureOr<bool> write({
    required String service,
    required String username,
    required String password,
  }) {
    final pending = tokenWrite;
    if (pending != null) {
      return pending.future.then((stored) {
        if (stored && writeTokens) {
          credential = SecureTokenCredential(
            username: username,
            password: password,
          );
        }
        return stored && writeTokens;
      });
    }
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
    credential = null;
    return true;
  }
}
