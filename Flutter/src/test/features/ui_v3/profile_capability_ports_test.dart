import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/data/profile_capability_ports.dart';
import 'package:huahuoai_app/features/ui_v3/domain/profile_capability_models.dart';

void main() {
  test('account demo port returns only masked binding state', () async {
    final port = ProfileAccountSecurityDemoPort();

    final phone = await port.rebindPhone('13800138000');
    final email = await port.bindEmail('creator@example.com');
    final password = await port.changePassword('one-time-password');

    expect(phone.ok, isTrue);
    expect(email.ok, isTrue);
    expect(password.ok, isTrue);
    expect(port.snapshot.maskedPhone, '138****8000');
    expect(port.snapshot.maskedEmail, 'c***@example.com');
    expect(port.snapshot.passwordUpdatedAt, isNotNull);
    expect(port.snapshot.isDemo, isTrue);
    expect(port.snapshot.toString(), isNot(contains('one-time-password')));
  });

  test(
    'account demo port rejects invalid values without changing state',
    () async {
      final port = ProfileAccountSecurityDemoPort();

      final phone = await port.rebindPhone('123');
      final email = await port.bindEmail('not-an-email');
      final password = await port.changePassword('short');

      expect(phone.errorCode, 'PROFILE_PHONE_INVALID');
      expect(email.errorCode, 'PROFILE_EMAIL_INVALID');
      expect(password.errorCode, 'PROFILE_PASSWORD_INVALID');
      expect(port.snapshot.maskedPhone, isNull);
      expect(port.snapshot.maskedEmail, isNull);
      expect(port.snapshot.passwordUpdatedAt, isNull);
    },
  );

  test(
    'support demo validates bug description without accepting file paths',
    () async {
      const port = ProfileSupportDemoPort();
      const request = ProfileBugReportRequest(
        description: '创作页点击保存后没有响应',
        screenshotCount: 3,
        includeDiagnostics: true,
      );

      final result = await port.submitBug(request);
      final invalid = await port.submitBug(
        const ProfileBugReportRequest(
          description: '短',
          screenshotCount: 0,
          includeDiagnostics: false,
        ),
      );

      expect(result.ok, isTrue);
      expect(result.isDemo, isTrue);
      expect(port.content.customerWechat, isNotEmpty);
      expect(invalid.errorCode, 'PROFILE_BUG_DESCRIPTION_INVALID');
    },
  );

  test('version demo exposes offline copy and unavailable check', () async {
    final port = ProfileVersionDemoPort(
      delay: Duration.zero,
      installedVersionLoader: () async => const ProfileVersionInfo(
        version: '2.4.0',
        buildNumber: '18',
        isDemo: false,
        releaseTitle: '本机版本介绍',
        releaseSummary: '随包说明',
        highlights: <String>['更新一', '更新二', '更新三'],
      ),
    );

    await port.loadCurrent();
    final result = await port.checkForUpdate();

    expect(result.ok, isFalse);
    expect(result.isDemo, isTrue);
    expect(result.errorCode, 'PROFILE_VERSION_CHECK_DEMO_UNAVAILABLE');
    expect(port.current.displayLabel, '2.4.0 (18)');
    expect(port.current.releaseTitle, isNotEmpty);
    expect(port.current.releaseSummary, isNotEmpty);
    expect(port.current.highlights, hasLength(greaterThanOrEqualTo(3)));
  });

  test(
    'installed version plugin failure keeps the packaged fallback',
    () async {
      final port = ProfileVersionDemoPort(
        delay: Duration.zero,
        installedVersionLoader: () =>
            Future<ProfileVersionInfo>.error(StateError('plugin unavailable')),
      );

      final current = await port.loadCurrent();

      expect(current, same(ProfileVersionDemoPort.fallbackCurrent));
      expect(current.displayLabel, '0.1.0 (1)');
      expect(current.releaseSummary, isNotEmpty);
    },
  );

  test(
    'runtime version port compares installed package with app config',
    () async {
      final port = ProfileVersionApiPort(
        apiClient: _apiClient(const <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'latestClientVersion': '1.3.0',
            'forceUpgrade': false,
          },
        }),
        installedVersionLoader: () async => const ProfileVersionInfo(
          version: '1.2.4',
          buildNumber: '24',
          isDemo: false,
        ),
      );

      final result = await port.checkForUpdate();

      expect(result.ok, isTrue);
      expect(result.isDemo, isFalse);
      expect(result.data?.current.displayLabel, '1.2.4 (24)');
      expect(result.data?.latestVersion, '1.3.0');
      expect(result.data?.updateAvailable, isTrue);
      expect(compareProfileVersions('1.2.10', '1.2.9'), greaterThan(0));
      expect(compareProfileVersions('1.2', '1.2.0'), 0);
    },
  );

  test('runtime version port rejects malformed app config', () async {
    final port = ProfileVersionApiPort(
      apiClient: _apiClient(const <String, Object?>{
        'success': true,
        'data': <String, Object?>{
          'latestClientVersion': 'latest',
          'forceUpgrade': false,
        },
      }),
      installedVersionLoader: () async =>
          ProfileVersionDemoPort.fallbackCurrent,
    );

    final result = await port.checkForUpdate();

    expect(result.ok, isFalse);
    expect(result.errorCode, isNotEmpty);
  });
}

ApiClient _apiClient(Map<String, Object?> responseBody) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'profile-version-test-device',
    platform: 'flutter_test',
    locale: 'zh-CN',
  ),
  transport: _StaticProfileTransport(responseBody),
);

final class _StaticProfileTransport implements ApiTransport {
  const _StaticProfileTransport(this.body);

  final Map<String, Object?> body;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      ApiTransportResponse(status: 200, body: body);
}
