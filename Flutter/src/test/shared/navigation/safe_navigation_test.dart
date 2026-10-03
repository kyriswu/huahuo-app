import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/shared/navigation/foreground_ingress_coordinator.dart';
import 'package:huahuoai_app/shared/navigation/safe_navigation.dart';

void main() {
  for (final replacePageKey in [false, true]) {
    testWidgets('child visits follow replacement pageKey=$replacePageKey', (
      tester,
    ) async {
      bool? returnedToOrigin;
      var completions = 0;
      final router = GoRouter(
        initialLocation: '/origin',
        routes: [
          GoRoute(
            path: '/origin',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  returnedToOrigin = await visitChildRoute(
                    GoRouter.of(context),
                    '/child',
                  );
                  completions += 1;
                },
                child: const Text('打开子页面'),
              ),
            ),
          ),
          for (final path in ['/child', '/grandchild', '/replacement'])
            GoRoute(
              path: path,
              builder: (context, state) => Scaffold(body: Text(path)),
            ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.tap(find.text('打开子页面'));
      await tester.pumpAndSettle();
      unawaited(router.push<void>('/grandchild'));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('/child'), findsOneWidget);
      expect(completions, 0);

      if (replacePageKey) {
        unawaited(router.pushReplacement<void>('/replacement'));
      } else {
        unawaited(router.replace<void>('/replacement'));
      }
      await tester.pumpAndSettle();
      expect(returnedToOrigin, isNull);
      expect(completions, 0);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('打开子页面'), findsOneWidget);
      expect(returnedToOrigin, isTrue);
      expect(completions, 1);

      await tester.tap(find.text('打开子页面'));
      await tester.pumpAndSettle();
      router.go('/origin');
      await tester.pumpAndSettle();
      expect(returnedToOrigin, isFalse);
      expect(completions, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a superseded child admission does not remain pending', (
    tester,
  ) async {
    final admission = Completer<String?>();
    final router = GoRouter(
      initialLocation: '/origin',
      routes: [
        GoRoute(
          path: '/child',
          redirect: (context, state) => admission.future,
          builder: (context, state) => const Scaffold(body: Text('child')),
        ),
        for (final path in ['/origin', '/other'])
          GoRoute(
            path: path,
            builder: (context, state) => Scaffold(body: Text(path)),
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    final visit = visitChildRoute(router, '/child');
    await tester.pump();
    router.go('/other');
    await tester.pumpAndSettle();
    expect(await visit, isFalse);
    admission.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('/other'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('Back pops native routes and preserves their typed result', (
    tester,
  ) async {
    String? returnedResult;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                returnedResult = await Navigator.of(context).push<String>(
                  MaterialPageRoute<String>(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () => returnToPreviousRoute<String>(
                          context,
                          result: 'saved',
                        ),
                        child: const Text('返回并保存'),
                      ),
                    ),
                  ),
                );
              },
              child: const Text('打开原生页面'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开原生页面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回并保存'));
    await tester.pumpAndSettle();

    expect(returnedResult, 'saved');
    expect(find.text('打开原生页面'), findsOneWidget);
  });

  for (final blockNestedRoot in [false, true]) {
    testWidgets('Back respects nested stacks and root veto=$blockNestedRoot', (
      tester,
    ) async {
      final nestedKey = GlobalKey<NavigatorState>();
      var vetoCalls = 0;
      final router = GoRouter(
        initialLocation: '/source',
        routes: [
          GoRoute(
            path: '/source',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: () => context.push<void>('/nested'),
                child: const Text('来源页面'),
              ),
            ),
          ),
          GoRoute(
            path: '/nested',
            builder: (context, state) => Navigator(
              key: nestedKey,
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                builder: (context) => PopScope<void>(
                  canPop: !blockNestedRoot,
                  onPopInvokedWithResult: (didPop, result) {
                    if (!didPop) vetoCalls += 1;
                  },
                  child: Scaffold(
                    body: TextButton(
                      onPressed: () => returnToPreviousRoute<void>(
                        context,
                        fallbackRoute: '/fallback',
                      ),
                      child: const Text('嵌套根页返回'),
                    ),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/fallback',
            builder: (context, state) => const Scaffold(body: Text('无上一层的回落页')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.tap(find.text('来源页面'));
      await tester.pumpAndSettle();
      unawaited(
        nestedKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => returnToPreviousRoute<void>(
                  context,
                  fallbackRoute: '/fallback',
                ),
                child: const Text('嵌套详情返回'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('嵌套详情返回'));
      await tester.pumpAndSettle();

      expect(find.text('嵌套根页返回'), findsOneWidget);
      expect(router.canPop(), isTrue);
      expect(vetoCalls, 0);

      await tester.tap(find.text('嵌套根页返回'));
      await tester.pumpAndSettle();
      expect(find.text('无上一层的回落页'), findsNothing);
      expect(vetoCalls, blockNestedRoot ? 1 : 0);
      expect(
        find.text('来源页面'),
        blockNestedRoot ? findsNothing : findsOneWidget,
      );
      expect(
        find.text('嵌套根页返回'),
        blockNestedRoot ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('cold ingress replaces while foreground ingress pushes', () {
    expect(
      ingressNavigationAction(coldStart: true),
      IngressNavigationAction.replace,
    );
    expect(
      ingressNavigationAction(coldStart: false),
      IngressNavigationAction.push,
    );
  });

  test(
    'foreground ingress asks its coordinator while cold start bypasses it',
    () async {
      final coordinator = ForegroundIngressCoordinator();
      var requests = 0;
      coordinator.register(
        onRequest: () {
          requests += 1;
          return ForegroundIngressDecision.cancel;
        },
      );

      expect(
        await requestIngressNavigation(
          action: IngressNavigationAction.push,
          foregroundIngressCoordinator: coordinator,
        ),
        isFalse,
      );
      expect(requests, 1);
      expect(
        await requestIngressNavigation(
          action: IngressNavigationAction.replace,
          foregroundIngressCoordinator: coordinator,
        ),
        isTrue,
      );
      expect(requests, 1);
    },
  );

  test(
    'foreground ingress exposes busy to callers that need rescheduling',
    () async {
      final coordinator = ForegroundIngressCoordinator();
      final response = Completer<ForegroundIngressDecision>();
      coordinator.register(onRequest: () => response.future);

      final active = requestIngressNavigationResult(
        action: IngressNavigationAction.push,
        foregroundIngressCoordinator: coordinator,
      );
      expect(
        await requestIngressNavigationResult(
          action: IngressNavigationAction.push,
          foregroundIngressCoordinator: coordinator,
        ),
        ForegroundIngressRequestResult.busy,
      );
      response.complete(ForegroundIngressDecision.allow);
      expect(await active, ForegroundIngressRequestResult.allow);
    },
  );
}
