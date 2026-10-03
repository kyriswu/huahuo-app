import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/shared/navigation/safe_navigation.dart';

void main() {
  testWidgets('foreground ingress pushes and restores the interrupted page', (
    tester,
  ) async {
    late final GoRouter router;
    router = GoRouter(
      initialLocation: '/source',
      routes: <RouteBase>[
        GoRoute(
          path: '/source',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => navigateForIngress(
                router,
                location: '/target',
                action: IngressNavigationAction.push,
              ),
              child: const Text('来源页'),
            ),
          ),
        ),
        GoRoute(
          path: '/target',
          builder: (context, state) => Scaffold(
            body: TextButton(onPressed: router.pop, child: const Text('入口目标页')),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('来源页'));
    await tester.pumpAndSettle();

    expect(find.text('入口目标页'), findsOneWidget);

    await tester.tap(find.text('入口目标页'));
    await tester.pumpAndSettle();

    expect(find.text('来源页'), findsOneWidget);
  });
}
