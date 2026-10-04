import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/shared/navigation/foreground_ingress_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_ai_inline_review.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/navigation/app_routes.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/creation_canvas_draft_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/chat/application/chat_voice_uploader.dart';
import 'package:huahuoai_app/features/chat/application/voice_message_controller.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/data/chat_thread_alias_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_autosave_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/deep_positioning_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/script_draft_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/canvas_ai_transform_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_document_codec.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_draft_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_history_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/knowledge_library_cache.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_ai_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_image_embed_data.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_draft.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_history.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/script_draft_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_creation_canvas_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_creation_canvas_chrome.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_creation_history_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_chat_mark.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_brand_mark.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

import '../../support/mobile_agent_test_support.dart';

void main() {
  testWidgets('Continue draft awaits replacement Library cache', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'restore-owner-note',
      title: '绑定笔记',
      source: V3MaterialSource.note,
      rawBody: '已保存的正文。',
      createdAt: DateTime.utc(2026, 9, 16),
    );
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: note.title,
          markdown: '草稿中的未保存修改。',
          sessionId: 'restore-owner-session',
          entryIdentity: 'previous-entry',
          boundNoteId: note.id,
          boundAssetFingerprint: _canvasNoteFingerprintForTest(note),
          revision: 1,
          createdAt: note.createdAt,
          updatedAt: note.createdAt,
        ),
      );
    final first = KnowledgeLibraryController(
      initialNotes: [note],
      includeDemoFixtures: false,
    );
    final cache = _GatedCanvasKnowledgeCache([note]);
    final replacement = KnowledgeLibraryController(
      initialNotes: const [],
      cache: cache,
      includeDemoFixtures: false,
    );
    final replaced = StateProvider<bool>((ref) => false);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: first,
      libraryResolver: (ref) => ref.watch(replaced) ? replacement : first,
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();
    expect(find.text('继续上次创作'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(V3CreationCanvasPage)),
    );
    container.read(replaced.notifier).state = true;
    await tester.pump();
    await tester.tap(find.text('继续上次创作'));
    await tester.pumpAndSettle();
    expect(cache.loadStarted.isCompleted, isTrue);
    expect(find.text('创作内容加载失败'), findsNothing);
    cache.releaseLoad();
    await _pumpUntilCanvasReady(tester);
    expect(_bodyText(tester), '草稿中的未保存修改。');
    expect(repository.load()!.sessionId, 'restore-owner-session');
    expect(replacement.noteForId(note.id)!.rawBody, note.rawBody);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long Canvas Chat retains newest receipts without locking', (
    tester,
  ) async {
    final repository = _draftRepository();
    final api = _CanvasChatApi();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      chatApi: api,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '长对话期间正文必须保持原样。');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(V3CreationCanvasPage)),
    );
    for (var turn = 1; turn <= 26; turn += 1) {
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('canvas-chat-input')),
        '长对话第 $turn 轮，只给建议',
      );
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-send')));
      await tester.pumpAndSettle();
      final receipts = repository.load()!.chatRewriteReceipts;
      expect(
        receipts,
        hasLength(turn.clamp(0, CreationCanvasDraft.maxChatRewriteReceipts)),
      );
      expect(
        receipts.every((receipt) => receipt.assistantMessageId != null),
        isTrue,
      );
      expect(receipts.last.assistantMessageId, 'canvas-assistant-$turn');
      expect(
        container.read(creationCanvasChatControllerProvider).state.messages,
        hasLength(turn * 2),
      );
      expect(
        container
            .read(creationCanvasChatControllerProvider)
            .state
            .canSubmitUserTurn,
        isTrue,
      );
      expect(_bodyText(tester), '长对话期间正文必须保持原样。');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-close')));
      await tester.pumpAndSettle();
    }
    expect(api.createIdempotencies, hasLength(1));
    expect(
      api.messageIdempotencies.map((context) => context.explicitKey).toSet(),
      hasLength(26),
    );
    expect(
      repository.load()!.chatRewriteReceipts.first.assistantMessageId,
      'canvas-assistant-3',
    );
    expect(
      tester
          .widget<V3CanvasEditingModeSwitch>(
            find.byType(V3CanvasEditingModeSwitch),
          )
          .onChanged,
      isNotNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey<String>('canvas-save')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final sourceKind in V3MaterialSource.values) {
    final ownership = switch (sourceKind) {
      V3MaterialSource.subscription => V3NoteOwnership.subscribed,
      V3MaterialSource.knowledgeSquare => V3NoteOwnership.knowledgeSquare,
      V3MaterialSource.hotspot => V3NoteOwnership.hotspot,
      _ => V3NoteOwnership.mine,
    };
    final stages =
        ownership == V3NoteOwnership.subscribed ||
            ownership == V3NoteOwnership.knowledgeSquare
        ? [V3ContentStage.raw]
        : V3ContentStage.values;
    for (final stage in stages) {
      testWidgets(
        'entry chat matrix ${sourceKind.name}/${stage.name} five turns',
        (tester) async {
          final source = V3FeedItem(
            id: 'entry-${sourceKind.name}',
            title: '入口验证-${sourceKind.name}',
            source: sourceKind,
            ownership: ownership,
            createdAt: DateTime.utc(2026, 9, 16),
            rawBody: '原始资料保持不变。',
            summaryBody: '纲要资料保持不变。',
            sproutReport: V3SproutReport(
              id: 'sprout-entry',
              noteId: 'entry-${sourceKind.name}',
              title: '深度洞察',
              markdown: '洞察资料保持不变。',
              generatedAt: DateTime.utc(2026, 9, 16),
            ),
            remoteNoteId: stages.length == 1
                ? null
                : 'remote-${sourceKind.name}',
            rawPartRevisionId: stages.length == 1 ? null : 'raw-1',
            outlinePartRevisionId: stages.length == 1 ? null : 'outline-1',
            germinationPartRevisionId: stages.length == 1 ? null : 'sprout-1',
            articleId: stages.length == 1 ? 'article-${sourceKind.name}' : null,
            articleRevisionId: stages.length == 1 ? 'article-revision-1' : null,
          );
          final seed = AssetCanvasSeed.tryFromItem(item: source, stage: stage)!;
          final repository = _draftRepository();
          final api = _CanvasChatApi();
          final script = _SuccessfulScriptDraftPort(
            finalMarkdown: '生成正文第一段。\n\n第二段用于局部上下文验证。',
          );
          final library = KnowledgeLibraryController(
            initialNotes: [source],
            includeDemoFixtures: false,
            notePort: const _CanvasSynchronizingNotePort(),
          );
          final harness = await _pumpCanvas(
            tester,
            repository: repository,
            library: library,
            chatApi: api,
            scriptDraftPort: script,
            assetSeed: seed.withInitialSourceMode(
              AssetCanvasInitialSourceMode.generateTranscript,
            ),
          );
          addTearDown(harness.dispose);
          await _pumpUntilCanvasReady(tester);
          await tester.pumpAndSettle();
          expect(script.requests, hasLength(1));
          final generated = _bodyText(tester);
          for (var turn = 1; turn <= 5; turn += 1) {
            if (turn == 4) {
              await _setBody(tester, '$generated\n\n第四轮新增正文标记。');
            } else {
              _bodyEditor(tester).focusNode.requestFocus();
              _selectBody(
                tester,
                turn == 3
                    ? const TextSelection(baseOffset: 0, extentOffset: 8)
                    : const TextSelection.collapsed(offset: 0),
              );
              await tester.pump();
            }
            final before = _bodyText(tester);
            await tester.tap(
              find.byKey(const ValueKey<String>('canvas-chat-entry')),
            );
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const ValueKey<String>('canvas-chat-input')),
              '${sourceKind.name}/${stage.name} 第 $turn 轮',
            );
            await tester.tap(
              find.byKey(const ValueKey<String>('canvas-chat-send')),
            );
            await tester.pumpAndSettle();
            final receipts = repository.load()!.chatRewriteReceipts;
            expect(receipts, hasLength(turn));
            expect(
              receipts.every((receipt) => receipt.assistantMessageId != null),
              isTrue,
            );
            expect(receipts.last.selectionScoped, turn == 3);
            if (turn >= 4) {
              expect(receipts.last.sourceMarkdown, contains('第四轮新增正文标记'));
            }
            expect(_bodyText(tester), before);
            await tester.tap(
              find.byKey(const ValueKey<String>('canvas-chat-close')),
            );
            await tester.pumpAndSettle();
          }
          expect(api.createIdempotencies, hasLength(1));
          expect(api.sentContents, hasLength(5));
          expect(
            api.messageIdempotencies
                .map((context) => context.explicitKey)
                .toSet(),
            hasLength(5),
          );
          expect(
            repository
                .load()!
                .chatRewriteReceipts
                .map((receipt) => receipt.userMessageId)
                .toSet(),
            hasLength(5),
          );
          expect(library.noteForId(source.id)!.rawBody, source.rawBody);
          expect(library.noteForId(source.id)!.summaryBody, source.summaryBody);
          expect(
            library.noteForId(source.id)!.sproutReport!.markdown,
            source.sproutReport!.markdown,
          );
          final copyId = repository.load()!.boundNoteId;
          expect(copyId, isNot(source.id));
          await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认保存'));
          await tester.pumpAndSettle();
          expect(repository.load(), isNull);
          expect(library.notes, hasLength(2));
          expect(library.noteForId(copyId!)!.syncState, NoteSyncState.synced);
        },
      );
    }
  }

  for (final action in CanvasAiAction.values) {
    testWidgets('simulator matrix repeats ${action.name} in both scopes', (
      tester,
    ) async {
      final positioning = DeepPositioningController(
        const DeepPositioningMockRepository(delay: Duration.zero),
      );
      await positioning.saveConversation(const [
        DeepPositioningConversationEntry(
          text: '我帮助创作者把复杂产品讲清楚。',
          isAssistant: false,
        ),
      ]);
      final port = _AuditedCanvasAiPort();
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        positioning: positioning,
        aiPort: port,
      );
      addTearDown(harness.dispose);
      final variants = switch (action) {
        CanvasAiAction.socialRelationShift =>
          CanvasRelationTarget.values.map((value) => value.label).toList(),
        CanvasAiAction.openingOptimization =>
          CanvasOpeningVariant.values.map((value) => value.label).toList(),
        CanvasAiAction.imageBrief =>
          CanvasImageVariant.values.map((value) => value.label).toList(),
        _ => <String?>[null],
      };
      for (final scope in CanvasAiEditScope.values) {
        for (final variant in variants) {
          for (final apply in [true, false]) {
            await _setBody(tester, '前文保持原样。\n\n创作者把灵感记录成可验证的行动。\n\n后文保持原样。');
            final before = _bodyText(tester);
            if (scope == CanvasAiEditScope.local) {
              final start = before.indexOf('创作者');
              _selectBody(
                tester,
                TextSelection(
                  baseOffset: start,
                  extentOffset: start + '创作者把灵感记录成可验证的行动。'.length,
                ),
              );
              await tester.pump();
            }
            await _tapAiSkill(tester, action.name);
            if (variant != null) {
              await tester.ensureVisible(find.text(variant).last);
              await tester.tap(find.text(variant).last);
            }
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
              findsOneWidget,
              reason: '${action.name}/$variant/${scope.name}/apply=$apply',
            );
            expect(port.requests.last.editScope, scope);
            expect(_bodyText(tester), before);
            await tester.tap(
              find.byKey(
                ValueKey<String>(
                  apply ? 'canvas-ai-apply' : 'canvas-ai-reject',
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
              findsNothing,
            );
            expect(_bodyController(tester).readOnly, isFalse);
            expect(
              tester
                  .widget<V3CanvasEditingModeSwitch>(
                    find.byType(V3CanvasEditingModeSwitch),
                  )
                  .onChanged,
              isNotNull,
            );
            if (!apply) {
              expect(_bodyText(tester), before);
            } else {
              expect(_bodyText(tester), isNot(before));
              if (scope == CanvasAiEditScope.local) {
                expect(_bodyText(tester), startsWith('前文保持原样。'));
                expect(_bodyText(tester), contains('后文保持原样。'));
              }
            }
            await tester.tap(
              find.byKey(const ValueKey<String>('canvas-edit-mode')),
            );
            await tester.pumpAndSettle();
          }
        }
      }
      expect(
        port.requests.map((request) => request.requestId).toSet().length,
        port.requests.length,
      );
    });
  }

  testWidgets('simulator matrix repeats Chat reopen save and fresh entry', (
    tester,
  ) async {
    final repository = _draftRepository();
    final api = _CanvasChatApi();
    final ai = _AuditedCanvasAiPort();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      chatApi: api,
      aiPort: ai,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '用于多轮聊天的冻结正文。');
    for (var turn = 1; turn <= 3; turn += 1) {
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('canvas-chat-input')),
        '第 $turn 次讨论',
      );
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      final receipts = repository.load()!.chatRewriteReceipts;
      expect(receipts, hasLength(turn));
      expect(
        receipts.every((receipt) => receipt.assistantMessageId != null),
        isTrue,
      );
      expect(find.text('上一次消息尚未完成'), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-close')));
      await tester.pumpAndSettle();
    }
    expect(api.createIdempotencies, hasLength(1));
    expect(
      api.messageIdempotencies.map((request) => request.explicitKey).toSet(),
      hasLength(3),
    );
    await _setBody(tester, '聊天结束后重新编辑的新正文。');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-chat-rewrite-proposal')).first,
    );
    await tester.pumpAndSettle();
    expect(ai.requests, isEmpty);
    expect(_bodyText(tester), '聊天结束后重新编辑的新正文。');
    if (find
        .byKey(const ValueKey<String>('canvas-chat-close'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-close')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(repository.load(), isNull);
    harness.router.go('/canvas');
    await tester.pumpAndSettle();
    expect(_bodyText(tester), isEmpty);
    expect(find.text('上一次消息尚未完成'), findsNothing);
  });

  testWidgets('canonical chat readback settles the same accepted Run', (
    tester,
  ) async {
    const runId = 'agent_run_canvas_canonical';
    final api = _CanvasChatApi(agentRunId: runId);
    final tracker = _CanvasSseTracker(
      onTrack:
          ({
            required agentRunId,
            required threadId,
            required scene,
            required purpose,
          }) {},
    );
    final controller = ChatController(
      api: api,
      scene: ChatScene.workAi,
      runTracker: tracker,
    );
    final repository = _draftRepository();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      chatApi: api,
      chatController: controller,
    );
    addTearDown(harness.dispose);
    addTearDown(tracker.dispose);
    await _setBody(tester, '冻结的聊天正文');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '请讨论正文',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final pending = repository.load()!.chatRewriteReceipts.single;
    expect(pending.agentRunId, runId);
    expect(pending.assistantMessageId, isNull);
    api.detailMessages = [
      ChatMessage(
        messageId: 'message_canonical_user',
        threadId: 'canvas-thread-1',
        scene: ChatScene.workAi,
        role: ChatMessageRole.user,
        contentType: ChatMessageContentType.text,
        status: 'sent',
        textPreview: api.sentContents.single,
      ),
      const ChatMessage(
        messageId: 'message_canonical_assistant',
        threadId: 'canvas-thread-1',
        scene: ChatScene.workAi,
        role: ChatMessageRole.assistant,
        contentType: ChatMessageContentType.text,
        status: 'succeeded',
        agentRunId: runId,
        textPreview: '这是最终建议',
      ),
    ];
    await controller.selectThread('canvas-thread-1', forceRemote: true);
    await tester.pumpAndSettle();
    expect(controller.state.turnState.userMessageId, 'message_canonical_user');
    final receipts = repository.load()!.chatRewriteReceipts;
    expect(receipts, hasLength(1));
    expect(receipts.single.assistantMessageId, 'message_canonical_assistant');
    expect(receipts.single.userMessageId, 'message_canonical_user');
    expect(
      receipts.single.messageIdempotencyKey,
      pending.messageIdempotencyKey,
    );
    expect(find.text('上一次消息尚未完成'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '继续聊',
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey<String>('canvas-chat-send')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('saving explains mode lock without switching modes', (
    tester,
  ) async {
    final port = _RecordingCanvasSynchronizingNotePort()
      ..gate = Completer<void>();
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      notePort: port,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '等待云端确认');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await _pumpUntil(tester, () => port.requests.isNotEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    final before = tester.widget<V3CanvasEditingModeSwitch>(
      find.byType(V3CanvasEditingModeSwitch),
    );
    expect(before.onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
    await tester.pump();
    expect(find.text('正在保存，请稍候'), findsOneWidget);
    expect(
      tester
          .widget<V3CanvasEditingModeSwitch>(
            find.byType(V3CanvasEditingModeSwitch),
          )
          .value,
      before.value,
    );
    port.gate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('local write failure has an explicit distinct label', (
    tester,
  ) async {
    final repository = _FailingCanvasDraftUpsertStore(_draftRepository());
    final harness = await _pumpCanvas(tester, repository: repository);
    addTearDown(harness.dispose);
    expect(find.byTooltip('尚无本地草稿'), findsOneWidget);
    await _setBody(tester, '本地写入失败不能显示为未创建草稿');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    expect(find.byTooltip('本地保存失败'), findsOneWidget);
    expect(find.byTooltip('尚无本地草稿'), findsNothing);
  });

  testWidgets('save drains non-timer draft writes before cloud and cleanup', (
    tester,
  ) async {
    final repository = _GatedCanvasDraftStore(_draftRepository());
    final port = _RecordingCanvasSynchronizingNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      notePort: port,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '本次需要保存的新正文');
    repository.gateNextUpsert();
    final staleWrite = CanvasDraftPersistenceCoordinator(repository).persist(
      CreationCanvasDraft(
        title: '旧快照',
        markdown: '旧正文',
        revision: 0,
        createdAt: DateTime.utc(2026, 9, 16),
        updatedAt: DateTime.utc(2026, 9, 16),
      ),
    );
    await _pumpUntil(tester, () => repository.upsertStarted);
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(port.requests, isEmpty);
    expect(library.notes, isEmpty);
    repository.releaseUpsert();
    await staleWrite;
    await tester.pumpAndSettle();
    expect(port.requests, hasLength(1));
    expect(library.notes.single.rawBody, '本次需要保存的新正文');
    expect(repository.load(), isNull);
    expect(find.text('detail:${library.notes.single.id}'), findsOneWidget);
  });

  testWidgets(
    'long-running initial draft leaves without cancellation and resumes the same run',
    (tester) async {
      final repository = _draftRepository();
      final scriptPort = _SuccessfulScriptDraftPort(pending: true);
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        dailyTopicSeed: _dailyTopicCanvasSeed(),
        scriptDraftPort: scriptPort,
      );
      addTearDown(harness.dispose);
      for (
        var frame = 0;
        frame < 30 && find.text('先返回，稍后查看').evaluate().isEmpty;
        frame += 1
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('先返回，稍后查看'), findsOneWidget);
      final sessionId = repository.load()!.sessionId!;
      await tester.tap(find.text('先返回，稍后查看'));
      await tester.pumpAndSettle();
      expect(find.text('创作空间'), findsOneWidget);
      expect(scriptPort.cancelledWith, isEmpty);
      expect(repository.load()!.scriptDraftReceipt!.agentRunId, 'script-run-1');
      unawaited(harness.router.push('/canvas?recoverySessionId=$sessionId'));
      for (var frame = 0; frame < 12; frame += 1) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(scriptPort.requests, hasLength(1));
      expect(scriptPort.createKeys, hasLength(1));
      expect(find.text('先返回，稍后查看'), findsOneWidget);
      expect(scriptPort.cancelledWith, isEmpty);
    },
  );

  testWidgets('long-running stale recovery never creates a replacement draft', (
    tester,
  ) async {
    final repository = _draftRepository();
    final scriptPort = _SuccessfulScriptDraftPort();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      scriptDraftPort: scriptPort,
      location: '/canvas?recoverySessionId=missing',
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();
    expect(find.textContaining('草稿已移除或替换'), findsOneWidget);
    expect(scriptPort.createKeys, isEmpty);
    expect(repository.load(), isNull);
  });

  testWidgets('long-running recovery query changes validate the new target', (
    tester,
  ) async {
    final repository = _draftRepository();
    final scriptPort = _SuccessfulScriptDraftPort();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '尚未离开的原始草稿');
    harness.router.go(
      '/canvas?recoverySessionId=missing&recoveryRunId=other-run',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('草稿已移除或替换'), findsOneWidget);
    expect(repository.load()!.markdown, contains('尚未离开的原始草稿'));
    expect(scriptPort.createKeys, isEmpty);
  });

  for (final accept in [false, true]) {
    testWidgets(
      'inline review is immutable and ${accept ? 'accepts' : 'rejects'} the candidate',
      (tester) async {
        final repository = _draftRepository();
        final harness = await _pumpCanvas(
          tester,
          repository: repository,
          aiPort: const _ReplacementCanvasAiPort('new proposal'),
        );
        addTearDown(harness.dispose);
        final source =
            'old source\n${List.generate(30, (index) => '上下文第 $index 行，正文保持不变。').join('\n')}';
        await _setBody(
          tester,
          source,
          selection: const TextSelection(baseOffset: 0, extentOffset: 10),
        );
        final original = _bodyController(tester).document.toDelta().toJson();
        final originalMarkdown = CanvasDocumentCodec().documentToMarkdown(
          _bodyController(tester).document,
        );
        await _tapAiSkill(tester, 'needsDeepening');
        await tester.pumpAndSettle();
        final confirmation = find.byKey(
          const ValueKey<String>('canvas-ai-confirmation'),
        );
        final inline = find.byKey(
          const ValueKey<String>('canvas-ai-inline-editor'),
        );
        expect(confirmation, findsOneWidget);
        expect(ModalRoute.of(tester.element(confirmation)), isA<PageRoute>());
        expect(
          find.descendant(of: confirmation, matching: find.byType(QuillEditor)),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('canvas-ai-regenerate')),
          findsNothing,
        );
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey<String>('canvas-save')),
              )
              .onPressed,
          isNull,
        );
        final preview = tester.widget<QuillEditor>(inline);
        expect(preview.controller.readOnly, isTrue);
        expect(_bodyController(tester).document.toDelta().toJson(), original);
        final scroll = tester
            .widget<ListView>(
              find.byKey(const ValueKey<String>('canvas-editor-scroll')),
            )
            .controller!;
        final offset = scroll.offset;
        await tester.dragFrom(const Offset(300, 340), const Offset(0, -220));
        await tester.pumpAndSettle();
        expect(scroll.offset, greaterThan(offset));
        expect(confirmation.hitTestable(), findsOneWidget);
        final projectionBefore = preview.controller.document.toDelta().toJson();
        preview.controller.replaceText(
          0,
          0,
          '不能写入',
          const TextSelection.collapsed(offset: 4),
        );
        expect(
          preview.controller.document.toDelta().toJson(),
          projectionBefore,
        );
        expect(_bodyController(tester).document.toDelta().toJson(), original);
        expect(repository.load()?.markdown, originalMarkdown);
        final apply = find.byKey(const ValueKey<String>('canvas-ai-apply'));
        expect(
          tester.getRect(apply).bottom,
          lessThanOrEqualTo(tester.view.physicalSize.height),
        );
        await tester.tap(
          find.byKey(
            ValueKey<String>(accept ? 'canvas-ai-apply' : 'canvas-ai-reject'),
          ),
        );
        await tester.pumpAndSettle();
        expect(confirmation, findsNothing);
        expect(
          _bodyText(tester),
          accept ? source.replaceFirst('old source', 'new proposal') : source,
        );
        expect(
          _bodyController(tester).document.toDelta().toJson().toString(),
          isNot(contains('canvas-review')),
        );
        if (accept) {
          await tester.tap(find.byTooltip('撤销'));
          await tester.pumpAndSettle();
          expect(_bodyController(tester).document.toDelta().toJson(), original);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('back rejects an AI review before offering draft choices', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: const _ReplacementCanvasAiPort('new proposal'),
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '原文必须等用户明确接受才改变。');
    final original = _bodyController(tester).document.toDelta().toJson();
    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await _pumpUntil(
      tester,
      () => find.text('AI 建议尚未处理').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    final reject = find.text('放弃建议并继续');
    await tester.ensureVisible(reject);
    await tester.tap(reject);
    await _pumpUntil(tester, () => find.text('离开自由创作？').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
      findsNothing,
    );
    expect(_bodyController(tester).document.toDelta().toJson(), original);
    expect(_bodyController(tester).readOnly, isFalse);
  });

  testWidgets('review hardware copy exports only the immutable candidate', (
    tester,
  ) async {
    String? clipboardText = 'unchanged';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboardText = (call.arguments as Map)['text'] as String?;
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
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: const _ReplacementCanvasAiPort('new proposal'),
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      'old source stays outside',
      selection: const TextSelection(baseOffset: 0, extentOffset: 10),
    );
    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();

    final inline = find.byKey(
      const ValueKey<String>('canvas-ai-inline-editor'),
    );
    final preview = tester.widget<QuillEditor>(inline);
    preview.controller.updateSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: preview.controller.document.length - 1,
      ),
      ChangeSource.local,
    );
    preview.focusNode.requestFocus();
    await tester.pump();
    final reviewFocus = find.descendant(
      of: inline,
      matching: find.byWidgetPredicate(
        (widget) => widget is Focus && widget.focusNode == preview.focusNode,
      ),
    );
    expect(reviewFocus, findsOneWidget);
    final projection = preview.controller.document.toDelta().toJson();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(preview.controller.document.toDelta().toJson(), projection);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(clipboardText, 'unchanged');
    expect(preview.controller.document.toPlainText(), contains('old source'));

    Actions.invoke(tester.element(reviewFocus), CopySelectionTextIntent.copy);
    await tester.pump();
    expect(clipboardText, contains('new proposal'));
    expect(clipboardText, isNot(contains('old source')));
    expect(_bodyText(tester), 'old source stays outside');
  });

  testWidgets(
    'review exposes change semantics and explains deleted-only copy',
    (tester) async {
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
      final semantics = tester.ensureSemantics();
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        aiPort: const _ReplacementCanvasAiPort('new proposal'),
      );
      addTearDown(harness.dispose);
      await _setBody(tester, 'old source');
      await _tapAiSkill(tester, 'needsDeepening');
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('AI 改写建议已生成，请审核删除和新增内容。'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'删除：.*old source')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r'新增：.*new proposal')), findsWidgets);

      final inline = find.byKey(
        const ValueKey<String>('canvas-ai-inline-editor'),
      );
      final preview = tester.widget<QuillEditor>(inline);
      var projectionOffset = 0;
      TextSelection? deletedOnlySelection;
      for (final operation in preview.controller.document.toDelta().toList()) {
        final data = operation.data;
        final length = data is String ? data.length : 1;
        if (deletedOnlySelection == null &&
            data is String &&
            data.isNotEmpty &&
            CanvasAiInlineReview.changeFor(operation.attributes) ==
                CanvasReviewChange.deleted) {
          deletedOnlySelection = TextSelection(
            baseOffset: projectionOffset,
            extentOffset: projectionOffset + length,
          );
        }
        projectionOffset += length;
      }
      expect(deletedOnlySelection, isNotNull);
      preview.controller.updateSelection(
        deletedOnlySelection!,
        ChangeSource.local,
      );
      preview.focusNode.requestFocus();
      await tester.pump();
      final reviewFocus = find.descendant(
        of: inline,
        matching: find.byWidgetPredicate(
          (widget) => widget is Focus && widget.focusNode == preview.focusNode,
        ),
      );
      Actions.invoke(tester.element(reviewFocus), CopySelectionTextIntent.copy);
      await tester.pump();

      expect(clipboardText, 'unchanged');
      expect(find.text('所选内容接受后为空'), findsOneWidget);
      expect(_bodyText(tester), 'old source');
      semantics.dispose();
    },
  );

  testWidgets(
    'stale original invalidates inline review without overwriting edits',
    (tester) async {
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        aiPort: const _ReplacementCanvasAiPort('AI suggestion'),
      );
      addTearDown(harness.dispose);
      await _setBody(tester, 'original');
      await _tapAiSkill(tester, 'needsDeepening');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-confirmation')),
        findsOneWidget,
      );
      final original = _bodyController(tester);
      original.replaceText(
        0,
        'original'.length,
        'external edit',
        const TextSelection.collapsed(offset: 13),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-apply')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-inline-editor')),
        findsNothing,
      );
      expect(_bodyText(tester), 'external edit');
      expect(find.text('正文已发生变化，请重新选择后生成。'), findsNothing);
      expect(find.text('重新生成'), findsNothing);
      expect(find.text('关闭'), findsNothing);
      expect(original.readOnly, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recoverable network errors describe result retrieval rather than generation failure',
    (tester) async {
      final aiPort = _FailThenSucceedCanvasAiPort(
        const CanvasAiTransformException(
          'API_SERVER_UNAVAILABLE',
          recovery: CanvasAiFailureRecovery.retrySameRequest,
        ),
      );
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        aiPort: aiPort,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '网络恢复前保留的正文。');
      await _tapAiSkill(tester, 'needsDeepening');
      await tester.pumpAndSettle();
      expect(find.text('暂时无法获取生成结果，可重试同一次任务，正文未被修改。'), findsOneWidget);
      expect(find.text('暂时无法生成，正文未被修改。'), findsNothing);
      expect(find.text('重新生成'), findsNothing);
      final requestId = aiPort.requests.single.requestId;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(aiPort.requests.last.requestId, requestId);
      expect(_bodyText(tester), '网络恢复前保留的正文。');
    },
  );

  testWidgets(
    'pending skill keeps the document locked and resumes without a fresh request',
    (tester) async {
      final aiPort = _FailThenSucceedCanvasAiPort(
        const CanvasAiTransformException(
          'AGENT_RUN_POLL_TIMEOUT',
          recovery: CanvasAiFailureRecovery.retrySameRequest,
          isAwaitingCompletion: true,
          agentRunId: 'pending-run',
        ),
      );
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        aiPort: aiPort,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '一段等待改写的正文。');
      await _tapAiSkill(tester, 'needsDeepening');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-awaiting-completion')),
        findsOneWidget,
      );
      expect(find.text('重新生成'), findsNothing);
      expect(find.text('暂时无法生成，正文未被修改。'), findsNothing);
      expect(_bodyText(tester), '一段等待改写的正文。');
      expect(_bodyField(tester).readOnly, isTrue);
      final requestId = aiPort.requests.single.requestId;
      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-ai-continue-waiting')),
      );
      await tester.pumpAndSettle();
      expect(aiPort.requests, hasLength(2));
      expect(aiPort.requests.last.requestId, requestId);
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-apply')),
        findsOneWidget,
      );
      expect(_bodyText(tester), '一段等待改写的正文。');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), '已完成新的改写。');
    },
  );

  testWidgets(
    'pending skill cancellation closes the sheet and unlocks the original document',
    (tester) async {
      final aiPort = _FailThenSucceedCanvasAiPort(
        const CanvasAiTransformException(
          'AGENT_RUN_POLL_TIMEOUT',
          recovery: CanvasAiFailureRecovery.retrySameRequest,
          isAwaitingCompletion: true,
        ),
      );
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        aiPort: aiPort,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '不要改变这段正文。');
      await _tapAiSkill(tester, 'needsDeepening');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-ai-cancel-waiting')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-awaiting-completion')),
        findsNothing,
      );
      expect(_bodyField(tester).readOnly, isFalse);
      expect(_bodyText(tester), '不要改变这段正文。');
      expect(aiPort.requests, hasLength(1));
    },
  );

  testWidgets(
    'prepared frozen save resumes without consuming newer confirmation edits',
    (tester) async {
      final storage = _draftRepository();
      final repository = _GatedCanvasDraftStore(
        _FailAfterPreparedCanvasDraftStore(storage),
      );
      final port = _RecordingCanvasSynchronizingNotePort();
      final library = KnowledgeLibraryController(
        initialNotes: const [],
        notePort: port,
      );
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '准备提交的版本');
      repository.gateNextUpsert(
        phase: CreationCanvasHistoryCommitPhase.prepared,
      );
      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await _pumpUntil(tester, () => repository.upsertStarted);
      await _setBody(tester, '写前记录期间的新编辑');
      repository.releaseUpsert();
      await tester.pumpAndSettle();
      final receipt = storage.load()!.historyCommitReceipt!;
      expect(receipt.phase, CreationCanvasHistoryCommitPhase.prepared);
      expect(receipt.snapshot!.markdown, '准备提交的版本');
      expect(library.notes, isEmpty);
      expect(port.requests, isEmpty);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留状态并离开'));
      await tester.pumpAndSettle();
      harness.router.go('/canvas');
      await tester.pumpAndSettle();
      await _pumpUntilCanvasReady(tester);
      expect(_bodyText(tester), '写前记录期间的新编辑');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await _setBody(tester, '再次确认窗口到达的新编辑');
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(port.requests, isEmpty);
      expect(library.notes, isEmpty);
      expect(find.text('正文已变化，请重新确认保存'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(port.requests.single.noteId, receipt.noteId);
      expect(port.requests.single.draft.rawBody, '准备提交的版本');
      expect(storage.load()?.markdown, contains('再次确认窗口到达的新编辑'));
      expect(storage.load()?.historyCommitReceipt, isNull);
      expect(find.text('detail:${receipt.noteId}'), findsNothing);
    },
  );

  testWidgets(
    'note committed frozen save repairs history without saving the working tail',
    (tester) async {
      final history = _ControlledCanvasHistoryPort()
        ..upsertGate = Completer<void>()
        ..failUpserts = true;
      final port = _RecordingCanvasSynchronizingNotePort();
      final library = KnowledgeLibraryController(
        initialNotes: const [],
        notePort: port,
      );
      final repository = _draftRepository();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
        historyPort: history,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '历史待写入版本');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await _pumpUntil(tester, () => history.upsertCalls == 1);
      await _setBody(tester, '历史写入期间的新编辑');
      history.upsertGate!.complete();
      await tester.pumpAndSettle();
      expect(
        repository.load()?.historyCommitReceipt?.phase,
        CreationCanvasHistoryCommitPhase.noteCommitted,
      );
      expect(port.requests, isEmpty);
      history.failUpserts = false;
      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(port.requests.single.draft.rawBody, '历史待写入版本');
      expect(history.list('test-user').single.markdown, '历史待写入版本');
      expect(repository.load()?.markdown, contains('历史写入期间的新编辑'));
      expect(repository.load()?.historyCommitReceipt, isNull);
      expect(find.byType(V3CreationCanvasPage), findsOneWidget);
    },
  );

  testWidgets(
    'voice stop remains clickable while ordinary editing stays locked',
    (tester) async {
      final recorder = _CanvasLiveRecorder();
      final asr = _CanvasLiveAsrPort();
      final liveTranscript = LiveTranscriptController(
        credentialPort: const _CanvasLiveCredentialPort(),
        asrPort: asr,
      );
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        surfaceSize: const Size(800, 852),
        additionalOverrides: <Override>[
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
      final canvasRoute =
          ModalRoute.of(tester.element(find.byType(V3CreationCanvasPage)))!
              as PageRoute<dynamic>;
      expect(appRouteObserver.debugObservingRoute(canvasRoute), isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-voice-dictation')),
      );
      await tester.pump();
      await tester.pump();
      expect(recorder.startedScenes, <VoiceRecordingScene>[
        VoiceRecordingScene.monologue,
      ]);
      expect(liveTranscript.state.status, LiveTranscriptStatus.transcribing);

      await tester.pumpAndSettle();
      expect(_bodyController(tester).readOnly, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('canvas-title-field')),
            )
            .readOnly,
        isTrue,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey<String>('canvas-save')),
            )
            .onPressed,
        isNull,
      );
      final document = _bodyController(tester).document.toDelta().toJson();
      await _tapCanvasPrimaryTool(tester, 'canvas-ai-tools');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-scope-selector')),
        findsNothing,
      );
      expect(_bodyController(tester).document.toDelta().toJson(), document);
      await _tapCanvasPrimaryTool(tester, 'canvas-voice-dictation');
      await tester.pumpAndSettle();
      expect(recorder.cancelCalls, 1);
      expect(recorder.snapshot.state, VoiceRecorderState.idle);
      await tester.runAsync(() async {
        for (
          var attempt = 0;
          attempt < 20 &&
              liveTranscript.state.status != LiveTranscriptStatus.idle;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pumpAndSettle();
      expect(liveTranscript.state.status, LiveTranscriptStatus.idle);
      expect(_bodyController(tester).readOnly, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      liveTranscript.dispose();
      await asr.close();
    },
  );

  testWidgets(
    'voice partials replace the selected range as one undo transaction',
    (tester) async {
      final recorder = _CanvasLiveRecorder();
      final asr = _CanvasLiveAsrPort();
      final liveTranscript = LiveTranscriptController(
        credentialPort: const _CanvasLiveCredentialPort(),
        asrPort: asr,
      );
      addTearDown(() async {
        liveTranscript.dispose();
        await asr.close();
      });
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        surfaceSize: const Size(800, 852),
        additionalOverrides: <Override>[
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
      const selected = '旧词';
      const original = '前缀$selected后缀';
      final start = original.indexOf(selected);
      await _setBody(
        tester,
        original,
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + selected.length,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-voice-dictation')),
      );
      await tester.pump();
      await tester.pump();
      expect(liveTranscript.state.status, LiveTranscriptStatus.transcribing);

      for (final transcript in const <String>['新', '新的说法', '最终听写']) {
        asr.emit(
          LiveTranscriptSentence(
            sentenceId: 1,
            text: transcript,
            stable: transcript == '最终听写',
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(_bodyText(tester), '前缀$transcript后缀');
      }

      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-voice-dictation')),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (
          var attempt = 0;
          attempt < 20 &&
              liveTranscript.state.status != LiveTranscriptStatus.idle;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pumpAndSettle();
      expect(_bodyText(tester), '前缀最终听写后缀');

      await tester.tap(find.byKey(const ValueKey<String>('canvas-top-undo')));
      await tester.pump();
      expect(_bodyText(tester), original);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final reopen in [false, true]) {
    testWidgets('frozen save retries preserve late edits with reopen=$reopen', (
      tester,
    ) async {
      final port = _RecordingCanvasSynchronizingNotePort()
        ..gate = Completer<void>()
        ..failNext = true;
      final library = KnowledgeLibraryController(
        initialNotes: const [],
        notePort: port,
      );
      final repository = _draftRepository();
      final history = InMemoryCreationCanvasHistoryPort();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
        historyPort: history,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '确认版本');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await _pumpUntil(tester, () => port.requests.isNotEmpty);
      final noteId = library.notes.single.id;
      await _setBody(tester, '保存期间到达的新编辑');
      port.gate!.complete();
      await tester.pumpAndSettle();
      final frozen = repository.load()!.historyCommitReceipt!.snapshot!;
      expect(frozen.markdown, '确认版本');
      expect(repository.load()!.markdown, contains('保存期间到达的新编辑'));

      if (reopen) {
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保留状态并离开'));
        await tester.pumpAndSettle();
        harness.router.go('/canvas');
        await tester.pumpAndSettle();
        await _pumpUntilCanvasReady(tester);
        expect(_bodyText(tester), '保存期间到达的新编辑');
      }

      for (final failAgain in [true, false]) {
        port.failNext = failAgain;
        await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
        await tester.pumpAndSettle();
        expect(find.text('继续完成保存？'), findsOneWidget);
        await tester.tap(find.text('确认保存'));
        await tester.pumpAndSettle();
        expect(repository.load()?.markdown, contains('保存期间到达的新编辑'));
        expect(find.text('detail:$noteId'), findsNothing);
        if (failAgain) {
          expect(
            repository.load()?.historyCommitReceipt?.snapshot?.toJson(),
            frozen.toJson(),
          );
        }
      }

      expect(port.requests, hasLength(3));
      expect(
        port.requests.map((request) => request.draft.rawBody),
        everyElement('确认版本'),
      );
      expect(
        port.requests.map((request) => request.noteId),
        everyElement(noteId),
      );
      expect(library.notes, hasLength(1));
      expect(library.noteForId(noteId)?.rawBody, '确认版本');
      expect(history.list('test-user').single.markdown, '确认版本');
      expect(repository.load()?.historyCommitReceipt, isNull);
      expect(repository.load()?.boundNoteId, noteId);
      expect(_bodyController(tester).readOnly, isFalse);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      expect(find.text('保存当前修改？'), findsOneWidget);
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(port.requests.last.draft.rawBody, '保存期间到达的新编辑');
      expect(port.requests.last.localNote?.pendingRawOnlyUpdate, isTrue);
      expect(library.notes, hasLength(1));
      expect(history.list('test-user').single.markdown, '保存期间到达的新编辑');
      expect(find.text('detail:$noteId'), findsOneWidget);
      expect(repository.load(), isNull);
    });
  }

  testWidgets('formatted final paragraph chat diff preserves block structure', (
    tester,
  ) async {
    final chat = _CanvasChatApi(
      assistantText: canvasBuildWholePayloadUnifiedDiff(
        baseMarkdown: '# 原标题',
        replacementMarkdown: '## 新标题',
      ),
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: chat,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '原标题');
    _bodyController(tester).formatText(0, 3, Attribute.h1);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '改成二级标题',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(chat.sentContexts.single?.localDraftSnapshot?.content, '# 原标题');
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();
    expect(_bodyText(tester), '新标题');
    expect(_lineBreakAttributes(tester, 0)['header'], 2);
    _bodyController(tester).undo();
    await tester.pump();
    expect(_bodyText(tester), '原标题');
    expect(_lineBreakAttributes(tester, 0)['header'], 1);
  });

  testWidgets('AI replacement retains the final generated list marker', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _DiffCanvasAiPort((_) => '- 列表项目'),
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '普通正文');
    await _tapAiSkill(tester, 'expansion');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();
    expect(_bodyText(tester), '列表项目');
    expect(_lineBreakAttributes(tester, 0)['list'], 'bullet');
  });

  testWidgets('AI replacement leaves the unselected blank paragraph intact', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _DiffCanvasAiPort((_) => '新段落'),
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '第一段。\n\n第二段。',
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await _tapAiSkill(tester, 'expansion');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();
    expect(_bodyText(tester), '新段落\n\n第二段。');
  });

  testWidgets(
    'cloud save retains edits arriving after the confirmed snapshot',
    (tester) async {
      final port = _RecordingCanvasSynchronizingNotePort()
        ..gate = Completer<void>();
      final library = KnowledgeLibraryController(
        initialNotes: const [],
        notePort: port,
      );
      final repository = _draftRepository();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '确认保存的正文');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await _pumpUntil(tester, () => port.requests.isNotEmpty);
      final noteId = library.notes.single.id;
      await _setBody(tester, '等待云端期间的新修改');
      port.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('detail:$noteId'), findsNothing);
      expect(library.noteForId(noteId)?.rawBody, '确认保存的正文');
      expect(repository.load()?.markdown, contains('等待云端期间的新修改'));
      expect(repository.load()?.boundNoteId, noteId);
      expect(repository.load()?.historyCommitReceipt, isNull);
    },
  );

  testWidgets('save cleanup retains edits arriving while recovery is cleared', (
    tester,
  ) async {
    final repository = _GatedCanvasDraftStore(_draftRepository());
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      notePort: const _CanvasSynchronizingNotePort(),
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '已确认版本');
    repository.gateNextClear();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await _pumpUntil(tester, () => repository.clearStarted);
    await _setBody(tester, '清理期间到达的修改');
    repository.releaseClear();
    await tester.pumpAndSettle();
    expect(find.byType(V3CreationCanvasPage), findsOneWidget);
    expect(repository.load()?.markdown, contains('清理期间到达的修改'));
    expect(library.notes.single.rawBody, '已确认版本');
  });

  testWidgets(
    'save rechecks the target after waiting for history persistence',
    (tester) async {
      final history = _ControlledCanvasHistoryPort()
        ..upsertGate = Completer<void>();
      final port = _RecordingCanvasSynchronizingNotePort();
      final library = KnowledgeLibraryController(
        initialNotes: const [],
        notePort: port,
      );
      final repository = _draftRepository();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
        historyPort: history,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '用户确认的正文');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await _pumpUntil(tester, () => history.upsertCalls == 1);
      final saved = library.notes.single;
      library.updateManualNoteDraft(
        id: saved.id,
        draft: V3NoteDraft(
          title: '其他位置的新标题',
          rawBody: '其他位置的新正文',
          linkedMaterials: saved.linkedMaterials,
        ),
        scheduleAutomaticSync: false,
      );
      history.upsertGate!.complete();
      await tester.pumpAndSettle();
      expect(port.requests, isEmpty);
      expect(library.noteForId(saved.id)?.rawBody, '其他位置的新正文');
      expect(find.text('detail:${saved.id}'), findsNothing);
      expect(repository.load()?.historyCommitReceipt, isNotNull);
    },
  );

  testWidgets('cleanup retry requires the exact cloud raw revision', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'incomplete-cloud-binding',
      title: '已保存',
      rawBody: '待确认正文',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 7, 20),
      remoteNoteId: 'cloud-binding',
      syncState: NoteSyncState.synced,
    );
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: note.title,
          markdown: note.rawBody,
          boundNoteId: note.id,
          boundAssetFingerprint: _canvasNoteFingerprintForTest(note),
          entryIdentity: 'history:cleanup-entry',
          sessionId: 'cleanup-session',
          savedDraftCleanupPending: true,
          revision: 1,
          createdAt: note.createdAt,
          updatedAt: note.createdAt,
        ),
      );
    final library = KnowledgeLibraryController(initialNotes: [note]);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      location: '/canvas?historyId=cleanup-entry',
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成清理'));
    await tester.pumpAndSettle();
    expect(find.byType(V3CreationCanvasPage), findsOneWidget);
    expect(repository.load()?.savedDraftCleanupPending, isTrue);
    expect(find.text('detail:${note.id}'), findsNothing);
  });

  testWidgets('mode-less asset source starts transcript generation directly', (
    tester,
  ) async {
    final source = V3FeedItem(
      id: 'choice-source',
      title: '来源标题',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 8, 12),
      rawBody: '保持原始正文',
      summaryBody: '不要混入纲要',
    );
    final script = _SuccessfulScriptDraftPort(finalMarkdown: '生成后的可编辑逐字稿');
    final repository = _draftRepository();
    final library = KnowledgeLibraryController(initialNotes: [source]);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      location: '/canvas?importAssetId=${source.id}',
      scriptDraftPort: script,
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);
    expect(
      find.byKey(const ValueKey<String>('canvas-source-choice')),
      findsNothing,
    );
    expect(find.text('使用原文'), findsNothing);
    expect(_bodyText(tester), '生成后的可编辑逐字稿');
    expect(script.requests, hasLength(1));
    expect(repository.load()?.boundNoteId, isNull);
    expect(library.notes, hasLength(1));
  });

  testWidgets('daily source starts transcript generation directly', (
    tester,
  ) async {
    final script = _SuccessfulScriptDraftPort(finalMarkdown: '优化后的可编辑逐字稿');
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      dailyTopicSeed: _dailyTopicCanvasSeed(),
      scriptDraftPort: script,
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);
    expect(
      find.byKey(const ValueKey<String>('canvas-source-choice')),
      findsNothing,
    );
    expect(find.text('使用原文'), findsNothing);
    expect(script.requests, hasLength(1));
    expect(_bodyText(tester), '优化后的可编辑逐字稿');
  });

  testWidgets('existing Note source starts transcript generation directly', (
    tester,
  ) async {
    final source = V3FeedItem(
      id: 'existing-note-source',
      title: '已有笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 8, 12),
      rawBody: '已有笔记原文',
      remoteNoteId: 'remote-existing-note-source',
      rawPartRevisionId: 'raw-existing-note-source-1',
    );
    final script = _SuccessfulScriptDraftPort(finalMarkdown: '已有笔记生成稿');
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: KnowledgeLibraryController(initialNotes: [source]),
      location: '/canvas?initialNoteId=${source.id}',
      scriptDraftPort: script,
    );
    addTearDown(harness.dispose);

    await _pumpUntilCanvasReady(tester);
    expect(
      find.byKey(const ValueKey<String>('canvas-source-choice')),
      findsNothing,
    );
    expect(find.text('使用原文'), findsNothing);
    expect(script.requests, hasLength(1));
    expect(_bodyText(tester), '已有笔记生成稿');
  });

  for (final scenario
      in <({AssetCanvasInitialSourceMode mode, bool generates})>[
        (
          mode: AssetCanvasInitialSourceMode.generateTranscript,
          generates: true,
        ),
        (mode: AssetCanvasInitialSourceMode.useOriginal, generates: false),
      ]) {
    testWidgets(
      'preselected asset mode ${scenario.mode.name} bypasses source sheet',
      (tester) async {
        const sourceMarkdown = '# 来源正文\n\n保持冻结版本';
        final seed = AssetCanvasSeed(
          assetId: 'preselected-${scenario.mode.name}',
          title: '预选资料',
          stage: AssetCanvasSourceStage.raw,
          sourceMarkdown: sourceMarkdown,
          partRevisionId: 'raw-preselected-1',
          sourceHash: AssetCanvasSeed.hashSourceMarkdown(sourceMarkdown),
          linkedReference: V3LinkedMaterialRef(
            id: 'preselected-${scenario.mode.name}',
            source: V3MaterialSource.note,
            title: '预选资料',
          ),
          initialSourceMode: scenario.mode,
        );
        final script = _SuccessfulScriptDraftPort(finalMarkdown: '# 已生成逐字稿');
        final harness = await _pumpCanvas(
          tester,
          repository: _draftRepository(),
          assetSeed: seed,
          scriptDraftPort: script,
        );
        addTearDown(harness.dispose);

        await _pumpUntilCanvasReady(tester);
        expect(
          find.byKey(const ValueKey<String>('canvas-source-choice')),
          findsNothing,
        );
        expect(find.byType(BottomSheet), findsNothing);
        expect(script.requests, hasLength(scenario.generates ? 1 : 0));
        expect(
          _bodyText(tester),
          scenario.generates ? '已生成逐字稿' : '来源正文\n保持冻结版本',
        );
      },
    );
  }

  testWidgets('cloud confirmation gates navigation and retry keeps one note', (
    tester,
  ) async {
    final port = _RecordingCanvasSynchronizingNotePort()
      ..gate = Completer<void>()
      ..failNext = true;
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      notePort: port,
    );
    final repository = _draftRepository();
    final history = InMemoryCreationCanvasHistoryPort();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      historyPort: history,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '仅在确认上云后离开');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await _pumpUntil(tester, () => port.requests.length == 1);
    final noteId = library.notes.single.id;
    expect(find.text('detail:$noteId'), findsNothing);
    expect(repository.load()?.historyCommitReceipt, isNotNull);
    port.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('detail:$noteId'), findsNothing);
    expect(repository.load()?.historyCommitReceipt?.noteId, noteId);
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(library.notes, hasLength(1));
    expect(history.list('test-user'), hasLength(1));
    expect(port.requests.map((request) => request.noteId).toSet(), {noteId});
    expect(find.text('detail:$noteId'), findsOneWidget);
    expect(repository.load(), isNull);
  });

  testWidgets(
    'completed chat diff opens confirmation without another agent call',
    (tester) async {
      final port = _CapturingCanvasAiPort();
      final chat = _CanvasChatApi(
        assistantText: canvasBuildWholePayloadUnifiedDiff(
          baseMarkdown: '原来正文',
          replacementMarkdown: '建议正文',
        ),
      );
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        aiPort: port,
        chatApi: chat,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '原来正文');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('canvas-chat-input')),
        '请改写并给出差分',
      );
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
        findsOneWidget,
      );
      expect(port.requests, isEmpty);
      expect(_bodyText(tester), '原来正文');
      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), '建议正文');
    },
  );

  testWidgets('chat skill rewrites only the exact selection after acceptance', (
    tester,
  ) async {
    final port = _CapturingCanvasAiPort();
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: port,
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '第一段内容。\n第二段不变。',
      selection: const TextSelection(baseOffset: 1, extentOffset: 3),
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    final skill = find.byKey(
      const ValueKey<String>('canvas-chat-skill-expansion'),
    );
    await tester.scrollUntilVisible(
      skill,
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey<String>('canvas-chat-skills')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(skill);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(port.requests, hasLength(1));
    expect(port.requests.single.action, CanvasAiAction.expansion);
    expect(port.requests.single.editScope, CanvasAiEditScope.local);
    expect(port.requests.single.targetMarkdown.trim(), '一段');
    expect(_bodyText(tester), '第一段内容。\n第二段不变。');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();
    expect(_bodyText(tester), '第带入定位后的正文内容。\n第二段不变。');
  });

  testWidgets('Assistant reply seed opens as an unsaved editable draft', (
    tester,
  ) async {
    final library = KnowledgeLibraryController(initialNotes: const []);
    final repository = _draftRepository();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      assistantReplySeed: const AssistantReplyCanvasSeed(
        title: '从回复继续创作',
        markdown: '# 核心观点\n\n把这段回复继续整理成文章。',
      ),
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();

    final titleField = find.byKey(const ValueKey<String>('canvas-title-field'));
    expect(tester.widget<TextField>(titleField).controller!.text, '从回复继续创作');
    expect(_bodyText(tester), contains('把这段回复继续整理成文章。'));
    expect(library.notes, isEmpty);
    expect(repository.load()?.title, '从回复继续创作');
    expect(repository.load()?.entryIdentity, startsWith('assistant-reply:'));
    expect(find.bySemanticsLabel('草稿已存本机'), findsOneWidget);
  });

  testWidgets('restores and autosaves the current user canvas draft', (
    tester,
  ) async {
    final repository = _draftRepository();
    repository.upsert(
      CreationCanvasDraft(
        title: '恢复标题',
        markdown: '恢复正文',
        revision: 3,
        createdAt: DateTime.utc(2026, 7, 20, 8),
        updatedAt: DateTime.utc(2026, 7, 20, 9),
      ),
    );
    final harness = await _pumpCanvas(tester, repository: repository);
    addTearDown(harness.dispose);

    expect(find.text('恢复标题'), findsOneWidget);
    expect(_bodyText(tester), '恢复正文');

    await _setBody(tester, '恢复正文\nAPI key 与 /Users/demo/note.md 示例');
    await tester.pump(const Duration(milliseconds: 810));

    final restoredDocument = CanvasDocumentCodec().documentFromDeltaJson(
      repository.load()!.documentJson!,
    );
    expect(
      restoredDocument.toPlainText(),
      '恢复正文\nAPI key 与 /Users/demo/note.md 示例\n',
    );
    expect(repository.load()!.revision, greaterThan(3));
    expect(
      repository.load()!.documentFormatVersion,
      CanvasDocumentCodec.documentFormatVersion,
    );
    expect(repository.load()!.documentJson, isNotNull);
  });

  testWidgets('Agent entry auto-creates and then updates one new cloud note', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'aggregation-note',
      title: '聚合草稿',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 28),
      rawBody: '# 原始聚合\n\n正文内容',
      summaryBody: '不应加载这段摘要',
      remoteNoteId: 'remote-aggregation-note',
      rawPartRevisionId: 'raw-aggregation-note-1',
    );
    final library = KnowledgeLibraryController(
      initialNotes: [note],
      notePort: const _CanvasSynchronizingNotePort(),
    );
    final scriptPort = _SuccessfulScriptDraftPort(
      finalMarkdown: '# 聚合逐字稿\n\n根据原始聚合生成的正文',
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      assetSeed: AssetCanvasSeed.tryFromItem(
        item: note,
        stage: V3ContentStage.raw,
      )!.withInitialSourceMode(AssetCanvasInitialSourceMode.generateTranscript),
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('canvas-title-field')),
          )
          .controller
          ?.text,
      '聚合草稿',
    );
    expect(_bodyText(tester), contains('聚合逐字稿'));
    expect(_bodyText(tester), isNot(contains('不应加载这段摘要')));
    expect(scriptPort.requests.single.source.content, contains('原始聚合'));
    await _pumpUntil(tester, () => library.notes.length == 2);
    await tester.pumpAndSettle();
    expect(find.text('保存为新笔记？'), findsNothing);
    expect(find.text('已保存'), findsOneWidget);
    expect(library.noteForId('aggregation-note')?.rawBody, note.rawBody);
    final created = library.notes.singleWhere((item) => item.id != note.id);
    expect(created.rawBody, '# 聚合逐字稿\n\n根据原始聚合生成的正文');
    expect(created.remoteNoteId, isNotEmpty);

    await _setBody(tester, '更新后的聚合正文');
    expect(find.text('修改未保存'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(library.notes, hasLength(2));
    expect(library.noteForId('aggregation-note')?.rawBody, note.rawBody);
    expect(library.noteForId(created.id)?.rawBody, '更新后的聚合正文');
    expect(find.text('detail:${created.id}'), findsOneWidget);
  });

  testWidgets('Agent auto-save retry completes the same new note', (
    tester,
  ) async {
    final source = V3FeedItem(
      id: 'agent-retry-source',
      title: '自动首存重试来源',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 15),
      rawBody: '用于生成的来源正文',
      remoteNoteId: 'remote-agent-retry-source',
      rawPartRevisionId: 'raw-agent-retry-source-1',
    );
    final notePort = _RecordingCanvasSynchronizingNotePort()
      ..gate = Completer<void>()
      ..failNext = true;
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[source],
      notePort: notePort,
      includeDemoFixtures: false,
    );
    final repository = _draftRepository();
    final seed = AssetCanvasSeed.tryFromItem(
      item: source,
      stage: V3ContentStage.raw,
    )!.withInitialSourceMode(AssetCanvasInitialSourceMode.generateTranscript);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      assetSeed: seed,
      scriptDraftPort: _SuccessfulScriptDraftPort(
        finalMarkdown: '自动生成后等待云端确认的正文',
      ),
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);
    await _pumpUntil(tester, () => notePort.requests.length == 1);

    expect(library.notes, hasLength(2));
    final createdId = library.notes
        .singleWhere((note) => note.id != source.id)
        .id;
    expect(find.text('保存为新笔记？'), findsNothing);
    expect(find.text('detail:$createdId'), findsNothing);

    notePort.gate!.complete();
    await tester.pumpAndSettle();
    expect(repository.load()?.historyCommitReceipt?.noteId, createdId);
    expect(find.text('detail:$createdId'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();

    expect(find.text('继续完成保存？'), findsNothing);
    expect(library.notes, hasLength(2));
    expect(notePort.requests.map((request) => request.noteId).toSet(), {
      createdId,
    });
    expect(find.text('已保存'), findsOneWidget);
    expect(find.text('detail:$createdId'), findsNothing);
    expect(repository.load(), isNull);
  });

  testWidgets(
    'restored Agent initial cleanup stays on the canvas after restart',
    (tester) async {
      final savedAt = DateTime.utc(2026, 9, 15, 9);
      final savedNote = V3FeedItem(
        id: 'agent-cleanup-note',
        title: 'Agent 已创建笔记',
        source: V3MaterialSource.note,
        createdAt: savedAt,
        rawBody: '云端已经确认的 Agent 正文',
        remoteNoteId: 'remote-agent-cleanup-note',
        rawPartRevisionId: 'raw-agent-cleanup-note-1',
      );
      final source = ScriptDraftSourceSnapshot(
        kind: ScriptDraftSourceKind.asset,
        sourceId: 'agent-cleanup-source',
        title: 'Agent 来源笔记',
        content: '用于生成新笔记的来源正文',
        assetPart: ScriptDraftAssetPart.raw,
        partRevisionId: 'raw-agent-cleanup-source-1',
        capturedAt: savedAt.subtract(const Duration(minutes: 2)),
      );
      const canvasSessionId = 'canvas-session-agent-cleanup';
      final repository = _draftRepository()
        ..upsert(
          CreationCanvasDraft(
            title: savedNote.title,
            markdown: savedNote.rawBody,
            sessionId: canvasSessionId,
            entryIdentity: 'agent-note:${source.identity}',
            scriptDraftReceipt: ScriptDraftGenerationReceipt(
              sessionId: 'script-session-agent-cleanup',
              source: source,
              createThreadIdempotencyKey: 'agent-cleanup-thread-key',
              messageIdempotencyKey: 'agent-cleanup-message-key',
              cancelIdempotencyKey: 'agent-cleanup-cancel-key',
              phase: ScriptDraftGenerationPhase.ready,
              threadId: 'agent-cleanup-thread',
              agentRunId: 'agent-cleanup-run',
              finalMarkdown: savedNote.rawBody,
              updatedAt: savedAt,
            ),
            boundNoteId: savedNote.id,
            boundAssetFingerprint: _canvasNoteFingerprintForTest(savedNote),
            savedDraftCleanupPending: true,
            revision: 3,
            createdAt: savedAt.subtract(const Duration(minutes: 1)),
            updatedAt: savedAt,
          ),
        );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[savedNote],
        notePort: const _CanvasSynchronizingNotePort(),
        includeDemoFixtures: false,
      );
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
        location: '/canvas?recoverySessionId=$canvasSessionId',
      );
      addTearDown(harness.dispose);
      await _pumpUntilCanvasReady(tester);

      expect(find.text('完成清理'), findsOneWidget);
      await tester.tap(find.text('完成清理'));
      await tester.pumpAndSettle();

      expect(find.byType(V3CreationCanvasPage), findsOneWidget);
      expect(find.text('detail:${savedNote.id}'), findsNothing);
      expect(find.text('已保存'), findsOneWidget);
      expect(library.notes, hasLength(1));
      expect(library.notes.single.id, savedNote.id);
      expect(repository.load(), isNull);
    },
  );

  testWidgets('the same source starts a second independent Agent note', (
    tester,
  ) async {
    final source = V3FeedItem(
      id: 'agent-repeat-source',
      title: '重复创作来源',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 15),
      rawBody: '同一个来源可以发起多次独立创作',
      remoteNoteId: 'remote-agent-repeat-source',
      rawPartRevisionId: 'raw-agent-repeat-source-1',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[source],
      notePort: const _CanvasSynchronizingNotePort(),
      includeDemoFixtures: false,
    );
    final seed = AssetCanvasSeed.tryFromItem(
      item: source,
      stage: V3ContentStage.raw,
    )!.withInitialSourceMode(AssetCanvasInitialSourceMode.generateTranscript);
    final scriptPort = _SuccessfulScriptDraftPort(finalMarkdown: '同源生成的独立正文');
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      assetSeed: seed,
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);
    await _pumpUntil(tester, () => library.notes.length == 2);
    final firstCreatedId = library.notes
        .singleWhere((note) => note.id != source.id)
        .id;

    unawaited(harness.router.push<void>('/canvas'));
    await tester.pump();
    await _pumpUntilAsync(tester, () => scriptPort.requests.length == 2);
    await _pumpUntilAsync(tester, () => library.notes.length == 3);
    await tester.pumpAndSettle();

    final createdIds = library.notes
        .where((note) => note.id != source.id)
        .map((note) => note.id)
        .toSet();
    expect(createdIds, hasLength(2));
    expect(createdIds, contains(firstCreatedId));
    expect(scriptPort.requests, hasLength(2));
    expect(library.noteForId(source.id)?.rawBody, source.rawBody);
    expect(find.text('已有未完成创作'), findsNothing);
  });

  testWidgets('a new Agent click replaces a same-source unfinished run', (
    tester,
  ) async {
    final source = V3FeedItem(
      id: 'agent-same-source-restart',
      title: '同源重新发起',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 15),
      rawBody: '冻结的同一份来源正文',
      remoteNoteId: 'remote-agent-same-source-restart',
      rawPartRevisionId: 'raw-agent-same-source-restart-1',
    );
    final seed = AssetCanvasSeed.tryFromItem(
      item: source,
      stage: V3ContentStage.raw,
    )!.withInitialSourceMode(AssetCanvasInitialSourceMode.generateTranscript);
    final sourceSnapshot = ScriptDraftSourceSnapshot(
      kind: ScriptDraftSourceKind.asset,
      sourceId: seed.assetId,
      title: seed.title,
      content: seed.sourceMarkdown,
      assetPart: ScriptDraftAssetPart.raw,
      partRevisionId: seed.partRevisionId,
      contentHash: seed.sourceHash,
      capturedAt: DateTime.utc(2026, 9, 15, 8),
    );
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: source.title,
          markdown: '上一次同源创作尚未完成',
          sessionId: 'canvas-session-old-same-source',
          entryIdentity: 'agent-note:${sourceSnapshot.identity}',
          scriptDraftReceipt: ScriptDraftGenerationReceipt(
            sessionId: 'script-session-old-same-source',
            source: sourceSnapshot,
            createThreadIdempotencyKey: 'old-create-thread-key',
            messageIdempotencyKey: 'old-message-key',
            cancelIdempotencyKey: 'old-cancel-key',
            phase: ScriptDraftGenerationPhase.streaming,
            threadId: 'old-thread-id',
            agentRunId: 'old-agent-run-id',
            partialMarkdown: '旧任务的流式结果',
            updatedAt: DateTime.utc(2026, 9, 15, 8, 1),
          ),
          revision: 2,
          createdAt: DateTime.utc(2026, 9, 15, 8),
          updatedAt: DateTime.utc(2026, 9, 15, 8, 1),
        ),
      );
    final scriptPort = _SuccessfulScriptDraftPort(finalMarkdown: '本次点击生成的新正文');
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[source],
      notePort: const _CanvasSynchronizingNotePort(),
      includeDemoFixtures: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      assetSeed: seed,
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);

    await _pumpUntilCanvasReady(tester);
    await _pumpUntilAsync(tester, () => library.notes.length == 2);

    expect(find.text('已有未完成创作'), findsNothing);
    expect(_bodyText(tester), '本次点击生成的新正文');
    expect(scriptPort.requests, hasLength(1));
    expect(scriptPort.cancelledWith, <(String, String)>[
      ('old-agent-run-id', 'old-cancel-key'),
    ]);
    expect(library.noteForId(source.id)?.rawBody, source.rawBody);
  });

  testWidgets(
    'Agent entry replaces an unrelated draft without a conflict sheet',
    (tester) async {
      final repository = _draftRepository()
        ..upsert(
          CreationCanvasDraft(
            title: '上一份草稿',
            markdown: '与新入口无关的内容',
            sessionId: 'canvas-session-previous-draft',
            entryIdentity: const CanvasEntryIntent.blank().stableSourceId,
            revision: 3,
            createdAt: DateTime.utc(2026, 9, 14, 8),
            updatedAt: DateTime.utc(2026, 9, 14, 9),
          ),
        );
      final source = V3FeedItem(
        id: 'agent-new-source',
        title: '新的来源',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 9, 15, 8),
        rawBody: '新的来源正文',
        remoteNoteId: 'remote-agent-new-source',
        rawPartRevisionId: 'raw-agent-new-source-1',
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[source],
        notePort: const _CanvasSynchronizingNotePort(),
        includeDemoFixtures: false,
      );
      final seed = AssetCanvasSeed.tryFromItem(
        item: source,
        stage: V3ContentStage.raw,
      )!.withInitialSourceMode(AssetCanvasInitialSourceMode.generateTranscript);
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
        assetSeed: seed,
        scriptDraftPort: _SuccessfulScriptDraftPort(
          finalMarkdown: '新的 Agent 初稿',
        ),
      );
      addTearDown(harness.dispose);

      await _pumpUntilCanvasReady(tester);
      await _pumpUntil(tester, () => library.notes.length == 2);
      await tester.pumpAndSettle();

      expect(find.text('已有未完成创作'), findsNothing);
      expect(find.text('继续上次创作'), findsNothing);
      expect(_bodyText(tester), '新的 Agent 初稿');
      expect(
        library.notes.singleWhere((note) => note.id != source.id).rawBody,
        '新的 Agent 初稿',
      );
    },
  );

  testWidgets('same-path note ingress uses the dirty draft conflict flow', (
    tester,
  ) async {
    final first = V3FeedItem(
      id: 'same-route-note-a',
      title: '入口 A',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 5, 8),
      rawBody: '入口 A 正文',
    );
    final second = V3FeedItem(
      id: 'same-route-note-b',
      title: '入口 B',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 5, 9),
      rawBody: '入口 B 正文',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[first, second],
      includeDemoFixtures: false,
    );
    final repository = _draftRepository();
    final scriptPort = _SuccessfulScriptDraftPort(finalMarkdown: '入口生成后的逐字稿');
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      location: '/canvas?initialNoteId=${first.id}',
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);
    await _setBody(tester, '入口 A 尚未保存的修改');

    harness.router.go('/canvas?initialNoteId=${second.id}');
    await _pumpUntil(tester, () => find.text('已有未完成创作').evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    expect(find.byType(V3CreationCanvasPage), findsOneWidget);
    expect(find.text('已有未完成创作'), findsOneWidget);
    expect(repository.load()?.markdown, contains('入口 A 尚未保存的修改'));

    final discardCurrent = find.text('放弃并打开当前入口');
    await tester.ensureVisible(discardCurrent);
    await tester.tap(discardCurrent);
    await _pumpUntilCanvasReady(tester);

    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('canvas-title-field')),
          )
          .controller
          ?.text,
      '入口 B',
    );
    expect(_bodyText(tester), '入口生成后的逐字稿');
    expect(find.byType(V3CreationCanvasPage), findsOneWidget);
  });

  testWidgets('asset import creates an independent canvas with its outline', (
    tester,
  ) async {
    final scriptPort = _SuccessfulScriptDraftPort(
      finalMarkdown: '# 新逐字稿\n\n根据资产阶段生成的可编辑正文。',
    );
    final note = V3FeedItem(
      id: 'asset-note',
      title: '资产标题',
      source: V3MaterialSource.documentImport,
      createdAt: DateTime(2026, 8, 11),
      rawBody: '# 原始内容\n\n真实资料',
      summaryBody: '- 纲要要点',
      rawPartRevisionId: 'asset-note-raw-r1',
    );
    final library = KnowledgeLibraryController(initialNotes: [note]);
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      location: '/canvas?importAssetId=asset-note',
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    final titleField = find.byKey(const ValueKey<String>('canvas-title-field'));
    expect(titleField, findsOneWidget);
    expect(tester.widget<TextField>(titleField).controller!.text, '资产标题');
    expect(_bodyText(tester), contains('根据资产阶段生成的可编辑正文'));
    expect(_bodyText(tester), isNot(contains('真实资料')));
    expect(scriptPort.requests.single.source.content, contains('真实资料'));
    expect(
      scriptPort.requests.single.source.partRevisionId,
      'asset-note-raw-r1',
    );
    expect(
      scriptPort.requests.single.source.contentHash,
      AssetCanvasSeed.hashSourceMarkdown('# 原始内容\n\n真实资料'),
    );
    await _setBody(tester, '新的自由创作');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(library.noteForId('asset-note')?.rawBody, '# 原始内容\n\n真实资料');
    expect(library.notes, hasLength(2));
  });

  testWidgets('existing draft must explicitly yield to aggregation note', (
    tester,
  ) async {
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: '未完成草稿',
          markdown: '保留内容',
          revision: 1,
          createdAt: DateTime.utc(2026, 7, 28),
          updatedAt: DateTime.utc(2026, 7, 28),
        ),
      );
    final library = KnowledgeLibraryController(
      initialNotes: [
        V3FeedItem(
          id: 'aggregation-note',
          title: '聚合草稿',
          source: V3MaterialSource.note,
          createdAt: DateTime(2026, 7, 28),
          rawBody: '聚合正文',
        ),
      ],
    );
    final scriptPort = _SuccessfulScriptDraftPort(finalMarkdown: '聚合生成后的逐字稿');
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      location: '/canvas?initialNoteId=aggregation-note',
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-body-field')),
      findsNothing,
    );
    expect(find.text('放弃并打开当前入口'), findsOneWidget);
    await tester.tap(find.text('放弃并打开当前入口'));
    await _pumpUntilCanvasReady(tester);
    expect(_bodyText(tester), '聚合生成后的逐字稿');
  });

  testWidgets('entry conflict clear locks Back until replacement activates', (
    tester,
  ) async {
    final delegate = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: '旧草稿',
          markdown: '不能被并发离开绕过的正文',
          entryIdentity: 'blank',
          revision: 1,
          createdAt: DateTime.utc(2026, 9, 5, 8),
          updatedAt: DateTime.utc(2026, 9, 5, 8),
        ),
      );
    final repository = _BlockingCanvasDraftClearStore(delegate);
    addTearDown(repository.finishClear);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      assistantReplySeed: const AssistantReplyCanvasSeed(
        title: '替换入口',
        markdown: '清理完成后才能打开的新正文',
      ),
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();

    expect(find.text('已有未完成创作'), findsOneWidget);
    await tester.tap(find.text('放弃并打开当前入口'));
    await tester.pumpAndSettle();
    await repository.cleared;
    await tester.pump();

    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    expect(find.text('离开自由创作？'), findsNothing);
    expect(find.text('正在确认草稿状态，请稍候'), findsOneWidget);
    expect(find.byType(V3CreationCanvasPage), findsOneWidget);

    repository.finishClear();
    await tester.pumpAndSettle();

    expect(find.byType(V3CreationCanvasPage), findsOneWidget);
    expect(_bodyText(tester), '清理完成后才能打开的新正文');
  });

  testWidgets(
    'unreadable structured-only draft is preserved until body replacement',
    (tester) async {
      final database = AppDatabase();
      final dao = CreationCanvasDraftDao(database);
      final repository = CreationCanvasDraftRepository(
        dao: dao,
        userScope: 'test-user',
      );
      dao.upsert(
        userScope: 'test-user',
        title: '待恢复草稿',
        markdown: '',
        documentJson: '{broken-json',
        documentFormatVersion: CreationCanvasDraft.currentDocumentFormatVersion,
        linkedMaterialsJson: null,
        sourceTopicId: null,
        sourceTitle: null,
        revision: 4,
        createdAt: DateTime.utc(2026, 7, 20, 8).toIso8601String(),
        updatedAt: DateTime.utc(2026, 7, 20, 9).toIso8601String(),
      );
      final harness = await _pumpCanvas(tester, repository: repository);
      addTearDown(harness.dispose);

      await tester.pump(const Duration(milliseconds: 810));
      expect(dao.load('test-user')!['document_json'], '{broken-json');
      expect(repository.load()!.unreadableStructuredDocument, isTrue);

      await _setBody(tester, '用户确认重新开始的正文');
      await tester.pump(const Duration(milliseconds: 810));

      final replaced = repository.load()!;
      expect(replaced.unreadableStructuredDocument, isFalse);
      expect(replaced.markdown, contains('用户确认重新开始的正文'));
      expect(replaced.documentJson, isNotNull);
      expect(
        CanvasDocumentCodec()
            .documentFromDeltaJson(replaced.documentJson!)
            .toPlainText(),
        '用户确认重新开始的正文\n',
      );
    },
  );

  testWidgets('explicit save retains a real source note and clears the draft', (
    tester,
  ) async {
    final repository = _draftRepository();
    final scriptPort = _SuccessfulScriptDraftPort();
    final sourceTopic = V3FeedItem(
      id: 'topic-1',
      title: '今日测试选题',
      source: V3MaterialSource.meeting,
      createdAt: DateTime(2026, 7, 20, 8),
      rawBody: '选题背景',
      summaryBody: '不应提交给逐字稿 Agent 的摘要',
      rawPartRevisionId: 'topic-1-raw-r1',
    );
    final library = KnowledgeLibraryController(
      initialNotes: [sourceTopic],
      notePort: const _CanvasSynchronizingNotePort(),
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      scriptDraftPort: scriptPort,
      location:
          '/canvas?topicId=topic-1&topicTitle=${Uri.encodeComponent('今日测试选题')}',
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    expect(scriptPort.requests.single.source.content, '选题背景');
    expect(scriptPort.requests.single.source.partRevisionId, 'topic-1-raw-r1');
    expect(
      scriptPort.requests.single.source.contentHash,
      AssetCanvasSeed.hashSourceMarkdown('选题背景'),
    );

    await _setBody(tester, '这是从选题开始写下的正文。');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('detail:manual-'), findsOneWidget);
    final saved = library.notes.singleWhere(
      (note) => note.source == V3MaterialSource.note,
    );
    expect(library.notes, hasLength(2));
    expect(saved.title, '今日测试选题');
    expect(saved.linkedMaterials.single.id, 'topic-1');
    expect(saved.linkedMaterials.single.source, V3MaterialSource.meeting);
    expect(repository.load(), isNull);
  });

  testWidgets(
    'daily topic seed adopts only the authoritative generated draft',
    (tester) async {
      final chatApi = _CanvasChatApi();
      final scriptPort = _SuccessfulScriptDraftPort(
        finalMarkdown: '每日推荐生成后的完整逐字稿。',
      );
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        chatApi: chatApi,
        dailyTopicSeed: _dailyTopicCanvasSeed(),
        scriptDraftPort: scriptPort,
      );
      addTearDown(harness.dispose);
      await _pumpUntilCanvasReady(tester);

      final titleField = find.byKey(
        const ValueKey<String>('canvas-title-field'),
      );
      expect(tester.widget<TextField>(titleField).controller!.text, '公开每日选题');
      expect(_bodyText(tester), '每日推荐生成后的完整逐字稿。');
      expect(_bodyText(tester), isNot(contains('流式预览')));
      expect(
        scriptPort.requests.single.source.content,
        contains('从公开每日推荐进入详情。'),
      );
      expect(chatApi.sentContents, isEmpty);
    },
  );

  testWidgets(
    'failed initial draft Return blocks Retry until draft clear settles',
    (tester) async {
      final delegate = _draftRepository();
      final repository = _BlockingCanvasDraftClearStore(delegate);
      addTearDown(repository.finishClear);
      final scriptPort = _SuccessfulScriptDraftPort(finalMarkdown: '');
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        dailyTopicSeed: _dailyTopicCanvasSeed(),
        scriptDraftPort: scriptPort,
      );
      addTearDown(harness.dispose);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await _pumpUntil(tester, () => find.text('初稿生成失败').evaluate().isNotEmpty);
      expect(scriptPort.createKeys, hasLength(1));
      expect(
        find.byKey(const ValueKey<String>('canvas-initial-draft-use-original')),
        findsNothing,
      );
      expect(find.text('不生成逐字稿，使用原始内容'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-initial-draft-return')),
      );
      await repository.cleared;
      await tester.pump();

      final retry = find.byKey(
        const ValueKey<String>('canvas-initial-draft-retry'),
      );
      expect(tester.widget<FilledButton>(retry).onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey<String>('canvas-initial-draft-return')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(retry);
      await tester.pump();
      expect(scriptPort.createKeys, hasLength(1));
      expect(find.byType(V3CreationCanvasPage), findsOneWidget);

      repository.finishClear();
      await tester.pumpAndSettle();

      expect(find.byType(V3CreationCanvasPage), findsNothing);
      expect(find.text('创作空间'), findsOneWidget);
    },
  );

  testWidgets('daily topic seed directly replaces an existing draft', (
    tester,
  ) async {
    final restoredSource = ScriptDraftSourceSnapshot(
      kind: ScriptDraftSourceKind.dailyRecommendation,
      sourceId: 'previous-topic',
      title: '未完成草稿',
      content: '上一次推荐的冻结来源。',
      partRevisionId: 'previous-recommendation-1',
      capturedAt: DateTime.utc(2026, 8, 19, 8),
    );
    final restoredReceipt = ScriptDraftGenerationReceipt(
      sessionId: 'previous-script-session',
      source: restoredSource,
      createThreadIdempotencyKey: 'previous-create-key',
      messageIdempotencyKey: 'previous-message-key',
      cancelIdempotencyKey: 'previous-cancel-key',
      phase: ScriptDraftGenerationPhase.streaming,
      threadId: 'previous-thread',
      agentRunId: 'previous-run',
      partialMarkdown: '未完成预览',
      updatedAt: DateTime.utc(2026, 8, 19, 8),
    );
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: '未完成草稿',
          markdown: '保留内容',
          entryIdentity: restoredSource.identity,
          scriptDraftReceipt: restoredReceipt,
          revision: 1,
          createdAt: DateTime.utc(2026, 8, 19, 8),
          updatedAt: DateTime.utc(2026, 8, 19, 8),
        ),
      );
    final scriptPort = _SuccessfulScriptDraftPort(
      finalMarkdown: '当前每日推荐生成的新逐字稿。',
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      dailyTopicSeed: _dailyTopicCanvasSeed(),
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-body-field')),
      findsNothing,
    );
    expect(find.text('继续上次创作'), findsOneWidget);
    await tester.tap(find.text('放弃并打开当前入口'));
    await _pumpUntilCanvasReady(tester);
    final titleField = find.byKey(const ValueKey<String>('canvas-title-field'));
    expect(tester.widget<TextField>(titleField).controller!.text, '公开每日选题');
    expect(_bodyText(tester), '当前每日推荐生成的新逐字稿。');
    expect(scriptPort.cancelledWith, <(String, String)>[
      ('previous-run', 'previous-cancel-key'),
    ]);
  });

  testWidgets('selected AI result applies as one undo transaction', (
    tester,
  ) async {
    final repository = _draftRepository();
    final harness = await _pumpCanvas(tester, repository: repository);
    addTearDown(harness.dispose);

    await _setBody(tester, '第一段观点\n\n第二段观点');
    final bodyField = _bodyField(tester);
    bodyField.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 5,
    );

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<QuillEditor>(
            find.byKey(const ValueKey<String>('canvas-ai-inline-editor')),
          )
          .controller
          .document
          .toPlainText(),
      contains('表层需求'),
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();
    expect(bodyField.controller!.text, contains('需求深化'));
    expect(bodyField.controller!.text, contains('第二段观点'));

    await tester.tap(find.byTooltip('撤销'));
    await tester.pump();
    expect(bodyField.controller!.text, '第一段观点\n\n第二段观点');
  });

  testWidgets(
    'global remote diff previews deletion and insertion before apply',
    (tester) async {
      const replacementMarkdown =
          '今天我想分享一个真实使用场景。\n\n它先描述用户在下班路上记录灵感的困难，再给出今天可执行的一步。';
      const expectedBody = '今天我想分享一个真实使用场景。\n它先描述用户在下班路上记录灵感的困难，再给出今天可执行的一步。';
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        aiPort: _DiffCanvasAiPort((_) => replacementMarkdown),
      );
      addTearDown(harness.dispose);
      const source = '今天我想分享一个产品想法。\n\n它解决用户的困扰。';
      await _setBody(tester, source);

      await _tapAiSkill(tester, 'expansion');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
        findsOneWidget,
      );
      expect(find.text('删除内容'), findsOneWidget);
      expect(find.text('新增内容'), findsOneWidget);
      _expectCanvasDiffStyles(
        tester,
        deletedFragment: '产品想法',
        insertedFragment: '真实使用场景',
      );
      expect(_bodyText(tester), source);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), expectedBody);
    },
  );

  testWidgets('local remote diff previews and preserves surrounding content', (
    tester,
  ) async {
    const selected = '中间旧句。';
    const source = '开头保留。$selected结尾保留。';
    final start = source.indexOf(selected);
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _DiffCanvasAiPort((_) => '中间新句，并补充一个今天可以验证的行动。'),
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      source,
      selection: TextSelection(
        baseOffset: start,
        extentOffset: start + selected.length,
      ),
    );

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
      findsOneWidget,
    );
    _expectCanvasDiffStyles(
      tester,
      deletedFragment: '旧',
      insertedFragment: '新',
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();

    expect(_bodyText(tester), '开头保留。中间新句，并补充一个今天可以验证的行动。结尾保留。');
    expect(_bodyText(tester), isNot(contains(selected)));
  });

  testWidgets('terminal transform failure offers a fresh generation only', (
    tester,
  ) async {
    final aiPort = _FailThenSucceedCanvasAiPort(
      const CanvasAiTransformException('AGENT_RUN_FAILED'),
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: aiPort,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '一段等待改写的正文。');

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsNothing);
    expect(find.text('重新生成'), findsOneWidget);
    final firstRequestId = aiPort.requests.single.requestId;
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();

    expect(aiPort.requests, hasLength(2));
    expect(aiPort.requests.last.requestId, isNot(firstRequestId));
  });

  testWidgets('transient transform failure retries the same operation only', (
    tester,
  ) async {
    final aiPort = _FailThenSucceedCanvasAiPort(
      const CanvasAiTransformException(
        'CANVAS_AI_DIFF_FILE_UNAVAILABLE',
        recovery: CanvasAiFailureRecovery.retrySameRequest,
      ),
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: aiPort,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '一段等待重试的正文。');

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('重新生成'), findsNothing);
    final firstRequestId = aiPort.requests.single.requestId;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(aiPort.requests, hasLength(2));
    expect(aiPort.requests.last.requestId, firstRequestId);
  });

  testWidgets('rejected AI image Markdown unlocks and preserves the document', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: const _ReplacementCanvasAiPort(
        '![公网图片](https://example.com/not-private.png)',
      ),
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '不可被替换的正文',
      selection: const TextSelection(baseOffset: 0, extentOffset: 8),
    );

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();

    expect(_bodyText(tester), '不可被替换的正文');
    expect(_bodyController(tester).readOnly, isFalse);
    expect(find.byKey(const ValueKey<String>('canvas-ai-apply')), findsNothing);
    expect(find.text('建议暂时无法显示，原文已保留'), findsOneWidget);
  });

  testWidgets('title keeps focus and AI tools dismiss the editor focus', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    final titleFinder = find.byKey(
      const ValueKey<String>('canvas-title-field'),
    );
    final bodyFinder = find.byKey(
      const ValueKey<String>('canvas-body-field'),
      skipOffstage: false,
    );

    await tester.tap(titleFinder);
    await tester.pump();
    final titleField = tester.widget<TextField>(titleFinder);
    final bodyField = _bodyField(tester);
    expect(titleField.focusNode!.hasFocus, isTrue);
    expect(bodyField.focusNode!.hasFocus, isFalse);

    await tester.tap(bodyFinder);
    await tester.pump();
    bodyField.controller!.value = const TextEditingValue(
      text: '保留这段选中文字',
      selection: TextSelection(baseOffset: 0, extentOffset: 4),
    );
    expect(bodyField.focusNode!.hasFocus, isTrue);

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pump();
    expect(bodyField.focusNode!.hasFocus, isFalse);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<QuillEditor>(
            find.byKey(const ValueKey<String>('canvas-ai-inline-editor')),
          )
          .controller
          .document
          .toPlainText(),
      contains('表层需求'),
    );
    expect(
      bodyField.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 4),
    );
  });

  testWidgets('canvas keeps one direct editing surface with top undo', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    final controller = _bodyController(tester);
    controller.replaceText(
      0,
      0,
      '直接编辑内容',
      const TextSelection.collapsed(offset: 6),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('canvas-body-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-markdown-preview')),
      findsNothing,
    );
    final titleField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('canvas-title-field')),
    );
    final bodyField = _bodyEditor(tester);
    expect(titleField.decoration?.hintText, '标题');
    expect(titleField.style?.fontSize, 17);
    expect(bodyField.config.placeholder, '开始写点什么...');
    expect(
      find.byKey(const ValueKey<String>('canvas-edit-mode-tag')),
      findsNothing,
    );
    expect(find.text('普通编辑'), findsNothing);
    expect(find.byType(V3BrandMark), findsNothing);
    final backRect = tester.getRect(find.byTooltip('返回'));
    final undoRect = tester.getRect(
      find.byKey(const ValueKey<String>('canvas-top-undo')),
    );
    expect(undoRect.left - backRect.right, closeTo(6, .1));

    await tester.tap(find.byKey(const ValueKey<String>('canvas-top-undo')));
    await tester.pump();
    expect(_bodyText(tester), isEmpty);
  });

  testWidgets('top undo follows the last active title editor', (tester) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    final title = find.byKey(const ValueKey<String>('canvas-title-field'));
    await tester.tap(title);
    await tester.enterText(title, '第一版标题');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(title, '第二版标题');
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byKey(const ValueKey<String>('canvas-top-undo')));
    await tester.pump();

    expect(tester.widget<TextField>(title).controller!.text, '第一版标题');
    expect(_bodyText(tester), isEmpty);
  });

  testWidgets('title undo history cannot cross a new canvas session', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    var title = find.byKey(const ValueKey<String>('canvas-title-field'));
    await tester.tap(title);
    await tester.enterText(title, '旧草稿标题');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(title, '旧草稿标题第二版');
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byKey(const ValueKey<String>('canvas-more-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃当前内容并新建'));
    await tester.pumpAndSettle();

    title = find.byKey(const ValueKey<String>('canvas-title-field'));
    expect(tester.widget<TextField>(title).controller!.text, isEmpty);
    await tester.tap(title);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(tester.widget<TextField>(title).controller!.text, isEmpty);
  });

  testWidgets(
    'bottom toolbar owns AI tools and reuses the homepage chat entry',
    (tester) async {
      final harness = await _pumpCanvas(tester, repository: _draftRepository());
      addTearDown(harness.dispose);

      final toolbar = find.byKey(
        const ValueKey<String>('canvas-markdown-toolbar'),
      );
      final toolbarRect = tester.getRect(toolbar);
      final canvasWidth = tester.getSize(find.byType(Scaffold).first).width;
      expect(toolbarRect.left, 0);
      expect(toolbarRect.right, canvasWidth);
      final toolbarDecoration =
          tester.widget<DecoratedBox>(toolbar).decoration as BoxDecoration;
      expect(toolbarDecoration.borderRadius, isNull);
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('canvas-keyboard-toggle')),
            )
            .right,
        toolbarRect.right,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-skill-strip')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-chat-entry')),
        findsOneWidget,
      );
      final chatEntrySize = tester.getSize(
        find.byKey(const ValueKey<String>('canvas-chat-entry')),
      );
      expect(chatEntrySize.width, greaterThanOrEqualTo(44));
      expect(chatEntrySize.height, greaterThanOrEqualTo(44));
      expect(
        find.descendant(
          of: toolbar,
          matching: find.byKey(const ValueKey<String>('canvas-chat-entry')),
        ),
        findsNothing,
      );
      final chatMark = tester.widget<V3ChatMark>(find.byType(V3ChatMark));
      expect(chatMark.size, 36);

      await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
      await tester.pumpAndSettle();
      expect(find.byTooltip('下划线'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('canvas-primary-toolbar-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-keyboard-toggle')),
        findsOneWidget,
      );
    },
  );

  testWidgets('iOS keyboard keeps the Markdown toolbar fully visible', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: const Size(393, 852),
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    addTearDown(harness.dispose);

    final body = find.byKey(const ValueKey<String>('canvas-body-field'));
    await tester.tap(body);
    await tester.pumpAndSettle();

    final toolbar = find.byKey(
      const ValueKey<String>('canvas-markdown-toolbar'),
    );
    expect(toolbar, findsOneWidget);
    final toolbarBottom = tester.getRect(toolbar).bottom;
    expect(toolbarBottom, lessThanOrEqualTo(852 - 300 + 0.5));
    expect((852 - 300) - toolbarBottom, lessThanOrEqualTo(6));
    expect(
      find.byKey(const ValueKey<String>('canvas-primary-toolbar-scroll')),
      findsOneWidget,
    );
    final editorScroll = tester.widget<ListView>(
      find.byKey(const ValueKey<String>('canvas-editor-scroll')),
    );
    expect(
      (editorScroll.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(432),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard reveals a long-document caret by the nearest edge', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: const Size(393, 852),
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    addTearDown(harness.dispose);
    final lines = List<String>.generate(
      34,
      (index) => '第 ${index + 1} 行用于验证长文中的光标定位和键盘跟随。',
    );
    final text = lines.join('\n');
    final caret = text.indexOf('第 19 行') + 5;
    await _setBody(
      tester,
      text,
      selection: TextSelection.collapsed(offset: caret),
    );
    _bodyEditor(tester).focusNode.requestFocus();
    await tester.pumpAndSettle();

    final renderEditor = tester.renderObject<RenderEditor>(
      find.byElementPredicate(
        (element) => element.renderObject is RenderEditor,
      ),
    );
    final caretRect = renderEditor.getLocalRectForCaret(
      TextPosition(offset: caret),
    );
    final caretTop = renderEditor.localToGlobal(caretRect.topLeft).dy;
    final caretBottom = renderEditor.localToGlobal(caretRect.bottomLeft).dy;
    final media = MediaQuery.of(
      tester.element(find.byKey(const ValueKey<String>('canvas-body-field'))),
    );
    final visibleTop = media.padding.top + 72;
    final visibleBottom = media.size.height - media.viewInsets.bottom - 64 - 12;
    expect(caretTop, greaterThanOrEqualTo(visibleTop - 2));
    expect(caretBottom, lessThanOrEqualTo(visibleBottom + 2));
  });

  testWidgets('dragging a non-collapsed selection does not recenter canvas', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: const Size(393, 852),
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    addTearDown(harness.dispose);
    final text = List<String>.generate(
      34,
      (index) => '第 ${index + 1} 行用于验证选区手柄拖动。',
    ).join('\n');
    await _setBody(
      tester,
      text,
      selection: const TextSelection(baseOffset: 12, extentOffset: 24),
    );
    _bodyEditor(tester).focusNode.requestFocus();
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<ListView>(
          find.byKey(const ValueKey<String>('canvas-editor-scroll')),
        )
        .controller!;
    final before = scroll.offset;

    _selectBody(tester, const TextSelection(baseOffset: 40, extentOffset: 18));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(scroll.offset, closeTo(before, .1));
  });

  testWidgets('selection-handle delegate reveals a far edge through canvas', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: const Size(393, 852),
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    addTearDown(harness.dispose);
    final text = List<String>.generate(
      48,
      (index) => '第 ${index + 1} 行用于验证选区手柄靠近边缘时平稳推动正文滚动。',
    ).join('\n');
    await _setBody(
      tester,
      text,
      selection: const TextSelection(baseOffset: 0, extentOffset: 8),
    );
    final editor = _bodyEditor(tester);
    editor.focusNode.requestFocus();
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<ListView>(
          find.byKey(const ValueKey<String>('canvas-editor-scroll')),
        )
        .controller!;
    scroll.jumpTo(0);
    await tester.pump();
    final before = scroll.offset;
    final extent = text.length - 2;
    final selection = TextSelection(baseOffset: 0, extentOffset: extent);
    final editorState = editor.config.editorKey!.currentState!;

    editorState.userUpdateTextEditingValue(
      editor.controller.plainTextEditingValue.copyWith(selection: selection),
      SelectionChangedCause.drag,
    );
    editorState.bringIntoView(TextPosition(offset: extent));
    await tester.pump();

    expect(editor.controller.selection, selection);
    expect(scroll.offset, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('upward scroll preserves focus for a range selection', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: const Size(393, 852),
      viewInsets: const EdgeInsets.only(bottom: 300),
      wrapKeyboardDismiss: true,
    );
    addTearDown(harness.dispose);
    final text = List<String>.generate(
      40,
      (index) => '第 ${index + 1} 行用于验证长选区滚动时保留选择手柄。',
    ).join('\n');
    const selection = TextSelection(baseOffset: 0, extentOffset: 12);
    await _setBody(tester, text, selection: selection);
    final editor = _bodyEditor(tester);
    editor.focusNode.requestFocus();
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey<String>('canvas-editor-scroll')),
      const Offset(0, -220),
    );
    await tester.pump();

    expect(editor.focusNode.hasFocus, isTrue);
    expect(_bodyController(tester).selection, selection);

    final collapsed = TextSelection.collapsed(
      offset: _bodyController(tester).selection.extentOffset,
    );
    _selectBody(tester, collapsed);
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey<String>('canvas-editor-scroll')),
      const Offset(0, -80),
    );
    await tester.pump();
    expect(editor.focusNode.hasFocus, isFalse);
  });

  testWidgets(
    '320px canvas keeps every bottom tool reachable without overflow',
    (tester) async {
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        surfaceSize: const Size(320, 700),
      );
      addTearDown(harness.dispose);

      final toolbar = find.byKey(
        const ValueKey<String>('canvas-markdown-toolbar'),
      );
      final primaryScroll = find.byKey(
        const ValueKey<String>('canvas-primary-toolbar-scroll'),
      );
      expect(toolbar, findsOneWidget);
      expect(primaryScroll, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-tools')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-import-notes')),
        findsOneWidget,
      );
      expect(find.text('尚未存储').hitTestable(), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('canvas-import-notes')),
        220,
        scrollable: find.descendant(
          of: primaryScroll,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-import-notes')).hitTestable(),
        findsOneWidget,
      );

      await _setBody(
        tester,
        '窄屏 AI 工具仍然可达。',
        selection: const TextSelection(baseOffset: 0, extentOffset: 2),
      );
      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
      await tester.pumpAndSettle();
      expect(find.text('全文').hitTestable(), findsOneWidget);
      expect(find.text('选区').hitTestable(), findsOneWidget);
      final aiList = find.descendant(
        of: find.byKey(const ValueKey<String>('canvas-ai-action-list')),
        matching: find.byType(Scrollable),
      );
      final lastAction = find.byKey(
        const ValueKey<String>('canvas-ai-action-atomization'),
      );
      await tester.scrollUntilVisible(lastAction, 260, scrollable: aiList);
      await tester.pumpAndSettle();
      expect(lastAction.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mode switch moves title focus back to the body editor', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    final titleFinder = find.byKey(
      const ValueKey<String>('canvas-title-field'),
    );
    await _setBody(tester, '正文必须保持原样');
    final bodyField = _bodyField(tester);

    await tester.tap(titleFinder);
    await tester.pump();
    expect(tester.widget<TextField>(titleFinder).focusNode!.hasFocus, isTrue);

    final boldButton = find.ancestor(
      of: find.byTooltip('加粗'),
      matching: find.byType(IconButton),
    );
    final textStyleButton = find.descendant(
      of: find.byKey(const ValueKey<String>('canvas-text-style')),
      matching: find.byType(IconButton),
    );
    final modeSwitch = find.byType(V3CanvasEditingModeSwitch);
    expect(tester.widget<IconButton>(boldButton).onPressed, isNull);
    expect(tester.widget<IconButton>(textStyleButton).onPressed, isNull);
    expect(
      tester.widget<V3CanvasEditingModeSwitch>(modeSwitch).onChanged,
      isNotNull,
    );
    expect(bodyField.controller!.text, '正文必须保持原样');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(titleFinder).focusNode!.hasFocus, isFalse);
    expect(_bodyEditor(tester).focusNode.hasFocus, isTrue);
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-action-list')),
      findsOneWidget,
    );
  });

  testWidgets('heading format applies to a line and reverses to paragraph', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(tester, '第一行\n第二行');
    final bodyField = _bodyField(tester);
    bodyField.controller!.selection = const TextSelection.collapsed(offset: 1);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-block-style')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('一级标题'));
    await tester.pump();
    expect(bodyField.controller!.text, '第一行\n第二行');
    expect(_lineBreakAttributes(tester, 0)['header'], 1);

    await tester.tap(find.byTooltip('正文'));
    await tester.pump();
    expect(bodyField.controller!.text, '第一行\n第二行');
    expect(_lineBreakAttributes(tester, 0), isNot(contains('header')));
  });

  testWidgets('divider toolbar action renders a supported Quill embed', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(tester, '分隔线前');
    _selectBody(tester, const TextSelection.collapsed(offset: 4));

    await tester.tap(find.byKey(const ValueKey<String>('canvas-block-style')));
    await tester.pumpAndSettle();
    final dividerAction = find.byTooltip('分隔线');
    await tester.scrollUntilVisible(
      dividerAction,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(dividerAction);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-divider-embed')),
      findsOneWidget,
    );
    expect(
      _bodyController(tester).document.toDelta().operations.any(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(
              CanvasDocumentCodec.canvasDividerEmbedType,
            ),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-top-undo')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('canvas-divider-embed')),
      findsNothing,
    );
  });

  testWidgets('inline formatting is visible in Delta and leaves no markers', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(tester, '正文');
    final bodyField = _bodyField(tester);
    bodyField.controller!.value = const TextEditingValue(
      text: '正文',
      selection: TextSelection(baseOffset: 0, extentOffset: 2),
    );

    await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(bodyField.controller!.text, '正文');
    expect(_bodyStyle(tester, start: 0, length: 2)['bold'], true);
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(bodyField.controller!.text, '正文');
    expect(_bodyStyle(tester, start: 0, length: 2), isNot(contains('bold')));
    expect(bodyField.controller!.text, isNot(contains('**')));
  });

  testWidgets('formatting rows apply persistent inline styles and alignment', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(tester, '查看链接');
    final bodyField = _bodyField(tester);
    bodyField.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 4,
    );
    final textStyle = find.byKey(const ValueKey<String>('canvas-text-style'));
    expect(
      tester.getRect(textStyle).right,
      lessThanOrEqualTo(tester.view.physicalSize.width),
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-insert-image')),
      findsNothing,
    );

    await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下划线'));
    await tester.pump();
    expect(bodyField.controller!.text, '查看链接');
    expect(_bodyStyle(tester, start: 0, length: 4)['underline'], true);
    await tester.tap(find.byTooltip('删除线'));
    await tester.pump();
    expect(_bodyStyle(tester, start: 0, length: 4)['strike'], true);
    expect(find.byTooltip('红色下划线'), findsNothing);
    expect(find.byTooltip('文字颜色'), findsNothing);
    expect(find.byTooltip('背景颜色'), findsNothing);
    expect(bodyField.controller!.text, isNot(contains('data-hh-')));

    bodyField.controller!.value = const TextEditingValue(
      text: '居中内容',
      selection: TextSelection(baseOffset: 0, extentOffset: 4),
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-alignment')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('居中对齐'));
    await tester.pump();
    expect(bodyField.controller!.text, '居中内容');
    expect(_lineBreakAttributes(tester, 0)['align'], 'center');
  });

  testWidgets('link editor updates display text and the full existing range', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '查看链接',
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
    await tester.pumpAndSettle();
    final link = find.byTooltip('链接');
    await tester.scrollUntilVisible(
      link,
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(link);
    await tester.pumpAndSettle();

    final label = find.byKey(
      const ValueKey<String>('canvas-markdown-link-label'),
    );
    final url = find.byKey(
      const ValueKey<String>('canvas-markdown-link-input'),
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-markdown-toolbar')),
      findsNothing,
    );
    expect(tester.widget<TextField>(label).controller!.text, '查看链接');
    await tester.enterText(url, 'https://example.com/first');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-link-apply')));
    await tester.pumpAndSettle();
    expect(
      _bodyStyle(tester, start: 0, length: 4)['link'],
      'https://example.com/first',
    );

    _selectBody(tester, const TextSelection.collapsed(offset: 2));
    await tester.pump();
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-link-editor-existing')),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(label).controller!.text, '查看链接');
    await tester.enterText(label, '阅读资料');
    await tester.enterText(url, 'https://example.com/updated');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-link-done')));
    await tester.pumpAndSettle();
    expect(_bodyText(tester), '阅读资料');
    expect(
      _bodyStyle(tester, start: 0, length: 4)['link'],
      'https://example.com/updated',
    );

    _selectBody(tester, const TextSelection.collapsed(offset: 2));
    await tester.pump();
    await tester.tap(link);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-link-remove')));
    await tester.pumpAndSettle();
    expect(_bodyStyle(tester, start: 0, length: 4), isNot(contains('link')));
  });

  testWidgets('link editor owns the canvas until applied or cancelled', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '待添加链接',
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('链接'));
    await tester.pumpAndSettle();

    expect(_bodyController(tester).readOnly, isTrue);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey<String>('canvas-save')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-more-actions')));
    await tester.pump();
    expect(find.text('请先应用或取消当前链接'), findsOneWidget);
    expect(find.text('应用链接'), findsOneWidget);

    harness.router.go(
      '/canvas',
      extra: const CanvasEntryIntent.assistantReply(
        AssistantReplyCanvasSeed(title: '排队的新入口', markdown: '链接结算后才可以打开。'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('新的任务入口正在等待安全切换'), findsOneWidget);
    expect(_bodyText(tester), '待添加链接');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('canvas-markdown-link-input')),
          )
          .enabled,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey<String>('canvas-link-cancel')));
    await _pumpUntil(tester, () => find.text('已有未完成创作').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-link-editor-new')),
      findsNothing,
    );
    final discardCurrent = find.text('放弃并打开当前入口');
    await tester.ensureVisible(discardCurrent);
    await tester.tap(discardCurrent);
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(const ValueKey<String>('canvas-body-field'))
              .evaluate()
              .isNotEmpty &&
          _bodyText(tester) == '链接结算后才可以打开。',
    );
    await tester.pumpAndSettle();
    expect(_bodyController(tester).readOnly, isFalse);
    expect(
      find.byKey(const ValueKey<String>('canvas-link-editor-new')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-markdown-toolbar')),
      findsOneWidget,
    );
  });

  testWidgets('landscape keyboard keeps the link form scroll-reachable', (
    tester,
  ) async {
    const surfaceSize = Size(568, 320);
    const keyboardInset = 160.0;
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: surfaceSize,
      textScale: 1.3,
      viewInsets: const EdgeInsets.only(bottom: keyboardInset),
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '横屏链接',
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    await _tapCanvasPrimaryTool(tester, 'canvas-text-style');
    await tester.pumpAndSettle();
    final link = find.byTooltip('链接');
    await tester.scrollUntilVisible(
      link,
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(link);
    await tester.pumpAndSettle();

    final url = find.byKey(
      const ValueKey<String>('canvas-markdown-link-input'),
    );
    final save = find.byKey(const ValueKey<String>('canvas-link-apply'));
    await tester.ensureVisible(url);
    await tester.pumpAndSettle();
    expect(url.hitTestable(), findsOneWidget);
    await tester.enterText(url, 'https://example.com/landscape');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-markdown-toolbar')),
      findsNothing,
    );
    expect(
      (tester
                  .widget<ListView>(
                    find.byKey(const ValueKey<String>('canvas-editor-scroll')),
                  )
                  .padding!
              as EdgeInsets)
          .bottom,
      greaterThanOrEqualTo(464),
    );
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(save.hitTestable(), findsOneWidget);
    expect(
      tester.getBottomRight(save).dy,
      lessThanOrEqualTo(surfaceSize.height - keyboardInset),
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      _bodyStyle(tester, start: 0, length: 4)['link'],
      'https://example.com/landscape',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('note picker imports raw bodies and reports skipped notes', (
    tester,
  ) async {
    final repository = _draftRepository();
    final first = V3FeedItem(
      id: 'note-first',
      title: '原始正文笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 7, 21),
      rawBody: '第一条完整正文',
    );
    final second = V3FeedItem(
      id: 'note-second',
      title: '只有摘要的笔记',
      source: V3MaterialSource.link,
      createdAt: DateTime.utc(2026, 7, 22),
      rawBody: '',
      summaryBody: '第二条摘要内容',
    );
    final library = KnowledgeLibraryController(initialNotes: [first, second]);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '开头');
    _selectBody(tester, const TextSelection.collapsed(offset: 2));

    await _tapCanvasPrimaryTool(tester, 'canvas-import-notes');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('knowledge-note-picker-note-note-second')),
    );
    await tester.tap(
      find.byKey(const ValueKey('knowledge-note-picker-note-note-first')),
    );
    await tester.tap(
      find.byKey(const ValueKey('knowledge-note-picker-confirm')),
    );
    await tester.pumpAndSettle();

    final body = _bodyText(tester);
    expect(body, isNot(contains('只有摘要的笔记')));
    expect(body, isNot(contains('第二条摘要内容')));
    expect(body, contains('原始正文笔记'));
    expect(body, contains('第一条完整正文'));
    expect(find.text('已导入 1 条笔记，1 条无原始正文未导入'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 810));
    expect(
      repository.load()!.linkedMaterials.map((item) => item.id),
      orderedEquals(<String>['note-first']),
    );

    await tester.tap(find.byKey(const ValueKey<String>('canvas-top-undo')));
    await tester.pump(const Duration(milliseconds: 810));
    expect(_bodyText(tester), '开头');
    expect(repository.load()!.linkedMaterials, isEmpty);

    expect(_bodyController(tester).hasRedo, isTrue);
    _bodyController(tester).redo();
    await tester.pump(const Duration(milliseconds: 810));
    expect(_bodyText(tester), contains('第一条完整正文'));
    expect(
      repository.load()!.linkedMaterials.map((item) => item.id),
      orderedEquals(<String>['note-first']),
    );
  });

  testWidgets('image embed has handles without legacy slider or presets', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    final controller = _bodyController(tester);
    final image = CanvasImageEmbedData(
      resourceId: 'canvas-widget-test.png',
      alt: '测试图片',
      widthRatio: .5,
      aspectRatio: 4 / 3,
    );
    controller.replaceText(
      0,
      0,
      Embeddable(CanvasImageEmbedData.deltaEmbedType, image.toJson()),
      const TextSelection.collapsed(offset: 1),
    );
    controller.document.history.clear();
    await tester.pumpAndSettle();

    final imageFinder = find.byKey(
      const ValueKey<String>('canvas-image-canvas-widget-test.png'),
    );
    expect(imageFinder, findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('小'), findsNothing);
    expect(find.text('中'), findsNothing);
    expect(find.text('大'), findsNothing);

    await tester.tapAt(tester.getTopLeft(imageFinder) + const Offset(48, 48));
    await tester.pump();
    for (final corner in const <String>[
      'top-left',
      'top-right',
      'bottom-left',
      'bottom-right',
    ]) {
      final handle = find.byKey(
        ValueKey<String>('canvas-image-handle-$corner-canvas-widget-test.png'),
      );
      expect(handle, findsOneWidget);
      final handleSize = tester.getSize(handle);
      expect(handleSize.width, greaterThanOrEqualTo(44));
      expect(handleSize.height, greaterThanOrEqualTo(44));
    }

    final handle = find.byKey(
      const ValueKey<String>(
        'canvas-image-handle-bottom-right-canvas-widget-test.png',
      ),
    );
    var handleDetector = tester.widget<GestureDetector>(handle);
    handleDetector.onPanUpdate!(
      DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: const Offset(62, 24),
      ),
    );
    await tester.pump();
    handleDetector.onPanCancel!();
    await tester.pump();
    expect(_firstCanvasImage(tester).widthRatio, .5);

    handleDetector = tester.widget<GestureDetector>(handle);
    handleDetector.onPanUpdate!(
      DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: const Offset(96, 36),
      ),
    );
    await tester.pump();
    handleDetector.onPanEnd!(DragEndDetails());
    await tester.pumpAndSettle();
    expect(_firstCanvasImage(tester).widthRatio, greaterThan(.5));

    expect(controller.hasUndo, isTrue);
    controller.undo();
    await tester.pump();
    expect(_firstCanvasImage(tester).widthRatio, .5);
  });

  testWidgets(
    'AI review marks deleted rich embeds and keeps unchanged embeds neutral',
    (tester) async {
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        aiPort: _DiffCanvasAiPort((_) => 'candidate'),
      );
      addTearDown(harness.dispose);
      final body = _bodyController(tester);
      final image = CanvasImageEmbedData(
        resourceId: 'review-image.png',
        alt: '审核图片',
        widthRatio: .5,
        aspectRatio: 4 / 3,
      );
      final document = Delta()
        ..insert(
          Embeddable(
            CanvasImageEmbedData.deltaEmbedType,
            image.toJson(),
          ).toJson(),
        )
        ..insert('\n')
        ..insert(CanvasDocumentCodec.canvasDividerDeltaInsert)
        ..insert('\nsource\n');
      body.replaceText(
        0,
        body.document.length - 1,
        document,
        TextSelection.collapsed(offset: document.length - 1),
      );
      body.document.history.clear();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-divider-embed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-image-review-image.png')),
        findsOneWidget,
      );

      Finder reviewFrame(String prefix) => find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            ((widget.key! as ValueKey<String>).value).startsWith(prefix),
      );

      await _tapAiSkill(tester, 'needsDeepening');
      await tester.pumpAndSettle();
      expect(reviewFrame('canvas-review-deleted-image-'), findsOneWidget);
      expect(reviewFrame('canvas-review-deleted-divider-'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-reject')));
      await tester.pumpAndSettle();

      _selectBody(tester, const TextSelection(baseOffset: 4, extentOffset: 10));
      await tester.pump();
      await _tapAiSkill(tester, 'needsDeepening');
      await tester.pumpAndSettle();
      expect(reviewFrame('canvas-review-inserted-image-'), findsNothing);
      expect(reviewFrame('canvas-review-inserted-divider-'), findsNothing);
      expect(reviewFrame('canvas-review-deleted-image-'), findsNothing);
      expect(reviewFrame('canvas-review-deleted-divider-'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('canvas-image-review-image.png')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-divider-embed')),
        findsOneWidget,
      );
    },
  );

  testWidgets('paused lifecycle flushes the draft before debounce elapses', (
    tester,
  ) async {
    final repository = _draftRepository();
    final harness = await _pumpCanvas(tester, repository: repository);
    addTearDown(harness.dispose);
    await _setBody(tester, '切到后台也必须立即保存');

    expect(repository.load(), isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(repository.load()!.markdown, contains('切到后台也必须立即保存'));
    expect(repository.load()!.documentJson, isNotNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets(
    'empty canvas gives AI guidance without opening an action sheet',
    (tester) async {
      final harness = await _pumpCanvas(tester, repository: _draftRepository());
      addTearDown(harness.dispose);
      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('canvas-ai-action-row')),
        findsNothing,
      );
      expect(find.text('AI 创作工具'), findsNothing);
      expect(find.text('先写下一些内容，再使用 AI 创作工具'), findsOneWidget);
      expect(
        find.descendant(
          of: find.descendant(
            of: find.byType(V3CreationCanvasPage),
            matching: find.byType(Scaffold),
          ),
          matching: find.byType(SnackBar),
        ),
        findsOneWidget,
      );
      expect(_bodyEditor(tester).focusNode.hasFocus, isTrue);
    },
  );

  testWidgets('edit and AI modes switch in place without opening a modal', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '模式切换不应改变正文。',
      selection: const TextSelection(baseOffset: 0, extentOffset: 2),
    );

    expect(
      find.byKey(const ValueKey<String>('canvas-primary-toolbar-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-action-row')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-ai-action-row')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SegmentedButton<CanvasAiEditScope>>(
            find.byKey(const ValueKey<String>('canvas-ai-scope-selector')),
          )
          .selected,
      <CanvasAiEditScope>{CanvasAiEditScope.local},
    );
    expect(find.text('AI 创作工具'), findsNothing);
    expect(_bodyText(tester), '模式切换不应改变正文。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-edit-mode')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-ai-action-row')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-primary-toolbar-scroll')),
      findsOneWidget,
    );
    expect(_bodyController(tester).readOnly, isFalse);
    expect(
      _bodyController(tester).selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );
  });

  testWidgets('running AI preview exposes cancellation and locks the editor', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _PendingCanvasAiPort(),
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '等待生成期间不应修改正文。');

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 500));

    final cancelFinder = find.byKey(const ValueKey<String>('canvas-ai-cancel'));
    expect(cancelFinder, findsOneWidget);
    expect(
      tester.getRect(cancelFinder).bottom,
      lessThanOrEqualTo(tester.view.physicalSize.height),
    );
    expect(_bodyController(tester).readOnly, isTrue);
    expect(_bodyText(tester), '等待生成期间不应修改正文。');
    expect(
      find.byKey(const ValueKey<String>('canvas-chat-entry')),
      findsNothing,
    );
    await tester.tap(cancelFinder);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-cancel')),
      findsNothing,
    );
  });

  testWidgets('back resolves running AI before offering draft choices', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _PendingCanvasAiPort(),
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '退出时要先取消仍在生成的建议。');
    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('返回'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('AI 仍在生成'), findsOneWidget);
    expect(find.text('取消生成并继续'), findsOneWidget);

    await tester.ensureVisible(find.text('取消生成并继续'));
    await tester.tap(find.text('取消生成并继续'));
    await tester.pumpAndSettle();
    expect(find.text('离开自由创作？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();

    expect(find.byType(V3CreationCanvasPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-cancel')),
      findsNothing,
    );
    expect(_bodyController(tester).readOnly, isFalse);
  });

  testWidgets('bottom AI command exposes eight actions and opening choices', (
    tester,
  ) async {
    final aiPort = _CapturingCanvasAiPort();
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: aiPort,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '需要优化的开头。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-action-row')),
      findsOneWidget,
    );
    expect(find.text('AI 创作工具'), findsNothing);
    expect(find.text('全文'), findsOneWidget);
    expect(find.text('选中文字'), findsOneWidget);
    for (final action in CanvasAiAction.values) {
      await _scrollCanvasAiActionIntoView(tester, action);
      expect(
        find.byKey(ValueKey<String>('canvas-ai-action-${action.name}')),
        findsOneWidget,
      );
    }
    await _scrollCanvasAiActionIntoView(
      tester,
      CanvasAiAction.openingOptimization,
    );
    await tester.tap(
      _canvasAiActionControl(CanvasAiAction.openingOptimization),
    );
    await tester.pumpAndSettle();
    expect(find.text('选择开头方式'), findsOneWidget);
    expect(find.text('标签化'), findsOneWidget);
    expect(find.text('陌生化'), findsOneWidget);
    expect(aiPort.requests, isEmpty);
    await tester.tap(find.text('标签化'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(aiPort.requests, hasLength(1));
    expect(
      aiPort.requests.single.openingVariant,
      CanvasOpeningVariant.labeling,
    );

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
  });

  testWidgets('relationship shift requires an explicit perspective', (
    tester,
  ) async {
    final aiPort = _CapturingCanvasAiPort();
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: aiPort,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '这段话需要调整表达关系。');

    await _tapAiSkill(tester, 'socialRelationShift');
    await tester.pumpAndSettle();
    expect(find.text('选择人称'), findsOneWidget);
    expect(find.text('平等交流'), findsOneWidget);
    expect(find.text('朋友分享'), findsOneWidget);
    expect(find.text('顾问建议'), findsOneWidget);
    expect(find.text('导师引导'), findsOneWidget);
    expect(find.text('客户对话'), findsOneWidget);
    expect(aiPort.requests, isEmpty);
    await tester.ensureVisible(find.text('平等交流'));
    await tester.pump();
    await tester.tap(find.text('平等交流'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(aiPort.requests, hasLength(1));
    expect(aiPort.requests.single.relationTarget, CanvasRelationTarget.peer);
  });

  testWidgets('AI scope freezes either full body or only the selection', (
    tester,
  ) async {
    final aiPort = _CapturingCanvasAiPort();
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: aiPort,
    );
    addTearDown(harness.dispose);

    await _setBody(tester, 'prefix selected suffix');
    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();

    expect(aiPort.requests, hasLength(1));
    final global = aiPort.requests.single;
    expect(global.editScope, CanvasAiEditScope.global);
    expect(global.documentMarkdown, contains('prefix selected suffix'));
    expect(global.targetMarkdown, contains('prefix selected suffix'));
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();

    await _setBody(
      tester,
      'prefix selected suffix',
      selection: const TextSelection(baseOffset: 7, extentOffset: 15),
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
    await tester.pumpAndSettle();
    final scopeSelector = tester.widget<SegmentedButton<CanvasAiEditScope>>(
      find.byKey(const ValueKey<String>('canvas-ai-scope-selector')),
    );
    expect(scopeSelector.selected, <CanvasAiEditScope>{
      CanvasAiEditScope.local,
    });
    await _scrollCanvasAiActionIntoView(tester, CanvasAiAction.needsDeepening);
    await tester.tap(_canvasAiActionControl(CanvasAiAction.needsDeepening));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(aiPort.requests, hasLength(2));
    final local = aiPort.requests.last;
    expect(local.editScope, CanvasAiEditScope.local);
    expect(local.documentMarkdown, contains('selected'));
    expect(local.documentMarkdown, isNot(contains('prefix')));
    expect(local.documentMarkdown, isNot(contains('suffix')));
    expect(local.targetMarkdown, contains('selected'));
  });

  testWidgets('local AI keeps the following paragraph boundary', (
    tester,
  ) async {
    const source = '第一段。\n第二段。';
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _DiffCanvasAiPort((_) => '新的第一段。'),
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      source,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: source.indexOf('\n') + 1,
      ),
    );

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();

    expect(_bodyText(tester), '新的第一段。\n第二段。');
  });

  testWidgets('local AI acceptance leaves the caret after the replacement', (
    tester,
  ) async {
    const source = 'prefix old suffix';
    const replacement = 'new text';
    const start = 7;
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _DiffCanvasAiPort((_) => replacement),
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      source,
      selection: const TextSelection(baseOffset: start, extentOffset: 10),
    );

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();

    expect(_bodyText(tester), 'prefix $replacement suffix');
    expect(
      _bodyController(tester).selection,
      const TextSelection.collapsed(offset: start + replacement.length),
    );
  });

  testWidgets('AI apply cannot inherit a pending caret style', (tester) async {
    const source = 'original body';
    const replacement = 'plain candidate';
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _DiffCanvasAiPort((_) => replacement),
    );
    addTearDown(harness.dispose);
    await _setBody(tester, source);
    final body = _bodyController(tester);
    final before = Delta.fromJson(body.document.toDelta().toJson());

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();
    body.forceToggledStyle(
      Style.attr(<String, Attribute>{Attribute.bold.key: Attribute.bold}),
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();

    final expected = CanvasDocumentCodec().documentFromMarkdown(replacement);
    expect(body.document.toDelta(), expected.toDelta());
    expect(
      body.document.toDelta().toList().where(
        (operation) =>
            operation.attributes?.containsKey(Attribute.bold.key) == true,
      ),
      isEmpty,
    );
    expect(body.toggledStyle.isEmpty, isTrue);
    expect(body.hasUndo, isTrue);
    body.undo();
    await tester.pump();
    expect(body.document.toDelta(), before);
  });

  testWidgets('failed AI commit restores exact rich body and selection', (
    tester,
  ) async {
    const source = 'prefix old suffix';
    const replacement = 'new';
    const selection = TextSelection(
      baseOffset: 10,
      extentOffset: 7,
      affinity: TextAffinity.upstream,
      isDirectional: true,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      aiPort: _DiffCanvasAiPort((_) => replacement),
    );
    addTearDown(harness.dispose);
    await _setBody(tester, source, selection: selection);
    final body = _bodyController(tester);
    body.formatText(0, 6, Attribute.bold);
    await tester.pump();

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();
    final before = Delta.fromJson(body.document.toDelta().toJson());
    var injected = false;
    body.onSelectionChanged = (_) {
      if (!injected && body.document.toPlainText().contains(replacement)) {
        injected = true;
        throw StateError('injected post-mutation selection failure');
      }
    };

    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();

    expect(injected, isTrue);
    expect(body.document.toDelta(), before);
    expect(body.selection, selection);
    expect(find.text('建议暂时无法应用，正文已保留'), findsOneWidget);
    expect(body.hasUndo, isTrue);
    body.onSelectionChanged = null;
  });

  testWidgets(
    'selected text context menu adds one AI entry to native actions',
    (tester) async {
      final harness = await _pumpCanvas(tester, repository: _draftRepository());
      addTearDown(harness.dispose);
      await _setBody(
        tester,
        '选中这段正文后显示原生上下文功能。',
        selection: const TextSelection(baseOffset: 0, extentOffset: 6),
      );

      final editor = _bodyEditor(tester);
      final rawState = tester.state<QuillRawEditorState>(
        find.byType(QuillRawEditor),
      );
      editor.focusNode.requestFocus();
      await tester.pump();
      expect(rawState.showToolbar(), isTrue);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-selection-context-menu')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-selection-native-actions')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-selection-ai-actions')),
        findsNothing,
      );
      expect(find.text('AI 改写'), findsOneWidget);
      for (final action in CanvasAiAction.values) {
        expect(find.text(action.label), findsNothing);
      }

      final original = _bodyText(tester);
      await tester.tap(find.text('AI 改写'));
      await tester.pumpAndSettle();
      expect(find.text('AI 创作工具'), findsOneWidget);
      expect(find.text('选中文字'), findsOneWidget);
      await _scrollCanvasAiActionIntoView(
        tester,
        CanvasAiAction.needsDeepening,
      );
      await tester.tap(_canvasAiActionControl(CanvasAiAction.needsDeepening));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-apply')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), contains('需求深化'));
      expect(_bodyText(tester), endsWith(original.substring(6)));

      _bodyController(tester).updateSelection(
        const TextSelection.collapsed(offset: 3),
        ChangeSource.local,
      );
      await tester.pump();
      final collapsedMenu = editor.config.contextMenuBuilder!(
        tester.element(_canvasBodyFinder),
        rawState,
      );
      final collapsedToolbar =
          (collapsedMenu as TextFieldTapRegion).child!
              as AdaptiveTextSelectionToolbar;
      final collapsedLabels = collapsedToolbar.buttonItems!
          .map((item) => item.label)
          .whereType<String>();
      expect(collapsedLabels, isNot(contains('AI 改写')));
    },
  );

  testWidgets('free creation keeps touch caret placement precise', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);

    expect(_bodyEditor(tester).config.detectWordBoundary, isFalse);
    expect(
      _bodyEditor(tester).config.textCapitalization,
      TextCapitalization.none,
    );
  });

  testWidgets('unused paper below a short document remains a body tap target', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(tester, '短正文');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-title-field')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('canvas-title-field')),
          )
          .focusNode!
          .hasFocus,
      isTrue,
    );

    final bodyRect = tester.getRect(_canvasBodyFinder);
    final toolbarTop = tester
        .getRect(find.byKey(const ValueKey<String>('canvas-markdown-toolbar')))
        .top;
    expect(bodyRect.bottom, greaterThanOrEqualTo(toolbarTop - 1));
    final blankPaper = Offset(bodyRect.center.dx, toolbarTop - 24);
    expect(bodyRect.contains(blankPaper), isTrue);
    await tester.tapAt(blankPaper);
    await tester.pump();

    expect(_bodyEditor(tester).focusNode.hasFocus, isTrue);
    expect(_bodyController(tester).selection.isCollapsed, isTrue);
    expect(
      _bodyController(tester).selection.baseOffset,
      _bodyController(tester).document.length - 1,
    );
  });

  testWidgets('canvas scroll dismisses the Quill menu but keeps selection', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: const Size(393, 700),
    );
    addTearDown(harness.dispose);
    final text = List<String>.generate(
      42,
      (index) => '第 ${index + 1} 行用于验证滚动时选择菜单不会停在旧位置。',
    ).join('\n');
    const selection = TextSelection(baseOffset: 0, extentOffset: 8);
    await _setBody(tester, text, selection: selection);
    final editor = _bodyEditor(tester);
    final rawState = tester.state<QuillRawEditorState>(
      find.byType(QuillRawEditor),
    );
    editor.focusNode.requestFocus();
    await tester.pump();
    expect(rawState.showToolbar(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('AI 改写'), findsOneWidget);

    final scroll = tester
        .widget<ListView>(
          find.byKey(const ValueKey<String>('canvas-editor-scroll')),
        )
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();

    expect(find.text('AI 改写'), findsNothing);
    expect(_bodyController(tester).selection, selection);
  });

  testWidgets('direct formatting follows each new live selection', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      'AAAA BBBB',
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );

    await tester.tap(find.byTooltip('加粗'));
    await tester.pumpAndSettle();
    _selectBody(tester, const TextSelection(baseOffset: 5, extentOffset: 9));
    await tester.pump();
    await tester.tap(find.byTooltip('斜体'));
    await tester.pumpAndSettle();

    final firstStyle = _bodyController(
      tester,
    ).document.querySegmentLeafNode(1).leaf!.style.attributes;
    final secondStyle = _bodyController(
      tester,
    ).document.querySegmentLeafNode(6).leaf!.style.attributes;
    expect(firstStyle, contains(Attribute.bold.key));
    expect(firstStyle, isNot(contains(Attribute.italic.key)));
    expect(secondStyle, contains(Attribute.italic.key));
    expect(secondStyle, isNot(contains(Attribute.bold.key)));
  });

  testWidgets('persona insertion uses the conversation positioning report', (
    tester,
  ) async {
    final positioning = DeepPositioningController(
      const DeepPositioningMockRepository(delay: Duration.zero),
    );
    expect(
      await positioning
          .saveConversation(const <DeepPositioningConversationEntry>[
            DeepPositioningConversationEntry(
              text: '我帮助创业团队把复杂产品讲清楚。',
              isAssistant: false,
            ),
          ]),
      isTrue,
    );
    final aiPort = _CapturingCanvasAiPort();
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      positioning: positioning,
      aiPort: aiPort,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '这段正文需要带入真实人设。');

    await _tapAiSkill(tester, 'personaInsertion');
    await tester.pumpAndSettle();

    expect(aiPort.requests, hasLength(1));
    expect(aiPort.requests.single.personaContext, contains('复杂产品讲清楚'));
    expect(find.text('需要先完成定位对话'), findsNothing);
  });

  testWidgets('dirty persona navigation requires a leave choice before push', (
    tester,
  ) async {
    final repository = _draftRepositoryWithPendingInitialReceipt(
      '尚未保存但需要先完成人设定位的正文。',
    );
    final scriptPort = _SuccessfulScriptDraftPort();
    final positioning = DeepPositioningController(
      const DeepPositioningMockRepository(delay: Duration.zero),
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      positioning: positioning,
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    await _tapAiSkill(tester, 'personaInsertion');
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始定位对话'));
    await tester.pumpAndSettle();

    expect(find.text('继续编辑'), findsOneWidget);
    expect(find.text('定位对话页'), findsNothing);
    await tester.tap(find.text('保留草稿并前往'));
    await tester.pumpAndSettle();

    expect(find.text('定位对话页'), findsOneWidget);
    expect(repository.load()?.markdown, contains('尚未保存但需要先完成人设定位'));
    expect(scriptPort.cancelledWith, isEmpty);
  });

  testWidgets('image brief is inserted without replacing the source', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);
    await _setBody(tester, '这段正文必须保留。');

    await _tapAiSkill(tester, 'imageBrief');
    await tester.pumpAndSettle();
    expect(find.text('选择配图方式'), findsOneWidget);
    expect(find.text('影像增强成品配图'), findsOneWidget);
    expect(find.text('口播解释性画面'), findsOneWidget);
    await tester.tap(find.text('影像增强成品配图'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
      findsOneWidget,
    );
    final reviewEditor = tester.widget<QuillEditor>(
      find.byKey(const ValueKey<String>('canvas-ai-inline-editor')),
    );
    expect(reviewEditor.controller.document.toPlainText(), contains('配图建议'));
    expect(_bodyText(tester), '这段正文必须保留。');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
      findsNothing,
    );
    expect(find.text('正文已变化，请重新生成'), findsNothing);
    expect(find.text('建议暂时无法应用，正文已保留'), findsNothing);
    final body = _bodyText(tester);
    expect(body, startsWith('这段正文必须保留。'));
    expect(body, contains('配图建议'));
  });

  testWidgets(
    'production transform shows local delete and insert before explicit apply',
    (tester) async {
      const original = '需要修改的旧句。';
      const candidate = '服务端应用后的新句。';
      final library = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        library: library,
        aiPort: _DiffCanvasAiPort((_) => candidate),
      );
      addTearDown(harness.dispose);
      await _setBody(tester, original);

      await _tapAiSkill(tester, 'needsDeepening');
      await tester.pumpAndSettle();

      expect(find.text('新增内容'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
        findsOneWidget,
      );
      _expectCanvasDiffStyles(
        tester,
        deletedFragment: '需要修改',
        insertedFragment: '服务端应用后',
      );
      expect(_bodyText(tester), original);
      expect(library.notes, isEmpty);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
      await tester.pumpAndSettle();

      expect(_bodyText(tester), candidate);
      expect(library.notes, isEmpty);
    },
  );

  testWidgets('autosave never creates or synchronizes an owned note', (
    tester,
  ) async {
    final notePort = _RecordingCanvasSynchronizingNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      notePort: notePort,
      includeDemoFixtures: false,
    );
    final repository = _draftRepository();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      autoSyncOwnedChanges: true,
    );
    addTearDown(harness.dispose);

    await _setBody(tester, '停顿后自动同步的自由创作正文');
    await tester.pump(const Duration(milliseconds: 1450));
    await tester.pump();

    expect(notePort.requests, isEmpty);
    expect(library.notes, isEmpty);
    expect(repository.load()?.markdown, contains('停顿后自动同步的自由创作正文'));
    expect(repository.load()?.synchronizedNoteId, isNull);
  });

  testWidgets(
    'undoing an autosaved edit settles the clean draft before leaving',
    (tester) async {
      final note = V3FeedItem(
        id: 'clean-settlement-note',
        title: '已保存标题',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 9, 4),
        rawBody: '已保存正文',
      );
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[note],
        includeDemoFixtures: false,
      );
      final repository = _draftRepository();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
        location: '/canvas?historyId=history-${note.id}',
        historyPort: _historyForNote(note),
      );
      addTearDown(harness.dispose);
      await _pumpUntilCanvasReady(tester);

      final body = _bodyController(tester);
      body.replaceText(
        0,
        body.document.length - 1,
        '已经自动保存但随后撤销的正文',
        const TextSelection.collapsed(offset: 14),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 810));
      expect(repository.load()?.markdown, contains('随后撤销'));

      body.undo();
      await tester.pump();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(find.text('创作空间'), findsOneWidget);
      expect(repository.load(), isNull);

      harness.router.go('/canvas?historyId=history-${note.id}');
      await _pumpUntilCanvasReady(tester);
      expect(_bodyText(tester), '已保存正文');
    },
  );

  testWidgets('dirty keep rejects an edit arriving during leave persistence', (
    tester,
  ) async {
    final delegate = _draftRepository();
    final repository = _GatedCanvasDraftStore(delegate);
    final recorder = _CanvasLiveRecorder();
    final stopGate = Completer<void>();
    final asr = _CanvasLiveAsrPort(stopGate: stopGate.future);
    final liveTranscript = LiveTranscriptController(
      credentialPort: const _CanvasLiveCredentialPort(),
      asrPort: asr,
    );
    addTearDown(() async {
      if (!stopGate.isCompleted) stopGate.complete();
      liveTranscript.dispose();
      await asr.close();
    });
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      surfaceSize: const Size(800, 852),
      additionalOverrides: <Override>[
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
    await _setBody(tester, '准备保留的正文');
    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-voice-dictation')),
    );
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('canvas-title-field')),
          )
          .readOnly,
      isTrue,
    );
    expect(_bodyController(tester).readOnly, isTrue);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey<String>('canvas-save')))
          .onPressed,
      isNull,
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-voice-dictation')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-voice-dictation')),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    repository.gateNextUpsert();
    await tester.tap(find.text('保留草稿并退出'));
    await _pumpUntil(tester, () => repository.upsertStarted);
    await tester.pump();

    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('canvas-title-field')),
          )
          .readOnly,
      isTrue,
    );
    asr.emit(
      LiveTranscriptSentence(sentenceId: 1, text: '不应写入的晚到语音', stable: true),
    );
    await tester.pump();
    expect(_bodyText(tester), isNot(contains('不应写入的晚到语音')));
    final body = _bodyController(tester);
    const lateText = '，以及晚到编辑';
    final insertionOffset = body.document.length - 1;
    body.replaceText(
      insertionOffset,
      0,
      lateText,
      TextSelection.collapsed(offset: insertionOffset + lateText.length),
    );
    await tester.pump();
    repository.releaseUpsert();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-body-field')),
      findsOneWidget,
    );
    expect(find.text('创作空间'), findsNothing);
    expect(delegate.load()?.markdown, contains('晚到编辑'));
    expect(delegate.load()?.markdown, isNot(contains('不应写入的晚到语音')));
    expect(find.textContaining('内容在离开过程中发生变化'), findsOneWidget);
    stopGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(_bodyText(tester), isNot(contains('不应写入的晚到语音')));
  });

  testWidgets(
    'internal navigation rejects an edit arriving during keep persistence',
    (tester) async {
      final delegate = _draftRepository();
      final repository = _GatedCanvasDraftStore(delegate);
      final positioning = DeepPositioningController(
        const DeepPositioningMockRepository(delay: Duration.zero),
      );
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        positioning: positioning,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '内部跳转前的正文');

      await _tapAiSkill(tester, 'personaInsertion');
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始定位对话'));
      await tester.pumpAndSettle();
      repository.gateNextUpsert();
      await tester.tap(find.text('保留草稿并前往'));
      await _pumpUntil(tester, () => repository.upsertStarted);

      final body = _bodyController(tester);
      const lateText = '，跳转前新增';
      final insertionOffset = body.document.length - 1;
      body.replaceText(
        insertionOffset,
        0,
        lateText,
        TextSelection.collapsed(offset: insertionOffset + lateText.length),
      );
      await tester.pump();
      repository.releaseUpsert();
      await tester.pumpAndSettle();

      expect(find.text('定位对话页'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('canvas-body-field')),
        findsOneWidget,
      );
      expect(delegate.load()?.markdown, contains('跳转前新增'));
    },
  );

  testWidgets('clean settlement rejects an edit arriving during draft clear', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'clean-leave-race-note',
      title: '已保存标题',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 4),
      rawBody: '已保存正文',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    final delegate = _draftRepository();
    final repository = _GatedCanvasDraftStore(delegate);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      location: '/canvas?historyId=history-${note.id}',
      historyPort: _historyForNote(note),
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);
    final body = _bodyController(tester);
    body.replaceText(
      0,
      body.document.length - 1,
      '先自动保存再撤销',
      const TextSelection.collapsed(offset: 9),
    );
    await tester.pump(const Duration(milliseconds: 810));
    body.undo();
    await tester.pump();

    repository.gateNextClear();
    await tester.tap(find.byTooltip('返回'));
    await _pumpUntil(tester, () => repository.clearStarted);
    const lateText = '，clean 结算晚到内容';
    final insertionOffset = body.document.length - 1;
    body.replaceText(
      insertionOffset,
      0,
      lateText,
      TextSelection.collapsed(offset: insertionOffset + lateText.length),
    );
    await tester.pump();
    repository.releaseClear();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('canvas-body-field')),
      findsOneWidget,
    );
    expect(delegate.load()?.markdown, contains('结算晚到内容'));
  });

  testWidgets('existing Note entry waits for cold Knowledge cache restore', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'cold-existing-note',
      title: '冷启动资产',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 4),
      rawBody: '缓存恢复后的正文',
    );
    final cache = _GatedCanvasKnowledgeCache(<V3FeedItem>[note]);
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      cache: cache,
      includeDemoFixtures: false,
    );
    final scriptPort = _SuccessfulScriptDraftPort(finalMarkdown: '缓存恢复后生成的逐字稿');
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      location: '/canvas?initialNoteId=${note.id}',
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);

    expect(cache.loadStarted.isCompleted, isTrue);
    expect(
      find.byKey(const ValueKey<String>('canvas-body-field')),
      findsNothing,
    );
    cache.releaseLoad();
    await _pumpUntilCanvasReady(tester);

    expect(_bodyText(tester), '缓存恢复后生成的逐字稿');
    expect(scriptPort.requests.single.source.content, '缓存恢复后的正文');
    expect(find.text('要打开的资产已不存在'), findsNothing);
  });

  testWidgets('local-only history is labeled locally saved and can retry', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'local-only-history-note',
      title: '仅在本机的创作',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 13),
      rawBody: '这篇内容还没有获得云端确认。',
      syncState: NoteSyncState.localOnly,
      contentOrigin: V3ContentOrigin.freeCreation,
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
      autoSyncOwnedChanges: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      location: '/canvas?historyId=history-${note.id}',
      historyPort: _historyForNote(note),
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey<String>('canvas-save-indicator')),
          )
          .label,
      '草稿已存本机',
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey<String>('canvas-save')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('failed Knowledge restore retains bound draft until retry', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'retry-bound-note',
      title: '待恢复资产',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 4),
      rawBody: '绑定草稿正文',
    );
    final cache = _RetryableCanvasKnowledgeCache(<V3FeedItem>[note]);
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      cache: cache,
      includeDemoFixtures: false,
    );
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: note.title,
          markdown: note.rawBody,
          boundNoteId: note.id,
          entryIdentity: 'history:history-${note.id}',
          revision: 2,
          createdAt: note.createdAt,
          updatedAt: note.createdAt,
        ),
      );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      location: '/canvas?historyId=history-${note.id}',
      historyPort: _historyForNote(note),
    );
    addTearDown(harness.dispose);
    await _pumpUntil(tester, () => find.text('创作内容加载失败').evaluate().isNotEmpty);

    expect(find.text('资产数据暂时无法读取，请重试'), findsOneWidget);
    expect(repository.load()?.boundNoteId, note.id);
    expect(repository.load()?.markdown, note.rawBody);

    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-initial-draft-retry')),
    );
    await _pumpUntilCanvasReady(tester);

    expect(cache.loadCalls, 2);
    expect(_bodyText(tester), note.rawBody);
    expect(repository.load()?.boundNoteId, note.id);
  });

  testWidgets('restored legacy draft remains local without another edit', (
    tester,
  ) async {
    final notePort = _RecordingCanvasSynchronizingNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      notePort: notePort,
      includeDemoFixtures: false,
    );
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: '文件测试',
          markdown: '恢复后直接同步的正文',
          revision: 2,
          createdAt: DateTime.utc(2026, 8, 14),
          updatedAt: DateTime.utc(2026, 8, 14, 1),
        ),
      );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      autoSyncOwnedChanges: true,
    );
    addTearDown(harness.dispose);

    await tester.pump(const Duration(milliseconds: 1450));
    await tester.pump();

    expect(notePort.requests, isEmpty);
    expect(library.notes, isEmpty);
    expect(repository.load()?.markdown, '恢复后直接同步的正文');
    expect(repository.load()?.synchronizedNoteId, isNull);
  });

  testWidgets('production local diff reject keeps the original canvas body', (
    tester,
  ) async {
    const original = '拒绝前的正文。';
    const candidate = '不应写入的候选正文。';
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      aiPort: _DiffCanvasAiPort((_) => candidate),
    );
    addTearDown(harness.dispose);
    await _setBody(tester, original);

    await _tapAiSkill(tester, 'needsDeepening');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-reject')));
    await tester.pumpAndSettle();

    expect(_bodyText(tester), original);
    expect(library.notes, isEmpty);
  });

  testWidgets('dirty back can keep the recoverable draft and exit', (
    tester,
  ) async {
    final repository = _draftRepositoryWithPendingInitialReceipt('下次继续编辑的正文');
    final scriptPort = _SuccessfulScriptDraftPort();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      scriptDraftPort: scriptPort,
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('保留草稿并退出'), findsOneWidget);
    await tester.tap(find.text('保留草稿并退出'));
    await tester.pumpAndSettle();

    expect(find.text('创作空间'), findsOneWidget);
    expect(repository.load()?.markdown.trimRight(), '下次继续编辑的正文');
    expect(repository.load()?.scriptDraftReceipt?.agentRunId, 'pending-run');
    expect(scriptPort.cancelledWith, isEmpty);
  });

  testWidgets('failed draft persistence still offers a copied exit path', (
    tester,
  ) async {
    String? clipboardText;
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
    final repository = _FailingCanvasDraftUpsertStore(_draftRepository());
    final harness = await _pumpCanvas(tester, repository: repository);
    addTearDown(harness.dispose);
    await _setBody(tester, '即使本地存储失败，也不能困在编辑器里。');

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留草稿并退出'));
    await tester.pumpAndSettle();

    expect(find.text('草稿无法写入本机'), findsOneWidget);
    expect(find.text('复制内容后退出'), findsOneWidget);
    expect(find.text('仍然退出（未保存）'), findsOneWidget);
    await tester.tap(find.text('复制内容后退出'));
    await tester.pumpAndSettle();

    expect(clipboardText, contains('即使本地存储失败，也不能困在编辑器里。'));
    expect(find.text('创作空间'), findsOneWidget);
  });

  testWidgets(
    'foreground ingress preserves a dirty canvas as a recoverable draft',
    (tester) async {
      final repository = _draftRepositoryWithPendingInitialReceipt(
        '前台入口前仍需保留的正文',
      );
      final scriptPort = _SuccessfulScriptDraftPort();
      final coordinator = ForegroundIngressCoordinator();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        scriptDraftPort: scriptPort,
        foregroundIngressCoordinator: coordinator,
      );
      addTearDown(harness.dispose);
      await _pumpUntilCanvasReady(tester);
      await tester.pump(const Duration(milliseconds: 300));

      final cancelled = coordinator.requestNavigation();
      await tester.pump();
      await _pumpUntil(
        tester,
        () => find.text('保留当前草稿？').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.text('保留当前草稿？'), findsOneWidget);
      final continueEditing = find.text('继续编辑');
      await tester.ensureVisible(continueEditing);
      await tester.tap(continueEditing);
      await tester.pumpAndSettle();
      expect(await cancelled, isFalse);
      expect(_bodyText(tester), '前台入口前仍需保留的正文');

      final allowed = coordinator.requestNavigation();
      await tester.pump();
      await _pumpUntil(
        tester,
        () => find.text('保留当前草稿？').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      final preserveDraft = find.text('保留草稿并查看');
      await tester.ensureVisible(preserveDraft);
      await tester.tap(preserveDraft);
      await tester.pumpAndSettle();
      expect(await allowed, isTrue);
      expect(repository.load()?.markdown.trimRight(), '前台入口前仍需保留的正文');
      expect(repository.load()?.scriptDraftReceipt?.agentRunId, 'pending-run');
      expect(scriptPort.cancelledWith, isEmpty);
      expect(_bodyText(tester), '前台入口前仍需保留的正文');
    },
  );

  testWidgets('a pending save finishes before opening a queued entry', (
    tester,
  ) async {
    final cache = _ControlledCanvasKnowledgeCache()..failSaves = true;
    final repository = _draftRepository();
    final library = KnowledgeLibraryController(
      notePort: const _CanvasSynchronizingNotePort(),
      initialNotes: const [],
      cache: cache,
    );
    await library.initialize();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '只应创建一条的正文');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-body-field')),
      findsOneWidget,
    );
    expect(
      library.notes.where((note) => note.source == V3MaterialSource.note),
      isEmpty,
    );
    final prepared = repository.load()!;
    expect(
      prepared.historyCommitReceipt?.phase,
      CreationCanvasHistoryCommitPhase.prepared,
    );
    expect(prepared.boundNoteId, isNull);
    final preparedTargetId = prepared.historyCommitReceipt!.noteId;

    harness.router.go(
      '/canvas',
      extra: const CanvasEntryIntent.assistantReply(
        AssistantReplyCanvasSeed(title: '保存后打开', markdown: '新入口必须等旧保存事务结束。'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('新的任务入口正在等待安全切换'), findsOneWidget);
    expect(_bodyText(tester), '只应创建一条的正文');
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey<String>('canvas-save')))
          .onPressed,
      isNotNull,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('canvas-save')),
        matching: find.text('继续'),
      ),
      findsOneWidget,
    );

    cache.failSaves = false;
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await _pumpUntil(tester, () => _bodyText(tester) == '新入口必须等旧保存事务结束。');
    await tester.pumpAndSettle();
    expect(find.textContaining('detail:manual-'), findsNothing);
    expect(
      library.notes.where((note) => note.source == V3MaterialSource.note),
      hasLength(1),
    );
    expect(library.notes.single.id, preparedTargetId);
  });

  testWidgets('prepared update recovery replays only an exact base', (
    tester,
  ) async {
    final base = V3FeedItem(
      id: 'prepared-update-base',
      title: '原资产标题',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 1),
      rawBody: '原资产正文',
      localRevision: 4,
      syncState: NoteSyncState.synced,
      contentOrigin: V3ContentOrigin.freeCreation,
    );
    final library = KnowledgeLibraryController(
      notePort: const _CanvasSynchronizingNotePort(),
      initialNotes: <V3FeedItem>[base],
      includeDemoFixtures: false,
      autoSyncOwnedChanges: false,
    );
    final delegate = _draftRepository();
    final repository = _FailAfterPreparedCanvasDraftStore(delegate);
    final history = _ControlledCanvasHistoryPort();
    history.upsert('test-user', _historyForNote(base).list('test-user').single);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      historyPort: history,
      location: '/canvas?historyId=history-${base.id}',
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);
    await _setBody(tester, '恢复后只更新原资产一次');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(library.noteForId(base.id)?.rawBody, base.rawBody);
    final prepared = delegate.load()!;
    expect(
      prepared.historyCommitReceipt?.phase,
      CreationCanvasHistoryCommitPhase.prepared,
    );
    expect(prepared.historyCommitReceipt?.baseNoteId, base.id);
    expect(prepared.boundNoteId, base.id);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留状态并离开'));
    await tester.pumpAndSettle();
    harness.router.go('/canvas?initialNoteId=unrelated-entry');
    await tester.pumpAndSettle();
    await _pumpUntilCanvasReady(tester);

    expect(_bodyText(tester), '恢复后只更新原资产一次');
    await tester.tap(find.text('继续提交'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .join(' | ');
    expect(
      find.text('detail:${base.id}'),
      findsOneWidget,
      reason:
          'visible=$visibleText; note=${library.noteForId(base.id)?.rawBody}; '
          'phase=${delegate.load()?.historyCommitReceipt?.phase}',
    );
    expect(library.notes, hasLength(1));
    expect(library.noteForId(base.id)?.rawBody, '恢复后只更新原资产一次');
    expect(library.noteForId(base.id)?.localRevision, 5);
    expect(history.list('test-user'), hasLength(1));
    expect(delegate.load(), isNull);
  });

  testWidgets(
    'history recovery does not synchronize another editors newer revision',
    (tester) async {
      final history = _ControlledCanvasHistoryPort()..failUpserts = true;
      final repository = _draftRepository();
      final notePort = _RecordingCanvasSynchronizingNotePort();
      final library = KnowledgeLibraryController(
        notePort: notePort,
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
      );
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
        historyPort: history,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '创作历史确认失败后仍可重试的正文');

      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();

      expect(library.notes, hasLength(1));
      final savedId = library.notes.single.id;
      expect(repository.load()?.boundNoteId, savedId);
      expect(
        repository.load()?.historyCommitReceipt?.phase,
        CreationCanvasHistoryCommitPhase.noteCommitted,
      );
      expect(history.list('test-user'), isEmpty);
      expect(find.textContaining('提交尚未完成'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey<String>('canvas-save')),
            )
            .onPressed,
        isNotNull,
      );

      final later = library.updateManualNoteDraft(
        id: savedId,
        draft: V3NoteDraft(
          title: '其他位置的新标题',
          rawBody: '其他位置稍后保存的新正文',
          linkedMaterials: library.noteForId(savedId)!.linkedMaterials,
        ),
        scheduleAutomaticSync: false,
      )!;
      expect(later.rawBody, '其他位置稍后保存的新正文');
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('保存尚未提交完成'), findsOneWidget);
      await tester.tap(find.text('保留状态并离开'));
      await tester.pumpAndSettle();
      expect(find.text('创作空间'), findsOneWidget);
      harness.router.go('/canvas?initialNoteId=unrelated-entry');
      await tester.pumpAndSettle();
      await _pumpUntilCanvasReady(tester);
      expect(_bodyText(tester), '创作历史确认失败后仍可重试的正文');
      expect(find.text('笔记已落盘，创作历史尚待提交'), findsOneWidget);

      history.failUpserts = false;
      await tester.tap(find.text('继续提交'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();

      expect(find.text('detail:$savedId'), findsNothing);
      expect(find.text('资产已在其他位置更新，内容仍保留'), findsOneWidget);
      expect(notePort.requests, isEmpty);
      expect(library.notes, hasLength(1));
      expect(library.noteForId(savedId)?.rawBody, '其他位置稍后保存的新正文');
      expect(history.list('test-user'), isEmpty);
      expect(
        repository.load()?.historyCommitReceipt?.phase,
        CreationCanvasHistoryCommitPhase.noteCommitted,
      );
      expect(history.upsertCalls, 1);
    },
  );

  testWidgets('prepared recovery promotes only an exact existing target', (
    tester,
  ) async {
    final target = V3FeedItem(
      id: 'prepared-target',
      title: '冻结标题',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 5, 9),
      rawBody: '冻结正文',
      localRevision: 1,
      syncState: NoteSyncState.pending,
      contentOrigin: V3ContentOrigin.freeCreation,
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[target],
      includeDemoFixtures: false,
      autoSyncOwnedChanges: false,
    );
    final normalizedTarget = library.noteForId(target.id)!;
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: target.title,
          markdown: target.rawBody,
          sessionId: 'prepared-session',
          entryIdentity: const CanvasEntryIntent.blank().stableSourceId,
          historyCommitReceipt: CreationCanvasHistoryCommitReceipt(
            phase: CreationCanvasHistoryCommitPhase.prepared,
            historyId: target.id,
            noteId: target.id,
            noteFingerprint: _canvasNoteFingerprintForTest(normalizedTarget),
            editorSnapshotHash: 'frozen-snapshot',
          ),
          revision: 1,
          createdAt: target.createdAt,
          updatedAt: target.createdAt,
        ),
      );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      location: '/canvas?initialNoteId=unrelated-entry',
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    expect(_bodyText(tester), target.rawBody);
    expect(repository.load()?.boundNoteId, target.id);
    expect(
      repository.load()?.historyCommitReceipt?.phase,
      CreationCanvasHistoryCommitPhase.noteCommitted,
    );
    expect(library.noteForId(target.id)?.localRevision, 1);
  });

  testWidgets('prepared recovery fails closed for a conflicting target', (
    tester,
  ) async {
    final target = V3FeedItem(
      id: 'conflicting-prepared-target',
      title: '已存在标题',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 5, 9),
      rawBody: '已存在的不同正文',
      localRevision: 2,
      syncState: NoteSyncState.pending,
      contentOrigin: V3ContentOrigin.freeCreation,
    );
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: '待保存标题',
          markdown: '待保存正文',
          sessionId: 'conflicting-prepared-session',
          historyCommitReceipt: CreationCanvasHistoryCommitReceipt(
            phase: CreationCanvasHistoryCommitPhase.prepared,
            historyId: target.id,
            noteId: target.id,
            noteFingerprint: 'different-target-fingerprint',
            editorSnapshotHash: 'frozen-snapshot',
          ),
          revision: 1,
          createdAt: target.createdAt,
          updatedAt: target.createdAt,
        ),
      );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[target],
      includeDemoFixtures: false,
      autoSyncOwnedChanges: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();

    expect(find.text('草稿状态无法安全恢复'), findsOneWidget);
    expect(find.textContaining('目标位置已被其他内容占用'), findsOneWidget);
    expect(
      repository.load()?.historyCommitReceipt?.phase,
      CreationCanvasHistoryCommitPhase.prepared,
    );
    expect(library.noteForId(target.id)?.rawBody, '已存在的不同正文');
  });

  testWidgets('history committed recovery skips a second History upsert', (
    tester,
  ) async {
    final delegate = _draftRepository();
    final repository = _FailAfterHistoryCommittedCanvasDraftStore(delegate);
    final history = _ControlledCanvasHistoryPort();
    final library = KnowledgeLibraryController(
      notePort: const _CanvasSynchronizingNotePort(),
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
      autoSyncOwnedChanges: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      historyPort: history,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '历史已经提交，只需恢复收尾。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(history.upsertCalls, 1);
    expect(
      delegate.load()?.historyCommitReceipt?.phase,
      CreationCanvasHistoryCommitPhase.historyCommitted,
    );
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留状态并离开'));
    await tester.pumpAndSettle();
    harness.router.go('/canvas?initialNoteId=unrelated-entry');
    await tester.pumpAndSettle();
    await _pumpUntilCanvasReady(tester);

    await tester.tap(find.text('继续提交'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(history.upsertCalls, 1);
    expect(find.textContaining('detail:manual-'), findsOneWidget);
    expect(delegate.load(), isNull);
  });

  testWidgets(
    'post-commit draft cleanup retries without saving the note twice',
    (tester) async {
      final notePort = _RecordingCanvasSynchronizingNotePort();
      final library = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        notePort: notePort,
        includeDemoFixtures: false,
        autoSyncOwnedChanges: true,
      );
      final delegate = _draftRepository();
      final repository = _FailingCanvasDraftClearStore(delegate);
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
        autoSyncOwnedChanges: true,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '已经提交、只待清理恢复记录的正文。');

      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();

      expect(library.notes, hasLength(1));
      final saved = library.notes.single;
      final savedRevision = saved.localRevision;
      expect(repository.clearCalls, 1);
      expect(find.text('笔记已保存，本地草稿记录待清理'), findsWidgets);
      expect(find.text('完成清理'), findsOneWidget);
      expect(find.textContaining('detail:'), findsNothing);
      expect(notePort.requests, hasLength(1));
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey<String>('canvas-save-indicator')),
            )
            .label,
        '待完成保存',
      );
      expect(_bodyController(tester).readOnly, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('canvas-save')),
          matching: find.text('继续'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();

      expect(find.text('detail:${saved.id}'), findsOneWidget);
      expect(library.notes, hasLength(1));
      expect(library.notes.single.id, saved.id);
      expect(library.notes.single.localRevision, savedRevision);
      expect(notePort.requests, hasLength(1));
      expect(repository.clearCalls, 2);
      expect(delegate.load(), isNull);
    },
  );

  testWidgets(
    'saving blocks the dirty discard flow until persistence finishes',
    (tester) async {
      final cache = _BlockingCanvasKnowledgeCache();
      final repository = _draftRepository();
      final library = KnowledgeLibraryController(
        notePort: const _CanvasSynchronizingNotePort(),
        initialNotes: const [],
        cache: cache,
      );
      await library.initialize();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        library: library,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '保存中的正文不能被误判为已放弃。');

      await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认保存'));
      await tester.pump();
      await cache.saveStarted.future;
      expect(find.text('保存中'), findsOneWidget);
      final prepared = repository.load()!;
      expect(
        prepared.historyCommitReceipt?.phase,
        CreationCanvasHistoryCommitPhase.prepared,
      );
      expect(prepared.boundNoteId, isNull);
      expect(prepared.historyCommitReceipt?.noteId, startsWith('manual-'));

      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      expect(find.text('离开自由创作？'), findsNothing);
      expect(find.text('正在保存，请稍候'), findsOneWidget);

      cache.completeSave();
      await tester.pumpAndSettle();
      expect(find.textContaining('detail:manual-'), findsOneWidget);
    },
  );

  testWidgets('backgrounding during discard cannot resurrect cleared draft', (
    tester,
  ) async {
    final delegate = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: '准备放弃的草稿',
          markdown: '这段内容在明确放弃后不能恢复。',
          revision: 1,
          createdAt: DateTime.utc(2026, 9, 4),
          updatedAt: DateTime.utc(2026, 9, 4),
        ),
      );
    final repository = _BlockingCanvasDraftClearStore(delegate);
    final activity = AppActivityCoordinator(binding: tester.binding)
      ..updateLifecycle(AppLifecycleState.resumed);
    addTearDown(activity.dispose);
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      additionalOverrides: <Override>[
        appActivityCoordinatorProvider.overrideWith((ref) => activity),
      ],
    );
    addTearDown(harness.dispose);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃并退出'));
    await tester.pump();
    await repository.cleared;
    expect(delegate.load(), isNull);

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(delegate.load(), isNull);

    repository.finishClear();
    await tester.pumpAndSettle();
    expect(delegate.load(), isNull);
  });

  testWidgets(
    'canvas chat sends a local snapshot and routes rewrites through Canvas AI',
    (tester) async {
      const original = '前段内容。后段内容。';
      const candidate = '经过需求深化的完整正文。';
      final chatApi = _CanvasChatApi();
      final library = KnowledgeLibraryController(initialNotes: const []);
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        library: library,
        chatApi: chatApi,
        aiPort: _DiffCanvasAiPort((_) => candidate),
      );
      addTearDown(harness.dispose);
      await _setBody(tester, original);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();
      expect(find.text('当前正文'), findsOneWidget);
      expect(find.text('需求深化'), findsOneWidget);
      final chatInput = find.byKey(const ValueKey<String>('canvas-chat-input'));
      final textField = tester.widget<TextField>(chatInput);
      expect(textField.minLines, 1);
      expect(textField.maxLines, V3ChatComposerMetrics.maxVisibleLines);
      await tester.enterText(chatInput, '请给出可执行的改写建议');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();

      expect(chatApi.sentAgentProfileIds, <String?>['self_media_creation']);
      expect(chatApi.sentContents, hasLength(1));
      expect(chatApi.sentContents.single, startsWith('范围约束：只基于本轮附带的当前创作文档回答'));
      expect(chatApi.sentContents.single, contains('请给出可执行的改写建议'));
      expect(chatApi.sentContents.single, contains('不要搜索、读取'));
      final context = chatApi.sentContexts.single!;
      expect(context.includeAccountProfile, isFalse);
      expect(context.localDraftSnapshot?.content, contains(original));
      expect(context.references, isEmpty);
      expect(library.notes, isEmpty);
      expect(_bodyText(tester), original);

      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-chat-rewrite-proposal')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
        findsOneWidget,
      );
      expect(_bodyText(tester), original);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-apply')));
      await tester.pumpAndSettle();
      expect(_bodyText(tester), candidate);
      expect(library.notes, isEmpty);
    },
  );

  testWidgets('canvas chat renders structured Assistant Markdown', (
    tester,
  ) async {
    const assistantMarkdown =
        '## 核心结论\n\n'
        '> 先验证一线价值。\n\n'
        '- **记录**基线\n\n'
        '| 阶段 | 负责人 |\n'
        '| --- | --- |\n'
        '| 调研 | 小周 |\n\n'
        '`关键指标`';
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: _CanvasChatApi(assistantText: assistantMarkdown),
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '用于对话的当前正文。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '请给我一个方案',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey<String>(
          'canvas-chat-assistant-markdown-canvas-assistant-1',
        ),
      ),
      findsOneWidget,
    );
    for (final text in <String>['核心结论', '先验证一线价值。', '记录', '负责人']) {
      expect(find.textContaining(text), findsAtLeastNWidgets(1));
    }
    expect(find.byType(Table), findsOneWidget);
    expect(find.textContaining('## 核心结论'), findsNothing);
    expect(find.textContaining('**记录**'), findsNothing);
  });

  testWidgets('canvas chat renders Agent Run deltas as they arrive', (
    tester,
  ) async {
    const agentRunId = 'agent_run_canvas_stream_1';
    final api = _CanvasChatApi(agentRunId: agentRunId);
    late final _CanvasSseTracker tracker;
    tracker = _CanvasSseTracker(
      onTrack:
          ({
            required agentRunId,
            required threadId,
            required scene,
            required purpose,
          }) {
            tracker.publish(
              agentRunId: agentRunId,
              threadId: threadId,
              scene: scene,
              purpose: purpose,
              deltaText: '第一段',
              replace: true,
            );
          },
    );
    final chatController = ChatController(
      api: api,
      scene: ChatScene.workAi,
      runTracker: tracker,
      coalescedStreamingUi: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: api,
      chatController: chatController,
    );
    addTearDown(harness.dispose);
    addTearDown(tracker.dispose);
    await _setBody(tester, '用于流式对话的当前正文。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '请分段回答',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(find.text('第一段'), findsOneWidget);
    expect(find.byTooltip('复制'), findsNothing);
    var controllerNotifications = 0;
    chatController.addListener(() => controllerNotifications += 1);

    tracker.publish(
      agentRunId: agentRunId,
      threadId: 'canvas-thread-1',
      scene: ChatScene.workAi,
      purpose: ChatConversationPurpose.general,
      deltaText: '\n\n  - 第二段  ',
    );
    await tester.pump();

    final markdown = tester.widget<V3AssistantReplyMarkdown>(
      find.byKey(
        const ValueKey<String>(
          'canvas-chat-assistant-markdown-stream-agent_run_canvas_stream_1',
        ),
      ),
    );
    expect(markdown.source, '第一段\n\n  - 第二段  ');
    expect(controllerNotifications, 0);
    expect(find.byTooltip('复制'), findsNothing);
  });

  testWidgets('canvas chat retains its scoped conversation when reopened', (
    tester,
  ) async {
    final chatApi = _CanvasChatApi();
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: chatApi,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '需要持续讨论的当前正文。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '先给出第一轮建议',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('这是可执行的改写建议。'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();

    expect(find.text('这是可执行的改写建议。'), findsOneWidget);
    expect(chatApi.sentContents, hasLength(1));
    expect(chatApi.sentAgentProfileIds, <String?>['self_media_creation']);
  });

  testWidgets('pending chat does not lock Save or editing mode', (
    tester,
  ) async {
    final sendGate = Completer<void>();
    addTearDown(() {
      if (!sendGate.isCompleted) sendGate.complete();
    });
    final chatApi = _CanvasChatApi(sendGate: sendGate);
    final library = KnowledgeLibraryController(
      initialNotes: const [],
      notePort: const _CanvasSynchronizingNotePort(),
      includeDemoFixtures: false,
    );
    final repository = _draftRepository();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      chatApi: chatApi,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '等待聊天时仍可继续编辑的正文。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '给出一版尚未完成的改写建议',
    );
    await tester.tap(find.byTooltip('发送'));
    await _pumpUntil(tester, () => chatApi.sentContents.isNotEmpty);
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-close')));
    await tester.pumpAndSettle();

    final pending = repository.load();
    expect(pending, isNotNull);
    expect(pending!.chatRewriteReceipts, hasLength(1));
    expect(pending.chatRewriteReceipts.single.assistantMessageId, isNull);
    expect(_bodyController(tester).readOnly, isFalse);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey<String>('canvas-save')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<V3CanvasEditingModeSwitch>(
            find.byType(V3CanvasEditingModeSwitch),
          )
          .onChanged,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-action-list')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-edit-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('canvas-text-style')));
    await tester.pumpAndSettle();
    final linkButton = find.ancestor(
      of: find.byTooltip('链接'),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(linkButton).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-close')));
    await tester.pumpAndSettle();

    await _setBody(tester, '聊天返回前发生变化、稍后应判 stale 的正文。');
    await tester.pump(const Duration(milliseconds: 810));
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(library.notes, hasLength(1));
    expect(library.notes.single.rawBody, contains('稍后应判 stale'));
    expect(find.text('detail:${library.notes.single.id}'), findsOneWidget);

    sendGate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'accepted chat turn keeps its rewrite baseline after panel dismissal',
    (tester) async {
      final sendGate = Completer<void>();
      final chatApi = _CanvasChatApi(sendGate: sendGate);
      final chatController = ChatController(
        api: chatApi,
        scene: ChatScene.workAi,
      );
      addTearDown(chatController.dispose);
      final repository = _draftRepository();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        chatApi: chatApi,
        chatController: chatController,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '关闭弹层后仍需保留本轮冻结正文。');

      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('canvas-chat-input')),
        '给出一版改写建议',
      );
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      expect(chatApi.sentContents, hasLength(1));
      final pendingReceipt = repository.load()!.chatRewriteReceipts.single;
      expect(pendingReceipt.assistantMessageId, isNull);
      expect(pendingReceipt.userMessageId, startsWith('local-'));
      expect(pendingReceipt.requestText, chatApi.sentContents.single);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-close')));
      await tester.pumpAndSettle();
      sendGate.complete();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();
      expect(find.text('这是可执行的改写建议。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('canvas-chat-rewrite-proposal')),
        findsOneWidget,
      );
    },
  );

  testWidgets('canvas chat persists Thread and keys before message POST', (
    tester,
  ) async {
    final delegate = _draftRepository();
    final repository = _CanvasChatCheckpointDraftStore(delegate);
    final chatApi = _CanvasChatApi();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      chatApi: chatApi,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '消息发送前必须先锁存恢复身份。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '检查发送顺序',
    );
    await tester.tap(find.byTooltip('发送'));
    await _pumpUntil(tester, () => repository.checkpointStarted.isCompleted);

    expect(chatApi.createIdempotencies, hasLength(1));
    expect(chatApi.sentContents, isEmpty);
    final checkpoint = repository.checkpointDraft!;
    final pending = checkpoint.chatRewriteReceipts.singleWhere(
      (receipt) => receipt.assistantMessageId == null,
    );
    expect(pending.threadId, 'canvas-thread-1');
    expect(
      pending.submissionPhase,
      CreationCanvasChatSubmissionPhase.submitting,
    );
    expect(
      chatApi.createIdempotencies.single.explicitKey,
      pending.createThreadIdempotencyKey,
    );

    repository.releaseCheckpoint();
    await tester.pumpAndSettle();

    expect(chatApi.sentContents, hasLength(1));
    expect(
      chatApi.messageIdempotencies.single.explicitKey,
      pending.messageIdempotencyKey,
    );
  });

  testWidgets(
    'restored ambiguous Chat receipt is discarded without locking the editor',
    (tester) async {
      const source = '恢复后仍需正常编辑的正文。';
      final repository = _draftRepository()
        ..upsert(
          CreationCanvasDraft(
            title: '恢复过期聊天状态',
            markdown: source,
            sessionId: 'canvas-session-stale-chat',
            entryIdentity: const CanvasEntryIntent.blank().stableSourceId,
            chatThreadId: 'thread-stale-chat',
            chatRewriteReceipts: <CreationCanvasChatRewriteReceipt>[
              CreationCanvasChatRewriteReceipt(
                threadId: 'thread-stale-chat',
                userMessageId: 'local-stale-chat-message',
                agentRunId: 'agent-run-stale-chat',
                submissionPhase: CreationCanvasChatSubmissionPhase.submitting,
                rangeStart: 0,
                rangeEnd: source.length,
                sourceMarkdown: source,
                sourceHash: scriptDraftContentHash(source),
                documentHash: scriptDraftContentHash('document:$source'),
                documentRevision: 2,
                selectionScoped: false,
                requestText: '已经无法与控制器对账的请求',
              ),
            ],
            revision: 2,
            createdAt: DateTime.utc(2026, 9, 14, 8),
            updatedAt: DateTime.utc(2026, 9, 14, 9),
          ),
        );
      final harness = await _pumpCanvas(tester, repository: repository);
      addTearDown(harness.dispose);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('canvas-chat-pending-status')),
        findsNothing,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey<String>('canvas-save')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<V3CanvasEditingModeSwitch>(
              find.byType(V3CanvasEditingModeSwitch),
            )
            .onChanged,
        isNotNull,
      );
      await _pumpUntil(
        tester,
        () => repository.load()!.chatRewriteReceipts.isEmpty,
      );
    },
  );

  testWidgets(
    'restored prepared canvas chat turn can end without a controller row',
    (tester) async {
      final repository = _draftRepository();
      const source = '等待发送的创作聊天上下文。';
      final receipt = CreationCanvasChatRewriteReceipt(
        userMessageId: 'local-restored-prepared-turn',
        submissionPhase: CreationCanvasChatSubmissionPhase.prepared,
        rangeStart: 0,
        rangeEnd: source.length,
        sourceMarkdown: source,
        sourceHash: scriptDraftContentHash(source),
        documentHash: scriptDraftContentHash('document:$source'),
        documentRevision: 4,
        selectionScoped: false,
        requestText: '请继续分析这段正文',
      );
      repository.upsert(
        CreationCanvasDraft(
          title: '恢复创作聊天',
          markdown: source,
          sessionId: 'canvas-session-restored-prepared',
          entryIdentity: const CanvasEntryIntent.blank().stableSourceId,
          chatRewriteReceipts: <CreationCanvasChatRewriteReceipt>[receipt],
          revision: 4,
          createdAt: DateTime.utc(2026, 9, 5, 8),
          updatedAt: DateTime.utc(2026, 9, 5, 9),
        ),
      );
      final chatApi = _CanvasChatApi();
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        chatApi: chatApi,
      );
      addTearDown(harness.dispose);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('canvas-chat-abandon')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-chat-abandon')),
      );
      await tester.pumpAndSettle();

      expect(chatApi.sentContents, isEmpty);
      expect(
        repository.load()?.chatRewriteReceipts ??
            const <CreationCanvasChatRewriteReceipt>[],
        isEmpty,
      );
    },
  );

  testWidgets(
    'restored prepared canvas proof can end its orphaned controller row',
    (tester) async {
      const threadId = 'canvas-restored-rejected-thread';
      const userMessageId = 'local-canvas-restored-rejected-message';
      const source = '明确拒绝后的创作聊天上下文。';
      final database = AppDatabase();
      final aliasRepository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'canvas-restored-rejected-user',
      );
      const thread = ChatThread(
        threadId: threadId,
        scene: ChatScene.workAi,
        title: '恢复的创作聊天',
        agentProfileId: standardCreationChatAgentProfileId,
      );
      const pendingMessage = ChatMessage(
        messageId: userMessageId,
        threadId: threadId,
        scene: ChatScene.workAi,
        role: ChatMessageRole.user,
        contentType: ChatMessageContentType.text,
        status: 'pending',
        textPreview: '请继续分析这段正文',
        localDelivery: ChatLocalDeliveryState.pending,
      );
      expect(
        await aliasRepository.saveConversationCacheDurably(
          scene: ChatScene.workAi,
          purpose: ChatConversationPurpose.general,
          agentProfileId: standardCreationChatAgentProfileId,
          threads: const <ChatThread>[thread],
          messagesByThread: const <String, List<ChatMessage>>{
            threadId: <ChatMessage>[pendingMessage],
          },
        ),
        isTrue,
      );
      final chatApi = _CanvasChatApi();
      final chatController = ChatController(
        api: chatApi,
        scene: ChatScene.workAi,
        aliasRepository: aliasRepository,
        agentScope: const ChatAgentScope.fixed(
          standardCreationChatAgentProfileId,
        ),
      );
      addTearDown(chatController.dispose);
      final repository = _draftRepository();
      final receipt = CreationCanvasChatRewriteReceipt(
        threadId: threadId,
        userMessageId: userMessageId,
        submissionPhase: CreationCanvasChatSubmissionPhase.prepared,
        rangeStart: 0,
        rangeEnd: source.length,
        sourceMarkdown: source,
        sourceHash: scriptDraftContentHash(source),
        documentHash: scriptDraftContentHash('document:$source'),
        documentRevision: 4,
        selectionScoped: false,
        requestText: '请继续分析这段正文',
      );
      repository.upsert(
        CreationCanvasDraft(
          title: '恢复创作聊天',
          markdown: source,
          sessionId: 'canvas-session-restored-rejected',
          entryIdentity: const CanvasEntryIntent.blank().stableSourceId,
          chatThreadId: threadId,
          chatRewriteReceipts: <CreationCanvasChatRewriteReceipt>[receipt],
          revision: 4,
          createdAt: DateTime.utc(2026, 9, 5, 8),
          updatedAt: DateTime.utc(2026, 9, 5, 9),
        ),
      );
      final harness = await _pumpCanvas(
        tester,
        repository: repository,
        chatApi: chatApi,
        chatController: chatController,
        userScope: 'canvas-restored-rejected-user',
      );
      addTearDown(harness.dispose);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();

      expect(chatController.state.messages.single.messageId, userMessageId);
      expect(
        chatController.canAbandonFailedTextMessage(userMessageId),
        isFalse,
      );
      expect(
        find.byKey(const ValueKey<String>('canvas-chat-abandon')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-chat-abandon')),
      );
      await tester.pumpAndSettle();

      expect(chatApi.sentContents, isEmpty);
      expect(chatController.state.messages, isEmpty);
      expect(
        repository.load()?.chatRewriteReceipts ??
            const <CreationCanvasChatRewriteReceipt>[],
        isEmpty,
      );
    },
  );

  testWidgets('failed durable chat end keeps its prepared Canvas receipt', (
    tester,
  ) async {
    final queue = DatabaseWriteQueue();
    final database = AppDatabase();
    final aliasRepository = ChatThreadAliasRepository(
      dao: UserMetadataDao(database),
      preferencesDao: AppPreferencesDao(
        database,
        worker: const _FailingCanvasChatCacheWorker(),
        writeQueue: queue,
      ),
      userScope: 'canvas-chat-end-failure-user',
    );
    addTearDown(() async {
      try {
        await queue.dispose();
      } catch (_) {}
    });
    final chatApi = _CanvasChatApi(
      sendResult: ApiResult<ChatTextMutation>.failure(
        error: const AppFailure(
          code: 'CHAT_REQUEST_REJECTED',
          category: AppFailureCategory.api,
          message: 'known rejected',
          userMessageKey: 'chat.test.known_rejected',
        ),
        status: 422,
        idempotencyStore: SubmissionKeyStore.empty,
      ),
    );
    final chatController = ChatController(
      api: chatApi,
      scene: ChatScene.workAi,
      aliasRepository: aliasRepository,
    );
    addTearDown(chatController.dispose);
    final repository = _draftRepository();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      chatApi: chatApi,
      chatController: chatController,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '结束失败时必须保留可恢复的聊天回执。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '这次请求会被明确拒绝',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final failedId = repository
        .load()!
        .chatRewriteReceipts
        .single
        .userMessageId;

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-abandon')));
    await tester.pumpAndSettle();

    final retained = repository.load()!.chatRewriteReceipts.single;
    expect(retained.userMessageId, failedId);
    expect(
      retained.submissionPhase,
      CreationCanvasChatSubmissionPhase.prepared,
    );
    expect(chatController.canAbandonFailedTextMessage(failedId), isTrue);
    expect(
      find.byKey(const ValueKey<String>('canvas-chat-abandon')),
      findsOneWidget,
    );
  });

  testWidgets('pending chat does not block a replacement Agent entry', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'clean-bound-pending-chat-note',
      title: '已保存正文',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 5),
      rawBody: '这份正文已经保存，但聊天仍在进行。',
      contentOrigin: V3ContentOrigin.freeCreation,
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: const _CanvasSynchronizingNotePort(),
      includeDemoFixtures: false,
    );
    final sendGate = Completer<void>();
    addTearDown(() {
      if (!sendGate.isCompleted) sendGate.complete();
    });
    final chatApi = _CanvasChatApi(sendGate: sendGate);
    final scriptPort = _SuccessfulScriptDraftPort(
      finalMarkdown: '新的 Agent 创作正文',
    );
    final repository = _draftRepository();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      chatApi: chatApi,
      scriptDraftPort: scriptPort,
      location: '/canvas?historyId=history-${note.id}',
      historyPort: _historyForNote(note),
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '仍在等待的建议',
    );
    await tester.tap(find.byTooltip('发送'));
    await _pumpUntil(tester, () => chatApi.sentContents.isNotEmpty);
    expect(
      find.byKey(const ValueKey<String>('canvas-chat-abandon')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-close')));
    await tester.pumpAndSettle();

    final seed = AssetCanvasSeed.tryFromItem(
      item: note,
      stage: V3ContentStage.raw,
    )!.withInitialSourceMode(AssetCanvasInitialSourceMode.generateTranscript);
    harness.router.go('/canvas', extra: CanvasEntryIntent.asset(seed));
    await tester.pump();
    await _pumpUntilAsync(tester, () => scriptPort.requests.isNotEmpty);
    await _pumpUntilAsync(tester, () => library.notes.length == 2);
    await tester.pumpAndSettle();

    expect(find.text('已有未完成创作'), findsNothing);
    expect(_bodyText(tester), '新的 Agent 创作正文');
    expect(library.noteForId(note.id)?.rawBody, note.rawBody);
    expect(
      library.notes.singleWhere((item) => item.id != note.id).rawBody,
      '新的 Agent 创作正文',
    );

    sendGate.complete();
    await tester.pumpAndSettle();
    expect(_bodyText(tester), '新的 Agent 创作正文');
    expect(repository.load(), isNull);
  });

  testWidgets(
    'fresh Canvas completes deferred chat reset after its panel closes',
    (tester) async {
      final sendGate = Completer<void>();
      final chatApi = _CanvasChatApi(sendGate: sendGate);
      final chatController = ChatController(
        api: chatApi,
        scene: ChatScene.workAi,
      );
      addTearDown(chatController.dispose);
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        chatApi: chatApi,
        chatController: chatController,
      );
      addTearDown(harness.dispose);
      await _setBody(tester, '新创作会话不应继承其他页面的旧聊天。');

      final oldSend = chatController.sendText('旧页面仍在提交的消息');
      await tester.pump();
      await tester.pump();
      expect(chatApi.sentContents, <String>['旧页面仍在提交的消息']);
      expect(chatController.state.isSending, isTrue);

      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-close')));
      await tester.pumpAndSettle();
      sendGate.complete();
      expect(await oldSend, isTrue);
      await tester.pumpAndSettle();

      expect(chatController.state.activeThreadId, isNull);
      expect(chatController.state.messages, isEmpty);
      await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
      await tester.pumpAndSettle();
      expect(find.text('旧页面仍在提交的消息'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey<String>('canvas-chat-send')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('Canvas chat task navigation honors continue editing', (
    tester,
  ) async {
    final chatApi = _CanvasChatApi(
      nextAction: const ChatNextAction(
        type: ChatNextActionType.openTaskPanel,
        taskId: 'canvas-task-1',
      ),
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: chatApi,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '任务导航前仍未保存的正文。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '创建一个后续任务',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看任务'));
    await tester.pumpAndSettle();

    expect(find.text('继续编辑'), findsOneWidget);
    expect(find.text('task:canvas-task-1'), findsNothing);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(V3CreationCanvasPage), findsOneWidget);
    expect(find.text('task:canvas-task-1'), findsNothing);
  });

  testWidgets('selected chat rewrite uses local Canvas diff and can reject', (
    tester,
  ) async {
    const selected = '中间旧句';
    const original = '开头保留。$selected，结尾保留。\n下一段也保留。';
    final selectedStart = original.indexOf(selected);
    final chatApi = _CanvasChatApi();
    final aiPort = _CapturingCanvasAiPort();
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: chatApi,
      aiPort: aiPort,
    );
    addTearDown(harness.dispose);
    final selection = TextSelection(
      baseOffset: selectedStart,
      extentOffset: selectedStart + selected.length,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-title-field')),
      '局部改写标题',
    );
    await _setBody(tester, original, selection: selection);
    _bodyEditor(tester).focusNode.requestFocus();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    expect(_bodyController(tester).selection, selection);
    expect(find.text('当前选中文字'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '请改写得更清晰',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('canvas-chat-input')),
          )
          .controller
          ?.text,
      isEmpty,
    );
    expect(chatApi.sentContents.single, contains('请改写得更清晰'));
    expect(chatApi.sentContents.single, isNot(contains('选中内容：')));
    expect(chatApi.sentContents.single, isNot(contains(selected)));
    expect(chatApi.sentContents.single.length, lessThanOrEqualTo(4000));
    final snapshot = chatApi.sentContexts.single?.localDraftSnapshot;
    expect(snapshot?.content, contains('## 当前选中文字（仅改写该范围）'));
    expect(snapshot?.content, contains('# 局部改写标题'));
    expect(snapshot?.content, contains(selected));
    expect(snapshot?.content, contains('## 所在段落（仅供理解）'));
    expect(snapshot?.content, contains('开头保留。$selected，结尾保留。'));
    expect(snapshot?.content, isNot(contains('下一段也保留。')));
    expect(snapshot?.kind, 'creation_canvas');
    expect(snapshot?.revision, startsWith('revision-'));
    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-chat-rewrite-proposal')),
    );
    await tester.pumpAndSettle();
    expect(aiPort.requests.single.targetMarkdown.trimRight(), selected);
    expect(aiPort.requests.single.targetMarkdown, isNot(contains('开头保留')));
    expect(aiPort.requests.single.targetMarkdown, isNot(contains('结尾保留')));
    expect(aiPort.requests.single.targetRange.start, 0);
    expect(
      aiPort.requests.single.targetRange.end,
      aiPort.requests.single.targetMarkdown.length,
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-ai-diff-preview')),
      findsOneWidget,
    );
    expect(_bodyText(tester), original);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-reject')));
    await tester.pumpAndSettle();
    expect(_bodyText(tester), original);
  });

  testWidgets('stale selected chat rewrite cannot start Canvas AI', (
    tester,
  ) async {
    final aiPort = _CapturingCanvasAiPort();
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: _CanvasChatApi(),
      aiPort: aiPort,
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '需要改写的段落。',
      selection: const TextSelection(baseOffset: 0, extentOffset: 7),
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '换一种表达',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    _bodyController(
      tester,
    ).replaceText(0, 0, '新增内容', const TextSelection.collapsed(offset: 4));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-chat-rewrite-proposal')),
    );
    await tester.pumpAndSettle();
    expect(_bodyText(tester), startsWith('新增内容需要改写的段落。'));
    expect(aiPort.requests, isEmpty);
    expect(find.text('正文已变化，请重新发问后再生成修改'), findsOneWidget);
  });

  testWidgets('canvas chat sends without creating or synchronizing an asset', (
    tester,
  ) async {
    final chatApi = _CanvasChatApi();
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      chatApi: chatApi,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '这段正文尚未同步。');

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-chat-input')),
      '请给出改写建议',
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(chatApi.sentContents, hasLength(1));
    expect(
      chatApi.sentContexts.single?.localDraftSnapshot?.content,
      contains('这段正文尚未同步。'),
    );
    expect(library.notes, isEmpty);
  });

  testWidgets('verified save records one user-scoped creation history', (
    tester,
  ) async {
    final history = InMemoryCreationCanvasHistoryPort();
    final library = KnowledgeLibraryController(initialNotes: const []);
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      historyPort: history,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '会进入创作历史的正文');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    final entry = history.list('test-user').single;
    final saved = library.notes.single;
    expect(entry.noteId, saved.id);
    expect(entry.id, saved.id);
    expect(entry.markdown, contains('会进入创作历史的正文'));
    expect(entry.documentJson, isNotEmpty);
  });

  testWidgets('top overflow owns creation history and new draft commands', (
    tester,
  ) async {
    final harness = await _pumpCanvas(tester, repository: _draftRepository());
    addTearDown(harness.dispose);

    expect(
      find.byKey(const ValueKey<String>('canvas-new-draft')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('canvas-more-actions')));
    await tester.pumpAndSettle();
    expect(find.text('创作历史'), findsOneWidget);
    expect(find.text('新建笔记'), findsOneWidget);

    await tester.tap(find.text('创作历史'));
    await tester.pumpAndSettle();
    expect(find.text('创作历史页'), findsOneWidget);
  });

  testWidgets(
    'new draft reset locks interactions and preserves a late clear mutation',
    (tester) async {
      final delegate = _draftRepository();
      final repository = _BlockingCanvasDraftClearStore(delegate);
      addTearDown(repository.finishClear);
      final harness = await _pumpCanvas(tester, repository: repository);
      addTearDown(harness.dispose);
      await _setBody(tester, '新建前必须保护的正文');

      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-more-actions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建笔记'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃当前内容并新建'));
      await tester.pump();
      await repository.cleared;
      await tester.pump();

      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('canvas-title-field')),
            )
            .readOnly,
        isTrue,
      );
      expect(_bodyController(tester).readOnly, isTrue);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey<String>('canvas-save')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      expect(find.text('离开自由创作？'), findsNothing);
      expect(find.text('正在确认草稿状态，请稍候'), findsOneWidget);

      final body = _bodyController(tester);
      const lateText = '，清理期间的晚到修改';
      final insertionOffset = body.document.length - 1;
      body.replaceText(
        insertionOffset,
        0,
        lateText,
        TextSelection.collapsed(offset: insertionOffset + lateText.length),
      );
      await tester.pump();
      repository.finishClear();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('canvas-body-field')),
        findsOneWidget,
      );
      expect(_bodyText(tester), contains(lateText));
      expect(delegate.load()?.markdown, contains(lateText));
      expect(find.textContaining('内容在离开过程中发生变化'), findsOneWidget);
    },
  );

  testWidgets('opening history releases Canvas realtime voice ownership', (
    tester,
  ) async {
    final recorder = _CanvasLiveRecorder();
    final asr = _CanvasLiveAsrPort();
    final liveTranscript = LiveTranscriptController(
      credentialPort: const _CanvasLiveCredentialPort(),
      asrPort: asr,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: const Size(800, 852),
      additionalOverrides: <Override>[
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
    final canvasRoute =
        ModalRoute.of(tester.element(find.byType(V3CreationCanvasPage)))!
            as PageRoute<dynamic>;
    expect(appRouteObserver.debugObservingRoute(canvasRoute), isTrue);

    await tester.tap(
      find.byKey(const ValueKey<String>('canvas-voice-dictation')),
    );
    await tester.pump();
    await tester.pump();
    expect(recorder.startedScenes, <VoiceRecordingScene>[
      VoiceRecordingScene.monologue,
    ]);
    expect(liveTranscript.state.status, LiveTranscriptStatus.transcribing);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-more-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创作历史'));
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() async {
      for (
        var attempt = 0;
        attempt < 8 && recorder.cancelCalls == 0;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();

    expect(find.text('创作历史页'), findsOneWidget);
    expect(harness.router.canPop(), isFalse);
    expect(find.byType(V3CreationCanvasPage), findsNothing);
    expect(recorder.cancelCalls, 1);
    expect(liveTranscript.state.status, LiveTranscriptStatus.idle);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    liveTranscript.dispose();
    await asr.close();
  });

  testWidgets('opening history restores and updates the same knowledge note', (
    tester,
  ) async {
    final codec = CanvasDocumentCodec();
    final document = codec.documentFromMarkdown('历史正文');
    final history = InMemoryCreationCanvasHistoryPort()
      ..upsert(
        'test-user',
        CreationCanvasHistoryEntry(
          id: 'history-1',
          noteId: 'note-history-1',
          title: '历史标题',
          markdown: '历史正文',
          documentJson: codec.encodeDocumentJson(document),
          documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
          revision: 2,
          createdAt: DateTime.utc(2026, 7, 20),
          updatedAt: DateTime.utc(2026, 7, 21),
        ),
      );
    final library = KnowledgeLibraryController(
      initialNotes: [
        V3FeedItem(
          id: 'note-history-1',
          title: '历史标题',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 7, 20),
          rawBody: '历史正文',
        ),
      ],
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      historyPort: history,
      location: '/canvas?historyId=history-1',
    );
    addTearDown(harness.dispose);

    expect(find.text('历史标题'), findsOneWidget);
    expect(_bodyText(tester), '历史正文');
    await _setBody(tester, '历史正文的更新版本');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(library.notes, hasLength(1));
    expect(library.notes.single.id, 'note-history-1');
    expect(library.notes.single.rawBody, contains('更新版本'));
    expect(history.list('test-user').single.id, 'history-1');
  });

  testWidgets('discarding bound edits keeps the last saved note version', (
    tester,
  ) async {
    final note = V3FeedItem(
      id: 'history-discard-note',
      title: '已保存标题',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 15),
      rawBody: '资产中已经保存的正文',
      remoteNoteId: 'remote-history-discard-note',
      rawPartRevisionId: 'raw-history-discard-note-1',
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[note],
      notePort: const _CanvasSynchronizingNotePort(),
      includeDemoFixtures: false,
    );
    final repository = _draftRepository();
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
      location: '/canvas?historyId=history-${note.id}',
      historyPort: _historyForNote(note),
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    await _setBody(tester, '这次编辑决定不保存');
    expect(find.text('修改未保存'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.text('保存到资产'), findsOneWidget);
    expect(find.text('不保存并退出'), findsOneWidget);
    expect(find.text('继续编辑'), findsOneWidget);
    expect(find.text('保留草稿并退出'), findsNothing);

    await tester.tap(find.text('不保存并退出'));
    await tester.pumpAndSettle();

    expect(find.text('创作空间'), findsOneWidget);
    expect(library.noteForId(note.id)?.rawBody, '资产中已经保存的正文');
    expect(repository.load(), isNull);
  });

  testWidgets('bound history keeps current linked-material metadata on save', (
    tester,
  ) async {
    const oldReference = V3LinkedMaterialRef(
      id: 'linked-note-1',
      source: V3MaterialSource.note,
      title: '旧引用标题',
      summary: '旧引用摘要',
    );
    const currentReference = V3LinkedMaterialRef(
      id: 'linked-note-1',
      source: V3MaterialSource.note,
      title: '最新引用标题',
      summary: '最新引用摘要',
    );
    final codec = CanvasDocumentCodec();
    final history = InMemoryCreationCanvasHistoryPort();
    await history.upsert(
      'test-user',
      CreationCanvasHistoryEntry(
        id: 'history-link-metadata',
        noteId: 'note-link-metadata',
        title: '历史绑定标题',
        markdown: '历史绑定正文',
        documentJson: codec.encodeDocumentJson(
          codec.documentFromMarkdown('历史绑定正文'),
        ),
        documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
        revision: 1,
        createdAt: DateTime.utc(2026, 9, 4),
        updatedAt: DateTime.utc(2026, 9, 4),
        linkedMaterials: const <V3LinkedMaterialRef>[oldReference],
      ),
    );
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'note-link-metadata',
          title: '历史绑定标题',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 9, 4),
          rawBody: '历史绑定正文',
          linkedMaterials: const <V3LinkedMaterialRef>[currentReference],
        ),
      ],
      includeDemoFixtures: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      historyPort: history,
      location: '/canvas?historyId=history-link-metadata',
    );
    addTearDown(harness.dispose);
    await _pumpUntilCanvasReady(tester);

    await _setBody(tester, '历史绑定正文的新版本');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅更新这篇笔记的原始内容'), findsOneWidget);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    final savedReference = library
        .noteForId('note-link-metadata')!
        .linkedMaterials
        .single;
    expect(savedReference.title, currentReference.title);
    expect(savedReference.summary, currentReference.summary);
    expect(
      history.list('test-user').single.linkedMaterials.single.title,
      currentReference.title,
    );
  });

  testWidgets('history binding waits for cold Knowledge cache restore', (
    tester,
  ) async {
    final codec = CanvasDocumentCodec();
    final note = V3FeedItem(
      id: 'cold-history-note',
      title: '冷启动历史',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 4),
      rawBody: '历史缓存正文',
    );
    final history = InMemoryCreationCanvasHistoryPort();
    await history.upsert(
      'test-user',
      CreationCanvasHistoryEntry(
        id: 'cold-history-entry',
        noteId: note.id,
        title: note.title,
        markdown: note.rawBody,
        documentJson: codec.encodeDocumentJson(
          codec.documentFromMarkdown(note.rawBody),
        ),
        documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
        revision: 1,
        createdAt: note.createdAt,
        updatedAt: note.createdAt,
      ),
    );
    final cache = _GatedCanvasKnowledgeCache(<V3FeedItem>[note]);
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      cache: cache,
      includeDemoFixtures: false,
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      historyPort: history,
      location: '/canvas?historyId=cold-history-entry',
    );
    addTearDown(harness.dispose);

    expect(
      find.byKey(const ValueKey<String>('canvas-body-field')),
      findsNothing,
    );
    cache.releaseLoad();
    await _pumpUntilCanvasReady(tester);
    await _setBody(tester, '历史缓存正文的新版本');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('仅更新这篇笔记的原始内容'), findsOneWidget);
  });

  testWidgets('changed restored history draft stays bound and cannot clone', (
    tester,
  ) async {
    final repository = _draftRepository()
      ..upsert(
        CreationCanvasDraft(
          title: '历史笔记',
          markdown: '尚未保存的修改',
          boundNoteId: 'history-bound-note',
          boundAssetFingerprint: 'old-base-fingerprint',
          entryIdentity: 'history:history-bound-entry',
          revision: 3,
          createdAt: DateTime.utc(2026, 7, 20),
          updatedAt: DateTime.utc(2026, 7, 21),
        ),
      );
    final library = KnowledgeLibraryController(
      initialNotes: [
        V3FeedItem(
          id: 'history-bound-note',
          title: '历史笔记',
          rawBody: '其他位置更新的正文',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 7, 20),
        ),
      ],
    );
    final harness = await _pumpCanvas(
      tester,
      repository: repository,
      library: library,
    );
    addTearDown(harness.dispose);
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续上次创作'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不会另建笔记或覆盖新版本'), findsOneWidget);
    expect(repository.load()?.boundNoteId, 'history-bound-note');
    expect(repository.load()?.markdown, '尚未保存的修改');
    expect(library.notes, hasLength(1));
    expect(library.notes.single.rawBody, '其他位置更新的正文');
  });

  testWidgets('changed history source updates current raw without cloning', (
    tester,
  ) async {
    final codec = CanvasDocumentCodec();
    final history = InMemoryCreationCanvasHistoryPort()
      ..upsert(
        'test-user',
        CreationCanvasHistoryEntry(
          id: 'history-stale-1',
          noteId: 'note-history-stale-1',
          title: '历史标题',
          markdown: '历史正文',
          documentJson: codec.encodeDocumentJson(
            codec.documentFromMarkdown('历史正文'),
          ),
          documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
          revision: 2,
          createdAt: DateTime.utc(2026, 7, 20),
          updatedAt: DateTime.utc(2026, 7, 21),
        ),
      );
    final library = KnowledgeLibraryController(
      notePort: const _CanvasSynchronizingNotePort(),
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'note-history-stale-1',
          title: '历史标题',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 7, 20),
          rawBody: '资产中更新后的正文',
          summaryBody: '保留原有纲要',
          localRevision: 4,
        ),
      ],
    );
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      library: library,
      historyPort: history,
      location: '/canvas?historyId=history-stale-1',
    );
    addTearDown(harness.dispose);

    expect(_bodyText(tester), '资产中更新后的正文');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('canvas-title-field')),
          )
          .readOnly,
      isTrue,
    );
    await _setBody(tester, '从历史稿继续形成的新正文');
    await tester.tap(find.byKey(const ValueKey<String>('canvas-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅更新这篇笔记的原始内容'), findsOneWidget);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(library.notes, hasLength(1));
    expect(library.notes.single.id, 'note-history-stale-1');
    expect(library.notes.single.rawBody, '从历史稿继续形成的新正文');
    expect(library.notes.single.summaryBody, '保留原有纲要');
    expect(history.list('test-user').single.noteId, 'note-history-stale-1');
  });

  testWidgets(
    'deleted history source blocks editing instead of creating a note',
    (tester) async {
      final codec = CanvasDocumentCodec();
      final history = InMemoryCreationCanvasHistoryPort()
        ..upsert(
          'test-user',
          CreationCanvasHistoryEntry(
            id: 'history-orphan-1',
            noteId: 'deleted-note-1',
            title: '已删除资产的历史稿',
            markdown: '仍可继续编辑的历史正文',
            documentJson: codec.encodeDocumentJson(
              codec.documentFromMarkdown('仍可继续编辑的历史正文'),
            ),
            documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
            revision: 1,
            createdAt: DateTime.utc(2026, 7, 20),
            updatedAt: DateTime.utc(2026, 7, 21),
          ),
        );
      final library = KnowledgeLibraryController(initialNotes: const []);
      final harness = await _pumpCanvas(
        tester,
        repository: _draftRepository(),
        library: library,
        historyPort: history,
        location: '/canvas?historyId=history-orphan-1',
      );
      addTearDown(harness.dispose);

      expect(find.textContaining('原笔记已不存在'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('canvas-body-field')),
        findsNothing,
      );
      expect(library.notes, isEmpty);
      expect(history.list('test-user'), hasLength(1));
    },
  );

  testWidgets('creation history page opens the selected rich canvas entry', (
    tester,
  ) async {
    final history = InMemoryCreationCanvasHistoryPort()
      ..upsert(
        'test-user',
        CreationCanvasHistoryEntry(
          id: 'history-page-1',
          noteId: 'note-page-1',
          title: '页面创作历史',
          markdown: '正文',
          documentJson: '[{"insert":"正文\\n"}]',
          documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
          revision: 1,
          createdAt: DateTime.utc(2026, 7, 20),
          updatedAt: DateTime.utc(2026, 7, 21),
        ),
      );
    final router = GoRouter(
      initialLocation: '/history',
      routes: [
        GoRoute(
          path: '/history',
          builder: (_, __) => const V3CreationHistoryPage(),
        ),
        GoRoute(
          path: '/v3/workbench/canvas',
          builder: (_, state) {
            final intent = state.extra! as CanvasHistoryEntryIntent;
            return Text('history:${intent.historyId}');
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...mobileAgentReadyTestOverrides(),
          resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
          authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
          creationCanvasHistoryPortProvider.overrideWithValue(history),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('页面创作历史'), findsOneWidget);
    await tester.tap(find.text('页面创作历史'));
    await tester.pumpAndSettle();
    expect(find.text('history:history-page-1'), findsOneWidget);
    expect(router.canPop(), isTrue);
  });

  testWidgets('creation history swipe cancels or confirms scoped deletion', (
    tester,
  ) async {
    final history = InMemoryCreationCanvasHistoryPort()
      ..upsert(
        'test-user',
        CreationCanvasHistoryEntry(
          id: 'history-swipe-1',
          noteId: 'note-swipe-1',
          title: '可以左滑删除的创作',
          markdown: '原文仍然保留。',
          documentJson: '[{"insert":"原文仍然保留。\\n"}]',
          documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
          revision: 1,
          createdAt: DateTime.utc(2026, 8, 20),
          updatedAt: DateTime.utc(2026, 8, 21),
        ),
      );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authenticatedUserDataScopeProvider.overrideWithValue('test-user'),
          creationCanvasHistoryPortProvider.overrideWithValue(history),
        ],
        child: const MaterialApp(home: V3CreationHistoryPage()),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(
      const ValueKey<String>('creation-history-history-swipe-1'),
    );
    await tester.drag(row, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('creation-history-delete-confirmation'),
      ),
      findsOneWidget,
    );
    expect(find.text('删除这篇创作？'), findsOneWidget);
    expect(find.textContaining('原文内容不会受到影响'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('creation-history-delete-cancel')),
    );
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    expect(history.list('test-user'), hasLength(1));

    await tester.drag(row, const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('creation-history-delete-confirm')),
    );
    await tester.pumpAndSettle();

    expect(row, findsNothing);
    expect(history.list('test-user'), isEmpty);
    expect(find.text('已删除创作历史'), findsOneWidget);
  });

  testWidgets('375x812 canvas remains stable at 1.3 text scale', (
    tester,
  ) async {
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      surfaceSize: const Size(375, 812),
      textScale: 1.3,
    );
    addTearDown(harness.dispose);
    await _setBody(tester, '较大文字下仍然可以编辑正文。');
    await tester.pump();

    expect(find.text('自由创作'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('canvas-markdown-toolbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-chat-entry')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark theme reaches canvas and Quill semantic styles', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: _CanvasChatApi(),
      surfaceSize: const Size(390, 844),
      theme: HuahuoV3Theme.dark(),
    );
    addTearDown(harness.dispose);
    await _setBody(
      tester,
      '暗黑主题正文',
      selection: const TextSelection.collapsed(offset: 4),
    );

    final body = _bodyEditor(tester);
    final styles = body.config.customStyles!;
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      HuahuoV3Theme.darkTokens.canvas,
    );
    expect(styles.paragraph?.style.color, HuahuoV3Theme.darkTokens.text);
    expect(styles.quote?.style.color, isNot(HuahuoV3Theme.lightTokens.ink));
    expect(
      styles.quote?.decoration?.color,
      HuahuoV3Theme.darkTokens.surfaceMuted,
    );
    expect(
      styles.code?.decoration?.color,
      HuahuoV3Theme.darkTokens.surfaceMuted,
    );
    expect(
      styles.inlineCode?.backgroundColor,
      HuahuoV3Theme.darkTokens.surfaceMuted,
    );
    expect(styles.placeHolder?.style.color, HuahuoV3Theme.darkTokens.muted);
    expect(styles.link?.color, HuahuoV3Theme.darkTokens.accent);
    expect(body.controller.selection.baseOffset, 4);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();
    expect(body.controller.selection, const TextSelection.collapsed(offset: 4));
    expect(find.text('当前正文'), findsOneWidget);
    final chatTitle = find.text('创作聊天');
    expect(chatTitle, findsOneWidget);
    expect(
      tester
          .widgetList<Material>(
            find.ancestor(of: chatTitle, matching: find.byType(Material)),
          )
          .any(
            (material) => material.color == HuahuoV3Theme.darkTokens.surface,
          ),
      isTrue,
    );
    final luminousEdge = find.byKey(
      const ValueKey<String>('canvas-chat-top-glow'),
    );
    expect(tester.getSize(luminousEdge).height, 12);
    final luminousSource = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey<String>('canvas-chat-top-glow-source')),
    );
    final luminousDecoration = luminousSource.decoration as BoxDecoration;
    final luminousGradient = luminousDecoration.gradient! as LinearGradient;
    expect(luminousGradient.colors, hasLength(3));
    expect(luminousGradient.colors.first, Colors.transparent);
    expect(
      luminousGradient.colors[1],
      HuahuoV3Theme.darkTokens.accent.withValues(alpha: .72),
    );
    expect(luminousGradient.colors.last, Colors.transparent);
    expect(luminousDecoration.boxShadow, hasLength(1));
    expect(find.byType(V3GlassBottomSheet), findsOneWidget);
    final dragHandle = find.byKey(
      const ValueKey('v3-glass-bottom-sheet-drag-handle'),
    );
    expect(dragHandle, findsOneWidget);
    expect(
      tester.getTopLeft(luminousEdge).dy,
      lessThan(tester.getTopLeft(dragHandle).dy),
    );
    expect(
      tester.getTopLeft(luminousEdge).dy,
      lessThan(tester.getTopLeft(chatTitle).dy),
    );
    expect(
      find.descendant(
        of: luminousEdge,
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
    );
    final chatInput = find.byKey(const ValueKey<String>('canvas-chat-input'));
    expect(chatInput, findsOneWidget);
    final send = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('canvas-chat-send')),
    );
    expect(
      send.style?.backgroundColor?.resolve(<WidgetState>{}),
      HuahuoV3Theme.darkTokens.accent,
    );
    expect(
      send.style?.foregroundColor?.resolve(<WidgetState>{}),
      HuahuoV3Theme.darkTokens.canvas,
    );
    await tester.enterText(chatInput, '继续完善这段内容');
    expect(find.text('继续完善这段内容'), findsOneWidget);
    expect(body.controller.selection, const TextSelection.collapsed(offset: 4));
  });

  testWidgets('wide canvas chat keeps standard motion durations', (
    tester,
  ) async {
    await _expectWideCanvasChatMotion(
      tester,
      disableAnimations: false,
      expectedDuration: const Duration(milliseconds: 180),
    );
  });

  testWidgets('canvas chat keeps primary controls above a landscape keyboard', (
    tester,
  ) async {
    const surfaceSize = Size(568, 320);
    const keyboardInset = 160.0;
    final harness = await _pumpCanvas(
      tester,
      repository: _draftRepository(),
      chatApi: _CanvasChatApi(),
      surfaceSize: surfaceSize,
      textScale: 1.3,
      viewInsets: const EdgeInsets.only(bottom: keyboardInset),
    );
    addTearDown(harness.dispose);

    await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey<String>('canvas-chat-input'));
    final send = find.byKey(const ValueKey<String>('canvas-chat-send'));
    final history = find.byKey(const ValueKey<String>('canvas-chat-history'));
    final close = find.byKey(const ValueKey<String>('canvas-chat-close'));
    expect(input, findsOneWidget);
    expect(send, findsOneWidget);
    expect(history, findsOneWidget);
    expect(close, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('canvas-chat-context-chip')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('canvas-chat-function-strip')),
      findsNothing,
    );

    final keyboardTop = surfaceSize.height - keyboardInset;
    for (final control in <Finder>[input, send, history, close]) {
      expect(tester.getTopLeft(control).dy, greaterThanOrEqualTo(0));
      expect(tester.getBottomRight(control).dy, lessThanOrEqualTo(keyboardTop));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide canvas chat disables motion for Reduce Motion', (
    tester,
  ) async {
    await _expectWideCanvasChatMotion(
      tester,
      disableAnimations: true,
      expectedDuration: Duration.zero,
    );
  });
}

