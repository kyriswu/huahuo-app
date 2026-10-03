import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session_store.dart';
import '../../core/native/home_widget_port.dart';
import '../../core/native/recording_card_native_port.dart';
import '../../features/ui_v3/application/knowledge_library_controller.dart';
import '../../features/ui_v3/application/deep_positioning_controller.dart';
import '../../features/ui_v3/data/creation_canvas_history_port.dart';
import '../../features/ui_v3/domain/profile_workspace_models.dart';
import '../lifecycle/app_activity_coordinator.dart';
import 'app_providers.dart';

@immutable
final class HomeWidgetProjectionRevision {
  const HomeWidgetProjectionRevision({
    required this.isAuthenticated,
    required this.personalContentCount,
    required this.depositedContentCount,
    required this.level,
    required this.pointsInLevel,
    required this.recordingState,
    required this.recordingDurationSeconds,
    required this.levelSpan,
    this.recordingActionToken,
    this.accountScope,
    this.recordingStartedAt,
    this.recordingCardBatteryPercent,
  });

  const HomeWidgetProjectionRevision.anonymous()
    : this(
        isAuthenticated: false,
        personalContentCount: 0,
        depositedContentCount: 0,
        level: 1,
        pointsInLevel: 0,
        levelSpan: 1,
        recordingState: HomeWidgetRecordingState.disconnected,
        recordingDurationSeconds: 0,
      );

  final String? accountScope;
  final bool isAuthenticated;
  final int personalContentCount;
  final int depositedContentCount;
  final int level;
  final int pointsInLevel;
  final int levelSpan;
  final String? recordingActionToken;
  final HomeWidgetRecordingState recordingState;
  final int recordingDurationSeconds;
  final DateTime? recordingStartedAt;
  final int? recordingCardBatteryPercent;

