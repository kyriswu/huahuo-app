import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_controller.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_providers.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_masterpiece_page.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_workspace_controller.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_overlays.dart';

import '../book_work/masterpiece_test_support.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'information sheet fits compact large text and closes in ${dark ? 'dark' : 'light'} mode',
      (tester) async {
        final runtime = MasterpieceController(
          remote: TestMasterpieceRemote(),
          store: TestMasterpieceStore(),
        );
        await _pump(
          tester,
          runtime,
          theme: dark ? HuahuoV3Theme.dark() : HuahuoV3Theme.light(),
          size: dark ? const Size(1688, 780) : const Size(640, 1136),
          textScale: 1.6,
        );
        await tester.tap(find.byKey(const ValueKey('masterpiece-more')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(V3SheetScaffold), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
        final bounds = tester.getRect(
          find.byKey(const ValueKey('masterpiece-information-sheet')),
        );
        final viewport =
            tester.view.physicalSize / tester.view.devicePixelRatio;
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(V3SheetScaffold), findsNothing);
        await tester.tap(find.byKey(const ValueKey('masterpiece-more')));
        await tester.pumpAndSettle();
        final hide = find.byKey(const ValueKey('masterpiece-information-hide'));
        await tester.scrollUntilVisible(
          hide,
          120,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('masterpiece-information-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.tap(hide);
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(V3MasterpiecePage)),
        );
        expect(
          container
              .read(profileWorkspaceControllerProvider)
              .masterpiece
              .isVisible,
          isFalse,
        );
        expect(find.byType(V3SheetScaffold), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'offline restored draft exposes baseline retry without losing input',
    (tester) async {
      final store = TestMasterpieceStore()
        ..value = const MasterpieceDraft(
          bookId: 'book-1',
          sectionKey: 'chapter-new',
          title: '离线稿',
          markdown: '未提交正文',
        );
      final remote = TestMasterpieceRemote()
        ..readFailure = StateError('offline');
      final runtime = MasterpieceController(remote: remote, store: store);
      await _pump(tester, runtime);
      expect(find.text('重新校验云端基线'), findsOneWidget);
      expect(runtime.canSave, isFalse);
      remote.readFailure = null;
      await tester.tap(find.text('重新校验云端基线'));
      await tester.pumpAndSettle();
      expect(runtime.canSave, isTrue);
      expect(runtime.draft!.markdown, '未提交正文');
    },
  );

  testWidgets(
    'promoted chapter explicitly confirms a separate preserved-source draft',
    (tester) async {
      final runtime = MasterpieceController(
        remote: TestMasterpieceRemote(
          snapshot: masterpieceSnapshot(
            managedSourceRefs: [
              SharedManagedWorkPartLineageRef(
                workId: 'work-1',
                part: 'raw',
                partRevisionId: 'work-part-1',
              ),
            ],
          ),
        ),
        store: TestMasterpieceStore(),
      );
      await _pump(tester, runtime);
      await tester.tap(find.byTooltip('续写为新章节 第一章'));
      await tester.pumpAndSettle();
      expect(runtime.draft, isNull);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(runtime.draft!.isNew, isTrue);
      expect(runtime.draft!.managedSourceRefs.single.kind, 'work_part');
      expect(runtime.draft!.sectionKey, isNot('chapter-1'));
    },
  );

  testWidgets(
    'empty cloud Book supports creating and saving the first chapter',
    (tester) async {
      final remote = TestMasterpieceRemote(
        snapshot: masterpieceSnapshot(empty: true),
      );
      final runtime = MasterpieceController(
        remote: remote,
        store: TestMasterpieceStore(),
      );
      await _pump(tester, runtime);
      expect(
        find.text('从第一个章节开始\n\n手写内容、与 AI 讨论，或从“典藏与创作”纳入已完成的作品。'),
        findsOneWidget,
      );
      expect(find.textContaining('100 篇'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('masterpiece-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('masterpiece-chapter-title')),
        '新的章节',
      );
      final editor = tester.widget<QuillEditor>(
        find.byKey(const ValueKey('masterpiece-editor')),
      );
      expect(editor.config.contextMenuBuilder, isNotNull);
      editor.controller.replaceText(
        0,
        0,
        '第一段正文',
        const TextSelection.collapsed(offset: 5),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('masterpiece-edit-done')));
      await tester.pumpAndSettle();
      expect(remote.writes, hasLength(1));
      expect(runtime.phase, MasterpiecePhase.reading);
      expect(
        runtime.snapshot!.chapters.single.revision!.contentMarkdown,
        contains('第一段正文'),
      );
      expect(find.byKey(const ValueKey('masterpiece-editor')), findsNothing);
    },
  );

  testWidgets(
    'cloud chapters are readable without a local note gate and edits preserve raw syntax',
    (tester) async {
      const source = '![保留图片](resource-image)\n\n原始正文';
      final runtime = MasterpieceController(
        remote: TestMasterpieceRemote(
          snapshot: masterpieceSnapshot(markdown: source),
        ),
        store: TestMasterpieceStore(),
      );
      await _pump(tester, runtime);
      expect(find.text('我的云端代表作'), findsOneWidget);
      await tester.tap(find.byTooltip('编辑 第一章'));
      await tester.pumpAndSettle();
      expect(runtime.draft!.markdown, source);
      final rawEditor = find.byKey(
        const ValueKey('masterpiece-markdown-editor'),
      );
      expect(rawEditor, findsOneWidget);
      await tester.enterText(rawEditor, '$source\n补充正文');
      await tester.pump();
      expect(runtime.draft!.markdown, '$source\n补充正文');
      await tester.tap(find.text('放弃本机草稿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(runtime.draft, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'missing backend Book reports unavailable instead of generating local content',
    (tester) async {
      final remote = TestMasterpieceRemote()
        ..readFailure = const MasterpieceRemoteException(
          'BOOK_NOT_FOUND',
          status: 404,
        );
      final runtime = MasterpieceController(
        remote: remote,
        store: TestMasterpieceStore(),
      );
      await _pump(tester, runtime);
      expect(find.textContaining('尚未初始化代表作'), findsOneWidget);
      expect(find.byKey(const ValueKey('masterpiece-new')), findsNothing);
      await tester.tap(find.text('重新读取云端'));
      await tester.pumpAndSettle();
      expect(remote.reads, 2);
      expect(remote.writes, isEmpty);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  MasterpieceController runtime, {
  ThemeData? theme,
  Size size = const Size(780, 1688),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [masterpieceControllerProvider.overrideWith((ref) => runtime)],
      child: MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: const Scaffold(body: V3MasterpiecePage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
