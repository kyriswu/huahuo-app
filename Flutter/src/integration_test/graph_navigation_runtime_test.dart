import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_app_shell.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_my_assets_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/features/ui_v3/graph_test_fixture.dart';
import '../test/features/ui_v3/v3_app_shell_gesture_test.dart' as shell;
import '../test/features/ui_v3/v3_graph_fullscreen_page_test.dart'
    as fullscreen;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('search keyboard simulator audit', (tester) async {
    final library = KnowledgeLibraryController(
      initialNotes: buildGraphTestNotes(),
      includeDemoFixtures: false,
    );
    final graph = FeedGraphController(library);
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => const V3AppShell(
            initialMode: V3HomeMode.feed,
            initialFeedNotes: true,
          ),
        ),
        GoRoute(
          path: '/assets',
          builder: (context, state) => const V3MyAssetsPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('search-audit-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: HuahuoV3Theme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('feed-graph-search-open')));
    await tester.pump(const Duration(milliseconds: 500));
    final input = find.byKey(const ValueKey('feed-graph-search-input'));
    await tester.tap(input);
    await tester.pump(const Duration(milliseconds: 200));
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    final editable = find.descendant(
      of: input,
      matching: find.byType(EditableText),
    );
    final target = find.byKey(const ValueKey('feed-graph-search-target'));
    expect(
      tester.getCenter(editable).dy,
      closeTo(tester.getCenter(target).dy, 1),
    );
    final inset = MediaQuery.viewInsetsOf(tester.element(input)).bottom;
    final inputRect = tester.getRect(input);
    final support = await getApplicationSupportDirectory();
    const stage = String.fromEnvironment(
      'SEARCH_AUDIT_STAGE',
      defaultValue: 'before',
    );
    final bytes = await binding.takeScreenshot('graph-search-$stage');
    final screenshot = File('${support.path}/graph-search-$stage.png');
    await screenshot.writeAsBytes(bytes, flush: true);
    debugPrint(
      'SEARCH_AUDIT stage=$stage keyboard=$inset input=$inputRect screenshot=${screenshot.path}',
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    expect(tester.takeException(), isNull);
    router.go('/assets');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(V3MyAssetsPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-assets-search')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('asset-search-group-tags')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BottomSheet), findsNothing);
    final assetBytes = await binding.takeScreenshot('asset-search-$stage');
    final assetScreenshot = File('${support.path}/asset-search-$stage.png');
    await assetScreenshot.writeAsBytes(assetBytes, flush: true);
    debugPrint('SEARCH_AUDIT stage=assets-$stage screenshot=${assetScreenshot.path}');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    expect(tester.takeException(), isNull);
  });
  shell.runGraphShellGestureTests(nativeRuntime: true);
  fullscreen.main();
}
