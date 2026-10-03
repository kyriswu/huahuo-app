import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/navigation/foreground_ingress_coordinator.dart';

void main() {
  test('the newest current registration decides the request', () async {
    final coordinator = ForegroundIngressCoordinator();
    var olderCalls = 0;
    var newerCalls = 0;
    var newerCurrent = true;
    coordinator.register(
      onRequest: () {
        olderCalls += 1;
        return ForegroundIngressDecision.allow;
      },
    );
    coordinator.register(
      isCurrent: () => newerCurrent,
      onRequest: () {
        newerCalls += 1;
        return ForegroundIngressDecision.cancel;
      },
    );

    expect(await coordinator.requestNavigation(), isFalse);
    expect(olderCalls, 0);
    expect(newerCalls, 1);

    newerCurrent = false;
    expect(await coordinator.requestNavigation(), isTrue);
    expect(olderCalls, 1);
    expect(newerCalls, 1);
  });

  test('disposed and failing registrations do not approve ingress', () async {
    final coordinator = ForegroundIngressCoordinator();
    final unregister = coordinator.register(
      onRequest: () => ForegroundIngressDecision.cancel,
    );
    unregister();
    expect(await coordinator.requestNavigation(), isTrue);

    coordinator.register(onRequest: () => throw StateError('route closing'));
    expect(await coordinator.requestNavigation(), isFalse);
  });

  test(
    'a concurrent request is denied while the current route decides',
    () async {
      final coordinator = ForegroundIngressCoordinator();
      final response = Completer<ForegroundIngressDecision>();
      coordinator.register(onRequest: () => response.future);

      final first = coordinator.requestNavigation();
      expect(await coordinator.requestNavigation(), isFalse);
      response.complete(ForegroundIngressDecision.allow);
      expect(await first, isTrue);
    },
  );

  test(
    'busy is distinct from cancel and exposes the active request settlement',
    () async {
      final coordinator = ForegroundIngressCoordinator();
      final response = Completer<ForegroundIngressDecision>();
      var calls = 0;
      coordinator.register(
        onRequest: () {
          calls += 1;
          return calls == 1 ? response.future : ForegroundIngressDecision.allow;
        },
      );

      final first = coordinator.requestNavigationResult();
      expect(
        await coordinator.requestNavigationResult(),
        ForegroundIngressRequestResult.busy,
      );
      var settled = false;
      final idle = coordinator.waitUntilIdle().then((_) => settled = true);
      response.complete(ForegroundIngressDecision.cancel);

      expect(await first, ForegroundIngressRequestResult.cancel);
      await idle;
      expect(settled, isTrue);
      expect(
        await coordinator.requestNavigationResult(),
        ForegroundIngressRequestResult.allow,
      );
    },
  );

  test('a route-local busy decision can later allow ingress', () async {
    final coordinator = ForegroundIngressCoordinator();
    var transitionPending = true;
    coordinator.register(
      onRequest: () => transitionPending
          ? ForegroundIngressDecision.busy
          : ForegroundIngressDecision.allow,
    );

    expect(
      await coordinator.requestNavigationResult(),
      ForegroundIngressRequestResult.busy,
    );
    transitionPending = false;
    expect(
      await coordinator.requestNavigationResult(),
      ForegroundIngressRequestResult.allow,
    );
  });

  testWidgets(
    'a popup retains its page while a newer page makes it ineligible',
    (tester) async {
      final observer = ForegroundIngressRouteObserver();
      late BuildContext pageContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[observer],
          home: Builder(
            builder: (context) {
              pageContext = context;
              return const Scaffold(body: Text('编辑页面'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final pageRoute = ModalRoute.of(pageContext)!;
      expect(observer.isTopmostPageRoute(pageRoute), isTrue);

      final dialog = showDialog<void>(
        context: pageContext,
        builder: (_) => const AlertDialog(content: Text('编辑器弹窗')),
      );
      await tester.pumpAndSettle();
      expect(observer.isTopmostPageRoute(pageRoute), isTrue);

      Navigator.of(pageContext, rootNavigator: true).pop();
      await dialog;
      await tester.pumpAndSettle();

      Navigator.of(pageContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('覆盖页面')),
        ),
      );
      await tester.pumpAndSettle();
      expect(observer.isTopmostPageRoute(pageRoute), isFalse);
    },
  );
}
