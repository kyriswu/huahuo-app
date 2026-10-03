import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/navigation/capture_leave_guard.dart';
import 'package:huahuoai_app/shared/navigation/foreground_ingress_coordinator.dart';

void main() {
  testWidgets('idle leave returns without a confirmation dialog', (
    tester,
  ) async {
    await tester.pumpWidget(_app(state: CaptureLeaveState.idle));
    await _openCapture(tester);

    await tester.tap(find.byKey(const ValueKey('capture-test-back')));
    await tester.pumpAndSettle();

    expect(find.text('来源页'), findsOneWidget);
    expect(find.text('正在录制'), findsNothing);
  });

  testWidgets(
    'capturing leave requires confirmation and invokes explicit end',
    (tester) async {
      var endCalls = 0;
      await tester.pumpWidget(
        _app(
          state: CaptureLeaveState.capturing,
          onEndAndLeave: () async {
            endCalls += 1;
            return true;
          },
        ),
      );
      await _openCapture(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('正在录制'), findsOneWidget);
      expect(find.text('离开当前页面将结束本次录制。'), findsOneWidget);
      expect(find.text('继续录制'), findsOneWidget);
      expect(find.text('结束并离开'), findsOneWidget);

      await tester.tap(find.text('继续录制'));
      await tester.pumpAndSettle();
      expect(find.text('采集页'), findsOneWidget);
      expect(endCalls, 0);

      await tester.tap(find.byKey(const ValueKey('capture-test-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束并离开'));
      await tester.pumpAndSettle();

      expect(endCalls, 1);
      expect(find.text('来源页'), findsOneWidget);
    },
  );

  testWidgets('processing leaves without ending its background task', (
    tester,
  ) async {
    var endCalls = 0;
    await tester.pumpWidget(
      _app(
        state: CaptureLeaveState.processing,
        onEndAndLeave: () {
          endCalls += 1;
          return true;
        },
      ),
    );
    await _openCapture(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('来源页'), findsOneWidget);
    expect(endCalls, 0);
    expect(find.text('正在录制'), findsNothing);
  });

  testWidgets('failed explicit end keeps the capture route mounted', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(state: CaptureLeaveState.capturing, onEndAndLeave: () => false),
    );
    await _openCapture(tester);

    await tester.tap(find.byKey(const ValueKey('capture-test-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('结束并离开'));
    await tester.pumpAndSettle();

    expect(find.text('采集页'), findsOneWidget);
    expect(find.text('来源页'), findsNothing);
  });

  testWidgets(
    'foreground ingress reuses capture confirmation without popping',
    (tester) async {
      final coordinator = ForegroundIngressCoordinator();
      var endCalls = 0;
      await tester.pumpWidget(
        _app(
          coordinator: coordinator,
          state: CaptureLeaveState.capturing,
          onEndAndLeave: () async {
            endCalls += 1;
            return true;
          },
        ),
      );
      await _openCapture(tester);

      final cancelled = coordinator.requestNavigation();
      await tester.pumpAndSettle();
      expect(find.text('正在录制'), findsOneWidget);
      await tester.tap(find.text('继续录制'));
      await tester.pumpAndSettle();
      expect(await cancelled, isFalse);
      expect(endCalls, 0);
      expect(find.text('采集页'), findsOneWidget);

      final allowed = coordinator.requestNavigation();
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束并离开'));
      await tester.pumpAndSettle();
      expect(await allowed, isTrue);
      expect(endCalls, 1);
      expect(find.text('采集页'), findsOneWidget);
    },
  );

  testWidgets(
    'foreground ingress waits for Back frame-end leave before pushing its target',
    (tester) async {
      final coordinator = ForegroundIngressCoordinator();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _app(
          coordinator: coordinator,
          navigatorKey: navigatorKey,
          state: CaptureLeaveState.idle,
        ),
      );
      await _openCapture(tester);

      await tester.tap(find.byKey(const ValueKey('capture-test-back')));
      final ingress = _pushForegroundIngressAfterOneRetry(
        coordinator: coordinator,
        navigatorKey: navigatorKey,
      );

      await tester.pump();
      await tester.pumpAndSettle();
      expect(await ingress, <ForegroundIngressRequestResult>[
        ForegroundIngressRequestResult.busy,
        ForegroundIngressRequestResult.allow,
      ]);
      await tester.pumpAndSettle();

      expect(find.text('前台入口目标'), findsOneWidget);
      expect(find.text('采集页'), findsNothing);
    },
  );

  testWidgets(
    'foreground ingress reads a capture transition before the next frame',
    (tester) async {
      final coordinator = ForegroundIngressCoordinator();
      var state = CaptureLeaveState.idle;
      await tester.pumpWidget(
        _app(
          coordinator: coordinator,
          state: state,
          stateResolver: () => state,
          onEndAndLeave: () async => true,
        ),
      );
      await _openCapture(tester);

      state = CaptureLeaveState.capturing;
      final decision = coordinator.requestNavigation();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('正在录制'), findsOneWidget);
      await tester.tap(find.text('继续录制'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await decision, isFalse);
      expect(find.text('采集页'), findsOneWidget);
    },
  );

  testWidgets(
    'a bottom sheet retains the active capture foreground confirmation',
    (tester) async {
      final coordinator = ForegroundIngressCoordinator();
      await tester.pumpWidget(
        _app(
          coordinator: coordinator,
          state: CaptureLeaveState.capturing,
          onEndAndLeave: () async => true,
        ),
      );
      await _openCapture(tester);

      await tester.tap(find.byKey(const ValueKey('capture-test-bottom-sheet')));
      await tester.pumpAndSettle();
      expect(find.text('采集底部面板'), findsOneWidget);

      final decision = coordinator.requestNavigation();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在录制'), findsOneWidget);

      await tester.tap(find.text('继续录制'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await decision, isFalse);
      expect(find.text('采集页'), findsOneWidget);
    },
  );

  testWidgets(
    'capture auto-navigation is suppressed after a full ingress page covers it',
    (tester) async {
      late BuildContext captureContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captureContext = context;
              return const Scaffold(body: Text('可见采集页'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(isCurrentCaptureRoute(captureContext), isTrue);

      Navigator.of(captureContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('前台入口目标')),
        ),
      );
      await tester.pumpAndSettle();

      expect(isCurrentCaptureRoute(captureContext), isFalse);
    },
  );
}

Widget _app({
  required CaptureLeaveState state,
  CaptureLeaveEndCallback? onEndAndLeave,
  ForegroundIngressCoordinator? coordinator,
  CaptureLeaveStateResolver? stateResolver,
  GlobalKey<NavigatorState>? navigatorKey,
}) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: <NavigatorObserver>[foregroundIngressRouteObserver],
    builder: coordinator == null
        ? null
        : (context, child) => ForegroundIngressScope(
            coordinator: coordinator,
            child: child ?? const SizedBox.shrink(),
          ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('来源页'),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _CapturePage(
                        state: state,
                        onEndAndLeave: onEndAndLeave,
                        stateResolver: stateResolver,
                      ),
                    ),
                  );
                },
                child: const Text('打开采集页'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _openCapture(WidgetTester tester) async {
  await tester.tap(find.text('打开采集页'));
  await tester.pumpAndSettle();
  expect(find.text('采集页'), findsOneWidget);
}

Future<List<ForegroundIngressRequestResult>>
_pushForegroundIngressAfterOneRetry({
  required ForegroundIngressCoordinator coordinator,
  required GlobalKey<NavigatorState> navigatorKey,
}) async {
  var result = await coordinator.requestNavigationResult();
  final results = <ForegroundIngressRequestResult>[result];
  if (result == ForegroundIngressRequestResult.busy) {
    await coordinator.waitUntilIdle();
    result = await coordinator.requestNavigationResult();
    results.add(result);
  }
  if (result == ForegroundIngressRequestResult.allow) {
    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('前台入口目标')),
        ),
      ),
    );
  }
  return results;
}

class _CapturePage extends StatelessWidget {
  const _CapturePage({
    required this.state,
    this.onEndAndLeave,
    this.stateResolver,
  });

  final CaptureLeaveState state;
  final CaptureLeaveEndCallback? onEndAndLeave;
  final CaptureLeaveStateResolver? stateResolver;

  @override
  Widget build(BuildContext context) {
    return CaptureLeaveGuard(
      state: state,
      fallbackRoute: '/fallback',
      onEndAndLeave: onEndAndLeave,
      stateResolver: stateResolver,
      child: Builder(
        builder: (guardContext) => Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('采集页'),
                TextButton(
                  key: const ValueKey('capture-test-back'),
                  onPressed: () =>
                      unawaited(CaptureLeaveGuard.requestLeave(guardContext)),
                  child: const Text('返回'),
                ),
                TextButton(
                  key: const ValueKey('capture-test-bottom-sheet'),
                  onPressed: () => unawaited(
                    showModalBottomSheet<void>(
                      context: guardContext,
                      builder: (_) => const SizedBox(
                        height: 120,
                        child: Center(child: Text('采集底部面板')),
                      ),
                    ),
                  ),
                  child: const Text('打开底部面板'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
