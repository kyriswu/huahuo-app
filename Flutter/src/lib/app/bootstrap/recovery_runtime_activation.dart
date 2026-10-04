import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/auth_providers.dart';
import '../../core/auth/session_store.dart';
import '../../core/tasking/task_orchestrator.dart';
import '../../features/ui_v3/application/profile_workspace_controller.dart';
import '../lifecycle/app_activity_coordinator.dart';
import '../runtime/runtime_provider_module.dart';
import 'app_bootstrap_controller.dart';
import 'app_providers.dart';

final class RecoveryRuntimeActivation extends ConsumerStatefulWidget {
  const RecoveryRuntimeActivation({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RecoveryRuntimeActivation> createState() =>
      _RecoveryRuntimeActivationState();
}

class _RecoveryRuntimeActivationState
    extends ConsumerState<RecoveryRuntimeActivation> {
  static const Set<String> _ownedTaskKeys = <String>{
    'recovery:material-ingestion',
    'recovery:recording-processing',
    'recovery:voiceprint-profiles',
  };

  bool _resumingIngestion = false;
  bool _resumingRecordingProcessing = false;
  String? _observedVoiceprintUserId;
  late final AppActivityCoordinator _activityCoordinator;
  late final TaskOrchestrator _taskOrchestrator;
  var _handledForegroundGeneration = -1;
  var _recoveryWaveGeneration = 0;

  @override
  void initState() {
    super.initState();
    _taskOrchestrator = ref.read(taskOrchestratorProvider);
    _activityCoordinator = ref.read(appActivityCoordinatorProvider)
      ..addListener(_handleActivityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _installRecoveryBindings();
      _resumeForCurrentGeneration();
    });
  }

  void _installRecoveryBindings() {
    ref
        .read(recordingProcessingTrackerProvider)
        .attachPollingRuntime(
          orchestrator: _taskOrchestrator,
          activityMetrics: ref.read(runtimeActivityMetricsProvider),
        );
    ref.listenManual<({bool bootstrapReady, String? userId})>(
      appBootstrapControllerProvider.select((controller) {
        final bootstrapReady =
            controller.state.status == AppBootstrapStatus.ready;
        final userId = bootstrapReady
            ? authenticatedRuntimeUserId(ref.read(sessionStoreProvider).state)
            : null;
        return (bootstrapReady: bootstrapReady, userId: userId);
      }),
      (_, next) => _handleVoiceprintUserChanged(next.userId),
      fireImmediately: true,
    );
    ref.listenManual<String?>(
      sessionStoreProvider.select((store) {
        if (ref.read(appBootstrapControllerProvider).state.status !=
            AppBootstrapStatus.ready) {
          return null;
        }
        return authenticatedRuntimeUserId(store.state);
      }),
      (_, userId) => _handleVoiceprintUserChanged(userId),
      fireImmediately: true,
    );
    ref.listenManual(
      profileWorkspaceControllerProvider,
      (_, __) {},
      fireImmediately: true,
    );
    ref.listenManual(
      uploadRecoveryBootstrapProvider,
      (_, __) {},
      fireImmediately: true,
    );
    ref.listenManual(
      materialIngestionRecoveryBootstrapProvider,
      (_, __) {},
      fireImmediately: true,
    );
  }

  void _handleVoiceprintUserChanged(String? userId) {
    if (_observedVoiceprintUserId == userId) return;
    _observedVoiceprintUserId = userId;
    _handledForegroundGeneration = -1;
    _invalidateRecoveryWave('recovery-account-scope-changed');
    if (userId == null) return;
    _resumeForCurrentGeneration();
  }

  @override
  void dispose() {
    _invalidateRecoveryWave('recovery-runtime-disposed');
    _activityCoordinator.removeListener(_handleActivityChanged);
    super.dispose();
  }

  void _handleActivityChanged() {
    final activity = _activityCoordinator.state;
    if (activity.isBackground) {
      _invalidateRecoveryWave('recovery-backgrounded');
      return;
    }
    if (activity.isForeground) _resumeForCurrentGeneration();
  }

  void _resumeForCurrentGeneration() {
    if (!mounted || !_activityCoordinator.state.isForeground) return;
    final generation = _activityCoordinator.state.foregroundGeneration;
    if (_handledForegroundGeneration == generation) return;
    _handledForegroundGeneration = generation;
    final recoveryWave = ++_recoveryWaveGeneration;
    _scheduleRecoveryTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'recovery:material-ingestion',
        owner: 'ingestion',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{
          TaskResource.network,
          TaskResource.database,
        },
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        token.throwIfCancelled();
        if (!_ownsRecoveryWave(recoveryWave, generation)) return;
        await _resumeMaterialIngestion(
          token: token,
          recoveryWave: recoveryWave,
          foregroundGeneration: generation,
        );
      },
    );
    _scheduleRecoveryTask(
      // performance-rfc: runtime-activation-resident-tasks
      TaskSpec(
        key: 'recovery:recording-processing',
        owner: 'recordings',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{
          TaskResource.network,
          TaskResource.database,
        },
        foregroundOnly: true,
        replaceExisting: true,
      ),
      (token) async {
        await token.delay(const Duration(milliseconds: 120));
        token.throwIfCancelled();
        if (!_ownsRecoveryWave(recoveryWave, generation)) return;
        await _resumeRecordingProcessing(
          token: token,
          recoveryWave: recoveryWave,
          foregroundGeneration: generation,
        );
      },
    );
    final userId = _observedVoiceprintUserId;
    if (userId != null) {
      _scheduleRecoveryTask(
        // performance-rfc: runtime-activation-resident-tasks
        TaskSpec(
          key: 'recovery:voiceprint-profiles',
          owner: 'voiceprint',
          priority: TaskPriority.foregroundDeferred,
          resources: const <TaskResource>{TaskResource.network},
          foregroundOnly: true,
          replaceExisting: true,
        ),
        (token) async {
          await token.delay(const Duration(milliseconds: 240));
          token.throwIfCancelled();
          if (!_ownsRecoveryWave(
            recoveryWave,
            generation,
            expectedUserId: userId,
          )) {
            return;
          }
          await _syncVoiceprintProfiles(
            userId,
            token: token,
            recoveryWave: recoveryWave,
            foregroundGeneration: generation,
          );
        },
      );
    }
  }

  void _scheduleRecoveryTask(TaskSpec spec, AppTaskBody<void> body) {
    final future = _taskOrchestrator.schedule<void>(spec, body);
    unawaited(_observeRecoveryTask(spec.key, future));
  }

  Future<void> _observeRecoveryTask(String key, Future<void> future) async {
    try {
      await future;
    } on AppTaskCancelledException {
      // The shared lifecycle moved to a newer generation.
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'huahuo recovery activation',
          context: ErrorDescription('while running $key'),
        ),
      );
    }
  }

  Future<void> _resumeMaterialIngestion({
    required AppTaskCancellationToken token,
    required int recoveryWave,
    required int foregroundGeneration,
  }) async {
    if (_resumingIngestion || !mounted) return;
    if (ref.read(sessionStoreProvider).state.authState !=
        SessionAuthState.authenticated) {
      return;
    }
    _resumingIngestion = true;
    try {
      final coordinator = ref.read(materialIngestionCoordinatorProvider);
      await coordinator.recoverPending();
      token.throwIfCancelled();
      if (!_ownsRecoveryWave(recoveryWave, foregroundGeneration)) return;
      await coordinator.refreshMemoryNotes();
      token.throwIfCancelled();
      if (!_ownsRecoveryWave(recoveryWave, foregroundGeneration)) return;
    } finally {
      _resumingIngestion = false;
    }
  }

  Future<void> _resumeRecordingProcessing({
    required AppTaskCancellationToken token,
    required int recoveryWave,
    required int foregroundGeneration,
  }) async {
    if (_resumingRecordingProcessing || !mounted) return;
    if (ref.read(sessionStoreProvider).state.authState !=
        SessionAuthState.authenticated) {
      return;
    }
    _resumingRecordingProcessing = true;
    try {
      final deletionRecovery = await ref
          .read(localRecordingRepositoryProvider)
          .recoverInterruptedLocalDeletions();
      if (!deletionRecovery.ok) {
        throw StateError(
          deletionRecovery.error?.code ??
              'RECORDING_DELETE_RECOVERY_UNEXPECTED_FAILURE',
        );
      }
      token.throwIfCancelled();
      if (!_ownsRecoveryWave(recoveryWave, foregroundGeneration)) return;
      await ref.read(recordingUploadControllerProvider).recoverDrafts();
      token.throwIfCancelled();
      if (!_ownsRecoveryWave(recoveryWave, foregroundGeneration)) return;
      await ref.read(recordingProcessingTrackerProvider).refreshPending();
      token.throwIfCancelled();
      if (!_ownsRecoveryWave(recoveryWave, foregroundGeneration)) return;
      await ref
          .read(recordingBatchTranscriptionControllerProvider)
          .resumePendingRemoteVerifications();
      token.throwIfCancelled();
      if (!_ownsRecoveryWave(recoveryWave, foregroundGeneration)) return;
    } finally {
      _resumingRecordingProcessing = false;
    }
  }

  Future<void> _syncVoiceprintProfiles(
    String expectedUserId, {
    required AppTaskCancellationToken token,
    required int recoveryWave,
    required int foregroundGeneration,
  }) async {
    if (!mounted) return;
    if (ref.read(appBootstrapControllerProvider).state.status !=
        AppBootstrapStatus.ready) {
      return;
    }
    final currentUserId = authenticatedRuntimeUserId(
      ref.read(sessionStoreProvider).state,
    );
    if (currentUserId != expectedUserId) return;
    await ref.read(voiceprintProfileSyncServiceProvider).sync();
    token.throwIfCancelled();
    if (!_ownsRecoveryWave(
      recoveryWave,
      foregroundGeneration,
      expectedUserId: expectedUserId,
    )) {
      return;
    }
  }

  bool _ownsRecoveryWave(
    int recoveryWave,
    int foregroundGeneration, {
    String? expectedUserId,
  }) {
    if (!mounted ||
        !_activityCoordinator.state.canRunForegroundWork ||
        _activityCoordinator.state.foregroundGeneration !=
            foregroundGeneration ||
        _recoveryWaveGeneration != recoveryWave) {
      return false;
    }
    if (expectedUserId == null) return true;
    return _observedVoiceprintUserId == expectedUserId &&
        authenticatedRuntimeUserId(ref.read(sessionStoreProvider).state) ==
            expectedUserId;
  }

  void _invalidateRecoveryWave(String reason) {
    _recoveryWaveGeneration += 1;
    for (final key in _ownedTaskKeys) {
      _taskOrchestrator.cancel(key, reason: reason);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