Finder get _canvasBodyFinder => find.byKey(
  const ValueKey<String>('canvas-body-field'),
  skipOffstage: false,
);

Future<void> _tapCanvasPrimaryTool(WidgetTester tester, String key) async {
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
}

Future<void> _tapAiSkill(WidgetTester tester, String actionName) async {
  final action = CanvasAiAction.values.byName(actionName);
  await tester.tap(find.byKey(const ValueKey<String>('canvas-ai-tools')));
  await tester.pumpAndSettle();
  await _scrollCanvasAiActionIntoView(tester, action);
  final actionFinder = _canvasAiActionControl(action);
  expect(actionFinder, findsOneWidget);
  await tester.tap(actionFinder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 260));
}

Future<void> _scrollCanvasAiActionIntoView(
  WidgetTester tester,
  CanvasAiAction action,
) async {
  final sheetAction = find.byKey(
    ValueKey<String>('canvas-ai-action-${action.name}'),
  );
  await tester.scrollUntilVisible(
    sheetAction,
    180,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey<String>('canvas-ai-action-list')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _canvasAiActionControl(CanvasAiAction action) =>
    find.byKey(ValueKey<String>('canvas-ai-action-${action.name}'));

QuillEditor _bodyEditor(WidgetTester tester) =>
    tester.widget<QuillEditor>(_canvasBodyFinder);

QuillController _bodyController(WidgetTester tester) =>
    _bodyEditor(tester).controller;

String _bodyText(WidgetTester tester) => _bodyController(
  tester,
).document.toPlainText().replaceFirst(RegExp(r'\n$'), '');

InMemoryCreationCanvasHistoryPort _historyForNote(V3FeedItem note) {
  final codec = CanvasDocumentCodec();
  return InMemoryCreationCanvasHistoryPort()..upsert(
    'test-user',
    CreationCanvasHistoryEntry(
      id: 'history-${note.id}',
      noteId: note.id,
      title: note.title,
      markdown: note.rawBody,
      documentJson: codec.encodeDocumentJson(
        codec.documentFromMarkdown(note.rawBody),
      ),
      documentFormatVersion: CanvasDocumentCodec.documentFormatVersion,
      revision: note.localRevision,
      createdAt: note.createdAt,
      updatedAt: note.createdAt,
      linkedMaterials: note.linkedMaterials,
    ),
  );
}

String _canvasNoteFingerprintForTest(V3FeedItem note) => scriptDraftContentHash(
  jsonEncode(<String, Object?>{
    'id': note.id,
    'localRevision': note.localRevision,
    'title': note.title,
    'rawBody': note.rawBody,
    'linkedMaterials': <Map<String, Object?>>[
      for (final material in note.linkedMaterials)
        <String, Object?>{
          'id': material.id,
          'source': material.source.name,
          'title': material.title,
          'summary': material.summary,
        },
    ],
    'contentLineId': note.contentLineId,
    'contentLineName': note.contentLineName,
    'folderId': note.folderId,
    'folderName': note.folderName,
    'copiedFromContentId': note.copiedFromContentId,
    'publicUrl': note.publicUrl,
    'contentOrigin': note.contentOrigin.name,
    'topics': note.topics,
  }),
);

Future<void> _setBody(
  WidgetTester tester,
  String text, {
  TextSelection? selection,
}) async {
  final controller = _bodyController(tester);
  controller.replaceText(
    0,
    controller.document.length - 1,
    text,
    selection ?? TextSelection.collapsed(offset: text.length),
  );
  controller.document.history.clear();
  await tester.pump();
  await tester.pump();
}

void _selectBody(WidgetTester tester, TextSelection selection) {
  _bodyController(tester).updateSelection(selection, ChangeSource.local);
}

void _expectCanvasDiffStyles(
  WidgetTester tester, {
  required String deletedFragment,
  required String insertedFragment,
}) {
  final editor = tester.widget<QuillEditor>(
    find.byKey(const ValueKey<String>('canvas-ai-inline-editor')),
  );
  final operations = editor.controller.document.toDelta().toList();
  final deleted = operations
      .where(
        (operation) =>
            CanvasAiInlineReview.changeFor(operation.attributes) ==
            CanvasReviewChange.deleted,
      )
      .map((operation) => operation.data)
      .join();
  final inserted = operations
      .where(
        (operation) =>
            CanvasAiInlineReview.changeFor(operation.attributes) ==
            CanvasReviewChange.inserted,
      )
      .map((operation) => operation.data)
      .join();
  expect(deleted, contains(deletedFragment));
  expect(inserted, contains(insertedFragment));
  final marked = operations.firstWhere(
    (operation) =>
        CanvasAiInlineReview.changeFor(operation.attributes) ==
        CanvasReviewChange.deleted,
  );
  final style = editor.config.customStyleBuilder!(
    Attribute.clone(Attribute.token, marked.attributes!['token']),
  );
  expect(style.color, const Color(0xFFB42318));
  expect(style.backgroundColor, isNotNull);
  expect(style.decoration, TextDecoration.lineThrough);
  final insertedMarked = operations.firstWhere(
    (operation) =>
        CanvasAiInlineReview.changeFor(operation.attributes) ==
        CanvasReviewChange.inserted,
  );
  final insertedStyle = editor.config.customStyleBuilder!(
    Attribute.clone(Attribute.token, insertedMarked.attributes!['token']),
  );
  expect(insertedStyle.color, const Color(0xFF137333));
  expect(insertedStyle.decoration, isNull);
}

_BodyTestField _bodyField(WidgetTester tester) =>
    _BodyTestField(_bodyEditor(tester));

final class _BodyTestField {
  const _BodyTestField(this.editor);

  final QuillEditor editor;

  _BodyTestController? get controller => _BodyTestController(editor.controller);
  FocusNode? get focusNode => editor.focusNode;
  bool get readOnly => editor.controller.readOnly;
}

final class _BodyTestController {
  const _BodyTestController(this.quill);

  final QuillController quill;

  String get text =>
      quill.document.toPlainText().replaceFirst(RegExp(r'\n$'), '');

  TextSelection get selection => quill.selection;

  set selection(TextSelection value) =>
      quill.updateSelection(value, ChangeSource.local);

  TextEditingValue get value =>
      TextEditingValue(text: text, selection: selection);

  set value(TextEditingValue value) {
    if (value.text == text) {
      selection = value.selection;
      return;
    }
    quill.replaceText(
      0,
      quill.document.length - 1,
      value.text,
      value.selection,
    );
  }
}

Map<String, dynamic> _bodyStyle(
  WidgetTester tester, {
  required int start,
  required int length,
}) =>
    _bodyController(tester).document.collectStyle(start, length).toJson() ??
    const <String, dynamic>{};

Map<String, dynamic> _lineBreakAttributes(WidgetTester tester, int lineIndex) {
  var currentLine = 0;
  for (final operation in _bodyController(
    tester,
  ).document.toDelta().operations) {
    final data = operation.data;
    if (data is! String) continue;
    for (var index = 0; index < data.length; index++) {
      if (data.codeUnitAt(index) != 10) continue;
      if (currentLine == lineIndex) {
        return operation.attributes ?? const <String, dynamic>{};
      }
      currentLine++;
    }
  }
  return const <String, dynamic>{};
}

CanvasImageEmbedData _firstCanvasImage(WidgetTester tester) {
  for (final operation in _bodyController(
    tester,
  ).document.toDelta().operations) {
    final data = operation.data;
    if (data is Map && data.containsKey(CanvasImageEmbedData.deltaEmbedType)) {
      return CanvasImageEmbedData.fromDeltaInsert(data);
    }
  }
  throw StateError('Canvas image embed not found');
}

CreationCanvasDraftRepository _draftRepository() {
  return CreationCanvasDraftRepository(
    dao: CreationCanvasDraftDao(AppDatabase()),
    userScope: 'test-user',
  );
}

CreationCanvasDraftRepository _draftRepositoryWithPendingInitialReceipt(
  String markdown,
) {
  final source = ScriptDraftSourceSnapshot(
    kind: ScriptDraftSourceKind.dailyRecommendation,
    sourceId: 'pending-topic',
    title: '待完成初稿',
    content: '生成初稿时冻结的来源。',
    partRevisionId: 'pending-recommendation-1',
    capturedAt: DateTime.utc(2026, 9, 10),
  );
  final receipt = ScriptDraftGenerationReceipt(
    sessionId: 'pending-script-session',
    source: source,
    createThreadIdempotencyKey: 'pending-create-key',
    messageIdempotencyKey: 'pending-message-key',
    cancelIdempotencyKey: 'pending-cancel-key',
    phase: ScriptDraftGenerationPhase.streaming,
    threadId: 'pending-thread',
    agentRunId: 'pending-run',
    partialMarkdown: '尚未成为可编辑正文的预览',
    updatedAt: DateTime.utc(2026, 9, 10),
  );
  return _draftRepository()..upsert(
    CreationCanvasDraft(
      title: '',
      markdown: markdown,
      entryIdentity: const CanvasEntryIntent.blank().stableSourceId,
      scriptDraftReceipt: receipt,
      revision: 1,
      createdAt: DateTime.utc(2026, 9, 10),
      updatedAt: DateTime.utc(2026, 9, 10),
    ),
  );
}

Future<void> _expectWideCanvasChatMotion(
  WidgetTester tester, {
  required bool disableAnimations,
  required Duration expectedDuration,
}) async {
  final harness = await _pumpCanvas(
    tester,
    repository: _draftRepository(),
    chatApi: _CanvasChatApi(),
    surfaceSize: const Size(800, 852),
    disableAnimations: disableAnimations,
  );
  addTearDown(harness.dispose);
  await _setBody(tester, '用于验证创作聊天动效。');

  await tester.tap(find.byKey(const ValueKey<String>('canvas-chat-entry')));
  await tester.pump();

  final chatTitle = find.text('创作聊天');
  expect(chatTitle, findsOneWidget);
  final chatRoute = ModalRoute.of(tester.element(chatTitle))!;
  expect(chatRoute.transitionDuration, expectedDuration);
  expect(chatRoute.reverseTransitionDuration, expectedDuration);
  final insetAnimation = find.ancestor(
    of: chatTitle,
    matching: find.byType(AnimatedPadding),
  );
  expect(insetAnimation, findsOneWidget);
  expect(
    tester.widget<AnimatedPadding>(insetAnimation).duration,
    expectedDuration,
  );
}

Future<_CanvasHarness> _pumpCanvas(
  WidgetTester tester, {
  required CreationCanvasDraftStore repository,
  KnowledgeLibraryController? library,
  KnowledgeLibraryController Function(Ref)? libraryResolver,
  ChatRepository? chatApi,
  ChatController? chatController,
  CanvasAiTransformPort? aiPort,
  ScriptDraftGenerationPort? scriptDraftPort,
  DeepPositioningController? positioning,
  CreationCanvasHistoryPort? historyPort,
  String userScope = 'test-user',
  String location = '/canvas',
  Size surfaceSize = const Size(393, 852),
  double textScale = 1,
  EdgeInsets viewInsets = EdgeInsets.zero,
  bool disableAnimations = false,
  bool wrapKeyboardDismiss = false,
  ThemeData? theme,
  bool autoSyncOwnedChanges = false,
  ForegroundIngressCoordinator? foregroundIngressCoordinator,
  DailyTopicCanvasSeed? dailyTopicSeed,
  AssetCanvasSeed? assetSeed,
  AssistantReplyCanvasSeed? assistantReplySeed,
  List<Override> additionalOverrides = const <Override>[],
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  final controller =
      library ??
      KnowledgeLibraryController(
        initialNotes: const [],
        notePort: const _CanvasSynchronizingNotePort(),
        includeDemoFixtures: false,
        autoSyncOwnedChanges: autoSyncOwnedChanges,
      );
  final router = GoRouter(
    initialLocation: location,
    observers: <NavigatorObserver>[appRouteObserver],
    routes: [
      GoRoute(
        path: '/canvas',
        builder: (context, state) {
          final explicitSeeds = <CanvasEntryIntent>[
            if (dailyTopicSeed != null)
              CanvasEntryIntent.dailyTopic(dailyTopicSeed),
            if (assetSeed != null) CanvasEntryIntent.asset(assetSeed),
            if (assistantReplySeed != null)
              CanvasEntryIntent.assistantReply(assistantReplySeed),
          ];
          final routeExtra = explicitSeeds.length == 1
              ? explicitSeeds.single
              : explicitSeeds.isEmpty
              ? state.extra
              : const Object();
          return V3CreationCanvasPage(
            recoverySessionId: state.uri.queryParameters['recoverySessionId'],
            recoveryRunId: state.uri.queryParameters['recoveryRunId'],
            entryIntent: resolveCanvasEntryIntent(
              extra: routeExtra,
              queryParametersAll: state.uri.queryParametersAll,
              sourceNoteForId: controller.noteForId,
            ),
          );
        },
      ),
      GoRoute(
        path: '/v3/feed/items/:itemId',
        builder: (context, state) =>
            Text('detail:${state.pathParameters['itemId']}'),
      ),
      GoRoute(
        path: '/v3/feed/chat',
        builder: (context, state) => const Text('定位对话页'),
      ),
      GoRoute(
        path: '/v3/workbench/tasks/:taskId',
        builder: (context, state) =>
            Text('task:${state.pathParameters['taskId']}'),
      ),
      GoRoute(
        path: '/v3',
        builder: (context, state) => Text(
          state.uri.queryParameters['mode'] == 'workbench' ? '创作空间' : '思想图谱',
        ),
      ),
      GoRoute(
        path: '/v3/workbench/history',
        builder: (context, state) => const Text('创作历史页'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...mobileAgentReadyTestOverrides(),
        resolvedDeviceIdProvider.overrideWithValue('test-device-1'),
        creationCanvasDraftRepositoryProvider.overrideWithValue(repository),
        authenticatedUserDataScopeProvider.overrideWithValue(userScope),
        creationCanvasHistoryPortProvider.overrideWithValue(
          historyPort ?? InMemoryCreationCanvasHistoryPort(),
        ),
        knowledgeLibraryControllerProvider.overrideWith(
          (ref) => libraryResolver?.call(ref) ?? controller,
        ),
        knowledgeLibraryAutoSyncOwnedChangesProvider.overrideWithValue(
          autoSyncOwnedChanges,
        ),
        profileHubControllerProvider.overrideWith(
          (ref) => ProfileHubController(),
        ),
        canvasAiTransformPortProvider.overrideWithValue(
          aiPort ?? const CanvasAiTransformMockPort(delay: Duration.zero),
        ),
        if (scriptDraftPort != null)
          scriptDraftGenerationPortProvider.overrideWithValue(scriptDraftPort),
        if (positioning != null)
          deepPositioningControllerProvider.overrideWith((ref) => positioning),
        if (chatApi != null) chatRepositoryProvider.overrideWithValue(chatApi),
        if (chatController != null)
          creationCanvasChatControllerProvider.overrideWith(
            (ref) => chatController,
          ),
        ...additionalOverrides,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: theme,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          final routedChild = wrapKeyboardDismiss
              ? V3KeyboardDismissOnUpwardScroll(child: child!)
              : child!;
          final app = MediaQuery(
            data: media.copyWith(
              size: surfaceSize,
              textScaler: TextScaler.linear(textScale),
              viewInsets: viewInsets,
              padding: EdgeInsets.fromLTRB(
                math.max(0, media.viewPadding.left - viewInsets.left),
                math.max(0, media.viewPadding.top - viewInsets.top),
                math.max(0, media.viewPadding.right - viewInsets.right),
                math.max(0, media.viewPadding.bottom - viewInsets.bottom),
              ),
              disableAnimations: disableAnimations,
            ),
            child: routedChild,
          );
          final coordinator = foregroundIngressCoordinator;
          return coordinator == null
              ? app
              : ForegroundIngressScope(coordinator: coordinator, child: app);
        },
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _CanvasHarness(router: router, tester: tester);
}

Future<void> _pumpUntilCanvasReady(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 10));
    if (find
        .byKey(const ValueKey<String>('canvas-body-field'))
        .evaluate()
        .isNotEmpty) {
      return;
    }
    if (find.text('初稿生成失败').evaluate().isNotEmpty) {
      final visibleText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data)
          .whereType<String>()
          .join(' | ');
      fail('Canvas initial draft failed: $visibleText');
    }
  }
  final visibleText = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data)
      .whereType<String>()
      .join(' | ');
  fail(
    'Canvas did not reach an editable or failed terminal state: $visibleText',
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

Future<void> _pumpUntilAsync(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 200 && !condition(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

DailyTopicCanvasSeed _dailyTopicCanvasSeed() => DailyTopicCanvasSeed(
  recommendationId: 'daily-recommendation-1',
  topicId: 'daily-topic-1',
  title: '公开每日选题',
  briefMarkdown: '从公开每日推荐进入详情。',
  sourceRefs: const <DailyTopicCanvasSourceRef>[
    DailyTopicCanvasSourceRef(hotspotId: 'daily-hotspot-1', label: '今日热点来源'),
  ],
);

final class _CanvasHarness {
  const _CanvasHarness({required this.router, required this.tester});

  final GoRouter router;
  final WidgetTester tester;

  void dispose() {
    router.dispose();
    tester.binding.setSurfaceSize(null);
  }
}

final class _CanvasLiveRecorder implements VoiceRecorderPort {
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  final List<VoiceRecordingScene> startedScenes = <VoiceRecordingScene>[];
  int cancelCalls = 0;

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
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    startedScenes.add(scene);
    final session = VoiceRecordingSession(
      recordingId: 'canvas-live-voice',
      scene: scene,
      state: VoiceRecorderState.recording,
      startedAt: DateTime.utc(2026, 9, 3),
    );
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    cancelCalls += 1;
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async =>
      throw UnimplementedError();

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async =>
      throw UnimplementedError();

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() async =>
      throw UnimplementedError();
}

final class _CanvasLiveCredentialPort
    implements LiveTranscriptionCredentialPort {
  const _CanvasLiveCredentialPort();

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async => ApiResult<LiveAsrSessionCredential>.success(
    data: LiveAsrSessionCredential(
      sessionId: 'canvas-live-session',
      appId: 123456789,
      projectId: 0,
      tmpSecretId: 'tmp-secret-id',
      tmpSecretKey: 'tmp-secret-key',
      token: 'tmp-token',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final class _CanvasLiveAsrPort implements TencentLiveAsrPort {
  _CanvasLiveAsrPort({this.stopGate});

  final Future<void>? stopGate;
  final StreamController<LiveTranscriptSentence> _events =
      StreamController<LiveTranscriptSentence>.broadcast(sync: true);

  void emit(LiveTranscriptSentence sentence) => _events.add(sentence);

  @override
  Stream<LiveTranscriptSentence> get events => _events.stream;

  @override
  Future<LiveAsrOperationResult> connect(
    LiveAsrSessionCredential credential,
  ) async => const LiveAsrOperationResult.success();

  @override
  Future<LiveAsrOperationResult> stop() async {
    final gate = stopGate;
    if (gate != null) await gate;
    return const LiveAsrOperationResult.success();
  }

  @override
  Future<LiveAsrOperationResult> release() async =>
      const LiveAsrOperationResult.success();

  Future<void> close() => _events.close();
}

final class _ControlledCanvasKnowledgeCache implements KnowledgeLibraryCache {
  bool failSaves = false;

  @override
  Future<List<V3FeedItem>?> load() async => null;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    if (failSaves) throw StateError('save failed');
  }
}

final class _GatedCanvasKnowledgeCache implements KnowledgeLibraryCache {
  _GatedCanvasKnowledgeCache(this.notes);

  final List<V3FeedItem> notes;
  final Completer<void> loadStarted = Completer<void>();
  final Completer<void> _loadGate = Completer<void>();

  void releaseLoad() {
    if (!_loadGate.isCompleted) _loadGate.complete();
  }

  @override
  Future<List<V3FeedItem>?> load() async {
    if (!loadStarted.isCompleted) loadStarted.complete();
    await _loadGate.future;
    return notes;
  }

  @override
  Future<void> save(List<V3FeedItem> notes) async {}
}

final class _RetryableCanvasKnowledgeCache implements KnowledgeLibraryCache {
  _RetryableCanvasKnowledgeCache(this.notes);

  final List<V3FeedItem> notes;
  int loadCalls = 0;

  @override
  Future<List<V3FeedItem>?> load() async {
    loadCalls += 1;
    if (loadCalls == 1) throw StateError('load failed');
    return List<V3FeedItem>.of(notes);
  }

  @override
  Future<void> save(List<V3FeedItem> notes) async {}
}

final class _ControlledCanvasHistoryPort implements CreationCanvasHistoryPort {
  final InMemoryCreationCanvasHistoryPort _delegate =
      InMemoryCreationCanvasHistoryPort();
  bool failUpserts = false;
  Completer<void>? upsertGate;
  int upsertCalls = 0;

  @override
  bool delete(String userScope, String historyId) =>
      _delegate.delete(userScope, historyId);

  @override
  CreationCanvasHistoryEntry? find(String userScope, String historyId) =>
      _delegate.find(userScope, historyId);

  @override
  List<CreationCanvasHistoryEntry> list(String userScope) =>
      _delegate.list(userScope);

  @override
  Future<void> upsert(
    String userScope,
    CreationCanvasHistoryEntry entry,
  ) async {
    upsertCalls += 1;
    await upsertGate?.future;
    if (failUpserts) {
      throw StateError('history upsert failed');
    }
    await _delegate.upsert(userScope, entry);
  }
}

final class _FailAfterHistoryCommittedCanvasDraftStore
    implements CreationCanvasDraftStore {
  _FailAfterHistoryCommittedCanvasDraftStore(this.delegate);

  final CreationCanvasDraftStore delegate;
  bool _failed = false;

  @override
  String get userScope => delegate.userScope;

  @override
  CreationCanvasDraft? load() => delegate.load();

  @override
  void upsert(CreationCanvasDraft draft) => delegate.upsert(draft);

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) async {
    await delegate.upsertDeferred(draft);
    if (!_failed &&
        draft.historyCommitReceipt?.phase ==
            CreationCanvasHistoryCommitPhase.historyCommitted) {
      _failed = true;
      throw StateError('simulated crash after History commit receipt');
    }
  }

  @override
  bool clear() => delegate.clear();

  @override
  Future<bool> clearDeferred() => delegate.clearDeferred();
}

final class _FailAfterPreparedCanvasDraftStore
    implements CreationCanvasDraftStore {
  _FailAfterPreparedCanvasDraftStore(this.delegate);

  final CreationCanvasDraftStore delegate;
  bool _failed = false;

  @override
  String get userScope => delegate.userScope;

  @override
  CreationCanvasDraft? load() => delegate.load();

  @override
  void upsert(CreationCanvasDraft draft) => delegate.upsert(draft);

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) async {
    await delegate.upsertDeferred(draft);
    if (!_failed &&
        draft.historyCommitReceipt?.phase ==
            CreationCanvasHistoryCommitPhase.prepared) {
      _failed = true;
      throw StateError('simulated crash after prepared receipt');
    }
  }

  @override
  bool clear() => delegate.clear();

  @override
  Future<bool> clearDeferred() => delegate.clearDeferred();
}

final class _FailingCanvasDraftClearStore implements CreationCanvasDraftStore {
  _FailingCanvasDraftClearStore(this.delegate);

  final CreationCanvasDraftStore delegate;
  int clearCalls = 0;

  @override
  String get userScope => delegate.userScope;

  @override
  CreationCanvasDraft? load() => delegate.load();

  @override
  void upsert(CreationCanvasDraft draft) => delegate.upsert(draft);

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) =>
      delegate.upsertDeferred(draft);

  @override
  bool clear() => delegate.clear();

  @override
  Future<bool> clearDeferred() {
    clearCalls += 1;
    if (clearCalls == 1) {
      return Future<bool>.error(StateError('draft clear failed'));
    }
    return delegate.clearDeferred();
  }
}

final class _FailingCanvasDraftUpsertStore implements CreationCanvasDraftStore {
  _FailingCanvasDraftUpsertStore(this.delegate);

  final CreationCanvasDraftStore delegate;

  @override
  String get userScope => delegate.userScope;

  @override
  CreationCanvasDraft? load() => delegate.load();

  @override
  void upsert(CreationCanvasDraft draft) => delegate.upsert(draft);

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) =>
      Future<void>.error(StateError('draft upsert failed'));

  @override
  bool clear() => delegate.clear();

  @override
  Future<bool> clearDeferred() => delegate.clearDeferred();
}

final class _BlockingCanvasDraftClearStore implements CreationCanvasDraftStore {
  _BlockingCanvasDraftClearStore(this.delegate);

  final CreationCanvasDraftStore delegate;
  final Completer<void> _cleared = Completer<void>();
  final Completer<void> _finish = Completer<void>();

  Future<void> get cleared => _cleared.future;

  void finishClear() {
    if (!_finish.isCompleted) _finish.complete();
  }

  @override
  String get userScope => delegate.userScope;

  @override
  CreationCanvasDraft? load() => delegate.load();

  @override
  void upsert(CreationCanvasDraft draft) => delegate.upsert(draft);

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) =>
      delegate.upsertDeferred(draft);

  @override
  bool clear() => delegate.clear();

  @override
  Future<bool> clearDeferred() async {
    final result = await delegate.clearDeferred();
    if (!_cleared.isCompleted) _cleared.complete();
    await _finish.future;
    return result;
  }
}

final class _GatedCanvasDraftStore implements CreationCanvasDraftStore {
  _GatedCanvasDraftStore(this.delegate);

  final CreationCanvasDraftStore delegate;
  Completer<void>? _upsertStarted;
  Completer<void>? _upsertRelease;
  CreationCanvasHistoryCommitPhase? _upsertPhase;
  Completer<void>? _clearStarted;
  Completer<void>? _clearRelease;

  bool get upsertStarted => _upsertStarted?.isCompleted ?? false;
  bool get clearStarted => _clearStarted?.isCompleted ?? false;

  void gateNextUpsert({CreationCanvasHistoryCommitPhase? phase}) {
    _upsertPhase = phase;
    _upsertStarted = Completer<void>();
    _upsertRelease = Completer<void>();
  }

  void releaseUpsert() {
    final release = _upsertRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  void gateNextClear() {
    _clearStarted = Completer<void>();
    _clearRelease = Completer<void>();
  }

  void releaseClear() {
    final release = _clearRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  @override
  String get userScope => delegate.userScope;

  @override
  CreationCanvasDraft? load() => delegate.load();

  @override
  void upsert(CreationCanvasDraft draft) => delegate.upsert(draft);

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) async {
    final started = _upsertStarted;
    final release = _upsertRelease;
    if (started != null &&
        release != null &&
        !started.isCompleted &&
        (_upsertPhase == null ||
            draft.historyCommitReceipt?.phase == _upsertPhase)) {
      started.complete();
      await release.future;
      _upsertStarted = null;
      _upsertRelease = null;
      _upsertPhase = null;
    }
    await delegate.upsertDeferred(draft);
  }

  @override
  bool clear() => delegate.clear();

  @override
  Future<bool> clearDeferred() async {
    final started = _clearStarted;
    final release = _clearRelease;
    if (started != null && release != null && !started.isCompleted) {
      started.complete();
      await release.future;
      _clearStarted = null;
      _clearRelease = null;
    }
    return delegate.clearDeferred();
  }
}

final class _CanvasChatCheckpointDraftStore
    implements CreationCanvasDraftStore {
  _CanvasChatCheckpointDraftStore(this.delegate);

  final CreationCanvasDraftStore delegate;
  final Completer<void> checkpointStarted = Completer<void>();
  final Completer<void> _checkpointRelease = Completer<void>();
  CreationCanvasDraft? checkpointDraft;
  bool _didGate = false;

  void releaseCheckpoint() {
    if (!_checkpointRelease.isCompleted) _checkpointRelease.complete();
  }

  @override
  String get userScope => delegate.userScope;

  @override
  CreationCanvasDraft? load() => delegate.load();

  @override
  void upsert(CreationCanvasDraft draft) => delegate.upsert(draft);

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) async {
    final pending = draft.chatRewriteReceipts
        .where((receipt) => receipt.assistantMessageId == null)
        .firstOrNull;
    if (!_didGate &&
        pending?.threadId != null &&
        pending?.submissionPhase ==
            CreationCanvasChatSubmissionPhase.submitting) {
      _didGate = true;
      checkpointDraft = draft;
      if (!checkpointStarted.isCompleted) checkpointStarted.complete();
      await _checkpointRelease.future;
    }
    await delegate.upsertDeferred(draft);
  }

  @override
  bool clear() => delegate.clear();

  @override
  Future<bool> clearDeferred() => delegate.clearDeferred();
}

final class _BlockingCanvasKnowledgeCache implements KnowledgeLibraryCache {
  final Completer<void> saveStarted = Completer<void>();
  final Completer<void> _saveCompleter = Completer<void>();

  @override
  Future<List<V3FeedItem>?> load() async => null;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await _saveCompleter.future;
  }

  void completeSave() {
    if (!_saveCompleter.isCompleted) _saveCompleter.complete();
  }
}

final class _PendingCanvasAiPort implements CanvasAiTransformPort {
  final Completer<CanvasAiResult> _result = Completer<CanvasAiResult>();

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) => _result.future;
}

