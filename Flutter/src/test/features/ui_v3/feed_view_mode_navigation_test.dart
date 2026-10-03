import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/app/navigation/app_routes.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_view_mode_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_app_shell.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_node_action_card.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_interactive_graph.dart';
import 'package:huahuoai_app/shared/navigation/safe_navigation.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

import 'graph_test_fixture.dart';

void main() {
  test(
    'dimension is initialized once and resets with workspace scope',
    () async {
      final container = ProviderContainer(
        overrides: [
          knowledgeLibraryCacheScopeProvider.overrideWithValue(
            'account/workspace-a',
          ),
        ],
      );
      addTearDown(container.dispose);
      final mode = container.read(feedViewModeControllerProvider);
      mode.initialize(initiallyShowNotes: false);
      mode.initialize(initiallyShowNotes: true);
      expect(mode.mode, FeedViewMode.sphere);
      mode.select(FeedViewMode.notes);
      mode.initialize(initiallyShowNotes: false);
      expect(mode.mode, FeedViewMode.notes);
      mode.select(FeedViewMode.sphere);
      container.updateOverrides([
        knowledgeLibraryCacheScopeProvider.overrideWithValue(
          'account/workspace-b',
        ),
      ]);
      await container.pump();
      final fresh = container.read(feedViewModeControllerProvider);
      expect(fresh, isNot(same(mode)));
      fresh.initialize(initiallyShowNotes: true);
      expect(fresh.mode, FeedViewMode.notes);
    },
  );

  for (final notes in [true, false]) {
    testWidgets(
      '${notes ? '1D' : '3D'} survives notification return and home reconstruction',
      (tester) async {
        final harness = await _pumpHome(tester);
        if (!notes) {
          await tester.tap(find.byKey(const ValueKey('feed-home-mode-3d')));
          await tester.pumpAndSettle();
        }
        final graph = harness.container.read(feedGraphControllerProvider);
        graph.selectNode(graphTestPrimaryNoteId);
        await tester.pumpAndSettle();
        _expectMode(tester, notes: notes, selected: true);
        final originalHome = tester.state(find.byType(V3AppShell));

        await tester.tap(find.byKey(const ValueKey('home-feed-notifications')));
        await tester.pumpAndSettle();
        expect(find.text('notification-target'), findsOneWidget);
        await tester.tap(find.text('notification-target'));
        await tester.pumpAndSettle();
        expect(find.text('asset-detail'), findsOneWidget);
        await tester.tap(find.text('return-home'));
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(V3AppShell)), same(originalHome));
        _expectMode(tester, notes: notes, selected: true);

        harness.router.go(AppRoutePaths.assets);
        await tester.pumpAndSettle();
        expect(find.byType(V3AppShell), findsNothing);
        await tester.tap(find.text('return-home'));
        await tester.pumpAndSettle();
        expect(
          tester.state(find.byType(V3AppShell)),
          isNot(same(originalHome)),
        );
        _expectMode(tester, notes: notes, selected: true);

        if (!notes) {
          await tester.timedDragFrom(
            const Offset(195, 330),
            const Offset(-110, 0),
            const Duration(milliseconds: 300),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<V3FeedPage>(find.byType(V3FeedPage)).active,
            isTrue,
          );
          expect(
            find.byKey(const ValueKey('v3-profile-side-panel')),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    '1D never renders a stale graph card and explicit switching clears focus',
    (tester) async {
      final harness = await _pumpHome(tester);
      final graph = harness.container.read(feedGraphControllerProvider);
      graph.selectNode(graphTestPrimaryNoteId);
      await tester.pumpAndSettle();
      _expectMode(tester, notes: true, selected: true);
      await tester.tap(find.byKey(const ValueKey('feed-home-mode-3d')));
      await tester.pumpAndSettle();
      _expectMode(tester, notes: false, selected: true);
      await tester.tap(find.byKey(const ValueKey('feed-home-mode-1d')));
      await tester.pumpAndSettle();
      expect(graph.selectedNodeId, isNull);
      _expectMode(tester, notes: true, selected: false);
      graph.selectNode(graphTestPrimaryNoteId);
      await tester.pumpAndSettle();
      _expectMode(tester, notes: true, selected: true);
      await tester.tap(find.byKey(const ValueKey('feed-home-mode-3d')));
      await tester.pumpAndSettle();
      harness.container.invalidate(feedGraphControllerProvider);
      await tester.pumpAndSettle();
      _expectMode(tester, notes: false, selected: false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('1D search opens detail without revealing the 3D card', (
    tester,
  ) async {
    final harness = await _pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('home-feed-search')));
    await tester.pumpAndSettle();
    final graph = harness.container.read(feedGraphControllerProvider);
    graph.setSearchQuery('睡眠');
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('选择笔记 睡眠、精力与重大选择'));
    await tester.pumpAndSettle();
    expect(find.text('note-detail-$graphTestSearchNoteId'), findsOneWidget);
    expect(graph.selectedNodeId, isNull);
    await tester.tap(find.text('return-home'));
    await tester.pumpAndSettle();
    _expectMode(tester, notes: true, selected: false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

void _expectMode(
  WidgetTester tester, {
  required bool notes,
  required bool selected,
}) {
  expect(
    find.byKey(const ValueKey('feed-notes-center')),
    notes ? findsOneWidget : findsNothing,
  );
  expect(
    find.byType(V3InteractiveGraph),
    notes ? findsNothing : findsOneWidget,
  );
  expect(
    find.byType(V3GraphNodeActionCard),
    !notes && selected ? findsOneWidget : findsNothing,
  );
  final semantics = tester.getSemantics(
    find.byKey(ValueKey('feed-home-mode-${notes ? '1d' : '3d'}')),
  );
  expect(
    semantics,
    matchesSemantics(
      isSelected: true,
      hasSelectedState: true,
      isButton: true,
      hasEnabledState: true,
      isEnabled: true,
      label: notes ? '1D 笔记' : '3D 图谱',
    ),
  );
}

Future<({GoRouter router, ProviderContainer container})> _pumpHome(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final library = KnowledgeLibraryController(
    initialNotes: buildGraphTestNotes(count: 8),
    includeDemoFixtures: false,
  );
  for (final note in library.notes.where((note) => !note.isHotspot)) {
    library.depositContent(note.id);
  }
  final home =
      buildAppRoutes(
        splashBuilder: (_, _) => const SizedBox.shrink(),
        restoreFailedBuilder: (_, _) => const SizedBox.shrink(),
        workspaceRetryBuilder: (_, _) => const SizedBox.shrink(),
      ).whereType<GoRoute>().singleWhere(
        (route) => route.path == AppRoutePaths.home,
      );
  final router = GoRouter(
    initialLocation: AppRoutePaths.home,
    observers: [appRouteObserver],
    routes: [
      home,
      GoRoute(
        path: AppRoutePaths.notifications,
        builder: (context, state) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => context.replace(AppRoutePaths.assets),
              child: const Text('notification-target'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutePaths.assets,
        builder: (context, state) => _detail(context, 'asset-detail'),
      ),
      GoRoute(
        path: '/v3/feed/items/:itemId',
        builder: (context, state) =>
            _detail(context, 'note-detail-${state.pathParameters['itemId']}'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        resolvedDeviceIdProvider.overrideWithValue('feed-mode-test-device'),
        knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        feedGraphControllerProvider.overrideWith(
          (ref) => FeedGraphController(library),
        ),
      ],
      child: MaterialApp.router(
        theme: HuahuoV3Theme.light(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(V3AppShell)),
  );
  final graphSubscription = container.listen(
    feedGraphControllerProvider,
    (_, _) {},
  );
  addTearDown(graphSubscription.close);
  return (router: router, container: container);
}

Widget _detail(BuildContext context, String title) => Scaffold(
  body: Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title),
        TextButton(
          onPressed: () =>
              returnToPreviousRoute(context, fallbackRoute: AppRoutePaths.home),
          child: const Text('return-home'),
        ),
      ],
    ),
  ),
);
