import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/chat/chat_history_surfaces.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_material_import_surfaces.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_long_running_task_notice.dart';

void main() {
  testWidgets('notice pops exactly one route without task side effects', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('上一级')),
        ),
        GoRoute(
          path: '/task',
          builder: (_, _) => const Scaffold(body: V3LongRunningTaskNotice()),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    unawaited(router.push('/task'));
    await tester.pumpAndSettle();
    expect(find.textContaining('消息通知'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('long-running-task-return')));
    await tester.pumpAndSettle();
    expect(find.text('上一级'), findsOneWidget);
  });

  testWidgets('deep link without a previous route uses its fallback', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/task',
      routes: [
        GoRoute(
          path: '/task',
          builder: (_, _) => const Scaffold(
            body: V3LongRunningTaskNotice(fallbackRoute: '/home'),
          ),
        ),
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('首页')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const ValueKey('long-running-task-return')));
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('notice respects a pending leave guard', (tester) async {
    var blocked = 0;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('上一级')),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) blocked += 1;
            },
            child: const Scaffold(body: V3LongRunningTaskNotice()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('long-running-task-return')));
    await tester.pumpAndSettle();
    expect(blocked, 1);
    expect(find.byType(V3LongRunningTaskNotice), findsOneWidget);
  });

  testWidgets('async return is invoked once while persistence is pending', (
    tester,
  ) async {
    final completion = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3LongRunningTaskNotice(
            onReturn: () {
              calls += 1;
              return completion.future;
            },
          ),
        ),
      ),
    );
    final action = find.byKey(const ValueKey('long-running-task-return'));
    await tester.tap(action);
    await tester.pump();
    await tester.tap(action);
    expect(calls, 1);
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.text('先返回，稍后查看'), findsOneWidget);
  });

  testWidgets('compact progress surface stays scrollable with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.5),
          ),
          child: V3MaterialImportProgressSurface(
            sourceLabel: '长录音.m4a',
            sourceIcon: Icons.audio_file_outlined,
            title: '正在分析',
            message: '正在处理已受理的任务',
            canReturnViaNotifications: true,
            onBack: () => returned = true,
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('先返回，稍后查看'));
    await tester.tap(find.text('先返回，稍后查看'));
    await tester.pump();
    expect(returned, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unaccepted and completed progress hides notification promise', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: V3MaterialImportProgressSurface(
          sourceLabel: '文件',
          sourceIcon: Icons.description_outlined,
          title: '导入完成',
          message: '已生成笔记',
          onBack: () {},
        ),
      ),
    );
    expect(find.byType(V3LongRunningTaskNotice), findsNothing);
  });

  for (final isRouteEntry in [true, false]) {
    testWidgets('history system back respects route entry: $isRouteEntry', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      var backCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('账号与服务')),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => V3ChatHistorySurface(
              threads: const [],
              loading: false,
              isRouteEntry: isRouteEntry,
              onBack: () => backCalls += 1,
              onNewConversation: () {},
              onSelect: (_) {},
              onMore: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(backCalls, isRouteEntry ? 0 : 1);
      expect(find.text('账号与服务'), isRouteEntry ? findsOneWidget : findsNothing);
    });
  }
}