final class _SuccessfulScriptDraftPort implements ScriptDraftGenerationPort {
  _SuccessfulScriptDraftPort({
    this.finalMarkdown = '这是服务端确认后的可编辑逐字稿。',
    this.pending = false,
  });

  final bool pending;

  final String finalMarkdown;
  final String partialMarkdown = '这只是流式预览，不能进入编辑器。';
  final List<String> createKeys = <String>[];
  final List<String> messageKeys = <String>[];
  final List<ScriptDraftRequest> requests = <ScriptDraftRequest>[];
  final List<int> afterSequences = <int>[];
  final List<(String, String)> cancelledWith = <(String, String)>[];

  @override
  Future<String> createThread({required String idempotencyKey}) async {
    createKeys.add(idempotencyKey);
    return 'script-thread-1';
  }

  @override
  Future<String> submit({
    required String threadId,
    required ScriptDraftRequest request,
    required String idempotencyKey,
  }) async {
    expectSync(threadId, 'script-thread-1');
    expectSync(ScriptDraftRequest.agentProfileId, 'script_draft');
    expectSync(ScriptDraftRequest.modelProfileId, 'deepseek-v4-flash-vision');
    requests.add(request);
    messageKeys.add(idempotencyKey);
    return 'script-run-1';
  }

  @override
  Future<Stream<ScriptDraftStreamSignal>> streamEvents({
    required String agentRunId,
    required int afterSequence,
  }) async {
    afterSequences.add(afterSequence);
    if (pending) return Stream<ScriptDraftStreamSignal>.multi((controller) {});
    return Stream<ScriptDraftStreamSignal>.fromIterable(
      <ScriptDraftStreamSignal>[
        ScriptDraftStreamSignal.event(
          ScriptDraftRemoteEvent(
            sequence: 1,
            status: 'running',
            deltaText: partialMarkdown,
            replace: true,
          ),
        ),
        const ScriptDraftStreamSignal.event(
          ScriptDraftRemoteEvent(sequence: 2, status: 'succeeded'),
        ),
      ],
    );
  }

