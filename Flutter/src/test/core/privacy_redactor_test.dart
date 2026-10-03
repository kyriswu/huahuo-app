import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/diagnostics/privacy_redactor.dart';

void main() {
  group('PrivacyRedactor', () {
    test('drops unsafe keys and redacts unsafe scalar values', () {
      const redactor = PrivacyRedactor();

      final metadata = redactor.redactMetadata(const <String, Object?>{
        'token': 'access-token-secret',
        'stage': 'upload',
        'message': 'Native Module Error: GATT_ERROR',
        'count': 2,
      });

      expect(metadata.containsKey('token'), isFalse);
      expect(metadata['stage'], 'upload');
      expect(metadata['message'], 'redacted');
      expect(metadata['count'], 2);
    });

    test('unsafe summaries are replaced', () {
      const redactor = PrivacyRedactor();

      expect(
        redactor.safeSummary('HTTP 500 /Users/run/private.wav'),
        'Application operation failed',
      );
    });

    test('diagnostic correlation and metadata do not leak internals', () {
      const redactor = PrivacyRedactor();

      expect(
        redactor.sanitizeCorrelationId(
          'runtime:tenant:/home/data/huahuo/runtime/a',
        ),
        'redacted-correlation',
      );

      final metadata = redactor.redactMetadata(const <String, Object?>{
        'providerModelKey': 'secret-key',
        'safeScene': 'permissions',
        'workspacePath': '/home/data/huahuo/workspaces/private',
        'nativeStatus': 'CRC_FAIL',
      });

      expect(metadata.containsKey('providerModelKey'), isFalse);
      expect(metadata.containsKey('workspacePath'), isFalse);
      expect(metadata['safeScene'], 'permissions');
      expect(metadata['nativeStatus'], 'redacted');
    });
  });
}
