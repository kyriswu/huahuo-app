import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session_store.dart';
import '../../core/tasking/task_orchestrator.dart';
import '../../features/chat/application/chat_run_tracker.dart';
import '../../features/ui_v3/application/automatic_outline_coordinator.dart';
import '../../features/ui_v3/application/daily_topic_controller.dart';
import '../../features/ui_v3/application/feed_aggregation_controller.dart';
import '../../features/ui_v3/application/knowledge_library_controller.dart';
import '../../features/ui_v3/data/note_file_agent_client.dart';
import '../../features/ui_v3/domain/feed_item_models.dart';
import '../lifecycle/app_activity_coordinator.dart';
import '../runtime/runtime_provider_module.dart';
import 'app_providers.dart';

final class _NotificationInboxReconciliationGate {
  bool _pending = false;
  int? _attemptedForegroundGeneration;

  void resetForAccount({required bool authenticated}) {
    _pending = authenticated;
    _attemptedForegroundGeneration = null;
  }

  void observeVisibility(
    AppVisibility visibility, {
    required bool authenticated,
  }) {
    if (authenticated && visibility == AppVisibility.background) {
      _pending = true;
    }
  }

  void settle() {
    _pending = false;
  }

  bool beginAttempt(int foregroundGeneration) {
    if (!_pending || _attemptedForegroundGeneration == foregroundGeneration) {
      return false;
    }
    _attemptedForegroundGeneration = foregroundGeneration;
    return true;
  }
}

final class _ChatTrackerRuntimeScope {
  const _ChatTrackerRuntimeScope({
    required this.tracker,
    required this.userId,
    required this.workspaceId,
    required this.foregroundGeneration,
  });

  final ChatRunTracker tracker;
  final String userId;
  final String workspaceId;
  final int foregroundGeneration;
}

