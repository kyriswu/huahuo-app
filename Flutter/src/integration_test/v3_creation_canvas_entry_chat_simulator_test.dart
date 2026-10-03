import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/script_draft_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_item_detail_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_creation_canvas_chrome.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _entry = String.fromEnvironment('HUAHUO_CANVAS_ENTRY_CHAT_AUDIT');
const _noteId = String.fromEnvironment('HUAHUO_CANVAS_ENTRY_CHAT_NOTE_ID');
const _runLabel = String.fromEnvironment(
  'HUAHUO_CANVAS_ENTRY_CHAT_RUN',
  defaultValue: '20260917',
);
const _resume = bool.fromEnvironment('HUAHUO_CANVAS_ENTRY_CHAT_RESUME');
const _resetOwned = bool.fromEnvironment(
  'HUAHUO_CANVAS_ENTRY_CHAT_RESET_OWNED',
);
const _resumeSession = String.fromEnvironment(
  'HUAHUO_CANVAS_ENTRY_CHAT_RESUME_SESSION',
);
const _testDiff = bool.fromEnvironment('HUAHUO_CANVAS_ENTRY_CHAT_DIFF');
const _finishRejectedDiff = bool.fromEnvironment(
  'HUAHUO_CANVAS_ENTRY_CHAT_FINISH_REJECTED_DIFF',
);
const _entries = {
  'blank',
  'note-raw',
  'note-summary',
  'note-sprout',
  'daily',
  'external-square',
  'external-subscribed',
  'history',
  'canvas-history',
  'canvas-new',
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'live entry and systematic multi-turn Canvas Chat',
    (tester) async {
      expect(_entries, contains(_entry));
      binding.testTextInput.register();
      addTearDown(binding.testTextInput.unregister);
      final directory = Directory(
        '${(await getApplicationSupportDirectory()).path}/CanvasEntryChatAudit',
      );
      await directory.create(recursive: true);
      final manifestFile = File('${directory.path}/$_runLabel-$_entry.json');
      final previous = await manifestFile.exists()
          ? jsonDecode(await manifestFile.readAsString())
                as Map<String, dynamic>
          : <String, dynamic>{};
      final phases = <Map<String, Object?>>[];
      final metadata = <String, Object?>{
        'entry': _entry,
        'run': _runLabel,
        'phases': phases,
      };
      Future<void> capture(String phase) async {
        phases.add({
          'phase': phase,
          'utc': DateTime.now().toUtc().toIso8601String(),
        });
        await manifestFile.writeAsString(jsonEncode(metadata));
        debugPrint(
          'CANVAS_ENTRY_CHAT ${jsonEncode({'entry': _entry, 'phase': phase, 'turn': metadata['turn'], 'threadId': metadata['threadId'], 'noteId': metadata['noteId']})}',
        );
        if (phase != 'turn_completed') {
          await File(
            '${directory.path}/$_runLabel-$_entry-$phase.png',
          ).writeAsBytes(await binding.takeScreenshot('$_entry-$phase'));
        }
      }

      try {
        await app.main();
        await _wait(
          tester,
          () => find.byType(Scaffold).evaluate().isNotEmpty,
          'app',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold).first),
        );
        await _wait(
          tester,
          () {
            final session = container.read(sessionStoreProvider).state;
            return session.authState == SessionAuthState.authenticated &&
                session.workspace?.status == SessionWorkspaceStatus.ready &&
                session.workspace?.workspaceId?.isNotEmpty == true;
          },
          'authenticated workspace',
          timeout: const Duration(seconds: 60),
        );
        final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
        final drafts = container.read(creationCanvasDraftRepositoryProvider);
        var existing = drafts.load();
        if (_resetOwned && existing != null) {
          expect(existing.sessionId, _resumeSession);
          expect(existing.documentJson, contains('自由创作入口联调-'));
          expect(existing.historyCommitReceipt, isNull);
          expect(
            existing.chatRewriteReceipts.every(
              (receipt) => receipt.assistantMessageId != null,
            ),
            isTrue,
          );
          router.go(AppRoutePaths.workbench);
          await _tapKey(tester, 'workbench-free-creation');
          await _wait(
            tester,
            () => find.text('放弃并打开当前入口').hitTestable().evaluate().isNotEmpty,
            'owned audit draft discard',
          );
          await tester.tap(find.text('放弃并打开当前入口').hitTestable());
          await _wait(
            tester,
            () => _body.evaluate().isNotEmpty && _text(tester).trim().isEmpty,
            'empty Canvas after owned discard',
          );
          await tester.tap(
            find.byType(V3NavigationBackButton).hitTestable().last,
          );
          await _wait(
            tester,
            () => _body.evaluate().isEmpty && drafts.load() == null,
            'owned draft cleanup',
          );
          existing = null;
        }
        const auditTitle = '自由创作入口联调-$_runLabel-$_entry';
        expect(
          existing == null ||
              (_resume &&
                  existing.documentJson?.contains(auditTitle) == true &&
                  existing.sessionId ==
                      (previous['sessionId'] ?? _resumeSession) &&
                  existing.historyCommitReceipt == null &&
                  existing.chatRewriteReceipts.every(
                    (receipt) => receipt.assistantMessageId != null,
                  )),
          isTrue,
          reason: 'Do not replace a user draft or retry an unfinished turn.',
        );
        V3FeedItem? source;
        final beforeIds = container
            .read(knowledgeLibraryControllerProvider)
            .notes
            .map((note) => note.id)
            .toSet();
        if (existing != null) {
          final currentLibrary = container.read(
            knowledgeLibraryControllerProvider,
          );
          await currentLibrary.ensureCacheRestored();
          final bound = currentLibrary.noteForId(existing.boundNoteId ?? '');
          debugPrint(
            'CANVAS_ENTRY_PROOF expected=${existing.boundAssetFingerprint} actual=${bound == null ? null : _boundFingerprint(bound)}',
          );
          debugPrint(
            'CANVAS_ENTRY_RESTORE ${jsonEncode({'cacheReady': currentLibrary.cacheRestoreSucceeded, 'boundId': existing.boundNoteId, 'found': bound != null, 'localRevision': bound?.localRevision, 'rawLength': bound?.rawBody.length, 'libraryNotes': currentLibrary.notes.length})}',
          );
          router.go(AppRoutePaths.workbench);
          await _tapKey(tester, 'workbench-free-creation');
          await _wait(
            tester,
            () =>
                find.text('继续上次创作').hitTestable().evaluate().isNotEmpty ||
                (find.byType(V3CanvasEditingModeSwitch).evaluate().isNotEmpty &&
                    tester
                            .widget<V3CanvasEditingModeSwitch>(
                              find.byType(V3CanvasEditingModeSwitch),
                            )
                            .onChanged !=
                        null),
            'restore draft choice',
          );
          if (find.text('继续上次创作').hitTestable().evaluate().isNotEmpty) {
            await tester.tap(find.text('继续上次创作').hitTestable());
            await tester.pump(const Duration(milliseconds: 500));
            final current = container.read(knowledgeLibraryControllerProvider);
            final note = current.noteForId(existing.boundNoteId ?? '');
            debugPrint(
              'CANVAS_ENTRY_RESTORE_AFTER ${jsonEncode({'sameLibrary': identical(current, currentLibrary), 'cacheReady': current.cacheRestoreSucceeded, 'found': note != null, 'actualFingerprint': note == null ? null : _boundFingerprint(note)})}',
            );
          }
        } else {
          source = await _openEntry(tester, container, router);
        }
        await _wait(
          tester,
          () =>
              _body.evaluate().isNotEmpty &&
              !_editor(tester).readOnly &&
              find.byType(V3CanvasEditingModeSwitch).evaluate().isNotEmpty &&
              tester
                      .widget<V3CanvasEditingModeSwitch>(
                        find.byType(V3CanvasEditingModeSwitch),
                      )
                      .onChanged !=
                  null,
          'editable Canvas',
          timeout: const Duration(minutes: 3),
        );
        if (existing == null) {
          if (!tester.widget<TextField>(_key('canvas-title-field')).readOnly) {
            await tester.enterText(_key('canvas-title-field'), auditTitle);
          }
          if (_text(tester).trim().isEmpty) {
            _editor(tester).replaceText(
              0,
              0,
              '这是自由创作入口与多轮聊天的验证正文。\n先明确读者遇到的问题，再给出一个可验证的小行动。',
              const TextSelection.collapsed(offset: 0),
            );
          }
          final offset = _editor(tester).document.length - 1;
          _editor(tester).replaceText(
            offset,
            0,
            '\n入口联调标记：$auditTitle',
            TextSelection.collapsed(offset: offset),
          );
          await _focusBody(tester);
          await _wait(
            tester,
            () => drafts.load()?.documentJson?.contains(auditTitle) == true,
            'audit draft checkpoint',
          );
        }
        metadata['sessionId'] = drafts.load()!.sessionId;
        metadata['draftTitle'] = drafts.load()!.title;
        metadata['sourceId'] = source?.id ?? previous['sourceId'];
        metadata['sourceReadOnly'] =
            source?.isReadOnly ?? previous['sourceReadOnly'];
        await capture('opened');
        final marker =
            'HH${_runLabel.replaceAll(RegExp('[^0-9A-Za-z]'), '')}${_entry.replaceAll('-', '')}';
        final bodyMarker = 'BODY$marker';
        final prompts = [
          '本次核对暗号是 $marker。请记住这个暗号，并用一句话确认。只聊天，不输出差分，不修改正文。',
          '上一轮的核对暗号是什么？请只返回那个完整暗号，不修改正文。',
          '请只针对这次选中的内容给一条写作建议。不要改写，不要输出差分。',
          '当前正文末尾的 BODY 开头核对标记是什么？只返回完整标记，不要修改正文。',
          '请回顾这次对话，分别复述第一轮暗号和最新正文的 BODY 标记。不要修改正文。',
        ];
        final firstTurn = drafts.load()!.chatRewriteReceipts.length;
        if (_finishRejectedDiff) {
          expect(_resume, isTrue);
          expect(_testDiff, isFalse);
          expect(existing?.sessionId, _resumeSession);
          expect(firstTurn, 6);
          final receipts = drafts.load()!.chatRewriteReceipts;
          expect(
            receipts.every(
              (receipt) =>
                  receipt.assistantMessageId != null &&
                  receipt.threadId == existing?.chatThreadId,
            ),
            isTrue,
          );
          expect(receipts.last.selectionScoped, isTrue);
          expect(_text(tester), contains(bodyMarker));
          expect(_text(tester), isNot(contains('$bodyMarker-OK')));
          metadata['recoveryOnly'] = 'rejected_sixth_diff';
          metadata['turn'] = firstTurn;
          metadata['lastRunId'] = receipts.last.agentRunId;
        } else {
          expect(firstTurn, lessThanOrEqualTo(5));
        }
        String? threadId = existing?.chatThreadId;
        for (var index = firstTurn; index < prompts.length; index += 1) {
          await _focusBody(tester);
          if (index == 2) {
            final length = _text(tester).split('\n').first.length;
            _editor(tester).updateSelection(
              TextSelection(baseOffset: 0, extentOffset: length),
              ChangeSource.local,
            );
            await tester.pump();
          } else {
            if (index == 3 && !_text(tester).contains(bodyMarker)) {
              final offset = _editor(tester).document.length - 1;
              _editor(tester).replaceText(
                offset,
                0,
                '\n$bodyMarker',
                TextSelection.collapsed(offset: offset + bodyMarker.length + 1),
              );
              await tester.pump(const Duration(milliseconds: 800));
            }
            _editor(tester).updateSelection(
              const TextSelection.collapsed(offset: 0),
              ChangeSource.local,
            );
          }
          final before = _text(tester);
          await _tapKey(tester, 'canvas-chat-entry');
          await _wait(
            tester,
            () => _key('canvas-chat-input').evaluate().isNotEmpty,
            'Chat composer',
          );
          await tester.enterText(_key('canvas-chat-input'), prompts[index]);
          await _wait(
            tester,
            () =>
                tester.widget<IconButton>(_key('canvas-chat-send')).onPressed !=
                null,
            'send admission',
          );
          await tester.tap(_key('canvas-chat-send'));
          if (index == 0) {
            await tester.tap(_key('canvas-chat-send'));
            await _wait(
              tester,
              () => drafts.load()?.chatRewriteReceipts.length == 1,
              'single durable receipt after double tap',
            );
            await _tapKey(tester, 'canvas-chat-close');
            await _tapKey(tester, 'canvas-ai-tools');
            await _tapKey(tester, 'canvas-edit-mode');
            expect(_editor(tester).readOnly, isFalse);
            await _focusBody(tester);
            await _tapKey(tester, 'canvas-chat-entry');
          }
          await _wait(
            tester,
            () {
              final receipts = drafts.load()?.chatRewriteReceipts;
              final controller = container.read(
                creationCanvasChatControllerProvider,
              );
              return receipts?.length == index + 1 &&
                  receipts!.every(
                    (receipt) => receipt.assistantMessageId != null,
                  ) &&
                  controller.state.canSubmitUserTurn &&
                  !controller.state.isSending;
            },
            'Chat turn ${index + 1}',
            timeout: const Duration(minutes: 3),
          );
          final chat = container
              .read(creationCanvasChatControllerProvider)
              .state;
          threadId ??= chat.activeThreadId;
          expect(chat.activeThreadId, threadId);
          final userMessages = chat.messages
              .where((message) => message.role == ChatMessageRole.user)
              .toList();
          expect(userMessages, hasLength(index + 1));
          expect(
            userMessages.map((message) => message.messageId).toSet(),
            hasLength(index + 1),
          );
          expect(
            userMessages.any(
              (message) => message.messageId.startsWith('local-'),
            ),
            isFalse,
          );
          final receipt = drafts.load()!.chatRewriteReceipts.last;
          expect(receipt.selectionScoped, index == 2);
          final answer =
              chat.messages
                  .singleWhere(
                    (message) =>
                        message.messageId == receipt.assistantMessageId,
                  )
                  .visibleText ??
              '';
          if (index == 1 || index == 4) expect(answer, contains(marker));
          if (index == 3 || index == 4) expect(answer, contains(bodyMarker));
          expect(_text(tester), before);
          metadata['threadId'] = threadId;
          metadata['turn'] = index + 1;
          metadata['lastRunId'] = receipt.agentRunId;
          await capture('turn_completed');
          if (index == 4) {
            await _tapKey(tester, 'canvas-chat-history');
            await _wait(
              tester,
              () => _key('canvas-chat-history-$threadId').evaluate().isNotEmpty,
              'current conversation in history',
            );
            await _tapKey(tester, 'canvas-chat-history-back');
          }
          await _tapKey(tester, 'canvas-chat-close');
        }
        if (_testDiff) {
          final before = _text(tester);
          await _focusBody(tester);
          final start = before.indexOf(bodyMarker);
          expect(start, greaterThanOrEqualTo(0));
          _editor(tester).updateSelection(
            TextSelection(
              baseOffset: start,
              extentOffset: start + bodyMarker.length,
            ),
            ChangeSource.local,
          );
          await _tapKey(tester, 'canvas-chat-entry');
          await _wait(
            tester,
            () => _key('canvas-chat-input').evaluate().isNotEmpty,
            'diff Chat',
          );
          await tester.enterText(
            _key('canvas-chat-input'),
            '请修改当前选中文本，仅在末尾添加 -OK。只返回一个标准 unified diff 代码块，'
            '包含 --- a/document、+++ b/document、@@ -1 +1 @@ 三行头部，'
            '删除行为 -$bodyMarker，插入行为 +$bodyMarker-OK。不要说明。',
          );
          await _wait(
            tester,
            () =>
                tester.widget<IconButton>(_key('canvas-chat-send')).onPressed !=
                null,
            'diff send',
          );
          await tester.tap(_key('canvas-chat-send'));
          await _wait(
            tester,
            () => _key('canvas-ai-diff-preview').evaluate().isNotEmpty,
            'returned Chat diff review',
            timeout: const Duration(minutes: 3),
          );
          expect(_text(tester), before);
          await _wait(tester, () {
            final receipts = drafts.load()?.chatRewriteReceipts;
            return receipts?.length == 6 &&
                receipts!.last.assistantMessageId != null;
          }, 'sixth diff receipt');
          final receipt = drafts.load()!.chatRewriteReceipts.last;
          expect(receipt.selectionScoped, isTrue);
          expect(receipt.threadId, threadId);
          metadata['turn'] = 6;
          metadata['lastRunId'] = receipt.agentRunId;
          await capture('chat_diff_review');
          await _tapKey(tester, 'canvas-ai-apply');
          expect(
            _text(tester),
            before.replaceFirst(bodyMarker, '$bodyMarker-OK'),
          );
        }
        await capture('chat_complete');
        final expectedMarkdown = drafts.load()!.markdown.trim();
        final boundId = drafts.load()!.boundNoteId;
        await _tapKey(tester, 'canvas-save');
        await _wait(
          tester,
          () => find.text('确认保存').evaluate().isNotEmpty,
          'save confirmation',
        );
        await tester.tap(find.text('确认保存'));
        await _wait(
          tester,
          () => _body.evaluate().isEmpty && drafts.load() == null,
          'confirmed save and cleanup',
          timeout: const Duration(minutes: 2),
        );
        final library = container.read(knowledgeLibraryControllerProvider);
        final saved = boundId != null
            ? library.noteForId(boundId)!
            : library.notes.singleWhere(
                (note) =>
                    !beforeIds.contains(note.id) &&
                    note.rawBody == expectedMarkdown,
              );
        expect(saved.syncState, NoteSyncState.synced);
        expect(saved.rawBody, expectedMarkdown);
        if (source != null && !{'history', 'canvas-history'}.contains(_entry)) {
          expect(saved.id, isNot(source.id));
          expect(library.noteForId(source.id)?.rawBody, source.rawBody);
        }
        metadata['noteId'] = saved.id;
        metadata['remoteNoteId'] = saved.remoteNoteId;
        await capture('saved');
        router.go(AppRoutePaths.workbench);
        await _tapKey(tester, 'workbench-free-creation');
        await _wait(tester, () => _body.evaluate().isNotEmpty, 'fresh Canvas');
        expect(_text(tester).trim(), isEmpty);
        await tester.tap(
          find.byType(V3NavigationBackButton).hitTestable().last,
        );
        await _wait(
          tester,
          () => _body.evaluate().isEmpty,
          'leave fresh Canvas',
        );
        expect(drafts.load(), isNull);
        await capture('complete');
        expect(tester.takeException(), isNull);
      } finally {
        await capture('last_state');
      }
    },
    skip: _entry.isEmpty,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

