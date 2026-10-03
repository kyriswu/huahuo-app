import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/session_store.dart';
import '../../core/database/diagnostic_log_dao.dart';
import '../../core/diagnostics/diagnostic_logger.dart';
import '../../features/onboarding/application/content_line_onboarding_controller.dart';
import '../../features/onboarding/application/first_launch_device_setup_controller.dart';
import '../../features/onboarding/application/initial_positioning_task_coordinator.dart';
import '../../features/onboarding/data/first_launch_device_setup_repository.dart';
import '../../features/onboarding/data/initial_positioning_agent.dart';
import '../../features/onboarding/data/onboarding_api.dart';
import '../../features/onboarding/data/onboarding_progress_repository.dart';
import '../../features/chat/domain/assistant_runtime.dart';
import '../../features/ui_v3/application/deep_positioning_controller.dart';
import '../../features/ui_v3/application/positioning_lifecycle_coordinator.dart';
import '../../features/ui_v3/data/deep_positioning_repository.dart';
import '../../features/ui_v3/data/positioning_update_repository.dart';
import '../bootstrap/app_providers.dart';
import '../runtime/runtime_provider_module.dart';
import 'chat_providers.dart';

// resident-provider: Shares one onboarding api dependency for the full account session.
final onboardingApiProvider = Provider<OnboardingApiPort>((ref) {
  return OnboardingApi(apiClient: ref.watch(apiClientProvider));
});

// resident-provider: Preserves the initial positioning agent dependency identity across route changes.
final initialPositioningAgentProvider = Provider<InitialPositioningAgentPort>((
  ref,
) {
  return InitialPositioningAgent(
    chatRepository: ref.watch(chatRepositoryProvider),
    assistantRuntime: ref.watch(assistantRuntimeProvider),
    threadAliasRepository: ref.watch(chatThreadAliasRepositoryProvider),
    profileApi: InitialPositioningProfileApi(
      workspaceClient: WorkspaceLifecycleClient(ref.watch(apiClientProvider)),
    ),
    workspaceReady: () {
      final state = ref.read(sessionStoreProvider).state;
      return state.authState == SessionAuthState.authenticated &&
          state.workspaceStatus == SessionWorkspaceStatus.ready &&
          state.workspace?.workspaceId?.trim().isNotEmpty == true;
    },
  );
});

// resident-provider: Shares one account-scoped onboarding progress repository identity across dependent controllers.
final onboardingProgressRepositoryProvider =
    Provider<OnboardingProgressRepository>(
      (ref) => OnboardingProgressRepository(
        dao: ref.watch(appPreferencesDaoProvider),
        workspaceId: ref.watch(
          sessionStoreProvider.select(
            (store) => store.state.workspace?.workspaceId,
          ),
        ),
      ),
    );

// resident-provider: Preserves the onboarding continuation controller state machine across route transitions.
final onboardingContinuationControllerProvider =
    ChangeNotifierProvider<OnboardingContinuationController>((ref) {
      return OnboardingContinuationController(
        repository: ref.watch(onboardingProgressRepositoryProvider),
      );
    });

// resident-provider: Shares a stable access-check callback; each call reads the current account lifecycle.
final initialPositioningAccessCheckProvider =
    Provider<Future<InitialPositioningAccess> Function()>((ref) {
      return () async =>
          await ref
              .read(positioningLifecycleCoordinatorProvider)
              ?.checkBasicAccess() ??
          InitialPositioningAccess.unavailable;
    });

final contentLineOnboardingControllerProvider =
    ChangeNotifierProvider.autoDispose<ContentLineOnboardingController>((ref) {
      final controller = ContentLineOnboardingController(
        checkPositioningAccess: ref.watch(
          initialPositioningAccessCheckProvider,
        ),
        api: ref.watch(onboardingApiProvider),
        initialPositioningAgent: ref.watch(initialPositioningAgentProvider),
        sessionStore: ref.read(sessionStoreProvider),
        positioningReportSink: ref.watch(initialPositioningReportSinkProvider),
        continuation: ref.watch(
          onboardingContinuationControllerProvider.notifier,
        ),
        runTracker: ref.read(chatRunTrackerProvider),
      );
      KeepAliveLink? submissionKeepAlive;
      void retainPendingSubmission() {
        if (controller.state.isSubmitting ||
            controller.checkingPositioningAccess) {
          submissionKeepAlive ??= ref.keepAlive();
          return;
        }
        final keepAlive = submissionKeepAlive;
        submissionKeepAlive = null;
        keepAlive?.close();
      }

      controller.addListener(retainPendingSubmission);
      ref.onDispose(() {
        controller.removeListener(retainPendingSubmission);
        submissionKeepAlive?.close();
        submissionKeepAlive = null;
      });
      return controller;
    });