final class PushRuntimeActivation extends ConsumerStatefulWidget {
  const PushRuntimeActivation({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PushRuntimeActivation> createState() =>
      _PushRuntimeActivationState();
}

class _PushRuntimeActivationState extends ConsumerState<PushRuntimeActivation> {
  static const String _pushLifecycleTaskKey = 'runtime:push:lifecycle';
  static const String _notificationReconciliationTaskKey =
      'runtime:notifications:reconcile';
  static const String _dailyTopicRefreshTaskKey = 'runtime:daily-topic:refresh';
  static const String _chatTrackerActivationTaskKey =
      'runtime:chat-run-tracker:resume';
  static const Duration _dailyTopicRefreshCadence = Duration(minutes: 1);
  static const Set<String> _ownedTaskKeys = <String>{
    'runtime:account-binding',
    'runtime:workspace-ready-refresh',
    _pushLifecycleTaskKey,
    _notificationReconciliationTaskKey,
    _dailyTopicRefreshTaskKey,
    _chatTrackerActivationTaskKey,
    'runtime:cache-policy:refresh',
    'runtime:bootstrap-status:refresh',
  };

  String? _observedUserId;
  ChatRunTracker? _taskTracker;
  final Map<(String, String), ChatRunTracker> _authenticatedTaskTrackers =
      <(String, String), ChatRunTracker>{};
  AutomaticOutlineCoordinator? _automaticOutlineCoordinator;
  FeedAggregationController? _aggregationController;
  Timer? _dailyTopicRefreshTimer;
  Timer? _taskTrackerRestoreRetryTimer;
  var _taskTrackerRestoreRetryAttempt = 0;
  final _NotificationInboxReconciliationGate _notificationReconciliation =
      _NotificationInboxReconciliationGate();
  late final AppActivityCoordinator _activityCoordinator;
  late final TaskOrchestrator _taskOrchestrator;
  var _handledForegroundGeneration = -1;
  var _runtimeStarted = false;
  var _taskTrackerReady = false;

  @override
  void initState() {
    super.initState();
    _taskOrchestrator = ref.read(taskOrchestratorProvider);
    _activityCoordinator = ref.read(appActivityCoordinatorProvider)
      ..addListener(_handleActivityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _installRuntimeBindings();
      _resumeRuntimeForCurrentGeneration();
    });
  }

  void _installRuntimeBindings() {
    ref.listenManual<FeedAggregationController>(
      feedAggregationControllerProvider.notifier,
      (previous, controller) {
        if (identical(previous, controller)) return;
        _aggregationController = controller;
        final canRunForegroundWork =
            _activityCoordinator.state.canRunForegroundWork;
        if (!canRunForegroundWork) controller.pauseProductionPolling();
        controller.attachPollingRuntime(
          orchestrator: _taskOrchestrator,
          activityMetrics: ref.read(runtimeActivityMetricsProvider),
        );
        if (canRunForegroundWork) controller.resumeProductionPolling();
      },
      fireImmediately: true,
    );
    ref.listenManual<String?>(
      sessionStoreProvider.select(
        (store) => authenticatedRuntimeUserId(store.state),
      ),
      _handleAccountUserChanged,
      fireImmediately: true,
    );
    ref.listenManual<SessionWorkspaceStatus?>(
      sessionStoreProvider.select((store) => store.state.workspaceStatus),
      (previous, next) {
        if (next == SessionWorkspaceStatus.ready &&
            previous != SessionWorkspaceStatus.ready) {
          _scheduleWorkspaceReadyRefresh();
        }
      },
    );
    ref.listenManual<ChatRunTracker>(chatRunTrackerProvider.notifier, (
      _,
      tracker,
    ) {
      final userId = authenticatedRuntimeUserId(
        ref.read(sessionStoreProvider).state,
      );
      final workspaceId = readyWorkspaceId(
        ref.read(sessionStoreProvider).state,
      );
      if (userId != null && workspaceId != null) {
        _authenticatedTaskTrackers[(userId, workspaceId)] = tracker;
      }
      if (identical(_taskTracker, tracker)) return;
      _cancelTaskTrackerRestoreRetry();
      _taskTrackerReady = false;
      _taskTracker = tracker;
      _automaticOutlineCoordinator?.setForeground(false);
      _scheduleTaskTrackerActivation(start: true);
    }, fireImmediately: true);
    ref.listenManual<KnowledgeLibraryController>(
      knowledgeLibraryControllerProvider,
      (_, library) {
        unawaited(
          Future<void>.microtask(() async {
            if (!mounted ||
                !identical(
                  ref.read(knowledgeLibraryControllerProvider),
                  library,
                )) {
              return;
            }
            final scope = _currentChatTrackerRuntimeScope();
            if (scope != null && _taskTrackerReady) {
              await _enrollAndReconcileAutomaticOutline(library, scope);
            }
          }),
        );
      },
      fireImmediately: true,
    );
    ref.listenManual<AutomaticOutlineCoordinator>(
      automaticOutlineCoordinatorProvider.notifier,
      (_, coordinator) {
        if (identical(_automaticOutlineCoordinator, coordinator)) return;
        _automaticOutlineCoordinator?.setForeground(false);
        _automaticOutlineCoordinator = coordinator;
        coordinator.start(foreground: false);
        final scope = _currentChatTrackerRuntimeScope();
        if (scope != null && _taskTrackerReady) {
          unawaited(
            _enrollAndReconcileAutomaticOutline(
              ref.read(knowledgeLibraryControllerProvider),
              scope,
            ),
          );
        }
      },
      fireImmediately: true,
    );
    ref.listenManual(
      pushRuntimeControllerProvider,
      (_, __) {},
      fireImmediately: true,
    );
  }

  void _handleAccountUserChanged(String? previous, String? next) {
    if (_observedUserId == next) return;
    final priorUserId = _observedUserId ?? previous;
    final departingTrackers = priorUserId == null || priorUserId == next
        ? const <ChatRunTracker>[]
        : _authenticatedTaskTrackers.entries
              .where((entry) => entry.key.$1 == priorUserId)
              .map((entry) => entry.value)
              .toSet()
              .toList(growable: false);
    _stopDailyTopicRefreshLoop();
    _cancelOwnedTasks('push-runtime-account-scope-changed');
    _observedUserId = next;
    _notificationReconciliation.resetForAccount(authenticated: next != null);
    _handledForegroundGeneration = -1;
    _runtimeStarted = false;
    _cancelTaskTrackerRestoreRetry();
    _taskTrackerReady = false;
    _automaticOutlineCoordinator?.setForeground(false);
    for (final tracker in departingTrackers) {
      tracker.clearForLogout();
    }
    if (priorUserId != null && priorUserId != next) {
      _authenticatedTaskTrackers.removeWhere(
        (scope, _) => scope.$1 == priorUserId,
      );
    }
    _scheduleActivationTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'runtime:account-binding',
        owner: 'runtime-account',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        if (!_ownsAccountScope(next)) return;
        for (final tracker in departingTrackers) {
          try {
            await tracker.flushCheckpointPersistence();
          } catch (_) {
            // The tracker keeps its synchronous tombstone when worker cleanup fails.
          }
        }
        token.throwIfCancelled();
        if (!_ownsAccountScope(next)) return;
        if (next == null) {
          ref.read(pushRuntimeControllerProvider).clearForLogout();
          ref.read(foregroundChatThreadIdProvider.notifier).state = null;
          return;
        }
        await ref.read(appCachePolicyProvider).refresh(force: true);
        token.throwIfCancelled();
        if (!_ownsAccountScope(next)) return;
        await ref.read(pushRuntimeControllerProvider).start();
        token.throwIfCancelled();
        if (!_ownsAccountScope(next)) return;
        await ref.read(pushRegistrationControllerProvider).synchronize();
        token.throwIfCancelled();
        if (!_ownsAccountScope(next)) return;
        final scope = _currentChatTrackerRuntimeScope();
        if (scope == null || scope.userId != next) return;
        await scope.tracker.start();
        token.throwIfCancelled();
        if (!_ownsChatTrackerRuntimeScope(scope)) return;
        _taskTrackerReady = scope.tracker.canTrackAcceptedRuns;
        if (!_taskTrackerReady) {
          _scheduleTaskTrackerRestoreRetry(scope);
          return;
        }
        _cancelTaskTrackerRestoreRetry();
        _runtimeStarted = true;
        await _enrollAndReconcileAutomaticOutline(
          ref.read(knowledgeLibraryControllerProvider),
          scope,
        );
        token.throwIfCancelled();
        if (!_ownsChatTrackerRuntimeScope(scope)) return;
        ref.read(feedAggregationControllerProvider).resumeProductionPolling();
      },
    );
    if (next != null && _activityCoordinator.state.isForeground) {
      _scheduleNotificationReconciliation();
      _startDailyTopicRefreshLoop(
        _activityCoordinator.state.foregroundGeneration,
      );
    }
  }

  void _scheduleWorkspaceReadyRefresh() {
    _scheduleActivationTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'runtime:workspace-ready-refresh',
        owner: 'workspace',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        ref.read(feedAggregationControllerProvider).resumeProductionPolling();
        await ref
            .read(dailyTopicControllerProvider)
            .refresh(DailyTopicRefreshTrigger.workspaceReady);
      },
    );
  }

  void _handleActivityChanged() {
    final activity = _activityCoordinator.state;
    _notificationReconciliation.observeVisibility(
      activity.visibility,
      authenticated: _observedUserId != null,
    );
    if (activity.isForeground) {
      _resumeRuntimeForCurrentGeneration();
      _scheduleNotificationReconciliation();
    } else if (activity.isBackground) {
      _stopDailyTopicRefreshLoop();
      _cancelTaskTrackerRestoreRetry();
      _taskTracker?.pause();
      _taskTrackerReady = false;
      _automaticOutlineCoordinator?.setForeground(false);
      ref.read(feedAggregationControllerProvider).pauseProductionPolling();
    }
  }

  void _scheduleNotificationReconciliation() {
    final userId = _observedUserId;
    if (!mounted ||
        userId == null ||
        !_activityCoordinator.state.isForeground) {
      return;
    }
    final generation = _activityCoordinator.state.foregroundGeneration;
    if (!_notificationReconciliation.beginAttempt(generation)) return;
    _scheduleActivationTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: _notificationReconciliationTaskKey,
        owner: 'notifications',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        if (!_ownsAccountScope(userId) ||
            !_ownsForegroundGeneration(generation)) {
          return;
        }
        final controller = ref.read(notificationControllerProvider);
        await controller.load(forceRemote: true);
        token.throwIfCancelled();
        if (!_ownsAccountScope(userId) ||
            !_ownsForegroundGeneration(generation) ||
            !identical(controller, ref.read(notificationControllerProvider))) {
          return;
        }
        final state = controller.state;
        if (state.lastErrorCode != null || !state.resolutionHydrated) return;
        _notificationReconciliation.settle();
      },
    );
  }

  void _resumeRuntimeForCurrentGeneration() {
    if (!mounted || !_activityCoordinator.state.isForeground) return;
    final generation = _activityCoordinator.state.foregroundGeneration;
    if (_handledForegroundGeneration == generation) return;
    _handledForegroundGeneration = generation;
    _aggregationController?.resumeProductionPolling();
    final shouldStartRuntime = !_runtimeStarted;
    _runtimeStarted = true;
    _startDailyTopicRefreshLoop(generation);

    _scheduleActivationTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: _pushLifecycleTaskKey,
        owner: 'notifications',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        if (!_ownsForegroundGeneration(generation)) return;
        if (shouldStartRuntime) {
          await ref.read(pushRuntimeControllerProvider).start();
        } else {
          await ref.read(pushRuntimeControllerProvider).resume();
        }
        token.throwIfCancelled();
        if (!_ownsForegroundGeneration(generation)) return;
      },
    );
    _scheduleTaskTrackerActivation(start: shouldStartRuntime);
    _scheduleActivationTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'runtime:cache-policy:refresh',
        owner: 'cache',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        await token.delay(const Duration(milliseconds: 80));
        token.throwIfCancelled();
        if (!_ownsForegroundGeneration(generation)) return;
        await ref.read(appCachePolicyProvider).refresh();
        token.throwIfCancelled();
        if (!_ownsForegroundGeneration(generation)) return;
      },
    );
    _scheduleActivationTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'runtime:bootstrap-status:refresh',
        owner: 'bootstrap',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        await token.delay(const Duration(milliseconds: 160));
        token.throwIfCancelled();
        if (!_ownsForegroundGeneration(generation)) return;
        await ref.read(appBootstrapControllerProvider).refreshStatus();
        token.throwIfCancelled();
        if (!_ownsForegroundGeneration(generation)) return;
      },
    );
  }

  void _scheduleTaskTrackerActivation({
    required bool start,
    bool resetRestoreRetry = true,
  }) {
    final scope = _currentChatTrackerRuntimeScope();
    if (scope == null) return;
    if (resetRestoreRetry) _cancelTaskTrackerRestoreRetry();
    _taskTrackerReady = false;
    _automaticOutlineCoordinator?.setForeground(false);
    _scheduleActivationTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: _chatTrackerActivationTaskKey,
        owner: 'chat',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        if (!_ownsChatTrackerRuntimeScope(scope)) return;
        if (start) {
          await scope.tracker.start();
        } else {
          await scope.tracker.resume();
        }
        token.throwIfCancelled();
        if (!_ownsChatTrackerRuntimeScope(scope)) return;
        _taskTrackerReady = scope.tracker.canTrackAcceptedRuns;
        if (!_taskTrackerReady) {
          _scheduleTaskTrackerRestoreRetry(scope);
          return;
        }
        _cancelTaskTrackerRestoreRetry();
        _runtimeStarted = true;
        await _enrollAndReconcileAutomaticOutline(
          ref.read(knowledgeLibraryControllerProvider),
          scope,
        );
        token.throwIfCancelled();
        if (!_ownsChatTrackerRuntimeScope(scope)) return;
      },
    );
  }

  void _scheduleTaskTrackerRestoreRetry(_ChatTrackerRuntimeScope scope) {
    if (_taskTrackerRestoreRetryTimer != null ||
        !_ownsChatTrackerRuntimeScope(scope)) {
      return;
    }
    const delays = <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ];
    final index = _taskTrackerRestoreRetryAttempt.clamp(0, delays.length - 1);
    _taskTrackerRestoreRetryAttempt += 1;
    _taskTrackerRestoreRetryTimer = Timer(delays[index], () {
      _taskTrackerRestoreRetryTimer = null;
      if (!_ownsChatTrackerRuntimeScope(scope) || _taskTrackerReady) return;
      _scheduleTaskTrackerActivation(start: false, resetRestoreRetry: false);
    });
  }

  void _cancelTaskTrackerRestoreRetry() {
    _taskTrackerRestoreRetryTimer?.cancel();
    _taskTrackerRestoreRetryTimer = null;
    _taskTrackerRestoreRetryAttempt = 0;
  }

  void _startDailyTopicRefreshLoop(int generation) {
    _stopDailyTopicRefreshLoop();
    if (_observedUserId == null || !_ownsForegroundGeneration(generation)) {
      return;
    }
    _scheduleDailyTopicRefresh(
      generation,
      DailyTopicRefreshTrigger.foregroundResume,
    );
    _dailyTopicRefreshTimer = Timer.periodic(_dailyTopicRefreshCadence, (_) {
      if (!_ownsForegroundGeneration(generation)) {
        _stopDailyTopicRefreshLoop();
        return;
      }
      _scheduleDailyTopicRefresh(
        generation,
        DailyTopicRefreshTrigger.foregroundCheck,
      );
    });
  }

  void _scheduleDailyTopicRefresh(
    int generation,
    DailyTopicRefreshTrigger trigger,
  ) {
    _scheduleActivationTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: _dailyTopicRefreshTaskKey,
        owner: 'daily-topic',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        if (!_ownsForegroundGeneration(generation)) return;
        await ref.read(dailyTopicControllerProvider).refresh(trigger);
        token.throwIfCancelled();
        if (!_ownsForegroundGeneration(generation)) return;
      },
    );
  }

  void _stopDailyTopicRefreshLoop() {
    _dailyTopicRefreshTimer?.cancel();
    _dailyTopicRefreshTimer = null;
  }

  Future<void> _enrollAndReconcileAutomaticOutline(
    KnowledgeLibraryController library,
    _ChatTrackerRuntimeScope scope,
  ) async {
    final coordinator = _automaticOutlineCoordinator;
    if (!_ownsAutomaticOutlineRuntimeScope(scope, coordinator)) return;
    await _enrollServerDerivedTasks(
      library,
      scope.tracker,
      ownsScope: () => _ownsAutomaticOutlineRuntimeScope(scope, coordinator),
    );
    if (!_ownsAutomaticOutlineRuntimeScope(scope, coordinator) ||
        coordinator == null) {
      return;
    }
    coordinator.setForeground(true);
    coordinator.reconcile();
  }

  _ChatTrackerRuntimeScope? _currentChatTrackerRuntimeScope() {
    if (!mounted || !_activityCoordinator.state.canRunForegroundWork) {
      return null;
    }
    final session = ref.read(sessionStoreProvider).state;
    final userId = _observedUserId;
    final workspaceId = readyWorkspaceId(session);
    if (userId == null ||
        authenticatedRuntimeUserId(session) != userId ||
        workspaceId == null) {
      return null;
    }
    final tracker = ref.read(chatRunTrackerProvider.notifier);
    if (!identical(_taskTracker, tracker)) return null;
    return _ChatTrackerRuntimeScope(
      tracker: tracker,
      userId: userId,
      workspaceId: workspaceId,
      foregroundGeneration: _activityCoordinator.state.foregroundGeneration,
    );
  }

  bool _ownsChatTrackerRuntimeScope(_ChatTrackerRuntimeScope scope) {
    if (!_ownsForegroundGeneration(scope.foregroundGeneration) ||
        _observedUserId != scope.userId ||
        !identical(_taskTracker, scope.tracker)) {
      return false;
    }
    final session = ref.read(sessionStoreProvider).state;
    return authenticatedRuntimeUserId(session) == scope.userId &&
        readyWorkspaceId(session) == scope.workspaceId &&
        identical(ref.read(chatRunTrackerProvider.notifier), scope.tracker);
  }

  bool _ownsAutomaticOutlineRuntimeScope(
    _ChatTrackerRuntimeScope scope,
    AutomaticOutlineCoordinator? coordinator,
  ) {
    if (!_taskTrackerReady ||
        !_ownsChatTrackerRuntimeScope(scope) ||
        !identical(_automaticOutlineCoordinator, coordinator)) {
      return false;
    }
    if (coordinator == null) return true;
    return coordinator.workspaceScope == scope.workspaceId &&
        identical(
          ref.read(automaticOutlineCoordinatorProvider.notifier),
          coordinator,
        );
  }

  bool _ownsForegroundGeneration(int generation) {
    return mounted &&
        _activityCoordinator.state.canRunForegroundWork &&
        _activityCoordinator.state.foregroundGeneration == generation;
  }

  bool _ownsAccountScope(String? userId) {
    return mounted &&
        _observedUserId == userId &&
        authenticatedRuntimeUserId(ref.read(sessionStoreProvider).state) ==
            userId;
  }

  void _cancelOwnedTasks(String reason) {
    for (final key in _ownedTaskKeys) {
      _taskOrchestrator.cancel(key, reason: reason);
    }
  }

  void _scheduleActivationTask(TaskSpec spec, AppTaskBody<void> body) {
    final future = _taskOrchestrator.schedule<void>(spec, body);
    unawaited(_observeActivationTask(spec.key, future));
  }

  Future<void> _observeActivationTask(String key, Future<void> future) async {
    try {
      await future;
    } on AppTaskCancelledException {
      // The shared lifecycle moved to a newer generation.
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'huahuo runtime activation',
          context: ErrorDescription('while running $key'),
        ),
      );
    }
  }

  @override
  void dispose() {
    _stopDailyTopicRefreshLoop();
    _cancelTaskTrackerRestoreRetry();
    _cancelOwnedTasks('push-runtime-disposed');
    _activityCoordinator.removeListener(_handleActivityChanged);
    _taskTracker?.pause();
    _automaticOutlineCoordinator?.setForeground(false);
    _aggregationController?.pauseProductionPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> _enrollServerDerivedTasks(
  KnowledgeLibraryController library,
  ChatRunTracker tracker, {
  required bool Function() ownsScope,
}) async {
  final enrollments = <Future<void>>[];
  for (final note in library.notes) {
    if (!ownsScope()) return;
    final remoteNoteId = note.remoteNoteId?.trim();
    if (remoteNoteId == null || remoteNoteId.isEmpty) continue;
    for (final task in note.activeDerivedTasks) {
      if (task.isTerminal) continue;
      enrollments.add(
        _enrollServerDerivedTask(
          tracker: tracker,
          note: note,
          remoteNoteId: remoteNoteId,
          task: task,
          ownsScope: ownsScope,
        ).catchError((Object _) {
          // The authoritative active-task projection still prevents a second
          // admission; another reconciliation can retry this tracker handoff.
        }),
      );
    }
  }
  if (enrollments.isNotEmpty) await Future.wait(enrollments);
}

Future<void> _enrollServerDerivedTask({
  required ChatRunTracker tracker,
  required V3FeedItem note,
  required String remoteNoteId,
  required V3ActiveDerivedTask task,
  required bool Function() ownsScope,
}) async {
  if (!ownsScope()) return;
  await tracker.rememberKnowledgeAssetSubject(
    localNoteId: note.id,
    subjectTitle: note.title,
  );
  if (!ownsScope()) return;
  await tracker.trackDerivedPart(
    fileAgentRunId: task.fileAgentRunId,
    agentRunId: task.agentRunId,
    status: task.status,
    localNoteId: note.id,
    remoteNoteId: remoteNoteId,
    targetPart: switch (task.stage) {
      V3DerivedTaskStage.outline => NoteFileAgentPart.outline,
      V3DerivedTaskStage.sprout => NoteFileAgentPart.germination,
    },
  );
  if (!ownsScope()) return;
}