  @override
  Future<ScriptDraftEventPage> readEvents({
    required String agentRunId,
    required int afterSequence,
  }) async => ScriptDraftEventPage(
    items: const <ScriptDraftRemoteEvent>[],
    nextAfterSequence: afterSequence,
    hasMore: false,
    gap: false,
    oldestAvailableSequence: afterSequence,
  );

  @override
  Future<ScriptDraftRunSnapshot> getRun({required String agentRunId}) async =>
      pending
      ? const ScriptDraftRunSnapshot(status: 'running')
      : ScriptDraftRunSnapshot(
          status: 'succeeded',
          completionMode: 'normal',
          finalAnswer: finalMarkdown,
        );

  @override
  Future<void> cancelRun({
    required String agentRunId,
    required String idempotencyKey,
  }) async {
    cancelledWith.add((agentRunId, idempotencyKey));
  }
}

final class _CanvasSynchronizingNotePort implements KnowledgeNotePort {
  const _CanvasSynchronizingNotePort();

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    final source =
        request.localNote ??
        V3FeedItem(
          id: request.noteId,
          title: request.draft.title,
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 8, 12),
          rawBody: request.draft.rawBody,
        );
    return KnowledgeNotePortResult.success(
      source.copyWith(
        title: request.draft.title,
        rawBody: request.draft.rawBody,
        localRevision: request.localRevision,
        remoteRevision: 1,
        remoteNoteId: request.remoteNoteId ?? 'remote-${request.noteId}',
        noteRevisionId: 'owner-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        etag: '"note-1"',
        contentCursor: 'cursor-1',
      ),
    );
  }
}

