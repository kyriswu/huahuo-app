import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/shared/navigation/foreground_ingress_coordinator.dart';
import 'package:huahuoai_app/shared/navigation/unsaved_changes_guard.dart';

void main() {
  testWidgets(
    'dirty Back waits for confirmation before returning to its parent',
    (tester) async {
      var confirmations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _EditablePage(
                      dirty: true,
                      onConfirmLeave: (_) async {
                        confirmations += 1;
                        return true;
                      },
                    ),
                  ),
                ),
                child: const Text('来源页'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('来源页'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(confirmations, 1);
      expect(find.text('来源页'), findsOneWidget);
    },
  );

  testWidgets('clean direct-entry system Back uses its typed fallback', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/editor',
      routes: <RouteBase>[
        GoRoute(
          path: '/editor',
          builder: (_, __) => const _EditablePage(dirty: false),
        ),
        GoRoute(
          path: '/fallback',
          builder: (_, __) => const Scaffold(body: Text('回退页')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('回退页'), findsOneWidget);
  });

  testWidgets('opted-in clean editor leaves native PopScope open', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: _EditablePage(dirty: false, enableLeadingEdgeSwipeLeave: true),
      ),
    );

    final scope = tester.widget<PopScope<Object?>>(
      find.byType(PopScope<Object?>),
    );
    expect(scope.canPop, isTrue);
  });

  testWidgets(
    'dirty iOS leading-edge swipe requests one guarded confirmation',
    (tester) async {
      var confirmations = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: _EditablePage(
            dirty: true,
            enableLeadingEdgeSwipeLeave: true,
            onConfirmLeave: (_) async {
              confirmations += 1;
              return false;
            },
          ),
        ),
      );

      final scope = tester.widget<PopScope<Object?>>(
        find.byType(PopScope<Object?>),
      );
      expect(scope.canPop, isFalse);

      await tester.dragFrom(const Offset(2, 300), const Offset(110, 4));
      await tester.pumpAndSettle();

      expect(confirmations, 1);
      expect(find.text('编辑页'), findsOneWidget);
    },
  );

  testWidgets('blocked edits and foreground ingress retain the editor route', (
    tester,
  ) async {
    final coordinator = ForegroundIngressCoordinator();
    var blockedCalls = 0;
    var ingressAllowed = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ForegroundIngressScope(
          coordinator: coordinator,
          child: child ?? const SizedBox.shrink(),
        ),
        home: _EditablePage(
          dirty: true,
          blocked: true,
          onBlocked: () => blockedCalls += 1,
          onConfirmForegroundIngress: (_) async => ingressAllowed,
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(blockedCalls, 1);
    expect(find.text('编辑页'), findsOneWidget);

    expect(await coordinator.requestNavigation(), isFalse);
    expect(find.text('编辑页'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ForegroundIngressScope(
          coordinator: coordinator,
          child: child ?? const SizedBox.shrink(),
        ),
        home: _EditablePage(
          dirty: true,
          onConfirmForegroundIngress: (_) async => ingressAllowed,
        ),
      ),
    );
    await tester.pumpAndSettle();
    ingressAllowed = true;

    expect(await coordinator.requestNavigation(), isTrue);
    expect(find.text('编辑页'), findsOneWidget);
  });

  testWidgets(
    'a dialog retains the dirty editor ingress decision but a full page does not',
    (tester) async {
      final coordinator = ForegroundIngressCoordinator();
      var foregroundCalls = 0;
      late BuildContext editorContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[
            foregroundIngressRouteObserver,
          ],
          builder: (context, child) => ForegroundIngressScope(
            coordinator: coordinator,
            child: child ?? const SizedBox.shrink(),
          ),
          home: Builder(
            builder: (context) {
              editorContext = context;
              return _EditablePage(
                dirty: true,
                onConfirmForegroundIngress: (_) async {
                  foregroundCalls += 1;
                  return true;
                },
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dialog = showDialog<void>(
        context: editorContext,
        builder: (_) => const AlertDialog(content: Text('编辑器弹窗')),
      );
      await tester.pumpAndSettle();

      expect(await coordinator.requestNavigation(), isTrue);
      expect(foregroundCalls, 1);

      Navigator.of(editorContext, rootNavigator: true).pop();
      await dialog;
      await tester.pumpAndSettle();

      Navigator.of(editorContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('新完整页面')),
        ),
      );
      await tester.pumpAndSettle();

      expect(await coordinator.requestNavigation(), isTrue);
      expect(foregroundCalls, 1);
    },
  );
}

class _EditablePage extends StatelessWidget {
  const _EditablePage({
    required this.dirty,
    this.blocked = false,
    this.onConfirmLeave,
    this.onConfirmForegroundIngress,
    this.onBlocked,
    this.enableLeadingEdgeSwipeLeave = false,
  });

  final bool dirty;
  final bool blocked;
  final UnsavedChangesConfirmation? onConfirmLeave;
  final UnsavedChangesConfirmation? onConfirmForegroundIngress;
  final VoidCallback? onBlocked;
  final bool enableLeadingEdgeSwipeLeave;

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesGuard(
      hasUnsavedChanges: dirty,
      isLeaveBlocked: blocked,
      fallbackRoute: '/fallback',
      onConfirmLeave: onConfirmLeave ?? (_) async => true,
      onConfirmForegroundIngress: onConfirmForegroundIngress,
      onLeaveBlocked: onBlocked,
      enableLeadingEdgeSwipeLeave: enableLeadingEdgeSwipeLeave,
      child: const Scaffold(body: Center(child: Text('编辑页'))),
    );
  }
}
