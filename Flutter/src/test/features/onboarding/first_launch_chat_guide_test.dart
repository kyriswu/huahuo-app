import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/onboarding/application/first_launch_device_setup_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/first_launch_device_setup_repository.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller.dart';
import 'package:huahuoai_app/features/chat/data/chat_api.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_chat_page.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_onboarding_spotlight.dart';

import 'package:huahuoai_app/app/di/onboarding_providers.dart';
import '../../support/mobile_agent_test_support.dart';

void main() {
  late AppPreferencesDao dao;
  late FirstLaunchDeviceSetupController controller;

  FirstLaunchDeviceSetupRepository repository(String user) =>
      FirstLaunchDeviceSetupRepository(dao: dao, userScope: user);

  void finishDeviceSteps() {
    expect(
      controller.finishPositioning(FirstLaunchStepStatus.submitted),
      isTrue,
    );
    expect(controller.finishVoiceprint(FirstLaunchStepStatus.deferred), isTrue);
    expect(
      controller.finishRecordingCard(FirstLaunchStepStatus.deferred),
      isTrue,
    );
  }

  setUp(() {
    dao = AppPreferencesDao(AppDatabase());
    controller = FirstLaunchDeviceSetupController.accountScoped(
      repositoryForUser: repository,
    );
  });
  tearDown(() => controller.dispose());

  for (final scenario in [
    (name: 'accepted', rejectsFirstRequest: false, failsCheckpoint: false),
    (name: 'retry', rejectsFirstRequest: true, failsCheckpoint: false),
    (
      name: 'checkpoint-retry',
      rejectsFirstRequest: false,
      failsCheckpoint: true,
    ),
  ]) {
    testWidgets('real chat completes the guide after ${scenario.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _GuideSnapshotStore();
      dao = AppPreferencesDao(AppDatabase(snapshotStore: store));
      final journey = FirstLaunchDeviceSetupController.accountScoped(
        repositoryForUser: repository,
      );
      journey.syncAccount(userId: 'chat-new', positioningRequired: true);
      journey.finishPositioning(FirstLaunchStepStatus.submitted);
      journey.finishVoiceprint(FirstLaunchStepStatus.deferred);
      journey.finishRecordingCard(FirstLaunchStepStatus.deferred);
      store.rejectWrites = scenario.failsCheckpoint;
      final api = _GuideChatApi(
        rejectsFirstRequest: scenario.rejectsFirstRequest,
      );
      final chatController = ChatController(api: api, scene: ChatScene.feedAi);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const V3ChatPage(
              startupGuide: true,
              launchMode: ChatLaunchMode.fresh,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...mobileAgentReadyTestOverrides(),
            firstLaunchDeviceSetupControllerProvider.overrideWith(
              (ref) => journey,
            ),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('guide-test-device'),
            feedAiChatControllerProvider.overrideWith((ref) => chatController),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        journey.snapshot.chatGuide,
        scenario.failsCheckpoint
            ? FirstLaunchChatGuideStage.openChat
            : FirstLaunchChatGuideStage.sendMessage,
      );
      expect(api.sent, isEmpty);
      final target = find.byWidgetPredicate(
        (widget) => widget is V3OnboardingSpotlight && widget.visible,
      );
      expect(target, findsOneWidget);
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(api.sent, hasLength(1));
      expect(journey.requiresChatGuide, isTrue);
      if (scenario.rejectsFirstRequest) {
        final retry = find.text('重试');
        expect(retry, findsOneWidget);
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(api.sent, hasLength(2));
        expect(api.sent.first, api.sent.last);
        expect(journey.requiresChatGuide, isTrue);
      }
      api.accept();
      for (var frame = 0; frame < 10 && journey.requiresChatGuide; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 250));
      if (scenario.failsCheckpoint) {
        expect(journey.requiresChatGuide, isTrue);
        expect(find.text('重试保存'), findsOneWidget);
        store.rejectWrites = false;
        await tester.tap(find.text('重试保存'));
        await tester.pump();
      }
      expect(journey.snapshot.chatGuide, FirstLaunchChatGuideStage.completed);
      expect(find.text('这是为你准备的创作开场'), findsWidgets);
      expect(
        find.byKey(const ValueKey('startup-chat-spotlight-2')),
        findsNothing,
      );
      expect(api.sent, hasLength(scenario.rejectsFirstRequest ? 2 : 1));
      expect(
        chatController.state.messages.where(
          (message) => message.role == ChatMessageRole.user,
        ),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('only first-login journey enables step four after recording card', () {
    controller.syncAccount(userId: 'existing');
    expect(controller.snapshot.hasChatGuide, isFalse);
    expect(controller.requiresChatGuide, isFalse);
    controller.syncAccount(userId: 'new', positioningRequired: true);
    expect(controller.snapshot.hasChatGuide, isTrue);
    expect(controller.requiresChatGuide, isFalse);
    expect(controller.requiresBlockingJourney, isTrue);
    expect(
      controller.openChatGuide(
        expectedAccountRevision: controller.accountRevision,
      ),
      isFalse,
    );
    controller.finishPositioning(FirstLaunchStepStatus.submitted);
    controller.finishVoiceprint(FirstLaunchStepStatus.deferred);
    expect(controller.phase, FirstLaunchJourneyPhase.recordingCardRequired);
    expect(controller.requiresChatGuide, isFalse);
    controller.finishRecordingCard(FirstLaunchStepStatus.deferred);
    expect(controller.phase, FirstLaunchJourneyPhase.chatRequired);
    expect(controller.requiresBlockingJourney, isFalse);
    expect(controller.allowsHome, isTrue);
  });

  test('opening chat is not completion and both stages persist', () {
    controller.syncAccount(userId: 'new', positioningRequired: true);
    finishDeviceSteps();
    final revision = controller.accountRevision;
    expect(
      controller.completeChatGuide(expectedAccountRevision: revision),
      isFalse,
    );
    expect(controller.openChatGuide(expectedAccountRevision: revision), isTrue);
    expect(
      repository('new').load().chatGuide,
      FirstLaunchChatGuideStage.sendMessage,
    );
    controller.syncAccount(userId: null);
    controller.syncAccount(userId: 'new');
    expect(controller.requiresChatGuide, isTrue);
    expect(
      controller.completeChatGuide(expectedAccountRevision: revision),
      isFalse,
    );
    expect(
      controller.completeChatGuide(
        expectedAccountRevision: controller.accountRevision,
      ),
      isTrue,
    );
    expect(
      repository('new').load().chatGuide,
      FirstLaunchChatGuideStage.completed,
    );
    controller.syncAccount(userId: null);
    controller.syncAccount(userId: 'new', positioningRequired: true);
    expect(controller.phase, FirstLaunchJourneyPhase.completed);
    expect(controller.requiresChatGuide, isFalse);
  });

  test('skip is persistent and cannot re-enable the guide', () {
    controller.syncAccount(userId: 'new', positioningRequired: true);
    finishDeviceSteps();
    expect(controller.skipChatGuide(), isTrue);
    controller.syncAccount(userId: null);
    controller.syncAccount(userId: 'new', positioningRequired: true);
    expect(controller.snapshot.chatGuide, FirstLaunchChatGuideStage.skipped);
    expect(
      controller.openChatGuide(
        expectedAccountRevision: controller.accountRevision,
      ),
      isFalse,
    );
    expect(
      repository('new').save(
        snapshot: controller.snapshot.copyWith(
          chatGuide: FirstLaunchChatGuideStage.openChat,
        ),
        updatedAt: DateTime.now(),
      ),
      isFalse,
    );
  });

  test(
    'late accepted response from another account cannot complete a guide',
    () {
      controller.syncAccount(userId: 'first', positioningRequired: true);
      finishDeviceSteps();
      final revision = controller.accountRevision;
      controller.openChatGuide(expectedAccountRevision: revision);
      controller.syncAccount(userId: 'second', positioningRequired: true);
      finishDeviceSteps();
      controller.openChatGuide(
        expectedAccountRevision: controller.accountRevision,
      );
      expect(
        controller.completeChatGuide(expectedAccountRevision: revision),
        isFalse,
      );
      expect(
        repository('first').load().chatGuide,
        FirstLaunchChatGuideStage.sendMessage,
      );
      expect(
        repository('second').load().chatGuide,
        FirstLaunchChatGuideStage.sendMessage,
      );
    },
  );

  test('v4 completed and unfinished accounts never receive the new guide', () {
    final now = DateTime.utc(2026, 9, 8);
    for (final finished in [false, true]) {
      final user = 'legacy-$finished';
      final legacy = FirstLaunchDeviceSetupSnapshot(
        positioning: FirstLaunchStepSnapshot(
          status: FirstLaunchStepStatus.submitted,
          updatedAt: now,
        ),
        voiceprint: FirstLaunchStepSnapshot(
          status: FirstLaunchStepStatus.deferred,
          updatedAt: now,
        ),
        recordingCard: FirstLaunchStepSnapshot(
          status: finished
              ? FirstLaunchStepStatus.deferred
              : FirstLaunchStepStatus.active,
          updatedAt: now,
        ),
      );
      dao.upsertValue(
        preferenceKey: repository(user).preferenceKey,
        value: jsonEncode({
          'version': 4,
          'positioning': legacy.positioning.toJson(),
          'voiceprint': legacy.voiceprint.toJson(),
          'recordingCard': legacy.recordingCard.toJson(),
        }),
        updatedAt: now.toIso8601String(),
      );
      controller.syncAccount(userId: user, positioningRequired: true);
      if (!finished) {
        controller.finishRecordingCard(FirstLaunchStepStatus.deferred);
      }
      expect(controller.phase, FirstLaunchJourneyPhase.completed);
      expect(controller.snapshot.hasChatGuide, isFalse);
      expect(
        repository(user).load().chatGuide,
        FirstLaunchChatGuideStage.disabled,
      );
    }
  });
}

class _GuideSnapshotStore extends LocalDatabaseSnapshotStore {
  _GuideSnapshotStore()
    : super(file: File('/tmp/huahuo-chat-guide-audit-unused.json'));

  bool rejectWrites = false;

  @override
  LocalDatabaseSnapshot? load() => null;

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    if (rejectWrites) throw StateError('Simulated checkpoint write failure');
  }
}

class _GuideChatApi extends Fake implements ChatRepository {
  _GuideChatApi({this.rejectsFirstRequest = false});

  final bool rejectsFirstRequest;
  final sent = <String>[];
  final _response = Completer<ApiResult<ChatTextMutation>>();
  final _thread = const ChatThread(
    threadId: 'guide-thread',
    scene: ChatScene.feedAi,
  );
  final _assistant = const ChatMessage(
    messageId: 'guide-assistant',
    threadId: 'guide-thread',
    scene: ChatScene.feedAi,
    role: ChatMessageRole.assistant,
    contentType: ChatMessageContentType.text,
    status: 'sent',
    textPreview: '这是为你准备的创作开场',
  );

  ChatMessage get _user => ChatMessage(
    messageId: 'guide-user',
    threadId: 'guide-thread',
    scene: ChatScene.feedAi,
    role: ChatMessageRole.user,
    contentType: ChatMessageContentType.text,
    status: 'sent',
    textPreview: sent.last,
  );

  ApiResult<T> _success<T>(T data) => ApiResult<T>.success(
    data: data,
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  void accept() => _response.complete(
    _success(ChatTextMutation(message: _user, assistantMessage: _assistant)),
  );

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => _success(_thread);

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async => _success(const ChatThreadPage(items: []));

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async => _success(
    ChatThreadDetail(
      thread: _thread,
      messages: _response.isCompleted ? [_user, _assistant] : [],
    ),
  );

  @override
  Future<ApiResult<ChatTextMutation>> sendTextMessage({
    required String threadId,
    required ChatScene scene,
    required String content,
    String? contentLineId,
    ChatContextEnvelope? context,
    String? agentProfileId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    sent.add(content);
    if (rejectsFirstRequest && sent.length == 1) {
      return Future.value(
        ApiResult<ChatTextMutation>.failure(
          error: chatApiFailure('VALIDATION_ERROR'),
          status: 400,
          idempotencyStore: idempotencyStore,
        ),
      );
    }
    return _response.future;
  }
}