final class _RecordingCanvasSynchronizingNotePort implements KnowledgeNotePort {
  Completer<void>? gate;
  bool failNext = false;
  final List<KnowledgeNoteUpdateRequest> requests =
      <KnowledgeNoteUpdateRequest>[];

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    requests.add(request);
    await gate?.future;
    if (failNext) {
      failNext = false;
      return const KnowledgeNotePortResult.unavailable();
    }
    return const _CanvasSynchronizingNotePort().updateNote(request);
  }
}

final class _CapturingCanvasAiPort implements CanvasAiTransformPort {
  final requests = <CanvasAiRequest>[];

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    requests.add(request);
    return CanvasAiResult(
      requestId: request.requestId,
      command: request.command,
      replacementMarkdown: '带入定位后的正文',
      sourceDocumentHash: request.documentHash,
      sourceTargetHash: request.targetHash,
      generatedAt: DateTime.utc(2026, 7, 27),
      unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
        baseMarkdown: request.targetMarkdown,
        replacementMarkdown: '带入定位后的正文',
      ),
    );
  }
}

final class _AuditedCanvasAiPort implements CanvasAiTransformPort {
  final requests = <CanvasAiRequest>[];

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) {
    requests.add(request);
    return const CanvasAiTransformMockPort(
      delay: Duration.zero,
    ).transform(request);
  }
}

