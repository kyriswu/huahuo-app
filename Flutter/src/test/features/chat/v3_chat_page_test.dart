import 'package:huahuo_foundation/huahuo_foundation.dart' show HuahuoMarkdown;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PanGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/navigation/app_routes.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/features/agent/application/mobile_agent_capability_controller.dart';
import 'package:huahuoai_app/features/agent/data/mobile_agent_capability_port.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller.dart';
import 'package:huahuoai_app/features/chat/application/chat_file_attachment_uploader.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/chat/application/chat_voice_uploader.dart';
import 'package:huahuoai_app/features/chat/application/voice_message_controller.dart';
import 'package:huahuoai_app/features/chat/data/authenticated_resource_image_cache.dart';
import 'package:huahuoai_app/features/chat/data/chat_api.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/data/chat_thread_alias_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';
import 'package:huahuoai_app/features/ui_v3/application/deep_positioning_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_workspace_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_figma_spec.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_surface.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/v3_chat_conversation_timeline.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_chat_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_note_chat.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_chat_mark.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../support/mobile_agent_test_support.dart';
import 'assistant_runtime_test_adapter.dart';

const _longPersonaReplyFinalQuestion = '要不要按照这个视觉参考设计直接生成图片？';

String _longPersonaReply() {
  return '人' * (20561 - _longPersonaReplyFinalQuestion.length) +
      _longPersonaReplyFinalQuestion;
}

