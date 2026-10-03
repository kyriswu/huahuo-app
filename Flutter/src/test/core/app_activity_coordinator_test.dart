import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('treats the pre-engine lifecycle as foreground', () {
    final state = AppActivityState.initial(null);

    expect(state.visibility, AppVisibility.foreground);
    expect(state.foregroundGeneration, 1);
    expect(state.canRunForegroundWork, isTrue);
  });

  test('transient inactive keeps the resident foreground generation', () {
    final coordinator = AppActivityCoordinator();
    addTearDown(coordinator.dispose);
    coordinator.updateLifecycle(AppLifecycleState.resumed);
    final initialGeneration = coordinator.state.foregroundGeneration;

    coordinator.updateLifecycle(AppLifecycleState.inactive);
    expect(coordinator.state.visibility, AppVisibility.inactive);
    expect(coordinator.state.canRunForegroundWork, isTrue);
    expect(coordinator.state.foregroundGeneration, initialGeneration);

    coordinator.updateLifecycle(AppLifecycleState.resumed);
    expect(coordinator.state.canRunForegroundWork, isTrue);
    expect(coordinator.state.foregroundGeneration, initialGeneration);
  });

  test('a complete background cycle creates exactly one new generation', () {
    final coordinator = AppActivityCoordinator();
    addTearDown(coordinator.dispose);
    coordinator.updateLifecycle(AppLifecycleState.resumed);
    final initialGeneration = coordinator.state.foregroundGeneration;

    coordinator.updateLifecycle(AppLifecycleState.inactive);
    expect(coordinator.state.canRunForegroundWork, isTrue);
    coordinator.updateLifecycle(AppLifecycleState.hidden);
    expect(coordinator.state.canRunForegroundWork, isFalse);
    coordinator.updateLifecycle(AppLifecycleState.paused);
    coordinator.updateLifecycle(AppLifecycleState.hidden);
    coordinator.updateLifecycle(AppLifecycleState.inactive);
    expect(coordinator.state.canRunForegroundWork, isFalse);
    coordinator.updateLifecycle(AppLifecycleState.resumed);

    expect(coordinator.state.canRunForegroundWork, isTrue);
    expect(coordinator.state.foregroundGeneration, initialGeneration + 1);
  });

  test(
    'projects lifecycle once and increments only real foreground entries',
    () {
      final coordinator = AppActivityCoordinator();
      addTearDown(coordinator.dispose);
      coordinator.updateLifecycle(AppLifecycleState.resumed);
      final initialGeneration = coordinator.state.foregroundGeneration;
      var notifications = 0;
      coordinator.addListener(() => notifications++);

      coordinator.updateLifecycle(AppLifecycleState.paused);
      coordinator.updateLifecycle(AppLifecycleState.paused);
      coordinator.updateLifecycle(AppLifecycleState.resumed);
      coordinator.updateLifecycle(AppLifecycleState.resumed);

      expect(coordinator.state.visibility, AppVisibility.foreground);
      expect(coordinator.state.foregroundGeneration, initialGeneration + 1);
      expect(notifications, 2);
    },
  );

  test('keeps only canonical route and low-frequency context', () {
    final coordinator = AppActivityCoordinator();
    addTearDown(coordinator.dispose);

    coordinator.updateRoute('v3/chat?thread=private#message');
    coordinator.updateActiveTab(' feed ');
    coordinator.updatePowerClass(AppPowerClass.lowPower);
    coordinator.updateNetworkAvailability(false);
    coordinator.didHaveMemoryPressure();

    expect(coordinator.state.route, '/v3/chat');
    expect(coordinator.state.activeTab, 'feed');
    expect(coordinator.state.powerClass, AppPowerClass.lowPower);
    expect(coordinator.state.networkAvailable, isFalse);
    expect(coordinator.state.memoryPressureRevision, 1);
  });

  test('deduplicates Reduce Motion accessibility changes', () {
    final coordinator = AppActivityCoordinator();
    addTearDown(coordinator.dispose);
    var notifications = 0;
    coordinator.addListener(() => notifications++);

    coordinator.updateReduceMotion(true);
    coordinator.updateReduceMotion(true);

    expect(coordinator.state.reduceMotion, isTrue);
    expect(notifications, 1);
  });

  test('projects view metrics changes through one shared revision', () {
    final coordinator = AppActivityCoordinator();
    addTearDown(coordinator.dispose);

    coordinator.didChangeMetrics();
    coordinator.didChangeMetrics();

    expect(coordinator.state.viewMetricsRevision, 2);
  });

  test('attach and detach are idempotent', () {
    final coordinator = AppActivityCoordinator();
    coordinator.attach();
    coordinator.attach();
    expect(coordinator.attached, isTrue);
    coordinator.detach();
    coordinator.detach();
    expect(coordinator.attached, isFalse);
    coordinator.dispose();
  });

  testWidgets('route-aware work receives exact active lifecycle edges', (
    tester,
  ) async {
    final activity = AppActivityCoordinator(binding: tester.binding)
      ..updateLifecycle(AppLifecycleState.resumed);
    addTearDown(activity.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    final events = <String>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[appRouteObserver],
          home: _ActivityRouteProbe(
            onActive: () => events.add('active'),
            onInactive: () => events.add('inactive'),
          ),
        ),
      ),
    );
    await tester.pump();

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(events, <String>['inactive']);

    activity.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    expect(events, <String>['inactive', 'active']);

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covering-route')),
      ),
    );
    await tester.pumpAndSettle();
    expect(events, <String>['inactive', 'active', 'inactive']);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(events, <String>['inactive', 'active', 'inactive', 'active']);

    var poppedInactive = 0;
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _ActivityRouteProbe(
          onActive: () {},
          onInactive: () => poppedInactive += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(poppedInactive, 1);
  });
}

final class _ActivityRouteProbe extends ConsumerStatefulWidget {
  const _ActivityRouteProbe({required this.onActive, required this.onInactive});

  final VoidCallback onActive;
  final VoidCallback onInactive;

  @override
  ConsumerState<_ActivityRouteProbe> createState() =>
      _ActivityRouteProbeState();
}

final class _ActivityRouteProbeState extends ConsumerState<_ActivityRouteProbe>
    with AppActivityRouteAware<_ActivityRouteProbe> {
  @override
  void onActivityRouteBecameActive() => widget.onActive();

  @override
  void onActivityRouteBecameInactive() => widget.onInactive();

  @override
  Widget build(BuildContext context) => const SizedBox();
}
