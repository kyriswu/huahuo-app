import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/creation_canvas_draft_dao.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/chat/application/chat_voice_uploader.dart';
import 'package:huahuoai_app/features/chat/application/voice_message_controller.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/daily_topic_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/canvas_ai_transform_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_document_codec.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_draft_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_history_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_draft.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_history.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_creation_canvas_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_creation_history_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_workbench_page.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_liquid_glass.dart';

import '../../support/figma_golden_test_support.dart';
import '../../support/mobile_agent_test_support.dart';

const _surface = Size(402, 874);
const _articleTitle = '欧洲难民政策的裂缝从哪里开始';
const _articleBody = '''欧盟新规落地仅一周，多名乌克兰男性在捷克申请临时保护被驳回。

从一个具体国家的政策执行切口进入，追踪临时保护机制变化。

以及被拒难民失去保障后的实际流动路径。''';

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M03 canvas default', (tester) async {
    final harness = await _pumpCanvas(tester, draft: null);
    addTearDown(harness.dispose);

    await expectLater(
      find.byType(V3CreationCanvasPage),
      matchesGoldenFile('goldens/m03_canvas_default.png'),
    );
  });

  testWidgets('M03 canvas keyboard geometry', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-body-field')));
    await tester.pump();
    await expectLater(
      find.byType(V3CreationCanvasPage),
      matchesGoldenFile('goldens/m03_canvas_keyboard.png'),
    );
  });

  testWidgets('M03 canvas selection context', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await _showCanvasSelectionContext(tester);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_selection_context.png'),
    );
  });

  testWidgets('M03 canvas copied feedback', (tester) async {
    String? clipboardText = 'unchanged';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await _showCanvasSelectionContext(tester);
    final selection = _bodyController(tester).selection;
    final expected = _bodyController(
      tester,
    ).document.toPlainText().substring(selection.start, selection.end);
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(clipboardText, expected);
    expect(find.text('已复制'), findsNothing);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_copied.png'),
    );
  });

  testWidgets('M03 canvas select all', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await _showCanvasSelectionContext(tester);
    await tester.tap(find.text('全选'));
    await tester.pump();
    final rawState = tester.state<QuillRawEditorState>(
      find.byType(QuillRawEditor),
    );
    if (find.byType(AdaptiveTextSelectionToolbar).evaluate().isEmpty) {
      expect(rawState.showToolbar(), isTrue);
      await tester.pumpAndSettle();
    }
    expect(_bodyController(tester).selection.extentOffset, greaterThan(40));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_select_all.png'),
    );
  });

  testWidgets('M03 canvas text style controls', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(V3CreationCanvasPage),
      matchesGoldenFile('goldens/m03_canvas_text_style.png'),
    );
  });

  testWidgets('M03 canvas block style controls', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-block-style')));
    await tester.pumpAndSettle();
    await _expectCanvasGolden(tester, 'm03_canvas_block_style.png');
  });

  for (final format in const <(String, String, String)>[
    ('一级标题', 'm03_canvas_heading_h1.png', 'heading h1'),
    ('二级标题', 'm03_canvas_heading_h2.png', 'heading h2'),
    ('三级标题', 'm03_canvas_heading_h3.png', 'heading h3'),
    ('引用', 'm03_canvas_quote.png', 'quote'),
    ('无序列表', 'm03_canvas_unordered_list.png', 'unordered list'),
    ('有序列表', 'm03_canvas_ordered_list.png', 'ordered list'),
    ('代码块', 'm03_canvas_code_block.png', 'code block'),
  ]) {
    testWidgets('M03 canvas ${format.$3}', (tester) async {
      final harness = await _pumpCanvas(tester, draft: _articleDraft());
      addTearDown(harness.dispose);
      _bodyController(tester).updateSelection(
        const TextSelection.collapsed(offset: 1),
        ChangeSource.local,
      );

      await tester.tap(find.byKey(const ValueKey('canvas-block-style')));
      await tester.pumpAndSettle();
      await _tapToolbarTooltip(tester, format.$1);
      await _expectCanvasGolden(tester, format.$2);
    });
  }

  for (final format in const <(String, String, String, bool)>[
    ('加粗', 'm03_canvas_bold.png', 'bold', false),
    ('斜体', 'm03_canvas_italic.png', 'italic', false),
    ('行内代码', 'm03_canvas_inline_code.png', 'inline code', true),
  ]) {
    testWidgets('M03 canvas ${format.$3}', (tester) async {
      final harness = await _pumpCanvas(tester, draft: _articleDraft());
      addTearDown(harness.dispose);
      _bodyController(tester).updateSelection(
        const TextSelection(baseOffset: 22, extentOffset: 31),
        ChangeSource.local,
      );

      if (format.$4) {
        await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
        await tester.pumpAndSettle();
      }
      await _tapToolbarTooltip(tester, format.$1);
      await _expectCanvasGolden(tester, format.$2);
    });
  }

  testWidgets('M03 canvas add, edit and finish link', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);
    _bodyController(tester).updateSelection(
      const TextSelection(baseOffset: 22, extentOffset: 31),
      ChangeSource.local,
    );

    await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
    await tester.pumpAndSettle();
    await _tapToolbarTooltip(tester, '链接');
    await _expectCanvasGolden(tester, 'm03_canvas_link_new.png');

    await tester.enterText(
      find.byKey(const ValueKey('canvas-markdown-link-input')),
      'https://example.com',
    );
    await tester.tap(find.byKey(const ValueKey('canvas-link-apply')));
    await tester.pumpAndSettle();
    _bodyController(tester).updateSelection(
      const TextSelection.collapsed(offset: 25),
      ChangeSource.local,
    );
    await tester.pump();
    await _tapToolbarTooltip(tester, '链接');
    await _expectCanvasGolden(tester, 'm03_canvas_link_existing.png');

    await tester.tap(find.byKey(const ValueKey('canvas-link-done')));
    await tester.pumpAndSettle();
    await _expectCanvasGolden(tester, 'm03_canvas_link_applied.png');
  });

  testWidgets('M03 canvas AI tools default and scrolled', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-ai-tools')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_ai_tools.png'),
    );

    await tester.binding.setSurfaceSize(const Size(402, 600));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('canvas-ai-action-list')),
      const Offset(-280, 0),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_ai_tools_scrolled.png'),
    );
  });

  testWidgets('M03 canvas relationship perspective picker', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-ai-tools')));
    await tester.pumpAndSettle();
    await _tapCanvasAiAction(tester, 'socialRelationShift');
    expect(find.text('选择人称'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_relationship_picker.png'),
    );
  });

  testWidgets('M03 canvas AI running state', (tester) async {
    final harness = await _pumpCanvas(
      tester,
      draft: _articleDraft(),
      aiPort: const CanvasAiTransformMockPort(delay: Duration(seconds: 30)),
    );
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-ai-tools')));
    await tester.pumpAndSettle();
    await _tapCanvasAiAction(tester, 'needsDeepening', settle: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('canvas-ai-running')), findsOneWidget);
    await _expectCanvasGolden(tester, 'm03_canvas_ai_running.png');
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
  });

  testWidgets('M03 canvas AI preview state', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-ai-tools')));
    await tester.pumpAndSettle();
    await _tapCanvasAiAction(tester, 'atomization');
    expect(find.byKey(const ValueKey('canvas-ai-apply')), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_ai_preview.png'),
    );
  });

  testWidgets('M03 canvas more actions', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-more-actions')));
    await tester.pumpAndSettle();
    expect(find.text('创作历史'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_more_sheet.png'),
    );
  });

  testWidgets('M03 canvas creation chat', (tester) async {
    final harness = await _pumpCanvas(tester, draft: _articleDraft());
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-chat-entry')));
    await tester.pumpAndSettle();
    expect(find.text('创作聊天'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_chat.png'),
    );
  });

  testWidgets('M03 canvas creation chat history', (tester) async {
    final history = _visualHistoryPort();
    final harness = await _pumpCanvas(
      tester,
      draft: _articleDraft(),
      historyPort: history,
      chatApi: _VisualCanvasChatApi(),
    );
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('canvas-chat-history')));
    await tester.pumpAndSettle();
    expect(find.text('历史对话'), findsOneWidget);
    expect(find.text('继续打磨政策观察稿'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_chat_history.png'),
    );
  });

  testWidgets('M03 daily recommendation detail', (tester) async {
    final harness = await _pumpRecommendation(tester);
    addTearDown(harness.dispose);

    final renderedText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList(growable: false);
    expect(renderedText, contains('Agent 辅助创作'));
    expect(renderedText, contains('Agent 自由创作'));
    expect(renderedText, isNot(contains('基于这个选题，继续往下创作')));
    expect(find.bySemanticsLabel('聊一聊'), findsOneWidget);
    await expectLater(
      find.byType(V3WorkbenchRecommendationPage),
      matchesGoldenFile('goldens/m03_daily_recommendation.png'),
    );
  });

  testWidgets('M03 daily recommendation note chat', (tester) async {
    final harness = await _pumpRecommendation(tester);
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey('detail-chat-entry')));
    await tester.pumpAndSettle();
    expect(find.text('选择 Agent'), findsNothing);
    expect(find.text('聊一聊'), findsWidgets);
    expect(find.text('猜你想问'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_daily_recommendation_agent_picker.png'),
    );
  });

  testWidgets('M03 canvas live dictation states', (tester) async {
    final recorder = _CanvasVisualRecorder();
    final asr = _CanvasVisualAsrPort();
    final liveTranscript = LiveTranscriptController(
      credentialPort: const _CanvasVisualCredentialPort(),
      asrPort: asr,
    );
    final harness = await _pumpCanvas(
      tester,
      draft: _articleDraft(),
      extraOverrides: <Override>[
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
    addTearDown(harness.dispose);
    addTearDown(asr.close);

    await _tapCanvasPrimaryTool(tester, 'canvas-voice-dictation');
    await tester.pump();
    await tester.pump();
    expect(find.text('正在听… 请开始说话'), findsOneWidget);
    await _expectCanvasGolden(tester, 'm03_canvas_voice_listening.png');

    asr.emit(
      LiveTranscriptSentence(
        sentenceId: 1,
        text: '这项政策还需要持续观察各地执行差异。',
        stable: true,
      ),
    );
    await tester.pump();
    expect(find.text('正在转写，可继续说'), findsOneWidget);
    await _expectCanvasGolden(tester, 'm03_canvas_voice_transcribing.png');

    await _tapCanvasPrimaryTool(
      tester,
      'canvas-voice-dictation',
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('语音已转为文字'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_voice_converted.png'),
    );
    ScaffoldMessenger.of(
      tester.element(find.byType(SnackBar)),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();

    await _tapCanvasPrimaryTool(tester, 'canvas-voice-dictation');
    await tester.pump();
    await tester.pump();
    expect(find.text('正在听… 请开始说话'), findsOneWidget);
    await _tapCanvasPrimaryTool(
      tester,
      'canvas-voice-dictation',
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('没有听清，点麦克风重试'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_voice_no_speech.png'),
    );
  });

  testWidgets('M03 canvas microphone permission recovery', (tester) async {
    final recorder = _CanvasVisualRecorder(permissionGranted: false);
    final asr = _CanvasVisualAsrPort();
    final liveTranscript = LiveTranscriptController(
      credentialPort: const _CanvasVisualCredentialPort(),
      asrPort: asr,
    );
    final harness = await _pumpCanvas(
      tester,
      draft: _articleDraft(),
      extraOverrides: <Override>[
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
    addTearDown(harness.dispose);
    addTearDown(asr.close);

    await _tapCanvasPrimaryTool(tester, 'canvas-voice-dictation');
    await tester.pumpAndSettle();
    expect(find.text('需要麦克风权限'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_canvas_voice_permission.png'),
    );
  });

  testWidgets('M03 creation history populated', (tester) async {
    final harness = await _pumpHistory(tester, port: _visualHistoryPort());
    addTearDown(harness.dispose);

    expect(
      find.ancestor(
        of: find.text('自由创作').first,
        matching: find.byType(V3LiquidGlassSurface),
      ),
      findsNothing,
    );

    await expectLater(
      find.byType(V3CreationHistoryPage),
      matchesGoldenFile('goldens/m03_creation_history.png'),
    );
  });

  testWidgets('M03 creation history loading', (tester) async {
    final harness = await _pumpHistory(
      tester,
      port: _visualHistoryPort(),
      settle: false,
    );
    addTearDown(harness.dispose);

    expect(find.text('正在加载创作历史...'), findsOneWidget);
    await expectLater(
      find.byType(V3CreationHistoryPage),
      matchesGoldenFile('goldens/m03_creation_history_loading.png'),
    );
  });

  testWidgets('M03 creation history failed', (tester) async {
    final harness = await _pumpHistory(
      tester,
      port: const _FailingHistoryPort(),
    );
    addTearDown(harness.dispose);

    expect(find.text('加载失败'), findsOneWidget);
    await expectLater(
      find.byType(V3CreationHistoryPage),
      matchesGoldenFile('goldens/m03_creation_history_failed.png'),
    );
  });

  testWidgets('M03 creation history empty', (tester) async {
    final harness = await _pumpHistory(
      tester,
      port: InMemoryCreationCanvasHistoryPort(),
    );
    addTearDown(harness.dispose);

    expect(find.text('还没有创作历史'), findsOneWidget);
    await expectLater(
      find.byType(V3CreationHistoryPage),
      matchesGoldenFile('goldens/m03_creation_history_empty.png'),
    );
  });

  testWidgets('M03 creation history swipe action', (tester) async {
    final harness = await _pumpHistory(tester, port: _visualHistoryPort());
    addTearDown(harness.dispose);
    final row = find.byKey(const ValueKey('creation-history-history-4'));

    final gesture = await tester.startGesture(tester.getCenter(row));
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-112, 0));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('creation-history-swipe-delete')),
      findsOneWidget,
    );
    await expectLater(
      find.byType(V3CreationHistoryPage),
      matchesGoldenFile('goldens/m03_creation_history_swipe.png'),
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('M03 creation history delete confirmation', (tester) async {
    final harness = await _pumpHistory(tester, port: _visualHistoryPort());
    addTearDown(harness.dispose);

    await _openHistoryDeleteConfirmation(tester);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_creation_history_delete_confirm.png'),
    );
  });

  testWidgets('M03 creation history deleting', (tester) async {
    final harness = await _pumpHistory(tester, port: _visualHistoryPort());
    addTearDown(harness.dispose);

    await _openHistoryDeleteConfirmation(tester);
    await tester.tap(
      find.byKey(const ValueKey('creation-history-delete-confirm')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('正在删除...'), findsOneWidget);
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_creation_history_deleting.png'),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  });

  testWidgets('M03 creation history delete success', (tester) async {
    final history = _visualHistoryPort();
    final harness = await _pumpHistory(tester, port: history);
    addTearDown(harness.dispose);

    await _openHistoryDeleteConfirmation(tester);
    await tester.tap(
      find.byKey(const ValueKey('creation-history-delete-confirm')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('已删除创作历史'), findsOneWidget);
    expect(history.list('test-user'), hasLength(4));
    await expectLater(
      find.byType(Overlay).first,
      matchesGoldenFile('goldens/m03_creation_history_delete_success.png'),
    );
  });
}

CreationCanvasDraft _articleDraft() => CreationCanvasDraft(
  title: _articleTitle,
  markdown: _articleBody,
  revision: 1,
  createdAt: DateTime.utc(2026, 8, 20, 8),
  updatedAt: DateTime.utc(2026, 8, 20, 8),
);

Future<_CanvasHarness> _pumpCanvas(
  WidgetTester tester, {
  required CreationCanvasDraft? draft,
  CanvasAiTransformPort aiPort = const CanvasAiTransformMockPort(
    delay: Duration.zero,
  ),
  CreationCanvasHistoryPort? historyPort,
  ChatRepository? chatApi,
  List<Override> extraOverrides = const <Override>[],
}) async {
  tester.view.devicePixelRatio = 1;
  await tester.binding.setSurfaceSize(_surface);
  final repository = CreationCanvasDraftRepository(
    dao: CreationCanvasDraftDao(AppDatabase()),
    userScope: 'test-user',
  );
  if (draft != null) repository.upsert(draft);
  final router = GoRouter(
    initialLocation: '/canvas',
    routes: [
      GoRoute(
        path: '/canvas',
        builder: (_, _) =>
            const V3CreationCanvasPage(entryIntent: CanvasEntryIntent.blank()),
      ),
      GoRoute(
        path: '/v3/workbench/history',
        builder: (_, _) => const SizedBox(),
      ),
      GoRoute(path: '/v3', builder: (_, _) => const SizedBox()),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...mobileAgentReadyTestOverrides(),
        ...extraOverrides,
        resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
        creationCanvasDraftRepositoryProvider.overrideWithValue(repository),
        creationCanvasHistoryPortProvider.overrideWithValue(
          historyPort ?? InMemoryCreationCanvasHistoryPort(),
        ),
        knowledgeLibraryControllerProvider.overrideWith(
          (_) => KnowledgeLibraryController(
            initialNotes: const [],
            includeDemoFixtures: false,
          ),
        ),
        profileHubControllerProvider.overrideWith(
          (_) => ProfileHubController(),
        ),
        canvasAiTransformPortProvider.overrideWithValue(aiPort),
        if (chatApi != null) chatRepositoryProvider.overrideWithValue(chatApi),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: figmaGoldenTheme(),
        debugShowCheckedModeBanner: false,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return _CanvasHarness(tester, router);
}

final class _VisualKnowledgeNotePort implements KnowledgeNotePort {
  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => KnowledgeNotePortResult.success(
    V3FeedItem(
      id: request.noteId,
      title: request.draft.title,
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 8, 20),
      rawBody: request.draft.rawBody,
      localRevision: request.localRevision,
      remoteRevision: 1,
      remoteNoteId: 'remote-${request.noteId}',
      noteRevisionId: 'note-revision-1',
      rawPartRevisionId: 'raw-part-revision-1',
      etag: '"visual-note-1"',
      contentCursor: 'visual-note-cursor-1',
    ),
  );
}

Future<_CanvasHarness> _pumpHistory(
  WidgetTester tester, {
  required CreationCanvasHistoryPort port,
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  await tester.binding.setSurfaceSize(_surface);
  final router = GoRouter(
    initialLocation: '/history',
    routes: [
      GoRoute(
        path: '/history',
        builder: (_, _) => const V3CreationHistoryPage(),
      ),
      GoRoute(path: '/v3/workbench', builder: (_, _) => const SizedBox()),
      GoRoute(
        path: '/v3/workbench/canvas',
        builder: (_, _) => const SizedBox(),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
        creationCanvasHistoryPortProvider.overrideWithValue(port),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: figmaGoldenTheme(),
        debugShowCheckedModeBanner: false,
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return _CanvasHarness(tester, router);
}

Future<_CanvasHarness> _pumpRecommendation(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  await tester.binding.setSurfaceSize(_surface);
  final controller = DailyTopicController(
    port: const _VisualDailyTopicPort(),
    preferences: AppPreferencesDao(AppDatabase()),
    userScope: 'test-user',
    workspaceId: () => 'visual-workspace',
    workspaceReady: () => true,
    cacheTtl: () => const Duration(minutes: 5),
  );
  await controller.initialize();
  if (controller.state.recommendation?.recommendationId !=
      'visual-recommendation') {
    throw StateError(
      'visual recommendation initialize failed: ${controller.state.errorCode}',
    );
  }
  final router = GoRouter(
    initialLocation: '/recommendation',
    routes: [
      GoRoute(
        path: '/recommendation',
        builder: (_, _) => const V3WorkbenchRecommendationPage(
          recommendationId: 'visual-recommendation',
          initialTopicId: 'visual-topic',
        ),
      ),
      GoRoute(path: '/v3/workbench', builder: (_, _) => const SizedBox()),
      GoRoute(
        path: '/v3/workbench/canvas',
        builder: (_, _) => const SizedBox(),
      ),
      GoRoute(path: '/v3/feed/chat', builder: (_, _) => const SizedBox()),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...mobileAgentReadyTestOverrides(),
        resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
        dailyTopicControllerProvider.overrideWith((_) => controller),
        knowledgeLibraryControllerProvider.overrideWith(
          (_) => KnowledgeLibraryController(
            initialNotes: const [],
            includeDemoFixtures: false,
            notePort: _VisualKnowledgeNotePort(),
          ),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: figmaGoldenTheme(),
        debugShowCheckedModeBanner: false,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
  await precacheFigmaFixtureImages(tester);
  if (controller.state.recommendation?.recommendationId !=
      'visual-recommendation') {
    throw StateError(
      'visual recommendation open failed: ${controller.state.errorCode}',
    );
  }
  return _CanvasHarness(tester, router);
}

final class _CanvasHarness {
  const _CanvasHarness(this.tester, this.router);

  final WidgetTester tester;
  final GoRouter router;

  Future<void> dispose() async {
    router.dispose();
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  }
}

QuillController _bodyController(WidgetTester tester) => tester
    .widget<QuillEditor>(find.byKey(const ValueKey('canvas-body-field')))
    .controller;

Future<void> _tapToolbarTooltip(WidgetTester tester, String tooltip) async {
  final action = find.byTooltip(tooltip);
  if (action.hitTestable().evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      action,
      160,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.tap(action.hitTestable());
  await tester.pumpAndSettle();
}

Future<void> _tapCanvasPrimaryTool(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final control = find.byKey(ValueKey<String>(key));
  if (control.hitTestable().evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      control,
      220,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey<String>('canvas-primary-toolbar-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
  }
  await tester.tap(control.hitTestable());
  if (settle) await tester.pumpAndSettle();
}

Future<void> _expectCanvasGolden(WidgetTester tester, String name) =>
    expectLater(
      find.byType(V3CreationCanvasPage),
      matchesGoldenFile('goldens/$name'),
    );

Future<void> _showCanvasSelectionContext(WidgetTester tester) async {
  _bodyController(tester).updateSelection(
    const TextSelection(baseOffset: 22, extentOffset: 31),
    ChangeSource.local,
  );
  final editor = tester.widget<QuillEditor>(
    find.byKey(const ValueKey('canvas-body-field')),
  );
  final rawState = tester.state<QuillRawEditorState>(
    find.byType(QuillRawEditor),
  );
  editor.focusNode.requestFocus();
  await tester.pump();
  expect(rawState.showToolbar(), isTrue);
  await tester.pumpAndSettle();
  expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
  expect(find.text('AI 改写'), findsOneWidget);
}

Future<void> _tapCanvasAiAction(
  WidgetTester tester,
  String action, {
  bool settle = true,
}) async {
  final control = find.byKey(ValueKey<String>('canvas-ai-action-$action'));
  await tester.scrollUntilVisible(
    control,
    180,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey<String>('canvas-ai-action-list')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pump();
  await tester.tap(control);
  if (settle) await tester.pumpAndSettle();
}

Future<void> _openHistoryDeleteConfirmation(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('creation-history-history-4'));
  await tester.drag(row, const Offset(-500, 0));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('creation-history-delete-confirmation')),
    findsOneWidget,
  );
}

InMemoryCreationCanvasHistoryPort _visualHistoryPort() {
  final history = InMemoryCreationCanvasHistoryPort();
  final codec = CanvasDocumentCodec();
  for (var index = 0; index < 5; index++) {
    final body = const <String>[
      '围绕创始人、行业变化与公众关注，整理可继续扩写的观察与判断。',
      '从政策执行切口进入，追踪临时保护机制变化与真实流动路径。',
      '先明确 AI 应该读取什么、可以修改什么，以及何时需要用户确认。',
      '思维过程、信息来源和可验证依据，共同构成专业工具的可信感。',
      '像自己的表达来自稳定判断和语气，而不是简单叠加口头禅。',
    ][index];
    final document = codec.documentFromMarkdown(body);
    history.upsert(
      'test-user',
      CreationCanvasHistoryEntry(
        id: 'history-$index',
        noteId: 'note-$index',
        title: const <String>[
          'DeepSeek 创始人身份飙升 3850...',
          '捷克开始拒绝乌克兰难民临时保护',
          '别只问“用哪个 AI”',
          '专业工具为什么更容易被相信',
          '口语化不是“嘿兄弟”',
        ][index],
        markdown: body,
        documentJson: codec.encodeDocumentJson(document),
        documentFormatVersion: CreationCanvasDraft.currentDocumentFormatVersion,
        revision: 1,
        createdAt: DateTime.utc(2026, 8, 16 + index, 7, 50),
        updatedAt: DateTime.utc(2026, 8, 16 + index, 7, 50),
      ),
    );
  }
  return history;
}

final class _FailingHistoryPort implements CreationCanvasHistoryPort {
  const _FailingHistoryPort();

  @override
  bool delete(String userScope, String historyId) => false;

  @override
  CreationCanvasHistoryEntry? find(String userScope, String historyId) => null;

  @override
  List<CreationCanvasHistoryEntry> list(String userScope) =>
      throw StateError('visual history failure');

  @override
  Future<void> upsert(
    String userScope,
    CreationCanvasHistoryEntry entry,
  ) async {}
}

final class _VisualDailyTopicPort implements DailyTopicPort {
  const _VisualDailyTopicPort();

  @override
  Future<ApiResult<DailyTopicRecommendationPage>> list(
    String workspaceId,
  ) async => _visualSuccess(
    DailyTopicRecommendationPage(
      items: <DailyTopicRecommendation>[_visualRecommendation()],
    ),
  );

  @override
  Future<ApiResult<DailyTopicRecommendation>> get(
    String workspaceId,
    String recommendationId,
  ) async => _visualSuccess(_visualRecommendation());

  @override
  Future<ApiResult<DailyTopicRecommendation>> markRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _visualSuccess(_visualRecommendation(read: true));

  @override
  Future<ApiResult<DailyTopicRecommendation>> dismiss(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _visualSuccess(_visualRecommendation());

  @override
  Future<ApiResult<DailyTopicUseResult>> use(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) => throw StateError('visual fixture does not use daily topics');
}

DailyTopicRecommendation _visualRecommendation({bool read = false}) =>
    DailyTopicRecommendation.fromJson(<String, Object?>{
      'recommendationId': 'visual-recommendation',
      'workspaceId': 'visual-workspace',
      'businessDate': '2026-08-20',
      'recommendationKind': 'daily_topic_report',
      'status': 'ready',
      'title': '内容增长',
      'summaryMarkdown': '今日推送',
      'etag': '"visual-recommendation"',
      if (read) 'readAt': '2026-08-20T08:00:00Z',
      'topics': <Object?>[
        <String, Object?>{
          'topicId': 'visual-topic',
          'title': '捷克开始拒绝乌克兰难民临时保护：欧洲难民政策的裂缝从哪里开始',
          'briefMarkdown':
              '欧盟新规落地仅一周，已有数十名乌克兰男性在捷克申请临时保护被驳回，'
              '失去住房、工作权和补助后开始转往其他国家。'
              '\n\n从一个具体国家的政策执行切口进入，追踪临时保护机制如何从“人人可用”变成“有人被挡在门外”，'
              '以及被拒难民在失去保障后的实际流动路径。',
          'sourceRefs': <Object?>[
            <String, Object?>{
              'kind': 'daily_hotspot',
              'hotspotId': 'visual-hotspot',
              'label': '欧洲政策动态',
            },
          ],
        },
      ],
    });

ApiResult<T> _visualSuccess<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

final class _VisualCanvasChatApi extends Fake implements ChatRepository {
  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async => ApiResult<ChatThreadPage>.success(
    data: ChatThreadPage(
      items: <ChatThread>[
        ChatThread(
          threadId: 'm03-canvas-chat-history',
          scene: scene,
          title: '继续打磨政策观察稿',
          updatedAt: DateTime.utc(2026, 8, 20, 9, 30),
          agentProfileId: AgentFeatureRoutes.forFeature(
            'creation.free',
          )!.agentProfileId,
        ),
      ],
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final class _CanvasVisualRecorder implements VoiceRecorderPort {
  _CanvasVisualRecorder({this.permissionGranted = true});

  final bool permissionGranted;
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
    VoiceRecorderPermission(
      state: permissionGranted
          ? VoiceRecorderPermissionState.granted
          : VoiceRecorderPermissionState.denied,
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
      recordingId: 'm03-live-voice',
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

final class _CanvasVisualCredentialPort
    implements LiveTranscriptionCredentialPort {
  const _CanvasVisualCredentialPort();

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async => ApiResult<LiveAsrSessionCredential>.success(
    data: LiveAsrSessionCredential(
      sessionId: 'm03-live-session',
      appId: 123456789,
      projectId: 0,
      tmpSecretId: 'visual-secret-id',
      tmpSecretKey: 'visual-secret-key',
      token: 'visual-token',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final class _CanvasVisualAsrPort implements TencentLiveAsrPort {
  final StreamController<LiveTranscriptSentence> _events =
      StreamController<LiveTranscriptSentence>.broadcast(sync: true);

  @override
  Stream<LiveTranscriptSentence> get events => _events.stream;

  void emit(LiveTranscriptSentence sentence) => _events.add(sentence);

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
