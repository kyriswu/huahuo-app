import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/home_widget_snapshot_sync.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/core/native/home_widget_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/profile_workspace_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('huahuoai/home_widgets-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'widget authorization rejects expired, foreign and replayed entries',
    () {
      final now = DateTime.utc(2026, 9, 5);
      final token = 'a' * 64;
      final binding = HomeWidgetRecordingActionBinding(
        token: token,
        deviceFingerprint: 'device-a',
      );
      final revision = now.millisecondsSinceEpoch;
      expect(binding.authorizes(token, revision, now), isTrue);
      expect(binding.authorizes('b' * 64, revision, now), isFalse);
      expect(binding.authorizes(token, null, now), isFalse);
      expect(binding.authorizes(token, revision + 1, now), isFalse);
      expect(
        binding.authorizes(
          token,
          revision,
          now.add(const Duration(minutes: 30)),
        ),
        isFalse,
      );
      expect(binding.claim(token, revision, now), isTrue);
      expect(binding.claim(token, revision, now), isFalse);
    },
  );

  test('widget carries growth stages and true deposit thresholds', () {
    for (final stage in [0, 1, 2]) {
      final growth = calculateGrowthProgress(
        personalContentCount: 4,
        explicitDepositCount: 4,
        completedCreationCount: 0,
        positioningStage: stage,
      );
      final snapshot = HomeWidgetSnapshot(
        isAuthenticated: true,
        personalContentCount: 4,
        depositedContentCount: 4,
        level: growth.level,
        pointsInLevel: growth.pointsInLevel,
        levelSpan: growth.levelSpan,
        recordingState: HomeWidgetRecordingState.disconnected,
        updatedAt: DateTime.utc(2026, 9, 5),
      );
      expect(snapshot.level, stage + 1);
      expect(snapshot.levelSpan, stage == 2 ? 5 : 1);
      expect(snapshot.pointsInLevel, stage == 2 ? 4 : 0);
      expect(snapshot.toChannelMap()['schemaVersion'], 3);
    }
  });

  test('snapshot normalizes bounded scalar values', () {
    final snapshot = HomeWidgetSnapshot(
      isAuthenticated: true,
      personalContentCount: -3,
      depositedContentCount: 2000000,
      level: 99,
      pointsInLevel: 110,
      levelSpan: 100,
      recordingState: HomeWidgetRecordingState.recording,
      recordingCardBatteryPercent: 150,
      recordingElapsedSeconds: 90000000,
      updatedAt: DateTime.utc(2026, 7, 24),
    );

    expect(snapshot.personalContentCount, 0);
    expect(snapshot.depositedContentCount, 1000000);
    expect(snapshot.level, 10);
    expect(snapshot.pointsInLevel, 0);
    expect(snapshot.levelSpan, 0);
    expect(snapshot.recordingCardBatteryPercent, 100);
    expect(snapshot.recordingElapsedSeconds, 86400000);
  });

  test('anonymous snapshot clears personalized widget state', () {
    final snapshot = HomeWidgetSnapshot(
      isAuthenticated: false,
      personalContentCount: 20,
      depositedContentCount: 12,
      level: 6,
      pointsInLevel: 70,
      levelSpan: 100,
      recordingState: HomeWidgetRecordingState.paused,
      recordingCardBatteryPercent: 52,
      recordingElapsedSeconds: 81,
      updatedAt: DateTime.utc(2026, 7, 24),
    );

    expect(snapshot.personalContentCount, 0);
    expect(snapshot.depositedContentCount, 0);
    expect(snapshot.level, 1);
    expect(snapshot.recordingState, HomeWidgetRecordingState.disconnected);
    expect(snapshot.recordingCardBatteryPercent, isNull);
    expect(snapshot.recordingElapsedSeconds, 0);
  });

  test('method channel sends only the approved safe scalar payload', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });
    final port = MethodChannelHomeWidgetPort(channel: channel);
    final snapshot = HomeWidgetSnapshot(
      isAuthenticated: true,
      personalContentCount: 42,
      depositedContentCount: 18,
      level: 4,
      pointsInLevel: 35,
      levelSpan: 100,
      recordingState: HomeWidgetRecordingState.recording,
      recordingCardBatteryPercent: 52,
      recordingElapsedSeconds: 81,
      updatedAt: DateTime.utc(2026, 7, 24),
    );

    expect(await port.update(snapshot), isTrue);
    expect(received?.method, 'updateSnapshot');
    final payload = Map<Object?, Object?>.from(received?.arguments as Map);
    expect(
      payload.keys,
      unorderedEquals(<String>[
        'schemaVersion',
        'isAuthenticated',
        'personalContentCount',
        'depositedContentCount',
        'level',
        'pointsInLevel',
        'levelSpan',
        'recordingState',
        'recordingCardBatteryPercent',
        'recordingElapsedSeconds',
        'updatedAtEpochMs',
      ]),
    );
    for (final forbidden in <String>[
      'userId',
      'safeDeviceFingerprint',
      'path',
      'title',
      'body',
    ]) {
      expect(payload, isNot(contains(forbidden)));
    }
  });

  test('missing native widget implementation fails closed', () async {
    final port = MethodChannelHomeWidgetPort(channel: channel);
    final snapshot = HomeWidgetSnapshot(
      isAuthenticated: false,
      personalContentCount: 0,
      depositedContentCount: 0,
      level: 1,
      pointsInLevel: 0,
      levelSpan: 1,
      recordingState: HomeWidgetRecordingState.disconnected,
      updatedAt: DateTime.utc(2026, 7, 24),
    );

    expect(await port.update(snapshot), isFalse);
  });

  testWidgets('disabled projection keeps child and skips native updates', (
    tester,
  ) async {
    final revision = StateProvider<HomeWidgetProjectionRevision>(
      (ref) => _homeRevision(personalContentCount: 1),
    );
    final port = _FakeHomeWidgetPort();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          homeWidgetProjectionRevisionProvider.overrideWith(
            (ref) => ref.watch(revision),
          ),
        ],
        child: HomeWidgetSnapshotSync(
          enabled: false,
          port: port,
          child: const SizedBox(key: ValueKey('home-widget-child')),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('home-widget-child')), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeWidgetSnapshotSync)),
    );
    container.read(revision.notifier).state = _homeRevision(
      personalContentCount: 2,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(port.snapshots, isEmpty);
  });

  testWidgets('publishes only the latest debounced content revision', (
    tester,
  ) async {
    final revision = StateProvider<HomeWidgetProjectionRevision>(
      (ref) => _homeRevision(personalContentCount: 1),
    );
    final port = _FakeHomeWidgetPort();
    final coordinator = AppActivityCoordinator(binding: tester.binding);
    addTearDown(coordinator.dispose);
    final rebuild = ValueNotifier<int>(0);
    addTearDown(rebuild.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          homeWidgetProjectionRevisionProvider.overrideWith(
            (ref) => ref.watch(revision),
          ),
          appActivityCoordinatorProvider.overrideWith((ref) => coordinator),
        ],
        child: ValueListenableBuilder<int>(
          valueListenable: rebuild,
          builder: (context, value, child) => HomeWidgetSnapshotSync(
            port: port,
            now: () => DateTime.utc(2026, 8, 31, 12),
            child: SizedBox(key: ValueKey<int>(value)),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeWidgetSnapshotSync)),
    );

    container.read(revision.notifier).state = _homeRevision(
      personalContentCount: 2,
    );
    container.read(revision.notifier).state = _homeRevision(
      personalContentCount: 3,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 999));
    expect(port.snapshots, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(port.snapshots, hasLength(1));
    expect(port.snapshots.single.personalContentCount, 3);

    rebuild.value += 1;
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(port.snapshots, hasLength(1));
  });

  testWidgets('bounds native update retries', (tester) async {
    final revision = StateProvider<HomeWidgetProjectionRevision>(
      (ref) => _homeRevision(personalContentCount: 4),
    );
    final port = _FakeHomeWidgetPort(results: <bool>[false, false, false]);
    final coordinator = AppActivityCoordinator(binding: tester.binding);
    addTearDown(coordinator.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          homeWidgetProjectionRevisionProvider.overrideWith(
            (ref) => ref.watch(revision),
          ),
          appActivityCoordinatorProvider.overrideWith((ref) => coordinator),
        ],
        child: HomeWidgetSnapshotSync(
          port: port,
          debounceDuration: Duration.zero,
          retryBaseDelay: const Duration(milliseconds: 10),
          retryMaximumDelay: const Duration(milliseconds: 20),
          maximumRetryAttempts: 2,
          now: () => DateTime.utc(2026, 8, 31, 12),
          child: const SizedBox.shrink(),
        ),
      ),
    );

    await tester.pump();
    expect(port.snapshots, hasLength(1));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(port.snapshots, hasLength(2));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(port.snapshots, hasLength(3));
    await tester.pump(const Duration(seconds: 1));
    expect(port.snapshots, hasLength(3));
  });

  testWidgets('cancels background retry and retries latest on resume', (
    tester,
  ) async {
    final revision = StateProvider<HomeWidgetProjectionRevision>(
      (ref) => _homeRevision(personalContentCount: 5),
    );
    final port = _FakeHomeWidgetPort(results: <bool>[false, true]);
    final coordinator = AppActivityCoordinator(binding: tester.binding);
    addTearDown(coordinator.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          homeWidgetProjectionRevisionProvider.overrideWith(
            (ref) => ref.watch(revision),
          ),
          appActivityCoordinatorProvider.overrideWith((ref) => coordinator),
        ],
        child: HomeWidgetSnapshotSync(
          port: port,
          debounceDuration: Duration.zero,
          retryBaseDelay: const Duration(milliseconds: 10),
          retryMaximumDelay: const Duration(milliseconds: 10),
          now: () => DateTime.utc(2026, 8, 31, 12),
          child: const SizedBox.shrink(),
        ),
      ),
    );

    await tester.pump();
    expect(port.snapshots, hasLength(1));
    coordinator.updateLifecycle(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 1));
    expect(port.snapshots, hasLength(2));

    coordinator.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(port.snapshots, hasLength(3));
  });

  testWidgets('transient inactive does not publish a home widget snapshot', (
    tester,
  ) async {
    final port = _FakeHomeWidgetPort();
    final coordinator = AppActivityCoordinator(binding: tester.binding)
      ..updateLifecycle(AppLifecycleState.resumed);
    addTearDown(coordinator.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          homeWidgetProjectionRevisionProvider.overrideWith(
            (ref) => _homeRevision(personalContentCount: 5),
          ),
          appActivityCoordinatorProvider.overrideWith((ref) => coordinator),
        ],
        child: HomeWidgetSnapshotSync(
          port: port,
          debounceDuration: Duration.zero,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
    expect(port.snapshots, hasLength(1));

    coordinator.updateLifecycle(AppLifecycleState.inactive);
    coordinator.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));

    expect(port.snapshots, hasLength(1));
  });

  testWidgets('latest value survives A to B to A during a native write', (
    tester,
  ) async {
    final revision = StateProvider<HomeWidgetProjectionRevision>(
      (ref) => _homeRevision(personalContentCount: 1),
    );
    final port = _FakeHomeWidgetPort();
    final coordinator = AppActivityCoordinator(binding: tester.binding);
    addTearDown(coordinator.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          homeWidgetProjectionRevisionProvider.overrideWith(
            (ref) => ref.watch(revision),
          ),
          appActivityCoordinatorProvider.overrideWith((ref) => coordinator),
        ],
        child: HomeWidgetSnapshotSync(
          port: port,
          debounceDuration: Duration.zero,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeWidgetSnapshotSync)),
    );
    final gate = Completer<bool>();
    port.nextUpdate = gate;
    container.read(revision.notifier).state = _homeRevision(
      personalContentCount: 2,
    );
    await tester.pump();
    container.read(revision.notifier).state = _homeRevision(
      personalContentCount: 1,
    );
    await tester.pump();
    gate.complete(true);
    await tester.pump();
    await tester.pump();
    expect(port.snapshots.map((value) => value.personalContentCount), <int>[
      1,
      2,
      1,
    ]);

    coordinator.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    container.read(revision.notifier).state =
        const HomeWidgetProjectionRevision.anonymous();
    await tester.pump();
    expect(port.snapshots.last.isAuthenticated, isFalse);
    expect(port.snapshots.last.personalContentCount, 0);
  });

  testWidgets('enabling and disabling synchronization updates subscriptions', (
    tester,
  ) async {
    final enabled = ValueNotifier<bool>(false);
    addTearDown(enabled.dispose);
    final port = _FakeHomeWidgetPort();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          homeWidgetProjectionRevisionProvider.overrideWith(
            (ref) => _homeRevision(personalContentCount: 3),
          ),
        ],
        child: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, value, child) => HomeWidgetSnapshotSync(
            enabled: value,
            port: port,
            debounceDuration: Duration.zero,
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    expect(port.snapshots, isEmpty);
    enabled.value = true;
    await tester.pump();
    await tester.pump();
    expect(port.snapshots, hasLength(1));
    enabled.value = false;
    await tester.pump();
    enabled.value = true;
    await tester.pump();
    await tester.pump();
    expect(port.snapshots, hasLength(2));
  });
}

HomeWidgetProjectionRevision _homeRevision({
  required int personalContentCount,
}) => HomeWidgetProjectionRevision(
  isAuthenticated: true,
  personalContentCount: personalContentCount,
  depositedContentCount: 2,
  level: 3,
  pointsInLevel: 40,
  levelSpan: 100,
  recordingState: HomeWidgetRecordingState.idle,
  recordingDurationSeconds: 0,
);

final class _FakeHomeWidgetPort implements HomeWidgetPort {
  _FakeHomeWidgetPort({List<bool> results = const <bool>[]})
    : _results = List<bool>.of(results);

  final List<bool> _results;
  final List<HomeWidgetSnapshot> snapshots = <HomeWidgetSnapshot>[];
  Completer<bool>? nextUpdate;

  @override
  Future<bool> update(HomeWidgetSnapshot snapshot) async {
    snapshots.add(snapshot);
    final gate = nextUpdate;
    nextUpdate = null;
    if (gate != null) return gate.future;
    return _results.isEmpty ? true : _results.removeAt(0);
  }
}
