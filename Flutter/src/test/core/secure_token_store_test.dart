import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';

void main() {
  group('SecureTokenStore', () {
    test('write false becomes SECURE_TOKEN_WRITE_FAILED', () async {
      final store = SecureTokenStore(
        driver: _FakeSecureTokenDriver(writeResult: false),
      );

      final result = await store.setTokens(
        const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'SECURE_TOKEN_WRITE_FAILED');
    });

    test('corrupted credential is retained for explicit reset', () async {
      final driver = _FakeSecureTokenDriver(
        credential: const SecureTokenCredential(
          username: 'session',
          password: '{"accessToken":""}',
        ),
      );
      final store = SecureTokenStore(driver: driver);

      final result = await store.getTokens();

      expect(result.ok, isFalse);
      expect(result.error?.code, 'SECURE_TOKEN_CORRUPTED');
      expect(driver.credential, isNotNull);
      expect(driver.cleared, isFalse);
    });

    test('safe recovery hint round-trips with tokens', () async {
      final store = SecureTokenStore(driver: _FakeSecureTokenDriver());
      final written = await store.setTokens(
        const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
        recoveryHint: const AuthSessionRecoveryHint(
          userId: 'user-1',
          maskedPhoneNumber: '138****8000',
          workspaceStatus: 'sync_failed',
          onboardingRequired: true,
          basicPositioningCompleted: false,
          positioningStatus: 'in_progress',
          coldStartPercent: 65,
          completedPercent: 24,
        ),
      );

      final hint = await store.getRecoveryHint();

      expect(written.ok, isTrue);
      expect(hint.ok, isTrue);
      expect(hint.value?.userId, 'user-1');
      expect(hint.value?.coldStartPercent, 65);
    });

    test(
      'malformed recovery hint is rejected without exposing credentials',
      () async {
        final store = SecureTokenStore(
          driver: _FakeSecureTokenDriver(
            credential: const SecureTokenCredential(
              username: 'session',
              password:
                  '{"accessToken":"access","refreshToken":"refresh","recoveryHint":{"userId":"user-1"}}',
            ),
          ),
        );

        final hint = await store.getRecoveryHint();

        expect(hint.ok, isFalse);
        expect(hint.error?.code, 'SECURE_TOKEN_CORRUPTED');
      },
    );
  });
}

final class _FakeSecureTokenDriver implements SecureTokenDriver {
  _FakeSecureTokenDriver({this.credential, this.writeResult = true});

  SecureTokenCredential? credential;
  bool writeResult;
  bool cleared = false;

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
    cleared = true;
    credential = null;
    return true;
  }
}
