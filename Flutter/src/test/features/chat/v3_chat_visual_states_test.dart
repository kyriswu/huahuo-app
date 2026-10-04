import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/chat/application/chat_file_attachment_uploader.dart';
import 'package:huahuoai_app/features/chat/application/chat_voice_uploader.dart';
import 'package:huahuoai_app/features/chat/application/voice_message_controller.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_figma_spec.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_entry_surface.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_chat_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_chat_mark.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

import '../../support/figma_golden_test_support.dart';
import '../../support/mobile_agent_test_support.dart';

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M05 production Chat entry and attachment Sheet', (tester) async {
    await _pumpChatPage(tester);
    expect(find.byKey(const ValueKey('chat-entry-surface')), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_chat_entry.png');

    await tester.tap(find.byKey(const ValueKey('chat-entry-add')));
    await tester.pumpAndSettle();
    expect(find.text('引用笔记'), findsOneWidget);
    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('本地文件'), findsNothing);
    await _expectScreenGolden(tester, 'm05_attachment_sheet.png');
  });

  testWidgets('M05 Personal IP uses the specialist guided entry', (
    tester,
  ) async {
    await _pumpChatPage(
      tester,
      workbenchContext: WorkbenchChatContext(
        skill: WorkbenchChatSkill.persona,
        materialIds: const <String>[],
      ),
      initialAgentProfileId: 'renshe_content',
    );

    expect(find.text('Hello，我是个人 IP Agent'), findsOneWidget);
    expect(find.text('从经历、优势和表达中，找到更准确的个人定位。'), findsOneWidget);
    expect(find.text('个人 IP'), findsOneWidget);
    expect(find.text('引用一份资产，提炼能支撑个人 IP 的经历'), findsOneWidget);
    expect(find.text('聊一聊'), findsNothing);
    expect(find.byKey(const ValueKey('chat-entry-avatar')), findsNothing);
    expect(find.byKey(const ValueKey('chat-active-agent-badge')), findsNothing);
    expect(find.text('输入一个问题，开始一段新的对话。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-local-agent-opening-renshe_content')),
      findsNothing,
    );
    expect(find.byType(V3ChatMark), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_personal_ip_entry.png');
  });

  testWidgets('M05 production Note picker default and selected states', (
    tester,
  ) async {
    await _pumpChatPage(tester);
    await tester.tap(find.byKey(const ValueKey('chat-entry-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用笔记'));
    await tester.pumpAndSettle();

    expect(find.text('选择引用笔记'), findsOneWidget);
    expect(find.text('最近更新'), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_note_picker.png');

    await tester.tap(
      find.byKey(const ValueKey('chat-note-picker-note-content-judgment')),
    );
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '引用这篇笔记'), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_note_picker_selected.png');
  });

  testWidgets('M05 Note picker adapts across phone viewports and text scale', (
    tester,
  ) async {
    final scenarios = <({Size size, double textScale})>[
      (size: const Size(320, 568), textScale: 1.3),
      (size: const Size(360, 640), textScale: 1.3),
      (size: const Size(414, 896), textScale: 1.3),
      (size: const Size(430, 932), textScale: 1.0),
    ];
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final scenario in scenarios) {
      tester.view
        ..physicalSize = scenario.size
        ..devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scenario.textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: V3ChatNotePickerSheet(notes: _notes),
            ),
          ),
        ),
      );
      await tester.pump();

      final firstRow = find.byKey(
        const ValueKey('chat-note-picker-note-content-judgment'),
      );
      expect(firstRow, findsOneWidget);
      expect(tester.getSize(firstRow).height, greaterThanOrEqualTo(82));
      expect(
        tester.takeException(),
        isNull,
        reason:
            '${scenario.size.width}x${scenario.size.height} '
            'at ${scenario.textScale} text scale',
      );

      await tester.tap(firstRow);
      await tester.pump();
      expect(
        find.descendant(
          of: firstRow,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('M05 Note picker stays operable above a landscape keyboard', (
    tester,
  ) async {
    const surface = Size(568, 320);
    const keyboardInset = 160.0;
    tester.view
      ..physicalSize = surface
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(top: 24)
      ..viewPadding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: figmaGoldenTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Builder(
          builder: (outerContext) => MediaQuery.removePadding(
            context: outerContext,
            removeTop: true,
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showV3GlassBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => V3ChatNotePickerSheet(notes: _notes),
                  ),
                  child: const Text('打开引用笔记'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final launcher = find.text('打开引用笔记');
    expect(MediaQuery.viewPaddingOf(tester.element(launcher)).top, 0);
    await tester.tap(launcher);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardInset);
    await tester.pumpAndSettle();

    final search = find.byKey(const ValueKey('chat-note-picker-search'));
    final close = find.byKey(const ValueKey('chat-note-picker-close'));
    final firstRow = find.byKey(
      const ValueKey('chat-note-picker-note-content-judgment'),
    );
    final confirm = find.widgetWithText(FilledButton, '引用这篇笔记');
    expect(search.hitTestable(), findsOneWidget);
    expect(close.hitTestable(), findsOneWidget);
    expect(firstRow.hitTestable(), findsOneWidget);
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(search).dy, greaterThanOrEqualTo(24));
    expect(tester.getTopLeft(close).dy, greaterThanOrEqualTo(24));
    expect(
      tester.getBottomRight(confirm).dy,
      lessThanOrEqualTo(surface.height - keyboardInset),
    );

    await tester.tap(firstRow);
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('M05 production Note picker filters visible results', (
    tester,
  ) async {
    await _pumpChatPage(tester);
    await tester.tap(find.byKey(const ValueKey('chat-entry-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chat-note-picker-search')),
      '内容判断',
    );
    await tester.pump();

    expect(find.text('搜索结果 · 2 篇'), findsOneWidget);
    expect(find.text('用户访谈问题清单'), findsNothing);
    await _expectScreenGolden(tester, 'm05_note_picker_results.png');
  });

  testWidgets('M05 production history and rename states', (tester) async {
    await _pumpChatPage(tester, browseAllAgentProfiles: true);
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();

    expect(find.text('对话记录'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-history-row-m05-history-1')),
      findsOneWidget,
    );
    await _expectScreenGolden(tester, 'm05_chat_history.png');

    await tester.tap(
      find.byKey(const ValueKey('chat-history-more-m05-history-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('对话操作'), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_chat_history_actions.png');

    await tester.tap(find.byKey(const ValueKey('chat-history-action-rename')));
    await tester.pumpAndSettle();
    expect(find.text('重命名会话'), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_chat_history_rename.png');
  });

  testWidgets('M05 production history delete confirmation', (tester) async {
    await _pumpChatPage(tester, browseAllAgentProfiles: true);
    await tester.tap(find.byTooltip('会话列表'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('chat-history-more-m05-history-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-history-action-delete')));
    await tester.pumpAndSettle();

    expect(find.text('从本机历史中删除？'), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_chat_history_delete.png');
  });

  testWidgets('M05 production initial thread loading', (tester) async {
    final pending = Completer<ApiResult<ChatThreadPage>>();
    await _pumpChatPage(
      tester,
      api: _VisualChatApi(pendingThreads: pending.future),
      newWindow: false,
      precacheImages: false,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await _expectScreenGolden(tester, 'm05_initial_loading.png');
    pending.complete(_success(const ChatThreadPage(items: <ChatThread>[])));
    await tester.pumpAndSettle();
  });

  testWidgets('M05 production restored conversation record', (tester) async {
    await _pumpConversationPage(tester, _conversationRecordMessages);
    expect(find.textContaining('可以读到。你引用的资产是'), findsOneWidget);
    expect(find.text('服务器升级中，请稍后再试'), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_conversation_record.png');
  });

  testWidgets('M05 production live transcription visual states', (
    tester,
  ) async {
    final recorder = _VisualLiveRecorder();
    final asr = _VisualLiveAsrPort();
    final liveTranscript = LiveTranscriptController(
      credentialPort: const _VisualLiveCredentialPort(),
      asrPort: asr,
    );
    await _pumpChatPage(
      tester,
      extraOverrides: <Override>[
        authenticatedUserDataScopeProvider.overrideWithValue('m05-visual-user'),
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
    );

    await _expectScreenGolden(tester, 'm05_voice_before_transcription.png');
    await tester.tap(find.byTooltip('开始实时转写'));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在转写，可继续说…'), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_voice_transcribing.png');

    await tester.tap(find.byTooltip('结束实时转写'));
    await tester.pumpAndSettle();
    expect(find.text(ChatEntryFigmaSpec.composerHint), findsOneWidget);
    await _expectScreenGolden(tester, 'm05_voice_transcribed.png');
    await asr.close();
  });

  for (final fixture in _executionFixtures) {
    testWidgets('M05 execution state ${fixture.name}', (tester) async {
      await _pumpExecutionState(
        tester,
        prompt: fixture.prompt,
        activity: V3ChatExecutionProcess(
          kind: fixture.kind,
          activeStep: fixture.activeStep,
        ),
      );
      expect(find.text('执行过程'), findsOneWidget);
      await _expectScreenGolden(tester, fixture.golden);
    });
  }

  for (final fixture in _receivedFixtures) {
    testWidgets('M05 received state ${fixture.name}', (tester) async {
      await _pumpExecutionState(
        tester,
        prompt: fixture.prompt,
        activity: V3ChatReceivedActivityCard(noteAware: fixture.noteAware),
      );
      expect(find.text('聊一聊 Agent'), findsOneWidget);
      await _expectScreenGolden(tester, fixture.golden);
    });
  }

  for (final fixture in _replyFixtures) {
    testWidgets('M05 production reply state ${fixture.name}', (tester) async {
      await _pumpConversationPage(tester, <ChatMessage>[
        _userMessage('${fixture.name}-user', fixture.prompt),
        _assistantMessage('${fixture.name}-assistant', fixture.reply),
      ]);
      expect(find.text(fixture.reply), findsOneWidget);
      await _expectScreenGolden(tester, fixture.golden);
    });
  }

  for (final fixture in _attachmentFixtures) {
    testWidgets('M05 document attachment ${fixture.name}', (tester) async {
      await _pumpAttachmentState(tester, fixture.attachment);
      expect(find.textContaining('选题素材.pdf'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-attachment-continue')),
        findsOneWidget,
      );
      await _expectScreenGolden(tester, fixture.golden);
    });
  }
}

Future<void> _pumpChatPage(
  WidgetTester tester, {
  ChatRepository? api,
  bool newWindow = true,
  String? threadId,
  bool precacheImages = true,
  WorkbenchChatContext? workbenchContext,
  String? initialAgentProfileId,
  bool browseAllAgentProfiles = false,
  List<Override> extraOverrides = const <Override>[],
}) async {
  await _configureViewport(tester);
  final library = KnowledgeLibraryController(
    initialNotes: _notes,
    includeDemoFixtures: false,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        ...mobileAgentReadyTestOverrides(),
        chatRepositoryProvider.overrideWithValue(api ?? _VisualChatApi()),
        if (initialAgentProfileId != null || browseAllAgentProfiles)
          feedAiChatControllerProvider.overrideWith(
            (ref) => createFeedAiChatController(
              ref,
              initialAgentProfileId: initialAgentProfileId,
              browseAllAgentProfiles: browseAllAgentProfiles,
            ),
          ),
        knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        resolvedDeviceIdProvider.overrideWithValue('m05-visual-device'),
        ...extraOverrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: figmaGoldenTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(402, 874),
            padding: EdgeInsets.only(top: 54, bottom: 24),
            viewPadding: EdgeInsets.only(top: 54, bottom: 24),
          ),
          child: V3ChatPage(
            threadId: threadId,
            windowId: newWindow ? 'm05-visual-entry' : null,
            workbenchContext: workbenchContext,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  if (precacheImages) await precacheFigmaFixtureImages(tester);
}

Future<void> _pumpConversationPage(
  WidgetTester tester,
  List<ChatMessage> messages,
) {
  return _pumpChatPage(
    tester,
    api: _VisualChatApi(detailMessages: messages),
    newWindow: false,
    threadId: _visualThreadId,
  );
}

Future<void> _pumpExecutionState(
  WidgetTester tester, {
  required String prompt,
  required Widget activity,
}) async {
  await _configureViewport(tester);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: figmaGoldenTheme(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(402, 874),
          padding: EdgeInsets.only(top: 54, bottom: 24),
          viewPadding: EdgeInsets.only(top: 54, bottom: 24),
        ),
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _VisualChatHeader(),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      width: 332,
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F4F2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            prompt,
                            style: const TextStyle(fontSize: 15, height: 1.45),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '发送于 刚刚',
                            style: TextStyle(
                              color: Color(0xFF7A7A7A),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  activity,
                  const Spacer(),
                  const _VisualComposer(),
                  const SizedBox(height: 4),
                  const Center(
                    child: Text(
                      ChatEntryFigmaSpec.disclaimer,
                      style: TextStyle(fontSize: 11, color: Color(0xFF6F6F6F)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpAttachmentState(
  WidgetTester tester,
  ChatFileAttachment attachment,
) async {
  await _configureViewport(tester);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: figmaGoldenTheme(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(402, 874),
          padding: EdgeInsets.only(top: 54, bottom: 24),
          viewPadding: EdgeInsets.only(top: 54, bottom: 24),
        ),
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 58,
                    child: Row(
                      children: [
                        const Icon(Icons.arrow_back_rounded, size: 22),
                        const SizedBox(width: 12),
                        const CircleAvatar(
                          radius: 17,
                          child: Icon(Icons.person_outline_rounded, size: 19),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            '聊一聊',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        ChatEntryHeaderActions(
                          onHistory: () {},
                          onNewConversation: () {},
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ChatEntrySurface(
                      showIntro: false,
                      suggestionSets: _attachmentSuggestions,
                      onSuggestion: (_) {},
                    ),
                  ),
                  Builder(
                    builder: (context) {
                      final colors = HuahuoV3Theme.tokensOf(context);
                      return Container(
                        key: const ValueKey('chat-composer-context-panel'),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: colors.line),
                          boxShadow: [
                            BoxShadow(
                              color: colors.ink.withValues(alpha: .08),
                              blurRadius: 12,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                              child: V3ChatFileAttachmentStrip(
                                attachments: <ChatFileAttachment>[attachment],
                                onRemove: (_) {},
                                onRetry: (_) {},
                                onPreview: (_) {},
                                onContinueAdding: () {},
                              ),
                            ),
                            const SizedBox(height: 12),
                            Divider(height: 1, color: colors.line),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
                              child: _VisualComposer(),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              ChatEntryFigmaSpec.disclaimer,
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF6F6F6F),
                              ),
                            ),
                            const SizedBox(height: 5),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _configureViewport(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _expectScreenGolden(WidgetTester tester, String name) {
  return expectLater(
    find.byType(Overlay).first,
    matchesGoldenFile('goldens/$name'),
  );
}

final _fixtureToday = DateTime.now();
final _fixtureYesterday = DateTime(
  _fixtureToday.year,
  _fixtureToday.month,
  _fixtureToday.day - 1,
);

final _notes = <V3FeedItem>[
  V3FeedItem(
    id: 'note-content-judgment',
    title: '内容不是堆数量，而是形成判断',
    source: V3MaterialSource.note,
    createdAt: DateTime(
      _fixtureYesterday.year,
      _fixtureYesterday.month,
      _fixtureYesterday.day,
      9,
      9,
    ),
    updatedAt: DateTime(
      _fixtureYesterday.year,
      _fixtureYesterday.month,
      _fixtureYesterday.day,
      9,
      9,
    ),
    rawBody: '整理信息后补上自己的判断依据，让笔记可以再次被调用。内容判断',
  ),
  V3FeedItem(
    id: 'note-product-review',
    title: '产品复盘：从信息到判断',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 8, 23, 22, 46),
    updatedAt: DateTime(2026, 8, 23, 22, 46),
    rawBody: '关键证据、结论与待验证问题，方便后续继续推进。内容判断',
  ),
  V3FeedItem(
    id: 'note-inspiration-network',
    title: '把零散灵感整理成知识网络',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 8, 22, 22, 46),
    rawBody: '从捕捉、聚合到关联，形成可以继续探索的主题路径。',
  ),
  V3FeedItem(
    id: 'note-interview-list',
    title: '用户访谈问题清单',
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 8, 18, 10),
    rawBody: '按目标、行为和阻碍组织问题，减少无效信息。',
  ),
];

const _attachmentSuggestions = <List<ChatEntrySuggestionSpec>>[
  <ChatEntrySuggestionSpec>[
    ChatEntrySuggestionSpec(
      kind: ChatEntrySuggestionKind.prompt,
      label: '帮我把一个模糊想法梳理成清晰的创作方向',
    ),
    ChatEntrySuggestionSpec(
      kind: ChatEntrySuggestionKind.notePicker,
      label: '从我的笔记里提炼 3 个值得展开的选题',
    ),
    ChatEntrySuggestionSpec(
      kind: ChatEntrySuggestionKind.prompt,
      label: '为这个主题列出可直接开始写的内容大纲',
    ),
  ],
];

const _visualThreadId = 'm05-visual-thread';

final _conversationRecordMessages = <ChatMessage>[
  _userMessage(
    'record-user-1',
    '可以读到我引用的资产吗',
    at: DateTime(2026, 8, 20, 3, 30),
  ),
  _assistantMessage(
    'record-assistant-1',
    '可以读到。你引用的资产是一篇会议笔记。\n'
        '这是一段你之前和顾问对话的记录，里面提到了你的几个关键经历：\n'
        '• 做过越南排名第一的小说 APP\n'
        '• 16 年就开始做 AI 投放系统\n'
        '• 现在有渠道能卖 10 万台硬件产品\n'
        '你现在想继续推进哪个方向？还是有新的想法想聊？',
    at: DateTime(2026, 8, 20, 3, 30),
  ),
  _userMessage(
    'record-user-2',
    '我想从中得到一个合适的选题。帮我提炼一下，认真提炼一下。',
    at: DateTime(2026, 8, 20, 4, 39),
  ),
  _assistantMessage(
    'record-assistant-2',
    '服务器升级中，请稍后再试',
    at: DateTime(2026, 8, 20, 4, 39),
  ),
];

final _executionFixtures =
    <
      ({
        String name,
        String prompt,
        V3ChatExecutionKind kind,
        int activeStep,
        String golden,
      })
    >[
      (
        name: 'reading workspace',
        prompt: '阅读一下当前我的资产',
        kind: V3ChatExecutionKind.workspace,
        activeStep: 0,
        golden: 'm05_reading_workspace.png',
      ),
      (
        name: 'analyzing reference',
        prompt: '去笔记库里面帮我选一篇生成选题',
        kind: V3ChatExecutionKind.noteLibrary,
        activeStep: 1,
        golden: 'm05_analyzing_reference.png',
      ),
      (
        name: 'researching sources',
        prompt: '去笔记库里面帮我选一篇生成选题',
        kind: V3ChatExecutionKind.noteLibrary,
        activeStep: 2,
        golden: 'm05_researching_sources.png',
      ),
      (
        name: 'topic analyzing',
        prompt: '帮我选一个今天的热点生成选题',
        kind: V3ChatExecutionKind.dailyTopics,
        activeStep: 1,
        golden: 'm05_topic_analyzing.png',
      ),
      (
        name: 'note analyzing',
        prompt: '帮我用这个完整的分析框架生成选题',
        kind: V3ChatExecutionKind.referencedNote,
        activeStep: 1,
        golden: 'm05_note_analyzing.png',
      ),
      (
        name: 'topic tool running',
        prompt: '帮我选一个今天的热点生成选题',
        kind: V3ChatExecutionKind.dailyTopics,
        activeStep: 2,
        golden: 'm05_topic_tool_running.png',
      ),
      (
        name: 'note tool running',
        prompt: '帮我用这个完整的分析框架生成选题',
        kind: V3ChatExecutionKind.referencedNote,
        activeStep: 2,
        golden: 'm05_note_tool_running.png',
      ),
    ];

const _receivedFixtures =
    <({String name, String prompt, bool noteAware, String golden})>[
      (
        name: 'suggested question 2',
        prompt: '去笔记库里面帮我选一篇生成选题',
        noteAware: false,
        golden: 'm05_suggested_question_2_sent.png',
      ),
      (
        name: 'suggested question 3',
        prompt: '帮我选一个今天的热点生成选题',
        noteAware: false,
        golden: 'm05_suggested_question_3_sent.png',
      ),
      (
        name: 'note auto sent',
        prompt: '帮我用这个完整的分析框架生成选题',
        noteAware: true,
        golden: 'm05_note_auto_sent.png',
      ),
    ];

const _replyFixtures =
    <({String name, String prompt, String reply, String golden})>[
      (
        name: 'reply output',
        prompt: '去笔记库里面帮我选一篇生成选题',
        reply: '分析完成，已整理出一组选题建议。',
        golden: 'm05_reply_output.png',
      ),
      (
        name: 'topic response',
        prompt: '帮我选一个今天的热点生成选题',
        reply: '已结合今日热点整理出一组选题建议。',
        golden: 'm05_topic_response.png',
      ),
      (
        name: 'note response',
        prompt: '帮我用这个完整的分析框架生成选题',
        reply: '分析完成，已整理出一组选题建议。',
        golden: 'm05_note_response.png',
      ),
    ];

ChatMessage _userMessage(String id, String text, {DateTime? at}) => ChatMessage(
  messageId: id,
  threadId: _visualThreadId,
  scene: ChatScene.feedAi,
  role: ChatMessageRole.user,
  contentType: ChatMessageContentType.text,
  status: 'sent',
  textPreview: text,
  createdAt: at ?? DateTime(2026, 8, 24, 18, 57),
);

ChatMessage _assistantMessage(String id, String text, {DateTime? at}) =>
    ChatMessage(
      messageId: id,
      threadId: _visualThreadId,
      scene: ChatScene.feedAi,
      role: ChatMessageRole.assistant,
      contentType: ChatMessageContentType.text,
      status: 'sent',
      textPreview: text,
      createdAt: at ?? DateTime(2026, 8, 24, 18, 58),
    );

const _attachmentFixtures =
    <({String name, ChatFileAttachment attachment, String golden})>[
      (
        name: 'uploading',
        attachment: ChatFileAttachment(
          localId: 'uploading-file',
          displayName: '选题素材.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1024,
          status: ChatFileAttachmentStatus.uploading,
          kind: ChatFileAttachmentKind.file,
        ),
        golden: 'm05_attachment_uploading.png',
      ),
      (
        name: 'ready',
        attachment: ChatFileAttachment(
          localId: 'ready-file',
          displayName: '选题素材.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1024,
          status: ChatFileAttachmentStatus.ready,
          kind: ChatFileAttachmentKind.file,
          resourceId: 'chat-file-resource',
        ),
        golden: 'm05_attachment_ready.png',
      ),
      (
        name: 'failed',
        attachment: ChatFileAttachment(
          localId: 'failed-file',
          displayName: '选题素材.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 1024,
          status: ChatFileAttachmentStatus.failed,
          kind: ChatFileAttachmentKind.file,
          errorCode: 'UPLOAD_FAILED',
        ),
        golden: 'm05_attachment_failed.png',
      ),
    ];

class _VisualComposer extends StatelessWidget {
  const _VisualComposer();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      height: V3ChatComposerMetrics.height,
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(V3ChatComposerMetrics.radius),
        border: Border.all(color: colors.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.add_rounded, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ChatEntryFigmaSpec.composerHint,
              style: TextStyle(color: colors.muted, fontSize: 14),
            ),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic_none_rounded, size: 20),
          ),
          const SizedBox(width: 6),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colors.accent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.arrow_upward_rounded,
              color: colors.onPrimary,
              size: 22,
            ),
          ),
        ],
      ),
    );
  }
}

class _VisualChatHeader extends StatelessWidget {
  const _VisualChatHeader();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          const Icon(Icons.arrow_back_rounded, size: 22),
          const SizedBox(width: 12),
          const CircleAvatar(
            radius: 17,
            child: Icon(Icons.person_outline_rounded, size: 19),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '聊一聊',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
          ),
          ChatEntryHeaderActions(onHistory: () {}, onNewConversation: () {}),
        ],
      ),
    );
  }
}

final class _VisualChatApi implements ChatRepository {
  _VisualChatApi({
    this.detailMessages = const <ChatMessage>[],
    this.pendingThreads,
  });

  final List<ChatMessage> detailMessages;
  final Future<ApiResult<ChatThreadPage>>? pendingThreads;

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => _success(ChatThread(threadId: 'm05-thread', scene: scene));

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async => _success(
    ChatThreadDetail(
      thread: ChatThread(
        threadId: threadId,
        scene: ChatScene.feedAi,
        title: '视觉验收会话',
        agentProfileId: standardCreationChatAgentProfileId,
      ),
      messages: detailMessages,
    ),
  );

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async {
    if (pendingThreads case final pending?) return pending;
    final today = DateTime.now();
    final now = DateTime(today.year, today.month, today.day, 15, 50);
    return _success(
      ChatThreadPage(
        items: <ChatThread>[
          ChatThread(
            threadId: 'm05-history-1',
            scene: scene,
            title: '从一篇笔记生成三个选题',
            updatedAt: now,
            agentProfileId: standardCreationChatAgentProfileId,
          ),
          ChatThread(
            threadId: 'm05-history-2',
            scene: scene,
            title: '为个人 IP 梳理内容方向',
            updatedAt: DateTime(now.year, now.month, now.day, 14, 32),
            agentProfileId: 'renshe_content',
          ),
          ChatThread(
            threadId: 'm05-history-3',
            scene: scene,
            title: '生成一张拍摄视觉参考',
            updatedAt: DateTime(now.year, now.month, now.day - 1, 20, 10),
            agentProfileId: 'visual_chat',
          ),
          ChatThread(
            threadId: 'm05-history-4',
            scene: scene,
            title: '分析热门视频的内容结构',
            updatedAt: DateTime(2020, 8, 20, 9, 20),
            agentProfileId: 'video_analysis',
          ),
        ],
      ),
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
  }) => throw UnimplementedError();

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
  }) => throw UnimplementedError();
}

final class _VisualLiveRecorder implements VoiceRecorderPort {
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async => VoiceRecorderResult.success(
    const VoiceRecorderPermission(
      state: VoiceRecorderPermissionState.granted,
      canAskAgain: false,
    ),
  );

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() => getMicrophonePermission();

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    final session = VoiceRecordingSession(
      recordingId: 'm05-live-voice',
      scene: scene,
      state: VoiceRecorderState.recording,
      startedAt: DateTime.utc(2026, 8, 24, 9),
    );
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() =>
      throw UnimplementedError();
}

final class _VisualLiveCredentialPort
    implements LiveTranscriptionCredentialPort {
  const _VisualLiveCredentialPort();

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async => _success(
    LiveAsrSessionCredential(
      sessionId: 'm05-live-session',
      appId: 123456789,
      projectId: 0,
      tmpSecretId: 'visual-secret-id',
      tmpSecretKey: 'visual-secret-key',
      token: 'visual-token',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    ),
  );
}

final class _VisualLiveAsrPort implements TencentLiveAsrPort {
  final StreamController<LiveTranscriptSentence> _events =
      StreamController<LiveTranscriptSentence>.broadcast(sync: true);

  @override
  Stream<LiveTranscriptSentence> get events => _events.stream;

  @override
  Future<LiveAsrOperationResult> connect(
    LiveAsrSessionCredential credential,
  ) async => const LiveAsrOperationResult.success();

  @override
  Future<LiveAsrOperationResult> release() async =>
      const LiveAsrOperationResult.success();

  @override
  Future<LiveAsrOperationResult> stop() async =>
      const LiveAsrOperationResult.success();

  Future<void> close() => _events.close();
}

ApiResult<T> _success<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);
