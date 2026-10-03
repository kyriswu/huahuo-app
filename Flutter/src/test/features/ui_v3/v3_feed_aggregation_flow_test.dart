import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart'
    show notificationControllerProvider, resolvedDeviceIdProvider;
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/notifications/application/pending_message_projection.dart';
import 'package:huahuoai_app/features/notifications/application/notification_center_state_machine.dart';
import 'package:huahuoai_app/features/notifications/application/notification_controller.dart';
import 'package:huahuoai_app/features/notifications/data/notification_api.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_app_shell.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_aggregation_task_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_quick_dock.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_notifications_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_sphere_mesh_painter.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_node_painter.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_interactive_graph.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'graph_test_fixture.dart';

final _aggregationOwnerReplacementProvider = StateProvider<bool>(
  (ref) => false,
);

void main() {
  testWidgets('audit: system back cancels only the unsubmitted preparation', (
    tester,
  ) async {
    final sourceGate = Completer<void>();
    final fixture = _AggregationNavigationFixture(sourceGate: sourceGate);
    final router = GoRouter(
      initialLocation: '/origin',
      routes: [
        GoRoute(
          path: '/origin',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  context.push(V3FeedAggregationTaskPage.newTaskRoute),
              child: const Text('发起选材'),
            ),
          ),
        ),
        _aggregationNewRoute(),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixture.overrides,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('发起选材'));
    await _pumpGraphFrames(tester);
    expect(fixture.controller.productionPhase, FeedAggregationPhase.preparing);
    router.pop();
    await _pumpGraphFrames(tester);
    expect(fixture.controller.productionPhase, FeedAggregationPhase.idle);
    expect(fixture.controller.hasUnresolvedTask, isFalse);
    sourceGate.complete();
    await _pumpGraphFrames(tester);
    expect(find.text('发起选材'), findsOneWidget);
    expect(find.byKey(const ValueKey('aggregation-selection')), findsNothing);
    expect(fixture.remote.submissions, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('audit: covered invalid selection removes only its own route', (
    tester,
  ) async {
    final fixture = _AggregationNavigationFixture();
    fixture.controller.startSelection();
    final navigator = GlobalKey<NavigatorState>();
    bool? accepted;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          feedAggregationControllerProvider.overrideWith(
            (ref) => fixture.controller,
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  accepted = await showV3FeedAggregationSelection(
                    context,
                    fixture.controller,
                  );
                },
                child: const Text('打开选材'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开选材'));
    await _pumpGraphFrames(tester);
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (context) => const Scaffold(body: Text('覆盖页面')),
        ),
      ),
    );
    await _pumpGraphFrames(tester);
    fixture.library.deleteNote(fixture.controller.selectedNoteIds.first);
    await _pumpGraphFrames(tester);
    expect(find.text('覆盖页面'), findsOneWidget);
    expect(accepted, isFalse);
    navigator.currentState!.pop();
    await _pumpGraphFrames(tester);
    expect(find.byKey(const ValueKey('aggregation-selection')), findsNothing);
    expect(fixture.remote.submissions, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('completed aggregation returns to the actual message sheet', (
    tester,
  ) async {
    final fixture = _AggregationNavigationFixture();
    const message = PendingMessage(
      id: 'aggregation-complete-link',
      source: PendingMessageSource.aggregation,
      scene: 'feed_ai',
      title: '聚合完成',
      body: '查看原结果笔记',
      state: PendingMessageState.succeeded,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      taskId: 'completed-run',
      targetType: 'asset',
      targetId: 'result-local',
      route: '/v3/feed/items/result-local?stage=raw',
      isTask: true,
    );
    final router = GoRouter(
      initialLocation: '/origin',
      routes: [
        GoRoute(
          path: '/origin',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (context) =>
                    const V3NotificationsPage(dismissBeforeNavigation: true),
              ),
              child: const Text('打开消息'),
            ),
          ),
        ),
        GoRoute(
          path: '/v3/feed/items/:noteId',
          builder: (context, state) => Scaffold(
            appBar: AppBar(title: const Text('结果正文')),
            body: Text(
              '${state.pathParameters['noteId']}:${state.uri.queryParameters['stage']}',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fixture.overrides,
          notificationControllerProvider.overrideWith(
            (ref) =>
                NotificationController(api: const UnavailableNotificationApi()),
          ),
          notificationCenterControllerProvider.overrideWith(
            (ref) => NotificationCenterController.withActions(
              actions: const _AggregationMessageActions(),
            ),
          ),
          pendingMessageProjectionProvider.overrideWith(
            (ref) => const PendingMessageProjection(
              items: [message],
              isLoading: false,
              resolutionIsDemo: false,
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('打开消息'));
    await _pumpGraphFrames(tester);
    await tester.tap(
      find.byKey(
        const ValueKey('notification-message-aggregation-complete-link'),
      ),
    );
    await _pumpGraphFrames(tester);
    expect(find.text('result-local:raw'), findsOneWidget);
    router.pop();
    await _pumpGraphFrames(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(V3NotificationsPage), findsOneWidget);
    expect(
      find
          .byKey(
            const ValueKey('notification-message-aggregation-complete-link'),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(fixture.remote.submissions, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'invalidated selection returns to failure instead of leaving task',
    (tester) async {
      final fixture = _AggregationNavigationFixture();
      fixture.remote.submissionResponse = Future.value(
        fixture.remote.response('dead_letter'),
      );
      fixture.controller.startSelection();
      await fixture.controller.confirm();
      final router = GoRouter(
        initialLocation: V3FeedAggregationTaskPage.routeFor(
          fixture.controller.taskId!,
        ),
        routes: [
          GoRoute(
            path: '/v3/feed',
            builder: (context, state) => const Scaffold(body: Text('首页')),
          ),
          _aggregationNewRoute(),
          GoRoute(
            path: '/v3/feed/aggregation',
            builder: (context, state) => V3FeedAggregationTaskPage(
              taskId: state.uri.queryParameters['taskId'] ?? '',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: fixture.overrides,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('aggregation-processing-retry')),
      );
      await _pumpGraphFrames(tester);
      expect(
        find.byKey(const ValueKey('aggregation-selection')),
        findsOneWidget,
      );
      fixture.library.deleteNote(fixture.controller.selectedNoteIds.first);
      await _pumpGraphFrames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('aggregation-selection')), findsNothing);
      expect(find.byType(V3FeedAggregationTaskPage), findsOneWidget);
      expect(find.textContaining('尚未提交'), findsOneWidget);
      expect(fixture.controller.errorCode, 'AGGREGATION_SELECTION_CHANGED');
      expect(fixture.remote.submissions, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'aggregation notification preserves intent identity and message return stack',
    (tester) async {
      final fixture = _AggregationNavigationFixture();
      fixture.controller.startSelection();
      final submission = fixture.controller.confirm();
      final intentId = fixture.controller.taskId!;
      await submission;
      fixture.attach();
      final message = PendingMessage(
        id: 'aggregation-link',
        source: PendingMessageSource.aggregation,
        scene: 'feed_ai',
        title: '查看本次聚合',
        body: '查看原任务进度',
        state: PendingMessageState.processing,
        isUnread: false,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        taskId: intentId,
        targetType: 'topic_collision',
        route: V3FeedAggregationTaskPage.routeFor(intentId),
        isTask: true,
      );
      final router = GoRouter(
        initialLocation: '/messages',
        routes: [
          GoRoute(
            path: '/messages',
            builder: (context, state) => const Scaffold(
              body: V3NotificationsPage(dismissBeforeNavigation: true),
            ),
          ),
          _aggregationNewRoute(),
          GoRoute(
            path: '/v3/feed/aggregation',
            builder: (context, state) => V3FeedAggregationTaskPage(
              key: ValueKey(state.uri.toString()),
              taskId: state.uri.queryParameters['taskId'] ?? '',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...fixture.overrides,
            notificationControllerProvider.overrideWith(
              (ref) => NotificationController(
                api: const UnavailableNotificationApi(),
              ),
            ),
            notificationCenterControllerProvider.overrideWith(
              (ref) => NotificationCenterController.withActions(
                actions: const _AggregationMessageActions(),
              ),
            ),
            pendingMessageProjectionProvider.overrideWith(
              (ref) => PendingMessageProjection(
                items: [message],
                isLoading: false,
                resolutionIsDemo: false,
              ),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await _pumpGraphFrames(tester);
      await tester.tap(
        find.byKey(const ValueKey('notification-message-aggregation-link')),
      );
      await _pumpGraphFrames(tester);
      expect(find.byType(V3FeedAggregationTaskPage), findsOneWidget);
      expect(find.text('聚合任务已排队'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('aggregation-processing-leave')),
      );
      await _pumpGraphFrames(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(V3NotificationsPage), findsOneWidget);
      expect(fixture.controller.hasUnresolvedTask, isTrue);
      expect(fixture.controller.noticeForReference(intentId), isNotNull);
      expect(fixture.remote.submissions, 1);
      await tester.tap(
        find.byKey(const ValueKey('notification-message-aggregation-link')),
      );
      await _pumpGraphFrames(tester);
      expect(find.text('聚合任务已排队'), findsOneWidget);
      fixture.remote.completeFailure();
      await _pumpGraphFrames(tester);
      expect(find.text('观点聚合未完成'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await _pumpGraphFrames(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(V3NotificationsPage), findsOneWidget);
      expect(find.byType(V3FeedAggregationTaskPage), findsNothing);
      expect(fixture.remote.submissions, 1);
      await tester.tap(
        find.byKey(const ValueKey('notification-message-aggregation-link')),
      );
      await _pumpGraphFrames(tester);
      await tester.tap(
        find.byKey(const ValueKey('aggregation-processing-retry')),
      );
      await _pumpGraphFrames(tester);
      expect(
        find.byKey(const ValueKey('aggregation-selection')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('关闭'));
      await _pumpGraphFrames(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(V3FeedAggregationTaskPage), findsOneWidget);
      expect(find.text('观点聚合未完成'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await _pumpGraphFrames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(V3NotificationsPage), findsOneWidget);
      expect(fixture.controller.noticeForReference(intentId), isNotNull);
      expect(fixture.remote.submissions, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'aggregation result note returns to task then to its originating page',
    (tester) async {
      final fixture = _AggregationNavigationFixture();
      fixture.sources.add(
        V3FeedItem(
          id: 'result-local',
          remoteNoteId: 'result-remote',
          remoteSourceKind: 'topic_collision',
          rawPartRevisionId: 'result-raw',
          title: '可读取的聚合结果',
          source: V3MaterialSource.note,
          rawBody: '# 聚合正文',
          createdAt: DateTime.utc(2026, 9, 6),
        ),
      );
      fixture.remote.submissionResponse = Future.value(
        fixture.remote.response('succeeded'),
      );
      fixture.controller.startSelection();
      await fixture.controller.confirm();
      final router = GoRouter(
        initialLocation: '/origin',
        routes: [
          GoRoute(
            path: '/origin',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: () => context.push(
                  V3FeedAggregationTaskPage.routeFor(
                    fixture.controller.taskId!,
                  ),
                ),
                child: const Text('打开聚合详情'),
              ),
            ),
          ),
          _aggregationNewRoute(),
          GoRoute(
            path: '/v3/feed/aggregation',
            builder: (context, state) => V3FeedAggregationTaskPage(
              taskId: state.uri.queryParameters['taskId'] ?? '',
            ),
          ),
          GoRoute(
            path: '/v3/feed/items/:noteId',
            builder: (context, state) => Scaffold(
              appBar: AppBar(title: const Text('结果正文')),
              body: Text(
                '${state.pathParameters['noteId']}:${state.uri.queryParameters['stage']}',
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: fixture.overrides,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.tap(find.text('打开聚合详情'));
      await _pumpGraphFrames(tester);
      await tester.tap(find.byKey(const ValueKey('aggregation-result-save')));
      await _pumpGraphFrames(tester);
      expect(find.text('result-local:raw'), findsOneWidget);
      router.pop();
      await _pumpGraphFrames(tester);
      expect(
        find.byKey(const ValueKey('aggregation-v5-result')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('aggregation-result-back')));
      await _pumpGraphFrames(tester);
      expect(find.text('打开聚合详情'), findsOneWidget);
      expect(fixture.remote.submissions, 1);
      fixture.controller.dismissCompletion();
      fixture.library.deleteNote('result-local');
      router.push(
        V3FeedAggregationTaskPage.routeFor(fixture.controller.taskId!),
      );
      await _pumpGraphFrames(tester);
      expect(find.text('聚合结果暂不可用'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'explicit selection cancellation and submitted system back preserve origin',
    (tester) async {
      final fixture = _AggregationNavigationFixture();
      final gate = Completer<ApiResult<TopicCollisionRun>>();
      fixture.remote.submissionResponse = gate.future;
      final router = _aggregationJourneyRouter();
      await tester.pumpWidget(
        ProviderScope(
          overrides: fixture.overrides,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await _pumpGraphFrames(tester);
      await _tapGraphAggregationAction(tester);
      await _pumpGraphFrames(tester);
      expect(
        find.byKey(const ValueKey('aggregation-selection')),
        findsOneWidget,
      );
      expect(fixture.controller.taskNotices, isEmpty);
      await tester.tap(find.byTooltip('关闭'));
      await _pumpGraphFrames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(V3FeedAggregationTaskPage), findsNothing);
      expect(fixture.remote.submissions, 0);
      await _tapGraphAggregationAction(tester);
      await _pumpGraphFrames(tester);
      await tester.tap(find.byKey(const ValueKey('aggregation-sheet-start')));
      await _pumpGraphFrames(tester);
      expect(find.text('正在提交聚合'), findsOneWidget);
      expect(fixture.remote.submissions, 1);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _pumpGraphFrames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(V3FeedAggregationTaskPage), findsNothing);
      expect(
        tester.widget<V3FeedQuickDock>(find.byType(V3FeedQuickDock)).enabled,
        isTrue,
      );
      gate.complete(fixture.remote.response('queued'));
      await _pumpGraphFrames(tester);
      expect(find.byKey(const ValueKey('aggregation-running')), findsNothing);
      expect(fixture.remote.submissions, 1);
      expect(
        fixture.controller.taskNotices.single.phase,
        FeedAggregationPhase.queued,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'aggregation submission does not block note view dock or other home modes',
    (tester) async {
      final fixture = _AggregationNavigationFixture();
      final gate = Completer<ApiResult<TopicCollisionRun>>();
      fixture.remote.submissionResponse = gate.future;
      fixture.controller.startSelection();
      final submitting = fixture.controller.confirm();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [...fixture.overrides],
          child: const MaterialApp(home: V3AppShell(initialFeedNotes: true)),
        ),
      );
      await _pumpGraphFrames(tester);
      expect(
        fixture.controller.productionPhase,
        FeedAggregationPhase.submitting,
      );
      await _pumpGraphFrames(tester);
      expect(
        find.byKey(const ValueKey('feed-notes-random-aggregation')),
        findsOneWidget,
      );
      expect(
        tester.widget<V3FeedQuickDock>(find.byType(V3FeedQuickDock)).enabled,
        isTrue,
      );
      final pager = tester.widget<PageView>(
        find.byKey(const ValueKey('home-content-mode-pager')),
      );
      pager.controller!.jumpToPage(1);
      await _pumpGraphFrames(tester);
      expect(pager.controller!.page, 1);
      expect(
        tester
            .widget<V3FeedPage>(find.byType(V3FeedPage, skipOffstage: false))
            .active,
        isFalse,
      );
      gate.complete(fixture.remote.response('queued'));
      await submitting;
      await _pumpGraphFrames(tester);
      expect(pager.controller!.page, 1);
      expect(fixture.remote.submissions, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('aggregation selection cannot confirm a replacement controller', (
    tester,
  ) async {
    final original = _AggregationNavigationFixture();
    final replacement = _AggregationNavigationFixture();
    original.controller.startSelection();
    bool? accepted;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          feedAggregationControllerProvider.overrideWith(
            (ref) => ref.watch(_aggregationOwnerReplacementProvider)
                ? replacement.controller
                : original.controller,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  accepted = await showV3FeedAggregationSelection(
                    context,
                    original.controller,
                  );
                },
                child: const Text('选择来源'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择来源'));
    await _pumpGraphFrames(tester);
    expect(find.byKey(const ValueKey('aggregation-selection')), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.text('选择来源')),
    );
    original.controller.toggleNormalNote(
      original.controller.selectedNoteIds.first,
    );
    await tester.pump();
    container.read(_aggregationOwnerReplacementProvider.notifier).state = true;
    await _pumpGraphFrames(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('aggregation-selection')), findsNothing);
    expect(accepted, isFalse);
    expect(original.remote.submissions, 0);
    expect(replacement.remote.submissions, 0);
    await tester.pumpWidget(const SizedBox());
  });

  test('graph fit matrix keeps finite node bounds inside its target', () {
    const sceneOrigin = Offset(240, 240);
    const target = Rect.fromLTWH(18, 24, 308, 350);
    final matrix = v3GraphFitTransformation(
      viewportSize: const Size(390, 520),
      positions: const <Offset>[Offset.zero, Offset(200, 300)],
      sceneOrigin: sceneOrigin,
      targetRect: target,
      nodePadding: 20,
    );
    final scale = v3GraphViewportScale(matrix);
    Offset transform(Offset position) => Offset(
      (position.dx + sceneOrigin.dx) * scale + matrix.entry(0, 3),
      (position.dy + sceneOrigin.dy) * scale + matrix.entry(1, 3),
    );

    expect(scale, 1);
    expect(target.inflate(1).contains(transform(Offset.zero)), isTrue);
    expect(
      target.inflate(1).contains(transform(const Offset(200, 300))),
      isTrue,
    );
    final fallback = v3GraphFitTransformation(
      viewportSize: const Size(390, 520),
      positions: const <Offset>[Offset(double.nan, 0)],
      sceneOrigin: sceneOrigin,
      targetRect: target,
    );
    expect(fallback.entry(0, 3), -240);
    expect(fallback.entry(1, 3), -240);

    final compactMatrix = v3GraphFitTransformation(
      viewportSize: const Size(390, 520),
      positions: const <Offset>[Offset.zero, Offset(340, 380)],
      sceneOrigin: sceneOrigin,
      targetRect: target,
      nodePadding: 18,
    );
    expect(v3GraphViewportScale(compactMatrix), closeTo(.82, .001));
  });

  test('center membership edges use stable softly curved geometry', () {
    const edge = V3GraphEdge(
      id: 'membership-center-note-a',
      sourceId: 'center',
      targetId: 'note-a',
      kind: V3GraphRelationKind.membership,
      label: '属于',
      weight: .62,
    );
    const from = Offset(195, 242);
    const to = Offset(340, 118);
    final midpoint = (from + to) / 2;
    final control = v3GraphEdgeControlPoint(from: from, to: to, edge: edge);

    expect(control, v3GraphEdgeControlPoint(from: from, to: to, edge: edge));
    expect((control - midpoint).distance, inInclusiveRange(4, 16));
  });

  test('selection weakens unrelated relation opacity', () {
    const edge = V3GraphEdge(
      id: 'shared-topic-note-a-note-b',
      sourceId: 'note-a',
      targetId: 'note-b',
      kind: V3GraphRelationKind.sharedTopic,
      label: '共同主题',
      weight: .7,
    );
    final idle = v3GraphEdgeOpacity(edge: edge, selectedNodeId: null);

    expect(
      v3GraphEdgeOpacity(edge: edge, selectedNodeId: 'unrelated-note'),
      lessThan(idle),
    );
    expect(
      v3GraphEdgeOpacity(edge: edge, selectedNodeId: 'note-a'),
      greaterThan(idle),
    );
  });

  test('entity colors are stable across sources and stay in the palette', () {
    final palette = HuahuoV3Theme.graphPaletteFor(HuahuoV3Theme.sakuraTokens);
    final first = v3GraphEntityColorFor('人物', palette);
    final second = v3GraphEntityColorFor('人物', palette);
    expect(first, second);
    expect(palette, contains(first));
    expect(v3GraphEntityColorFor('方法', palette), palette[2]);
    expect(
      v3GraphEntityColorFor('Person', palette),
      v3GraphEntityColorFor('person', palette),
    );
    expect(
      v3GraphEntityColorFor('PERSON', palette),
      v3GraphEntityColorFor('人物', palette),
    );
    expect(
      v3GraphEntityColorFor('未知类型', palette),
      v3GraphEntityColorFor('未知类型', palette),
    );
    expect(
      canonicalGraphEntityType('未知类型'),
      isNot(canonicalGraphEntityType('另一个未知类型')),
    );
  });

  testWidgets('graph never opens a selection from shared controller state', (
    tester,
  ) async {
    final fixture = _AggregationNavigationFixture();
    fixture.controller.startSelection();
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixture.overrides,
        child: const MaterialApp(home: V3AppShell(initialFeedNotes: false)),
      ),
    );
    await _pumpGraphFrames(tester);
    expect(find.byKey(const ValueKey('aggregation-selection')), findsNothing);
    expect(find.byType(V3FeedAggregationTaskPage), findsNothing);
    expect(
      find.byKey(const ValueKey('home-feed-notifications')),
      findsOneWidget,
    );
    expect(find.byType(V3FeedQuickDock), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('successful aggregation opens the Mobile V5 result surface', (
    tester,
  ) async {
    final notes = <V3FeedItem>[
      for (var i = 0; i < 5; i++)
        V3FeedItem(
          id: 'route-note-$i',
          title: '路线笔记 $i',
          source: V3MaterialSource.note,
          createdAt: DateTime(2026, 7, 20 + i),
          rawBody: '正文 $i',
        ),
      V3FeedItem(
        id: 'route-hotspot',
        title: '路线热点',
        source: V3MaterialSource.hotspot,
        ownership: V3NoteOwnership.hotspot,
        createdAt: DateTime(2026, 7, 28),
        rawBody: '',
      ),
    ];
    final library = _depositedLibrary(initialNotes: notes);
    final aggregation = FeedAggregationController(
      library: library,
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 7, 28)),
      repository: const FeedAggregationMockRepository(delay: Duration.zero),
    );
    Uri? openedResult;
    final router = GoRouter(
      routes: [
        _aggregationNewRoute(),
        _aggregationExistingRoute(),
        GoRoute(path: '/', builder: (context, state) => const V3AppShell()),
        GoRoute(
          path: '/v3/feed/items/:noteId',
          builder: (context, state) {
            openedResult = state.uri;
            return const Scaffold(body: Text('聚合结果正文'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pendingMessageBadgeCountProvider.overrideWithValue(0),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedAggregationControllerProvider.overrideWith((ref) => aggregation),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    await _tapGraphAggregationAction(tester);
    await _pumpGraphFrames(tester);
    expect(find.byKey(const ValueKey('aggregation-selection')), findsOneWidget);
    expect(find.text('已随机选中 4 篇笔记'), findsOneWidget);
    await tester.tap(find.text('开始聚合'));
    await _pumpGraphFrames(tester);

    expect(aggregation.status, FeedAggregationStatus.succeeded);
    expect(find.byKey(const ValueKey('aggregation-v5-result')), findsOneWidget);
    expect(find.text(aggregation.generatedNote!.title), findsNWidgets(2));
    expect(find.text('查看聚合笔记'), findsOneWidget);
    expect(find.text('换一组'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('aggregation-result-save')));
    await _pumpGraphFrames(tester);
    expect(find.text('聚合结果正文'), findsOneWidget);
    expect(
      openedResult?.path,
      '/v3/feed/items/${aggregation.generatedNote!.id}',
    );
    expect(openedResult?.queryParameters['stage'], 'raw');
  });

  testWidgets(
    'production aggregation has only a task route and no graph reminder',
    (tester) async {
      final fixture = _AggregationNavigationFixture();
      fixture.controller.startSelection();
      await fixture.controller.confirm();
      final router = _aggregationJourneyRouter();
      await tester.pumpWidget(
        ProviderScope(
          overrides: fixture.overrides,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await _pumpGraphFrames(tester);
      expect(find.byKey(const ValueKey('aggregation-running')), findsNothing);
      expect(find.byKey(const ValueKey('aggregation-failed')), findsNothing);
      expect(
        find.byKey(const ValueKey('aggregation-completion')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('aggregation-open-task')), findsNothing);
      final titles = fixture.controller.selectedNotes
          .map((note) => note.title)
          .toList();
      expect(
        fixture.controller.taskNotices.single.sources.map((note) => note.title),
        titles,
      );
      await _tapGraphAggregationAction(tester);
      await _pumpGraphFrames(tester);
      expect(find.text('已有聚合任务，请从消息中查看进度'), findsOneWidget);
      expect(find.byType(V3FeedAggregationTaskPage), findsNothing);
      router.push(
        V3FeedAggregationTaskPage.routeFor(fixture.controller.taskId!),
      );
      await _pumpGraphFrames(tester);
      expect(find.text('聚合任务已排队'), findsOneWidget);
      expect(fixture.remote.submissions, 1);
      await tester.tap(find.byTooltip('返回'));
      await _pumpGraphFrames(tester);
      expect(find.byType(V3AppShell), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('background completion never interrupts another route', (
    tester,
  ) async {
    final fixture = _AggregationNavigationFixture();
    fixture.controller.startSelection();
    await fixture.controller.confirm();
    fixture.sources.add(
      V3FeedItem(
        id: 'result-local',
        remoteNoteId: 'result-remote',
        remoteSourceKind: 'topic_collision',
        rawPartRevisionId: 'result-raw',
        title: '后台聚合结果',
        source: V3MaterialSource.note,
        rawBody: '# 正文',
        createdAt: DateTime.utc(2026, 9, 7),
      ),
    );
    final router = _aggregationJourneyRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: fixture.overrides,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    router.push('/v3/feed/items/other-note');
    await _pumpGraphFrames(tester);
    fixture.attach();
    fixture.remote.query.complete(fixture.remote.response('succeeded'));
    await _pumpGraphFrames(tester);
    expect(fixture.controller.status, FeedAggregationStatus.succeeded);
    expect(find.text('other-note:raw'), findsOneWidget);
    expect(find.byKey(const ValueKey('aggregation-v5-result')), findsNothing);
    router.pop();
    await _pumpGraphFrames(tester);
    expect(find.byKey(const ValueKey('aggregation-completion')), findsNothing);
    expect(find.byKey(const ValueKey('aggregation-v5-result')), findsNothing);
    expect(fixture.controller.taskNotices.single.note?.id, 'result-local');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'ordinary graph node actions remain available while aggregation runs',
    (tester) async {
      final fixture = _AggregationNavigationFixture();
      fixture.controller.startSelection();
      await fixture.controller.confirm();
      final graph = FeedGraphController(fixture.library);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...fixture.overrides,
            feedGraphControllerProvider.overrideWith((ref) => graph),
          ],
          child: const MaterialApp(home: V3AppShell(initialFeedNotes: false)),
        ),
      );
      await _pumpGraphFrames(tester);
      graph.selectNode(fixture.library.notes.first.id);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(ValueKey('node-card-${fixture.library.notes.first.id}')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('aggregation-running')), findsNothing);
      expect(
        tester.widget<V3FeedQuickDock>(find.byType(V3FeedQuickDock)).enabled,
        isTrue,
      );
      expect(fixture.remote.submissions, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'compact feed keeps aggregation confirmation on-screen and tappable',
    (tester) async {
      tester.view
        ..physicalSize = const Size(375, 667)
        ..devicePixelRatio = 1
        ..padding = const FakeViewPadding(top: 20, bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      final notes = _bottomOverlayNotes();
      final library = _depositedLibrary(initialNotes: notes);
      final aggregation = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(referenceDay: DateTime(2026, 7, 17)),
        repository: const FeedAggregationMockRepository(delay: Duration.zero),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pendingMessageBadgeCountProvider.overrideWithValue(0),
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            feedAggregationControllerProvider.overrideWith(
              (ref) => aggregation,
            ),
          ],
          child: MaterialApp.router(routerConfig: _aggregationJourneyRouter()),
        ),
      );
      await tester.pump();
      await _tapGraphAggregationAction(tester);
      await _pumpGraphFrames(tester);

      final confirmation = find.byKey(const ValueKey('aggregation-selection'));
      final confirmationRect = tester.getRect(confirmation);
      expect(confirmationRect.left, greaterThanOrEqualTo(0));
      expect(confirmationRect.right, lessThanOrEqualTo(375));
      expect(confirmationRect.top, greaterThanOrEqualTo(20));
      expect(confirmationRect.bottom, lessThanOrEqualTo(667));
      expect(find.text('换一批').hitTestable(), findsOneWidget);
      expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
      expect(find.text('开始聚合').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('graph search expands remotely and closes after selection', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(home: V3AppShell()),
      ),
    );
    await tester.pump();

    final searchField = find.byKey(const ValueKey('feed-graph-search-input'));
    expect(searchField, findsNothing);
    expect(find.text('思想图谱'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.byKey(const ValueKey('feed-graph-aggregate')), findsOneWidget);

    graph.toggleSearch();
    await tester.pump();

    expect(searchField, findsOneWidget);
    expect(find.text('思想图谱'), findsNothing);

    await tester.enterText(searchField, 'AI');
    await tester.pump();

    expect(
      find.byKey(const ValueKey('feed-graph-search-close')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('feed-graph-aggregate')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('feed-graph-search-close')));
    await tester.pump();

    expect(searchField, findsNothing);
    expect(graph.searchQuery, isEmpty);
    expect(find.text('思想图谱'), findsOneWidget);

    final expected = library.mineNotes.first;
    graph.toggleSearch();
    await tester.pump();
    await tester.enterText(searchField, expected.title);
    await tester.pump();
    final resultPanel = find.byKey(const ValueKey('feed-graph-search-results'));
    await tester.tap(
      find.descendant(of: resultPanel, matching: find.text(expected.title)),
    );
    await tester.pump();

    expect(searchField, findsNothing);
    expect(find.text('思想图谱'), findsOneWidget);
    expect(graph.searchQuery, isEmpty);
    expect(graph.selectedNodeId, expected.id);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('local graph search resolves the current scoped controller', (
    tester,
  ) async {
    final firstLibrary = _depositedLibrary();
    final secondLibrary = _depositedLibrary();
    final scopedLibrary = StateProvider<KnowledgeLibraryController>(
      (ref) => firstLibrary,
    );
    final container = ProviderContainer(
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith(
          (ref) => ref.watch(scopedLibrary),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: V3AppShell()),
      ),
    );
    await tester.pump();
    final firstGraph = container.read(feedGraphControllerProvider);

    container.read(scopedLibrary.notifier).state = secondLibrary;
    await tester.pump();
    await tester.pump();
    final secondGraph = container.read(feedGraphControllerProvider);
    expect(secondGraph, isNot(same(firstGraph)));

    secondGraph.toggleSearch();
    await tester.pump();

    expect(firstGraph.searchOpen, isFalse);
    expect(secondGraph.searchOpen, isTrue);
  });

  testWidgets(
    'interactive graph rotates its sphere and resets the home camera',
    (tester) async {
      final library = _depositedLibrary();
      final graph = FeedGraphController(library);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            feedGraphControllerProvider.overrideWith((ref) => graph),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 390,
                  height: 520,
                  child: V3InteractiveGraph(aggregated: false),
                ),
              ),
            ),
          ),
        ),
      );
      await _pumpGraphFrames(tester);

      final viewerFinder = find.byKey(
        const ValueKey('feed-graph-interactive-viewer'),
      );
      final sceneFinder = find.byKey(const ValueKey('feed-graph-scene'));
      final viewer = tester.widget<InteractiveViewer>(viewerFinder);
      final scene = tester.widget<SizedBox>(sceneFinder);

      expect(viewer.constrained, isFalse);
      expect(scene.width, 870);
      expect(scene.height, 1000);
      final homeMatrix = viewer.transformationController!.value.clone();
      expect(v3GraphViewportScale(homeMatrix), inInclusiveRange(.9, 1.0));
      expect(homeMatrix.entry(0, 3).isFinite, isTrue);
      expect(homeMatrix.entry(1, 3).isFinite, isTrue);
      expect(find.byKey(ValueKey(library.mineNotes.first.id)), findsOneWidget);
      final sampledNode = find.byKey(const ValueKey(graphTestPrimaryNoteId));
      final homeNodeCenter = tester.getCenter(sampledNode);
      final viewerRect = tester.getRect(viewerFinder).inflate(1);
      for (final note in library.allDepositedNotes) {
        expect(
          viewerRect.contains(tester.getCenter(find.byKey(ValueKey(note.id)))),
          isTrue,
          reason: '${note.id} should be visible in the home viewport',
        );
      }

      final dragOrigin =
          tester.getTopLeft(viewerFinder) + const Offset(195, 24);
      await tester.dragFrom(dragOrigin, const Offset(60, 50));
      await tester.pump();
      final afterRotationX =
          viewer.transformationController?.value.entry(0, 3) ?? -240;
      final afterRotationY =
          viewer.transformationController?.value.entry(1, 3) ?? -240;
      final firstRotatedCenter = tester.getCenter(sampledNode);
      expect(afterRotationX, closeTo(homeMatrix.entry(0, 3), .001));
      expect(afterRotationY, closeTo(homeMatrix.entry(1, 3), .001));
      expect((firstRotatedCenter - homeNodeCenter).distance, greaterThan(2));

      await tester.dragFrom(dragOrigin, const Offset(-120, -100));
      await tester.pump();
      expect(
        viewer.transformationController?.value.entry(0, 3),
        closeTo(afterRotationX, .001),
      );
      expect(
        viewer.transformationController?.value.entry(1, 3),
        closeTo(afterRotationY, .001),
      );
      expect(
        (tester.getCenter(sampledNode) - firstRotatedCenter).distance,
        greaterThan(2),
      );

      viewer.transformationController?.value = Matrix4.translationValues(
        -120,
        -80,
        0,
      );
      await tester.pump();
      final nodeCenters = [
        for (final note in library.mineNotes)
          tester.getCenter(find.byKey(ValueKey(note.id))),
      ];
      final viewportTopLeft = tester.getTopLeft(viewerFinder);
      final resetOrigin =
          <Offset>[
                const Offset(14, 14),
                const Offset(376, 14),
                const Offset(14, 506),
                const Offset(376, 506),
                const Offset(195, 260),
              ]
              .map((offset) => viewportTopLeft + offset)
              .firstWhere(
                (candidate) => nodeCenters.every(
                  (center) => (center - candidate).distance > 55,
                ),
              );
      graph
        ..selectNode(graphTestPrimaryNoteId)
        ..setFilter(V3GraphFilter.audio)
        ..setSearchQuery('睡眠')
        ..toggleEntityTypeFilter('观点');
      await tester.pump();
      await tester.tapAt(resetOrigin);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(resetOrigin);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      final resetMatrix = viewer.transformationController!.value;
      for (var index = 0; index < 16; index++) {
        expect(
          resetMatrix.storage[index],
          closeTo(homeMatrix.storage[index], .01),
        );
      }
      expect(graph.selectedNodeId, isNull);
      expect(graph.selectedEdgeId, isNull);
      expect(graph.activeFilter, V3GraphFilter.all);
      expect(graph.searchQuery, isEmpty);
      expect(graph.selectedEntityTypes, isEmpty);
      expect(
        (tester.getCenter(sampledNode) - homeNodeCenter).distance,
        lessThan(.5),
      );
      expect(
        tester
            .widget<Opacity>(
              find.byKey(
                const ValueKey(
                  'feed-graph-node-zoom-effect-$graphTestPrimaryNoteId',
                ),
              ),
            )
            .opacity,
        1,
      );
    },
  );

  testWidgets('ordinary drag beginning on a node rotates without selecting', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 390,
                height: 520,
                child: V3InteractiveGraph(aggregated: false),
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);

    const nodeId = graphTestPrimaryNoteId;
    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
    );
    final zoomEffect = find.byKey(
      const ValueKey('feed-graph-node-zoom-effect-$graphTestPrimaryNoteId'),
    );
    expect(tester.widget<Opacity>(zoomEffect).opacity, 1);
    final beforeMatrix = viewer.transformationController!.value.clone();
    final beforeNode = tester.getCenter(find.byKey(const ValueKey(nodeId)));
    final gesture = await tester.startGesture(beforeNode);
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(const Offset(8.5, 4.5));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.widget<Opacity>(zoomEffect).opacity, 1);
    await gesture.up();
    await _pumpGraphFrames(tester);

    final afterMatrix = viewer.transformationController!.value;
    expect(graph.hasManualPosition(nodeId), isFalse);
    expect(graph.selectedNodeId, isNull);
    expect(afterMatrix.entry(0, 3), closeTo(beforeMatrix.entry(0, 3), .001));
    expect(afterMatrix.entry(1, 3), closeTo(beforeMatrix.entry(1, 3), .001));
    expect(
      (tester.getCenter(find.byKey(const ValueKey(nodeId))) - beforeNode)
          .distance,
      greaterThan(2),
    );
  });

  testWidgets('zoom changes scale without replaying node pulse', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 520,
              child: V3InteractiveGraph(aggregated: false),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);

    const nodeId = graphTestPrimaryNoteId;
    final nodeCenter = tester.getCenter(find.byKey(const ValueKey(nodeId)));
    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
    );
    final beforeScale = v3GraphViewportScale(
      viewer.transformationController!.value,
    );
    final zoomEffect = find.byKey(
      const ValueKey('feed-graph-node-zoom-effect-$graphTestPrimaryNoteId'),
    );
    final pulseOffset = find.byKey(
      const ValueKey('feed-graph-node-pulse-offset-$graphTestPrimaryNoteId'),
    );
    final pulseScale = find.byKey(
      const ValueKey('feed-graph-node-pulse-scale-$graphTestPrimaryNoteId'),
    );
    double pulseOpacity() => tester.widget<Opacity>(zoomEffect).opacity;
    double pulseOffsetDistance() {
      final matrix = tester.widget<Transform>(pulseOffset).transform;
      return Offset(matrix.entry(0, 3), matrix.entry(1, 3)).distance;
    }

    double pulseVisualScale() =>
        tester.widget<Transform>(pulseScale).transform.entry(0, 0);
    expect(pulseOpacity(), 1);
    expect(pulseOffsetDistance(), 0);
    expect(pulseVisualScale(), 1);
    final first = await tester.startGesture(
      nodeCenter - const Offset(20, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      nodeCenter + const Offset(20, 0),
      pointer: 2,
    );
    await first.moveBy(const Offset(-22, 0));
    await second.moveBy(const Offset(22, 0));
    await tester.pump();
    expect(pulseOpacity(), 1);
    expect(pulseOffsetDistance(), 0);
    expect(pulseVisualScale(), 1);

    await tester.pump(const Duration(milliseconds: 120));
    final beforeContinuedUpdate = pulseOpacity();
    await first.moveBy(const Offset(-2, 0));
    await second.moveBy(const Offset(2, 0));
    await tester.pump(const Duration(milliseconds: 20));
    expect(pulseOpacity(), greaterThanOrEqualTo(beforeContinuedUpdate));

    await first.up();
    await second.up();
    await _pumpGraphFrames(tester);

    final zoomedInScale = v3GraphViewportScale(
      viewer.transformationController!.value,
    );
    expect(zoomedInScale, greaterThan(beforeScale));
    expect(pulseOpacity(), 1);

    final zoomedNodeCenter = tester.getCenter(
      find.byKey(const ValueKey(nodeId)),
    );
    final third = await tester.startGesture(
      zoomedNodeCenter - const Offset(30, 0),
      pointer: 3,
    );
    final fourth = await tester.startGesture(
      zoomedNodeCenter + const Offset(30, 0),
      pointer: 4,
    );
    await third.moveBy(const Offset(20, 0));
    await fourth.moveBy(const Offset(-20, 0));
    await tester.pump();
    expect(pulseOpacity(), 1);
    await third.up();
    await fourth.up();
    await _pumpGraphFrames(tester);

    expect(
      v3GraphViewportScale(viewer.transformationController!.value),
      lessThan(zoomedInScale),
    );
    expect(pulseOpacity(), 1);

    final viewportCenter = tester.getCenter(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.trackpad,
        position: viewportCenter,
        scrollDelta: const Offset(20, 20),
      ),
    );
    await tester.pump();
    expect(pulseOpacity(), 1);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: viewportCenter,
        scrollDelta: const Offset(0, -1),
      ),
    );
    await tester.pump();
    expect(pulseOpacity(), 1);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: viewportCenter,
        scrollDelta: const Offset(0, -1),
      ),
    );
    await tester.pump();
    expect(pulseOpacity(), 1);
    await tester.pump(const Duration(milliseconds: 120));
    final beforeContinuedSignal = pulseOpacity();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: viewportCenter,
        scrollDelta: const Offset(0, -1),
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(pulseOpacity(), greaterThanOrEqualTo(beforeContinuedSignal));

    await tester.pump(const Duration(milliseconds: 160));
    expect(pulseOpacity(), 1);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(pulseOpacity(), 1);
    await _pumpGraphFrames(tester);
    expect(pulseOpacity(), 1);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: viewportCenter,
        scrollDelta: const Offset(0, 40),
      ),
    );
    await tester.pump();
    expect(pulseOpacity(), 1);
    await _pumpGraphFrames(tester);

    expect(graph.hasManualPosition(nodeId), isFalse);
  });

  testWidgets('phone viewport renders an irregular sphere with depth cues', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 390,
                height: 520,
                child: V3InteractiveGraph(aggregated: false),
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);

    final noteRects = [
      for (final note in library.allDepositedNotes)
        _markerRect(tester, note.id),
    ];
    final graphPalette = HuahuoV3Theme.graphPaletteFor(
      HuahuoV3Theme.lightTokens,
    );
    final approvedColors = graphPalette.toSet();
    expect(find.byKey(const ValueKey('feed-graph-center-dot')), findsNothing);
    expect(
      find.byKey(const ValueKey('feed-graph-center-anchor')),
      findsNothing,
    );
    final diameters = <double>[];
    final opacities = <double>[];
    final graphRect = tester.getRect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
    );
    for (var left = 0; left < noteRects.length; left++) {
      final nodeCenter = noteRects[left].center;
      final nodeId = library.allDepositedNotes[left].id;
      final marker = _markerFinder(nodeId);
      final diameter = tester.getSize(marker).shortestSide;
      diameters.add(diameter);
      expect(diameter, inInclusiveRange(7.0, 17.0), reason: nodeId);
      final opacity = tester
          .widget<Opacity>(
            find.byKey(ValueKey('feed-graph-node-opacity-$nodeId')),
          )
          .opacity;
      opacities.add(opacity);
      expect(opacity, inInclusiveRange(.05, 1.0), reason: nodeId);
      expect(
        approvedColors,
        contains(v3GraphEntityColorFor(nodeId, graphPalette)),
      );
      expect(graphRect.inflate(1).contains(nodeCenter), isTrue, reason: nodeId);
    }
    expect(diameters.reduce((a, b) => a < b ? a : b), lessThan(11));
    expect(diameters.reduce((a, b) => a > b ? a : b), greaterThan(14));
    expect(opacities.reduce((a, b) => a < b ? a : b), lessThan(.4));
    expect(opacities.reduce((a, b) => a > b ? a : b), greaterThan(.8));

    final idleCenters = <String, Offset>{
      for (final note in library.allDepositedNotes)
        note.id: tester.getCenter(find.byKey(ValueKey(note.id))),
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 390,
                height: 520,
                child: V3InteractiveGraph(aggregated: true),
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);
    expect(find.byKey(const ValueKey('feed-graph-center-dot')), findsNothing);
    for (final entry in idleCenters.entries) {
      expect(
        (tester.getCenter(find.byKey(ValueKey(entry.key))) - entry.value)
            .distance,
        lessThan(.5),
        reason: '${entry.key} moved after aggregation completed',
      );
    }
  });

  testWidgets('stationary node long press selects and opens the note', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);
    String? longPressedNodeId;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 520,
              child: V3InteractiveGraph(
                aggregated: false,
                onNodeLongPress: (node) => longPressedNodeId = node.id,
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);

    final nodeId = _frontmostHitNodeId(
      tester,
      library.mineNotes.map((note) => note.id),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey(nodeId))),
    );
    await tester.pump(const Duration(milliseconds: 240));
    await gesture.up();
    await tester.pump();

    expect(longPressedNodeId, nodeId);
    expect(graph.selectedNodeId, nodeId);
  });

  testWidgets('long press then drag moves one node and commits once', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);
    var graphNotifications = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 520,
              child: V3InteractiveGraph(aggregated: false),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);
    graph.addListener(() => graphNotifications++);

    final nodeId = _frontmostHitNodeId(
      tester,
      library.allDepositedNotes.map((note) => note.id),
    );
    final node = find.byKey(ValueKey(nodeId));
    final before = tester.getCenter(node);
    final gesture = await tester.startGesture(before);
    await tester.pump(const Duration(milliseconds: 240));
    for (var frame = 0; frame < 12; frame++) {
      await gesture.moveBy(const Offset(52 / 12, 28 / 12));
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(graph.hasManualPosition(nodeId), isFalse);
    expect(graphNotifications, 0);
    expect((tester.getCenter(node) - before).distance, greaterThan(5));

    await gesture.up();
    await _pumpGraphFrames(tester);

    expect(graph.hasManualPosition(nodeId), isTrue);
    expect((tester.getCenter(node) - before).distance, greaterThan(10));
    expect(graphNotifications, 1);
  });

  testWidgets('50-node sphere uses front-aware three-level title LOD', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 520,
              child: V3InteractiveGraph(aggregated: false),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);

    expect(library.allDepositedNotes, isNotEmpty);
    for (final note in library.allDepositedNotes) {
      expect(find.byKey(ValueKey(note.id)), findsOneWidget, reason: note.id);
    }
    final meshPainter =
        tester
                .widget<CustomPaint>(
                  find.byKey(const ValueKey('feed-graph-sphere-mesh')),
                )
                .painter!
            as V3GraphSphereMeshPainter;
    expect(meshPainter.projection.topology.nodeCount, 72);
    expect(meshPainter.projection.topology.syntheticFlags, contains(1));
    expect(
      meshPainter.projection.topology.realNodeCount,
      graph.nodes.where((node) => !node.center).length,
    );
    expect(meshPainter.projection.topology.nodeIds, isNot(contains('center')));
    expect(
      find.byKey(const ValueKey('feed-graph-center-anchor')),
      findsNothing,
    );
    expect(_valueKeysStartingWith('feed-graph-cluster-label-'), findsNothing);
    final farLabelIds = _graphNodeLabelIds();
    expect(farLabelIds, isNotEmpty);
    expect(farLabelIds.length, lessThanOrEqualTo(4));
    _expectFrontFacingLabels(tester, farLabelIds);
    expect(
      graph.overviewEdges.where(
        (edge) => edge.kind == V3GraphRelationKind.membership,
      ),
      hasLength(library.allDepositedNotes.length),
    );
    expect(graph.overviewEdges.length, greaterThan(graph.layoutEdges.length));
    expect(graph.layoutEdges.length, lessThanOrEqualTo(250));

    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
    );
    viewer.transformationController?.value = Matrix4.identity()
      ..setEntry(0, 0, 1.4)
      ..setEntry(1, 1, 1.4)
      ..setEntry(0, 3, -240)
      ..setEntry(1, 3, -240);
    await _pumpGraphFrames(tester);

    expect(_valueKeysStartingWith('feed-graph-cluster-label-'), findsNothing);
    final middleLabelIds = _graphNodeLabelIds();
    expect(middleLabelIds, isNotEmpty);
    expect(
      middleLabelIds.length,
      lessThanOrEqualTo(V3GraphCluster.values.length),
    );
    for (final cluster in V3GraphCluster.values) {
      expect(
        graph.nodes
            .where((node) => middleLabelIds.contains(node.id))
            .where((node) => node.cluster == cluster),
        hasLength(lessThanOrEqualTo(1)),
        reason: cluster.label,
      );
    }
    _expectFrontFacingLabels(tester, middleLabelIds);
    expect(
      tester
          .widget<Text>(
            find.byKey(
              ValueKey('feed-graph-node-label-${middleLabelIds.first}'),
            ),
          )
          .maxLines,
      3,
    );
    expect(
      tester.getSize(
        find.byKey(ValueKey('feed-graph-label-bounds-${middleLabelIds.first}')),
      ),
      const Size(144, 34),
    );

    final selectedExtra = graph.nodes.firstWhere(
      (node) => !node.center && !middleLabelIds.contains(node.id),
    );
    graph.selectNode(selectedExtra.id);
    await tester.pump();
    expect(_graphNodeLabelIds(), containsAll(middleLabelIds));
    expect(_graphNodeLabelIds(), contains(selectedExtra.id));

    graph.selectNode(null);
    graph.setSearchQuery(selectedExtra.label);
    await tester.pump();
    expect(_graphNodeLabelIds(), containsAll(middleLabelIds));
    expect(_graphNodeLabelIds(), contains(selectedExtra.id));
    graph.setSearchQuery('');
    await tester.pump();

    viewer.transformationController?.value = Matrix4.identity()
      ..setEntry(0, 0, 2)
      ..setEntry(1, 1, 2)
      ..setEntry(0, 3, -240)
      ..setEntry(1, 3, -240);
    await _pumpGraphFrames(tester);
    final nearLabelIds = _graphNodeLabelIds();
    expect(nearLabelIds.length, greaterThan(12));
    expect(nearLabelIds.length, lessThan(library.allDepositedNotes.length));
    _expectFrontFacingLabels(tester, nearLabelIds);
    final stableLabelId = nearLabelIds.first;
    final stableLabelFinder = find.byKey(
      ValueKey('feed-graph-node-label-$stableLabelId'),
    );
    expect(tester.widget<Text>(stableLabelFinder).maxLines, 4);
    expect(
      tester.getSize(
        find.byKey(ValueKey('feed-graph-label-bounds-$stableLabelId')),
      ),
      const Size(180, 44),
    );
    expect(
      tester
          .widget<Transform>(
            find.byKey(ValueKey('feed-graph-node-label-scale-$stableLabelId')),
          )
          .transform
          .entry(0, 0),
      closeTo(.5, .001),
    );
    final labelRectAt2x = tester.getRect(stableLabelFinder);

    viewer.transformationController?.value = Matrix4.identity()
      ..setEntry(0, 0, 3)
      ..setEntry(1, 1, 3)
      ..setEntry(0, 3, -240)
      ..setEntry(1, 3, -240);
    await tester.pump();

    expect(_graphNodeLabelIds(), nearLabelIds);
    expect(
      tester
          .widget<Transform>(
            find.byKey(ValueKey('feed-graph-node-label-scale-$stableLabelId')),
          )
          .transform
          .entry(0, 0),
      closeTo(1 / 3, .001),
    );
    final labelRectAt3x = tester.getRect(stableLabelFinder);
    expect(labelRectAt3x.width, closeTo(labelRectAt2x.width, .01));
    expect(labelRectAt3x.height, closeTo(labelRectAt2x.height, .01));
  });

  testWidgets('dense Canvas node promotes and commits one drag', (
    tester,
  ) async {
    final notes = List<V3FeedItem>.generate(
      130,
      (index) => V3FeedItem(
        id: 'dense-note-$index',
        title: '密集节点 $index',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 1).add(Duration(minutes: index)),
        rawBody: '密集图谱正文 $index',
        summaryBody: '密集图谱摘要 $index',
      ),
    );
    final library = _depositedLibrary(initialNotes: notes);
    final graph = FeedGraphController(library);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 520,
              child: V3InteractiveGraph(aggregated: false),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);

    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('feed-graph-dense-node-canvas')),
    );
    final painter = paint.painter! as V3GraphNodePainter;
    expect(painter.labelNodeIds, isNotEmpty);
    expect(
      painter.labelNodeIds.length,
      lessThanOrEqualTo(painter.nodes.where((node) => !node.center).length),
    );
    expect(painter.nodes, hasLength(120));
    final sceneBox = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('feed-graph-scene')),
    );
    V3GraphNode? target;
    Offset? targetGlobal;
    for (final node in graph.nodes.where((node) => !node.center)) {
      if (find.byKey(ValueKey(node.id)).evaluate().isNotEmpty) continue;
      final position = painter.resolvePositions()[node.id];
      if (position == null) continue;
      final global = sceneBox.localToGlobal(position + painter.sceneOrigin);
      if (global.dx > 36 &&
          global.dx < 340 &&
          global.dy > 125 &&
          global.dy < 430) {
        target = node;
        targetGlobal = global;
        break;
      }
    }
    expect(target, isNotNull);
    expect(targetGlobal, isNotNull);
    expect(find.byKey(ValueKey(target!.id)), findsNothing);
    Set<String> widgetNodeIds() => <String>{
      for (final node in graph.nodes)
        if (find.byKey(ValueKey(node.id)).evaluate().isNotEmpty) node.id,
    };
    final overlaysBeforeDrag = widgetNodeIds();
    var graphNotifications = 0;
    graph.addListener(() => graphNotifications++);

    final gesture = await tester.startGesture(targetGlobal!);
    await tester.pump(const Duration(milliseconds: 240));
    final promotedIds = widgetNodeIds().difference(overlaysBeforeDrag);
    expect(promotedIds, hasLength(1));
    final promotedId = promotedIds.single;
    expect(find.byKey(ValueKey(promotedId)), findsOneWidget);
    final promotedOriginalPosition = sceneBox.localToGlobal(
      painter.resolvePositions()[promotedId]! + painter.sceneOrigin,
    );
    expect(
      (tester.getCenter(find.byKey(ValueKey(promotedId))) -
              promotedOriginalPosition)
          .distance,
      lessThan(1.5),
    );
    await gesture.moveBy(const Offset(32, 18));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await _pumpGraphFrames(tester);

    expect(graph.hasManualPosition(promotedId), isTrue);
    expect(graphNotifications, 1);
  });

  testWidgets('selection enhances a note and weakens unrelated context', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 520,
              child: V3InteractiveGraph(aggregated: false),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);

    final selectedId = _frontmostHitNodeId(
      tester,
      library.allDepositedNotes.map((note) => note.id),
    );
    final selectedFinder = find.byKey(ValueKey(selectedId));
    final selectedCenterBefore = tester.getCenter(selectedFinder);
    expect(find.byKey(const ValueKey('feed-graph-center-dot')), findsNothing);
    await tester.tap(selectedFinder);
    await _pumpGraphFrames(tester);

    expect(graph.selectedNodeId, selectedId);
    expect(graph.firstDegreeNodeIds, contains('center'));
    expect(
      find.byKey(ValueKey('feed-graph-node-label-$selectedId')),
      findsOneWidget,
    );
    expect(_graphNodeLabelIds(), hasLength(lessThanOrEqualTo(14)));
    final selectedCenterAfter = tester.getCenter(selectedFinder);
    expect((selectedCenterAfter - selectedCenterBefore).distance, lessThan(.5));
    final unrelatedId = graph.nodes
        .where((node) => !node.center)
        .map((node) => node.id)
        .firstWhere((id) => !graph.focusedNodeIds.contains(id));
    final unrelatedOpacity = tester.widget<Opacity>(
      find.byKey(ValueKey('feed-graph-node-opacity-$unrelatedId')),
    );
    expect(unrelatedOpacity.opacity, lessThanOrEqualTo(.18));
    for (final note in library.allDepositedNotes) {
      expect(find.byKey(ValueKey(note.id)), findsOneWidget, reason: note.id);
    }
  });

  testWidgets('viewport exposes one labelled 44dp aggregation action', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);
    var aggregationCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 520),
              textScaler: TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: SizedBox(
                width: 390,
                height: 520,
                child: V3InteractiveGraph(
                  aggregated: false,
                  showAggregationAction: true,
                  onStartAggregation: () => aggregationCalls++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpGraphFrames(tester);

    final aggregate = find.byKey(const ValueKey('feed-graph-aggregate'));
    expect(aggregate, findsOneWidget);
    expect(tester.getSize(aggregate), const Size(44, 44));
    expect(
      find.descendant(of: aggregate, matching: find.byType(Text)),
      findsNothing,
    );
    expect(find.bySemanticsLabel('开始聚合'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('feed-graph-aggregation-glyph')),
      findsOneWidget,
    );
    expect(find.byIcon(LucideIcons.blend), findsOneWidget);
    expect(
      find.descendant(
        of: aggregate,
        matching: find.byIcon(LucideIcons.network),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(aggregate);
    await tester.pump();
    expect(aggregationCalls, 1);
    for (final key in const <String>[
      'feed-graph-edge-labels',
      'feed-graph-legend-toggle',
      'feed-graph-refresh',
      'feed-graph-fullscreen',
      'feed-graph-filter',
      'feed-graph-reset',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
  });

  testWidgets('only successful aggregation shows completed feedback', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);
    var aggregated = false;
    var aggregating = true;
    var progress = .5;
    late StateSetter update;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return SizedBox(
                  width: 390,
                  height: 520,
                  child: V3InteractiveGraph(
                    aggregated: aggregated,
                    aggregating: aggregating,
                    aggregationProgress: progress,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('feed-graph-status-building')),
      findsOneWidget,
    );

    update(() {
      aggregating = false;
      progress = 0;
    });
    await tester.pump(const Duration(milliseconds: 240));
    expect(
      find.byKey(const ValueKey('feed-graph-status-completed')),
      findsNothing,
    );

    update(() {
      aggregating = true;
      progress = .7;
    });
    await tester.pump();
    update(() {
      aggregated = true;
      aggregating = false;
      progress = 1;
    });
    await tester.pump(const Duration(milliseconds: 240));
    expect(
      find.byKey(const ValueKey('feed-graph-status-completed')),
      findsOneWidget,
    );
  });

  testWidgets('local graph search preserves deposited nodes without filters', (
    tester,
  ) async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: const MaterialApp(home: V3AppShell()),
      ),
    );
    await _pumpGraphFrames(tester);

    final zoomEffect = find.byKey(
      const ValueKey('feed-graph-node-zoom-effect-$graphTestPrimaryNoteId'),
    );
    double pulseOpacity() => tester.widget<Opacity>(zoomEffect).opacity;
    expect(pulseOpacity(), 1);
    expect(find.byKey(const ValueKey('feed-graph-aggregate')), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-graph-filter')), findsNothing);
    expect(find.byKey(const ValueKey('feed-graph-reset')), findsNothing);

    graph.toggleSearch();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('feed-graph-search-input')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('feed-graph-filter-open')), findsNothing);
    expect(find.text('筛选图谱'), findsNothing);
    expect(graph.activeFilter, V3GraphFilter.all);

    graph.setSearchQuery('睡眠');
    await _pumpGraphFrames(tester);
    expect(graph.searchResults, isNotEmpty);
    for (final note in library.allDepositedNotes) {
      expect(find.byKey(ValueKey(note.id)), findsOneWidget, reason: note.id);
    }

    expect(find.byKey(const ValueKey('feed-graph-reset')), findsNothing);
  });
}

