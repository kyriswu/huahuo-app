import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/lifecycle/page_activity_lease.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('requires foreground, visible route, active tab and no cover', () {
    final activity = AppActivityCoordinator();
    final lease = PageActivityLease(activity: activity);
    addTearDown(activity.dispose);
    addTearDown(lease.dispose);
    var notifications = 0;
    lease.addListener(() => notifications += 1);

    expect(lease.active, isTrue);
    lease.setTabActive(false);
    lease.setRouteVisible(false);
    lease.setCovered(true);
    expect(lease.active, isFalse);
    expect(notifications, 1);

    lease.setTabActive(true);
    lease.setRouteVisible(true);
    expect(lease.active, isFalse);
    lease.setCovered(false);
    expect(lease.active, isTrue);
    expect(lease.activationGeneration, 1);

    activity.updateLifecycle(AppLifecycleState.paused);
    activity.updateLifecycle(AppLifecycleState.resumed);
    expect(lease.active, isTrue);
    expect(lease.activationGeneration, 2);
    expect(notifications, 4);
  });

  test('dispose detaches from application activity', () {
    final activity = AppActivityCoordinator();
    final lease = PageActivityLease(activity: activity);
    var notifications = 0;
    lease.addListener(() => notifications += 1);

    lease.dispose();
    activity.updateLifecycle(AppLifecycleState.paused);

    expect(notifications, 0);
    activity.dispose();
  });
}