Future<V3FeedItem?> _openEntry(
  WidgetTester tester,
  ProviderContainer container,
  GoRouter router,
) async {
  if (_entry.startsWith('note-') ||
      _entry == 'history' ||
      _entry == 'canvas-history') {
    final library = container.read(knowledgeLibraryControllerProvider);
    await library.restore();
    final note = library.noteForId(_noteId);
    expect(note, isNotNull, reason: 'Audit Note is required.');
    expect(
      note!.title.startsWith('自由创作仿真验证-') || note.title.startsWith('自由创作入口联调-'),
      isTrue,
    );
    if (_entry.startsWith('note-')) {
      router.go(AppRoutePaths.feedItem(note.id));
      await _wait(
        tester,
        () => _key('note-detail-stage-bar').evaluate().isNotEmpty,
        'Note detail',
      );
      if (_entry != 'note-raw') {
        await tester.tap(
          find.text(_entry == 'note-summary' ? '纲要' : '深度洞察').hitTestable(),
        );
        await tester.pump(const Duration(milliseconds: 500));
        const stage = _entry == 'note-summary' ? 'outline' : 'sprout';
        const content = _entry == 'note-summary' ? 'summary' : 'sprout';
        if (_key(
          'detail-generate-$stage',
        ).hitTestable().evaluate().isNotEmpty) {
          await _tapKey(tester, 'detail-generate-$stage');
        }
        await _wait(
          tester,
          () => _key('detail-$content-content').evaluate().isNotEmpty,
          'generated $stage source',
          timeout: const Duration(minutes: 3),
        );
      }
      await _tapKey(tester, 'detail-floating-action-Agent 自由创作');
      return note;
    }
    if (_entry == 'history') {
      router.go('/v3/profile/account');
      await _tapKey(tester, 'account-service-creation-history', scroll: true);
    } else {
      router.go(AppRoutePaths.workbench);
      await _tapKey(tester, 'workbench-free-creation');
      await _tapKey(tester, 'canvas-more-actions');
      await tester.tap(find.text('创作历史').hitTestable());
    }
    await _tapKey(tester, 'creation-history-${note.id}', scroll: true);
    return note;
  }
  if (_entry.startsWith('external-')) {
    router.go(
      _entry == 'external-square'
          ? AppRoutePaths.knowledgeSquare
          : AppRoutePaths.knowledge,
    );
    if (_entry == 'external-subscribed') {
      await _tapKey(tester, 'knowledge-tab-subscribed');
      await _tapKey(
        tester,
        'remote-subscribed-selected-publication',
        scroll: true,
      );
    }
    final article = _prefix(
      _entry == 'external-square'
          ? 'remote-knowledge-world-hero-'
          : 'subscription-open-',
    );
    await _wait(
      tester,
      () => article.evaluate().isNotEmpty,
      'available external article',
      timeout: const Duration(seconds: 60),
    );
    await tester.ensureVisible(article.first);
    await _wait(
      tester,
      () => article.hitTestable().evaluate().isNotEmpty,
      'external article ready to tap',
    );
    await tester.tap(article.hitTestable().first);
    if (_entry == 'external-square') {
      await _wait(
        tester,
        () => find.text('阅读文章').hitTestable().evaluate().isNotEmpty,
        'external hero preview',
      );
      await tester.tap(find.text('阅读文章').hitTestable());
    }
    await _wait(
      tester,
      () => _key('external-article-free-creation').evaluate().isNotEmpty,
      'external reader creation-copy capability',
      timeout: const Duration(seconds: 60),
    );
    final sourceId = tester
        .widget<V3FeedItemDetailPage>(find.byType(V3FeedItemDetailPage).last)
        .itemId;
    final source = container
        .read(knowledgeLibraryControllerProvider)
        .noteForId(sourceId);
    expect(source, isNotNull);
    expect(source!.isReadOnly, isTrue);
    await _tapKey(tester, 'external-article-free-creation', scroll: true);
    return source;
  }
  router.go(AppRoutePaths.workbench);
  if (_entry == 'daily') {
    final topic = _prefix('workbench-today-topic-');
    await _wait(
      tester,
      () => topic.evaluate().isNotEmpty,
      'daily recommendation',
    );
    await tester.ensureVisible(topic.first);
    await tester.tap(topic.first.hitTestable());
    await _tapKey(tester, 'detail-floating-action-Agent 自由创作');
  } else {
    await _tapKey(tester, 'workbench-free-creation');
    await _wait(tester, () => _body.evaluate().isNotEmpty, 'blank editor');
    if (_entry == 'canvas-new') {
      await tester.enterText(_key('canvas-title-field'), '自由创作入口联调-待放弃测试草稿');
      await _tapKey(tester, 'canvas-more-actions');
      await tester.tap(find.text('新建笔记').hitTestable());
      await _wait(
        tester,
        () => find.text('放弃当前内容并新建').evaluate().isNotEmpty,
        'new draft confirmation',
      );
      await tester.tap(find.text('放弃当前内容并新建'));
      await _wait(
        tester,
        () => tester
            .widget<TextField>(_key('canvas-title-field'))
            .controller!
            .text
            .isEmpty,
        'new draft reset',
      );
    }
  }
  return null;
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));
String _boundFingerprint(V3FeedItem note) => scriptDraftContentHash(
  jsonEncode({
    'id': note.id,
    'localRevision': note.localRevision,
    'title': note.title,
    'rawBody': note.rawBody,
    'linkedMaterials': [
      for (final material in note.linkedMaterials)
        {
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
Finder _prefix(String prefix) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);
Finder get _body => find.byKey(
  const ValueKey<String>('canvas-body-field'),
  skipOffstage: false,
);
QuillController _editor(WidgetTester tester) =>
    tester.widget<QuillEditor>(_body).controller;
String _text(WidgetTester tester) =>
    _editor(tester).document.toPlainText().trimRight();

Future<void> _focusBody(WidgetTester tester) async {
  tester.widget<QuillEditor>(_body).focusNode.requestFocus();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _tapKey(
  WidgetTester tester,
  String key, {
  bool scroll = false,
}) async {
  if (key == 'workbench-free-creation') {
    final workbench = find.byKey(
      const PageStorageKey<String>('workbench-home-scroll'),
    );
    await _wait(
      tester,
      () => workbench.evaluate().isNotEmpty,
      'workbench list',
    );
    if (_key(key).hitTestable().evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        _key(key),
        -450,
        scrollable: find
            .descendant(of: workbench, matching: find.byType(Scrollable))
            .first,
      );
    }
  }
  if (scroll && _key(key).evaluate().isEmpty) {
    final viewport = find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .hitTestable();
    await _wait(
      tester,
      () => viewport.evaluate().isNotEmpty,
      '$key scroll viewport',
    );
    await tester.scrollUntilVisible(
      _key(key),
      450,
      scrollable: viewport.last,
      maxScrolls: 30,
    );
  }
  await _wait(tester, () => _key(key).evaluate().isNotEmpty, key);
  if (scroll) await tester.ensureVisible(_key(key));
  await _wait(
    tester,
    () => _key(key).hitTestable().evaluate().isNotEmpty,
    '$key visible',
  );
  await tester.tap(_key(key).hitTestable());
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() predicate,
  String stage, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clock = Stopwatch()..start();
  while (!predicate() && clock.elapsed < timeout) {
    if (stage == 'editable Canvas' &&
        _key(
          'canvas-initial-draft-retry',
        ).hitTestable().evaluate().isNotEmpty) {
      fail('CANVAS_ENTRY_BOOTSTRAP_FAILURE: visible retry during $stage');
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(predicate(), isTrue, reason: 'CANVAS_ENTRY_CHAT_TIMEOUT: $stage');
}