final class _ReplacementCanvasAiPort implements CanvasAiTransformPort {
  const _ReplacementCanvasAiPort(this.replacementMarkdown);

  final String replacementMarkdown;

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    return CanvasAiResult(
      requestId: request.requestId,
      command: request.command,
      replacementMarkdown: replacementMarkdown,
      sourceDocumentHash: request.documentHash,
      sourceTargetHash: request.targetHash,
      generatedAt: DateTime.utc(2026, 7, 23),
      unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
        baseMarkdown: request.targetMarkdown,
        replacementMarkdown: replacementMarkdown,
      ),
    );
  }
}

final class _FailThenSucceedCanvasAiPort implements CanvasAiTransformPort {
  _FailThenSucceedCanvasAiPort(this.firstFailure);

  final CanvasAiTransformException firstFailure;
  final List<CanvasAiRequest> requests = <CanvasAiRequest>[];

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    requests.add(request);
    if (requests.length == 1) throw firstFailure;
    return CanvasAiResult(
      requestId: request.requestId,
      command: request.command,
      replacementMarkdown: '已完成新的改写。',
      sourceDocumentHash: request.documentHash,
      sourceTargetHash: request.targetHash,
      generatedAt: DateTime.utc(2026, 8, 11),
      unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
        baseMarkdown: request.targetMarkdown,
        replacementMarkdown: '已完成新的改写。',
      ),
    );
  }
}

