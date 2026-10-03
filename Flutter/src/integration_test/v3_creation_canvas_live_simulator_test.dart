import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_ai_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _liveAudit = bool.fromEnvironment('HUAHUO_CANVAS_LIVE_AUDIT');
const _resumeTitle = String.fromEnvironment(
  'HUAHUO_CANVAS_LIVE_AUDIT_RESUME_TITLE',
);
const _firstSkill = int.fromEnvironment('HUAHUO_CANVAS_LIVE_AUDIT_FIRST_SKILL');
const _sourceNoteId = String.fromEnvironment(
  'HUAHUO_CANVAS_LIVE_AUDIT_NOTE_ID',
);
const _auditBody =
    '创作者经常收集很多灵感，却不知道从哪里开始。\n\n'
    '先记录今天遇到的一个真实问题，再写出一项能够在明天完成的小行动。'
    '不要编造数据，用实际反馈检验内容是否清楚。\n\n'
    '把复杂的产品讲清楚，让读者知道下一步可以做什么。';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'live Canvas skills and repeated Chat save lifecycle',
    (tester) async {
      expect(defaultTargetPlatform, TargetPlatform.iOS);
      binding.testTextInput.register();
      addTearDown(binding.testTextInput.unregister);
      final stages = <Map<String, Object?>>[];
      final rejectedSkills = <String>[];
      final support = await getApplicationSupportDirectory();
      final directory = Directory('${support.path}/CanvasLiveAudit');
      await directory.create(recursive: true);
      Future<void> capture(String stage) async {
        debugPrint('CANVAS_LIVE_STAGE $stage');
        stages.add({
          'stage': stage,
          'utc': DateTime.now().toUtc().toIso8601String(),
          'firstSkill': _firstSkill,
        });
        await File(
          '${directory.path}/stages.json',
        ).writeAsString(jsonEncode(stages));
        final image = await binding.takeScreenshot(stage);
        await File('${directory.path}/$stage.png').writeAsBytes(image);
      }

      try {
        await app.main();
        await _wait(
          tester,
          () => find.byType(Scaffold).evaluate().isNotEmpty,
          'startup',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold).first),
        );
        await _wait(
          tester,
          () => _readySession(container),
          'authenticated session',
          timeout: const Duration(seconds: 45),
        );
        final drafts = container.read(creationCanvasDraftRepositoryProvider);
        final existing = drafts.load();
        expect(
          existing == null ||
              (_resumeTitle.isNotEmpty &&
                  existing.title == _resumeTitle &&
                  existing.entryIdentity == 'blank' &&
                  existing.boundNoteId == null &&
                  existing.historyCommitReceipt == null &&
                  existing.chatRewriteReceipts.length <= 2 &&
                  existing.chatRewriteReceipts.every(
                    (receipt) => receipt.assistantMessageId != null,
                  )),
          isTrue,
          reason: 'Never overwrite a pre-existing user Canvas draft.',
        );
        final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
        final title =
            existing?.title ??
            '自由创作仿真验证-${DateTime.now().millisecondsSinceEpoch}';
        router.go(AppRoutePaths.workbench);
        await _tap(tester, 'workbench-free-creation');
        await _wait(tester, () => _body.evaluate().isNotEmpty, 'blank canvas');
        await tester.enterText(_key('canvas-title-field'), title);
        _replaceBody(tester, _auditBody);
        await tester.pump(const Duration(seconds: 1));
        await capture('01_blank_entry');

        for (final action in CanvasAiAction.values.skip(_firstSkill)) {
          await _tap(tester, 'canvas-ai-tools');
          final control = _key('canvas-ai-action-${action.name}');
          await tester.scrollUntilVisible(
            control,
            180,
            scrollable: find.descendant(
              of: _key('canvas-ai-action-list'),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.tap(control.hitTestable());
          await tester.pump(const Duration(milliseconds: 350));
          if (find.text('需要先完成定位对话').evaluate().isNotEmpty) {
            rejectedSkills.add('${action.name}: positioning required');
            await capture('prerequisite_${action.name}');
            await tester.binding.handlePopRoute();
            await tester.pump(const Duration(milliseconds: 350));
            await _tap(tester, 'canvas-edit-mode');
            continue;
          }
          final variant = switch (action) {
            CanvasAiAction.socialRelationShift =>
              CanvasRelationTarget.values.first.label,
            CanvasAiAction.openingOptimization =>
              CanvasOpeningVariant.values.first.label,
            CanvasAiAction.imageBrief => CanvasImageVariant.values.first.label,
            _ => null,
          };
          if (variant != null) {
            await tester.ensureVisible(find.text(variant).last);
            await tester.tap(find.text(variant).last);
          }
          bool finished() =>
              _key('canvas-ai-diff-preview').evaluate().isNotEmpty ||
              find.text('重新生成').evaluate().isNotEmpty;
          await _wait(
            tester,
            finished,
            'live ${action.name}',
            timeout: const Duration(minutes: 3),
          );
          if (_key('canvas-ai-diff-preview').evaluate().isEmpty) {
            await capture('rejected_${action.name}');
            await tester.tap(find.text('重新生成').hitTestable());
            await tester.pump(const Duration(milliseconds: 350));
            await _wait(
              tester,
              finished,
              'retry ${action.name}',
              timeout: const Duration(minutes: 3),
            );
          }
          if (_key('canvas-ai-diff-preview').evaluate().isEmpty) {
            rejectedSkills.add(action.name);
            await capture('failed_${action.name}');
            expect(
              _controller(tester).document.toPlainText().trim(),
              _auditBody,
            );
            await tester.tap(find.text('关闭').hitTestable());
            await tester.pump(const Duration(milliseconds: 350));
            await _tap(tester, 'canvas-edit-mode');
            expect(_controller(tester).readOnly, isFalse);
            continue;
          }
          expect(_controller(tester).document.toPlainText().trim(), _auditBody);
          await capture('skill_${action.name}');
          await _tap(
            tester,
            action == CanvasAiAction.socialRelationShift
                ? 'canvas-ai-apply'
                : 'canvas-ai-reject',
          );
          await _tap(tester, 'canvas-edit-mode');
          expect(_controller(tester).readOnly, isFalse);
          if (action == CanvasAiAction.socialRelationShift) {
            expect(
              _controller(tester).document.toPlainText().trim(),
              isNot(_auditBody),
            );
            _replaceBody(tester, _auditBody);
            await tester.pump(const Duration(milliseconds: 350));
          }
        }

        final firstChatTurn =
            (drafts.load()?.chatRewriteReceipts.length ?? 0) + 1;
        for (var turn = firstChatTurn; turn <= 2; turn += 1) {
          await tester.tap(_body.hitTestable());
          await tester.pump(const Duration(milliseconds: 350));
          await _tap(tester, 'canvas-chat-entry');
          await _wait(
            tester,
            () => _key('canvas-chat-input').evaluate().isNotEmpty,
            'Chat composer',
          );
          await tester.enterText(
            _key('canvas-chat-input'),
            '这是仿真验证第 $turn 轮。请用两句话建议如何让正文更清楚，不要直接修改笔记。',
          );
          await _wait(
            tester,
            () =>
                tester.widget<IconButton>(_key('canvas-chat-send')).onPressed !=
                null,
            'Chat send admission after canonical readback',
          );
          await tester.tap(find.byTooltip('发送').hitTestable());
          await _wait(
            tester,
            () {
              final receipts = drafts.load()?.chatRewriteReceipts;
              return receipts != null &&
                  receipts.length == turn &&
                  receipts.every(
                    (receipt) => receipt.assistantMessageId != null,
                  );
            },
            'live Chat turn $turn',
            timeout: const Duration(minutes: 3),
          );
          await capture('chat_$turn');
          await _tap(tester, 'canvas-chat-close');
          expect(_controller(tester).document.toPlainText().trim(), _auditBody);
        }

        final expectedMarkdown = drafts.load()!.markdown;
        await _tap(tester, 'canvas-save');
        await _wait(
          tester,
          () => find.text('确认保存').evaluate().isNotEmpty,
          'save confirmation',
        );
        await tester.tap(find.text('确认保存'));
        await _wait(
          tester,
          () => _body.evaluate().isEmpty,
          'cloud save',
          timeout: const Duration(minutes: 2),
        );
        final library = container.read(knowledgeLibraryControllerProvider);
        final saved = library.notes.singleWhere((note) => note.title == title);
        debugPrint('CANVAS_LIVE_AUDIT_NOTE_ID=${saved.id}');
        expect(saved.syncState, NoteSyncState.synced);
        expect(saved.remoteNoteId, isNotEmpty);
        expect(saved.rawBody, expectedMarkdown.trim());
        expect(drafts.load(), isNull);
        await capture('02_cloud_saved');

        router.go(AppRoutePaths.workbench);
        await _tap(tester, 'workbench-free-creation');
        await _wait(tester, () => _body.evaluate().isNotEmpty, 'fresh entry');
        expect(_controller(tester).document.toPlainText().trim(), isEmpty);
        await capture('03_fresh_entry');
        await _leaveCanvas(tester);
        expect(drafts.load(), isNull);
        await capture('blank_chat_save_complete');
        expect(tester.takeException(), isNull);
        expect(
          rejectedSkills,
          isEmpty,
          reason: 'Live Skills rejected both initial and retry results.',
        );
      } finally {
        await capture('last_state');
      }
    },
    skip: !_liveAudit || _sourceNoteId.isNotEmpty,
    timeout: const Timeout(Duration(minutes: 35)),
  );

  testWidgets(
    'live Canvas Note and daily source entries',
    (tester) async {
      binding.testTextInput.register();
      addTearDown(binding.testTextInput.unregister);
      Future<void> capture(String stage) async {
        debugPrint('CANVAS_LIVE_SOURCE_STAGE $stage');
        final directory = Directory(
          '${(await getApplicationSupportDirectory()).path}/CanvasLiveAudit',
        );
        await directory.create(recursive: true);
        await File(
          '${directory.path}/source_$stage.png',
        ).writeAsBytes(await binding.takeScreenshot('source_$stage'));
      }

      try {
        const noteId = _sourceNoteId;
        expect(
          noteId,
          isNotEmpty,
          reason: 'An exact audit Note ID is required for source acceptance.',
        );
        await app.main();
        await _wait(
          tester,
          () => find.byType(Scaffold).evaluate().isNotEmpty,
          'startup',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold).first),
        );
        await _wait(
          tester,
          () => _readySession(container),
          'authenticated session',
          timeout: const Duration(seconds: 45),
        );
        final drafts = container.read(creationCanvasDraftRepositoryProvider);
        expect(
          drafts.load(),
          isNull,
          reason: 'Never replace a pre-existing Canvas draft.',
        );
        final library = container.read(knowledgeLibraryControllerProvider);
        await library.restore();
        final saved = library.notes.singleWhere((note) => note.id == noteId);
        expect(saved.title.startsWith('自由创作仿真验证-'), isTrue);
        expect(saved.syncState, NoteSyncState.synced);
        final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
        router.go(AppRoutePaths.workbench);
        await _tap(tester, 'workbench-free-creation');
        await _wait(
          tester,
          () => _body.evaluate().isNotEmpty,
          'fresh post-save entry',
        );
        expect(_controller(tester).document.toPlainText().trim(), isEmpty);
        await capture('fresh_entry');
        router.go(AppRoutePaths.feedItem(saved.id));
        final existingIds = library.notes.map((note) => note.id).toSet();
        await _tap(tester, 'detail-floating-action-Agent 自由创作');
        await _wait(
          tester,
          () =>
              _body.evaluate().isNotEmpty &&
              _controller(tester).document.toPlainText().trim().isNotEmpty &&
              find.text('已保存').evaluate().isNotEmpty &&
              drafts.load() == null &&
              container
                  .read(knowledgeLibraryControllerProvider)
                  .notes
                  .any(
                    (note) =>
                        note.title == saved.title &&
                        !existingIds.contains(note.id) &&
                        note.syncState == NoteSyncState.synced,
                  ),
          'Note generated copy',
          timeout: const Duration(minutes: 3),
        );
        expect(
          container
              .read(knowledgeLibraryControllerProvider)
              .notes
              .singleWhere((note) => note.id == saved.id)
              .rawBody,
          saved.rawBody,
        );
        await capture('note_copy');
        await _tap(tester, 'canvas-ai-tools');
        await _tap(tester, 'canvas-edit-mode');
        await _leaveCanvas(tester);
        router.go(AppRoutePaths.workbench);
        final topic = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'workbench-today-topic-',
              ),
        );
        await _wait(
          tester,
          () => topic.evaluate().isNotEmpty,
          'today recommendation',
          timeout: const Duration(seconds: 45),
        );
        await tester.ensureVisible(topic.first);
        await tester.tap(topic.first.hitTestable());
        await _tap(tester, 'detail-floating-action-Agent 自由创作');
        await _wait(
          tester,
          () =>
              _body.evaluate().isNotEmpty &&
              _controller(tester).document.toPlainText().trim().isNotEmpty &&
              !_controller(tester).readOnly,
          'daily generated copy',
          timeout: const Duration(minutes: 3),
        );
        await capture('daily_copy');
        final dailyTitle = '${saved.title}-今日推荐';
        await tester.enterText(_key('canvas-title-field'), dailyTitle);
        await _tap(tester, 'canvas-save');
        await _wait(
          tester,
          () => find.text('确认保存').evaluate().isNotEmpty,
          'daily save confirmation',
        );
        await tester.tap(find.text('确认保存'));
        await _wait(
          tester,
          () => _body.evaluate().isEmpty,
          'daily cloud save',
          timeout: const Duration(minutes: 2),
        );
        expect(
          container
              .read(knowledgeLibraryControllerProvider)
              .notes
              .singleWhere((note) => note.title == dailyTitle)
              .syncState,
          NoteSyncState.synced,
        );
        expect(drafts.load(), isNull);
        await capture('complete');
        expect(tester.takeException(), isNull);
      } finally {
        await capture('last_state');
      }
    },
    skip: !_liveAudit || _sourceNoteId.isEmpty,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<void> _leaveCanvas(WidgetTester tester) async {
  await tester.tap(find.byType(V3NavigationBackButton).hitTestable().last);
  await _wait(tester, () => _body.evaluate().isEmpty, 'Canvas Back navigation');
}

bool _readySession(ProviderContainer container) {
  final session = container.read(sessionStoreProvider).state;
  return session.authState == SessionAuthState.authenticated &&
      session.workspace?.status == SessionWorkspaceStatus.ready &&
      session.workspace?.workspaceId?.isNotEmpty == true;
}

Finder get _body => find.byKey(
  const ValueKey<String>('canvas-body-field'),
  skipOffstage: false,
);
QuillController _controller(WidgetTester tester) =>
    tester.widget<QuillEditor>(_body).controller;

void _replaceBody(WidgetTester tester, String value) {
  final controller = _controller(tester);
  controller.replaceText(
    0,
    controller.document.length - 1,
    value,
    TextSelection.collapsed(offset: value.length),
  );
}

Future<void> _tap(WidgetTester tester, String key) async {
  await _wait(tester, () => _key(key).hitTestable().evaluate().isNotEmpty, key);
  await tester.tap(_key(key).hitTestable());
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() condition,
  String stage, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final clock = Stopwatch()..start();
  while (!condition() && clock.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(condition(), isTrue, reason: 'LIVE_CANVAS_TIMEOUT: $stage');
}