void main() {
  test(
    'terminal result recovery copy distinguishes synchronization from execution',
    () {
      final message = chatFailureMessage('CHAT_THREAD_RESULT_SYNC_FAILED');
      expect(message, contains('上一轮已结束'));
      expect(message, contains('再次发送'));
      expect(message, isNot(contains('仍在处理中')));
    },
  );

  testWidgets(
    'shared timeline partial selection supports handles copy paste and full copy',
    (tester) async {
      const userText = 'please compare both choices';
      const reply =
          '## 回复标题\n\nfirst alpha beta gamma\n\n下一段内容\n\n```text\nsample code\n```';
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboardText = (call.arguments as Map)['text'] as String;
              return null;
            case 'Clipboard.getData':
              return <String, Object?>{'text': clipboardText};
            case 'Clipboard.hasStrings':
              return <String, Object>{
                'value': clipboardText?.isNotEmpty ?? false,
              };
            default:
              return null;
          }
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[]),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'partial-selection-user',
      );
      final drafts = ValueNotifier<Map<String, ChatAssistantAnswerDraft>>({});
      final composer = TextEditingController();
      final composerFocus = FocusNode();
      addTearDown(drafts.dispose);
      addTearDown(composer.dispose);
      addTearDown(composerFocus.dispose);
      await tester.pumpWidget(
        _sharedTimelineHarness(
          tracker: tracker,
          timelineKey: const ValueKey('partial-selection-timeline'),
          threadId: 'partial-selection-thread',
          messages: const <ChatMessage>[
            ChatMessage(
              messageId: 'partial-user',
              threadId: 'partial-selection-thread',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: userText,
            ),
            ChatMessage(
              messageId: 'partial-assistant',
              threadId: 'partial-selection-thread',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: reply,
            ),
          ],
          fallbackRunStatuses: const {},
          drafts: drafts,
          bottomNavigationBar: V3ChatInputBar(
            controller: composer,
            focusNode: composerFocus,
            hasText: false,
            isSubmissionInFlight: false,
            isInputBusy: false,
            enabled: true,
            canSubmit: true,
            voicePhase: V3ChatVoiceControlPhase.idle,
            voiceEnabled: false,
            entryMode: false,
            attachments: const [],
            memoryNotes: const [],
            onPlus: () {},
            onRemoveAttachment: (_) {},
            onRetryAttachment: (_) {},
            onPreviewAttachment: (_) {},
            onRemoveMemoryNote: (_) {},
            onVoice: () {},
            onSend: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('first alpha beta gamma'),
          matching: find.byType(RichText),
        ),
      );
      await _doubleTapChatWord(tester, paragraph, 8);
      expect(
        paragraph.selections.single,
        const TextSelection(baseOffset: 6, extentOffset: 11),
      );
      final selectionHandles = find.byWidgetPredicate(
        (widget) =>
            widget is RawGestureDetector &&
            widget.gestures.containsKey(PanGestureRecognizer),
      );
      expect(selectionHandles, findsNWidgets(2));
      final handle = await tester.startGesture(
        tester.getCenter(selectionHandles.last),
      );
      await handle.moveBy(const Offset(24, 0));
      await tester.pump();
      await handle.moveBy(const Offset(75, 0));
      await tester.pump();
      await handle.up();
      await tester.pump(const Duration(milliseconds: 300));
      final selectedRange = paragraph.selections.single;
      expect(selectedRange.start, 6);
      expect(selectedRange.end, greaterThan(11));
      final selectedText = selectedRange.textInside('first alpha beta gamma');
      expect(selectedText, startsWith('alpha beta'));
      final toolbar = find.byType(AdaptiveTextSelectionToolbar);
      expect(
        find.descendant(of: toolbar, matching: find.text('粘贴')),
        findsNothing,
      );
      await tester.tap(find.descendant(of: toolbar, matching: find.text('复制')));
      await tester.pump();
      expect(clipboardText, selectedText);

      await tester.tap(find.byKey(const ValueKey('chat-composer')));
      await tester.pump();
      final input = tester.state<EditableTextState>(find.byType(EditableText));
      await input.pasteText(SelectionChangedCause.toolbar);
      await tester.pump();
      expect(composer.text, selectedText);
      composerFocus.unfocus();
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('chat-copy-partial-assistant')),
      );
      await tester.pump();
      expect(clipboardText, reply);

      final userParagraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text(userText),
          matching: find.byType(RichText),
        ),
      );
      await _doubleTapChatWord(tester, userParagraph, 9);
      await tester.tap(find.descendant(of: toolbar, matching: find.text('复制')));
      await tester.pump();
      expect(clipboardText, 'compare');

      final selection = tester.state<SelectionAreaState>(
        find.byKey(
          const ValueKey('chat-assistant-selection-partial-assistant'),
        ),
      );
      selection.selectableRegion.selectAll(SelectionChangedCause.toolbar);
      await tester.pump();
      selection.selectableRegion.contextMenuButtonItems
          .singleWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();
      expect(clipboardText, contains('sample code'));
      expect(clipboardText, contains('下一段内容'));
      expect(clipboardText, isNot(contains(userText)));
      expect(clipboardText, isNot(contains('回复时间未知')));
      expect(clipboardText, isNot(contains('复制')));

      drafts.value = const <String, ChatAssistantAnswerDraft>{
        'stream-partial-run': ChatAssistantAnswerDraft(
          visibleText: 'visible alpha',
          targetText: 'visible alpha hidden target',
          source: ChatAssistantAnswerDraftSource.transportDelta,
        ),
      };
      await tester.pumpWidget(
        _sharedTimelineHarness(
          tracker: tracker,
          timelineKey: const ValueKey('partial-selection-timeline'),
          threadId: 'partial-selection-thread',
          messages: const <ChatMessage>[
            ChatMessage(
              messageId: 'partial-user',
              threadId: 'partial-selection-thread',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: userText,
            ),
            ChatMessage(
              messageId: 'stream-partial-run',
              threadId: 'partial-selection-thread',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'streaming',
              agentRunId: 'partial-run',
              textPreview: 'visible alpha hidden target',
            ),
          ],
          fallbackRunStatuses: const {'partial-run': 'running'},
          fallbackToolRunId: 'partial-run',
          drafts: drafts,
          isSending: true,
          threadPending: true,
        ),
      );
      await tester.pump();
      final draftSelection = tester.state<SelectionAreaState>(
        find.byKey(
          const ValueKey('chat-assistant-selection-stream-partial-run'),
        ),
      );
      draftSelection.selectableRegion.selectAll(SelectionChangedCause.toolbar);
      await tester.pump();
      draftSelection.selectableRegion.contextMenuButtonItems
          .singleWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();
      expect(clipboardText, 'visible alpha');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final usesVoice in <bool>[false, true]) {
    testWidgets(
      usesVoice
          ? 'deep positioning route reuses live dictation and sends only on request'
          : 'deep positioning route rotates and submits relevant suggested questions',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = _WidgetChatApi(listedThreads: const <ChatThread>[]);
        final recorder = _ChatLiveRecorder();
        final asr = _ChatLiveAsrPort();
        addTearDown(asr.close);
        final liveTranscript = LiveTranscriptController(
          credentialPort: const _ChatLiveCredentialPort(),
          asrPort: asr,
        );
        final router = GoRouter(
          initialLocation:
              '/v3/feed/chat?skill=social-positioning&purpose=deep-positioning',
          routes: buildAppRoutes(
            splashBuilder: (context, state) => const SizedBox.shrink(),
            restoreFailedBuilder: (context, state) => const SizedBox.shrink(),
            workspaceRetryBuilder: (context, state) => const SizedBox.shrink(),
          ),
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              ...mobileAgentReadyTestOverrides(),
              chatRepositoryProvider.overrideWithValue(api),
              resolvedDeviceIdProvider.overrideWithValue('positioning-device'),
              authenticatedUserDataScopeProvider.overrideWithValue(
                'positioning-user',
              ),
              feedAiChatControllerProvider.overrideWith(
                (ref) => throw StateError(
                  'Must not bind the ordinary Chat controller',
                ),
              ),
              voiceRecorderPortProvider.overrideWithValue(recorder),
              liveTranscriptControllerProvider.overrideWith(
                (ref) => liveTranscript,
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Hello，我是深度定位 Agent'), findsOneWidget);
        expect(find.text('还不确定服务谁时，应该怎样缩小目标人群？'), findsOneWidget);
        expect(api.sentContents, isEmpty);

        if (usesVoice) {
          await tester.tap(find.byTooltip('开始实时转写'));
          await tester.pump();
          await tester.pump();
          expect(recorder.startedScenes, <VoiceRecordingScene>[
            VoiceRecordingScene.monologue,
          ]);
          expect(
            liveTranscript.state.status,
            LiveTranscriptStatus.transcribing,
          );
          expect(find.text('正在实时转写'), findsNothing);
          expect(find.text('正在转写，可继续说…'), findsOneWidget);
          expect(find.byTooltip('结束实时转写'), findsOneWidget);
          expect(find.byTooltip('结束转写并编辑'), findsNothing);
          expect(find.byTooltip('取消录制'), findsNothing);
          asr.add(
            LiveTranscriptSentence(
              sentenceId: 1,
              text: '帮我梳理面向客户的独特价值',
              stable: true,
            ),
          );
          await tester.pump();
          final transcribingComposer = tester.widget<TextField>(
            find.byKey(const ValueKey('chat-composer')),
          );
          expect(transcribingComposer.readOnly, isTrue);
          expect(transcribingComposer.controller?.text, '帮我梳理面向客户的独特价值');
          expect(find.text('正在实时转写'), findsNothing);
          await tester.tap(find.byTooltip('结束实时转写'));
          await tester.pumpAndSettle();
          expect(recorder.cancelCalls, 1);
          expect(api.voiceMessageCalls, 0);
          expect(api.sentContents, isEmpty);
          final composer = tester.widget<TextField>(find.byType(TextField));
          expect(composer.readOnly, isFalse);
          expect(composer.controller?.text, '帮我梳理面向客户的独特价值');
          await tester.tap(find.byKey(const ValueKey('chat-composer-send')));
          await tester.pumpAndSettle();
          expect(api.sentContents, <String>['帮我梳理面向客户的独特价值']);
        } else {
          await tester.tap(
            find.byKey(const ValueKey('chat-entry-refresh-suggestions')),
          );
          await tester.pump();
          expect(find.text('怎样把专业能力转成用户能感知的价值？'), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('chat-entry-refresh-suggestions')),
          );
          await tester.pump();
          expect(find.text('怎样选择长期内容支柱，避免定位越做越散？'), findsOneWidget);
          await tester.tap(find.text('定位确定前，最值得做的低成本验证有哪些？'));
          await tester.pumpAndSettle();
          expect(api.sentContents, <String>['定位确定前，最值得做的低成本验证有哪些？']);
        }
        expect(api.sentAgentProfileIds, <String?>['positioning_lv2']);
        expect(
          api.sentContexts.single?.purpose,
          ChatContextPurpose.socialPositioning,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('conversation history shows and searches safe source labels', (
    tester,
  ) async {
    final threads = <ChatThread>[
      const ChatThread(
        threadId: 'ordinary-history',
        scene: ChatScene.feedAi,
        title: '普通会话',
        agentProfileId: standardCreationChatAgentProfileId,
      ),
      const ChatThread(
        threadId: 'persona-history',
        scene: ChatScene.feedAi,
        title: '人设梳理',
        agentProfileId: 'renshe_content',
      ),
      const ChatThread(
        threadId: 'lead-history',
        scene: ChatScene.feedAi,
        title: '营销复盘',
        agentProfileId: 'huoke_content',
      ),
      const ChatThread(
        threadId: 'unknown-history',
        scene: ChatScene.feedAi,
        title: '跨端旧会话',
      ),
    ];
    ChatThread? moreThread;

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: V3ChatHistorySurface(
          threads: threads,
          loading: false,
          onBack: () {},
          onNewConversation: () {},
          onSelect: (_) {},
          onMore: (thread) => moreThread = thread,
        ),
      ),
    );

    expect(find.text('对话记录'), findsOneWidget);
    expect(find.text('普通聊一聊'), findsOneWidget);
    expect(find.text('个人 IP'), findsOneWidget);
    expect(find.text('获客营销'), findsOneWidget);
    expect(find.text('来源待同步'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('chat-history-search')),
      '获客营销',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('chat-history-row-lead-history')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chat-history-row-ordinary-history')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('chat-history-more-lead-history')),
    );
    expect(moreThread?.threadId, 'lead-history');
  });

  testWidgets(
    'account history merges both purposes and routes deep history directly',
    (tester) async {
      final generalApi = _WidgetChatApi(
        listedThreads: <ChatThread>[
          ChatThread(
            threadId: 'general-latest',
            scene: ChatScene.feedAi,
            title: '普通记录',
            firstUserMessageText: '普通问题',
            updatedAt: DateTime.utc(2026, 9, 2, 12),
            agentProfileId: standardCreationChatAgentProfileId,
          ),
          ChatThread(
            threadId: 'shared-history',
            scene: ChatScene.feedAi,
            title: '重复记录',
            firstUserMessageText: '重复问题',
            updatedAt: DateTime.utc(2026, 9, 2, 10),
            agentProfileId: standardCreationChatAgentProfileId,
          ),
        ],
      );
      final deepApi = _WidgetChatApi(
        listedThreads: <ChatThread>[
          ChatThread(
            threadId: 'deep-middle',
            scene: ChatScene.feedAi,
            title: '深度定位记录',
            firstUserMessageText: '继续定位',
            updatedAt: DateTime.utc(2026, 9, 2, 11),
            purpose: ChatConversationPurpose.deepPositioning,
            agentProfileId: 'positioning_lv2',
          ),
          ChatThread(
            threadId: 'shared-history',
            scene: ChatScene.feedAi,
            title: '重复记录',
            firstUserMessageText: '重复问题',
            updatedAt: DateTime.utc(2026, 9, 2, 10),
            purpose: ChatConversationPurpose.deepPositioning,
            agentProfileId: 'positioning_lv2',
          ),
        ],
      );
      final generalController = ChatController(
        api: generalApi,
        scene: ChatScene.feedAi,
      );
      final deepController = ChatController(
        api: deepApi,
        scene: ChatScene.feedAi,
        conversationPurpose: ChatConversationPurpose.deepPositioning,
      );
      Uri? destinationUri;
      final router = GoRouter(
        initialLocation: '/v3/feed/chat?history=1',
        routes: <RouteBase>[
          GoRoute(
            path: '/v3/feed/chat',
            builder: (context, state) {
              if (state.uri.queryParameters['threadId'] != null) {
                destinationUri = state.uri;
                return const Scaffold(body: Text('已进入精确会话'));
              }
              return const V3ChatPage(
                showHistoryOnStart: true,
                launchMode: ChatLaunchMode.history,
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            feedAiChatControllerProvider.overrideWith(
              (ref) => generalController,
            ),
            deepPositioningChatControllerProvider.overrideWith(
              (ref) => deepController,
            ),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp.router(
            theme: HuahuoV3Theme.light(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(generalApi.listPurposes, <ChatConversationPurpose>[
        ChatConversationPurpose.general,
      ]);
      expect(deepApi.listPurposes, <ChatConversationPurpose>[
        ChatConversationPurpose.deepPositioning,
      ]);
      expect(
        find.byKey(const ValueKey('chat-history-row-general-latest')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-history-row-deep-middle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-history-row-shared-history')),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('chat-history-row-general-latest')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('chat-history-row-deep-middle')),
              )
              .dy,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('chat-history-row-deep-middle')),
      );
      await tester.pumpAndSettle();

      final location = destinationUri!;
      expect(location.queryParameters['threadId'], 'deep-middle');
      expect(location.queryParameters['purpose'], 'deep-positioning');
      expect(location.queryParameters['agentProfileId'], 'positioning_lv2');
      expect(generalApi.detailThreadIds, isEmpty);
      expect(find.text('已进入精确会话'), findsOneWidget);
    },
  );

  testWidgets('ordinary account history route carries explicit purpose', (
    tester,
  ) async {
    final generalApi = _WidgetChatApi(
      listedThreads: <ChatThread>[
        ChatThread(
          threadId: 'general-exact',
          scene: ChatScene.feedAi,
          title: '普通记录',
          firstUserMessageText: '普通问题',
          updatedAt: DateTime.utc(2026, 9, 2, 12),
          agentProfileId: standardCreationChatAgentProfileId,
        ),
      ],
    );
    final generalController = ChatController(
      api: generalApi,
      scene: ChatScene.feedAi,
    );
    final deepController = ChatController(
      api: _WidgetChatApi(listedThreads: const <ChatThread>[]),
      scene: ChatScene.feedAi,
      conversationPurpose: ChatConversationPurpose.deepPositioning,
    );
    Uri? destinationUri;
    final router = GoRouter(
      initialLocation: '/v3/feed/chat?history=1',
      routes: <RouteBase>[
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) {
            if (state.uri.queryParameters['threadId'] != null) {
              destinationUri = state.uri;
              return const Scaffold(body: Text('已进入普通精确会话'));
            }
            return const V3ChatPage(
              showHistoryOnStart: true,
              launchMode: ChatLaunchMode.history,
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          feedAiChatControllerProvider.overrideWith((ref) => generalController),
          deepPositioningChatControllerProvider.overrideWith(
            (ref) => deepController,
          ),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp.router(
          theme: HuahuoV3Theme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('chat-history-row-general-exact')),
    );
    await tester.pumpAndSettle();

    final location = destinationUri!;
    expect(location.queryParameters['threadId'], 'general-exact');
    expect(location.queryParameters['purpose'], 'general');
    expect(
      location.queryParameters['agentProfileId'],
      standardCreationChatAgentProfileId,
    );
    expect(generalApi.detailThreadIds, isEmpty);
  });

  test('Chat purpose is normalized to the selected Agent Profile', () {
    expect(
      resolveChatConversationPurposeForAgent(
        requestedPurpose: ChatConversationPurpose.deepPositioning,
        agentProfileId: 'video_analysis',
      ),
      ChatConversationPurpose.general,
    );
    expect(
      resolveChatConversationPurposeForAgent(
        requestedPurpose: ChatConversationPurpose.general,
        agentProfileId: 'positioning_lv2',
      ),
      ChatConversationPurpose.deepPositioning,
    );
    expect(
      resolveChatConversationPurposeForAgent(
        requestedPurpose: ChatConversationPurpose.deepPositioning,
      ),
      ChatConversationPurpose.deepPositioning,
    );
  });

  testWidgets('Assistant reply actions share one text and icon scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3AssistantResponseAction(
            width: 50,
            tooltip: '保存为笔记',
            icon: Icons.bookmark_add_outlined,
            label: '保存',
            onPressed: () {},
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('保存'));
    final icon = tester.widget<Icon>(find.byIcon(Icons.bookmark_add_outlined));
    expect(label.style?.fontSize, 12);
    expect(label.style?.fontWeight, FontWeight.w500);
    expect(icon.size, 16);
    expect(find.byType(FittedBox), findsNothing);
    expect(tester.getSize(find.byType(TextButton)), const Size(50, 48));
    expect(
      tester.getSemantics(find.bySemanticsLabel('保存为笔记')).rect.size,
      const Size(50, 48),
    );
    final labels = await labeledTapTargetGuideline.evaluate(tester);
    expect(labels.passed, isTrue, reason: labels.reason);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: V3AssistantResponseAction(
            width: 50,
            tooltip: '保存为笔记',
            icon: Icons.bookmark_add_outlined,
            label: '保存',
            onPressed: null,
          ),
        ),
      ),
    );
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
  });

  testWidgets('finished execution process marks every step completed', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: V3ChatExecutionProcess(
            kind: V3ChatExecutionKind.noteLibrary,
            activeStep: 2,
            finished: true,
          ),
        ),
      ),
    );

    expect(find.text('已完成'), findsNWidgets(3));
    expect(find.text('进行中'), findsNothing);
    expect(find.text('等待中'), findsNothing);
  });

  for (final fixture
      in <
        ({
          String agentProfileId,
          WorkbenchChatSkill skill,
          String title,
          String greeting,
          String firstQuestion,
          String rotatedQuestion,
          ChatContextPurpose purpose,
        })
      >[
        (
          agentProfileId: 'renshe_content',
          skill: WorkbenchChatSkill.persona,
          title: '个人 IP',
          greeting: 'Hello，我是个人 IP Agent',
          firstQuestion: '个人 IP 定位，应先明确能力还是受众？',
          rotatedQuestion: '怎样形成稳定又不刻意的人设表达？',
          purpose: ChatContextPurpose.persona,
        ),
        (
          agentProfileId: 'huoke_content',
          skill: WorkbenchChatSkill.lead,
          title: '获客营销',
          greeting: 'Hello，我是获客营销 Agent',
          firstQuestion: '怎样区分客户的表面需求和真实购买动机？',
          rotatedQuestion: '如何用内容验证目标客户是否值得重点投入？',
          purpose: ChatContextPurpose.lead,
        ),
        (
          agentProfileId: 'visual_chat',
          skill: WorkbenchChatSkill.visualDesign,
          title: '视觉设计',
          greeting: 'Hello，我是视觉参考 Agent',
          firstQuestion: '口播视频怎样搭配道具、灯光和拍摄场景？',
          rotatedQuestion: '不同内容主题适合怎样的色彩和字体风格？',
          purpose: ChatContextPurpose.visualDesign,
        ),
        (
          agentProfileId: 'video_analysis',
          skill: WorkbenchChatSkill.videoAnalysis,
          title: '视频分析',
          greeting: 'Hello，我是视频分析 Agent',
          firstQuestion: '判断短视频开头是否有效，通常看哪些信号？',
          rotatedQuestion: '前五秒怎样建立期待并减少用户划走？',
          purpose: ChatContextPurpose.videoAnalysis,
        ),
      ]) {
    testWidgets(
      'V3 ${fixture.agentProfileId} shows its V5 guide and sends its backend profile',
      (tester) async {
        final api = _WidgetChatApi();
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          initialAgentProfileId: fixture.agentProfileId,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              ...mobileAgentReadyTestOverrides(),
              chatRepositoryProvider.overrideWithValue(api),
              feedAiChatControllerProvider.overrideWith((ref) => controller),
              resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            ],
            child: MaterialApp(
              home: V3ChatPage(
                windowId: 'opening-${fixture.agentProfileId}',
                workbenchContext: WorkbenchChatContext(
                  skill: fixture.skill,
                  materialIds: const <String>[],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text(fixture.title), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('chat-entry-surface')),
          findsOneWidget,
        );
        expect(find.text(fixture.greeting), findsOneWidget);
        expect(find.text(fixture.firstQuestion), findsOneWidget);
        expect(
          find.byKey(
            const ValueKey<String>('chat-entry-suggestion-notePicker'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
          findsNWidgets(2),
        );
        expect(api.createdContentLineIds, isEmpty);
        expect(api.sentContents, isEmpty);

        final visualReferenceHelp = find.byKey(
          const ValueKey<String>('chat-visual-reference-help'),
        );
        if (fixture.skill == WorkbenchChatSkill.visualDesign) {
          expect(visualReferenceHelp, findsOneWidget);
          await tester.tap(visualReferenceHelp);
          await tester.pumpAndSettle();

          final sheet = find.byKey(
            const ValueKey<String>('visual-reference-help-sheet'),
          );
          final confirm = find.byKey(
            const ValueKey<String>('visual-reference-help-confirm'),
          );
          expect(sheet, findsOneWidget);
          expect(tester.getSize(sheet).height, 418);
          expect(
            find.textContaining('提前呈现这条视频需要准备的道具、灯光布局和拍摄场景'),
            findsOneWidget,
          );
          expect(find.text('它不是最终成片，而是一张帮助你准备拍摄的视觉清单。'), findsOneWidget);
          expect(tester.getSize(confirm).height, 48);

          await tester.tap(confirm);
          await tester.pumpAndSettle();
          expect(sheet, findsNothing);
        } else {
          expect(visualReferenceHelp, findsNothing);
        }

        await tester.tap(
          find.byKey(const ValueKey<String>('chat-entry-refresh-suggestions')),
        );
        await tester.pump();
        expect(find.text(fixture.firstQuestion), findsNothing);
        expect(find.text(fixture.rotatedQuestion), findsOneWidget);
        expect(
          find.byKey(
            const ValueKey<String>('chat-entry-suggestion-notePicker'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
          findsNWidgets(2),
        );
        await tester.ensureVisible(find.text(fixture.rotatedQuestion));
        await tester.tap(find.text(fixture.rotatedQuestion));
        await tester.pump();
        await tester.pump();

        expect(api.sentContents, <String>[fixture.rotatedQuestion]);
        expect(api.sentAgentProfileIds, <String?>[fixture.agentProfileId]);
        expect(api.sentContexts.single?.purpose, fixture.purpose);
        expect(api.sentContexts.single?.references, isEmpty);
        expect(
          find.byKey(
            ValueKey<String>(
              'chat-local-agent-opening-${fixture.agentProfileId}',
            ),
          ),
          findsNothing,
        );
        expect(find.byTooltip('复制开场白'), findsNothing);
        expect(find.text(fixture.greeting), findsNothing);
        expect(controller.state.messages.first.role, ChatMessageRole.user);
      },
    );
  }

  testWidgets('visual reference help preserves portrait and compact geometry', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final scenario
        in <({Size size, double textScale, double maxSheetHeight})>[
          (size: const Size(402, 874), textScale: 1, maxSheetHeight: 418),
          (size: const Size(568, 320), textScale: 1.3, maxSheetHeight: 320),
        ]) {
      tester.view.physicalSize = scenario.size;
      final api = _WidgetChatApi();
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        initialAgentProfileId: 'visual_chat',
      )..startNewThread();

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            feedAiChatControllerProvider.overrideWith((ref) => controller),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.textScale)),
              child: child!,
            ),
            home: V3ChatPage(
              windowId: 'visual-reference-help-${scenario.size.height}',
              workbenchContext: WorkbenchChatContext(
                skill: WorkbenchChatSkill.visualDesign,
                materialIds: <String>[],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('chat-visual-reference-help')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('chat-visual-reference-help')),
      );
      await tester.pumpAndSettle();

      final sheet = find.byKey(
        const ValueKey<String>('visual-reference-help-sheet'),
      );
      final title = find.byKey(
        const ValueKey<String>('visual-reference-help-title'),
      );
      final confirm = find.byKey(
        const ValueKey<String>('visual-reference-help-confirm'),
      );
      expect(sheet, findsOneWidget);
      expect(
        tester.getSize(sheet).height,
        scenario.size.height > 418
            ? scenario.maxSheetHeight
            : lessThanOrEqualTo(scenario.maxSheetHeight),
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(title).bottom,
        lessThan(tester.getRect(confirm).top),
      );
      expect(confirm.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
    }
  });

  testWidgets('V3 ordinary Chat uses the canonical identity without a badge', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      initialAgentProfileId: standardCreationChatAgentProfileId,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('聊一聊'), findsOneWidget);
    expect(find.text('标准创作'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('chat-active-agent-badge')),
      findsNothing,
    );
    expect(find.text('普通聊一聊'), findsNothing);
  });

  testWidgets(
    'V3 ordinary Chat replaces an empty server thread with the guided entry',
    (tester) async {
      tester.view
        ..physicalSize = const Size(402, 874)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _WidgetChatApi(
        detailMessages: const <String, List<ChatMessage>>{
          'feed-1': <ChatMessage>[],
        },
        secondThreadAgentProfileId: 'video_analysis',
      );
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        initialAgentProfileId: standardCreationChatAgentProfileId,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            feedAiChatControllerProvider.overrideWith((ref) => controller),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: const MaterialApp(home: V3ChatPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.state.activeThreadId, isNull);
      expect(
        find.byKey(const ValueKey<String>('chat-entry-surface')),
        findsOneWidget,
      );
      expect(find.text('Hello，我是花火 AI'), findsOneWidget);
      expect(find.text('引用一份资产，帮我找到可继续创作的方向'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    },
  );

  testWidgets('V3 cached ordinary Chat keeps its route while reconciling', (
    tester,
  ) async {
    final database = AppDatabase();
    final repository = ChatThreadAliasRepository(
      dao: UserMetadataDao(database),
      preferencesDao: AppPreferencesDao(database),
      userScope: 'widget-canonical-recent-thread-user',
    );
    const threadId = 'ordinary-cached-thread';
    repository.saveConversationCache(
      scene: ChatScene.feedAi,
      purpose: ChatConversationPurpose.general,
      threads: const <ChatThread>[
        ChatThread(
          threadId: threadId,
          scene: ChatScene.feedAi,
          agentProfileId: standardCreationChatAgentProfileId,
        ),
      ],
      messagesByThread: const <String, List<ChatMessage>>{
        threadId: <ChatMessage>[
          ChatMessage(
            messageId: 'ordinary-cached-message',
            threadId: threadId,
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'sent',
            textPreview: '恢复后仍是同一条普通会话。',
          ),
        ],
      },
    );
    final api = _WidgetChatApi();
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      aliasRepository: repository,
      initialAgentProfileId: standardCreationChatAgentProfileId,
    );
    final router = GoRouter(
      initialLocation: '/v3/feed/chat',
      routes: <RouteBase>[
        GoRoute(
          path: '/v3/feed/chat',
          pageBuilder: (context, state) => NoTransitionPage<void>(
            key: state.pageKey,
            child: V3ChatPage(
              key: ValueKey<String>('ordinary-cached-${state.uri}'),
              threadId: state.uri.queryParameters['threadId'],
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          appDatabaseProvider.overrideWithValue(database),
          chatRepositoryProvider.overrideWithValue(api),
          chatThreadAliasRepositoryProvider.overrideWithValue(repository),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      router.routeInformationProvider.value.uri.queryParameters['threadId'],
      isNull,
    );
    expect(find.text('服务器已返回的内容'), findsOneWidget);
    expect(find.text('恢复后仍是同一条普通会话。'), findsNothing);
    expect(api.listThreadCalls, 1);
  });

  testWidgets('V3 standard history excludes other Agent Profiles', (
    tester,
  ) async {
    final api = _WidgetChatApi(secondThreadAgentProfileId: 'video_analysis');
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey<String>('chat-local-agent-opening-video_analysis'),
      ),
      findsNothing,
    );
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('chat-history-row-feed-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-history-row-feed-2')),
      findsNothing,
    );
    expect(find.text('请分析第二次访谈'), findsNothing);
  });

  for (final visualDesignRoute in <String, String>{
    'skill': '/v3/feed/chat?skill=visual-design',
    'profile': '/v3/feed/chat?agentProfileId=visual_chat',
  }.entries) {
    testWidgets(
      'visual-design ${visualDesignRoute.key} route opens specialist Chat',
      (tester) async {
        final api = _WidgetChatApi(listedThreads: const <ChatThread>[]);
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          initialAgentProfileId: standardCreationChatAgentProfileId,
        );
        final router = GoRouter(
          initialLocation: visualDesignRoute.value,
          routes: buildAppRoutes(
            splashBuilder: (context, state) => const SizedBox.shrink(),
            restoreFailedBuilder: (context, state) => const SizedBox.shrink(),
            workspaceRetryBuilder: (context, state) => const SizedBox.shrink(),
          ),
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              ...mobileAgentReadyTestOverrides(),
              chatRepositoryProvider.overrideWithValue(api),
              feedAiChatControllerProvider.overrideWith((ref) => controller),
              resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          router.routeInformationProvider.value.uri.toString(),
          visualDesignRoute.value,
        );
        expect(find.text('Hello，我是视觉参考 Agent'), findsOneWidget);
        expect(find.text('视觉设计'), findsOneWidget);
      },
    );
  }

  testWidgets('V3 persona history contains only persona conversations', (
    tester,
  ) async {
    final api = _WidgetChatApi(secondThreadAgentProfileId: 'renshe_content');
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      initialAgentProfileId: 'renshe_content',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.persona,
              materialIds: <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('chat-history-row-feed-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-history-row-feed-1')),
      findsNothing,
    );
    expect(find.text('请分析第二次访谈'), findsOneWidget);
    expect(find.text('如何整理客户访谈'), findsNothing);
  });

  testWidgets(
    'production video history remains video-scoped after selecting a thread',
    (tester) async {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'widget-video-history-route-scope-user',
      );
      final api = _WidgetChatApi(secondThreadAgentProfileId: 'video_analysis');
      final rootController = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        aliasRepository: repository,
        initialAgentProfileId: standardCreationChatAgentProfileId,
      );
      await rootController.loadThreads();
      expect(
        rootController.historyThreads.map((thread) => thread.threadId),
        <String>['feed-1'],
      );
      final runApi = _WidgetAgentRunApi(
        <Future<ApiResult<AgentRunSnapshot>>>[],
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runApi),
        preferences: AppPreferencesDao(database),
        userScope: 'widget-video-history-route-scope-user',
      );
      final router = GoRouter(
        initialLocation: '/v3/feed/chat?skill=video-analysis',
        routes: buildAppRoutes(
          splashBuilder: (context, state) => const SizedBox.shrink(),
          restoreFailedBuilder: (context, state) => const SizedBox.shrink(),
          workspaceRetryBuilder: (context, state) => const SizedBox.shrink(),
        ),
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            appDatabaseProvider.overrideWithValue(database),
            chatRepositoryProvider.overrideWithValue(api),
            assistantRuntimeProvider.overrideWithValue(
              legacyAssistantRuntime(runApi),
            ),
            chatRunTrackerProvider.overrideWith((ref) => tracker),
            chatThreadAliasRepositoryProvider.overrideWithValue(repository),
            feedAiChatControllerProvider.overrideWith((ref) => rootController),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
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
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('会话列表'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('chat-history-row-feed-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-history-row-feed-1')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('chat-history-row-feed-2')),
      );
      await tester.pumpAndSettle();

      final selectedUri = GoRouterState.of(
        tester.element(find.byType(V3ChatPage)),
      ).uri;
      expect(selectedUri.queryParameters['threadId'], 'feed-2');
      expect(selectedUri.queryParameters['agentProfileId'], 'video_analysis');
      expect(find.text('第二个服务器会话'), findsOneWidget);

      await tester.tap(find.byTooltip('新建会话'));
      await tester.pumpAndSettle();

      final freshUri = GoRouterState.of(
        tester.element(find.byType(V3ChatPage)),
      ).uri;
      expect(freshUri.queryParameters['threadId'], isNull);
      expect(freshUri.queryParameters['window'], isNotEmpty);
      expect(freshUri.queryParameters['agentProfileId'], 'video_analysis');
      expect(find.text('Hello，我是视频分析 Agent'), findsOneWidget);

      await tester.tap(find.byTooltip('会话列表'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('chat-history-row-feed-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-history-row-feed-1')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('chat-history-row-feed-2')),
          matching: find.text('请分析第二次访谈'),
        ),
        findsOneWidget,
      );
    },
  );

  for (final fixture
      in <
        ({
          WorkbenchChatSkill skill,
          String agentProfileId,
          String greeting,
          String headerTitle,
        })
      >[
        (
          skill: WorkbenchChatSkill.persona,
          agentProfileId: 'renshe_content',
          greeting: 'Hello，我是个人 IP Agent',
          headerTitle: '个人 IP',
        ),
        (
          skill: WorkbenchChatSkill.lead,
          agentProfileId: 'huoke_content',
          greeting: 'Hello，我是获客营销 Agent',
          headerTitle: '获客营销',
        ),
        (
          skill: WorkbenchChatSkill.visualDesign,
          agentProfileId: 'visual_chat',
          greeting: 'Hello，我是视觉参考 Agent',
          headerTitle: '视觉设计',
        ),
        (
          skill: WorkbenchChatSkill.videoAnalysis,
          agentProfileId: 'video_analysis',
          greeting: 'Hello，我是视频分析 Agent',
          headerTitle: '视频分析',
        ),
        (
          skill: WorkbenchChatSkill.masterpiece,
          agentProfileId: 'book_writing',
          greeting: 'Hello，我是代表作 Agent',
          headerTitle: '代表作',
        ),
      ]) {
    testWidgets(
      'V3 ${fixture.skill.routeValue} entry starts fresh despite matching history',
      (tester) async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'widget-specialist-entry-${fixture.skill.routeValue}',
        );
        final threadId = '${fixture.skill.routeValue}-durable-history';
        final historyText = '${fixture.skill.label}最近一次历史回复';
        final historyThread = ChatThread(
          threadId: threadId,
          scene: ChatScene.feedAi,
          title: '${fixture.skill.label}历史',
          updatedAt: DateTime.utc(2026, 8, 30),
          agentProfileId: fixture.agentProfileId,
        );
        final historyUser = ChatMessage(
          messageId: '${fixture.skill.routeValue}-history-user',
          threadId: threadId,
          scene: ChatScene.feedAi,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.text,
          status: 'sent',
          textPreview: '${fixture.skill.label}历史问题',
        );
        final historyMessage = ChatMessage(
          messageId: '${fixture.skill.routeValue}-history-message',
          threadId: threadId,
          scene: ChatScene.feedAi,
          role: ChatMessageRole.assistant,
          contentType: ChatMessageContentType.text,
          status: 'sent',
          textPreview: historyText,
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          agentProfileId: fixture.agentProfileId,
          threads: <ChatThread>[historyThread],
          messagesByThread: <String, List<ChatMessage>>{
            threadId: <ChatMessage>[historyUser, historyMessage],
          },
        );
        final api = _WidgetChatApi(
          listedThreads: <ChatThread>[historyThread],
          detailThreads: <String, ChatThread>{threadId: historyThread},
          detailMessages: <String, List<ChatMessage>>{
            threadId: <ChatMessage>[historyUser, historyMessage],
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: fixture.agentProfileId,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              ...mobileAgentReadyTestOverrides(),
              chatRepositoryProvider.overrideWithValue(api),
              chatThreadAliasRepositoryProvider.overrideWithValue(repository),
              feedAiChatControllerProvider.overrideWith((ref) => controller),
              resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            ],
            child: MaterialApp(
              home: V3ChatPage(
                launchMode: ChatLaunchMode.fresh,
                workbenchContext: WorkbenchChatContext(
                  skill: fixture.skill,
                  materialIds: const <String>[],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.state.activeThreadId, isNull);
        expect(find.text(historyText), findsNothing);
        expect(find.text(fixture.greeting), findsOneWidget);
        expect(find.text('Hello，我是花火 AI'), findsNothing);
        expect(find.text(fixture.headerTitle), findsOneWidget);
        expect(
          find.byKey(
            ValueKey<String>('chat-agent-leading-${fixture.agentProfileId}'),
          ),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('chat-entry-surface')),
          findsOneWidget,
        );
        expect(api.listThreadCalls, 0);
        expect(api.createdContentLineIds, isEmpty);
      },
    );
  }

  testWidgets('V3 data body profile renders its own fresh guide', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      initialAgentProfileId: 'data_body',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(
          home: V3ChatPage(launchMode: ChatLaunchMode.fresh),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.state.activeThreadId, isNull);
    expect(find.text('Hello，我是数字孪生 Agent'), findsOneWidget);
    expect(find.text('Hello，我是花火 AI'), findsNothing);
    expect(find.text('数字孪生'), findsOneWidget);
    expect(find.text('建立准确的数字孪生，最先需要补充哪些信息？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
      findsNWidgets(2),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('chat-entry-refresh-suggestions')),
    );
    await tester.pump();
    expect(find.text('怎样判断一段经历是否足以代表一个人的能力？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-agent-leading-data_body')),
      findsNothing,
    );
    expect(api.listThreadCalls, 0);
  });

  for (final fixture
      in <({String profile, String greeting, String first, String rotated})>[
        (
          profile: 'self_media_creation',
          greeting: 'Hello，我是自媒体创作 Agent',
          first: '一个新账号应该先确定受众、主题还是内容形式？',
          rotated: '内容更新不稳定时，应该怎样建立选题流程？',
        ),
        (
          profile: 'faya_germination',
          greeting: 'Hello，我是深度洞察 Agent',
          first: '普通素材怎样找到有冲突感的观点切口？',
          rotated: '一个事实可以从哪些角度发展成独立观点？',
        ),
        (
          profile: 'positioning_lv1',
          greeting: 'Hello，我是基础定位 Agent',
          first: '做基础定位时，应该先梳理经历还是目标受众？',
          rotated: '定位太宽泛时，可以用哪些问题逐步缩小范围？',
        ),
      ]) {
    testWidgets('V3 ${fixture.profile} uses dedicated balanced starters', (
      tester,
    ) async {
      final api = _WidgetChatApi();
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        initialAgentProfileId: fixture.profile,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            feedAiChatControllerProvider.overrideWith((ref) => controller),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp(
            home: V3ChatPage(
              windowId: 'balanced-${fixture.profile}',
              launchMode: ChatLaunchMode.fresh,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(fixture.greeting), findsOneWidget);
      expect(find.text(fixture.first), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
        findsNWidgets(2),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('chat-entry-refresh-suggestions')),
      );
      await tester.pump();
      expect(find.text(fixture.first), findsNothing);
      expect(find.text(fixture.rotated), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
        findsNWidgets(2),
      );
    });
  }

  testWidgets('V3 specialist route starts fresh after every re-entry', (
    tester,
  ) async {
    final database = AppDatabase();
    final repository = ChatThreadAliasRepository(
      dao: UserMetadataDao(database),
      preferencesDao: AppPreferencesDao(database),
      userScope: 'widget-profile-route-reentry-user',
    );
    const threadId = 'persona-route-history';
    final historyThread = ChatThread(
      threadId: threadId,
      scene: ChatScene.feedAi,
      title: '个人 IP 路由历史',
      updatedAt: DateTime.utc(2026, 8, 30),
      agentProfileId: 'renshe_content',
    );
    const historyMessage = ChatMessage(
      messageId: 'persona-route-history-message',
      threadId: threadId,
      scene: ChatScene.feedAi,
      role: ChatMessageRole.assistant,
      contentType: ChatMessageContentType.text,
      status: 'sent',
      textPreview: '重新进入后仍显示这条个人 IP 历史',
    );
    const historyUser = ChatMessage(
      messageId: 'persona-route-history-user',
      threadId: threadId,
      scene: ChatScene.feedAi,
      role: ChatMessageRole.user,
      contentType: ChatMessageContentType.text,
      status: 'sent',
      textPreview: '个人 IP 历史问题',
    );
    repository.saveConversationCache(
      scene: ChatScene.feedAi,
      purpose: ChatConversationPurpose.general,
      agentProfileId: 'renshe_content',
      threads: <ChatThread>[historyThread],
      messagesByThread: <String, List<ChatMessage>>{
        threadId: const <ChatMessage>[historyUser, historyMessage],
      },
    );
    final api = _WidgetChatApi(
      listedThreads: <ChatThread>[historyThread],
      detailThreads: <String, ChatThread>{threadId: historyThread},
      detailMessages: const <String, List<ChatMessage>>{
        threadId: <ChatMessage>[historyUser, historyMessage],
      },
    );
    final controllers = <ChatController>[];
    final router = GoRouter(
      initialLocation: '/v3/feed/chat?agentProfileId=renshe_content',
      routes: <RouteBase>[
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) {
            final controller = ChatController(
              api: api,
              scene: ChatScene.feedAi,
              aliasRepository: repository,
              initialAgentProfileId:
                  state.uri.queryParameters['agentProfileId'],
            );
            controllers.add(controller);
            return ProviderScope(
              key: ValueKey<String>('profile-route-${state.uri}'),
              overrides: <Override>[
                chatRepositoryProvider.overrideWithValue(api),
                chatThreadAliasRepositoryProvider.overrideWithValue(repository),
                feedAiChatControllerProvider.overrideWith((ref) => controller),
                feedAiVoiceMessageControllerProvider.overrideWith(
                  createFeedAiVoiceMessageController,
                ),
              ],
              child: V3ChatPage(
                windowId: state.uri.queryParameters['window'],
                launchMode: ChatLaunchMode.fresh,
                workbenchContext: WorkbenchChatContext(
                  skill: WorkbenchChatSkill.persona,
                  materialIds: const <String>[],
                ),
              ),
            );
          },
        ),
        GoRoute(
          path: '/other',
          builder: (context, state) => const Scaffold(body: Text('其他页面')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          chatThreadAliasRepositoryProvider.overrideWithValue(repository),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(controllers.single.state.activeThreadId, isNull);
    expect(find.text('重新进入后仍显示这条个人 IP 历史'), findsNothing);
    expect(find.text('Hello，我是个人 IP Agent'), findsOneWidget);

    router.go('/other');
    await tester.pumpAndSettle();
    router.go('/v3/feed/chat?agentProfileId=renshe_content');
    await tester.pumpAndSettle();

    expect(controllers, hasLength(2));
    expect(controllers.last.state.activeThreadId, isNull);
    expect(find.text('重新进入后仍显示这条个人 IP 历史'), findsNothing);
    expect(find.text('Hello，我是个人 IP Agent'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-agent-leading-renshe_content')),
      findsNothing,
    );
    expect(api.createdContentLineIds, isEmpty);

    await tester.tap(find.byTooltip('新建会话'));
    await tester.pumpAndSettle();

    final newChatUri = router.routeInformationProvider.value.uri;
    expect(newChatUri.queryParameters['window'], isNotEmpty);
    expect(newChatUri.queryParameters['agentProfileId'], 'renshe_content');
    expect(controllers, hasLength(3));
    expect(controllers.last.activeAgentProfileId, 'renshe_content');
    expect(controllers.last.state.activeThreadId, isNull);
    expect(find.text('Hello，我是个人 IP Agent'), findsOneWidget);
  });

  testWidgets(
    'source route stays isolated from an unbound Thought Graph entry',
    (tester) async {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'widget-source-route-isolation-user',
      );
      final rootApi = _WidgetChatApi();
      final sourceApi = _WidgetChatApi();
      final rootController = ChatController(
        api: rootApi,
        scene: ChatScene.feedAi,
        aliasRepository: repository,
      );
      await rootController.loadThreads();
      expect(rootController.state.activeThreadId, 'feed-1');
      expect(rootController.state.messages, isNotEmpty);

      final runApi = _WidgetAgentRunApi(
        <Future<ApiResult<AgentRunSnapshot>>>[],
      );
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runApi),
        preferences: AppPreferencesDao(database),
        userScope: 'widget-source-route-isolation-user',
      );
      final router = GoRouter(
        initialLocation: '/v3/feed/chat?contentLineId=line-1',
        routes: buildAppRoutes(
          splashBuilder: (context, state) => const SizedBox.shrink(),
          restoreFailedBuilder: (context, state) => const SizedBox.shrink(),
          workspaceRetryBuilder: (context, state) => const SizedBox.shrink(),
        ),
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            appDatabaseProvider.overrideWithValue(database),
            chatRepositoryProvider.overrideWithValue(sourceApi),
            assistantRuntimeProvider.overrideWithValue(
              legacyAssistantRuntime(runApi),
            ),
            chatRunTrackerProvider.overrideWith((ref) => tracker),
            chatThreadAliasRepositoryProvider.overrideWithValue(repository),
            feedAiChatControllerProvider.overrideWith((ref) => rootController),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('已带入本次转写上下文，首条消息会创建关联会话。'), findsOneWidget);
      expect(rootController.state.activeThreadId, 'feed-1');
      expect(rootController.state.messages, isNotEmpty);
      expect(sourceApi.createdContentLineIds, isEmpty);

      router.go('/v3/feed/chat?entry=$thoughtGraphChatEntryRouteValue');
      await tester.pumpAndSettle();

      expect(rootController.state.activeThreadId, isNull);
      expect(find.text('服务器已返回的内容'), findsNothing);
      expect(sourceApi.createdContentLineIds, isEmpty);
    },
  );

  testWidgets(
    'V3 ordinary blank new chat does not block on an optional catalog read',
    (tester) async {
      tester.view
        ..physicalSize = const Size(402, 874)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _WidgetChatApi();
      final capabilityPort = _NeverCompletingCatalogPort();
      final capabilities = MobileAgentCapabilityController(
        port: capabilityPort,
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            mobileAgentCapabilityControllerProvider.overrideWith(
              (ref) => capabilities,
            ),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: const MaterialApp(
            home: V3ChatPage(windowId: 'ordinary-new-window'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(capabilityPort.profileCalls, 0);
      expect(find.text('正在校验当前账号的 AI 能力，请稍候'), findsNothing);
      expect(find.text('Hello，我是花火 AI'), findsOneWidget);
      expect(find.text('把你的想法整理成清晰、可执行的创作方向。'), findsOneWidget);
      expect(find.text('引用一份资产，帮我找到可继续创作的方向'), findsOneWidget);
      expect(find.text('输入一个问题，开始一段新的对话。'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('chat-entry-disclaimer')),
        findsOneWidget,
      );
      expect(find.text(ChatEntryFigmaSpec.disclaimer), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.getSize(
          find.byKey(const ValueKey<String>('chat-entry-composer')),
        ),
        const Size(370, 54),
      );
      expect(
        find.byKey(const ValueKey<String>('chat-entry-avatar')),
        findsNothing,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('chat-entry-add'))),
        const Size.square(40),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('chat-entry-voice'))),
        const Size.square(40),
      );
      expect(
        find.byKey(const ValueKey<String>('chat-entry-send')),
        findsOneWidget,
      );
    },
  );

  testWidgets('chat attachment menu ends at the device safe edge', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(bottom: 34)
      ..viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: V3ChatAttachmentSheet(
              onClose: () {},
              onNote: () {},
              onCamera: () {},
              onImages: () {},
            ),
          ),
        ),
      ),
    );

    final imageTile = find.ancestor(
      of: find.text('图片'),
      matching: find.byType(InkWell),
    );
    expect(imageTile, findsOneWidget);
    expect(
      tester.view.physicalSize.height / tester.view.devicePixelRatio -
          tester.getRect(imageTile).bottom,
      closeTo(34, .1),
    );
  });

  for (final fixture
      in <
        ({String name, String profile, WorkbenchChatSkill? skill, bool video})
      >[
        (
          name: 'general',
          profile: standardCreationChatAgentProfileId,
          skill: null,
          video: false,
        ),
        (
          name: 'persona',
          profile: 'renshe_content',
          skill: WorkbenchChatSkill.persona,
          video: false,
        ),
        (
          name: 'lead',
          profile: 'huoke_content',
          skill: WorkbenchChatSkill.lead,
          video: false,
        ),
        (
          name: 'visual',
          profile: 'visual_chat',
          skill: WorkbenchChatSkill.visualDesign,
          video: false,
        ),
        (
          name: 'video-workbench',
          profile: 'video_analysis',
          skill: WorkbenchChatSkill.videoAnalysis,
          video: true,
        ),
        (
          name: 'video-profile-only',
          profile: 'video_analysis',
          skill: null,
          video: true,
        ),
        (
          name: 'visual-with-stale-video-skill',
          profile: 'visual_chat',
          skill: WorkbenchChatSkill.videoAnalysis,
          video: false,
        ),
      ]) {
    testWidgets('chat video upload menu is scoped for ${fixture.name}', (
      tester,
    ) async {
      final api = _WidgetChatApi();
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        initialAgentProfileId: fixture.profile,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            feedAiChatControllerProvider.overrideWith((ref) => controller),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp(
            home: V3ChatPage(
              windowId: 'video-upload-menu-${fixture.name}',
              workbenchContext: fixture.skill == null
                  ? null
                  : WorkbenchChatContext(
                      skill: fixture.skill!,
                      materialIds: const <String>[],
                    ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pumpAndSettle();

      for (final label in const ['引用笔记', '拍照', '图片']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('上传视频'), fixture.video ? findsOneWidget : findsNothing);
      expect(api.sentContents, isEmpty);
    });
  }

  for (final source in const ['gallery', 'files']) {
    testWidgets(
      'chat video upload selects $source and handles picker recovery',
      (tester) async {
        const channel = MethodChannel('huahuoai/native_file');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final pickerRequests = <Map<Object?, Object?>>[];
        var pickerFails = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickMediaFiles');
          pickerRequests.add(call.arguments as Map<Object?, Object?>);
          if (pickerFails) {
            throw PlatformException(code: 'NATIVE_MEDIA_PICKER_UNAVAILABLE');
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final api = _WidgetChatApi();
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          initialAgentProfileId: 'video_analysis',
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              ...mobileAgentReadyTestOverrides(),
              chatRepositoryProvider.overrideWithValue(api),
              feedAiChatControllerProvider.overrideWith((ref) => controller),
              resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            ],
            child: MaterialApp(
              home: V3ChatPage(windowId: 'video-upload-source-$source'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.add).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('上传视频'));
        await tester.pumpAndSettle();
        expect(find.text('从相册选择'), findsOneWidget);
        expect(find.text('从文件选择'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(pickerRequests, isEmpty);

        for (final fail in const [false, true, false]) {
          pickerFails = fail;
          await tester.tap(find.byIcon(Icons.add).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('上传视频'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(source == 'gallery' ? '从相册选择' : '从文件选择'));
          await tester.pumpAndSettle();
          expect(pickerRequests.last, <String, String>{
            'kind': 'video',
            'source': source,
          });
          expect(find.text('上传视频'), findsNothing);
          expect(
            find.text('视频选择或上传失败，请重试'),
            fail ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const ValueKey('chat-composer-attachment-tray')),
            findsNothing,
          );
          expect(api.sentContents, isEmpty);
          if (fail) {
            await tester.pump(const Duration(seconds: 5));
            await tester.pumpAndSettle();
          }
        }
        expect(pickerRequests, hasLength(3));
      },
    );
  }

  testWidgets('M05 renders retryable failure instead of a new conversation', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(
            _WidgetChatApi(listFailureCode: 'CHAT_THREAD_LIST_FAILED'),
          ),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('chat-entry-surface')),
      findsNothing,
    );
    expect(find.text('加载最近对话失败，请重试。'), findsOneWidget);
    expect(find.byTooltip('重试'), findsOneWidget);
  });

  testWidgets('M05 renders the new entry only after confirmed empty history', (
    tester,
  ) async {
    final api = _WidgetChatApi(listedThreads: const <ChatThread>[]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.listThreadCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('chat-entry-surface')),
      findsOneWidget,
    );
    expect(find.text('加载最近对话失败，请重试。'), findsNothing);
  });

  testWidgets('explicit historical route stays loading until detail resolves', (
    tester,
  ) async {
    final detail = Completer<ApiResult<ChatThreadDetail>>();
    final api = _WidgetChatApi(
      detailCompleters: <String, Completer<ApiResult<ChatThreadDetail>>>{
        'feed-1': detail,
      },
    );
    final controller = ChatController(api: api, scene: ChatScene.feedAi);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage(threadId: 'feed-1')),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在加载最近对话'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-entry-surface')),
      findsNothing,
    );

    detail.complete(
      _success(
        const ChatThreadDetail(
          thread: ChatThread(
            threadId: 'feed-1',
            scene: ChatScene.feedAi,
            agentProfileId: standardCreationChatAgentProfileId,
          ),
          messages: <ChatMessage>[
            ChatMessage(
              messageId: 'explicit-history-user',
              threadId: 'feed-1',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: '加载明确历史会话',
            ),
            ChatMessage(
              messageId: 'explicit-history-assistant',
              threadId: 'feed-1',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: '明确历史会话已经加载',
            ),
          ],
        ),
        SubmissionKeyStore.empty,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('明确历史会话已经加载'), findsOneWidget);
    expect(find.text('正在加载最近对话'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('chat-entry-surface')),
      findsNothing,
    );
  });

  testWidgets('M05 starters keep one asset action and direct questions', (
    tester,
  ) async {
    final api = _WidgetChatApi(
      assistantMessage: ChatMessage(
        messageId: 'starter-assistant',
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        role: ChatMessageRole.assistant,
        contentType: ChatMessageContentType.text,
        status: 'sent',
        textPreview: '可以，先从受众和表达目标开始梳理。',
        createdAt: DateTime.utc(2026, 9, 12),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(initialNotes: const []),
          ),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(
          home: V3ChatPage(windowId: 'm05-balanced-starters'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
      findsNWidgets(2),
    );
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-noteLibrary')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-dailyTopic')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
    );
    await tester.pump();
    expect(find.text('我的资产暂时没有可引用的内容'), findsOneWidget);
    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('chat-composer')),
    );
    expect(composer.controller?.text, isEmpty);
    expect(composer.minLines, 1);
    expect(composer.maxLines, V3ChatComposerMetrics.maxVisibleLines);
    expect(api.sentContents, isEmpty);

    const directQuestion = '一个模糊想法，怎样变成清晰的创作主题？';
    await tester.tap(find.text(directQuestion));
    await tester.pump();
    await tester.pump();
    expect(api.sentContents, <String>[directQuestion]);
    expect(api.sentContexts.single?.references, isEmpty);
    expect(find.text('可以，先从受众和表达目标开始梳理。'), findsOneWidget);
  });

  testWidgets('full-page Note entry keeps contextual direct questions', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'full-page-note',
          title: '产品复盘',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 9, 12),
          rawBody: '记录了本周产品验证的结果。',
          remoteNoteId: 'remote-full-page-note',
          rawPartRevisionId: 'raw-full-page-note-1',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(
          home: V3ChatPage(
            windowId: 'full-page-note-entry',
            feedItemId: 'full-page-note',
            launchMode: ChatLaunchMode.fresh,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('已引用资产「产品复盘」'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
      findsNWidgets(3),
    );
    const question = '这条笔记的核心判断是什么？';
    await tester.tap(find.text(question));
    await tester.pump();
    await tester.pump();

    expect(api.sentContents, <String>[question]);
    expect(api.sentContexts.single?.references, hasLength(1));
    expect(
      api.sentContexts.single?.references.single,
      isA<ChatContextReference>()
          .having((reference) => reference.id, 'id', 'remote-full-page-note')
          .having(
            (reference) => reference.revision,
            'revision',
            'raw-full-page-note-1',
          ),
    );
  });

  testWidgets('standard chat composer follows the software keyboard once', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final api = _WidgetChatApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final headerActions = find.byType(ChatEntryHeaderActions);
    expect(headerActions, findsOneWidget);
    expect(
      tester.view.physicalSize.width / tester.view.devicePixelRatio -
          tester.getRect(headerActions).right,
      closeTo(HuahuoSpacing.xs, .1),
    );
    final composer = find.byType(TextField).last;
    final latestReply = find.text('服务器已返回的内容');
    expect(latestReply, findsOneWidget);
    await tester.tap(composer);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final keyboardTop = tester.view.physicalSize.height - 300;
    final composerBottom = tester.getRect(composer).bottom;
    final composerTop = tester.getRect(composer).top;
    final latestReplyRect = tester.getRect(latestReply);
    final conversation = tester.widget<CustomScrollView>(
      find.byKey(const PageStorageKey<String>('v3-page-scroll-聊一聊')),
    );
    final conversationPadding = conversation.slivers.single as SliverPadding;
    expect(composerBottom, lessThanOrEqualTo(keyboardTop));
    expect(keyboardTop - composerBottom, lessThan(80));
    expect((conversationPadding.padding as EdgeInsets).bottom, 16);
    expect(latestReplyRect.bottom, greaterThan(52));
    expect(latestReplyRect.bottom, lessThan(composerTop));
  });

  testWidgets('V3 first send stays on its mounted transient new-window route', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi();
    final router = GoRouter(
      initialLocation: '/v3/feed/chat?window=first-visible-window',
      routes: <RouteBase>[
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) => ProviderScope(
            key: ValueKey<String>('first-send-scope-${state.uri}'),
            overrides: <Override>[
              feedAiChatControllerProvider.overrideWith((ref) {
                return ChatController(api: api, scene: ChatScene.feedAi);
              }),
              feedAiVoiceMessageControllerProvider.overrideWith(
                createFeedAiVoiceMessageController,
              ),
            ],
            child: V3ChatPage(
              windowId: state.uri.queryParameters['window'],
              threadId: state.uri.queryParameters['threadId'],
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '首条消息保持可见');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    final route = router.routeInformationProvider.value.uri;
    expect(api.createdContentLineIds, <String?>[null]);
    expect(api.sentContents, <String>['首条消息保持可见']);
    expect(route.queryParameters['threadId'], isNull);
    expect(route.queryParameters['window'], 'first-visible-window');
    expect(find.text('首条消息保持可见'), findsWidgets);
  });

  testWidgets(
    'V3 rejected first send keeps its transient route and explains credit block',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi(
        sendFailureCode: 'ACCOUNT_UNCOVERED_CREDIT_BLOCKED',
      );
      final router = GoRouter(
        initialLocation: '/v3/feed/chat?window=failed-first-window',
        routes: <RouteBase>[
          GoRoute(
            path: '/v3/feed/chat',
            builder: (context, state) => ProviderScope(
              key: ValueKey<String>('failed-first-send-scope-${state.uri}'),
              overrides: <Override>[
                feedAiChatControllerProvider.overrideWith((ref) {
                  return ChatController(api: api, scene: ChatScene.feedAi);
                }),
                feedAiVoiceMessageControllerProvider.overrideWith(
                  createFeedAiVoiceMessageController,
                ),
              ],
              child: V3ChatPage(
                windowId: state.uri.queryParameters['window'],
                threadId: state.uri.queryParameters['threadId'],
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '额度失败首条消息');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      final route = router.routeInformationProvider.value.uri;
      expect(api.sentContents, <String>['额度失败首条消息']);
      expect(route.queryParameters['window'], 'failed-first-window');
      expect(route.queryParameters['threadId'], isNull);
      expect(find.text('当前账号有尚未补足的历史算力额度，聊天暂不可用。'), findsWidgets);
      expect(find.text('额度失败首条消息'), findsWidgets);
    },
  );

  testWidgets(
    'V3 history selection creates a canonical thread page from a new window',
    (tester) async {
      final api = _WidgetChatApi();
      final routeThreadIds = <String?>[];
      var scopedControllerCount = 0;
      Uri? destinationUri;
      final router = GoRouter(
        initialLocation: '/v3/feed/chat?window=history-window',
        routes: <RouteBase>[
          GoRoute(
            path: '/v3/feed/chat',
            pageBuilder: (context, state) {
              final threadId = state.uri.queryParameters['threadId'];
              if (threadId != null) destinationUri = state.uri;
              routeThreadIds.add(threadId);
              final page = V3ChatPage(
                key: ValueKey<String>('history-page-${state.uri}'),
                windowId: state.uri.queryParameters['window'],
                threadId: threadId,
              );
              return NoTransitionPage<void>(
                key: state.pageKey,
                child: ProviderScope(
                  key: ValueKey<String>('history-route-${state.uri}'),
                  overrides: <Override>[
                    feedAiChatControllerProvider.overrideWith((ref) {
                      scopedControllerCount += 1;
                      return ChatController(
                        api: api,
                        scene: ChatScene.feedAi,
                        agentScope: threadId == null
                            ? const ChatAgentScope.fixed(
                                standardCreationChatAgentProfileId,
                              )
                            : const ChatAgentScope.threadBound(),
                      );
                    }),
                    feedAiVoiceMessageControllerProvider.overrideWith(
                      createFeedAiVoiceMessageController,
                    ),
                  ],
                  child: page,
                ),
              );
            },
          ),
          GoRoute(
            path: '/other',
            builder: (context, state) => const Scaffold(body: Text('其他页面')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
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
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('会话列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('如何整理客户访谈'));
      await tester.pumpAndSettle();

      final selectedUri = destinationUri!;
      expect(selectedUri.queryParameters['threadId'], 'feed-1');
      expect(selectedUri.queryParameters['window'], isNull);
      expect(selectedUri.queryParameters['contentLineId'], isNull);
      expect(selectedUri.queryParameters['materialIds'], isNull);
      expect(routeThreadIds, contains('feed-1'));
      expect(scopedControllerCount, 2);
      expect(find.text('服务器已返回的内容'), findsOneWidget);

      final detailReadsBeforeResume = api.detailThreadIds.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(destinationUri!.queryParameters['threadId'], 'feed-1');
      expect(api.detailThreadIds, hasLength(detailReadsBeforeResume));
      expect(find.text('服务器已返回的内容'), findsOneWidget);

      router.go('/other');
      await tester.pumpAndSettle();
      router.go('/v3/feed/chat?threadId=feed-1');
      await tester.pump();
      await tester.pumpAndSettle();

      expect(routeThreadIds.last, 'feed-1');
      expect(find.text('服务器已返回的内容'), findsOneWidget);
      expect(
        api.detailThreadIds.where((id) => id == 'feed-1').length,
        greaterThanOrEqualTo(2),
      );
    },
  );

  testWidgets(
    'V3 direct deep positioning thread hydrates an unassigned local purpose',
    (tester) async {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'widget-direct-positioning-user',
      );
      final api = _WidgetChatApi(
        threadPurposes: const <String, ChatConversationPurpose>{
          'remote-positioning': ChatConversationPurpose.deepPositioning,
        },
      );
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        aliasRepository: repository,
        conversationPurpose: ChatConversationPurpose.deepPositioning,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            deepPositioningChatControllerProvider.overrideWith(
              (ref) => controller,
            ),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: const MaterialApp(
            home: V3ChatPage(
              threadId: 'remote-positioning',
              conversationPurpose: ChatConversationPurpose.deepPositioning,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(api.listThreadCalls, 0);
      expect(api.detailThreadIds, contains('remote-positioning'));
      expect(controller.state.activeThreadId, 'remote-positioning');
      expect(controller.state.lastErrorCode, isNull);
      expect(api.createdContentLineIds, isEmpty);
      expect(find.text('服务器已返回的内容'), findsOneWidget);
    },
  );

  testWidgets(
    'V3 chat preserves historical reading position on composer focus and follows after send',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(393, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi(
        detailMessages: <String, List<ChatMessage>>{
          'feed-1': List<ChatMessage>.generate(18, (index) {
            final isUser = index.isEven;
            return ChatMessage(
              messageId: 'keyboard-message-$index',
              threadId: 'feed-1',
              scene: ChatScene.feedAi,
              role: isUser ? ChatMessageRole.user : ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: '这是用于验证移动端滚动定位的第 $index 条${isUser ? '用户' : '助手'}消息。',
              createdAt: DateTime.utc(2026, 8, 17, 8, index),
            );
          }),
        },
        assistantMessage: ChatMessage(
          messageId: 'keyboard-assistant-reply',
          threadId: 'feed-1',
          scene: ChatScene.feedAi,
          role: ChatMessageRole.assistant,
          contentType: ChatMessageContentType.text,
          status: 'sent',
          textPreview: '这是一条刚收到的助手回复。',
          createdAt: DateTime.utc(2026, 8, 17, 9),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: const MaterialApp(home: V3ChatPage()),
        ),
      );
      await tester.pumpAndSettle();

      final composer = find.byKey(const ValueKey<String>('chat-composer'));
      final conversation = find.byKey(
        const PageStorageKey<String>('v3-page-scroll-聊一聊'),
      );
      final scrollable = find.descendant(
        of: conversation,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(
        tester.widget<CustomScrollView>(conversation).keyboardDismissBehavior,
        ScrollViewKeyboardDismissBehavior.manual,
      );

      await tester.drag(conversation, const Offset(0, 180));
      await tester.pumpAndSettle();
      final readingOffset = position.pixels;
      expect(readingOffset, lessThan(position.maxScrollExtent));

      await tester.tap(composer);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isTrue);
      expect(position.pixels, closeTo(readingOffset, 1));

      await tester.enterText(composer, '请把这条消息定位到最新位置');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isFalse);
      expect(position.pixels, closeTo(position.maxScrollExtent, 1));
      expect(find.text('这是一条刚收到的助手回复。'), findsOneWidget);
    },
  );

  testWidgets('V3 chat title scrolls a long conversation to its first row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi(
      detailMessages: <String, List<ChatMessage>>{
        'feed-1': List<ChatMessage>.generate(
          24,
          (index) => ChatMessage(
            messageId: 'title-scroll-$index',
            threadId: 'feed-1',
            scene: ChatScene.feedAi,
            role: index.isEven
                ? ChatMessageRole.user
                : ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'sent',
            textPreview: '用于验证点击标题返回第一条的第 $index 条消息。',
            createdAt: DateTime.utc(2026, 8, 26, 8, index),
          ),
        ),
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    for (var layoutPass = 0; layoutPass < 8; layoutPass += 1) {
      await tester.pump();
    }

    final conversation = find.byKey(
      const PageStorageKey<String>('v3-page-scroll-聊一聊'),
    );
    final scrollable = find.descendant(
      of: conversation,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    expect(position.isScrollingNotifier.value, isFalse);

    final titleTarget = tester
        .widgetList<GestureDetector>(
          find.ancestor(
            of: find.text('聊一聊').first,
            matching: find.byType(GestureDetector),
          ),
        )
        .firstWhere((widget) => widget.behavior == HitTestBehavior.opaque);
    titleTarget.onTap!();
    await tester.pumpAndSettle();

    expect(position.pixels, closeTo(position.minScrollExtent, 1));
  });

  testWidgets(
    'V3 chat stops live voice on the second mic tap and keeps the draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi();
      final recorder = _ChatLiveRecorder();
      final asr = _ChatLiveAsrPort();
      final liveTranscript = LiveTranscriptController(
        credentialPort: const _ChatLiveCredentialPort(),
        asrPort: asr,
      );
      final runtimeMetrics = RuntimeActivityMetrics();
      addTearDown(runtimeMetrics.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
            voiceRecorderPortProvider.overrideWithValue(recorder),
            feedAiVoiceMessageControllerProvider.overrideWith(
              (ref) => VoiceMessageController(
                recorder: recorder,
                uploader: ChatVoiceUploader(
                  uploadClient: ref.watch(recordingUploadClientProvider),
                ),
                localRecordingRepository: ref.watch(
                  localRecordingRepositoryProvider,
                ),
                chatController: ref.watch(feedAiChatControllerProvider),
                recordingApi: ref.watch(recordingApiProvider),
                liveTranscriptController: liveTranscript,
                liveTranscriptStopGrace: Duration.zero,
              ),
            ),
          ],
          child: RuntimeActivityMetricsScope(
            metrics: runtimeMetrics,
            child: const MaterialApp(home: V3ChatPage()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final idleDecoration = _liveVoiceDecoration(tester);
      expect(idleDecoration.boxShadow, isEmpty);
      expect(runtimeMetrics.current.activeTickers, 0);
      await tester.tap(find.byTooltip('开始实时转写'));
      await tester.pump();
      await tester.pump();
      expect(recorder.startedScenes, <VoiceRecordingScene>[
        VoiceRecordingScene.monologue,
      ]);
      expect(liveTranscript.state.status, LiveTranscriptStatus.transcribing);
      expect(
        ProviderScope.containerOf(
          tester.element(find.byType(V3ChatPage)),
        ).read(feedAiVoiceMessageControllerProvider).state.liveTranscriptStatus,
        LiveTranscriptStatus.transcribing,
      );
      expect(find.text('正在实时转写'), findsNothing);
      expect(find.text('正在转写，可继续说…'), findsOneWidget);
      expect(find.byTooltip('结束实时转写'), findsOneWidget);
      expect(runtimeMetrics.current.activeTickers, 1);
      expect(
        find.byKey(const ValueKey<String>('chat-live-transcription-voice')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.mic_rounded)).color,
        HuahuoV3Theme.tokensOf(
          tester.element(find.byKey(const ValueKey('chat-entry-voice'))),
        ).accent,
      );
      expect(_liveVoiceDecoration(tester).boxShadow, isNotEmpty);
      final activeBorder = _liveVoiceDecoration(tester).border! as Border;
      expect(
        activeBorder.top.color,
        HuahuoV3Theme.tokensOf(
          tester.element(find.byKey(const ValueKey('chat-entry-voice'))),
        ).accent.withValues(alpha: .90),
      );
      expect(activeBorder.top.width, 1.2);
      final waveFinder = find.byKey(
        const ValueKey<String>('chat-live-transcription-wave-outer'),
      );
      final initialWaveScale = tester
          .widget<Transform>(waveFinder)
          .transform
          .entry(0, 0);
      await tester.pump(const Duration(milliseconds: 300));
      final expandedWaveScale = tester
          .widget<Transform>(waveFinder)
          .transform
          .entry(0, 0);
      expect(expandedWaveScale, greaterThan(initialWaveScale));

      asr.add(
        LiveTranscriptSentence(sentenceId: 1, text: '把这段内容整理成提纲', stable: true),
      );
      await tester.pump();
      await tester.pump();

      expect(
        ProviderScope.containerOf(
          tester.element(find.byType(V3ChatPage)),
        ).read(feedAiVoiceMessageControllerProvider).state.liveTranscriptText,
        '把这段内容整理成提纲',
      );
      final composer = tester.widget<TextField>(find.byType(TextField));
      expect(composer.controller?.text, '把这段内容整理成提纲');
      expect(composer.readOnly, isTrue);

      await tester.tap(find.byTooltip('结束实时转写'));
      await tester.pumpAndSettle();
      expect(recorder.cancelCalls, 1);
      expect(recorder.pauseCalls, 0);
      expect(recorder.resumeCalls, 0);
      expect(api.voiceMessageCalls, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '把这段内容整理成提纲',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );

      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-live-transcription-voice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-entry-voice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-entry-send')),
        findsOneWidget,
      );
      expect(api.voiceMessageCalls, 0);
      expect(runtimeMetrics.current.activeTickers, 0);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.byTooltip('开始实时转写'), findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      expect(_liveVoiceDecoration(tester).boxShadow, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(runtimeMetrics.current.activeTickers, 0);
      await asr.close();
    },
  );

  testWidgets('V3 chat rejects a covered Canvas transcript when it returns', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recorder = _ChatLiveRecorder();
    final asr = _ChatLiveAsrPort();
    final liveTranscript = LiveTranscriptController(
      credentialPort: const _ChatLiveCredentialPort(),
      asrPort: asr,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(_WidgetChatApi()),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
          voiceRecorderPortProvider.overrideWithValue(recorder),
          feedAiVoiceMessageControllerProvider.overrideWith(
            (ref) => VoiceMessageController(
              recorder: recorder,
              uploader: ChatVoiceUploader(
                uploadClient: ref.watch(recordingUploadClientProvider),
              ),
              localRecordingRepository: ref.watch(
                localRecordingRepositoryProvider,
              ),
              chatController: ref.watch(feedAiChatControllerProvider),
              recordingApi: ref.watch(recordingApiProvider),
              liveTranscriptController: liveTranscript,
              liveTranscriptStopGrace: Duration.zero,
            ),
          ),
        ],
        child: MaterialApp(
          navigatorObservers: <NavigatorObserver>[appRouteObserver],
          home: const V3ChatPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('开始实时转写'));
    await tester.pump();
    await tester.pump();
    asr.add(
      LiveTranscriptSentence(sentenceId: 1, text: '聊天自己的文字', stable: true),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '聊天自己的文字',
    );

    final chatRoute =
        ModalRoute.of(tester.element(find.byType(V3ChatPage)))!
            as PageRoute<dynamic>;
    final coverRoute = MaterialPageRoute<void>(
      builder: (_) => const SizedBox.shrink(),
    );
    appRouteObserver.didPush(coverRoute, chatRoute);
    final voiceController = ProviderScope.containerOf(
      tester.element(find.byType(V3ChatPage)),
    ).read(feedAiVoiceMessageControllerProvider);
    final chatOwner = voiceController.state.liveTranscriptOwner!;
    asr.add(
      LiveTranscriptSentence(sentenceId: 2, text: '覆盖期间识别', stable: true),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '聊天自己的文字',
    );

    final chatEnded = await tester.runAsync(
      () => voiceController.endCaptureForLeave(owner: chatOwner),
    );
    expect(chatEnded, isTrue);
    expect(voiceController.state.liveTranscriptOwner, isNull);
    expect(
      await tester.runAsync(
        () => voiceController.startLiveTranscription(owner: 'canvas:test'),
      ),
      isTrue,
    );
    asr.add(
      LiveTranscriptSentence(sentenceId: 1, text: 'Canvas 的文字', stable: true),
    );
    expect(
      await tester.runAsync(
        () => voiceController.stopAndTranscribe(owner: 'canvas:test'),
      ),
      isTrue,
    );
    expect(voiceController.state.liveTranscriptText, 'Canvas 的文字');
    expect(voiceController.state.liveTranscriptOwner, 'canvas:test');
    expect(voiceController.state.liveTranscriptAttemptId, isNotNull);

    appRouteObserver.didPop(coverRoute, chatRoute);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '聊天自己的文字',
    );
    expect(recorder.cancelCalls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    liveTranscript.dispose();
    await asr.close();
  });

  testWidgets(
    'V3 chat immediately shows a distinct starting voice state in dark theme',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final permission =
          Completer<VoiceRecorderResult<VoiceRecorderPermission>>();
      final api = _WidgetChatApi();
      final recorder = _ChatLiveRecorder(permissionResult: permission.future);
      final asr = _ChatLiveAsrPort();
      final liveTranscript = LiveTranscriptController(
        credentialPort: const _ChatLiveCredentialPort(),
        asrPort: asr,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
            voiceRecorderPortProvider.overrideWithValue(recorder),
            feedAiVoiceMessageControllerProvider.overrideWith(
              (ref) => VoiceMessageController(
                recorder: recorder,
                uploader: ChatVoiceUploader(
                  uploadClient: ref.watch(recordingUploadClientProvider),
                ),
                localRecordingRepository: ref.watch(
                  localRecordingRepositoryProvider,
                ),
                chatController: ref.watch(feedAiChatControllerProvider),
                recordingApi: ref.watch(recordingApiProvider),
                liveTranscriptController: liveTranscript,
                liveTranscriptStopGrace: Duration.zero,
              ),
            ),
          ],
          child: MaterialApp(
            theme: HuahuoV3Theme.dark(),
            home: const V3ChatPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final coreFinder = find.byKey(
        const ValueKey<String>('chat-live-transcription-core'),
      );
      final idleColor = tester.widget<Material>(coreFinder).color;
      await tester.tap(find.byTooltip('开始实时转写'));
      await tester.pump();

      expect(find.byTooltip('正在启动实时转写'), findsOneWidget);
      expect(
        tester.widget<Material>(coreFinder).color,
        Theme.of(tester.element(coreFinder)).colorScheme.surface,
      );
      expect(tester.widget<Material>(coreFinder).color, isNot(idleColor));
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byKey(
                const ValueKey<String>('chat-live-transcription-progress'),
              ),
            )
            .color,
        HuahuoV3Theme.tokensOf(tester.element(coreFinder)).accent,
      );
      expect(_liveVoiceDecoration(tester).boxShadow, isNotEmpty);

      permission.complete(
        VoiceRecorderResult.success(
          const VoiceRecorderPermission(
            state: VoiceRecorderPermissionState.granted,
            canAskAgain: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byTooltip('结束实时转写'), findsOneWidget);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
      asr.add(
        LiveTranscriptSentence(sentenceId: 1, text: '深色主题实时转写', stable: true),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('结束实时转写'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await asr.close();
    },
  );

  testWidgets(
    'V3 chat keeps an exact note reference while live dictation fills the draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi();
      final recorder = _ChatLiveRecorder();
      final asr = _ChatLiveAsrPort();
      final liveTranscript = LiveTranscriptController(
        credentialPort: const _ChatLiveCredentialPort(),
        asrPort: asr,
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[
          V3FeedItem(
            id: 'dictation-note',
            title: '语音提问参考',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 8, 27),
            rawBody: '这条内容需要和口述问题一起发送。',
            remoteNoteId: 'remote-dictation-note',
            rawPartRevisionId: 'raw-dictation-note-2',
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            voiceRecorderPortProvider.overrideWithValue(recorder),
            feedAiVoiceMessageControllerProvider.overrideWith(
              (ref) => VoiceMessageController(
                recorder: recorder,
                uploader: ChatVoiceUploader(
                  uploadClient: ref.watch(recordingUploadClientProvider),
                ),
                localRecordingRepository: ref.watch(
                  localRecordingRepositoryProvider,
                ),
                chatController: ref.watch(feedAiChatControllerProvider),
                recordingApi: ref.watch(recordingApiProvider),
                liveTranscriptController: liveTranscript,
                liveTranscriptStopGrace: Duration.zero,
              ),
            ),
          ],
          child: const MaterialApp(
            home: V3ChatPage(
              windowId: 'contextual-dictation-window',
              feedItemId: 'dictation-note',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('已引用资产「语音提问参考」'), findsOneWidget);
      await tester.tap(find.byTooltip('开始实时转写'));
      await tester.pump();
      await tester.pump();
      expect(recorder.startedScenes, <VoiceRecordingScene>[
        VoiceRecordingScene.monologue,
      ]);

      asr.add(
        LiveTranscriptSentence(
          sentenceId: 1,
          text: '结合这条笔记给我三个建议',
          stable: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('结束实时转写'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '结合这条笔记给我三个建议',
      );
      await tester.tap(find.byKey(const ValueKey<String>('chat-entry-send')));
      await tester.pumpAndSettle();

      expect(api.sentContents, <String>['结合这条笔记给我三个建议']);
      expect(api.sentContexts, hasLength(1));
      expect(
        api.sentContexts.single?.references.single,
        isA<ChatContextReference>()
            .having((reference) => reference.id, 'id', 'remote-dictation-note')
            .having(
              (reference) => reference.revision,
              'revision',
              'raw-dictation-note-2',
            ),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await asr.close();
    },
  );

  testWidgets('V3 chat shows retryable backend realtime-ASR failure once', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi();
    final recorder = _ChatLiveRecorder();
    final asr = _ChatLiveAsrPort();
    final liveTranscript = LiveTranscriptController(
      credentialPort: const _ChatUnavailableLiveCredentialPort(),
      asrPort: asr,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
          voiceRecorderPortProvider.overrideWithValue(recorder),
          feedAiVoiceMessageControllerProvider.overrideWith(
            (ref) => VoiceMessageController(
              recorder: recorder,
              uploader: ChatVoiceUploader(
                uploadClient: ref.watch(recordingUploadClientProvider),
              ),
              localRecordingRepository: ref.watch(
                localRecordingRepositoryProvider,
              ),
              chatController: ref.watch(feedAiChatControllerProvider),
              recordingApi: ref.watch(recordingApiProvider),
              liveTranscriptController: liveTranscript,
              liveTranscriptStopGrace: Duration.zero,
            ),
          ),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('开始实时转写'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(recorder.startedScenes, <VoiceRecordingScene>[
      VoiceRecordingScene.monologue,
    ]);
    expect(recorder.cancelCalls, 1);
    final voiceState = ProviderScope.containerOf(
      tester.element(find.byType(V3ChatPage)),
    ).read(feedAiVoiceMessageControllerProvider).state;
    expect(voiceState.status, VoiceMessageControllerStatus.failed);
    expect(voiceState.liveTranscriptStatus, LiveTranscriptStatus.failed);
    expect(find.text('实时转写启动失败'), findsOneWidget);
    expect(find.text('实时转写暂时不可用，请稍后重试。已识别的文字会保留。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('实时转写服务未准备好'), findsNothing);
    expect(find.text('启动失败：实时转写服务未准备好'), findsNothing);
    expect(find.text('REALTIME_ASR_SESSION_UNAVAILABLE'), findsNothing);
    expect(find.byTooltip('重试实时转写'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    liveTranscript.dispose();
    await asr.close();
  });

  testWidgets(
    'V3 ordinary chat paints its cached recent conversation on the first frame',
    (tester) async {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'ordinary-first-frame-user',
      );
      const thread = ChatThread(
        threadId: 'cached-recent-thread',
        scene: ChatScene.feedAi,
        title: '最近一次对话',
        agentProfileId: standardCreationChatAgentProfileId,
      );
      repository
        ..markThreadPurpose(
          scene: ChatScene.feedAi,
          threadId: thread.threadId,
          purpose: ChatConversationPurpose.general,
        )
        ..saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          agentProfileId: standardCreationChatAgentProfileId,
          threads: const <ChatThread>[thread],
          messagesByThread: const <String, List<ChatMessage>>{
            'cached-recent-thread': <ChatMessage>[
              ChatMessage(
                messageId: 'cached-recent-user',
                threadId: 'cached-recent-thread',
                scene: ChatScene.feedAi,
                role: ChatMessageRole.user,
                contentType: ChatMessageContentType.text,
                status: 'succeeded',
                textPreview: '最近一次对话的问题',
              ),
              ChatMessage(
                messageId: 'cached-recent-assistant',
                threadId: 'cached-recent-thread',
                scene: ChatScene.feedAi,
                role: ChatMessageRole.assistant,
                contentType: ChatMessageContentType.text,
                status: 'succeeded',
                textPreview: '这是最近一次对话的本地内容',
              ),
            ],
          },
        );
      final api = _WidgetChatApi();
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        aliasRepository: repository,
        initialAgentProfileId: standardCreationChatAgentProfileId,
        restoreRecentConversationOnCreate: true,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            chatThreadAliasRepositoryProvider.overrideWithValue(repository),
            feedAiChatControllerProvider.overrideWith((ref) => controller),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: const MaterialApp(home: V3ChatPage()),
        ),
      );

      expect(find.text('这是最近一次对话的本地内容'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-entry-surface')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'V3 chat restores the latest conversation and changes history explicitly',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi(
        secondThreadAgentProfileId: standardCreationChatAgentProfileId,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp(
            home: const V3ChatPage(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('chat-entry-surface')),
        findsNothing,
      );
      await tester.pump();
      await tester.pump();
      expect(api.listThreadCalls, 1);
      expect(find.text('服务器已返回的内容'), findsOneWidget);
      expect(find.textContaining('我会围绕'), findsNothing);

      await tester.tap(find.byTooltip('会话列表'));
      await tester.pumpAndSettle();
      expect(api.listThreadCalls, 2);
      expect(find.text('请分析第二次访谈'), findsOneWidget);
      expect(find.text('标准创作'), findsNothing);
      await tester.tap(find.text('请分析第二次访谈'));
      await tester.pump();
      await tester.pump();
      expect(find.text('第二个服务器会话'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('chat-active-agent-badge')),
        findsNothing,
      );
      expect(find.textContaining('发送于'), findsOneWidget);
      expect(find.textContaining('回复于'), findsOneWidget);

      final feed2ReadsBeforeReselection = api.detailThreadIds
          .where((threadId) => threadId == 'feed-2')
          .length;
      await tester.tap(find.byTooltip('会话列表'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('chat-history-row-feed-2')),
      );
      await tester.pumpAndSettle();
      expect(
        api.detailThreadIds.where((threadId) => threadId == 'feed-2').length,
        feed2ReadsBeforeReselection,
      );
      expect(api.listThreadCalls, 2);
      expect(find.text('第二个服务器会话'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '这是一次真实发送');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(api.sentContents, <String>['这是一次真实发送']);
      expect(api.sentAgentProfileIds, <String?>[
        standardCreationChatAgentProfileId,
      ]);
      expect(find.text('这是一次真实发送'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
      expect(find.textContaining('我会围绕'), findsNothing);
    },
  );

  testWidgets('V3 chat session sheet keeps the route-scoped controller', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rootApi = _WidgetChatApi();
    final routeApi = _WidgetChatApi();
    final rootController = ChatController(
      api: rootApi,
      scene: ChatScene.feedAi,
    );
    final routeController = ChatController(
      api: routeApi,
      scene: ChatScene.feedAi,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          feedAiChatControllerProvider.overrideWith((ref) => rootController),
        ],
        child: MaterialApp(
          home: ProviderScope(
            overrides: <Override>[
              feedAiChatControllerProvider.overrideWith(
                (ref) => routeController,
              ),
            ],
            child: const V3ChatPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();

    expect(routeApi.listThreadCalls, 2);
    expect(rootApi.listThreadCalls, 0);
    expect(find.text('请分析第二次访谈'), findsOneWidget);
  });

  testWidgets(
    'V3 chat renders structured assistant Markdown and date context',
    (tester) async {
      final now = DateTime.now();
      final api = _WidgetChatApi(
        detailMessages: <String, List<ChatMessage>>{
          'feed-2': <ChatMessage>[
            ChatMessage(
              messageId: 'user-markdown',
              threadId: 'feed-2',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: '请给出方案',
              createdAt: now.subtract(const Duration(days: 2)).toUtc(),
            ),
            ChatMessage(
              messageId: 'assistant-markdown',
              threadId: 'feed-2',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview:
                  '## 核心结论\n\n'
                  '> 先验证一线价值。\n\n'
                  '1. 明确目标\n'
                  '- **记录**基线\n\n'
                  '| 阶段 | 负责人 |\n'
                  '| --- | --- |\n'
                  '| 调研 | 小周 |\n\n'
                  '`关键指标`',
              createdAt: now.toUtc(),
            ),
            ChatMessage(
              messageId: 'assistant-flattened-markdown',
              threadId: 'feed-2',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview:
                  '我已经阅读了你的 Workspace 资产： '
                  '## 资产概览 '
                  '### 定位画像： - 业务方向：内容生产 '
                  '1. 明确目标 2. 记录基线 '
                  '> 关键判断 **先验证价值**',
              createdAt: now.toUtc(),
            ),
          ],
        },
      );
      final chatController = ChatController(api: api, scene: ChatScene.feedAi);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            feedAiChatControllerProvider.overrideWith((ref) => chatController),
          ],
          child: const MaterialApp(home: V3ChatPage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 300));
      await chatController.loadThreads(refresh: true, selectLatest: false);
      await chatController.selectThread('feed-2');
      await tester.pump();

      expect(api.detailThreadIds, contains('feed-2'));
      expect(chatController.state.activeThreadId, 'feed-2');
      expect(chatController.state.messages, hasLength(3));
      await tester.pump();
      final conversation = find.byKey(
        const PageStorageKey<String>('v3-page-scroll-聊一聊'),
      );
      final conversationPosition = tester
          .state<ScrollableState>(
            find.descendant(
              of: conversation,
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      conversationPosition.jumpTo(conversationPosition.minScrollExtent);
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey('chat-assistant-markdown-assistant-markdown'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<HuahuoMarkdown>(
              find.byKey(
                const ValueKey('chat-assistant-markdown-assistant-markdown'),
              ),
            )
            .source,
        isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('chat-copy-assistant-markdown')),
        findsOneWidget,
      );
      expect(find.text('复制'), findsAtLeastNWidgets(1));
      expect(find.text('保存'), findsAtLeastNWidgets(1));
      expect(find.text('保存 / 创作'), findsNothing);
      expect(find.text('去自由创作'), findsNothing);
      for (final text in <String>['核心结论', '先验证一线价值。', '明确目标', '记录', '负责人']) {
        expect(find.textContaining(text), findsAtLeastNWidgets(1));
      }
      expect(find.byType(Table), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              RegExp(
                r'^发送于 \d{2}-\d{2} \d{2}:\d{2}$',
              ).hasMatch(widget.data ?? ''),
        ),
        findsOneWidget,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -640));
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(
          const ValueKey(
            'chat-assistant-markdown-assistant-flattened-markdown',
          ),
        ),
        findsOneWidget,
      );
      for (final text in <String>[
        '资产概览',
        '定位画像：',
        '业务方向：内容生产',
        '明确目标',
        '记录基线',
        '关键判断',
        '先验证价值',
      ]) {
        expect(find.textContaining(text), findsAtLeastNWidgets(1));
      }
      expect(find.textContaining('## 资产概览'), findsNothing);
      expect(find.textContaining('### 定位画像'), findsNothing);
      expect(find.textContaining('回复于 今天 '), findsOneWidget);
    },
  );

  testWidgets(
    'V3 chat renders a complete durable Assistant reply beyond the composer limit',
    (tester) async {
      final reply = _longPersonaReply();
      final api = _WidgetChatApi(
        detailMessages: <String, List<ChatMessage>>{
          'feed-2': <ChatMessage>[
            const ChatMessage(
              messageId: 'long-reply-user',
              threadId: 'feed-2',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: '请完成这次人设创作',
            ),
            ChatMessage(
              messageId: 'long-reply-assistant',
              threadId: 'feed-2',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: reply,
            ),
          ],
        },
      );
      final chatController = ChatController(api: api, scene: ChatScene.feedAi);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            feedAiChatControllerProvider.overrideWith((ref) => chatController),
          ],
          child: const MaterialApp(home: V3ChatPage()),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      await chatController.loadThreads(refresh: true, selectLatest: false);
      await chatController.selectThread('feed-2');
      await tester.pumpAndSettle();

      final assistant = chatController.state.messages.singleWhere(
        (message) => message.messageId == 'long-reply-assistant',
      );
      expect(assistant.visibleText, reply);
      expect(assistant.visibleText?.length, 20561);
      expect(
        find.byKey(
          const ValueKey('chat-assistant-markdown-long-reply-assistant'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(_longPersonaReplyFinalQuestion),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'V3 visual chat renders generated Resources with shared attachment actions',
    (tester) async {
      final api = _WidgetChatApi(
        detailMessages: <String, List<ChatMessage>>{
          'feed-2': <ChatMessage>[
            const ChatMessage(
              messageId: 'visual-user-1',
              threadId: 'feed-2',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: '请为我的课程设计封面',
            ),
            const ChatMessage(
              messageId: 'visual-assistant-1',
              threadId: 'feed-2',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'succeeded',
              textPreview: '我为你生成了两版封面。',
              imageAttachments: <ChatImageAttachment>[
                ChatImageAttachment(
                  resourceId: 'resource-generated-cover-1',
                  displayName: 'course-cover.png',
                  mimeType: 'image/png',
                ),
              ],
              resourceAttachments: <ChatResourceAttachment>[
                ChatResourceAttachment(
                  kind: ChatResourceAttachmentKind.file,
                  resourceId: 'resource-generated-report-1',
                  displayName: '设计说明.pdf',
                  mimeType: 'application/pdf',
                  sizeBytes: 4096,
                ),
              ],
            ),
          ],
        },
      );
      final chatController = ChatController(api: api, scene: ChatScene.feedAi);
      final playbackTransport = _GeneratedImagePlaybackTransport();
      final resourceImageCache = AuthenticatedResourceImageCache(
        playbackClient: ChatImagePlaybackClient(
          _playbackApiClient(playbackTransport),
        ),
        userScope: 'test-user',
        workspaceScope: 'test-workspace',
        cacheDirectoryProvider: () async => throw StateError('DISK_DISABLED'),
        download: (_) async => ChatImageBytes(
          bytes: Uint8List.fromList(_transparentPng),
          mimeType: 'image/png',
        ),
      );
      addTearDown(resourceImageCache.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            apiClientProvider.overrideWithValue(
              _playbackApiClient(playbackTransport),
            ),
            resourceImageCacheProvider.overrideWithValue(resourceImageCache),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            feedAiChatControllerProvider.overrideWith((ref) => chatController),
          ],
          child: DefaultAssetBundle(
            bundle: _ChatTestAssetBundle(),
            child: MaterialApp(
              home: V3ChatPage(
                workbenchContext: WorkbenchChatContext(
                  skill: WorkbenchChatSkill.visualDesign,
                  materialIds: const <String>[],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await chatController.loadThreads(refresh: true, selectLatest: false);
      await chatController.selectThread('feed-2');
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('我为你生成了两版封面。'), findsOneWidget);
      expect(find.text('AI 生成图片'), findsOneWidget);
      expect(find.text('设计说明.pdf'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('chat-resource-resource-generated-report-1'),
        ),
        findsOneWidget,
      );
      await tester.pump();
      expect(playbackTransport.resourceIds, <String>[
        'resource-generated-cover-1',
      ]);
      final generatedImage = find.byKey(
        const ValueKey<String>('chat-image-resource-generated-cover-1'),
      );
      expect(generatedImage, findsOneWidget);
      final thumbnail = tester.widget<Image>(
        find.descendant(of: generatedImage, matching: find.byType(Image)).first,
      );
      final thumbnailResize = thumbnail.image as ResizeImage;
      expect(thumbnailResize.width, inInclusiveRange(1, 4096));
      expect(thumbnailResize.height, inInclusiveRange(1, 4096));

      tester
          .widget<InkWell>(
            find.descendant(of: generatedImage, matching: find.byType(InkWell)),
          )
          .onTap!();
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip('保存到相册'), findsOneWidget);
      expect(find.byTooltip('关闭图片预览'), findsOneWidget);
      final viewerImages = tester.widgetList<Image>(
        find.descendant(of: find.byType(Dialog), matching: find.byType(Image)),
      );
      expect(
        viewerImages.any(
          (image) =>
              image.image is ResizeImage &&
              (image.image as ResizeImage).width != null &&
              (image.image as ResizeImage).width! > thumbnailResize.width! &&
              (image.image as ResizeImage).width! <= 4096,
        ),
        isTrue,
      );
      await tester.tap(find.byTooltip('关闭图片预览'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pumpAndSettle();
      for (final label in const ['引用笔记', '拍照', '图片']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('本地文件'), findsNothing);
    },
  );

  testWidgets('V3 shared attachment strip previews and removes a ready file', (
    tester,
  ) async {
    String? removedId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3ChatFileAttachmentStrip(
            attachments: const <ChatFileAttachment>[
              ChatFileAttachment(
                localId: 'local-brief',
                displayName: 'brief.pdf',
                mimeType: 'application/pdf',
                sizeBytes: 4096,
                status: ChatFileAttachmentStatus.ready,
                kind: ChatFileAttachmentKind.file,
                resourceId: 'resource-brief',
              ),
            ],
            onRemove: (localId) => removedId = localId,
            onRetry: (_) {},
            onPreview: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('brief.pdf'), findsOneWidget);
    await tester.tap(find.byTooltip('移除资料'));
    expect(removedId, 'local-brief');
  });

  testWidgets('V3 chat shows send progress in the pending message bubble', (
    tester,
  ) async {
    final pendingMutation = Completer<ApiResult<ChatTextMutation>>();
    final api = _WidgetChatApi(textMutationCompleter: pendingMutation);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '请等待这条消息发送');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('chat-pending-send-progress')),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(find.byTooltip('开始实时转写'), findsOneWidget);
    expect(find.byTooltip('复制消息'), findsAtLeastNWidgets(1));
    await tester.enterText(find.byType(TextField), '等待回复时准备的下一条草稿');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '等待回复时准备的下一条草稿',
    );
    expect(
      find.byKey(const ValueKey<String>('chat-assistant-thinking-progress')),
      findsNothing,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pendingMutation.complete(
      _success(
        const ChatTextMutation(
          message: ChatMessage(
            messageId: 'user-pending-message',
            threadId: 'feed-1',
            scene: ChatScene.feedAi,
            role: ChatMessageRole.user,
            contentType: ChatMessageContentType.text,
            status: 'sent',
          ),
        ),
        SubmissionKeyStore.empty,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('V3 chat shows real current and recent tool states', (
    tester,
  ) async {
    const agentRunId = 'agent-run-widget-trace';
    final api = _WidgetChatApi(
      nextAction: const ChatNextAction(
        type: ChatNextActionType.pollAgentRun,
        agentRunId: agentRunId,
      ),
    );
    final trackerRuns = _WidgetAgentRunApi(
      <Future<ApiResult<AgentRunSnapshot>>>[
        Future<ApiResult<AgentRunSnapshot>>.value(
          _success(
            _widgetAgentRun(
              agentRunId: agentRunId,
              status: 'queued',
              toolTrace: <AgentRunToolTrace>[
                AgentRunToolTrace(
                  invocationId: 'invocation-private-id',
                  toolName: 'workspace_search',
                  state: 'finished',
                  outcome: 'succeeded',
                  createdAt: DateTime.utc(2026, 8, 11, 8),
                  completedAt: DateTime.utc(2026, 8, 11, 8, 0, 1),
                  outputFiles: const <AgentRunOutputFile>[],
                ),
                AgentRunToolTrace(
                  invocationId: 'invocation-rejected-id',
                  toolName: 'edit',
                  state: 'rejected',
                  outcome: 'failed',
                  createdAt: DateTime.utc(2026, 8, 11, 8, 0, 2),
                  completedAt: DateTime.utc(2026, 8, 11, 8, 0, 2),
                  outputFiles: const <AgentRunOutputFile>[],
                ),
                AgentRunToolTrace(
                  invocationId: 'invocation-image-id',
                  toolName: 'image_analysis',
                  state: 'started',
                  createdAt: DateTime.utc(2026, 8, 11, 8, 0, 3),
                  outputFiles: const <AgentRunOutputFile>[],
                ),
              ],
            ),
            SubmissionKeyStore.empty,
          ),
        ),
      ],
    );
    final localRuns = _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
      Future<ApiResult<AgentRunSnapshot>>.value(
        _success(
          _widgetAgentRun(agentRunId: agentRunId, status: 'running'),
          SubmissionKeyStore.empty,
        ),
      ),
    ]);
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(trackerRuns),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'test-user',
      pollInterval: const Duration(days: 1),
    );
    await tracker.start();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          assistantRuntimeProvider.overrideWithValue(
            legacyAssistantRuntime(localRuns),
          ),
          chatRunTrackerProvider.overrideWith((ref) => tracker),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '请分析工作区图片');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();

    expect(find.text('执行过程'), findsNothing);
    final assistantTurn = find.byKey(
      const ValueKey<String>('chat-assistant-turn-agent-run-widget-trace'),
    );
    expect(assistantTurn, findsOneWidget);
    expect(
      find.descendant(of: assistantTurn, matching: find.byType(V3ChatMark)),
      findsOneWidget,
    );
    final toolProgress = find.byKey(
      const ValueKey<String>('chat-assistant-tool-progress'),
    );
    expect(toolProgress, findsOneWidget);
    expect(find.text('正在调用工具'), findsOneWidget);
    expect(find.text('分析图片'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('检索工作区'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('编辑内容'), findsOneWidget);
    expect(find.text('未执行'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-assistant-thinking-toggle')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-assistant-thinking-elapsed')),
      findsOneWidget,
    );
    expect(find.text('AI 正在回复...'), findsNothing);
    expect(find.text('invocation-private-id'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'shared Assistant Turn stays identical through run draft and terminal',
    (tester) async {
      const threadId = 'stable-timeline-thread';
      const runId = 'stable-timeline-run';
      const streamMessageId = 'stream-stable-timeline-run';
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[]),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'stable-timeline-user',
        pollInterval: const Duration(days: 1),
      );
      await tracker.start();
      final drafts = ValueNotifier<Map<String, ChatAssistantAnswerDraft>>(
        const <String, ChatAssistantAnswerDraft>{},
      );
      addTearDown(drafts.dispose);
      final tool = AgentRunToolTrace(
        invocationId: 'stable-tool-private-id',
        toolName: 'workspace_search',
        state: 'finished',
        outcome: 'succeeded',
        createdAt: DateTime.utc(2026, 9, 1, 8, 0, 1),
        completedAt: DateTime.utc(2026, 9, 1, 8, 0, 2),
        outputFiles: const <AgentRunOutputFile>[],
      );
      final rejectedTool = AgentRunToolTrace(
        invocationId: 'stable-rejected-tool-private-id',
        toolName: 'image_analysis',
        state: 'rejected',
        createdAt: DateTime.utc(2026, 9, 1, 8, 0, 4),
        completedAt: DateTime.utc(2026, 9, 1, 8, 0, 5),
        outputFiles: const <AgentRunOutputFile>[],
      );
      final runtime = SharedThreadRuntimeInvocation(
        schemaVersion: '1',
        threadId: threadId,
        agentRunId: runId,
        status: 'running',
        agentProfileId: 'standard_creation',
        modelProfileId: 'model-test',
        skillProfileIds: const <String>[],
        contentTypes: const <String>['text'],
        tools: const <SharedRuntimeTool>[],
        files: const <SharedRuntimeFile>[],
        createdAt: DateTime.utc(2026, 9, 1, 8),
        progress: <SharedRuntimeProgress>[
          SharedRuntimeProgress(
            kind: 'status',
            title: '理解问题',
            status: 'completed',
            createdAt: DateTime.utc(2026, 9, 1, 8, 0, 0),
          ),
          SharedRuntimeProgress(
            kind: 'status',
            title: '整理答案',
            status: 'updated',
            createdAt: DateTime.utc(2026, 9, 1, 8, 0, 3),
          ),
        ],
      );

      Future<void> pumpTimeline({
        required List<ChatMessage> messages,
        required String runStatus,
        required bool active,
        List<AgentRunToolTrace> tools = const <AgentRunToolTrace>[],
      }) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              chatRunTrackerProvider.overrideWith((ref) => tracker),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: CustomScrollView(
                  slivers: <Widget>[
                    V3ChatConversationTimeline(
                      key: const ValueKey<String>('stable-timeline'),
                      threadId: threadId,
                      messages: messages,
                      fallbackRunStatuses: <String, String?>{runId: runStatus},
                      fallbackToolRunId: runId,
                      fallbackToolTrace: assistantToolTracesFromLegacy(tools),
                      isSending: active,
                      isThreadPending: () => active,
                      assistantAnswerDrafts: drafts,
                      imageAttachmentsBuilder: (_, __, ___) =>
                          const SizedBox.shrink(),
                      resourceAttachmentsBuilder: (_, __) =>
                          const SizedBox.shrink(),
                      isCreatingNote: (_) => false,
                      createNoteActionFor: (_) => null,
                      onStreamingRebuild: () {},
                      onRunRebuild: () {},
                      runtimeInvocationReader: (_) async =>
                          ChatRuntimeInvocationHistorySnapshot(
                            items: <SharedThreadRuntimeInvocation>[runtime],
                            isSettled: true,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      final turn = find.byKey(
        const ValueKey<String>('chat-assistant-turn-stable-timeline-run'),
      );
      await pumpTimeline(
        messages: const <ChatMessage>[],
        runStatus: 'queued',
        active: true,
      );
      expect(turn, findsOneWidget);
      final initialElement = tester.element(turn);
      expect(
        find.descendant(of: turn, matching: find.byType(V3ChatMark)),
        findsOneWidget,
      );
      expect(find.text('正在准备'), findsOneWidget);

      await pumpTimeline(
        messages: const <ChatMessage>[],
        runStatus: 'running',
        active: true,
        tools: <AgentRunToolTrace>[tool],
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(identical(tester.element(turn), initialElement), isTrue);
      expect(find.text('理解问题'), findsOneWidget);
      expect(find.text('检索工作区'), findsOneWidget);
      expect(find.text('整理答案'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('理解问题')).dy,
        lessThan(tester.getTopLeft(find.text('检索工作区')).dy),
      );
      expect(
        tester.getTopLeft(find.text('检索工作区')).dy,
        lessThan(tester.getTopLeft(find.text('整理答案')).dy),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('理解问题'), findsOneWidget);
      expect(find.text('检索工作区'), findsOneWidget);
      expect(find.text('整理答案'), findsOneWidget);

      await pumpTimeline(
        messages: const <ChatMessage>[],
        runStatus: 'running',
        active: true,
        tools: <AgentRunToolTrace>[rejectedTool],
      );
      expect(find.text('检索工作区'), findsOneWidget);
      expect(find.text('分析图片'), findsOneWidget);
      expect(find.text('未执行'), findsOneWidget);

      drafts.value = const <String, ChatAssistantAnswerDraft>{
        streamMessageId: ChatAssistantAnswerDraft(
          visibleText: '这是回答正文草稿',
          targetText: '这是回答正文草稿',
          source: ChatAssistantAnswerDraftSource.transportDelta,
        ),
      };
      await pumpTimeline(
        messages: const <ChatMessage>[
          ChatMessage(
            messageId: streamMessageId,
            threadId: threadId,
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'streaming',
            agentRunId: runId,
            textPreview: '这是回答正文草稿',
          ),
        ],
        runStatus: 'running',
        active: true,
        tools: <AgentRunToolTrace>[tool],
      );
      expect(identical(tester.element(turn), initialElement), isTrue);
      final processCard = find.byKey(
        const ValueKey<String>('chat-assistant-thinking-bubble'),
      );
      final answerDraft = find.byKey(
        const ValueKey<String>('chat-assistant-draft-$streamMessageId'),
      );
      expect(answerDraft, findsOneWidget);
      expect(
        find.descendant(of: processCard, matching: answerDraft),
        findsNothing,
      );

      await pumpTimeline(
        messages: const <ChatMessage>[
          ChatMessage(
            messageId: 'stable-timeline-final',
            threadId: threadId,
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'succeeded',
            agentRunId: runId,
            textPreview: '这是最终正式回答',
          ),
        ],
        runStatus: 'succeeded',
        active: false,
      );
      expect(identical(tester.element(turn), initialElement), isTrue);
      expect(find.text('这是最终正式回答'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-assistant-thinking-bubble')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-assistant-thinking-toggle')),
        findsOneWidget,
      );
      expect(find.textContaining('已完成 · 用时'), findsOneWidget);
      expect(find.text('理解问题'), findsNothing);
      expect(find.text('检索工作区'), findsNothing);
      expect(find.text('整理答案'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('chat-assistant-thinking-toggle')),
      );
      await tester.pump();
      expect(find.text('理解问题'), findsOneWidget);
      expect(find.text('检索工作区'), findsOneWidget);
      expect(find.text('整理答案'), findsOneWidget);
      expect(find.text('stable-tool-private-id'), findsNothing);
    },
  );

  testWidgets(
    'shared timeline closes a failed tracker Run without a durable reply',
    (tester) async {
      const threadId = 'feed-1';
      const runId = 'agent-run-terminal-failure';
      final runApi = _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
        Future<ApiResult<AgentRunSnapshot>>.value(
          _success(
            _widgetAgentRun(agentRunId: runId, status: 'running'),
            SubmissionKeyStore.empty,
          ),
        ),
        Future<ApiResult<AgentRunSnapshot>>.value(
          _success(
            _widgetAgentRun(agentRunId: runId, status: 'failed'),
            SubmissionKeyStore.empty,
          ),
        ),
      ]);
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(runApi),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'terminal-failure-user',
        pollInterval: const Duration(days: 1),
        eventStreamReconnectDelay: const Duration(days: 1),
      );
      await tracker.start();
      await tracker.track(
        agentRunId: runId,
        threadId: threadId,
        scene: ChatScene.feedAi,
      );
      await tracker.refresh();
      expect(
        tracker.activityFor(threadId: threadId, agentRunId: runId)?.status,
        'running',
      );
      expect(tracker.lastCompletion, isNull);
      final drafts = ValueNotifier<Map<String, ChatAssistantAnswerDraft>>(
        const <String, ChatAssistantAnswerDraft>{
          'stream-agent-run-terminal-failure': ChatAssistantAnswerDraft(
            visibleText: '失败前已经返回的正文',
            targetText: '失败前已经返回的正文',
            source: ChatAssistantAnswerDraftSource.transportDelta,
          ),
        },
      );
      addTearDown(drafts.dispose);
      var runtimeReads = 0;
      var runtimeStatus = 'running';

      await tester.pumpWidget(
        _sharedTimelineHarness(
          tracker: tracker,
          timelineKey: const ValueKey<String>('terminal-failure-timeline'),
          threadId: threadId,
          messages: const <ChatMessage>[
            ChatMessage(
              messageId: 'stream-agent-run-terminal-failure',
              threadId: threadId,
              scene: ChatScene.feedAi,
              role: ChatMessageRole.assistant,
              contentType: ChatMessageContentType.text,
              status: 'streaming',
              agentRunId: runId,
              textPreview: '失败前已经返回的正文',
              localDelivery: ChatLocalDeliveryState.pending,
            ),
          ],
          fallbackRunStatuses: const <String, String?>{runId: 'queued'},
          fallbackToolRunId: runId,
          threadPending: true,
          drafts: drafts,
          runtimeInvocationReader: (_) async {
            runtimeReads += 1;
            return ChatRuntimeInvocationHistorySnapshot(
              items: <SharedThreadRuntimeInvocation>[
                SharedThreadRuntimeInvocation(
                  schemaVersion: '1',
                  threadId: threadId,
                  agentRunId: runId,
                  status: runtimeStatus,
                  agentProfileId: 'standard_creation',
                  modelProfileId: 'model-test',
                  skillProfileIds: <String>[],
                  contentTypes: <String>['text'],
                  tools: <SharedRuntimeTool>[],
                  files: <SharedRuntimeFile>[],
                  progress: <SharedRuntimeProgress>[],
                  completedAt: runtimeStatus == 'running'
                      ? null
                      : DateTime.utc(2026, 9, 2, 8, 0, 2),
                ),
              ],
              isSettled: true,
            );
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      final turn = find.byKey(
        const ValueKey<String>('chat-assistant-turn-$runId'),
      );
      expect(turn, findsOneWidget);
      final activeElement = tester.element(turn);

      runtimeStatus = 'failed';
      await tracker.refresh();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(turn, findsOneWidget);
      expect(identical(tester.element(turn), activeElement), isTrue);
      expect(find.textContaining('处理失败 · 用时'), findsOneWidget);
      expect(find.text('失败前已经返回的正文'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-assistant-thinking-elapsed')),
        findsNothing,
      );
      final readsAtTerminal = runtimeReads;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(runtimeReads, readsAtTerminal);
    },
  );

  testWidgets('shared timeline freezes aborted and rejected runtime Runs', (
    tester,
  ) async {
    const threadId = 'runtime-terminal-boundary-thread';
    const abortedRunId = 'runtime-terminal-aborted-run';
    const rejectedRunId = 'runtime-terminal-rejected-run';
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[]),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'runtime-terminal-boundary-user',
      pollInterval: const Duration(days: 1),
    );
    await tracker.start();
    final drafts = ValueNotifier<Map<String, ChatAssistantAnswerDraft>>(
      const <String, ChatAssistantAnswerDraft>{},
    );
    addTearDown(drafts.dispose);
    SharedThreadRuntimeInvocation runtime(String runId, String status) =>
        SharedThreadRuntimeInvocation(
          schemaVersion: 'huahuo.thread-runtime-invocation.v1',
          threadId: threadId,
          agentRunId: runId,
          status: status,
          agentProfileId: 'self_media_creation_standard',
          modelProfileId: 'model-test',
          skillProfileIds: const <String>[],
          contentTypes: const <String>['text'],
          tools: const <SharedRuntimeTool>[],
          files: const <SharedRuntimeFile>[],
          createdAt: DateTime.utc(2026, 9, 2, 8),
          completedAt: status == 'running'
              ? null
              : DateTime.utc(2026, 9, 2, 8, 0, 4),
        );

    var runtimeItems = <SharedThreadRuntimeInvocation>[
      runtime(abortedRunId, 'running'),
      runtime(rejectedRunId, 'running'),
    ];
    var runtimeReads = 0;
    await tester.pumpWidget(
      _sharedTimelineHarness(
        tracker: tracker,
        timelineKey: const ValueKey<String>('runtime-terminal-boundary'),
        threadId: threadId,
        messages: const <ChatMessage>[],
        fallbackRunStatuses: const <String, String?>{
          abortedRunId: 'running',
          rejectedRunId: 'running',
        },
        threadPending: true,
        drafts: drafts,
        runtimeInvocationReader: (_) async {
          runtimeReads += 1;
          return ChatRuntimeInvocationHistorySnapshot(
            items: runtimeItems,
            isSettled: true,
          );
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    runtimeItems = <SharedThreadRuntimeInvocation>[
      runtime(abortedRunId, 'aborted'),
      runtime(rejectedRunId, 'rejected'),
    ];
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.textContaining('已停止 · 用时'), findsOneWidget);
    expect(find.textContaining('未能开始处理 · 用时'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-assistant-thinking-elapsed')),
      findsNothing,
    );
    final readsAtTerminal = runtimeReads;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(runtimeReads, readsAtTerminal);
  });

  testWidgets('newer terminal Run closes an older active presentation', (
    tester,
  ) async {
    const threadId = 'terminal-over-active-thread';
    const olderRunId = 'terminal-over-active-older';
    const newerRunId = 'terminal-over-active-newer';
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[]),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'terminal-over-active-user',
      pollInterval: const Duration(days: 1),
    );
    await tracker.start();
    final drafts = ValueNotifier<Map<String, ChatAssistantAnswerDraft>>(
      const <String, ChatAssistantAnswerDraft>{},
    );
    addTearDown(drafts.dispose);

    await tester.pumpWidget(
      _sharedTimelineHarness(
        tracker: tracker,
        timelineKey: const ValueKey<String>('terminal-over-active-timeline'),
        threadId: threadId,
        messages: const <ChatMessage>[],
        fallbackRunStatuses: const <String, String?>{},
        drafts: drafts,
        runtimeInvocationReader: (_) async =>
            ChatRuntimeInvocationHistorySnapshot(
              items: <SharedThreadRuntimeInvocation>[
                SharedThreadRuntimeInvocation(
                  schemaVersion: '1',
                  threadId: threadId,
                  agentRunId: olderRunId,
                  status: 'running',
                  agentProfileId: 'standard_creation',
                  modelProfileId: 'model-test',
                  skillProfileIds: <String>[],
                  contentTypes: <String>['text'],
                  tools: <SharedRuntimeTool>[],
                  files: <SharedRuntimeFile>[],
                  createdAt: DateTime.utc(2026, 9, 2, 8),
                ),
                SharedThreadRuntimeInvocation(
                  schemaVersion: '1',
                  threadId: threadId,
                  agentRunId: newerRunId,
                  status: 'failed',
                  agentProfileId: 'standard_creation',
                  modelProfileId: 'model-test',
                  skillProfileIds: <String>[],
                  contentTypes: <String>['text'],
                  tools: <SharedRuntimeTool>[],
                  files: <SharedRuntimeFile>[],
                  createdAt: DateTime.utc(2026, 9, 2, 8, 0, 1),
                  completedAt: DateTime.utc(2026, 9, 2, 8, 0, 2),
                ),
              ],
              isSettled: true,
            ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('chat-assistant-turn-$olderRunId')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-assistant-thinking-progress')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-assistant-thinking-elapsed')),
      findsNothing,
    );
  });

  testWidgets('shared timeline exposes one exact mutable Run per Thread', (
    tester,
  ) async {
    const threadId = 'feed-1';
    const firstRunId = 'agent-run-exact-first';
    const secondRunId = 'agent-run-exact-second';
    final firstTool = AgentRunToolTrace(
      invocationId: 'first-run-tool',
      toolName: 'workspace_search',
      state: 'finished',
      outcome: 'succeeded',
      createdAt: DateTime.utc(2026, 9, 1, 8),
      completedAt: DateTime.utc(2026, 9, 1, 8, 0, 1),
      outputFiles: const <AgentRunOutputFile>[],
    );
    final secondTool = AgentRunToolTrace(
      invocationId: 'second-run-tool',
      toolName: 'image_analysis',
      state: 'finished',
      outcome: 'succeeded',
      createdAt: DateTime.utc(2026, 9, 1, 8, 0, 2),
      completedAt: DateTime.utc(2026, 9, 1, 8, 0, 3),
      outputFiles: const <AgentRunOutputFile>[],
    );
    final fallbackTool = AgentRunToolTrace(
      invocationId: 'fallback-tool',
      toolName: 'write',
      state: 'started',
      createdAt: DateTime.utc(2026, 9, 1, 8, 0, 4),
      outputFiles: const <AgentRunOutputFile>[],
    );
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(
        _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
          Future<ApiResult<AgentRunSnapshot>>.value(
            _success(
              _widgetAgentRun(
                agentRunId: firstRunId,
                status: 'running',
                toolTrace: <AgentRunToolTrace>[firstTool],
              ),
              SubmissionKeyStore.empty,
            ),
          ),
          Future<ApiResult<AgentRunSnapshot>>.value(
            _success(
              _widgetAgentRun(
                agentRunId: secondRunId,
                status: 'queued',
                toolTrace: <AgentRunToolTrace>[secondTool],
              ),
              SubmissionKeyStore.empty,
            ),
          ),
        ]),
      ),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'exact-run-user',
      pollInterval: const Duration(days: 1),
      eventStreamReconnectDelay: const Duration(days: 1),
    );
    await tracker.start();
    await tracker.track(
      agentRunId: firstRunId,
      threadId: threadId,
      scene: ChatScene.feedAi,
    );
    await tracker.track(
      agentRunId: secondRunId,
      threadId: threadId,
      scene: ChatScene.feedAi,
    );
    final drafts = ValueNotifier<Map<String, ChatAssistantAnswerDraft>>(
      const <String, ChatAssistantAnswerDraft>{},
    );
    addTearDown(drafts.dispose);

    await tester.pumpWidget(
      _sharedTimelineHarness(
        tracker: tracker,
        timelineKey: const ValueKey<String>('exact-run-timeline'),
        threadId: threadId,
        messages: const <ChatMessage>[],
        fallbackRunStatuses: const <String, String?>{
          firstRunId: 'queued',
          secondRunId: 'running',
        },
        fallbackToolRunId: firstRunId,
        fallbackToolTrace: <AgentRunToolTrace>[fallbackTool],
        threadPending: true,
        drafts: drafts,
        runtimeInvocationReader: (_) async =>
            ChatRuntimeInvocationHistorySnapshot(
              items: <SharedThreadRuntimeInvocation>[
                SharedThreadRuntimeInvocation(
                  schemaVersion: '1',
                  threadId: threadId,
                  agentRunId: firstRunId,
                  status: 'running',
                  agentProfileId: 'standard_creation',
                  modelProfileId: 'model-test',
                  skillProfileIds: <String>[],
                  contentTypes: <String>['text'],
                  tools: <SharedRuntimeTool>[],
                  files: <SharedRuntimeFile>[],
                  progress: <SharedRuntimeProgress>[
                    SharedRuntimeProgress(
                      kind: 'status',
                      title: '核对第一轮资料',
                      status: 'completed',
                      createdAt: DateTime.utc(2026, 9, 1, 8, 0, 1),
                    ),
                  ],
                ),
                SharedThreadRuntimeInvocation(
                  schemaVersion: '1',
                  threadId: threadId,
                  agentRunId: secondRunId,
                  status: 'running',
                  agentProfileId: 'standard_creation',
                  modelProfileId: 'model-test',
                  skillProfileIds: <String>[],
                  contentTypes: <String>['text'],
                  tools: <SharedRuntimeTool>[],
                  files: <SharedRuntimeFile>[],
                  progress: <SharedRuntimeProgress>[
                    SharedRuntimeProgress(
                      kind: 'status',
                      title: '整理第二轮答案',
                      status: 'updated',
                      createdAt: DateTime.utc(2026, 9, 1, 8, 0, 2),
                    ),
                  ],
                ),
              ],
              isSettled: true,
            ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    final firstTurn = find.byKey(
      const ValueKey<String>('chat-assistant-turn-$firstRunId'),
    );
    final secondTurn = find.byKey(
      const ValueKey<String>('chat-assistant-turn-$secondRunId'),
    );
    expect(firstTurn, findsOneWidget);
    expect(secondTurn, findsNothing);
    expect(
      find.descendant(of: firstTurn, matching: find.text('正在处理')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: firstTurn, matching: find.text('检索工作区')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: firstTurn, matching: find.text('核对第一轮资料')),
      findsOneWidget,
    );
    expect(find.text('分析图片'), findsNothing);
    expect(find.text('整理第二轮答案'), findsNothing);
    expect(find.text('整理并写入内容'), findsNothing);
  });

  testWidgets(
    'shared timeline reveals only a new answer for an observed active Run',
    (tester) async {
      const threadId = 'run-scoped-reveal-thread';
      const activeRunId = 'run-scoped-reveal-active';
      const unrelatedRunId = 'run-scoped-reveal-unrelated';
      const historicalId = 'assistant-history-hydration';
      const unrelatedId = 'assistant-unrelated-run-hydration';
      const liveId = 'assistant-observed-active-run';
      final tracker = ChatRunTracker(
        assistantRuntime: legacyAssistantRuntime(
          _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[]),
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'run-scoped-reveal-user',
        pollInterval: const Duration(days: 1),
      );
      await tracker.start();
      final drafts = ValueNotifier<Map<String, ChatAssistantAnswerDraft>>(
        const <String, ChatAssistantAnswerDraft>{},
      );
      addTearDown(drafts.dispose);

      Future<void> pumpTimeline({
        required List<ChatMessage> messages,
        required bool sending,
        required Map<String, String?> fallbackRunStatuses,
      }) async {
        await tester.pumpWidget(
          _sharedTimelineHarness(
            tracker: tracker,
            timelineKey: const ValueKey<String>('run-scoped-reveal-timeline'),
            threadId: threadId,
            messages: messages,
            fallbackRunStatuses: fallbackRunStatuses,
            isSending: sending,
            drafts: drafts,
          ),
        );
        await tester.pump();
      }

      await pumpTimeline(
        messages: const <ChatMessage>[],
        sending: true,
        fallbackRunStatuses: const <String, String?>{activeRunId: 'running'},
      );
      await pumpTimeline(
        messages: const <ChatMessage>[
          ChatMessage(
            messageId: historicalId,
            threadId: threadId,
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'succeeded',
            textPreview: '这是批量加载的无 Run 历史回答。',
          ),
          ChatMessage(
            messageId: unrelatedId,
            threadId: threadId,
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'succeeded',
            agentRunId: unrelatedRunId,
            textPreview: '这是批量加载的其他 Run 历史回答。',
          ),
          ChatMessage(
            messageId: liveId,
            threadId: threadId,
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'succeeded',
            agentRunId: activeRunId,
            textPreview: '这是当前已观察活动 Run 的正式回答，应当平滑显示。',
          ),
        ],
        sending: false,
        fallbackRunStatuses: const <String, String?>{},
      );
      expect(
        find.byKey(
          const ValueKey<String>('chat-assistant-local-reveal-$historicalId'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('chat-assistant-markdown-$historicalId'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('chat-assistant-local-reveal-$unrelatedId'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('chat-assistant-markdown-$unrelatedId'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('chat-assistant-local-reveal-$liveId'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('V3 chat keeps answer draft outside the active Run card', (
    tester,
  ) async {
    const agentRunId = 'agent-run-widget-inline-stream';
    const secondAgentRunId = 'agent-run-widget-standalone-update';
    const streamedReply = '这是流式正文。为了验证局部更新边界，这段回复会按照既有节奏逐字展示，并保持聊天页面骨架稳定。';
    final rebuildMetrics = RuntimeActivityMetrics();
    addTearDown(rebuildMetrics.dispose);
    int rebuildCount(String owner) =>
        rebuildMetrics.snapshot().rebuildsByOwner[owner] ?? 0;
    final api = _WidgetChatApi(
      nextAction: const ChatNextAction(
        type: ChatNextActionType.pollAgentRun,
        agentRunId: agentRunId,
      ),
      progressPages: <AssistantProgressPage>[
        const AssistantProgressPage(
          conversationId: 'feed-1',
          nextSequence: 1,
          events: <AssistantProgressEvent>[
            AssistantProgressEvent(
              sequence: 1,
              type: AssistantProgressEventType.draftDelta,
              runHandle: agentRunId,
              deltaText: streamedReply,
            ),
          ],
        ),
      ],
    );
    final trackerRuns =
        _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
          Future<ApiResult<AgentRunSnapshot>>.value(
            _success(
              _widgetAgentRun(agentRunId: agentRunId, status: 'running'),
              SubmissionKeyStore.empty,
            ),
          ),
        ]);
    final localRuns = _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
      Future<ApiResult<AgentRunSnapshot>>.value(
        _success(
          _widgetAgentRun(agentRunId: agentRunId, status: 'running'),
          SubmissionKeyStore.empty,
        ),
      ),
    ]);
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(trackerRuns),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'inline-stream-user',
      pollInterval: const Duration(days: 1),
    );
    await tracker.start();
    final controller = ChatController(
      api: api,
      assistantProgress: api,
      assistantRuntime: legacyAssistantRuntime(localRuns),
      runTracker: tracker,
      scene: ChatScene.feedAi,
      taskPollInterval: Duration.zero,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          assistantRuntimeProvider.overrideWithValue(
            legacyAssistantRuntime(localRuns),
          ),
          chatRunTrackerProvider.overrideWith((ref) => tracker),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          runtimeActivityMetricsProvider.overrideWithValue(rebuildMetrics),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(
          home: V3ChatPage(windowId: 'inline-stream-window'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '请流式回答');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 40 && rebuildCount('chat_streaming_bubble') == 0;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(rebuildCount('chat_streaming_bubble'), greaterThan(0));

    final surfaceBeforeToken = rebuildCount('chat_page_surface');
    final runBeforeToken = rebuildCount('chat_current_run');
    final bubbleBeforeToken = rebuildCount('chat_streaming_bubble');
    await tester.pump(const Duration(milliseconds: 50));
    expect(rebuildCount('chat_page_surface'), surfaceBeforeToken);
    expect(rebuildCount('chat_current_run'), runBeforeToken);
    expect(
      rebuildCount('chat_streaming_bubble'),
      greaterThan(bubbleBeforeToken),
    );
    await tester.pump(const Duration(seconds: 2));

    final content = find.byKey(
      const ValueKey<String>(
        'chat-assistant-content-agent-run-widget-inline-stream',
      ),
    );
    await tester.scrollUntilVisible(
      content,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    final activity = find.byKey(
      const ValueKey<String>('chat-assistant-thinking-bubble'),
    );
    final markdown = find.byKey(
      const ValueKey<String>(
        'chat-assistant-markdown-stream-agent-run-widget-inline-stream',
      ),
    );
    final answerDraft = find.byKey(
      const ValueKey<String>(
        'chat-assistant-draft-stream-agent-run-widget-inline-stream',
      ),
    );

    expect(content, findsOneWidget);
    expect(activity, findsOneWidget);
    expect(find.descendant(of: content, matching: activity), findsOneWidget);
    expect(markdown, findsNothing);
    expect(answerDraft, findsOneWidget);
    expect(find.descendant(of: activity, matching: answerDraft), findsNothing);
    final answerText = find.descendant(
      of: answerDraft,
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(answerText).style?.fontSize, 15);
    expect(tester.widget<Text>(answerText).maxLines, isNull);
    expect(
      find.byKey(const ValueKey<String>('chat-assistant-thinking-elapsed')),
      findsOneWidget,
    );
    expect(find.text(streamedReply), findsOneWidget);
    final rebuilds = rebuildMetrics.snapshot().rebuildsByOwner;
    expect(rebuilds['chat_current_run'], greaterThan(0));
    expect(rebuilds['chat_streaming_bubble'], greaterThan(0));
    expect(rebuilds['app_root'], isNull);
    expect(
      rebuilds.keys,
      everyElement(
        allOf(isNot(contains('feed-1')), isNot(contains(agentRunId))),
      ),
    );

    tracker.pause();
    await tester.pump();
    final surfaceBeforeRun = rebuildCount('chat_page_surface');
    final runBeforeRun = rebuildCount('chat_current_run');
    final bubbleBeforeRun = rebuildCount('chat_streaming_bubble');
    await tracker.track(
      agentRunId: secondAgentRunId,
      threadId: 'feed-1',
      scene: ChatScene.feedAi,
    );
    await tester.pump();
    expect(rebuildCount('chat_page_surface'), surfaceBeforeRun);
    expect(rebuildCount('chat_current_run'), greaterThan(runBeforeRun));
    expect(rebuildCount('chat_streaming_bubble'), bubbleBeforeRun);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('V3 chat keeps one exact Run as the mutable Assistant Turn', (
    tester,
  ) async {
    const streamedRunId = 'agent-run-widget-first-draft';
    const pendingRunId = 'agent-run-widget-before-draft';
    final api = _WidgetChatApi(
      nextAction: const ChatNextAction(
        type: ChatNextActionType.pollAgentRun,
        agentRunId: streamedRunId,
      ),
      progressPages: <AssistantProgressPage>[
        const AssistantProgressPage(
          conversationId: 'feed-1',
          nextSequence: 1,
          events: <AssistantProgressEvent>[
            AssistantProgressEvent(
              sequence: 1,
              type: AssistantProgressEventType.draftDelta,
              runHandle: streamedRunId,
              deltaText: '第一条 Run 的流式正文。',
            ),
          ],
        ),
      ],
    );
    final trackerRuns =
        _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
          Future<ApiResult<AgentRunSnapshot>>.value(
            _success(
              _widgetAgentRun(agentRunId: streamedRunId, status: 'running'),
              SubmissionKeyStore.empty,
            ),
          ),
          Future<ApiResult<AgentRunSnapshot>>.value(
            _success(
              _widgetAgentRun(agentRunId: streamedRunId, status: 'running'),
              SubmissionKeyStore.empty,
            ),
          ),
          Future<ApiResult<AgentRunSnapshot>>.value(
            _success(
              _widgetAgentRun(agentRunId: pendingRunId, status: 'running'),
              SubmissionKeyStore.empty,
            ),
          ),
        ]);
    final localRuns = _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
      Future<ApiResult<AgentRunSnapshot>>.value(
        _success(
          _widgetAgentRun(agentRunId: streamedRunId, status: 'running'),
          SubmissionKeyStore.empty,
        ),
      ),
    ]);
    final tracker = ChatRunTracker(
      assistantRuntime: legacyAssistantRuntime(trackerRuns),
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'concurrent-inline-stream-user',
      pollInterval: const Duration(days: 1),
    );
    await tracker.start();
    final controller = ChatController(
      api: api,
      assistantProgress: api,
      assistantRuntime: legacyAssistantRuntime(localRuns),
      runTracker: tracker,
      scene: ChatScene.feedAi,
      taskPollInterval: Duration.zero,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          assistantRuntimeProvider.overrideWithValue(
            legacyAssistantRuntime(localRuns),
          ),
          chatRunTrackerProvider.overrideWith((ref) => tracker),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(
          home: V3ChatPage(windowId: 'concurrent-stream-window'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '请并行回答');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 850));
    await tracker.track(
      agentRunId: pendingRunId,
      threadId: 'feed-1',
      scene: ChatScene.feedAi,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    final content = find.byKey(
      const ValueKey<String>(
        'chat-assistant-content-agent-run-widget-first-draft',
      ),
    );
    await tester.scrollUntilVisible(
      content,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    final activity = find.byKey(
      const ValueKey<String>('chat-assistant-thinking-bubble'),
    );

    expect(content, findsOneWidget);
    expect(activity, findsOneWidget);
    expect(find.descendant(of: content, matching: activity), findsOneWidget);
    expect(find.text('第一条 Run 的流式正文。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final reduceMotion in const <bool>[false, true]) {
    testWidgets(
      'V3 chat renders a terminal tracker reply without a page completion event'
      '${reduceMotion ? ' with Reduce Motion' : ''}',
      (tester) async {
        const agentRunId = 'agent-run-widget-terminal';
        const assistantId = 'assistant-widget-terminal';
        final details = <String, List<ChatMessage>>{
          'feed-1': <ChatMessage>[
            const ChatMessage(
              messageId: 'user-feed-1',
              threadId: 'feed-1',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.text,
              status: 'sent',
              textPreview: '已有会话',
            ),
          ],
        };
        final api = _WidgetChatApi(
          detailMessages: details,
          nextAction: const ChatNextAction(
            type: ChatNextActionType.pollAgentRun,
            agentRunId: agentRunId,
          ),
        );
        final trackerRuns =
            _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
              Future<ApiResult<AgentRunSnapshot>>.value(
                _success(
                  _widgetAgentRun(agentRunId: agentRunId, status: 'running'),
                  SubmissionKeyStore.empty,
                ),
              ),
              Future<ApiResult<AgentRunSnapshot>>.value(
                _success(
                  _widgetAgentRun(
                    agentRunId: agentRunId,
                    status: 'succeeded',
                    assistantMessageId: assistantId,
                    completionMode: 'normal',
                  ),
                  SubmissionKeyStore.empty,
                ),
              ),
            ]);
        final tracker = ChatRunTracker(
          assistantRuntime: legacyAssistantRuntime(trackerRuns),
          preferences: AppPreferencesDao(AppDatabase()),
          userScope: 'widget-account',
          pollInterval: const Duration(days: 1),
        );
        await tracker.start();
        final localRuns =
            _WidgetAgentRunApi(<Future<ApiResult<AgentRunSnapshot>>>[
              Future<ApiResult<AgentRunSnapshot>>.value(
                _success(
                  _widgetAgentRun(agentRunId: agentRunId, status: 'running'),
                  SubmissionKeyStore.empty,
                ),
              ),
            ]);
        final chatController = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(localRuns),
          runTracker: tracker,
          scene: ChatScene.feedAi,
          workspaceReady: () => true,
          taskPollInterval: Duration.zero,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              ...mobileAgentReadyTestOverrides(),
              chatRepositoryProvider.overrideWithValue(api),
              assistantRuntimeProvider.overrideWithValue(
                legacyAssistantRuntime(localRuns),
              ),
              chatRunTrackerProvider.overrideWith((ref) => tracker),
              feedAiChatControllerProvider.overrideWith(
                (ref) => chatController,
              ),
              resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduceMotion),
                  child: const V3ChatPage(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), '请返回聚合内容');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
        await tester.pump();
        await tester.pump();
        expect(trackerRuns.calls, hasLength(1));

        details['feed-1'] = <ChatMessage>[
          ...details['feed-1']!,
          const ChatMessage(
            messageId: 'user-widget-terminal',
            threadId: 'feed-1',
            scene: ChatScene.feedAi,
            role: ChatMessageRole.user,
            contentType: ChatMessageContentType.text,
            status: 'sent',
            textPreview: '请返回聚合内容',
          ),
          const ChatMessage(
            messageId: assistantId,
            threadId: 'feed-1',
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'succeeded',
            textPreview: '聚合后的服务端回复。',
            agentRunId: agentRunId,
          ),
        ];
        await tracker.refresh();
        await tester.pump(const Duration(milliseconds: 2));
        await tester.pump();

        expect(trackerRuns.calls, hasLength(2));
        final localReveal = find.byKey(
          const ValueKey<String>(
            'chat-assistant-local-reveal-assistant-widget-terminal',
          ),
        );
        if (reduceMotion) {
          expect(localReveal, findsNothing);
          expect(find.text('聚合后的服务端回复。'), findsOneWidget);
        } else {
          expect(localReveal, findsOneWidget);
          await tester.pump(const Duration(seconds: 2));
          expect(find.text('聚合后的服务端回复。'), findsOneWidget);
        }
        expect(
          find.byKey(const ValueKey<String>('chat-assistant-thinking-bubble')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('chat-assistant-thinking-toggle')),
          findsOneWidget,
        );
        expect(find.textContaining('已完成 · 用时'), findsOneWidget);
        expect(find.text('Agent 任务已排队'), findsNothing);
        expect(api.detailThreadIds.where((id) => id == 'feed-1').length, 2);
      },
    );
  }

  testWidgets('V3 chat localizes unavailable backend admission failures', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi(sendFailureCode: 'AGENT_PROFILE_NOT_SELECTABLE');
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '测试普通聊天');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(find.text('当前聊天助手尚未发布，请稍后再试。'), findsOneWidget);
    expect(find.textContaining('AGENT_PROFILE_NOT_SELECTABLE'), findsNothing);
    expect(find.text('测试普通聊天'), findsNWidgets(2));
    expect(find.textContaining('我会围绕'), findsNothing);
  });

  testWidgets('V3 chat top tools remain visible in dark theme', (tester) async {
    final api = _WidgetChatApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.dark(),
          home: const V3ChatPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    for (final tooltip in <String>['会话列表', '新建会话']) {
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.color, HuahuoV3Theme.darkTokens.ink);
    }
    final assistantText = tester.widget<Text>(find.text('服务器已返回的内容'));
    expect(assistantText.style?.color, HuahuoV3Theme.darkTokens.text);
    final assistantContent = find.byKey(
      const ValueKey<String>('chat-assistant-content-assistant-feed-1'),
    );
    expect(assistantContent, findsOneWidget);
    expect(tester.widget(assistantContent), isA<Padding>());
    expect(tester.getSize(assistantContent).width, greaterThan(350));
    expect(
      find.byKey(
        const ValueKey<String>('chat-assistant-bubble-assistant-feed-1'),
      ),
      findsNothing,
    );
    final userGlass = find.byKey(
      const ValueKey<String>('chat-user-glass-user-feed-1'),
    );
    expect(userGlass, findsOneWidget);
    expect(tester.widget(userGlass), isA<Container>());
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byTooltip('会话列表'),
              matching: find.byType(Icon),
            ),
          )
          .icon,
      LucideIcons.history,
    );
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byTooltip('新建会话'),
              matching: find.byType(Icon),
            ),
          )
          .icon,
      LucideIcons.messageSquarePlus,
    );
  });

  testWidgets('account history survives thread and new-chat round trips', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final router = GoRouter(
      initialLocation: '/account',
      routes: [
        GoRoute(
          path: '/account',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/v3/feed/chat?history=1'),
              child: const Text('账号的对话历史入口'),
            ),
          ),
        ),
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) {
            if (state.uri.queryParameters['history'] == '1') {
              return const V3ChatPage(
                showHistoryOnStart: true,
                launchMode: ChatLaunchMode.history,
              );
            }
            return V3PageScaffold(
              title: state.uri.queryParameters['threadId'] == 'feed-1'
                  ? '历史详情页'
                  : '新会话页',
              fallbackRoute: '/home',
              children: [
                TextButton(
                  onPressed: () => context.replace(
                    '/v3/feed/chat?window=history-replaced-child',
                  ),
                  child: const Text('在详情内新建会话'),
                ),
              ],
            );
          },
        ),
        GoRoute(
          path: '/home',
          builder: (context, state) => const Scaffold(body: Text('错误的首页')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('账号的对话历史入口'));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('chat-history-search'));
    await tester.enterText(search, '客户访谈');
    await tester.pumpAndSettle();

    for (final useSystemBack in [false, true]) {
      await tester.tap(find.byKey(const ValueKey('chat-history-row-feed-1')));
      await tester.pumpAndSettle();
      expect(find.text('历史详情页'), findsOneWidget);
      if (useSystemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.bySemanticsLabel('返回'));
      }
      await tester.pumpAndSettle();
      expect(search, findsOneWidget);
      expect(tester.widget<TextField>(search).controller!.text, '客户访谈');
    }

    await tester.tap(find.byKey(const ValueKey('chat-history-row-feed-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在详情内新建会话'));
    await tester.pumpAndSettle();
    expect(find.text('新会话页'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, '客户访谈');
    await tester.tap(find.byKey(const ValueKey('chat-history-row-feed-1')));
    await tester.pumpAndSettle();
    expect(find.text('历史详情页'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('新建会话'));
    await tester.pumpAndSettle();
    expect(find.text('新会话页'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('返回'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, '客户访谈');

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('账号的对话历史入口'), findsOneWidget);
    expect(find.text('错误的首页'), findsNothing);
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat back returns to the immediate source page', (tester) async {
    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/chat'),
              child: const Text('打开聊天'),
            ),
          ),
        ),
        GoRoute(path: '/chat', builder: (context, state) => const V3ChatPage()),
        GoRoute(
          path: '/v3/feed',
          builder: (context, state) => const Scaffold(body: Text('思想图谱')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(_WidgetChatApi()),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
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
    await tester.tap(find.text('打开聊天'));
    await tester.pumpAndSettle();
    expect(find.byType(V3ChatPage), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('打开聊天'), findsOneWidget);
    expect(find.text('思想图谱'), findsNothing);
  });

  testWidgets('direct chat fallbacks follow their visible source', (
    tester,
  ) async {
    Future<V3PageScaffold> pump(V3ChatPage page) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(_WidgetChatApi()),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp(home: page),
        ),
      );
      await tester.pump();
      return tester.widget<V3PageScaffold>(find.byType(V3PageScaffold));
    }

    var scaffold = await pump(const V3ChatPage());
    expect(scaffold.backBehavior, V3BackBehavior.popThenFallback);
    expect(scaffold.fallbackRoute, '/v3/feed');

    scaffold = await pump(
      V3ChatPage(
        workbenchContext: WorkbenchChatContext(
          skill: WorkbenchChatSkill.visualDesign,
          materialIds: const [],
        ),
      ),
    );
    expect(scaffold.fallbackRoute, '/v3/workbench');

    scaffold = await pump(
      V3ChatPage(
        workbenchContext: WorkbenchChatContext(
          skill: WorkbenchChatSkill.masterpiece,
          materialIds: const [],
        ),
      ),
    );
    expect(scaffold.fallbackRoute, '/v3/masterpiece');

    scaffold = await pump(
      V3ChatPage(
        conversationPurpose: ChatConversationPurpose.deepPositioning,
        workbenchContext: WorkbenchChatContext(
          skill: WorkbenchChatSkill.socialPositioning,
          materialIds: const [],
        ),
      ),
    );
    expect(scaffold.fallbackRoute, '/v3/workbench');
  });

  testWidgets('V3 chat creates a content-line context thread on first send', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage(contentLineId: 'line-1')),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('已带入本次转写上下文，首条消息会创建关联会话。'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '请基于这段转写继续追问');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.createdContentLineIds, <String?>['line-1']);
    expect(api.sentContentLineIds, <String?>['line-1']);
    expect(api.sentThreadIds, <String>['context-thread-1']);
  });

  testWidgets('V3 chat renames a thread through canonical history actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(
            _WidgetChatApi(
              secondThreadAgentProfileId: standardCreationChatAgentProfileId,
            ),
          ),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-history-more-feed-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名对话'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chat-thread-name-input')),
      '项目复盘',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('项目复盘'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-history-more-feed-2')));
    await tester.pumpAndSettle();
    expect(find.text('删除对话'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('项目复盘'), findsOneWidget);
  });

  testWidgets(
    'V3 new chat replaces the active conversation and returns to its parent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pendingMutation = Completer<ApiResult<ChatTextMutation>>();
      final api = _WidgetChatApi(textMutationCompleter: pendingMutation);
      final secondWindowApi = _WidgetChatApi();
      final firstController = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        initialAgentProfileId: 'self_media_creation',
      );
      final router = GoRouter(
        initialLocation: '/home',
        routes: <RouteBase>[
          GoRoute(
            path: '/home',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('聊一聊上一级'))),
          ),
          GoRoute(
            path: '/chat',
            builder: (context, state) => ProviderScope(
              key: const ValueKey<String>('first-chat-scope'),
              overrides: [
                chatRepositoryProvider.overrideWithValue(api),
                feedAiChatControllerProvider.overrideWith(
                  (ref) => firstController,
                ),
                feedAiVoiceMessageControllerProvider.overrideWith(
                  createFeedAiVoiceMessageController,
                ),
              ],
              child: const V3ChatPage(key: ValueKey<String>('first-chat')),
            ),
          ),
          GoRoute(
            path: '/v3/feed/chat',
            builder: (context, state) => ProviderScope(
              key: ValueKey<String>(
                'new-chat-scope-${state.uri.queryParameters['window']}',
              ),
              overrides: [
                chatRepositoryProvider.overrideWithValue(secondWindowApi),
                feedAiChatControllerProvider.overrideWith(
                  (ref) => createFeedAiChatController(
                    ref,
                    initialAgentProfileId: knownPublicChatAgentProfileId(
                      state.uri.queryParameters['agentProfileId'],
                    ),
                  ),
                ),
                feedAiVoiceMessageControllerProvider.overrideWith(
                  createFeedAiVoiceMessageController,
                ),
              ],
              child: V3ChatPage(
                key: ValueKey<String>(
                  'new-chat-${state.uri.queryParameters['window']}',
                ),
                windowId: state.uri.queryParameters['window'],
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump();
      router.push('/chat');
      await tester.pump();
      await tester.pump();

      final firstSubmission = firstController.sendText(
        '请在回复时打开新会话',
        context: ChatContextEnvelope.create(
          purpose: ChatContextPurpose.general,
          entryPoint: const ChatContextEntryPoint(surface: 'feed_chat'),
        ),
      );
      await tester.pump();

      expect(firstController.state.isSending, isTrue);
      final newChatButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '新建会话',
        ),
      );
      newChatButton.onPressed!.call();
      await tester.pump();
      await tester.pump();

      final activeContainer = ProviderScope.containerOf(
        tester.element(find.byType(V3ChatPage).last),
      );
      final activeController = activeContainer.read(
        feedAiChatControllerProvider,
      );
      expect(identical(activeController, firstController), isFalse);
      expect(activeController.state.messages, isEmpty);
      expect(activeController.activeAgentProfileId, 'self_media_creation');
      expect(firstController.state.isSending, isTrue);

      final sent = await activeController.sendText(
        '第二个窗口继续使用原来的 Agent',
        context: ChatContextEnvelope.create(
          purpose: ChatContextPurpose.general,
          entryPoint: const ChatContextEntryPoint(surface: 'feed_chat'),
        ),
      );
      expect(sent, isTrue);
      expect(secondWindowApi.sentAgentProfileIds, <String?>[
        'self_media_creation',
      ]);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('聊一聊上一级'), findsOneWidget);
      expect(find.byType(V3ChatPage), findsNothing);

      pendingMutation.complete(
        _success(
          const ChatTextMutation(
            message: ChatMessage(
              messageId: 'first-window-message',
              threadId: 'feed-1',
              scene: ChatScene.feedAi,
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.text,
              status: 'sent',
            ),
          ),
          SubmissionKeyStore.empty,
        ),
      );
      await tester.pump();
      await firstSubmission;
    },
  );

  testWidgets('V3 chat opens a cached new window after the first frame', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase();
    final repository =
        ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'widget-cache-window-user',
        )..saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: const <ChatThread>[
            ChatThread(
              threadId: 'cached-window-thread',
              scene: ChatScene.feedAi,
              title: '缓存会话',
            ),
          ],
          messagesByThread: const <String, List<ChatMessage>>{},
        );
    final sourceApi = _WidgetChatApi();
    final destinationApi = _WidgetChatApi();
    final destinationController = ChatController(
      api: destinationApi,
      scene: ChatScene.feedAi,
      aliasRepository: repository,
    );
    final router = GoRouter(
      initialLocation: '/chat',
      routes: <RouteBase>[
        GoRoute(
          path: '/chat',
          builder: (context, state) => ProviderScope(
            overrides: <Override>[
              chatRepositoryProvider.overrideWithValue(sourceApi),
              feedAiChatControllerProvider.overrideWith(
                (ref) =>
                    ChatController(api: sourceApi, scene: ChatScene.feedAi),
              ),
              feedAiVoiceMessageControllerProvider.overrideWith(
                createFeedAiVoiceMessageController,
              ),
            ],
            child: const V3ChatPage(),
          ),
        ),
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) => ProviderScope(
            overrides: <Override>[
              chatRepositoryProvider.overrideWithValue(destinationApi),
              feedAiChatControllerProvider.overrideWith(
                (ref) => destinationController,
              ),
              feedAiVoiceMessageControllerProvider.overrideWith(
                createFeedAiVoiceMessageController,
              ),
            ],
            child: V3ChatPage(windowId: state.uri.queryParameters['window']),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(sourceApi),
          chatThreadAliasRepositoryProvider.overrideWithValue(repository),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('新建会话'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);

    expect(destinationController.state.threads, hasLength(1));
    expect(destinationController.state.activeThreadId, isNull);
    expect(destinationController.state.messages, isEmpty);
  });

  testWidgets(
    'V3 exact specialist thread keeps its verified profile for a new window',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi(secondThreadAgentProfileId: 'renshe_content');
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        agentScope: const ChatAgentScope.threadBound(),
      );
      String? receivedAgentProfileId;
      final router = GoRouter(
        initialLocation: '/chat',
        routes: <RouteBase>[
          GoRoute(
            path: '/chat',
            builder: (context, state) => ProviderScope(
              overrides: <Override>[
                feedAiChatControllerProvider.overrideWith((ref) => controller),
                feedAiVoiceMessageControllerProvider.overrideWith(
                  createFeedAiVoiceMessageController,
                ),
              ],
              child: const V3ChatPage(threadId: 'feed-2'),
            ),
          ),
          GoRoute(
            path: '/v3/feed/chat',
            builder: (context, state) {
              receivedAgentProfileId =
                  state.uri.queryParameters['agentProfileId'];
              return const SizedBox.shrink();
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.state.activeThreadId, 'feed-2');
      expect(controller.activeAgentProfileId, 'renshe_content');
      final newConversationButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '新建会话',
        ),
      );
      newConversationButton.onPressed!();
      await tester.pump();
      await tester.pump();

      expect(receivedAgentProfileId, 'renshe_content');
    },
  );

  testWidgets(
    'V3 masterpiece new conversation preserves the book writing profile',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi();
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        initialAgentProfileId: 'book_writing',
      );
      String? receivedWindowId;
      String? receivedAgentProfileId;
      final router = GoRouter(
        initialLocation: '/chat',
        routes: <RouteBase>[
          GoRoute(
            path: '/chat',
            builder: (context, state) => ProviderScope(
              overrides: <Override>[
                feedAiChatControllerProvider.overrideWith((ref) => controller),
                feedAiVoiceMessageControllerProvider.overrideWith(
                  createFeedAiVoiceMessageController,
                ),
              ],
              child: V3ChatPage(
                workbenchContext: WorkbenchChatContext(
                  skill: WorkbenchChatSkill.masterpiece,
                  materialIds: const <String>[],
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/v3/feed/chat',
            builder: (context, state) {
              receivedWindowId = state.uri.queryParameters['window'];
              receivedAgentProfileId =
                  state.uri.queryParameters['agentProfileId'];
              return const SizedBox.shrink();
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump();

      final newConversationButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '新建会话',
        ),
      );
      newConversationButton.onPressed!();
      await tester.pump();
      await tester.pump();

      expect(receivedWindowId, isNotEmpty);
      expect(receivedAgentProfileId, 'book_writing');
    },
  );

  testWidgets(
    'Note-sheet Chat only auto-references its source for a fresh conversation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const threadId = 'note-sheet-bound-thread';
      const sourceId = 'note-sheet-bound-source';
      final entryPoint = OrdinaryChatEntryPoint.asset(sourceId);
      const restoredThread = ChatThread(
        threadId: threadId,
        scene: ChatScene.feedAi,
        workspaceId: 'test-workspace',
        agentProfileId: standardCreationChatAgentProfileId,
      );
      final detailCompleter = Completer<ApiResult<ChatThreadDetail>>();
      final api = _WidgetChatApi(
        detailCompleters: <String, Completer<ApiResult<ChatThreadDetail>>>{
          threadId: detailCompleter,
        },
      );
      final database = AppDatabase();
      final repository =
          ChatThreadAliasRepository(
            dao: UserMetadataDao(database),
            preferencesDao: AppPreferencesDao(database),
            userScope: 'test-user',
            workspaceScope: 'test-workspace',
          )..markOrdinaryThreadOpened(
            scene: ChatScene.feedAi,
            entryPoint: entryPoint,
            threadId: threadId,
            agentProfileId: standardCreationChatAgentProfileId,
          );
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        aliasRepository: repository,
        initialAgentProfileId: standardCreationChatAgentProfileId,
      );
      addTearDown(controller.dispose);
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[
          V3FeedItem(
            id: sourceId,
            title: '已绑定入口资料',
            source: V3MaterialSource.note,
            ownership: V3NoteOwnership.mine,
            createdAt: DateTime.utc(2026, 9, 10),
            rawBody: '只应在新会话首条消息自动引用。',
            syncState: NoteSyncState.synced,
            remoteNoteId: 'remote-note-sheet-bound-source',
            rawPartRevisionId: 'raw-note-sheet-bound-source-1',
          ),
        ],
        includeDemoFixtures: false,
      );
      final sourceReference = find.byKey(
        const ValueKey<String>('chat-memory-note-context-$sourceId'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            appDatabaseProvider.overrideWithValue(database),
            chatRepositoryProvider.overrideWithValue(api),
            chatThreadAliasRepositoryProvider.overrideWithValue(repository),
            feedAiChatControllerProvider.overrideWith((ref) => controller),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: MaterialApp(
            home: V3ChatPage(
              feedItemId: sourceId,
              ordinaryEntryPoint: entryPoint,
              launchMode: ChatLaunchMode.fresh,
              presentation: V3ChatPresentation.noteSheet,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(api.detailThreadIds, <String>[threadId]);
      expect(sourceReference, findsNothing);

      detailCompleter.complete(
        _success(
          const ChatThreadDetail(
            thread: restoredThread,
            messages: <ChatMessage>[
              ChatMessage(
                messageId: 'note-sheet-bound-user',
                threadId: threadId,
                scene: ChatScene.feedAi,
                role: ChatMessageRole.user,
                contentType: ChatMessageContentType.text,
                status: 'sent',
                textPreview: '上一次已经讨论过这份资料。',
              ),
            ],
          ),
          SubmissionKeyStore.empty,
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.state.activeThreadId, threadId);
      expect(find.text('上一次已经讨论过这份资料。'), findsOneWidget);
      expect(sourceReference, findsNothing);

      await tester.enterText(find.byType(TextField), '继续上一次的话题');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(api.sentContexts, hasLength(1));
      expect(api.sentContexts.single?.references, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey<String>('note-chat-new-conversation')),
      );
      await tester.pump();

      expect(controller.state.activeThreadId, isNull);
      expect(sourceReference, findsOneWidget);

      api.sendFailureCode = 'SERVICE_BUSY';
      await tester.enterText(find.byType(TextField), '开始一段新话题');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(api.sentContexts, hasLength(2));
      final failedFreshReference = api.sentContexts.last?.references.single;
      expect(failedFreshReference?.type, ChatContextReferenceType.material);
      expect(failedFreshReference?.id, 'remote-note-sheet-bound-source');
      expect(failedFreshReference?.revision, 'raw-note-sheet-bound-source-1');
      expect(controller.state.activeThreadId, 'feed-1');
      expect(sourceReference, findsOneWidget);

      api.sendFailureCode = null;
      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await tester.pumpAndSettle();

      expect(api.sentContexts, hasLength(3));
      final retriedFreshReference = api.sentContexts.last?.references.single;
      expect(retriedFreshReference?.type, ChatContextReferenceType.material);
      expect(retriedFreshReference?.id, 'remote-note-sheet-bound-source');
      expect(retriedFreshReference?.revision, 'raw-note-sheet-bound-source-1');
      expect(sourceReference, findsNothing);
    },
  );

  testWidgets(
    'Note-sheet Chat shares the page surface and restores its source on New',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi();
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[
          V3FeedItem(
            id: 'note-sheet-source',
            title: '弹窗自动引用资料',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 9, 3),
            rawBody: '弹窗与全屏聊天共用的正式引用。',
            remoteNoteId: 'remote-note-sheet-source',
            rawPartRevisionId: 'raw-note-sheet-source-1',
          ),
        ],
      );
      V3ChatSheetExpansion? expansion;
      var closeCount = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: MaterialApp(
            home: V3ChatPage(
              feedItemId: 'note-sheet-source',
              presentation: V3ChatPresentation.noteSheet,
              onSheetClose: () => closeCount += 1,
              onSheetExpand: (value) => expansion = value,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('note-chat-close')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('note-chat-expand')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('note-chat-new-conversation')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('note-chat-history')),
        findsOneWidget,
      );
      final sourceReference = find.byKey(
        const ValueKey<String>('chat-memory-note-context-note-sheet-source'),
      );
      expect(sourceReference, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
        findsNothing,
      );
      expect(find.text('这条笔记的核心判断是什么？'), findsOneWidget);
      expect(find.text('怎样把信息整理成可调用的知识？'), findsOneWidget);
      expect(find.text('如何让这条笔记进入下一步行动？'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('chat-entry-refresh-suggestions')),
      );
      await tester.pump();
      expect(find.text('这条笔记的核心判断是什么？'), findsNothing);
      expect(find.text('这条笔记里最值得继续追问的是什么？'), findsOneWidget);
      await tester.tap(find.text('这条笔记里最值得继续追问的是什么？'));
      await tester.pumpAndSettle();
      expect(api.sentContents, <String>['这条笔记里最值得继续追问的是什么？']);
      expect(
        api.sentContexts.single?.references.single.id,
        'remote-note-sheet-source',
      );
      expect(sourceReference, findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('note-chat-new-conversation')),
      );
      await tester.pump();
      expect(sourceReference, findsOneWidget);

      await tester.tap(find.byTooltip('移除引用资产'));
      await tester.pump();
      expect(sourceReference, findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('note-chat-expand')));
      expect(expansion?.includesSourceReference, isFalse);

      await tester.tap(
        find.byKey(const ValueKey<String>('note-chat-new-conversation')),
      );
      await tester.pump();
      expect(sourceReference, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('note-chat-expand')));
      expect(expansion?.includesSourceReference, isTrue);

      await tester.tap(find.byKey(const ValueKey<String>('note-chat-close')));
      expect(closeCount, 1);
    },
  );

  testWidgets('Note Chat launcher keeps the established bottom-sheet height', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view
      ..padding = const FakeViewPadding(bottom: 34)
      ..viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final api = _WidgetChatApi();
    final note = V3FeedItem(
      id: 'note-sheet-launcher-source',
      title: '弹窗入口引用资料',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 3),
      rawBody: '验证实际底部弹窗宿主。',
      remoteNoteId: 'remote-note-sheet-launcher-source',
      rawPartRevisionId: 'raw-note-sheet-launcher-source-1',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
    );
    late double launcherViewportHeight;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                launcherViewportHeight = MediaQuery.sizeOf(context).height;
                return FilledButton(
                  onPressed: () =>
                      showV3NoteChatSheet(context: context, item: note),
                  child: const Text('打开聊一聊'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开聊一聊'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    final sheetSurface = find.byKey(
      const ValueKey<String>('note-chat-sheet-surface'),
    );
    expect(sheetSurface, findsOneWidget);
    expect(
      tester.getSize(sheetSurface).height,
      closeTo(launcherViewportHeight * .87, .1),
    );
    expect(
      tester
          .widget<V3PageScaffold>(find.byType(V3PageScaffold))
          .bottomBarUsesSafeArea,
      isFalse,
    );
    expect(
      tester.getRect(sheetSurface).bottom -
          tester
              .getRect(
                find.byKey(const ValueKey<String>('chat-entry-disclaimer')),
              )
              .bottom,
      closeTo(8, .1),
    );
    expect(
      find.byKey(const ValueKey<String>('note-chat-close')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>(
          'chat-memory-note-context-note-sheet-launcher-source',
        ),
      ),
      findsOneWidget,
    );

    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pumpAndSettle();
    final resizedViewportHeight = MediaQuery.sizeOf(
      tester.element(sheetSurface),
    ).height;
    expect(
      tester.getSize(sheetSurface).height,
      closeTo(resizedViewportHeight * .87, .1),
    );
    expect(
      tester.getRect(sheetSurface).bottom,
      closeTo(tester.getRect(find.byType(BottomSheet)).bottom, .1),
    );

    await tester.tap(find.byKey(const ValueKey<String>('note-chat-close')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
    'V3 chat sends multiple selected memory notes from one scrollable strip',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi();
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[
          V3FeedItem(
            id: 'demo-laozhou-021',
            title: '重大决定的四栏分析法',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 7, 29),
            rawBody: '仅保留在本地的笔记正文。',
            remoteNoteId: 'remote-note-laozhou-021',
            rawPartRevisionId: 'remote-note-laozhou-021-raw-3',
          ),
          V3FeedItem(
            id: 'demo-laozhou-022',
            title: '访谈素材的三层提炼法',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 7, 30),
            rawBody: '第二篇已同步的笔记正文。',
            remoteNoteId: 'remote-note-laozhou-022',
            rawPartRevisionId: 'remote-note-laozhou-022-raw-1',
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: const MaterialApp(
            home: V3ChatPage(windowId: 'referenced-note-guided-entry'),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('引用笔记'), findsOneWidget);
      expect(find.text('本地文件'), findsNothing);
      expect(find.text('引用观点'), findsNothing);
      expect(find.text('引用录音'), findsNothing);
      await tester.tap(find.text('引用笔记'));
      await tester.pumpAndSettle();
      final searchField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '搜索标题、正文或来源',
      );
      await tester.enterText(searchField, '重大决定');
      await tester.pumpAndSettle();
      await tester.tap(find.text('重大决定的四栏分析法'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用这篇笔记'));
      await tester.pumpAndSettle();

      expect(find.text('已引用资产「重大决定的四栏分析法」'), findsOneWidget);
      expect(find.text('已引用资产「重大决定的四栏分析法」，将随本条消息发送。'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-entry-send')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-entry-voice')),
        findsOneWidget,
      );
      final contextPanel = find.byKey(
        const ValueKey('chat-composer-context-panel'),
      );
      final noteContext = find.byKey(
        const ValueKey<String>('chat-memory-note-context-demo-laozhou-021'),
      );
      final composer = find.byKey(
        const ValueKey<String>('chat-entry-composer'),
      );
      expect(contextPanel, findsOneWidget);
      expect(
        find.descendant(of: contextPanel, matching: noteContext),
        findsOneWidget,
      );
      expect(
        find.descendant(of: contextPanel, matching: composer),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(noteContext).dy,
        lessThan(tester.getTopLeft(composer).dy),
      );
      expect(
        find.byKey(const ValueKey('chat-memory-note-continue-adding')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('chat-memory-note-continue-adding')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用笔记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('访谈素材的三层提炼法'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用这篇笔记'));
      await tester.pumpAndSettle();

      final secondNoteContext = find.byKey(
        const ValueKey<String>('chat-memory-note-context-demo-laozhou-022'),
      );
      expect(noteContext, findsOneWidget);
      expect(secondNoteContext, findsOneWidget);
      final strip = tester.widget<ListView>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-memory-note-context-strip')),
          matching: find.byType(ListView),
        ),
      );
      expect(strip.scrollDirection, Axis.horizontal);

      await tester.enterText(find.byType(TextField), '请给我下一步');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.pump();

      expect(api.sentContents.single, '请给我下一步');
      expect(api.sentContexts.single?.purpose, ChatContextPurpose.general);
      expect(
        api.sentContexts.single?.references.map((reference) => reference.id),
        <String>['remote-note-laozhou-021', 'remote-note-laozhou-022'],
      );
      expect(
        api.sentContexts.single?.references.map(
          (reference) => reference.revision,
        ),
        <String>[
          'remote-note-laozhou-021-raw-3',
          'remote-note-laozhou-022-raw-1',
        ],
      );
      expect(find.text('请给我下一步'), findsOneWidget);
      expect(find.textContaining('事实、自己的感受和解释'), findsNothing);

      expect(
        find.byKey(
          const ValueKey<String>('chat-message-asset-demo-laozhou-021'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('chat-message-asset-demo-laozhou-022'),
        ),
        findsOneWidget,
      );
      expect(noteContext, findsNothing);
      expect(secondNoteContext, findsNothing);
      await tester.enterText(find.byType(TextField), '继续基于这份资产给建议');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.pump();

      expect(api.sentContents, <String>['请给我下一步', '继续基于这份资产给建议']);
      expect(api.sentContexts[1]?.references, isEmpty);
    },
  );

  testWidgets(
    'V3 chat resolves a deposited knowledge-square article to its owned HNote',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _WidgetChatApi();
      final database = AppDatabase();
      final aliases = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'deposited-route-asset-user',
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[
          V3FeedItem(
            id: 'square-article-01',
            title: '训练大模型的账，不能只算最后一次训练',
            source: V3MaterialSource.knowledgeSquare,
            ownership: V3NoteOwnership.knowledgeSquare,
            createdAt: DateTime.utc(2026, 8, 8),
            rawBody: '知识世界公开文章正文。',
          ),
          V3FeedItem(
            id: 'owned-hnote-01',
            title: '训练大模型的账，不能只算最后一次训练',
            source: V3MaterialSource.subscription,
            ownership: V3NoteOwnership.mine,
            copiedFromContentId: 'square-article-01',
            createdAt: DateTime.utc(2026, 8, 8),
            rawBody: '已沉淀到我的资产的正文。',
            remoteNoteId: 'workspace-hnote-01',
            rawPartRevisionId: 'workspace-hnote-01-raw-2',
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            chatThreadAliasRepositoryProvider.overrideWithValue(aliases),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: const MaterialApp(
            home: V3ChatPage(
              feedItemId: 'square-article-01',
              dailyTopicTitle: '训练大模型的账，不能只算最后一次训练',
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey<String>('chat-memory-note-context-owned-hnote-01'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('chat-message-asset-owned-hnote-01')),
        findsNothing,
      );
      expect(find.text('本会话已使用今日选题「训练大模型的账，不能只算最后一次训练」。'), findsNothing);
      expect(find.text('已引用资产「训练大模型的账，不能只算最后一次训练」，将随本条消息发送。'), findsNothing);

      await tester.enterText(find.byType(TextField), '基于这篇文章帮我总结');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.pump();

      expect(api.sentContents, <String>['基于这篇文章帮我总结']);
      expect(
        api.sentContexts.single?.references.single,
        isA<ChatContextReference>()
            .having((reference) => reference.id, 'id', 'workspace-hnote-01')
            .having(
              (reference) => reference.revision,
              'revision',
              'workspace-hnote-01-raw-2',
            ),
      );
      expect(
        aliases.threadAssetReferenceFor(
          scene: ChatScene.feedAi,
          threadId: 'feed-1',
        ),
        'owned-hnote-01',
      );
      expect(
        find.byKey(const ValueKey<String>('chat-message-asset-owned-hnote-01')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('chat-memory-note-context-owned-hnote-01'),
        ),
        findsNothing,
      );
      await tester.enterText(find.byType(TextField), '继续说明重点');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.pump();

      expect(api.sentContexts[1]?.references, isEmpty);
      expect(find.text('请先沉淀到我的资产，再在聊一聊中引用'), findsNothing);
    },
  );

  testWidgets('V3 chat sends typed workbench skill and material context', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi();
    final database = AppDatabase();
    final repository = ChatThreadAliasRepository(
      dao: UserMetadataDao(database),
      preferencesDao: AppPreferencesDao(database),
      userScope: 'persona-retained-asset-user',
    );
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      aliasRepository: repository,
      initialAgentProfileId: 'renshe_content',
    );
    final library = KnowledgeLibraryController(
      initialNotes: [
        V3FeedItem(
          id: 'persona-material',
          title: '客户访谈证据',
          source: V3MaterialSource.meeting,
          createdAt: DateTime.utc(2026, 7, 24),
          rawBody: '客户最关注真实经历和具体结果。',
          summaryBody: '用可验证经历建立人设。',
          remoteNoteId: 'remote-persona-material',
          rawPartRevisionId: 'remote-persona-material-raw-2',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          chatThreadAliasRepositoryProvider.overrideWithValue(repository),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            windowId: 'typed-persona-material-context',
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.persona,
              materialIds: <String>['persona-material'],
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(find.text('个人IP创作 · 已带入 1 份资产'), findsNothing);

    await tester.enterText(find.byType(TextField), '帮我提炼一个可信人设');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump();

    expect(api.sentContents.single, '帮我提炼一个可信人设');
    expect(api.sentContexts.single?.purpose, ChatContextPurpose.persona);
    expect(
      api.sentContexts.single?.references.single.id,
      'remote-persona-material',
    );
    expect(
      api.sentContexts.single?.references.single.revision,
      'remote-persona-material-raw-2',
    );
    expect(
      find.byKey(const ValueKey<String>('chat-message-asset-persona-material')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('chat-memory-note-context-persona-material'),
      ),
      findsNothing,
    );
    expect(find.text('帮我提炼一个可信人设'), findsOneWidget);
    expect(find.textContaining('客户最关注真实经历'), findsNothing);
  });

  testWidgets('persona guide exposes its V5 questions before a turn', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      initialAgentProfileId: 'renshe_content',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            windowId: 'persona-upload-guide',
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.persona,
              materialIds: const <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('chat-entry-surface')),
      findsOneWidget,
    );
    expect(find.text('Hello，我是个人 IP Agent'), findsOneWidget);
    expect(find.text('引用一份资产，提炼能支撑个人 IP 的经历'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-upload-assets-persona')),
      findsNothing,
    );
    expect(api.sentContents, isEmpty);
  });

  testWidgets('lead guide exposes its V5 questions before a turn', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      initialAgentProfileId: 'huoke_content',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            windowId: 'lead-upload-guide',
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.lead,
              materialIds: const <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('chat-entry-surface')),
      findsOneWidget,
    );
    expect(find.text('Hello，我是获客营销 Agent'), findsOneWidget);
    expect(find.text('引用一份资产，提炼客户最在意的问题'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-upload-assets-lead')), findsNothing);
    expect(api.sentContents, isEmpty);
  });

  testWidgets('V5 guide suggestions stay within a narrow chat viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi();
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      initialAgentProfileId: 'renshe_content',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            windowId: 'narrow-persona-upload-guide',
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.persona,
              materialIds: const <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(
      const ValueKey<String>('chat-entry-suggestion-notePicker'),
    );
    await tester.scrollUntilVisible(
      action,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(action, findsOneWidget);
    expect(tester.getRect(action).right, lessThanOrEqualTo(280));
    expect(tester.takeException(), isNull);
  });

  testWidgets('guided Note suggestion confirms and auto-sends its prompt', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi();
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'guided-note-sync-failure',
          title: '待同步失败资产',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 27),
          rawBody: '这条本地资产没有可用的同步端口。',
          syncState: NoteSyncState.localOnly,
        ),
        V3FeedItem(
          id: 'guided-note',
          title: '获客复盘',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 28),
          rawBody: '本周从三个渠道获得了有效咨询。',
          remoteNoteId: 'remote-guided-note',
          rawPartRevisionId: 'remote-guided-note-raw-1',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            windowId: 'guided-note-auto-send',
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.lead,
              materialIds: const <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('chat-note-picker-close')),
    );
    await tester.pumpAndSettle();
    expect(api.sentContents, isEmpty);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('chat-composer')),
          )
          .controller
          ?.text,
      isEmpty,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('待同步失败资产'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用这篇笔记'));
    await tester.pumpAndSettle();
    expect(find.text('所选笔记未能同步到云端，暂时无法引用'), findsOneWidget);
    expect(api.sentContents, isEmpty);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('chat-composer')),
          )
          .controller
          ?.text,
      isEmpty,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('获客复盘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用这篇笔记'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.sentContents, <String>['引用一份资产，提炼客户最在意的问题']);
    expect(api.sentContexts.single?.references.single.id, 'remote-guided-note');
    expect(
      find.byKey(const ValueKey<String>('chat-message-asset-guided-note')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('chat-memory-note-context-guided-note'),
      ),
      findsNothing,
    );
  });

  testWidgets('asset analysis sends one configured prompt with exact context', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final library = KnowledgeLibraryController(
      initialNotes: [
        V3FeedItem(
          id: 'analysis-material',
          title: '分析资产',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 19),
          rawBody: '来自真实客户的结果复盘。',
          remoteNoteId: 'remote-analysis-material',
          rawPartRevisionId: 'raw-analysis-material-3',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.persona,
              materialIds: const <String>['analysis-material'],
            ),
            autoAnalyzeMaterials: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    expect(api.sentContents, <String>[
      WorkbenchPurpose.persona.assetAnalysisPrompt,
    ]);
    expect(api.sentContexts.single?.purpose, ChatContextPurpose.persona);
    expect(
      api.sentContexts.single?.references.single.id,
      'remote-analysis-material',
    );
    expect(
      api.sentContexts.single?.references.single.revision,
      'raw-analysis-material-3',
    );
    expect(api.createdContentLineIds, <String?>[null]);
    expect(
      find.byKey(const ValueKey<String>('chat-workbench-context-persona')),
      findsNothing,
    );

    await tester.enterText(find.byType(TextField), '请继续给出一个具体选题');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.sentContexts, hasLength(2));
    expect(api.sentContexts.last?.references, isEmpty);
    expect(
      find.byKey(
        const ValueKey<String>('chat-memory-note-context-analysis-material'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey<String>('chat-message-asset-analysis-material'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('note prompt auto-submits once with the exact note context', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final database = AppDatabase();
    final aliases = ChatThreadAliasRepository(
      dao: UserMetadataDao(database),
      preferencesDao: AppPreferencesDao(database),
      userScope: 'expanded-note-first-send-user',
    );
    final library = KnowledgeLibraryController(
      initialNotes: [
        V3FeedItem(
          id: 'prompt-note',
          title: '判断方法',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 23),
          rawBody: '保留原始上下文，再比较相近观点。',
          remoteNoteId: 'remote-prompt-note',
          rawPartRevisionId: 'raw-prompt-note-2',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          chatThreadAliasRepositoryProvider.overrideWithValue(aliases),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: const MaterialApp(
          home: V3ChatPage(
            windowId: 'note-prompt-window',
            feedItemId: 'prompt-note',
            initialPrompt: '这条笔记的核心判断是什么？',
            autoSubmitInitialPrompt: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    expect(api.sentContents, <String>['这条笔记的核心判断是什么？']);
    expect(api.sentContexts, hasLength(1));
    expect(api.sentContexts.single?.references.single.id, 'remote-prompt-note');
    expect(
      api.sentContexts.single?.references.single.revision,
      'raw-prompt-note-2',
    );
    expect(
      aliases.threadAssetReferenceFor(
        scene: ChatScene.feedAi,
        threadId: 'feed-1',
      ),
      'prompt-note',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(api.sentContents, hasLength(1));
  });

  testWidgets('explicit Agent-assisted entry skips every opening guide', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'explicit-goal-material',
          title: '明确目标资料',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 9, 3),
          rawBody: '已有明确目标的辅助创作资料。',
          remoteNoteId: 'remote-explicit-goal-material',
          rawPartRevisionId: 'raw-explicit-goal-material-1',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.persona,
              materialIds: const <String>['explicit-goal-material'],
            ),
            initialPrompt: '使用 Huahuo AI 分析框架，帮我一次性分析完毕。',
            autoSubmitInitialPrompt: true,
            isAgentAssistedCreationEntry: true,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('chat-entry-surface')),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey<String>('chat-local-agent-opening-renshe_content'),
      ),
      findsNothing,
    );
    expect(find.textContaining('欢迎来到花火 AI'), findsNothing);
    expect(find.text('输入一个问题，开始一段新的对话。'), findsNothing);

    await tester.pumpAndSettle();
    expect(api.sentContents, <String>['使用 Huahuo AI 分析框架，帮我一次性分析完毕。']);
  });

  testWidgets('asset analysis synchronizes a local asset before submission', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final notePort = _SynchronizingNotePort();
    final library = KnowledgeLibraryController(
      notePort: notePort,
      initialNotes: [
        V3FeedItem(
          id: 'local-analysis-material',
          title: '待同步资产',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 19),
          rawBody: '尚未上传的客户结果复盘。',
          syncState: NoteSyncState.localOnly,
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.lead,
              materialIds: const <String>['local-analysis-material'],
            ),
            autoAnalyzeMaterials: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    expect(notePort.requestedNoteIds, <String>['local-analysis-material']);
    expect(api.sentContents, <String>[
      WorkbenchPurpose.lead.assetAnalysisPrompt,
    ]);
    expect(
      api.sentContexts.single?.references.single.id,
      'remote-local-analysis-material',
    );
    expect(
      api.sentContexts.single?.references.single.revision,
      'raw-local-analysis-material-1',
    );
  });

  testWidgets('asset analysis consumes materials after a transport failure', (
    tester,
  ) async {
    final api = _WidgetChatApi(sendFailureCode: 'SERVICE_BUSY');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'failed-analysis-material',
          title: '失败后应解除的资产',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 19),
          rawBody: '这次提交会被服务端拒绝。',
          remoteNoteId: 'remote-failed-analysis-material',
          rawPartRevisionId: 'raw-failed-analysis-material-1',
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.persona,
              materialIds: const <String>['failed-analysis-material'],
            ),
            autoAnalyzeMaterials: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    expect(api.sentContexts, hasLength(1));
    expect(
      find.byKey(const ValueKey<String>('chat-workbench-context-persona')),
      findsNothing,
    );
  });

  testWidgets('V3 chat synchronizes selected lead material before sending', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final notePort = _SynchronizingNotePort();
    final library = KnowledgeLibraryController(
      notePort: notePort,
      initialNotes: const <V3FeedItem>[],
    );
    final localNote = library.createManualNote(
      title: '本地客户复盘',
      rawBody: '客户转化发生在明确问题被记录以后。',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.lead,
              materialIds: <String>[localNote.id],
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '请帮我整理获客方案');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(notePort.requestedNoteIds, <String>[localNote.id]);
    expect(
      api.sentContexts.single?.references.single.id,
      'remote-${localNote.id}',
    );
    expect(
      api.sentContexts.single?.references.single.revision,
      'raw-${localNote.id}-1',
    );
  });

  testWidgets(
    'V3 chat freezes a selected asset note before adding it to send context',
    (tester) async {
      final api = _WidgetChatApi();
      final notePort = _SynchronizingNotePort();
      final library = KnowledgeLibraryController(
        notePort: notePort,
        initialNotes: const <V3FeedItem>[],
      );
      final localNote = library.createManualNote(
        title: '待同步的访谈转写',
        rawBody: '客户确认了下周的产品演示。',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: const MaterialApp(home: V3ChatPage()),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用笔记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(localNote.title).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用这篇笔记'));
      await tester.pumpAndSettle();

      expect(notePort.requestedNoteIds, <String>[localNote.id]);
      expect(find.textContaining('已引用资产'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '请总结这段访谈');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      final firstReference = api.sentContexts.single?.references.single;
      expect(firstReference?.type, ChatContextReferenceType.material);
      expect(firstReference?.id, 'remote-${localNote.id}');
      expect(firstReference?.revision, 'raw-${localNote.id}-1');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey<String>('chat-memory-note-context-${localNote.id}'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey<String>('chat-message-asset-${localNote.id}')),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField).first, '继续提炼三个重点');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(api.sentContexts, hasLength(2));
      expect(api.sentContexts.last?.references, isEmpty);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey<String>('chat-memory-note-context-${localNote.id}'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('V3 chat does not inject a legacy thread asset into a new turn', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final database = AppDatabase();
    final repository = ChatThreadAliasRepository(
      dao: UserMetadataDao(database),
      preferencesDao: AppPreferencesDao(database),
      userScope: 'restored-thread-asset-user',
    );
    repository.saveThreadAssetReference(
      scene: ChatScene.feedAi,
      threadId: 'feed-1',
      assetId: 'restored-local-note',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'restored-local-note',
          title: '已保存的会话资产',
          source: V3MaterialSource.note,
          ownership: V3NoteOwnership.mine,
          createdAt: DateTime.utc(2026, 8, 20),
          rawBody: '这份内容应在重新进入会话后继续提供给 AI。',
          syncState: NoteSyncState.synced,
          remoteNoteId: 'restored-remote-note',
          rawPartRevisionId: 'restored-raw-revision-2',
        ),
      ],
      includeDemoFixtures: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          chatThreadAliasRepositoryProvider.overrideWithValue(repository),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: const MaterialApp(home: V3ChatPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey<String>('chat-memory-note-context-restored-local-note'),
      ),
      findsNothing,
    );
    await tester.enterText(find.byType(TextField).first, '继续分析这份资产');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.sentContexts.single?.references, isEmpty);
    expect(
      repository.threadAssetReferenceFor(
        scene: ChatScene.feedAi,
        threadId: 'feed-1',
      ),
      'restored-local-note',
    );
    expect(
      find.byKey(
        const ValueKey<String>('chat-memory-note-context-restored-local-note'),
      ),
      findsNothing,
    );
  });

  testWidgets('V3 chat uses the real send flow for deep positioning', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final detailMessages = <String, List<ChatMessage>>{
      'feed-1': <ChatMessage>[],
    };
    final api = _WidgetChatApi(
      detailMessages: detailMessages,
      threadPurposes: const <String, ChatConversationPurpose>{
        'feed-1': ChatConversationPurpose.deepPositioning,
      },
    );
    final positioning = DeepPositioningController(
      const DeepPositioningMockRepository(delay: Duration.zero),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          deepPositioningControllerProvider.overrideWith((ref) => positioning),
        ],
        child: const MaterialApp(
          home: V3ChatPage(
            conversationPurpose: ChatConversationPurpose.deepPositioning,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(V3ChatPage)),
    );
    final chatController = container.read(
      deepPositioningChatControllerProvider,
    );
    expect(find.text('进一步定位'), findsOneWidget);
    expect(find.textContaining('定位对话已开启'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-context-chat-mark')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-context-chat-mark')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(find.byType(V3ChatMark), findsWidgets);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNothing);

    await tester.enterText(find.byType(TextField), '我想找到长期值得分享的方向');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.sentContents, hasLength(1));
    expect(api.sentContents.single, '我想找到长期值得分享的方向');
    expect(
      api.sentContexts.single?.purpose,
      ChatContextPurpose.socialPositioning,
    );
    expect(api.sentContexts.single?.includeAccountProfile, isTrue);
    expect(find.text('我想找到长期值得分享的方向'), findsOneWidget);
    expect(find.textContaining('你是花火 AI 的定位顾问'), findsNothing);
    expect(api.listThreadCalls, 1);
    expect(positioning.result, isNull);

    detailMessages['feed-1'] = <ChatMessage>[
      ChatMessage(
        messageId: 'user-durable-1',
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        role: ChatMessageRole.user,
        contentType: ChatMessageContentType.text,
        status: 'sent',
        textPreview: '我想找到长期值得分享的方向',
        createdAt: DateTime.utc(2026, 8, 28, 9),
      ),
      ChatMessage(
        messageId: 'assistant-durable-1',
        threadId: 'feed-1',
        scene: ChatScene.feedAi,
        role: ChatMessageRole.assistant,
        contentType: ChatMessageContentType.text,
        status: 'sent',
        textPreview: '先从你反复愿意讲述的真实经历开始。',
        createdAt: DateTime.utc(2026, 8, 28, 9, 0, 2),
      ),
    ];
    await chatController.selectThread('feed-1', forceRemote: true);
    await tester.pumpAndSettle();

    expect(positioning.result, isNotNull);
    expect(positioning.result!.isDemo, isTrue);
    expect(positioning.result!.markdown, contains('我想找到长期值得分享的方向'));
    expect(positioning.result!.markdown, contains('先从你反复愿意讲述的真实经历开始'));

    expect(
      container.read(feedAiChatControllerProvider).state.messages,
      isEmpty,
    );
  });

  testWidgets('Lv1 chat does not fabricate local positioning completion', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    final positioning = DeepPositioningController(
      const DeepPositioningMockRepository(delay: Duration.zero),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          deepPositioningControllerProvider.overrideWith((ref) => positioning),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            conversationPurpose: ChatConversationPurpose.deepPositioning,
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.positioningLv1,
              materialIds: const <String>[],
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('基础定位'), findsWidgets);

    await tester.enterText(find.byType(TextField), '我想找到长期内容方向');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(
      api.sentContexts.single?.purpose,
      ChatContextPurpose.deepPositioning,
    );
    expect(positioning.result, isNull);
  });

  testWidgets('tag-only chat sends capability without invented assets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi();
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      initialAgentProfileId: 'visual_chat',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          feedAiChatControllerProvider.overrideWith((ref) => controller),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(initialNotes: const []),
          ),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            windowId: 'tag-only-new-window',
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.visualDesign,
              materialIds: const <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Hello，我是视觉参考 Agent'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '给我一个封面方向');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump();

    expect(api.sentContents.single, '给我一个封面方向');
    expect(api.sentAgentProfileIds.single, 'visual_chat');
    expect(api.sentContexts.single?.purpose, ChatContextPurpose.visualDesign);
    expect(api.sentContexts.single?.references, isEmpty);
  });

  testWidgets(
    'video analysis enables only when the current catalog installs it',
    (tester) async {
      final api = _WidgetChatApi();
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        initialAgentProfileId: 'video_analysis',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            chatRepositoryProvider.overrideWithValue(api),
            feedAiChatControllerProvider.overrideWith((ref) => controller),
            resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          ],
          child: MaterialApp(
            home: V3ChatPage(
              windowId: 'video-analysis-new-window',
              workbenchContext: WorkbenchChatContext(
                skill: WorkbenchChatSkill.videoAnalysis,
                materialIds: const <String>[],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Hello，我是视频分析 Agent'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(api.listThreadCalls, 0);
      expect(api.sentContents, isEmpty);

      await tester.enterText(find.byType(TextField), '分析这个视频的结构');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      await tester.pump();

      expect(api.sentContents, <String>['分析这个视频的结构']);
      expect(api.sentAgentProfileIds, <String?>['video_analysis']);
      expect(
        api.sentContexts.single?.purpose,
        ChatContextPurpose.videoAnalysis,
      );
    },
  );

  testWidgets('masterpiece entry keeps balanced relevant starters', (
    tester,
  ) async {
    final api = _WidgetChatApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            windowId: 'masterpiece-starter-window',
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.masterpiece,
              materialIds: const <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Hello，我是代表作 Agent'), findsOneWidget);
    expect(find.text('一部代表作的核心主线应该如何定义和检验？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
      findsNWidgets(2),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('chat-entry-refresh-suggestions')),
    );
    await tester.pump();
    expect(find.text('写作卡住时，如何判断该补材料还是改结构？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-notePicker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('chat-entry-suggestion-prompt')),
      findsNWidgets(2),
    );
    expect(api.sentContents, isEmpty);
  });

  testWidgets('masterpiece chat sends a bounded persisted document snapshot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _WidgetChatApi();
    final workspace = ProfileWorkspaceController();
    const document = '# 我的代表作\n\n第一章完整正文\n\n第二章完整正文';
    expect(
      workspace.saveMasterpieceDocument(
        markdown: document,
        includedNoteIds: const <String>['note-a'],
      ),
      isTrue,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          profileWorkspaceControllerProvider.overrideWith((ref) => workspace),
          knowledgeLibraryControllerProvider.overrideWith(
            (ref) => KnowledgeLibraryController(initialNotes: const []),
          ),
        ],
        child: MaterialApp(
          home: V3ChatPage(
            windowId: 'masterpiece-new-window',
            workbenchContext: WorkbenchChatContext(
              skill: WorkbenchChatSkill.masterpiece,
              materialIds: const <String>[],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('已带入当前代表作正文'), findsOneWidget);
    expect(find.text('Hello，我是代表作 Agent'), findsOneWidget);
    expect(find.text('Hello，我是花火 AI'), findsNothing);

    await tester.enterText(find.byType(TextField), '帮我提炼中心思想');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump();

    expect(api.sentContents.single, '帮我提炼中心思想');
    expect(api.sentContexts.single?.purpose, ChatContextPurpose.masterpiece);
    expect(
      api.sentContexts.single?.localDraftSnapshot?.kind,
      'masterpiece_markdown',
    );
    expect(api.sentContexts.single?.localDraftSnapshot?.content, document);
    expect(find.text('帮我提炼中心思想'), findsOneWidget);
    expect(find.textContaining('第二章完整正文'), findsNothing);
  });

  testWidgets('V3 deep positioning starts fresh with shared Agent header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase();
    final repository =
        ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'widget-positioning-user',
        )..markThreadPurpose(
          scene: ChatScene.feedAi,
          threadId: 'positioning-restored',
          purpose: ChatConversationPurpose.deepPositioning,
        );
    final api = _WidgetChatApi(
      detailMessages: <String, List<ChatMessage>>{
        'positioning-restored': <ChatMessage>[
          const ChatMessage(
            messageId: 'restored-user',
            threadId: 'positioning-restored',
            scene: ChatScene.feedAi,
            role: ChatMessageRole.user,
            contentType: ChatMessageContentType.text,
            status: 'sent',
            textPreview: '【深度定位对话】\n服务端保存的内部提示\n\n用户问题：我想聚焦组织管理',
          ),
          const ChatMessage(
            messageId: 'restored-assistant',
            threadId: 'positioning-restored',
            scene: ChatScene.feedAi,
            role: ChatMessageRole.assistant,
            contentType: ChatMessageContentType.text,
            status: 'sent',
            textPreview: '哪段经历最能证明这项能力？',
          ),
        ],
      },
    );
    final controller = ChatController(
      api: api,
      scene: ChatScene.feedAi,
      aliasRepository: repository,
      conversationPurpose: ChatConversationPurpose.deepPositioning,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          chatRepositoryProvider.overrideWithValue(api),
          deepPositioningChatControllerProvider.overrideWith(
            (ref) => controller,
          ),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        ],
        child: const MaterialApp(
          home: V3ChatPage(
            conversationPurpose: ChatConversationPurpose.deepPositioning,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(api.listThreadCalls, 0);
    expect(api.detailThreadIds, isNot(contains('positioning-restored')));
    expect(find.text('我想聚焦组织管理'), findsNothing);
    expect(find.text('哪段经历最能证明这项能力？'), findsNothing);
    expect(find.textContaining('服务端保存的内部提示'), findsNothing);
    expect(find.textContaining('【深度定位对话】'), findsNothing);
    expect(find.text('深度定位'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-agent-leading-positioning_lv2')),
      findsNothing,
    );
    expect(find.byTooltip('会话列表'), findsOneWidget);
    expect(find.byTooltip('新建会话'), findsOneWidget);
  });
}

Widget _sharedTimelineHarness({
  required ChatRunTracker tracker,
  required Key timelineKey,
  required String threadId,
  required List<ChatMessage> messages,
  required Map<String, String?> fallbackRunStatuses,
  required ValueListenable<Map<String, ChatAssistantAnswerDraft>> drafts,
  String? fallbackToolRunId,
  List<AgentRunToolTrace> fallbackToolTrace = const <AgentRunToolTrace>[],
  bool isSending = false,
  bool threadPending = false,
  bool reduceMotion = false,
  Widget? bottomNavigationBar,
  V3ChatRuntimeInvocationReader? runtimeInvocationReader,
}) => ProviderScope(
  overrides: <Override>[chatRunTrackerProvider.overrideWith((ref) => tracker)],
  child: MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: Scaffold(
          bottomNavigationBar: bottomNavigationBar,
          body: CustomScrollView(
            slivers: <Widget>[
              V3ChatConversationTimeline(
                key: timelineKey,
                threadId: threadId,
                messages: messages,
                fallbackRunStatuses: fallbackRunStatuses,
                fallbackToolRunId: fallbackToolRunId,
                fallbackToolTrace: assistantToolTracesFromLegacy(
                  fallbackToolTrace,
                ),
                isSending: isSending,
                isThreadPending: () => threadPending,
                assistantAnswerDrafts: drafts,
                imageAttachmentsBuilder: (_, __, ___) =>
                    const SizedBox.shrink(),
                resourceAttachmentsBuilder: (_, __) => const SizedBox.shrink(),
                isCreatingNote: (_) => false,
                createNoteActionFor: (_) => null,
                onStreamingRebuild: () {},
                onRunRebuild: () {},
                runtimeInvocationReader: runtimeInvocationReader,
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

Future<void> _doubleTapChatWord(
  WidgetTester tester,
  RenderParagraph paragraph,
  int offset,
) async {
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + 1),
      )
      .single;
  final position = paragraph.localToGlobal(box.toRect().center);
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tapAt(position);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

BoxDecoration _liveVoiceDecoration(WidgetTester tester) {
  final decoration = tester
      .widget<DecoratedBox>(
        find.byKey(const ValueKey<String>('chat-live-transcription-voice')),
      )
      .decoration;
  return decoration as BoxDecoration;
}

final class _NeverCompletingCatalogPort implements MobileAgentCapabilityPort {
  final _profiles = Completer<ApiResult<AgentProfileCatalog>>();
  int profileCalls = 0;

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() {
    profileCalls += 1;
    return _profiles.future;
  }

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) => Future<ApiResult<List<SkillProfileCatalogItem>>>.error(
    StateError('Unexpected catalog skills request'),
  );

  @override
  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) => Future<ApiResult<List<ModelProfileCatalogItem>>>.error(
    StateError('Unexpected catalog models request'),
  );

  @override
  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) => Future<ApiResult<SharedSkillInstallationList>>.error(
    StateError('Unexpected installation request'),
  );

  @override
  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) => Future<ApiResult<AgentRunSnapshot>>.error(
    StateError('Unexpected Agent Run request'),
  );

  @override
  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId) =>
      Future<ApiResult<AgentRunSnapshot>>.error(
        StateError('Unexpected Agent Run poll'),
      );

  @override
  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId) =>
      Future<ApiResult<SharedRunUsage>>.error(
        StateError('Unexpected usage request'),
      );
}

final class _WidgetChatApi
    implements ChatRepository, AssistantThreadProgressPort {
  _WidgetChatApi({
    this.detailMessages = const <String, List<ChatMessage>>{},
    this.detailThreads = const <String, ChatThread>{},
    this.detailCompleters =
        const <String, Completer<ApiResult<ChatThreadDetail>>>{},
    this.threadPurposes = const <String, ChatConversationPurpose>{},
    this.listedThreads,
    this.sendFailureCode,
    this.listFailureCode,
    this.textMutationCompleter,
    this.nextAction = const ChatNextAction.none(),
    this.assistantMessage,
    this.secondThreadAgentProfileId = 'self_media_creation',
    Iterable<AssistantProgressPage> progressPages =
        const <AssistantProgressPage>[],
  }) : _progressPages = List<AssistantProgressPage>.of(progressPages);

  final Map<String, List<ChatMessage>> detailMessages;
  final Map<String, ChatThread> detailThreads;
  final Map<String, Completer<ApiResult<ChatThreadDetail>>> detailCompleters;
  final Map<String, ChatConversationPurpose> threadPurposes;
  final List<ChatThread>? listedThreads;
  String? sendFailureCode;
  final String? listFailureCode;
  final Completer<ApiResult<ChatTextMutation>>? textMutationCompleter;
  final ChatNextAction nextAction;
  final ChatMessage? assistantMessage;
  final String secondThreadAgentProfileId;
  final List<AssistantProgressPage> _progressPages;
  final sentContents = <String>[];
  final sentContexts = <ChatContextEnvelope?>[];
  final sentThreadIds = <String>[];
  final sentAgentProfileIds = <String?>[];
  final sentContentLineIds = <String?>[];
  final createdContentLineIds = <String?>[];
  final detailThreadIds = <String>[];
  final listPurposes = <ChatConversationPurpose>[];
  int listThreadCalls = 0;
  int voiceMessageCalls = 0;

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    createdContentLineIds.add(contentLineId);
    return _success(
      ChatThread(
        threadId: contentLineId == null ? 'feed-1' : 'context-thread-1',
        scene: ChatScene.feedAi,
        purpose: purpose,
      ),
      idempotencyStore,
    );
  }

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async {
    detailThreadIds.add(threadId);
    final completer = detailCompleters[threadId];
    if (completer != null) return completer.future;
    return _success(
      ChatThreadDetail(
        thread:
            detailThreads[threadId] ??
            ChatThread(
              threadId: threadId,
              scene: ChatScene.feedAi,
              purpose:
                  threadPurposes[threadId] ?? ChatConversationPurpose.general,
              agentProfileId: threadId == 'feed-2'
                  ? secondThreadAgentProfileId
                  : standardCreationChatAgentProfileId,
            ),
        messages:
            detailMessages[threadId] ??
            <ChatMessage>[
              ChatMessage(
                messageId: 'user-$threadId',
                threadId: threadId,
                scene: ChatScene.feedAi,
                role: ChatMessageRole.user,
                contentType: ChatMessageContentType.text,
                status: 'sent',
                textPreview: threadId == 'feed-2' ? '请分析第二次访谈' : '如何整理客户访谈',
                createdAt: DateTime.utc(2026, 8, 1, 8),
              ),
              ChatMessage(
                messageId: 'assistant-$threadId',
                threadId: threadId,
                scene: ChatScene.feedAi,
                role: ChatMessageRole.assistant,
                contentType: ChatMessageContentType.text,
                status: 'sent',
                textPreview: threadId == 'feed-2' ? '第二个服务器会话' : '服务器已返回的内容',
                createdAt: DateTime.utc(2026, 8, 1, 8, 0, 2),
              ),
            ],
      ),
      SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async {
    listThreadCalls += 1;
    listPurposes.add(purpose);
    if (listFailureCode case final code?) {
      return ApiResult<ChatThreadPage>.failure(
        error: chatApiFailure(code),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return _success(
      ChatThreadPage(
        items:
            listedThreads ??
            <ChatThread>[
              ChatThread(
                threadId: 'feed-1',
                scene: ChatScene.feedAi,
                title: '当前会话',
                updatedAt: DateTime.utc(2026, 7, 10),
                agentProfileId: standardCreationChatAgentProfileId,
              ),
              ChatThread(
                threadId: 'feed-2',
                scene: ChatScene.feedAi,
                title: '历史会话',
                updatedAt: DateTime.utc(2026, 7, 9),
                agentProfileId: secondThreadAgentProfileId,
              ),
            ],
      ),
      SubmissionKeyStore.empty,
    );
  }

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
  }) async {
    sentContents.add(content);
    sentAgentProfileIds.add(agentProfileId);
    sentContexts.add(context);
    sentThreadIds.add(threadId);
    sentContentLineIds.add(contentLineId);
    if (sendFailureCode case final code?) {
      return ApiResult<ChatTextMutation>.failure(
        error: chatApiFailure(code),
        idempotencyStore: idempotencyStore,
      );
    }
    if (textMutationCompleter case final completer?) {
      return completer.future;
    }
    return _success(
      ChatTextMutation(
        message: ChatMessage(
          messageId: 'user-${sentContents.length}',
          threadId: threadId,
          scene: scene,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.text,
          status: 'sent',
        ),
        assistantMessage: assistantMessage,
        nextAction: nextAction,
      ),
      idempotencyStore,
    );
  }

  @override
  Future<ApiResult<ChatVoiceMutation>> sendVoiceMessage({
    required String threadId,
    required ChatScene scene,
    required String audioResourceId,
    required int durationSeconds,
    String? contentLineId,
    ChatContextEnvelope? context,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    voiceMessageCalls += 1;
    return _success(
      ChatVoiceMutation(
        message: ChatMessage(
          messageId: 'voice-$audioResourceId',
          threadId: threadId,
          scene: scene,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.voice,
          status: 'sent',
        ),
      ),
      idempotencyStore,
    );
  }

  @override
  Future<AssistantRuntimeRead<AssistantProgressPage>> readProgress({
    required String conversationId,
    required int afterSequence,
  }) async {
    final page = _progressPages.isEmpty
        ? AssistantProgressPage(
            conversationId: conversationId,
            events: const <AssistantProgressEvent>[],
            nextSequence: afterSequence,
          )
        : _progressPages.removeAt(0);
    return AssistantRuntimeRead.success(page);
  }
}

AgentRunSnapshot _widgetAgentRun({
  required String agentRunId,
  required String status,
  String? assistantMessageId,
  String? completionMode,
  List<AgentRunToolTrace> toolTrace = const <AgentRunToolTrace>[],
}) {
  return AgentRunSnapshot(
    agentRunId: agentRunId,
    workspaceId: 'workspace-widget',
    threadId: 'feed-1',
    status: status,
    workspaceVersion: 1,
    workspaceBindingVersion: 1,
    contextGeneration: 1,
    assistantMessageId: assistantMessageId,
    completionMode: completionMode,
    usage: const AgentRunUsage(
      measurementStatus: 'unavailable',
      inputTokens: null,
      outputTokens: null,
      imageCount: null,
      videoSeconds: null,
      accountedCredits: null,
      policyVersion: null,
    ),
    toolTrace: toolTrace,
    createdAt: DateTime.utc(2026, 8, 11, 8),
    updatedAt: DateTime.utc(2026, 8, 11, 8, 0, 2),
  );
}

final class _WidgetAgentRunApi implements ProjectRunFixture {
  _WidgetAgentRunApi(this.results);

  final List<Future<ApiResult<AgentRunSnapshot>>> results;
  final calls = <String>[];

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({required String agentRunId}) {
    calls.add(agentRunId);
    return results.removeAt(0);
  }
}

final class _ChatLiveRecorder implements VoiceRecorderPort {
  _ChatLiveRecorder({this.permissionResult});

  final Future<VoiceRecorderResult<VoiceRecorderPermission>>? permissionResult;
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  final startedScenes = <VoiceRecordingScene>[];
  int cancelCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    cancelCalls += 1;
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async {
    final pending = permissionResult;
    if (pending != null) return pending;
    return VoiceRecorderResult.success(
      const VoiceRecorderPermission(
        state: VoiceRecorderPermissionState.granted,
        canAskAgain: false,
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async {
    pauseCalls += 1;
    _snapshot = _snapshot.copyWith(
      state: VoiceRecorderState.paused,
      session: _session(VoiceRecorderState.paused),
    );
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async {
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() => getMicrophonePermission();

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async {
    resumeCalls += 1;
    _snapshot = _snapshot.copyWith(
      state: VoiceRecorderState.recording,
      session: _session(VoiceRecorderState.recording),
    );
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    startedScenes.add(scene);
    final session = _session(VoiceRecorderState.recording, scene: scene);
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() async {
    throw UnimplementedError();
  }

  VoiceRecordingSession _session(
    VoiceRecorderState state, {
    VoiceRecordingScene scene = VoiceRecordingScene.monologue,
  }) {
    return VoiceRecordingSession(
      recordingId: 'live-chat-voice',
      scene: scene,
      state: state,
      startedAt: DateTime.utc(2026, 8, 10, 8),
    );
  }
}

final class _ChatLiveCredentialPort implements LiveTranscriptionCredentialPort {
  const _ChatLiveCredentialPort();

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async {
    return _success(
      LiveAsrSessionCredential(
        sessionId: 'v3-live-chat-session',
        appId: 123456789,
        projectId: 0,
        tmpSecretId: 'tmp-secret-id',
        tmpSecretKey: 'tmp-secret-key',
        token: 'tmp-token',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
      ),
      SubmissionKeyStore.empty,
    );
  }
}

final class _ChatUnavailableLiveCredentialPort
    implements LiveTranscriptionCredentialPort {
  const _ChatUnavailableLiveCredentialPort();

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async {
    return ApiResult<LiveAsrSessionCredential>.failure(
      error: const AppFailure(
        code: 'REALTIME_ASR_SESSION_UNAVAILABLE',
        category: AppFailureCategory.api,
        message: 'realtime ASR unavailable',
        userMessageKey: 'test.realtimeAsr.unavailable',
      ),
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _ChatLiveAsrPort implements TencentLiveAsrPort {
  final StreamController<LiveTranscriptSentence> _events =
      StreamController<LiveTranscriptSentence>.broadcast(sync: true);

  @override
  Stream<LiveTranscriptSentence> get events => _events.stream;

  void add(LiveTranscriptSentence sentence) => _events.add(sentence);

  @override
  Future<LiveAsrOperationResult> connect(
    LiveAsrSessionCredential credential,
  ) async {
    return const LiveAsrOperationResult.success();
  }

  @override
  Future<LiveAsrOperationResult> release() async {
    return const LiveAsrOperationResult.success();
  }

  @override
  Future<LiveAsrOperationResult> stop() async {
    return const LiveAsrOperationResult.success();
  }

  Future<void> close() => _events.close();
}

final class _SynchronizingNotePort implements KnowledgeNotePort {
  final requestedNoteIds = <String>[];

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    requestedNoteIds.add(request.noteId);
    return KnowledgeNotePortResult.success(
      V3FeedItem(
        id: request.noteId,
        title: request.draft.title,
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 8),
        rawBody: request.draft.rawBody,
        localRevision: request.localRevision,
        remoteRevision: 1,
        remoteNoteId: 'remote-${request.noteId}',
        noteRevisionId: 'note-${request.noteId}-1',
        rawPartRevisionId: 'raw-${request.noteId}-1',
        etag: 'etag-${request.noteId}-1',
        contentCursor: 'cursor-${request.noteId}-1',
      ),
    );
  }
}

ApiResult<T> _success<T>(T data, SubmissionKeyStore idempotencyStore) {
  return ApiResult<T>.success(
    data: data,
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

ApiClient _playbackApiClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'test-device-1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () async => 'access-token',
  ),
  transport: transport,
);

final class _GeneratedImagePlaybackTransport implements ApiTransport {
  final resourceIds = <String>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    const prefix = '/api/v1/media/resources/';
    const suffix = '/playback';
    final path = request.url.path;
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) {
      throw StateError('Unexpected request: $path');
    }
    final resourceId = path.substring(
      prefix.length,
      path.length - suffix.length,
    );
    resourceIds.add(resourceId);
    return ApiTransportResponse(
      status: 200,
      body: <String, Object?>{
        'success': true,
        'data': <String, Object?>{
          'resourceId': resourceId,
          'url': 'https://storage.example.test/$resourceId.png',
          'status': 'available',
          'expiresIn': 900,
          'resource': <String, Object?>{
            'resourceId': resourceId,
            'displayName': 'course-cover.png',
            'mimeType': 'image/png',
          },
        },
      },
    );
  }
}

final class _ChatTestAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) {
    if (key == 'AssetManifest.bin') {
      return Future<ByteData>.value(
        const StandardMessageCodec().encodeMessage(<String, Object?>{
          'assets/images/chat_firework_mark.png': <Object?>[
            <String, Object?>{
              'asset': 'assets/images/chat_firework_mark.png',
              'dpr': null,
            },
          ],
        })!,
      );
    }
    if (key == 'assets/images/chat_firework_mark.png') {
      return Future<ByteData>.value(
        ByteData.sublistView(Uint8List.fromList(_transparentPng)),
      );
    }
    return Future<ByteData>.error(FlutterError('Unexpected test asset: $key'));
  }
}

const _transparentPng = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0a,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0d,
  0x0a,
  0x2d,
  0xb4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];