final class _AggregationSourcePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  const _AggregationSourcePort(this.sources, {this.loadGate});
  final List<V3FeedItem> sources;
  final Completer<void>? loadGate;

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async {
    await loadGate?.future;
    return KnowledgeNoteRemoteLoadResult.success(sources);
  }

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

GoRoute _aggregationNewRoute() => GoRoute(
  path: V3FeedAggregationTaskPage.newTaskRoute,
  builder: (context, state) =>
      V3FeedAggregationTaskPage(key: state.pageKey, taskId: '', startNew: true),
);
GoRoute _aggregationExistingRoute() => GoRoute(
  path: '/v3/feed/aggregation',
  builder: (context, state) => V3FeedAggregationTaskPage(
    key: state.pageKey,
    taskId: state.uri.queryParameters['taskId'] ?? '',
  ),
);
GoRouter _aggregationJourneyRouter() {
  final router = GoRouter(
    initialLocation: '/v3/feed',
    routes: [
      GoRoute(
        path: '/v3/feed',
        builder: (context, state) => const V3AppShell(initialFeedNotes: false),
      ),
      _aggregationNewRoute(),
      _aggregationExistingRoute(),
      GoRoute(
        path: '/v3/feed/items/:noteId',
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('笔记正文')),
          body: Text(
            '${state.pathParameters['noteId']}:${state.uri.queryParameters['stage'] ?? 'raw'}',
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  return router;
}

final class _AggregationNavigationFixture {
  _AggregationNavigationFixture({Completer<void>? sourceGate}) {
    library = KnowledgeLibraryController(
      initialNotes: sources,
      includeDemoFixtures: false,
      notePort: _AggregationSourcePort(sources, loadGate: sourceGate),
    );
    profile = ProfileHubController(referenceDay: DateTime.utc(2026, 9, 6));
    controller = FeedAggregationController(
      library: library,
      profileHub: profile,
      repository: const UnavailableFeedAggregationRepository(),
      topicCollisionRuns: remote,
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'aggregation-navigation',
      workspaceId: () => 'workspace-production',
      workspaceReady: () => true,
    );
    addTearDown(controller.dispose);
    addTearDown(() {
      if (!_libraryProvided) library.dispose();
    });
    addTearDown(profile.dispose);
  }
  final sources = List.generate(
    4,
    (index) => V3FeedItem(
      id: 'navigation-source-$index',
      remoteNoteId: 'remote-navigation-$index',
      remoteSourceKind: 'manual',
      rawPartRevisionId: 'raw-navigation-$index',
      title: '导航来源 $index',
      rawBody: '有效正文 $index',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 6),
    ),
  );
  final remote = _RecoveringTopicCollisionRunPort();
  late final KnowledgeLibraryController library;
  late final ProfileHubController profile;
  late final FeedAggregationController controller;
  bool _libraryProvided = false;
  List<Override> get overrides => [
    resolvedDeviceIdProvider.overrideWithValue('aggregation-test-device'),
    pendingMessageBadgeCountProvider.overrideWithValue(0),
    knowledgeLibraryControllerProvider.overrideWith((ref) {
      _libraryProvided = true;
      return library;
    }),
    feedAggregationControllerProvider.overrideWith((ref) => controller),
  ];
  void attach() {
    final orchestrator = TaskOrchestrator();
    final metrics = RuntimeActivityMetrics();
    addTearDown(orchestrator.dispose);
    addTearDown(metrics.dispose);
    controller.attachPollingRuntime(
      orchestrator: orchestrator,
      activityMetrics: metrics,
    );
  }
}

final class _AggregationMessageActions implements NotificationCenterActionPort {
  const _AggregationMessageActions();
  @override
  Future<bool> markRead(PendingMessage item) async => true;
  @override
  Future<bool> markOpened(PendingMessage item) async => true;
  @override
  Future<bool> markHandled(PendingMessage item) async => true;
  @override
  Future<PendingMessageMarkAllReadResult> markAllRead() async =>
      const PendingMessageMarkAllReadResult(total: 0, succeeded: 0);
}

final class _RecoveringTopicCollisionRunPort implements TopicCollisionRunPort {
  Future<ApiResult<TopicCollisionRun>>? submissionResponse;
  final query = Completer<ApiResult<TopicCollisionRun>>();
  final List<String> readRunIds = [];
  final List<String> readWorkspaces = [];
  var submissions = 0;

  ApiResult<TopicCollisionRun> response(String status) => ApiResult.success(
    data: TopicCollisionRun(
      topicCollisionRunId: 'topic-collision-restored',
      workspaceId: 'workspace-production',
      status: status,
      stage: status == 'queued' ? 'source_frozen' : 'output_validation',
      selectedNoteCount: 4,
      outputNoteId: status == 'succeeded' ? 'result-remote' : null,
      attempt: status == 'dead_letter' ? 3 : 0,
      retryable: status == 'dead_letter',
      failureStage: status == 'dead_letter' ? 'output_validation' : null,
      failureCode: status == 'dead_letter'
          ? 'NOTE_TOPIC_COLLISION_OUTPUT_INVALID'
          : null,
    ),
    status: status == 'queued' ? 202 : 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  void completeFailure() => query.complete(response('dead_letter'));

  @override
  Future<ApiResult<TopicCollisionRun>> get(String workspaceId, String runId) {
    readRunIds.add(runId);
    readWorkspaces.add(workspaceId);
    return query.future;
  }

  @override
  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  }) async {
    submissions++;
    return submissionResponse ?? response('queued');
  }
}

KnowledgeLibraryController _depositedLibrary({
  Iterable<V3FeedItem>? initialNotes,
}) {
  final library = KnowledgeLibraryController(
    initialNotes: initialNotes ?? buildGraphTestNotes(),
  );
  for (final note in library.notes.where((note) => !note.isHotspot)) {
    library.depositContent(note.id);
  }
  return library;
}

Future<void> _pumpGraphFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 24; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _tapGraphAggregationAction(WidgetTester tester) async {
  final action = find.descendant(
    of: find.byKey(const ValueKey('feed-graph-aggregate')),
    matching: find.byType(IconButton),
  );
  expect(action, findsOneWidget);
  await tester.tap(action);
}

Finder _valueKeysStartingWith(String prefix) =>
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith(prefix);
    });