// resident-provider: Retains one repository identity per user scope across first-launch route changes.
final firstLaunchDeviceSetupRepositoryProvider =
    Provider.family<FirstLaunchDeviceSetupRepository, String>((ref, userScope) {
      return FirstLaunchDeviceSetupRepository(
        dao: ref.watch(appPreferencesDaoProvider),
        userScope: userScope,
      );
    });

// resident-provider: Keeps the account-synchronization listeners alive across first-launch route changes.
final firstLaunchDeviceSetupControllerProvider =
    ChangeNotifierProvider<FirstLaunchDeviceSetupController>((ref) {
      final sessionStore = ref.read(sessionStoreProvider);
      final continuation = ref.read(onboardingContinuationControllerProvider);
      final controller = FirstLaunchDeviceSetupController.accountScoped(
        repositoryForUser: (userScope) =>
            ref.read(firstLaunchDeviceSetupRepositoryProvider(userScope)),
      );
      void syncAccount() {
        final session = sessionStore.state;
        final userId = session.authState == SessionAuthState.authenticated
            ? session.user?.userId
            : null;
        final progress = continuation.snapshotFor(userId);
        controller.syncAccount(
          userId: userId,
          positioningRequired: session.requiresFirstLoginOnboarding,
          initialPositioningAccepted:
              progress.acceptedRun?.isRegisteredFor(
                session.workspace?.workspaceId,
              ) ==
              true,
          positioningResult: switch (progress.acceptedRun?.lifecycle) {
            OnboardingAcceptedRunLifecycle.succeeded =>
              FirstLaunchStepStatus.succeeded,
            OnboardingAcceptedRunLifecycle.failed =>
              FirstLaunchStepStatus.submitted,
            _ => FirstLaunchStepStatus.submitted,
          },
        );
      }

      sessionStore.addListener(syncAccount);
      continuation.addListener(syncAccount);
      ref.onDispose(() {
        sessionStore.removeListener(syncAccount);
        continuation.removeListener(syncAccount);
      });
      syncAccount();
      return controller;
    });

// resident-provider: Preserves the initial positioning task coordinator dependency identity across route changes.
final initialPositioningTaskCoordinatorProvider =
    ChangeNotifierProvider<InitialPositioningTaskCoordinator>((ref) {
      return InitialPositioningTaskCoordinator(
        onboardingApi: ref.watch(onboardingApiProvider),
        positioningAgent: ref.watch(initialPositioningAgentProvider),
        sessionStore: ref.read(sessionStoreProvider),
        reportSink: ref.watch(initialPositioningReportSinkProvider),
        continuation: ref.watch(
          onboardingContinuationControllerProvider.notifier,
        ),
        taskTracker: ref.watch(chatRunTrackerProvider.notifier),
        reportLifecycle: ref.watch(
          positioningLifecycleCoordinatorProvider.notifier,
        ),
        verifyRunWorkspace: (runId, workspaceId) async {
            final response = await ref
              .read(assistantRuntimeProvider)
              .readRun(handle: AssistantRunHandle(runId));
          return response.ok &&
              response.data?.handle.value == runId &&
              response.data?.workspaceId == workspaceId;
        },
      );
    });

// resident-provider: Keeps the initial positioning task state value consistent across sibling route consumers.
final initialPositioningTaskStateProvider =
    Provider<InitialPositioningTaskState>((ref) {
      final authenticated = ref.watch(
        sessionStoreProvider.select(
          (store) => store.state.authState == SessionAuthState.authenticated,
        ),
      );
      return authenticated
          ? ref.watch(initialPositioningTaskCoordinatorProvider).state
          : const InitialPositioningTaskState();
    });

final initialPositioningRunRegistrarProvider =
    Provider.autoDispose<InitialPositioningRunRegistrar>(
      (ref) =>
          (agentRunId) => ref
              .read(initialPositioningTaskCoordinatorProvider)
              .ensureBackendRegistered(agentRunId),
    );

final initialPositioningReportAcknowledgerProvider =
    Provider.autoDispose<InitialPositioningReportAcknowledger>(
      (ref) =>
          (agentRunId) => ref
              .read(initialPositioningTaskCoordinatorProvider)
              .acknowledgeReportShown(agentRunId: agentRunId),
    );

