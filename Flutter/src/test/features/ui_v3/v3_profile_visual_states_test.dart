import 'package:huahuoai_app/app/di/account_usage_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/billing_providers.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/billing/data/android_payment_port.dart';
import 'package:huahuoai_app/features/billing/data/ios_store_purchase_port.dart';
import 'package:huahuoai_app/features/billing/widgets/v3_membership_page.dart';
import 'package:huahuoai_app/features/ui_v3/application/user_profile_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/voiceprint_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/profile_capability_ports.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_profile_side_panel.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_voiceprint_page.dart';

import '../../support/figma_golden_test_support.dart';

const _surface = Size(402, 874);

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M06 profile home', (tester) async {
    await _pump(
      tester,
      const V3ProfileHomePage(),
      overrides: _profileOverrides(),
    );
    await _golden(tester, 'm06_profile_home.png');
  });

  testWidgets('M06 settings', (tester) async {
    _stubPermissionStatuses();
    await _pump(tester, const V3ProfilePlaceholderPage(section: '设置'));
    expect(find.text('权限隐私'), findsOneWidget);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('settings-account-security')))
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('settings-permission-privacy')),
            )
            .dy,
      ),
    );
    await _golden(tester, 'm06_settings.png');
  });

  testWidgets('M06 account security', (tester) async {
    await _pump(
      tester,
      const V3ProfilePlaceholderPage(section: '账号与安全'),
      overrides: [
        sessionStoreProvider.overrideWith((ref) => _sessionStore()),
        profileAccountSecurityPortProvider.overrideWith(
          (ref) => ProfileAccountSecurityDemoPort(),
        ),
      ],
    );
    expect(find.text('手机号换绑'), findsOneWidget);
    expect(find.text('注销账号'), findsOneWidget);
    for (final key in const ['wechat', 'email', 'password']) {
      expect(find.byKey(ValueKey('account-security-$key')), findsNothing);
    }
    await _golden(tester, 'm06_account_security.png');
  });

  testWidgets('M06 appearance', (tester) async {
    await _pump(tester, const V3ProfilePlaceholderPage(section: '外观与显示'));
    await _golden(tester, 'm06_appearance.png');
  });

  testWidgets('M06 reminder disabled', (tester) async {
    await _pump(tester, const V3ProfilePlaceholderPage(section: '日报提醒'));
    await _golden(tester, 'm06_reminder_disabled.png');
  });

  testWidgets('M06 reminder enabled', (tester) async {
    await _pump(tester, const V3ProfilePlaceholderPage(section: '日报提醒'));
    await tester.tap(
      find.byKey(const ValueKey('settings-daily-reminder-switch')),
    );
    await tester.pump();
    await _golden(tester, 'm06_reminder_enabled.png');
  });

  testWidgets('M06 permissions', (tester) async {
    _stubPermissionStatuses();
    await _pump(tester, const V3ProfilePlaceholderPage(section: '权限隐私'));
    expect(find.text('权限隐私'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-permission-group-设备连接')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-permission-group-录音与通知')),
      findsOneWidget,
    );
    for (final label in <String>[
      '蓝牙',
      '附近设备',
      '本地网络',
      '麦克风',
      '相机',
      '媒体库',
      '通知',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('前往系统设置'), findsNothing);
    expect(find.text('设备连接'), findsWidgets);
    expect(find.text('录音与通知'), findsWidgets);
    expect(find.text('说明'), findsOneWidget);
    expect(find.text('待授权'), findsWidgets);
    await _golden(tester, 'm06_permissions.png');
  });

  testWidgets('M06 version', (tester) async {
    await _pump(
      tester,
      const V3ProfilePlaceholderPage(section: '版本更新'),
      overrides: [
        profileVersionPortProvider.overrideWith(
          (ref) => ProfileVersionDemoPort(delay: Duration.zero),
        ),
      ],
    );
    await _golden(tester, 'm06_version.png');
  });

  testWidgets('M06 help about', (tester) async {
    await _pump(
      tester,
      const V3ProfilePlaceholderPage(section: '帮助与反馈'),
      overrides: [
        profileSupportPortProvider.overrideWith(
          (ref) => const ProfileSupportDemoPort(),
        ),
      ],
    );
    await _golden(tester, 'm06_help_about.png');
  });

  testWidgets('M06 membership', (tester) async {
    await _pump(
      tester,
      V3MembershipPage(
        billingController: billingControllerProvider,
        accountUsageController: accountUsageControllerProvider,
      ),
      overrides: [
        androidPaymentPortProvider.overrideWithValue(
          const _VisualAndroidPaymentPort(),
        ),
        iosStorePurchasePortProvider.overrideWithValue(
          const _VisualIOSStorePurchasePort(),
        ),
      ],
    );
    await _golden(tester, 'm06_membership.png');
  });

  testWidgets('M06 voiceprint management empty', (tester) async {
    await _pump(
      tester,
      const V3VoiceprintPage(),
      overrides: _voiceprintOverrides(),
    );
    await _golden(tester, 'm06_voiceprint_empty.png');
  });

  testWidgets('M06 voiceprint ready', (tester) async {
    await _pump(
      tester,
      const V3VoiceprintPage(enrollmentOnly: true, initialProfileName: '我的声纹'),
      overrides: _voiceprintOverrides(),
    );
    await _golden(tester, 'm06_voiceprint_ready.png');
  });

  testWidgets('M06 voiceprint recording', (tester) async {
    await _pump(
      tester,
      const V3VoiceprintPage(enrollmentOnly: true, initialProfileName: '我的声纹'),
      overrides: _voiceprintOverrides(),
    );
    await tester.tap(find.text('开始录入'));
    await tester.pump();
    await _golden(tester, 'm06_voiceprint_recording.png');
  });
}

