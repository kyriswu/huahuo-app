import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_app_shell.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_masterpiece_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

import 'graph_test_fixture.dart';

void main() => runGraphShellGestureTests();

void runGraphShellGestureTests({bool nativeRuntime = false}) {
  testWidgets('profile remains reachable after a child goes to retained home', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final library = KnowledgeLibraryController(
      initialNotes: buildGraphTestNotes(),
    );
    Completer<String?>? accountRedirect;
    final router = GoRouter(
      initialLocation: '/home',
      observers: [appRouteObserver],
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => const V3AppShell(
            initialMode: V3HomeMode.feed,
            initialFeedNotes: true,
          ),
        ),
        GoRoute(
          path: '/v3/profile/account',
          redirect: (context, state) => accountRedirect?.future,
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.go('/home'),
              child: const Text('return-directly-home'),
            ),
          ),
        ),
        GoRoute(
          path: '/profile-child',
          builder: (context, state) =>
              const Scaffold(body: Text('profile-child-page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith(
            (ref) => FeedGraphController(library),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    final homeState = tester.state(find.byType(V3AppShell));
    final panel = find.byKey(const ValueKey('v3-profile-side-panel'));
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('profile-header-account-entry')),
    );
    await tester.pumpAndSettle();
    expect(find.text('return-directly-home'), findsOneWidget);
    await tester.tap(find.text('return-directly-home'));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(V3AppShell)), same(homeState));
    expect(panel, findsNothing);

    await tester.timedDragFrom(
      const Offset(195, 420),
      const Offset(180, 0),
      const Duration(milliseconds: 80),
    );
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-panel-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('profile-header-account-entry')),
    );
    await tester.pumpAndSettle();
    router.push<void>('/profile-child');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('return-directly-home'), findsOneWidget);
    expect(panel, findsNothing);
    router.pop();
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);

    for (final replace in [
      () => router.replace<void>('/profile-child'),
      () => router.pushReplacement<void>('/profile-child'),
    ]) {
      await tester.tap(
        find.byKey(const ValueKey('profile-header-account-entry')),
      );
      await tester.pumpAndSettle();
      replace();
      await tester.pumpAndSettle();
      expect(find.text('profile-child-page'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(tester.state(find.byType(V3AppShell)), same(homeState));
      await tester.tap(find.byTooltip('我的'));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    accountRedirect = Completer<String?>();
    await tester.tap(
      find.byKey(const ValueKey('profile-header-account-entry')),
    );
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    router.go('/home');
    await tester.pumpAndSettle();
    accountRedirect.complete(null);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.state(find.byType(V3AppShell)), same(homeState));
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bottom pager shows the graph only in AI feed mode', (
    tester,
  ) async {
    if (!nativeRuntime) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
    }

    final library = KnowledgeLibraryController(
      initialNotes: buildGraphTestNotes(),
    );
    for (final note in library.notes.where((note) => !note.isHotspot)) {
      library.depositContent(note.id);
    }
    final graphController = FeedGraphController(library);
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) =>
              const V3AppShell(initialMode: V3HomeMode.feed),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graphController),
        ],
        child: MaterialApp.router(
          theme: HuahuoV3Theme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    if (nativeRuntime) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    final pageViewFinder = find.byKey(
      const ValueKey<String>('home-content-mode-pager'),
    );
    final graphFinder = find.byKey(
      const ValueKey('feed-graph-interactive-viewer'),
    );
    final pageView = tester.widget<PageView>(pageViewFinder);
    final graph = tester.widget<InteractiveViewer>(graphFinder);
    final comfortableTravel = (tester.getSize(pageViewFinder).width * .12)
        .clamp(48.0, 64.0)
        .toDouble();

    expect(find.byType(V3FeedPage), findsOneWidget);
    expect(tester.widget<V3FeedPage>(find.byType(V3FeedPage)).active, isTrue);
    expect(pageView.childrenDelegate.estimatedChildCount, 3);
    expect(pageView.controller?.page, 0);
    expect(find.bySemanticsLabel('聊一聊'), findsOneWidget);
    expect(find.byType(V3GraphSearchIcon), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-graph-search-input')), findsNothing);

    if (!nativeRuntime) {
      await tester.tap(find.byType(V3GraphSearchIcon));
      await tester.pump();
      expect(find.byType(V3GraphSearchControl), findsOneWidget);
      final searchInput = find.byKey(const ValueKey('feed-graph-search-input'));
      expect(searchInput, findsOneWidget);
      final searchField = tester.widget<TextField>(searchInput);
      expect(searchField.decoration?.filled, isFalse);
      expect(searchField.decoration?.isCollapsed, isTrue);
      final target = find.byKey(const ValueKey('feed-graph-search-target'));
      expect(tester.getSize(target).height, 44);
      final editable = find.descendant(
        of: searchInput,
        matching: find.byType(EditableText),
      );
      expect(
        tester.getCenter(editable).dy,
        closeTo(tester.getCenter(target).dy, 1),
      );

      await tester.enterText(searchInput, '客户访谈');
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pump();
      expect(find.byType(V3GraphSearchControl), findsNothing);
      expect(find.byType(V3GraphSearchIcon), findsOneWidget);
      expect(find.text('思想图谱'), findsOneWidget);
    }
    final beforeTranslationX = graph.transformationController!.value.entry(
      0,
      3,
    );
    final beforeTranslationY = graph.transformationController!.value.entry(
      1,
      3,
    );
    final sampledNode = find.byKey(const ValueKey(graphTestPrimaryNoteId));
    expect(sampledNode, findsOneWidget);
    final graphRect = tester.getRect(graphFinder);
    final graphCanvasPoint = Offset(graphRect.center.dx, graphRect.top + 180);
    final beforeHorizontalRotationCenter = tester.getCenter(sampledNode);
    await tester.dragFrom(graphCanvasPoint, const Offset(64, 0));
    await tester.pump();
    final horizontalRotationCenter = tester.getCenter(sampledNode);
    expect(
      (horizontalRotationCenter - beforeHorizontalRotationCenter).distance,
      greaterThan(2),
    );
    expect(pageView.controller?.page, 0);

    final beforeRotationCenter = horizontalRotationCenter;
    await tester.dragFrom(graphCanvasPoint, const Offset(64, 52));
    await tester.pump();

    final rotatedTranslationX = graph.transformationController!.value.entry(
      0,
      3,
    );
    final rotatedTranslationY = graph.transformationController!.value.entry(
      1,
      3,
    );
    final rotatedNodeCenter = tester.getCenter(sampledNode);
    expect(rotatedTranslationX, closeTo(beforeTranslationX, .001));
    expect(rotatedTranslationY, closeTo(beforeTranslationY, .001));
    expect((rotatedNodeCenter - beforeRotationCenter).distance, greaterThan(2));
    expect(pageView.controller?.page, 0);

    for (final key in [
      'feed-left-edge-profile-gesture',
      'feed-right-edge-workbench-gesture',
      'feed-bottom-workbench-gesture',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
    final dockGesture = find.byKey(const ValueKey('feed-dock-mode-gesture'));
    final dockRect = tester.getRect(dockGesture);
    expect(dockRect.height, 54);
    expect(dockRect.width, lessThan(300));
    for (final (start, delta) in [
      (Offset(graphRect.left + 12, graphRect.center.dy), const Offset(120, 0)),
      (
        Offset(graphRect.right - 12, graphRect.center.dy),
        const Offset(-120, 0),
      ),
      (
        Offset(graphRect.center.dx, graphRect.bottom - 144),
        const Offset(-120, 0),
      ),
      (dockRect.center, const Offset(-23, 0)),
      (dockRect.center, const Offset(-70, -64)),
    ]) {
      await tester.timedDragFrom(
        start,
        delta,
        const Duration(milliseconds: 80),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      expect(pageView.controller?.page, 0, reason: 'start=$start delta=$delta');
      expect(find.byKey(const ValueKey('v3-profile-side-panel')), findsNothing);
    }

    await tester.timedDragFrom(
      dockRect.center,
      Offset(-(comfortableTravel - 1), 0),
      const Duration(milliseconds: 600),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(pageView.controller?.page, 0);

    final verticalRelease = await tester.startGesture(dockRect.center);
    await verticalRelease.moveBy(
      const Offset(-70, 0),
      timeStamp: const Duration(milliseconds: 100),
    );
    for (var step = 0; step < 4; step++) {
      await verticalRelease.moveBy(
        const Offset(-4, -12),
        timeStamp: Duration(milliseconds: 150 + step * 5),
      );
    }
    await verticalRelease.up(timeStamp: const Duration(milliseconds: 170));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(pageView.controller?.page, 0);
    expect(find.text('思想图谱'), findsOneWidget);

    final canvasToDock = await tester.startGesture(
      Offset(dockRect.center.dx, dockRect.top - 90),
    );
    await canvasToDock.moveTo(dockRect.center);
    await tester.pump();
    expect(pageView.controller?.page, 0);
    await canvasToDock.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(pageView.controller?.page, 0);
    await canvasToDock.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(pageView.controller?.page, 0);

    final zoomBefore = graph.transformationController!.value
        .getMaxScaleOnAxis();
    final pinchLeft = await tester.startGesture(const Offset(140, 440));
    final pinchRight = await tester.startGesture(const Offset(240, 440));
    await pinchLeft.moveBy(const Offset(-30, 0));
    await pinchRight.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(
      graph.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(zoomBefore),
    );
    await pinchLeft.up();
    await pinchRight.up();

    for (final firstPosition in [const Offset(195, 420), dockRect.center]) {
      final firstTouch = await tester.startGesture(firstPosition);
      final secondTouch = await tester.startGesture(
        dockRect.center + const Offset(30, 0),
      );
      if (firstPosition.dy < dockRect.top) {
        await firstTouch.moveBy(const Offset(24, 0));
      }
      await firstTouch.up();
      await secondTouch.moveBy(const Offset(-120, 0));
      await secondTouch.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      expect(pageView.controller?.page, 0);
    }
    final cancelledTouch = await tester.startGesture(dockRect.center);
    await cancelledTouch.moveBy(const Offset(-100, 0));
    await cancelledTouch.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(pageView.controller?.page, 0);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(V3AppShell)),
    );
    final aggregation = container.read(feedAggregationControllerProvider);
    final lockedTouch = await tester.startGesture(dockRect.center);
    await lockedTouch.moveBy(const Offset(-30, 0));
    expect(aggregation.startSelection(), isTrue);
    await tester.pump();
    await tester.drag(pageViewFinder, const Offset(-280, 0));
    await tester.pump(const Duration(milliseconds: 450));
    expect(pageView.controller?.page, 0);
    aggregation.cancelSelection();
    await tester.pump();
    await lockedTouch.moveBy(const Offset(-90, 0));
    await lockedTouch.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(pageView.controller?.page, 0);

    await tester.timedDragFrom(
      dockRect.center,
      const Offset(28, 0),
      const Duration(milliseconds: 40),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final profilePanel = find.byKey(const ValueKey('v3-profile-side-panel'));
    expect(profilePanel, findsOneWidget);
    Navigator.of(tester.element(profilePanel)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    graphController.selectNode(graphTestPrimaryNoteId);
    await tester.pump(const Duration(milliseconds: 450));

    await tester.dragFrom(const Offset(120, 34), const Offset(-100, 0));
    await tester.pump(const Duration(milliseconds: 450));
    expect(pageView.controller?.page, 0);
    expect(find.text('思想图谱'), findsOneWidget);

    final departureTransform = graph.transformationController!.value.clone();
    final bottomGesture = dockGesture;
    expect(bottomGesture, findsOneWidget);
    expect(
      tester.getRect(bottomGesture).right,
      tester.getRect(pageViewFinder).right - 22,
    );
    await tester.timedDragFrom(
      tester.getRect(bottomGesture).center,
      Offset(-comfortableTravel, 0),
      const Duration(milliseconds: 600),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(pageView.controller?.page, 1);
    expect(find.text('创作空间'), findsOneWidget);
    final workbenchChat = find.byKey(
      const ValueKey<String>('home-chat-workbench'),
    );
    expect(workbenchChat, findsNothing);
    expect(find.bySemanticsLabel('聊一聊'), findsNothing);
    expect(find.byType(V3FeedPage), findsNothing);
    expect(graphFinder, findsNothing);
    expect(find.byType(V3FeedPage, skipOffstage: false), findsOneWidget);
    expect(
      tester
          .widget<V3FeedPage>(find.byType(V3FeedPage, skipOffstage: false))
          .active,
      isFalse,
    );
    expect(
      find.byKey(
        const ValueKey('feed-graph-interactive-viewer'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(find.byType(V3GraphSearchControl), findsNothing);
    expect(find.byType(V3GraphSearchIcon), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('workbench-free-creation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('workbench-topic-section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-workbench-dock-frame')),
      findsNothing,
    );
    expect(find.text('今日推送'), findsOneWidget);
    expect(find.text('碰撞'), findsNothing);
    expect(find.text('大师升级'), findsNothing);
    expect(tester.getRect(pageViewFinder).height, greaterThan(700));
    expect(
      find.byKey(const ValueKey<String>('home-workbench-surface')),
      findsOneWidget,
    );
    expect(graphController.selectedNodeId, graphTestPrimaryNoteId);

    final modePageExtent = pageView.controller!.position.viewportDimension;
    pageView.controller!.jumpTo(modePageExtent * .7);
    await tester.pump();
    expect(pageView.controller?.page, closeTo(.7, .001));
    await tester.timedDrag(
      pageViewFinder,
      Offset(-comfortableTravel, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);

    pageView.controller!.jumpTo(modePageExtent * 1.3);
    await tester.pump();
    expect(pageView.controller?.page, closeTo(1.3, .001));
    await tester.timedDrag(
      pageViewFinder,
      Offset(comfortableTravel, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);

    pageView.controller!.jumpTo(modePageExtent * .7);
    await tester.pump();
    await tester.timedDrag(
      pageViewFinder,
      Offset(-(modePageExtent * .3 + comfortableTravel - 1), 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);

    pageView.controller!.jumpTo(modePageExtent * .7);
    await tester.pump();
    await tester.timedDrag(
      pageViewFinder,
      Offset(-(modePageExtent * .3 + comfortableTravel), 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 2);
    await tester.timedDrag(
      pageViewFinder,
      Offset(comfortableTravel, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);
    expect(find.text('创作空间'), findsOneWidget);

    final feedSnap = await tester.startGesture(
      tester.getCenter(pageViewFinder),
    );
    await feedSnap.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(pageView.controller?.page, greaterThan(.5));
    expect(pageView.controller?.page, lessThan(.9));
    await feedSnap.up();
    await tester.pump(const Duration(milliseconds: 16));
    final interruptedPage = pageView.controller!.page!;
    expect(interruptedPage, greaterThan(.5));
    expect(interruptedPage, lessThan(.9));

    final pageRect = tester.getRect(pageViewFinder);
    final interruptedSnap = await tester.startGesture(
      Offset(pageRect.right - 30, pageRect.center.dy),
    );
    await tester.pump();
    expect(find.text('创作空间'), findsOneWidget);
    expect(
      tester
          .widget<V3FeedPage>(find.byType(V3FeedPage, skipOffstage: false))
          .active,
      isFalse,
    );
    await interruptedSnap.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await interruptedSnap.up();
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);
    expect(find.text('创作空间'), findsOneWidget);
    expect(
      tester
          .widget<V3FeedPage>(find.byType(V3FeedPage, skipOffstage: false))
          .active,
      isFalse,
    );

    final cancelledFeedTouch = await tester.startGesture(
      tester.getCenter(pageViewFinder),
    );
    await cancelledFeedTouch.moveBy(const Offset(250, 0));
    await tester.pump();
    expect(pageView.controller?.page, lessThan(.5));
    expect(
      tester
          .widget<V3FeedPage>(find.byType(V3FeedPage, skipOffstage: false))
          .active,
      isFalse,
    );
    expect(find.text('创作空间'), findsOneWidget);
    await cancelledFeedTouch.cancel();
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);
    expect(find.text('创作空间'), findsOneWidget);

    final masterpieceFinder = find.byType(
      V3MasterpiecePage,
      skipOffstage: false,
    );
    final cancelledPageTouch = await tester.startGesture(
      tester.getCenter(pageViewFinder),
    );
    await cancelledPageTouch.moveBy(const Offset(-500, 0));
    await tester.pump();
    expect(pageView.controller?.page, greaterThan(1.9));
    expect(tester.widget<V3MasterpiecePage>(masterpieceFinder).active, isFalse);
    expect(find.text('创作空间'), findsOneWidget);
    await cancelledPageTouch.cancel();
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);
    expect(
      tester
          .widgetList<V3MasterpiecePage>(masterpieceFinder)
          .every((page) => !page.active),
      isTrue,
    );

    final trackpadToMasterpiece = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await trackpadToMasterpiece.panZoomStart(tester.getCenter(pageViewFinder));
    await trackpadToMasterpiece.panZoomUpdate(
      tester.getCenter(pageViewFinder),
      pan: Offset(-comfortableTravel, 0),
      timeStamp: const Duration(milliseconds: 600),
    );
    await trackpadToMasterpiece.panZoomEnd(
      timeStamp: const Duration(milliseconds: 700),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 2);

    final trackpadToWorkbench = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await trackpadToWorkbench.panZoomStart(tester.getCenter(pageViewFinder));
    await trackpadToWorkbench.panZoomUpdate(
      tester.getCenter(pageViewFinder),
      pan: Offset(comfortableTravel, 0),
      timeStamp: const Duration(milliseconds: 600),
    );
    await trackpadToWorkbench.panZoomEnd(
      timeStamp: const Duration(milliseconds: 700),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);

    final firstPageTouch = await tester.startGesture(
      tester.getCenter(pageViewFinder),
    );
    final secondPageTouch = await tester.startGesture(
      tester.getCenter(pageViewFinder) + const Offset(0, 32),
    );
    await secondPageTouch.moveBy(const Offset(-500, 0));
    await tester.pump();
    expect(pageView.controller?.page, greaterThan(1.9));
    await firstPageTouch.up();
    await secondPageTouch.up();
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);

    await tester.fling(pageViewFinder, const Offset(-23, 0), 8000);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(pageView.controller?.page, lessThan(1.5));
    }
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);

    await tester.timedDrag(
      pageViewFinder,
      const Offset(-28, 0),
      const Duration(milliseconds: 40),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 2);
    expect(find.text('代表作'), findsOneWidget);
    expect(tester.widget<V3MasterpiecePage>(masterpieceFinder).active, isTrue);

    await tester.timedDrag(
      pageViewFinder,
      Offset(-comfortableTravel, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 2);

    final adjacentGesture = await tester.startGesture(
      tester.getCenter(pageViewFinder),
    );
    for (var step = 0; step < 6; step++) {
      await adjacentGesture.moveBy(Offset(comfortableTravel / 6, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pageView.controller?.page, greaterThan(1.8));
    expect(pageView.controller?.page, lessThan(2));
    await adjacentGesture.up();
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);
    expect(find.text('创作空间'), findsOneWidget);

    var returnGesture = await tester.startGesture(
      tester.getCenter(pageViewFinder),
    );
    for (var step = 0; step < 6; step++) {
      await returnGesture.moveBy(Offset((comfortableTravel - 1) / 6, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pageView.controller?.page, greaterThan(.8));
    expect(pageView.controller?.page, lessThan(1));
    await returnGesture.up();
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 1);

    returnGesture = await tester.startGesture(tester.getCenter(pageViewFinder));
    for (var step = 0; step < 6; step++) {
      await returnGesture.moveBy(Offset(comfortableTravel / 6, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pageView.controller?.page, greaterThan(.8));
    expect(pageView.controller?.page, lessThan(1));
    await returnGesture.up();
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(pageView.controller?.page, 0);
    expect(find.byType(V3FeedPage), findsOneWidget);
    expect(tester.widget<V3FeedPage>(find.byType(V3FeedPage)).active, isTrue);
    expect(graphFinder, findsOneWidget);
    final returnedGraph = tester.widget<InteractiveViewer>(graphFinder);
    expect(
      returnedGraph.transformationController!.value.entry(0, 3),
      closeTo(departureTransform.entry(0, 3), .001),
    );
    expect(
      returnedGraph.transformationController!.value.entry(1, 3),
      closeTo(departureTransform.entry(1, 3), .001),
    );
    expect(find.byType(V3GraphSearchIcon), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home-workbench-surface')),
      findsNothing,
    );
    expect(pageView.controller?.position.isScrollingNotifier.value, isFalse);
    await tester.tap(
      find.descendant(of: dockGesture, matching: find.text('创作空间')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(pageView.controller?.page, 1);
  });

  testWidgets('1D accepts horizontal navigation from the full content area', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final library = KnowledgeLibraryController(
      initialNotes: buildGraphTestNotes(),
    );
    for (final note in library.notes.where((note) => !note.isHotspot)) {
      library.depositContent(note.id);
    }
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
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith(
            (ref) => FeedGraphController(library),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    final pageViewFinder = find.byKey(
      const ValueKey<String>('home-content-mode-pager'),
    );
    final pageView = tester.widget<PageView>(pageViewFinder);
    expect(find.byKey(const ValueKey('feed-notes-center')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('feed-bottom-workbench-gesture')),
      findsNothing,
    );
    final notesScrollable = find.descendant(
      of: find.byKey(const ValueKey('feed-notes-center')),
      matching: find.byType(Scrollable),
    );
    expect(notesScrollable, findsOneWidget);
    final notesPosition = tester
        .state<ScrollableState>(notesScrollable)
        .position;
    expect(notesPosition.pixels, 0);

    await tester.timedDragFrom(
      const Offset(195, 420),
      const Offset(70, -60),
      const Duration(milliseconds: 100),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller?.page, 0);
    expect(notesPosition.pixels, greaterThan(0));
    expect(
      find.byKey(const ValueKey<String>('v3-profile-side-panel')),
      findsNothing,
    );

    final beforeTrackpadScroll = notesPosition.pixels;
    final trackpad = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await trackpad.panZoomStart(const Offset(195, 420));
    await trackpad.panZoomUpdate(
      const Offset(195, 420),
      pan: const Offset(0, -120),
      timeStamp: const Duration(milliseconds: 100),
    );
    await trackpad.panZoomEnd(timeStamp: const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(notesPosition.pixels, greaterThan(beforeTrackpadScroll));
    expect(pageView.controller?.page, 0);

    await tester.timedDragFrom(
      const Offset(195, 420),
      const Offset(28, 0),
      const Duration(milliseconds: 40),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('v3-profile-side-panel')),
      findsOneWidget,
    );

    Navigator.of(
      tester.element(
        find.byKey(const ValueKey<String>('v3-profile-side-panel')),
      ),
    ).pop();
    await tester.pumpAndSettle();

    await tester.timedDragFrom(
      const Offset(195, 420),
      const Offset(-48, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pump(const Duration(milliseconds: 65));
    expect(pageView.controller?.page, greaterThan(0));
    expect(pageView.controller?.page, lessThan(.5));
    expect(find.text('思想图谱'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 220));
    expect(pageView.controller?.page, 1);
    expect(find.text('创作空间'), findsOneWidget);
  });
}
