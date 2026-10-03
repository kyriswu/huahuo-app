import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/navigation/app_routes.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/settings/application/settings_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/voiceprint_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/user_profile_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/profile_capability_ports.dart';
import 'package:huahuoai_app/features/ui_v3/data/voiceprint_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/voiceprint_profile_repository.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_account_profile_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_chat_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_profile_side_panel.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_voiceprint_page.dart';

import '../../support/mobile_agent_test_support.dart';

void main() {
  testWidgets('production avatar history returns through every parent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/history-origin',
      observers: [appRouteObserver],
      routes: [
        GoRoute(
          path: '/history-origin',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => showV3ProfileSidePanel(context),
              child: const Text('打开我的面板'),
            ),
          ),
        ),
        ...buildAppRoutes(
          splashBuilder: (context, state) => const SizedBox.shrink(),
          restoreFailedBuilder: (context, state) => const SizedBox.shrink(),
          workspaceRetryBuilder: (context, state) => const SizedBox.shrink(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(_ProfileHistoryChatApi()),
          resolvedDeviceIdProvider.overrideWithValue('profile-history-device'),
          userProfilePortProvider.overrideWith(
            (ref) => SessionMockUserProfilePort(),
          ),
          voiceRecorderPortProvider.overrideWithValue(_WidgetVoiceRecorder()),
          voiceprintPortProvider.overrideWithValue(_testVoiceprintPort()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开我的面板'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('profile-header-account-entry')),
    );
    await tester.pumpAndSettle();
    final historyEntry = find.byKey(
      const ValueKey('account-service-conversation-history'),
    );
    await tester.scrollUntilVisible(
      historyEntry,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    final accountPosition = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final accountOffset = accountPosition.pixels;
    await tester.tap(historyEntry);
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('chat-history-search'));
    await tester.enterText(search, '历史');
    await tester.pumpAndSettle();

    for (final threadId in ['history-general', 'history-positioning']) {
      await tester.tap(find.byKey(ValueKey('chat-history-row-$threadId')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('chat-assistant-markdown-reply-$threadId')),
        findsOneWidget,
      );
      expect(find.textContaining('原始历史回复', findRichText: true), findsWidgets);
      expect(
        GoRouterState.of(
          tester.element(find.byType(V3ChatPage)),
        ).uri.queryParameters['threadId'],
        threadId,
      );
      if (threadId == 'history-general') {
        await tester.tap(find.byTooltip('新建会话'));
        await tester.pumpAndSettle();
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(search, findsOneWidget);
      expect(tester.widget<TextField>(search).controller!.text, '历史');
      expect(
        GoRouterState.of(
          tester.element(find.byType(V3ChatPage)),
        ).uri.queryParameters['history'],
        '1',
      );
    }

    await tester.tap(find.byKey(const ValueKey('chat-history-back')));
    await tester.pumpAndSettle();
    expect(find.byType(V3AccountProfilePage), findsOneWidget);
    expect(historyEntry.hitTestable(), findsOneWidget);
    expect(accountPosition.pixels, closeTo(accountOffset, 1));
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('v3-profile-side-panel')), findsOneWidget);
    expect(router.canPop(), isTrue);
    await tester.tap(find.byKey(const ValueKey('profile-panel-close')));
    await tester.pumpAndSettle();
    expect(find.text('打开我的面板'), findsOneWidget);
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account page exposes services and persists avatar selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sessionStore = _sessionStore();
    final voiceprintController = VoiceprintController(
      recorder: _WidgetVoiceRecorder(),
      port: _testVoiceprintPort(),
      initialUserId: 'profile-widget-user',
      profileRepository: VoiceprintProfileRepository(
        dao: UserMetadataDao(AppDatabase()),
        userScope: 'profile-widget-user',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          userProfilePortProvider.overrideWith(
            (ref) => SessionMockUserProfilePort(),
          ),
          voiceprintControllerProvider.overrideWith(
            (ref) => voiceprintController,
          ),
        ],
        child: const MaterialApp(home: V3AccountProfilePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('账号与服务'), findsOneWidget);
    expect(find.text('138****8000'), findsOneWidget);
    expect(find.text('无限花火会员'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-usage-panel')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('account-service-conversation-history')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('声纹识别'), findsOneWidget);
    expect(find.text('录音文件'), findsOneWidget);
    expect(find.text('独白 · 内录 · 外录'), findsOneWidget);
    expect(find.text('对话记录'), findsOneWidget);
    expect(find.text('回收站'), findsNothing);
    expect(find.byKey(const ValueKey('account-service-trash')), findsNothing);
    expect(find.text('日报提醒'), findsNothing);
    expect(
      find.byKey(const ValueKey('account-service-daily-reminder')),
      findsNothing,
    );
    expect(find.text('未录入'), findsOneWidget);
    final voiceprintRow = find.byKey(
      const ValueKey('account-service-voiceprint'),
    );
    final recordingsRow = find.byKey(
      const ValueKey('account-service-recordings'),
    );
    final conversationRow = find.byKey(
      const ValueKey('account-service-conversation-history'),
    );
    expect(
      tester.getTopLeft(recordingsRow).dy,
      greaterThan(tester.getTopLeft(voiceprintRow).dy),
    );
    expect(
      tester.getTopLeft(recordingsRow).dy,
      lessThan(tester.getTopLeft(conversationRow).dy),
    );

    final nicknameButton = find.byKey(
      const ValueKey('profile-nickname-button'),
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 1600));
    await tester.pumpAndSettle();
    expect(nicknameButton, findsOneWidget);
    expect(tester.getSize(nicknameButton), const Size(44, 44));
    final semantics = tester.ensureSemantics();
    try {
      expect(find.bySemanticsLabel('修改昵称'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
    await tester.tap(nicknameButton);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-nickname-input')),
      '新的昵称',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('新的昵称'), findsOneWidget);
    expect(find.text('昵称已更新'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(V3AccountProfilePage)),
    );
    expect(
      container.read(userProfileControllerProvider).state.profile.nickname,
      '新的昵称',
    );

    await tester.tap(find.byKey(const ValueKey('profile-avatar-button')));
    await tester.pumpAndSettle();
    expect(find.text('从相册选择'), findsOneWidget);
    await tester.tap(find.text('从相册选择'));
    await tester.pumpAndSettle();
    expect(find.textContaining('头像已更新'), findsOneWidget);
  });

  testWidgets(
    'account voiceprint summary excludes demo while loading and on failure',
    (tester) async {
      final database = AppDatabase();
      UserMetadataDao(database).upsertVoiceprintProfile(
        userScope: 'profile-widget-user',
        profileId: 'profile-demo',
        name: '本地演示档案',
        enrolledAt: '2026-07-15T09:00:00.000Z',
        updatedAt: '2026-07-15T09:00:00.000Z',
        isDemo: true,
      );
      final response =
          Completer<VoiceprintPortResult<List<VoiceprintRemoteProfile>>>();
      final controller = VoiceprintController(
        recorder: _WidgetVoiceRecorder(),
        port: _ControlledListVoiceprintPort(response),
        initialUserId: 'profile-widget-user',
        profileRepository: VoiceprintProfileRepository(
          dao: UserMetadataDao(database),
          userScope: 'profile-widget-user',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionStoreProvider.overrideWith((ref) => _sessionStore()),
            userProfilePortProvider.overrideWith(
              (ref) => SessionMockUserProfilePort(),
            ),
            voiceprintControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3AccountProfilePage()),
        ),
      );
      await tester.pump();

      expect(find.text('正在同步'), findsOneWidget);
      expect(find.text('未录入'), findsNothing);
      expect(find.text('已录入'), findsNothing);

      response.complete(VoiceprintPortResult.failure('NETWORK_REQUEST_FAILED'));
      await tester.pumpAndSettle();
      expect(find.text('同步异常'), findsOneWidget);
      expect(find.text('未录入'), findsNothing);
      expect(find.text('已录入'), findsNothing);
    },
  );

  testWidgets('account voiceprint summary reports a real profile as enrolled', (
    tester,
  ) async {
    final database = AppDatabase();
    UserMetadataDao(database).upsertVoiceprintProfile(
      userScope: 'profile-widget-user',
      profileId: 'profile-real',
      name: '我的真实声纹',
      enrolledAt: '2026-07-15T09:00:00.000Z',
      updatedAt: '2026-07-15T09:00:00.000Z',
      isDemo: false,
    );
    final response =
        Completer<VoiceprintPortResult<List<VoiceprintRemoteProfile>>>();
    final controller = VoiceprintController(
      recorder: _WidgetVoiceRecorder(),
      port: _ControlledListVoiceprintPort(response),
      initialUserId: 'profile-widget-user',
      profileRepository: VoiceprintProfileRepository(
        dao: UserMetadataDao(database),
        userScope: 'profile-widget-user',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => _sessionStore()),
          userProfilePortProvider.overrideWith(
            (ref) => SessionMockUserProfilePort(),
          ),
          voiceprintControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: V3AccountProfilePage()),
      ),
    );
    await tester.pump();
    expect(find.text('已录入'), findsOneWidget);
    expect(find.text('未录入'), findsNothing);

    response.complete(
      VoiceprintPortResult.success(<VoiceprintRemoteProfile>[
        VoiceprintRemoteProfile(
          profileId: 'profile-real',
          speakerNick: 'remote-speaker',
          status: VoiceprintRemoteProfileStatus.active,
          referenceVersion: 2,
          registeredAt: DateTime.utc(2026, 7, 15, 9),
          updatedAt: DateTime.utc(2026, 7, 15, 9),
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('已录入'), findsOneWidget);
    expect(find.text('未录入'), findsNothing);
  });

  testWidgets('voiceprint management creates a name before explicit capture', (
    tester,
  ) async {
    final recorder = _WidgetVoiceRecorder();
    final sessionStore = _sessionStore();
    final router = GoRouter(
      initialLocation: '/voiceprint',
      routes: [
        GoRoute(
          path: '/voiceprint',
          builder: (context, state) => const V3VoiceprintPage(),
        ),
        GoRoute(
          path: '/v3/profile/voiceprint/enroll',
          builder: (context, state) => V3VoiceprintPage(
            enrollmentOnly: true,
            initialProfileName: state.uri.queryParameters['name'],
            targetProfileId: state.uri.queryParameters['profileId'],
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          voiceRecorderPortProvider.overrideWithValue(recorder),
          voiceprintPortProvider.overrideWithValue(_testVoiceprintPort()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('声纹属于敏感生物特征'), findsOneWidget);
    expect(find.text('让 AI 认出已录入的声音'), findsOneWidget);
    expect(find.text('说话人 1'), findsOneWidget);
    expect(find.text('我的声纹'), findsOneWidget);
    expect(find.byKey(const ValueKey('voiceprint-help')), findsOneWidget);
    expect(find.textContaining('仅用于辅助识别你的发言'), findsOneWidget);
    expect(find.textContaining('腾讯云'), findsNothing);
    expect(find.textContaining('声纹 ID'), findsNothing);
    expect(find.textContaining('演示声纹'), findsNothing);
    expect(find.text('声纹管理'), findsOneWidget);
    expect(find.text('还没有声纹档案'), findsOneWidget);
    expect(find.textContaining('你好，无限花火'), findsNothing);
    expect(find.text('开始录入'), findsNothing);
    expect(recorder.scene, isNull);

    await tester.tap(find.byKey(const ValueKey('voiceprint-help')));
    await tester.pumpAndSettle();
    expect(find.text('声纹识别使用说明'), findsOneWidget);
    expect(find.textContaining('距离嘴部约 20-40 厘米'), findsOneWidget);
    expect(find.textContaining('录入完成后'), findsOneWidget);
    expect(find.textContaining('上传完成后'), findsNothing);
    expect(recorder.scene, isNull);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('创建首个声纹'));
    await tester.tap(find.text('创建首个声纹'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('voiceprint-name-input')),
      '采访主持人',
    );
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    expect(find.text('录入声纹'), findsOneWidget);
    expect(find.text('准备录入：采访主持人'), findsOneWidget);
    expect(find.text('环境安静'), findsOneWidget);
    expect(find.text('距离 20-40cm'), findsOneWidget);
    expect(find.text('自然朗读'), findsOneWidget);
    expect(find.textContaining('你好，无限花火'), findsOneWidget);
    expect(recorder.scene, isNull);
    await tester.tap(find.text('开始录入'));
    await tester.pump();
    expect(recorder.scene, VoiceRecordingScene.voiceprint);
    expect(find.text('继续朗读'), findsOneWidget);
  });

  testWidgets(
    'profile header and recording-card voiceprint are route entries',
    (tester) async {
      final sessionStore = _sessionStore();
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: () => showV3ProfileSidePanel(context),
                child: const Text('open-profile'),
              ),
            ),
          ),
          GoRoute(
            path: '/v3/profile',
            builder: (context, state) => const V3ProfileHomePage(),
          ),
          GoRoute(
            path: '/v3/profile/account',
            builder: (context, state) =>
                const Scaffold(body: Text('account-route')),
          ),
          GoRoute(
            path: '/v3/profile/voiceprint',
            builder: (context, state) =>
                const Scaffold(body: Text('voiceprint-route')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionStoreProvider.overrideWith((ref) => sessionStore),
            resolvedDeviceIdProvider.overrideWithValue('profile-route-device'),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await tester.tap(find.text('open-profile'));
      await tester.pumpAndSettle();
      expect(find.text('声纹识别'), findsNothing);
      expect(find.text('声纹管理'), findsNothing);
      expect(
        find.byKey(const ValueKey('profile-recording-card-voiceprint')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('profile-header-account-entry')),
      );
      await tester.pumpAndSettle();
      expect(find.text('account-route'), findsOneWidget);
    },
  );

  testWidgets(
    'account security retains phone rebinding and omits retired actions',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionStoreProvider.overrideWith((ref) => _sessionStore()),
            profileAccountSecurityPortProvider.overrideWith(
              (ref) => ProfileAccountSecurityDemoPort(),
            ),
          ],
          child: const MaterialApp(
            home: V3ProfilePlaceholderPage(section: '账号与安全'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final label in const ['手机号换绑', '注销账号']) {
        expect(find.text(label), findsOneWidget);
      }
      for (final key in const ['wechat', 'email', 'password']) {
        expect(find.byKey(ValueKey('account-security-$key')), findsNothing);
      }
      for (final label in const ['微信账号绑定', '邮箱绑定', '密码修改']) {
        expect(find.text(label), findsNothing);
      }
      await tester.tap(find.byKey(const ValueKey('account-security-phone')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-security-phone-input')),
        '13900139000',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('139****9000'), findsOneWidget);
      expect(find.text('手机号已换绑'), findsOneWidget);
    },
  );

  testWidgets('account cancellation is visible but does not fake deletion', (
    tester,
  ) async {
    final sessionStore = _sessionStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionStoreProvider.overrideWith((ref) => sessionStore)],
        child: const MaterialApp(
          home: V3ProfilePlaceholderPage(section: '账号与安全'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(sessionStore.state.authState, SessionAuthState.authenticated);
    await tester.tap(find.byKey(const ValueKey('account-security-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('账号注销服务尚未接入'), findsOneWidget);
    expect(find.textContaining('未向服务端发起请求'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(sessionStore.state.authState, SessionAuthState.authenticated);
    expect(find.textContaining('账号已注销'), findsNothing);
  });

  testWidgets('help feedback and version update expose working interactions', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileSupportPortProvider.overrideWith(
            (ref) => const ProfileSupportDemoPort(),
          ),
        ],
        child: const MaterialApp(
          home: V3ProfilePlaceholderPage(section: '帮助与反馈'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('help-entry-manual')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('help-entry-recording-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('help-entry-customer-service')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('help-upload-bug')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('help-upload-bug')));
    await tester.tap(find.byKey(const ValueKey('help-upload-bug')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('bug-report-description')),
      '打开创作页面后无法继续输入',
    );
    await tester.tap(find.byKey(const ValueKey('bug-report-screenshot')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bug-report-screenshot')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bug-report-screenshot')));
    await tester.pump();
    expect(find.text('已添加 3 / 3'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bug-report-remove-screenshot-2')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('bug-report-remove-screenshot-2')),
    );
    await tester.pump();
    expect(find.text('已添加 2 / 3'), findsOneWidget);
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bug 已提交'), findsOneWidget);

    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('settings-provider-scope'),
        overrides: [
          profileVersionPortProvider.overrideWith((ref) => _testVersionPort()),
        ],
        child: const MaterialApp(home: V3ProfilePlaceholderPage(section: '设置')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-account-security')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-help')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-feedback')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-appearance-card')),
      findsOneWidget,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -520));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-version')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-about')), findsOneWidget);

    await tester.pumpWidget(
      const ProviderScope(
        key: ValueKey('appearance-provider-scope'),
        child: MaterialApp(home: V3ProfilePlaceholderPage(section: '外观与显示')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-appearance-card')),
      findsOneWidget,
    );
    for (final label in const [
      '跟随系统',
      '明亮',
      '暗黑',
      '雾蓝',
      '松绿',
      '暖金',
      '绯樱',
      '极光',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('玻璃透明度'), findsNothing);

    await tester.pumpWidget(
      const ProviderScope(
        key: ValueKey('reminder-provider-scope'),
        child: MaterialApp(home: V3ProfilePlaceholderPage(section: '日报提醒')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-daily-reminder')),
      findsOneWidget,
    );
    final settingsContainer = ProviderScope.containerOf(
      tester.element(find.byKey(const ValueKey('settings-daily-reminder'))),
    );
    expect(
      settingsContainer
          .read(settingsControllerProvider)
          .state
          .dailyReminderEnabled,
      isFalse,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-daily-reminder-switch')),
    );
    await tester.pump();
    expect(
      settingsContainer
          .read(settingsControllerProvider)
          .state
          .dailyReminderEnabled,
      isTrue,
    );

    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('version-provider-scope'),
        overrides: [
          profileVersionPortProvider.overrideWith((ref) => _testVersionPort()),
        ],
        child: const MaterialApp(
          home: V3ProfilePlaceholderPage(section: '版本更新'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-check-update')));
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    expect(find.textContaining('版本检查服务尚未接入'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -90));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-version-introduction')),
    );
    await tester.pumpAndSettle();
    expect(find.text('版本介绍'), findsWidgets);
    expect(
      find.byKey(const ValueKey('settings-version-release-title')),
      findsOneWidget,
    );
    expect(find.textContaining('随安装包离线提供'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
  });

  testWidgets('settings routes account security and help independently', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) =>
              const V3ProfilePlaceholderPage(section: '设置'),
        ),
        GoRoute(
          path: '/v3/profile/voiceprint',
          builder: (context, state) =>
              const Scaffold(body: Text('voiceprint-route')),
        ),
        GoRoute(
          path: '/v3/profile/:section',
          builder: (context, state) => Scaffold(
            body: Text('profile-route-${state.pathParameters['section']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileVersionPortProvider.overrideWith((ref) => _testVersionPort()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final account = find.byKey(const ValueKey('settings-account-security'));
    expect(account, findsOneWidget);
    await tester.tap(account);
    await tester.pumpAndSettle();
    expect(find.text('profile-route-账号与安全'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('settings-help'));
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('profile-route-帮助与反馈'), findsOneWidget);
  });

  testWidgets('diagnostics route copies a redacted user-triggered package', (
    tester,
  ) async {
    String? clipboardText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final arguments = call.arguments! as Map<Object?, Object?>;
        clipboardText = arguments['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: V3ProfilePlaceholderPage(section: '诊断')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('诊断'), findsOneWidget);
    expect(find.textContaining('不包含音频内容'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-diagnostics-export')));
    await tester.pumpAndSettle();

    expect(clipboardText, contains('huahuo.diagnostics.v1'));
    expect(clipboardText, isNot(contains('/Users/')));
    expect(clipboardText, isNot(contains('access_token')));
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('membership page is independent from growth and routes support', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/level',
      routes: [
        GoRoute(
          path: '/level',
          builder: (context, state) =>
              const V3ProfilePlaceholderPage(section: '会员充值'),
        ),
        GoRoute(
          path: '/help/customer-service',
          builder: (context, state) =>
              const Scaffold(body: Text('customer-service-route')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    expect(find.text('无限花火会员'), findsOneWidget);
    expect(find.textContaining('当前等级'), findsNothing);
    expect(find.textContaining('每一次创作'), findsOneWidget);
    expect(find.text('会员商品暂不可用'), findsOneWidget);
    expect(find.text('外部世界容量'), findsNothing);
    expect(find.text('支付服务尚未接入，会员状态未改变'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('billing-purchase-button')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('voiceprint profiles can be renamed and deleted', (tester) async {
    final sessionStore = _sessionStore();
    final database = AppDatabase();
    UserMetadataDao(database).upsertVoiceprintProfile(
      userScope: 'profile-widget-user',
      profileId: 'profile-1',
      name: '主持人',
      enrolledAt: '2026-07-15T09:00:00.000Z',
      updatedAt: '2026-07-15T09:00:00.000Z',
      isDemo: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => sessionStore),
          appDatabaseProvider.overrideWithValue(database),
          voiceprintPortProvider.overrideWithValue(_testVoiceprintPort()),
        ],
        child: const MaterialApp(home: V3VoiceprintPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('主持人'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('voiceprint-profile-more-profile-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('voiceprint-rename-input')),
      '访谈主持人',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('访谈主持人'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('voiceprint-profile-more-profile-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除声纹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('访谈主持人'), findsNothing);
    expect(find.text('声纹管理'), findsOneWidget);
    expect(find.text('创建首个声纹'), findsOneWidget);
  });

  testWidgets(
    'profile sync failure keeps local card and retry only refreshes server list',
    (tester) async {
      final recorder = _WidgetVoiceRecorder();
      final database = AppDatabase();
      final dao = UserMetadataDao(database)
        ..upsertVoiceprintProfile(
          userScope: 'profile-widget-user',
          profileId: 'profile-local-real',
          name: '本地保留声纹',
          enrolledAt: '2026-07-15T09:00:00.000Z',
          updatedAt: '2026-07-15T09:00:00.000Z',
          isDemo: false,
        );
      final port = _FailingListVoiceprintPort();
      final controller = VoiceprintController(
        recorder: recorder,
        port: port,
        initialUserId: 'profile-widget-user',
        profileRepository: VoiceprintProfileRepository(
          dao: dao,
          userScope: 'profile-widget-user',
        ),
      );
      expect(await controller.refreshProfiles(), isFalse);
      expect(port.listCalls, 1);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            voiceprintControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3VoiceprintPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本地保留声纹'), findsOneWidget);
      expect(find.text('暂时无法更新声纹档案，请稍后重试'), findsOneWidget);
      expect(recorder.scene, isNull);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(port.listCalls, 2);
      expect(recorder.scene, isNull);
      expect(find.text('本地保留声纹'), findsOneWidget);
    },
  );

  testWidgets('enrollment route stays in capture with an existing profile', (
    tester,
  ) async {
    final recorder = _WidgetVoiceRecorder();
    final database = AppDatabase();
    UserMetadataDao(database).upsertVoiceprintProfile(
      userScope: 'profile-widget-user',
      profileId: 'profile-existing',
      name: '我的声纹',
      enrolledAt: '2026-07-15T09:00:00.000Z',
      updatedAt: '2026-07-15T09:00:00.000Z',
      isDemo: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => _sessionStore()),
          appDatabaseProvider.overrideWithValue(database),
          voiceRecorderPortProvider.overrideWithValue(recorder),
          voiceprintPortProvider.overrideWithValue(_testVoiceprintPort()),
        ],
        child: const MaterialApp(home: V3VoiceprintPage(enrollmentOnly: true)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('录入声纹'), findsOneWidget);
    expect(find.text('声纹管理'), findsNothing);
    expect(find.textContaining('你好，无限花火'), findsOneWidget);
    await tester.tap(find.text('开始录入'));
    await tester.pump();
    expect(recorder.scene, VoiceRecordingScene.voiceprint);
    expect(find.text('正在录入：我的声纹 2'), findsOneWidget);
  });

  testWidgets('busy enrollment action is truly disabled', (tester) async {
    final permission =
        Completer<VoiceRecorderResult<VoiceRecorderPermission>>();
    final recorder = _WidgetVoiceRecorder(permission: permission.future);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => _sessionStore()),
          voiceRecorderPortProvider.overrideWithValue(recorder),
          voiceprintPortProvider.overrideWithValue(_testVoiceprintPort()),
        ],
        child: const MaterialApp(
          home: V3VoiceprintPage(
            enrollmentOnly: true,
            initialProfileName: '我的声纹',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始录入'));
    await tester.pump();

    final busyButton = find.widgetWithText(FilledButton, '检查麦克风权限');
    expect(busyButton, findsOneWidget);
    expect(tester.widget<FilledButton>(busyButton).onPressed, isNull);

    permission.complete(
      VoiceRecorderResult.success(
        const VoiceRecorderPermission(
          state: VoiceRecorderPermissionState.granted,
          canAskAgain: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
}

ProfileVersionPort _testVersionPort() => ProfileVersionDemoPort(
  delay: Duration.zero,
  installedVersionLoader: () async => ProfileVersionDemoPort.fallbackCurrent,
);

VoiceprintPort _testVoiceprintPort() {
  return SessionMockVoiceprintPort(deleteLocalSample: (_) async => true);
}

SessionStore _sessionStore() {
  return SessionStore(
    secureTokenStore: SecureTokenStore(driver: _MemoryTokenDriver()),
  )..refreshUserStatus(
    status: const SessionUserStatus(
      user: SessionUser(
        userId: 'profile-widget-user',
        maskedPhoneNumber: '138****8000',
        displayName: '初始昵称',
      ),
      workspace: SessionWorkspace(status: SessionWorkspaceStatus.ready),
    ),
    updatedAt: DateTime.utc(2026, 7, 15),
  );
}

final class _ProfileHistoryChatApi extends Fake implements ChatRepository {
  static const general = ChatThread(
    threadId: 'history-general',
    scene: ChatScene.feedAi,
    title: '普通历史记录',
    agentProfileId: standardCreationChatAgentProfileId,
  );
  static const positioning = ChatThread(
    threadId: 'history-positioning',
    scene: ChatScene.feedAi,
    title: '定位历史记录',
    purpose: ChatConversationPurpose.deepPositioning,
    agentProfileId: 'positioning_lv2',
  );

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async => ApiResult.success(
    data: ChatThreadPage(
      items: [
        if (purpose == ChatConversationPurpose.general)
          general
        else
          positioning,
      ],
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async => ApiResult.success(
    data: ChatThreadDetail(
      thread: threadId == general.threadId ? general : positioning,
      messages: [
        ChatMessage(
          messageId: 'user-$threadId',
          threadId: threadId,
          scene: ChatScene.feedAi,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.text,
          status: 'sent',
          textPreview: '历史问题 $threadId',
          createdAt: DateTime.utc(2026, 9, 12, 8),
        ),
        ChatMessage(
          messageId: 'reply-$threadId',
          threadId: threadId,
          scene: ChatScene.feedAi,
          role: ChatMessageRole.assistant,
          contentType: ChatMessageContentType.text,
          status: 'sent',
          textPreview: '原始历史回复 $threadId',
          createdAt: DateTime.utc(2026, 9, 12, 8, 0, 2),
        ),
      ],
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
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

final class _WidgetVoiceRecorder
    implements VoiceRecorderPort, VoiceRecorderLevelSource {
  _WidgetVoiceRecorder({this.permission});

  final Future<VoiceRecorderResult<VoiceRecorderPermission>>? permission;
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  VoiceRecordingScene? scene;

  @override
  Stream<VoiceLevelSample> get levelSamples => const Stream.empty();

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() =>
      permission ??
      Future<VoiceRecorderResult<VoiceRecorderPermission>>.value(
        VoiceRecorderResult.success(
          const VoiceRecorderPermission(
            state: VoiceRecorderPermissionState.granted,
            canAskAgain: false,
          ),
        ),
      );

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() => getMicrophonePermission();

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    this.scene = scene;
    final session = VoiceRecordingSession(
      recordingId: 'widget-voiceprint',
      scene: scene,
      state: VoiceRecorderState.recording,
      startedAt: DateTime.utc(2026, 7, 15),
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

final class _FailingListVoiceprintPort implements VoiceprintPort {
  _FailingListVoiceprintPort()
    : _delegate = SessionMockVoiceprintPort(
        deleteLocalSample: (_) async => true,
      );

  final SessionMockVoiceprintPort _delegate;
  int listCalls = 0;

  @override
  VoiceprintEnrollment? beginSession(String? userId) {
    return _delegate.beginSession(userId);
  }

  @override
  Future<VoiceprintPortResult<List<VoiceprintRemoteProfile>>> listProfiles({
    required String userId,
  }) async {
    listCalls += 1;
    return VoiceprintPortResult.failure('NETWORK_REQUEST_FAILED');
  }

  @override
  Future<VoiceprintPortResult<VoiceprintEnrollment>> enroll({
    required String userId,
    required String profileId,
    required String profileName,
    required VoiceRecordingDraft sample,
    required bool consentAccepted,
    String? replacementProfileId,
  }) {
    return _delegate.enroll(
      userId: userId,
      profileId: profileId,
      profileName: profileName,
      sample: sample,
      consentAccepted: consentAccepted,
      replacementProfileId: replacementProfileId,
    );
  }

  @override
  Future<VoiceprintPortResult<bool>> deleteEnrollment({
    required String userId,
    required String profileId,
  }) {
    return _delegate.deleteEnrollment(userId: userId, profileId: profileId);
  }

  @override
  Future<VoiceprintPortResult<bool>> discardSample(String appPrivateUri) {
    return _delegate.discardSample(appPrivateUri);
  }
}

final class _ControlledListVoiceprintPort implements VoiceprintPort {
  _ControlledListVoiceprintPort(this.response)
    : _delegate = SessionMockVoiceprintPort(
        deleteLocalSample: (_) async => true,
      );

  final Completer<VoiceprintPortResult<List<VoiceprintRemoteProfile>>> response;
  final SessionMockVoiceprintPort _delegate;

  @override
  VoiceprintEnrollment? beginSession(String? userId) {
    return _delegate.beginSession(userId);
  }

  @override
  Future<VoiceprintPortResult<List<VoiceprintRemoteProfile>>> listProfiles({
    required String userId,
  }) {
    return response.future;
  }

  @override
  Future<VoiceprintPortResult<VoiceprintEnrollment>> enroll({
    required String userId,
    required String profileId,
    required String profileName,
    required VoiceRecordingDraft sample,
    required bool consentAccepted,
    String? replacementProfileId,
  }) {
    return _delegate.enroll(
      userId: userId,
      profileId: profileId,
      profileName: profileName,
      sample: sample,
      consentAccepted: consentAccepted,
      replacementProfileId: replacementProfileId,
    );
  }

  @override
  Future<VoiceprintPortResult<bool>> deleteEnrollment({
    required String userId,
    required String profileId,
  }) {
    return _delegate.deleteEnrollment(userId: userId, profileId: profileId);
  }

  @override
  Future<VoiceprintPortResult<bool>> discardSample(String appPrivateUri) {
    return _delegate.discardSample(appPrivateUri);
  }
}