final class _DiffCanvasAiPort implements CanvasAiTransformPort {
  const _DiffCanvasAiPort(this._replacementFor);

  final String Function(CanvasAiRequest request) _replacementFor;

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    final replacement = _replacementFor(request);
    return CanvasAiResult(
      requestId: request.requestId,
      command: request.command,
      sourceDocumentHash: request.documentHash,
      sourceTargetHash: request.targetHash,
      generatedAt: DateTime.utc(2026, 8, 11),
      unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
        baseMarkdown: request.targetMarkdown,
        replacementMarkdown: replacement,
      ),
    );
  }
}

final class _CanvasChatApi implements ChatRepository {
  _CanvasChatApi({
    this.assistantText = '这是可执行的改写建议。',
    this.agentRunId,
    this.sendGate,
    this.nextAction,
    this.sendResult,
  });

  final String assistantText;
  final String? agentRunId;
  final Completer<void>? sendGate;
  final ChatNextAction? nextAction;
  final ApiResult<ChatTextMutation>? sendResult;
  List<ChatMessage> detailMessages = const [];
  final Map<String, int> _messageOrdinals = {};
  final List<String> sentContents = <String>[];
  final List<ChatContextEnvelope?> sentContexts = <ChatContextEnvelope?>[];
  final List<String?> sentAgentProfileIds = <String?>[];
  final List<IdempotencyRequestContext> createIdempotencies =
      <IdempotencyRequestContext>[];
  final List<IdempotencyRequestContext> messageIdempotencies =
      <IdempotencyRequestContext>[];