final initialPositioningServerStateReaderProvider =
    Provider.autoDispose<InitialPositioningServerStateReader>((ref) {
      final onboardingApi = ref.watch(onboardingApiProvider);
      return ({required String workspaceId}) async {
        final normalizedWorkspaceId = workspaceId.trim();
        if (normalizedWorkspaceId.isEmpty ||
            onboardingApi is! OnboardingInitialPositioningPort) {
          return InitialPositioningServerState.unavailable(
            workspaceId: normalizedWorkspaceId,
            errorCode: 'ONBOARDING_FORMALIZATION_UNAVAILABLE',
            retryable: false,
          );
        }
        final initialPositioningApi =
            onboardingApi as OnboardingInitialPositioningPort;
        try {
          final response = await initialPositioningApi
              .currentInitialPositioning(workspaceId: normalizedWorkspaceId);
          final attempt = response.data;
          if (!response.ok || attempt == null) {
            return InitialPositioningServerState.unavailable(
              workspaceId: normalizedWorkspaceId,
              errorCode:
                  response.error?.code ??
                  'INITIAL_POSITIONING_CURRENT_UNAVAILABLE',
              retryable: !response.ok && response.error?.isRetryable == true,
            );
          }
          if (attempt.workspaceId != normalizedWorkspaceId) {
            return InitialPositioningServerState.unavailable(
              workspaceId: normalizedWorkspaceId,
              errorCode: 'INITIAL_POSITIONING_CURRENT_INVALID',
              retryable: false,
            );
          }
          return InitialPositioningServerState.fromAttempt(attempt);
        } catch (_) {
          return InitialPositioningServerState.unavailable(
            workspaceId: normalizedWorkspaceId,
          );
        }
      };
    });

final positioningLifecycleCoordinatorProvider =
    ChangeNotifierProvider.autoDispose<PositioningLifecycleCoordinator?>((ref) {
      final userScope = ref.watch(authenticatedUserDataScopeProvider);
      final workspaceId = ref.watch(
        sessionStoreProvider.select(
          (store) => store.state.workspace?.workspaceId?.trim(),
        ),
      );
      final session = ref.read(sessionStoreProvider);
      final userId = session.state.user?.userId;
      if (userScope == 'anonymous' ||
          userId == null ||
          workspaceId == null ||
          workspaceId.isEmpty)
        return null;
      var disposed = false;
      void invalidateScope() {
        if (session.state.user?.userId != userId ||
            session.state.workspace?.workspaceId?.trim() != workspaceId ||
            session.state.authState != SessionAuthState.authenticated)
          disposed = true;
      }

      session.addListener(invalidateScope);
      ref.onDispose(() {
        disposed = true;
        session.removeListener(invalidateScope);
      });
      bool isCurrent() =>
          !disposed &&
          session.state.authState == SessionAuthState.authenticated &&
          session.state.user?.userId == userId &&
          session.state.workspace?.workspaceId?.trim() == workspaceId;
      final api = ref.watch(onboardingApiProvider);
      final continuation = ref.watch(
        onboardingContinuationControllerProvider.notifier,
      );
      final logger = ref.read(diagnosticLoggerProvider);
      return PositioningLifecycleCoordinator(
        scope: '$userScope\u0000$workspaceId',
        workspaceId: workspaceId,
        isCurrent: isCurrent,
        reports: ref.watch(deepPositioningControllerProvider.notifier),
        updates: RemotePositioningUpdateRepository(
          api: ref.watch(apiClientProvider),
          workspaceId: workspaceId,
          isCurrent: isCurrent,
          assistantRuntime: ref.watch(assistantRuntimeProvider),
          chats: ref.watch(chatRepositoryProvider),
        ),
        store: PreferencePositioningUpdateStore(
          ref.watch(appPreferencesDaoProvider),
          '$userScope\u0000$workspaceId',
        ),
        readAttempt: () async {
          if (!isCurrent() || api is! OnboardingInitialPositioningPort)
            throw StateError('POSITIONING_ATTEMPT_UNAVAILABLE');
          final response = await (api as OnboardingInitialPositioningPort)
              .currentInitialPositioning(workspaceId: workspaceId);
          if (!isCurrent() || !response.ok || response.data == null)
            throw StateError('POSITIONING_ATTEMPT_UNAVAILABLE');
          return response.data!;
        },
        hasLocalPending: () {
          if (session.state.basicPositioningCompleted == true) return true;
          final accepted = continuation.acceptedRunFor(userId);
          return accepted != null &&
              (accepted.workspaceId == null ||
                  accepted.workspaceId == workspaceId) &&
              accepted.lifecycle != OnboardingAcceptedRunLifecycle.failed;
        },
        markBasicCompleted: () {
          if (isCurrent() && session.state.basicPositioningCompleted != true)
            session.applyInitialPositioningAttemptCompletion(
              completedAt: DateTime.now().toUtc(),
            );
        },
        tracker: ref.watch(chatRunTrackerProvider.notifier),
        orchestrator: ref.watch(taskOrchestratorProvider),
        onDiagnostic: (code) {
          if (!isCurrent()) return;
          logger.log(
            DiagnosticLogInput(
              category: DiagnosticCategory.workAi,
              severity: DiagnosticSeverity.info,
              safeSummary: 'positioning lifecycle transition',
              metadata: {
                'scope_hash': positioningDigest('$userScope\u0000$workspaceId'),
                'state': code,
              },
            ),
          );
        },
      );
    });