Set<String> _graphNodeLabelIds() => find
    .byWidgetPredicate((widget) {
      final key = widget.key;
      return widget is Text &&
          key is ValueKey<String> &&
          key.value.startsWith('feed-graph-node-label-');
    })
    .evaluate()
    .map((element) {
      final key = element.widget.key! as ValueKey<String>;
      return key.value.substring('feed-graph-node-label-'.length);
    })
    .toSet();

String _frontmostHitNodeId(WidgetTester tester, Iterable<String> nodeIds) {
  for (final id in nodeIds) {
    if (find.byKey(ValueKey(id)).hitTestable().evaluate().isNotEmpty) return id;
  }
  throw TestFailure('Expected at least one frontmost hit-testable graph node.');
}

List<V3FeedItem> _bottomOverlayNotes() => <V3FeedItem>[
  for (var index = 0; index < 5; index++)
    V3FeedItem(
      id: 'overlay-note-$index',
      title: '浮层笔记 $index',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 10 + index),
      rawBody: '浮层正文 $index',
      summaryBody: '浮层纲要 $index',
    ),
  V3FeedItem(
    id: 'overlay-hotspot',
    title: '浮层热点',
    source: V3MaterialSource.hotspot,
    ownership: V3NoteOwnership.hotspot,
    createdAt: DateTime(2026, 7, 17),
    rawBody: '',
    summaryBody: '热点纲要',
  ),
];

void _expectFrontFacingLabels(WidgetTester tester, Iterable<String> nodeIds) {
  for (final id in nodeIds) {
    final opacity = tester
        .widget<Opacity>(find.byKey(ValueKey('feed-graph-node-opacity-$id')))
        .opacity;
    expect(opacity, greaterThanOrEqualTo(.38), reason: id);
  }
}

Finder _markerFinder(String id) =>
    find.byKey(ValueKey('feed-graph-node-marker-$id'));

Rect _markerRect(WidgetTester tester, String id) =>
    tester.getRect(_markerFinder(id));