  static const _thread = ChatThread(
    threadId: 'canvas-thread-1',
    scene: ChatScene.workAi,
    title: '创作聊天',
  );

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    createIdempotencies.add(idempotency);
    return ApiResult<ChatThread>.success(
      data: _thread,
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async => ApiResult<ChatThreadDetail>.success(
    data: ChatThreadDetail(thread: _thread, messages: detailMessages),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async => ApiResult<ChatThreadPage>.success(
    data: const ChatThreadPage(items: <ChatThread>[]),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
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
  }) async {
    sentContents.add(content);
    sentContexts.add(context);
    sentAgentProfileIds.add(agentProfileId);
    messageIdempotencies.add(idempotency);
    await sendGate?.future;
    final explicitResult = sendResult;
    if (explicitResult != null) return explicitResult;
    final ordinal = _messageOrdinals.putIfAbsent(
      idempotency.explicitKey ?? 'turn-${sentContents.length}',
      () => _messageOrdinals.length + 1,
    );
    final acceptedNextAction =
        nextAction ??
        (agentRunId == null
            ? const ChatNextAction.none()
            : ChatNextAction(
                type: ChatNextActionType.pollAgentRun,
                agentRunId: agentRunId,
              ));
    return ApiResult<ChatTextMutation>.success(
      data: ChatTextMutation(
        message: ChatMessage(
          messageId: 'canvas-user-$ordinal',
          threadId: threadId,
          scene: scene,
          role: ChatMessageRole.user,
          contentType: ChatMessageContentType.text,
          status: 'sent',
          textPreview: content,
        ),
        assistantMessage: agentRunId == null
            ? ChatMessage(
                messageId: 'canvas-assistant-$ordinal',
                threadId: threadId,
                scene: scene,
                role: ChatMessageRole.assistant,
                contentType: ChatMessageContentType.text,
                status: 'sent',
                textPreview: assistantText,
              )
            : null,
        nextAction: acceptedNextAction,
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
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
  }) async => throw UnsupportedError('Canvas chat does not send voice');
}

final class _FailingCanvasChatCacheWorker implements DatabaseRecordWorkerPort {
  const _FailingCanvasChatCacheWorker();

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) async => throw StateError('injected Canvas chat cache failure');

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async => throw StateError('injected Canvas chat cache failure');

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async => throw StateError('unexpected delete');

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async =>
      const <LocalDatabaseRecord>[];
}

typedef _CanvasTrackCallback =
    void Function({
      required String agentRunId,
      required String threadId,
      required ChatScene scene,
      required ChatConversationPurpose purpose,
    });

final class _CanvasSseTracker extends ChangeNotifier
    implements
        ChatRunTrackingPort,
        ChatRunLifecycleOwnerPort,
        ChatRunDraftDeltaSourcePort {
  _CanvasSseTracker({required this.onTrack});

  final _CanvasTrackCallback onTrack;
  int _sequence = 0;
  ChatRunDraftDelta? _lastDelta;

  @override
  bool get canTrackAcceptedRuns => true;

  @override
  int get draftDeltaSequence => _sequence;

  @override
  ChatRunDraftDelta? get lastDraftDelta => _lastDelta;

  void publish({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    required String deltaText,
    bool replace = false,
  }) {
    _sequence += 1;
    _lastDelta = ChatRunDraftDelta(
      agentRunId: agentRunId,
      threadId: threadId,
      scene: scene,
      purpose: purpose,
      eventSequence: _sequence,
      deltaText: deltaText,
      replace: replace,
    );
    notifyListeners();
  }

  @override
  Future<void> track({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) async {
    onTrack(
      agentRunId: agentRunId,
      threadId: threadId,
      scene: scene,
      purpose: purpose,
    );
  }
}