void _stubPermissionStatuses() {
  const channel = MethodChannel('huahuoai/platform_permissions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method != 'getPermissionStatuses') return null;
    return <String, Object?>{
      'bluetooth': 'not_determined',
      'nearby_devices': 'not_determined',
      'microphone': 'not_determined',
      'camera': 'not_determined',
      'media_library': 'not_determined',
      'notification': 'not_determined',
      'local_network': 'not_determined',
    };
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  List<Override> overrides = const [],
}) async {
  await tester.binding.setSurfaceSize(_surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: figmaGoldenTheme(),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _golden(
  WidgetTester tester,
  String name, {
  bool overlay = false,
}) async {
  await precacheFigmaFixtureImages(tester);
  await expectLater(
    overlay ? find.byType(Overlay).first : find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name'),
  );
}

List<Override> _profileOverrides() => [
  sessionStoreProvider.overrideWith((ref) => _sessionStore()),
  userProfilePortProvider.overrideWith((ref) => SessionMockUserProfilePort()),
];

List<Override> _voiceprintOverrides() => [
  sessionStoreProvider.overrideWith((ref) => _sessionStore()),
  voiceRecorderPortProvider.overrideWithValue(_VisualVoiceRecorder()),
  voiceprintPortProvider.overrideWithValue(
    SessionMockVoiceprintPort(deleteLocalSample: (_) async => true),
  ),
];

SessionStore _sessionStore() {
  return SessionStore(
    secureTokenStore: SecureTokenStore(driver: _MemoryTokenDriver()),
  )..refreshUserStatus(
    status: const SessionUserStatus(
      user: SessionUser(
        userId: 'm06-visual-user',
        maskedPhoneNumber: '138****8000',
        displayName: '002测试',
      ),
      workspace: SessionWorkspace(status: SessionWorkspaceStatus.ready),
    ),
    updatedAt: DateTime.utc(2026, 8, 24),
  );
}

final class _MemoryTokenDriver implements SecureTokenDriver {
  @override
  bool clear({required String service}) => true;

  @override
  SecureTokenCredential? read({required String service}) => null;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) => true;
}

final class _VisualAndroidPaymentPort implements AndroidPaymentPort {
  const _VisualAndroidPaymentPort();

  @override
  Stream<AndroidPaymentEvent> get events => const Stream.empty();

  @override
  Future<bool> isAvailable(BillingProvider provider) async => false;

  @override
  Future<AndroidPaymentClientResult> start({
    required BillingProvider provider,
    required String orderId,
    required Map<String, Object?> launchPayload,
  }) async => AndroidPaymentClientResult.unavailable;
}

final class _VisualIOSStorePurchasePort implements IOSStorePurchasePort {
  const _VisualIOSStorePurchasePort();

  @override
  Stream<IOSPurchaseUpdate> get purchaseUpdates => const Stream.empty();

  @override
  Future<void> completePurchase(String purchaseKey) async {}

  @override
  Future<List<IOSStoreProduct>> loadProducts(Set<String> productIds) async =>
      const <IOSStoreProduct>[];

  @override
  Future<bool> purchase({
    required String productId,
    required String appAccountToken,
  }) async => false;

  @override
  Future<void> restorePurchases() async {}
}

final class _VisualVoiceRecorder
    implements VoiceRecorderPort, VoiceRecorderLevelSource {
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();

  @override
  Stream<VoiceLevelSample> get levelSamples => const Stream.empty();

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async => VoiceRecorderResult.success(
    const VoiceRecorderPermission(
      state: VoiceRecorderPermissionState.granted,
      canAskAgain: false,
    ),
  );

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() => getMicrophonePermission();

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    final session = VoiceRecordingSession(
      recordingId: 'm06-voiceprint',
      scene: scene,
      state: VoiceRecorderState.recording,
      startedAt: DateTime.utc(2026, 8, 24),
    );
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() {
    throw UnimplementedError();
  }
}