  HomeWidgetSnapshot snapshotAt(DateTime now) {
    final startedAt = recordingStartedAt;
    final elapsedSinceStart =
        recordingState == HomeWidgetRecordingState.recording &&
            startedAt != null
        ? now.difference(startedAt).inSeconds
        : 0;
    return HomeWidgetSnapshot(
      isAuthenticated: isAuthenticated,
      personalContentCount: personalContentCount,
      depositedContentCount: depositedContentCount,
      level: level,
      pointsInLevel: pointsInLevel,
      levelSpan: levelSpan,
      recordingActionToken: recordingActionToken,
      recordingState: recordingState,
      recordingElapsedSeconds:
          recordingDurationSeconds +
          (elapsedSinceStart < 0 ? 0 : elapsedSinceStart),
      recordingCardBatteryPercent: recordingCardBatteryPercent,
      updatedAt: now,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetProjectionRevision &&
      other.accountScope == accountScope &&
      other.isAuthenticated == isAuthenticated &&
      other.personalContentCount == personalContentCount &&
      other.depositedContentCount == depositedContentCount &&
      other.level == level &&
      other.pointsInLevel == pointsInLevel &&
      other.levelSpan == levelSpan &&
      other.recordingActionToken == recordingActionToken &&
      other.recordingState == recordingState &&
      other.recordingDurationSeconds == recordingDurationSeconds &&
      other.recordingStartedAt == recordingStartedAt &&
      other.recordingCardBatteryPercent == recordingCardBatteryPercent;

  @override
  int get hashCode => Object.hash(
    accountScope,
    isAuthenticated,
    personalContentCount,
    depositedContentCount,
    level,
    pointsInLevel,
    levelSpan,
    recordingActionToken,
    recordingState,
    recordingDurationSeconds,
    recordingStartedAt,
    recordingCardBatteryPercent,
  );
}

final homeWidgetRecordingActionBindingProvider =
    Provider.autoDispose<HomeWidgetRecordingActionBinding>((ref) {
      final account = ref.watch(
        sessionStoreProvider.select(
          (store) => store.state.authState == SessionAuthState.authenticated
              ? store.state.user?.userId
              : null,
        ),
      );
      if (account == null) return HomeWidgetRecordingActionBinding();
      final target = ref.watch(
        recordingCardControllerProvider.select((controller) {
          final snapshot = controller.state.snapshot;
          return (
            revision: controller.recordingControlRevision,
            connected: snapshot.deviceState.isOperationallyConnected,
            fingerprint: snapshot.deviceState.safeDeviceFingerprint,
            recordingState: snapshot.recordingInfo.state,
          );
        }),
      );
      final fingerprint = target.fingerprint?.trim();
      if (!target.connected || fingerprint == null || fingerprint.isEmpty) {
        return HomeWidgetRecordingActionBinding();
      }
      final random = Random.secure();
      final token = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      return HomeWidgetRecordingActionBinding(
        token: token,
        deviceFingerprint: fingerprint,
      );
    });

// resident-provider: Keeps the home widget projection revision value consistent across sibling route consumers.
final homeWidgetProjectionRevisionProvider =
    Provider<HomeWidgetProjectionRevision>((ref) {
      final account = ref.watch(
        sessionStoreProvider.select(
          (store) =>
              store.state.authState == SessionAuthState.authenticated &&
                  store.state.user != null
              ? store.state.user!.userId
              : null,
        ),
      );
      if (account == null) {
        return const HomeWidgetProjectionRevision.anonymous();
      }

      final counts = ref.watch(
        knowledgeLibraryControllerProvider.select(
          (library) => (
            personal: library.myCreatedNotes.length,
            deposited: library.allDepositedNotes.length,
            growthLedger: library.growthLedgerCount,
          ),
        ),
      );
      final userScope = ref.watch(authenticatedUserDataScopeProvider);
      final historyCount = ref
          .watch(creationCanvasHistoryPortProvider)
          .list(userScope)
          .length;
      final growth = calculateGrowthProgress(
        personalContentCount: counts.personal,
        explicitDepositCount: counts.growthLedger,
        completedCreationCount: historyCount,
        positioningStage:
            ref
                .watch(deepPositioningControllerProvider)
                .result
                ?.positioningStage ??
            0,
      );
      final recording = ref.watch(
        recordingCardControllerProvider.select((controller) {
          final snapshot = controller.state.snapshot;
          final device = snapshot.deviceState;
          final info = snapshot.recordingInfo;
          final connected = device.isOperationallyConnected;
          return (
            state: connected ? info.state : RecordingCardRecordingState.idle,
            startedAt: connected ? info.startedAt : null,
            durationSeconds: connected ? info.durationSeconds ?? 0 : 0,
            batteryPercent: connected ? device.batteryPercent : null,
            connected: connected,
          );
        }),
      );
      return HomeWidgetProjectionRevision(
        accountScope: account,
        isAuthenticated: true,
        personalContentCount: counts.personal,
        depositedContentCount: counts.deposited,
        level: growth.level,
        pointsInLevel: growth.pointsInLevel,
        levelSpan: growth.levelSpan,
        recordingActionToken: ref
            .watch(homeWidgetRecordingActionBindingProvider)
            .token,
        recordingState: !recording.connected
            ? HomeWidgetRecordingState.disconnected
            : switch (recording.state) {
                RecordingCardRecordingState.idle =>
                  HomeWidgetRecordingState.idle,
                RecordingCardRecordingState.recording =>
                  HomeWidgetRecordingState.recording,
                RecordingCardRecordingState.paused =>
                  HomeWidgetRecordingState.paused,
              },
        recordingDurationSeconds: recording.durationSeconds,
        recordingStartedAt: recording.startedAt,
        recordingCardBatteryPercent: recording.batteryPercent,
      );
    });

class HomeWidgetSnapshotSync extends ConsumerStatefulWidget {
  const HomeWidgetSnapshotSync({
    required this.child,
    this.port,
    this.debounceDuration = const Duration(seconds: 1),
    this.retryBaseDelay = const Duration(seconds: 1),
    this.retryMaximumDelay = const Duration(seconds: 30),
    this.maximumRetryAttempts = 4,
    this.now,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final HomeWidgetPort? port;
  final Duration debounceDuration;
  final Duration retryBaseDelay;
  final Duration retryMaximumDelay;
  final int maximumRetryAttempts;
  final DateTime Function()? now;
  final bool enabled;

  @override
  ConsumerState<HomeWidgetSnapshotSync> createState() =>
      _HomeWidgetSnapshotSyncState();
}

class _HomeWidgetSnapshotSyncState
    extends ConsumerState<HomeWidgetSnapshotSync> {
  HomeWidgetPort? _port;
  AppActivityCoordinator? _activityCoordinator;
  ProviderSubscription<HomeWidgetProjectionRevision>? _projectionSubscription;
  HomeWidgetSnapshot? _sent;
  HomeWidgetSnapshot? _queued;
  Timer? _debounceTimer;
  Timer? _retryTimer;
  String? _accountScope;
  var _handledForegroundGeneration = -1;
  var _retryAttempts = 0;
  var _generation = 0;
  var _queuedVersion = 0;
  bool _sending = false;
  bool _wasForeground = false;
  bool _urgent = false;
  bool _forceQueued = false;
  bool _resetRequired = false;

  DateTime get _now => (widget.now ?? DateTime.now)();
  bool get _isForeground =>
      _activityCoordinator?.state.canRunForegroundWork ?? false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _activate();
  }

  void _activate() {
    _port = widget.port ?? MethodChannelHomeWidgetPort();
    final coordinator = ref.read(appActivityCoordinatorProvider);
    _activityCoordinator = coordinator;
    _wasForeground = coordinator.state.canRunForegroundWork;
    coordinator.addListener(_handleActivityChanged);
    _handledForegroundGeneration = coordinator.state.foregroundGeneration;
    _projectionSubscription = ref.listenManual<HomeWidgetProjectionRevision>(
      homeWidgetProjectionRevisionProvider,
      (_, next) {
        if (_accountScope != null && _accountScope != next.accountScope) {
          _resetRequired = true;
          _sent = null;
        }
        _accountScope = next.accountScope;
        _queue(next.snapshotAt(_now));
      },
      fireImmediately: true,
    );
  }

  void _deactivate() {
    _generation += 1;
    _projectionSubscription?.close();
    _projectionSubscription = null;
    _activityCoordinator?.removeListener(_handleActivityChanged);
    _activityCoordinator = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _sent = null;
    _queued = null;
    _urgent = false;
    _forceQueued = false;
    _resetRequired = false;
    _retryAttempts = 0;
  }

  @override
  void didUpdateWidget(covariant HomeWidgetSnapshotSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled || oldWidget.port != widget.port) {
      _deactivate();
      if (widget.enabled) _activate();
    }
  }

  @override
  void dispose() {
    _deactivate();
    super.dispose();
  }

  void _handleActivityChanged() {
    final activity = _activityCoordinator?.state;
    if (activity == null) return;
    final canRunForegroundWork = activity.canRunForegroundWork;
    final changed = _wasForeground != canRunForegroundWork;
    _wasForeground = canRunForegroundWork;
    if (!canRunForegroundWork) {
      if (!changed) return;
      _retryTimer?.cancel();
      _retryTimer = null;
      _queue(
        ref.read(homeWidgetProjectionRevisionProvider).snapshotAt(_now),
        force: true,
        immediate: true,
      );
      return;
    }
    if (_handledForegroundGeneration == activity.foregroundGeneration) return;
    _handledForegroundGeneration = activity.foregroundGeneration;
    ref.invalidate(homeWidgetProjectionRevisionProvider);
    _retryAttempts = 0;
    _queue(
      ref.read(homeWidgetProjectionRevisionProvider).snapshotAt(_now),
      force: true,
    );
  }

  void _queue(
    HomeWidgetSnapshot snapshot, {
    bool force = false,
    bool immediate = false,
  }) {
    final urgent =
        immediate ||
        !snapshot.isAuthenticated ||
        _resetRequired ||
        (_sent != null && _sent!.recordingState != snapshot.recordingState);
    if (!_sending &&
        !force &&
        !_forceQueued &&
        !_resetRequired &&
        _sameContent(_sent, snapshot)) {
      _queued = null;
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      _retryAttempts = 0;
      _urgent = false;
      return;
    }
    final changed = !_sameContent(_queued, snapshot);
    _queued = snapshot;
    _queuedVersion += 1;
    _urgent = _urgent || urgent;
    _forceQueued = _forceQueued || force;
    if (changed || force) {
      _retryAttempts = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (!_isForeground && !_urgent) return;
    if (_urgent || widget.debounceDuration <= Duration.zero) {
      unawaited(_drain());
      return;
    }
    _debounceTimer = Timer(widget.debounceDuration, () {
      _debounceTimer = null;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (!mounted ||
        !widget.enabled ||
        _sending ||
        (!_isForeground && !_urgent)) {
      return;
    }
    final resetting = _resetRequired;
    final snapshot = resetting
        ? const HomeWidgetProjectionRevision.anonymous().snapshotAt(_now)
        : _queued;
    if (snapshot == null) return;
    if (!resetting && !_forceQueued && _sameContent(_sent, snapshot)) {
      _queued = null;
      _urgent = false;
      return;
    }
    final generation = _generation;
    final version = _queuedVersion;
    _sending = true;
    var sent = false;
    try {
      sent = await _port!.update(snapshot);
    } catch (_) {
      sent = false;
    } finally {
      _sending = false;
    }
    if (!mounted || !widget.enabled) return;
    if (generation != _generation) {
      unawaited(_drain());
      return;
    }
    if (sent) {
      _sent = snapshot;
      _retryAttempts = 0;
      if (resetting) {
        _resetRequired = false;
      } else if (version == _queuedVersion) {
        _queued = null;
        _urgent = false;
        _forceQueued = false;
      }
      if (_queued != null) unawaited(_drain());
      return;
    }
    if (version != _queuedVersion) {
      unawaited(_drain());
    } else {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!_isForeground ||
        _retryAttempts >= widget.maximumRetryAttempts ||
        _retryTimer != null) {
      return;
    }
    final delay = _retryDelay(_retryAttempts);
    _retryAttempts += 1;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_drain());
    });
  }

  Duration _retryDelay(int attempt) {
    if (widget.retryBaseDelay <= Duration.zero) return Duration.zero;
    final maximum = widget.retryMaximumDelay <= Duration.zero
        ? widget.retryBaseDelay
        : widget.retryMaximumDelay;
    var microseconds = widget.retryBaseDelay.inMicroseconds
        .clamp(0, maximum.inMicroseconds)
        .toInt();
    for (
      var index = 0;
      index < attempt && microseconds < maximum.inMicroseconds;
      index += 1
    ) {
      microseconds = (microseconds * 2)
          .clamp(0, maximum.inMicroseconds)
          .toInt();
    }
    return Duration(microseconds: microseconds);
  }

  bool _sameContent(HomeWidgetSnapshot? left, HomeWidgetSnapshot right) =>
      left != null && left.hashCode == right.hashCode && left == right;

  @override
  Widget build(BuildContext context) => widget.child;
}
