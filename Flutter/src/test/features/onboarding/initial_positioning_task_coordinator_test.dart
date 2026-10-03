import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/onboarding/application/content_line_onboarding_controller.dart';
import 'package:huahuoai_app/features/onboarding/application/initial_positioning_task_coordinator.dart';
import 'package:huahuoai_app/features/onboarding/data/initial_positioning_agent.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_api.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_progress_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';
import '../chat/assistant_runtime_test_adapter.dart';

final _productionLengthRunId =
    'agent_run_user_${List<String>.filled(64, 'a').join()}'
    '_workspace_chat_workspace_chat_run_0123456789abcdef';

void main() {
  test(
    'independent formal recovery does not depend on historical assistant messages',
    () async {
      final fixture = await _fixture(
        acceptedSucceeded: true,
        savedProfileRead: _savedProfileSuccess(),
        reportResults: [
          InitialPositioningAgentSubmission.failure(
            'ONBOARDING_THREAD_READBACK_INVALID',
          ),
        ],
        registeredAttemptId: 'positioning_attempt_agent_run_positioning_1',
      );
      await fixture.coordinator.start();
      await _waitForReportReady(fixture);
      expect(
        fixture.coordinator.state.isReportReadyFor('agent_run_positioning_1'),
        isTrue,
      );
      expect(fixture.agent.completeCalls, 0);
      expect(fixture.agent.profileReadCalls, greaterThan(0));
    },
  );
  test(
    'server read projection only polls retryable unavailable failures',
    () async {
      final api = _OnboardingApi(
        currentFailures: const <AppFailure?>[
          AppFailure(
            code: 'INITIAL_POSITIONING_CURRENT_INVALID',
            category: AppFailureCategory.compatibility,
            message: 'invalid response',
            userMessageKey: 'initialPositioning.invalid',
          ),
          AppFailure(
            code: 'INITIAL_POSITIONING_UNAVAILABLE',
            category: AppFailureCategory.api,
            message: 'temporarily unavailable',
            userMessageKey: 'initialPositioning.unavailable',
            isRetryable: true,
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [onboardingApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final first = await container.read(
        initialPositioningServerStateReaderProvider,
      )(workspaceId: 'workspace-1');
      final second = await container.read(
        initialPositioningServerStateReaderProvider,
      )(workspaceId: 'workspace-1');
      final unknown = InitialPositioningServerState.fromAttempt(
        const InitialPositioningAttempt(
          workspaceId: 'workspace-1',
          state: 'future_state',
          attemptId: 'positioning_attempt_future',
          agentRunId: 'agent_run_future',
        ),
      );

      expect(first.phase, InitialPositioningServerPhase.unavailable);
      expect(first.shouldPoll, isFalse);
      expect(second.phase, InitialPositioningServerPhase.unavailable);
      expect(second.shouldPoll, isTrue);
      expect(unknown.phase, InitialPositioningServerPhase.unavailable);
      expect(unknown.shouldPoll, isFalse);
    },
  );

  test(
    'recovers an orphaned Run when its canonical report was already committed',
    () async {
      final fixture = await _fixture(
        runStatus: 'orphaned',
        currentAttempts: <InitialPositioningAttempt>[
          _committedRuntimeGapAttempt(
            reportUpdatedAt: DateTime.utc(2026, 8, 16, 9, 0, 30),
          ),
        ],
        registeredAttemptId: 'positioning_attempt_agent_run_positioning_1',
        acceptedFailureCode: 'CHAT_AGENT_RUN_ORPHANED',
        savedProfileRead: _savedProfileSuccess(),
      );
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(
        fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
        OnboardingAcceptedRunLifecycle.succeeded,
      );
      expect(
        fixture.continuation.acceptedRunFor('user-1')?.reportSource,
        OnboardingAcceptedRunReportSource.workspaceProfile,
      );
      expect(fixture.session.state.requiresInitialPositioning, isFalse);
      expect(fixture.sink.markdown, '## 已写入的定位报告\n适合持续表达。');
      expect(fixture.agent.profileReadCalls, 1);
      expect(fixture.agent.completeCalls, 0);
      expect(fixture.agent.startCalls, 0);
      expect(fixture.agent.submitCalls, 0);
      expect(fixture.api.formalRequests, isEmpty);
    },
  );

  test(
    'restores a persisted recovered report without rereading the orphaned Run',
    () async {
      final fixture = await _fixture(
        runStatus: 'orphaned',
        completedSession: true,
        acceptedSucceeded: true,
        acceptedReportSource:
            OnboardingAcceptedRunReportSource.workspaceProfile,
        registeredAttemptId: 'positioning_attempt_agent_run_positioning_1',
        savedProfileRead: _savedProfileSuccess(),
      );
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(
        fixture.coordinator.state.isReportReadyFor('agent_run_positioning_1'),
        isTrue,
      );
      expect(fixture.sink.markdown, '## 已写入的定位报告\n适合持续表达。');
      expect(fixture.agent.profileReadCalls, 1);
      expect(fixture.agent.completeCalls, 0);
      expect(fixture.api.formalRequests, isEmpty);
    },
  );

  test(
    'keeps persisted success while its Workspace Profile is unavailable',
    () async {
      final fixture = await _fixture(
        runStatus: 'orphaned',
        completedSession: true,
        acceptedSucceeded: true,
        acceptedReportSource:
            OnboardingAcceptedRunReportSource.workspaceProfile,
        registeredAttemptId: 'positioning_attempt_agent_run_positioning_1',
        savedProfileRead: InitialPositioningProfileRead.failure(
          'ONBOARDING_PROFILE_READ_FAILED',
        ),
      );
      addTearDown(fixture.dispose);

      await fixture.coordinator.start();

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(
        fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
        OnboardingAcceptedRunLifecycle.succeeded,
      );
      expect(fixture.agent.profileReadCalls, 1);
      expect(fixture.agent.completeCalls, 0);
      expect(fixture.sink.markdown, isNull);
    },
  );

  test('keeps an orphaned Run failed when report evidence is stale', () async {
    final fixture = await _fixture(
      runStatus: 'orphaned',
      currentAttempts: <InitialPositioningAttempt>[
        _committedRuntimeGapAttempt(
          reportUpdatedAt: DateTime.utc(2026, 8, 16, 8, 59, 59),
        ),
      ],
      registeredAttemptId: 'positioning_attempt_agent_run_positioning_1',
      acceptedFailureCode: 'CHAT_AGENT_RUN_ORPHANED',
      savedProfileRead: _savedProfileSuccess(),
    );
    addTearDown(fixture.dispose);

    await _settle(fixture.coordinator);

    expect(
      fixture.coordinator.state.status,
      InitialPositioningTaskStatus.failed,
    );
    expect(fixture.session.state.requiresInitialPositioning, isTrue);
    expect(fixture.sink.markdown, isNull);
    expect(fixture.agent.profileReadCalls, 0);
    expect(fixture.agent.completeCalls, 0);
    expect(fixture.api.formalRequests, isEmpty);
  });

  test(
    'does not recover an unrelated failed Run from report presence',
    () async {
      final fixture = await _fixture(
        runStatus: 'failed',
        currentAttempts: <InitialPositioningAttempt>[
          _committedRuntimeGapAttempt(
            reportUpdatedAt: DateTime.utc(2026, 8, 16, 9, 0, 30),
          ),
        ],
        registeredAttemptId: 'positioning_attempt_agent_run_positioning_1',
        acceptedFailureCode: 'WORKSPACE_VERSION_CONFLICT',
        savedProfileRead: _savedProfileSuccess(),
      );
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.failed,
      );
      expect(fixture.session.state.requiresInitialPositioning, isTrue);
      expect(fixture.sink.markdown, isNull);
      expect(fixture.agent.profileReadCalls, 0);
      expect(fixture.agent.completeCalls, 0);
      expect(fixture.api.formalRequests, isEmpty);
    },
  );

  test(
    'handoff persistence failure recovers the registered attempt without resending',
    () async {
      final fixture = await _fixture(
        runStatus: 'running',
        failReceiptPersistenceOnce: true,
      );
      addTearDown(fixture.dispose);
      fixture.snapshotStore!.failWrites = true;
      expect(
        await fixture.coordinator.ensureBackendRegistered(
          'agent_run_positioning_1',
        ),
        isFalse,
      );
      expect(
        fixture.continuation.acceptedRunFor('user-1')?.agentRunId,
        'agent_run_positioning_1',
      );
      expect(
        fixture.continuation.hasRegisteredRunFor('user-1', 'workspace-1'),
        isFalse,
      );
      expect(
        fixture.coordinator.state.errorCode,
        'ONBOARDING_PROGRESS_SAVE_FAILED',
      );
      fixture.snapshotStore!.failWrites = false;
      expect(
        await fixture.coordinator.ensureBackendRegistered(
          'agent_run_positioning_1',
        ),
        isTrue,
      );
      expect(
        fixture.continuation.hasRegisteredRunFor('user-1', 'workspace-1'),
        isTrue,
      );
      expect(fixture.api.formalRequests, hasLength(1));
      expect(fixture.agent.startCalls, 0);
      expect(fixture.agent.submitCalls, 0);
    },
  );

  test(
    'handoff confirmation coalesces and returns before generation completes',
    () async {
      final fixture = await _fixture(runStatus: 'running');
      addTearDown(fixture.dispose);
      final gate = Completer<void>();
      fixture.api.createGate = gate;
      final background = fixture.coordinator.start();
      final submission = fixture.coordinator.ensureBackendRegistered(
        'agent_run_positioning_1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.api.formalRequests, hasLength(1));
      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.registering,
      );
      expect(
        fixture.continuation.hasRegisteredRunFor('user-1', 'workspace-1'),
        isFalse,
      );
      gate.complete();
      expect(await submission, isTrue);
      expect(
        fixture.continuation.hasRegisteredRunFor('user-1', 'workspace-1'),
        isTrue,
      );
      expect(fixture.sink.saveCalls, 0);
      await background;
      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.running,
      );
      expect(fixture.api.formalRequests, hasLength(1));
    },
  );

  test(
    'registration retry preserves its Run after a lost acknowledgement',
    () async {
      final fixture = await _fixture(
        runStatus: 'running',
        createFailures: [
          const AppFailure(
            code: 'NETWORK_UNAVAILABLE',
            category: AppFailureCategory.network,
            message: 'offline',
            userMessageKey: 'network.offline',
            isRetryable: true,
          ),
          null,
        ],
        currentAttempts: const [
          InitialPositioningAttempt(
            workspaceId: 'workspace-1',
            state: 'not_started',
          ),
          InitialPositioningAttempt(
            workspaceId: 'workspace-1',
            state: 'not_started',
          ),
        ],
      );
      addTearDown(fixture.dispose);
      expect(
        await fixture.coordinator.ensureBackendRegistered(
          'agent_run_positioning_1',
        ),
        isFalse,
      );
      expect(
        fixture.continuation.hasRegisteredRunFor('user-1', 'workspace-1'),
        isFalse,
      );
      expect(
        fixture.continuation.acceptedRunFor('user-1')?.registrationErrorCode,
        'NETWORK_UNAVAILABLE',
      );
      expect(
        await fixture.coordinator.ensureBackendRegistered(
          'agent_run_positioning_1',
        ),
        isTrue,
      );
      expect(fixture.api.formalRequests, hasLength(2));
      expect(
        fixture.api.formalRequests.map((request) => request.agentRunId).toSet(),
        {'agent_run_positioning_1'},
      );
      expect(fixture.agent.submitCalls, 0);
    },
  );

  for (final alreadyBound in [false, true]) {
    test(
      'registers a running task before terminal status, existing=$alreadyBound',
      () async {
        const attempt = InitialPositioningAttempt(
          workspaceId: 'workspace-1',
          agentRunId: 'agent_run_positioning_1',
          attemptId: 'positioning_attempt_agent_run_positioning_1',
          state: 'running',
        );
        final fixture = await _fixture(
          runStatus: 'running',
          currentAttempts: [
            if (alreadyBound)
              attempt
            else
              const InitialPositioningAttempt(
                workspaceId: 'workspace-1',
                state: 'not_started',
              ),
          ],
          createdAttempt: attempt,
        );
        addTearDown(fixture.dispose);
        await fixture.coordinator.start();
        await fixture.coordinator.refresh();
        await fixture.coordinator.refresh();
        expect(fixture.api.formalRequests.length, alreadyBound ? 0 : 1);
        expect(
          fixture.coordinator.state.status,
          InitialPositioningTaskStatus.running,
        );
        expect(
          fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
          OnboardingAcceptedRunLifecycle.running,
        );
        expect(fixture.session.state.requiresInitialPositioning, isTrue);
        expect(fixture.sink.markdown, isNull);
        expect(fixture.agent.startCalls, 0);
        expect(fixture.agent.submitCalls, 0);
      },
    );
  }

  test('report sink replacement rebinds the durable finalizer', () async {
    final fixture = await _fixture();
    fixture.coordinator.dispose();
    var sink = _ReportSink(saveResults: <bool>[false]);
    final container = ProviderContainer(
      overrides: [
        positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
        assistantRuntimeProvider.overrideWithValue(
          legacyAssistantRuntime(_SucceededRunPort(status: 'succeeded')),
        ),
        sessionStoreProvider.overrideWith((ref) => fixture.session),
        onboardingApiProvider.overrideWithValue(fixture.api),
        initialPositioningAgentProvider.overrideWithValue(fixture.agent),
        initialPositioningReportSinkProvider.overrideWith((ref) => sink),
        onboardingContinuationControllerProvider.overrideWith(
          (ref) => fixture.continuation,
        ),
        chatRunTrackerProvider.overrideWith((ref) => fixture.tracker),
      ],
    );
    addTearDown(container.dispose);
    final previous = container.read(initialPositioningTaskCoordinatorProvider);
    fixture.continuation.markRunFinalizing('user-1');
    sink = _ReportSink();
    container.invalidate(initialPositioningReportSinkProvider);
    final current = container.read(initialPositioningTaskCoordinatorProvider);
    expect(current, isNot(same(previous)));

    await _settle(current);

    expect(current.state.status, InitialPositioningTaskStatus.succeeded);
    expect(sink.markdown, isNotNull);
    expect(fixture.agent.startCalls, 0);
    expect(fixture.agent.submitCalls, 0);
    expect(
      container.read(initialPositioningTaskCoordinatorProvider),
      same(current),
    );
  });

  for (final alreadyCompleted in <bool>[false, true]) {
    test(
      'reconciles a persisted admission failure with existing attempt $alreadyCompleted',
      () async {
        expect(_productionLengthRunId.length, 130);
        final fixture = await _fixture(
          agentRunId: _productionLengthRunId,
          currentAttempts: alreadyCompleted
              ? <InitialPositioningAttempt>[
                  InitialPositioningAttempt(
                    workspaceId: 'workspace-1',
                    state: 'completed',
                    agentRunId: _productionLengthRunId,
                    attemptId: 'positioning_attempt_$_productionLengthRunId',
                  ),
                ]
              : null,
        );
        addTearDown(fixture.dispose);
        expect(
          fixture.continuation.markRunFailed(
            'user-1',
            'INITIAL_POSITIONING_INVALID',
          ),
          isTrue,
        );
        final savedAnswers = fixture.continuation.snapshotFor('user-1').answers;
        final observed = <OnboardingAcceptedRunLifecycle>[];
        final taskStates = <InitialPositioningTaskState>[];
        fixture.coordinator.addListener(() {
          taskStates.add(fixture.coordinator.state);
        });
        fixture.continuation.addListener(() {
          final accepted = fixture.continuation.acceptedRunFor('user-1');
          if (accepted != null) observed.add(accepted.lifecycle);
        });

        await _settle(fixture.coordinator);
        await _waitForReportReady(fixture, agentRunId: _productionLengthRunId);

        expect(
          fixture.coordinator.state.isReportReadyFor(_productionLengthRunId),
          isTrue,
        );
        expect(observed, contains(OnboardingAcceptedRunLifecycle.finalizing));
        expect(
          taskStates.where(
            (state) => state.status == InitialPositioningTaskStatus.finalizing,
          ),
          isNotEmpty,
        );
        expect(
          taskStates
              .where(
                (state) =>
                    state.status == InitialPositioningTaskStatus.finalizing,
              )
              .map((state) => state.errorCode),
          everyElement(isNull),
        );
        final accepted = fixture.continuation.acceptedRunFor('user-1')!;
        expect(accepted.agentRunId, _productionLengthRunId);
        expect(accepted.lifecycle, OnboardingAcceptedRunLifecycle.succeeded);
        expect(accepted.failureCode, isNull);
        expect(accepted.needsFinalizationReconciliation, isFalse);
        expect(
          fixture.continuation.snapshotFor('user-1').answers,
          savedAnswers,
        );
        expect(fixture.continuation.acceptedRunFor('another-user'), isNull);
        expect(fixture.api.formalRequests, hasLength(alreadyCompleted ? 0 : 1));
        if (!alreadyCompleted) {
          expect(
            fixture.api.formalRequests.single.agentRunId,
            _productionLengthRunId,
          );
        }
        expect(fixture.agent.startCalls, 0);
        expect(fixture.agent.submitCalls, 0);
        expect(fixture.session.state.requiresInitialPositioning, isFalse);
      },
    );
  }

  test(
    'persists and finalizes a Run at the shared identifier boundary',
    () async {
      final agentRunId = 'agent_run_${List<String>.filled(240, 'a').join()}';
      final fixture = await _fixture(agentRunId: agentRunId);
      addTearDown(fixture.dispose);

      expect(
        fixture.continuation.acceptedRunFor('user-1')?.agentRunId,
        agentRunId,
      );
      await _settle(fixture.coordinator);
      await _waitForReportReady(fixture, agentRunId: agentRunId);

      expect(fixture.coordinator.state.isReportReadyFor(agentRunId), isTrue);
      expect(fixture.api.formalRequests.single.agentRunId, agentRunId);
    },
  );

  for (final runStatus in <String>['running', 'failed']) {
    test(
      'does not finalize a recovered receipt while its Run is $runStatus',
      () async {
        final fixture = await _fixture(
          agentRunId: _productionLengthRunId,
          runStatus: runStatus,
        );
        addTearDown(fixture.dispose);
        fixture.continuation.markRunFailed(
          'user-1',
          'INITIAL_POSITIONING_INVALID',
        );

        await fixture.coordinator.start();
        for (var refresh = 0; refresh < 8; refresh += 1) {
          await Future<void>.delayed(Duration.zero);
          await fixture.coordinator.refresh();
        }

        expect(
          fixture.coordinator.state.status,
          InitialPositioningTaskStatus.failed,
        );
        expect(
          fixture.continuation.acceptedRunFor('user-1')?.failureCode,
          runStatus == 'failed'
              ? 'WORKSPACE_VERSION_CONFLICT'
              : 'INITIAL_POSITIONING_INVALID',
        );
        expect(fixture.api.formalRequests, isEmpty);
        expect(fixture.sink.markdown, isNull);
        expect(fixture.agent.startCalls, 0);
        expect(fixture.agent.submitCalls, 0);
        expect(fixture.session.state.requiresInitialPositioning, isTrue);
      },
    );
  }

  test('does not revive unrelated terminal failures', () async {
    final fixture = await _fixture();
    addTearDown(fixture.dispose);
    fixture.continuation.markRunFailed(
      'user-1',
      'INITIAL_POSITIONING_RUN_INVALID',
    );

    await _settle(fixture.coordinator);

    expect(
      fixture.coordinator.state.status,
      InitialPositioningTaskStatus.failed,
    );
    expect(
      fixture.coordinator.state.errorCode,
      'INITIAL_POSITIONING_RUN_INVALID',
    );
    expect(fixture.api.formalRequests, isEmpty);
    expect(fixture.agent.completeCalls, 0);
  });

  for (final invalidWorkspace in <bool>[false, true]) {
    test(
      'gates admission recovery for invalid Workspace $invalidWorkspace',
      () async {
        final fixture = await _fixture();
        addTearDown(fixture.dispose);
        fixture.continuation.markRunFailed(
          'user-1',
          'INITIAL_POSITIONING_INVALID',
        );
        if (invalidWorkspace) {
          fixture.session.refreshUserStatus(
            status: const SessionUserStatus(
              user: SessionUser(
                userId: 'user-1',
                maskedPhoneNumber: '138****8000',
              ),
              workspace: SessionWorkspace(
                status: SessionWorkspaceStatus.ready,
                workspaceId: '_workspace_invalid',
              ),
              onboardingRequired: true,
            ),
            updatedAt: DateTime.utc(2026, 9, 8),
          );
          expect(
            fixture.session.state.workspace?.workspaceId,
            '_workspace_invalid',
          );
        } else {
          fixture.session.requireWorkspaceRecovery(
            updatedAt: DateTime.utc(2026, 9, 8),
          );
        }

        await _settle(fixture.coordinator);

        expect(
          fixture.coordinator.state.status,
          InitialPositioningTaskStatus.failed,
        );
        expect(fixture.api.formalRequests, isEmpty);

        fixture.restoreWorkspaceReady();
        await _waitForReportReady(fixture);
        expect(
          fixture.coordinator.state.isReportReadyFor('agent_run_positioning_1'),
          isTrue,
        );
      },
    );
  }

  for (final runStatus in <String>['succeeded', 'failed']) {
    test(
      'provider keeps its active coordinator through $runStatus notifications',
      () async {
        final fixture = await _fixture(runStatus: runStatus);
        fixture.coordinator.dispose();
        final container = ProviderContainer(
          overrides: [
            positioningLifecycleCoordinatorProvider.overrideWith((ref) => null),
            assistantRuntimeProvider.overrideWithValue(
              legacyAssistantRuntime(_SucceededRunPort(status: 'succeeded')),
            ),
            sessionStoreProvider.overrideWith((ref) => fixture.session),
            onboardingApiProvider.overrideWithValue(fixture.api),
            initialPositioningAgentProvider.overrideWithValue(fixture.agent),
            initialPositioningReportSinkProvider.overrideWithValue(
              fixture.sink,
            ),
            onboardingContinuationControllerProvider.overrideWith(
              (ref) => fixture.continuation,
            ),
            chatRunTrackerProvider.overrideWith((ref) => fixture.tracker),
          ],
        );
        addTearDown(container.dispose);
        final coordinator = container.read(
          initialPositioningTaskCoordinatorProvider,
        );
        final observed = <InitialPositioningTaskStatus>[];
        container.listen(initialPositioningTaskStateProvider, (previous, next) {
          observed.add(next.status);
        }, fireImmediately: true);

        await _settle(coordinator);

        expect(
          container.read(initialPositioningTaskCoordinatorProvider),
          same(coordinator),
        );
        final expectedStatus = runStatus == 'failed'
            ? InitialPositioningTaskStatus.failed
            : InitialPositioningTaskStatus.succeeded;
        expect(
          container.read(initialPositioningTaskStateProvider).status,
          expectedStatus,
        );
        expect(observed, contains(expectedStatus));
        expect(
          fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
          runStatus == 'failed'
              ? OnboardingAcceptedRunLifecycle.failed
              : OnboardingAcceptedRunLifecycle.succeeded,
        );
        if (runStatus == 'failed') {
          expect(coordinator.state.errorCode, 'WORKSPACE_VERSION_CONFLICT');
          expect(fixture.api.formalRequests, hasLength(1));
          await coordinator.refresh();
          expect(coordinator.state.status, InitialPositioningTaskStatus.failed);
          expect(fixture.api.formalRequests, hasLength(1));
        }
      },
    );
  }

  test('releases onboarding only after the formal attempt completes', () async {
    final fixture = await _fixture();
    addTearDown(fixture.dispose);

    await _settle(fixture.coordinator);

    expect(
      fixture.coordinator.state.status,
      InitialPositioningTaskStatus.succeeded,
    );
    expect(fixture.api.formalRequests, hasLength(1));
    expect(fixture.api.formalRequests.single, (
      workspaceId: 'workspace-1',
      agentRunId: 'agent_run_positioning_1',
    ));
    expect(fixture.api.requests, isEmpty);
    expect(fixture.api.defaultLineReads, 0);
    expect(fixture.session.state.requiresInitialPositioning, isFalse);
    expect(fixture.session.state.defaultContentLine, isNull);
    expect(
      fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
      OnboardingAcceptedRunLifecycle.succeeded,
    );
    expect(
      fixture.coordinator.state.reportReadyAgentRunId,
      'agent_run_positioning_1',
    );
    expect(
      fixture.coordinator.acknowledgeReportShown(agentRunId: 'another-run'),
      isFalse,
    );

    expect(
      fixture.coordinator.acknowledgeReportShown(
        agentRunId: 'agent_run_positioning_1',
      ),
      isTrue,
    );
    expect(fixture.continuation.acceptedRunFor('user-1'), isNull);
  });

  test('does not let a historical attempt decide the accepted Run', () async {
    final fixture = await _fixture(
      currentAttempts: const <InitialPositioningAttempt>[
        InitialPositioningAttempt(
          workspaceId: 'workspace-1',
          state: 'failed_terminal',
          attemptId: 'positioning_attempt_old',
          agentRunId: 'agent_run_positioning_old',
          failureCode: 'POSITIONING_FILE_PENDING',
        ),
        InitialPositioningAttempt(
          workspaceId: 'workspace-1',
          state: 'completed',
          attemptId: 'positioning_attempt_1',
          agentRunId: 'agent_run_positioning_1',
        ),
      ],
      reportReadbackRetryInterval: Duration.zero,
    );
    addTearDown(fixture.dispose);

    await _settle(fixture.coordinator);

    expect(
      fixture.coordinator.state.status,
      InitialPositioningTaskStatus.succeeded,
    );
    expect(fixture.api.formalRequests, hasLength(1));
    expect(
      fixture.api.formalRequests.single.agentRunId,
      'agent_run_positioning_1',
    );
  });

  for (final failure in <AppFailure>[
    const AppFailure(
      code: 'INITIAL_POSITIONING_ATTEMPT_ACTIVE',
      category: AppFailureCategory.api,
      message: 'Another attempt is active',
      userMessageKey: 'onboarding.attemptActive',
    ),
    const AppFailure(
      code: 'NETWORK_UNAVAILABLE',
      category: AppFailureCategory.network,
      message: 'Network unavailable',
      userMessageKey: 'network.unavailable',
      isRetryable: true,
    ),
  ]) {
    test(
      'recovers cloud completion after ${failure.code} without duplicate creation',
      () async {
        final fixture = await _fixture(
          currentAttempts: const <InitialPositioningAttempt>[
            InitialPositioningAttempt(
              workspaceId: 'workspace-1',
              state: 'running',
              attemptId: 'positioning_attempt_old',
              agentRunId: 'agent_run_positioning_old',
            ),
            InitialPositioningAttempt(
              workspaceId: 'workspace-1',
              state: 'not_started',
            ),
            InitialPositioningAttempt(
              workspaceId: 'workspace-1',
              state: 'completed',
              attemptId: 'positioning_attempt_1',
              agentRunId: 'agent_run_positioning_1',
            ),
          ],
          createFailures: <AppFailure?>[failure, null],
          reportReadbackRetryInterval: Duration.zero,
        );
        addTearDown(fixture.dispose);

        await _settle(fixture.coordinator);

        expect(
          fixture.coordinator.state.status,
          InitialPositioningTaskStatus.succeeded,
        );
        expect(fixture.api.formalRequests, hasLength(1));
        expect(
          fixture.api.formalRequests.map((request) => request.agentRunId),
          everyElement('agent_run_positioning_1'),
        );
      },
    );
  }

  test(
    'keeps the gate and questionnaire when formal finalization fails',
    () async {
      final fixture = await _fixture(
        createdAttempt: const InitialPositioningAttempt(
          workspaceId: 'workspace-1',
          state: 'failed_terminal',
          attemptId: 'positioning_attempt_1',
          agentRunId: 'agent_run_positioning_1',
          failureCode: 'POSITIONING_FILE_PENDING',
        ),
      );
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.failed,
      );
      expect(fixture.coordinator.state.errorCode, 'POSITIONING_FILE_PENDING');
      expect(fixture.api.requests, isEmpty);
      expect(fixture.api.formalRequests, hasLength(1));
      expect(fixture.session.state.requiresInitialPositioning, isTrue);
      expect(
        fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
        OnboardingAcceptedRunLifecycle.failed,
      );
      expect(
        fixture.continuation
            .snapshotFor('user-1')
            .answers['productDescription'],
        '持续表达的业务',
      );
    },
  );

  test(
    'waits for the server worker instead of treating a local report as complete',
    () async {
      final fixture = await _fixture(
        currentAttempts: const <InitialPositioningAttempt>[
          InitialPositioningAttempt(
            workspaceId: 'workspace-1',
            state: 'not_started',
          ),
          InitialPositioningAttempt(
            workspaceId: 'workspace-1',
            state: 'finalizing',
            attemptId: 'positioning_attempt_1',
            agentRunId: 'agent_run_positioning_1',
          ),
        ],
        createdAttempt: const InitialPositioningAttempt(
          workspaceId: 'workspace-1',
          state: 'running',
          attemptId: 'positioning_attempt_1',
          agentRunId: 'agent_run_positioning_1',
        ),
      );
      addTearDown(fixture.dispose);

      await fixture.coordinator.start();
      await Future<void>.delayed(Duration.zero);
      await fixture.coordinator.refresh();

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.finalizing,
      );
      expect(fixture.api.formalRequests, hasLength(1));
      expect(fixture.api.requests, isEmpty);
      expect(fixture.api.defaultLineReads, 0);
      expect(fixture.session.state.requiresInitialPositioning, isTrue);
    },
  );

  test(
    'keeps an accepted Run until an early-completed Session saves its report',
    () async {
      final fixture = await _fixture(completedSession: true);
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(fixture.sink.saveCalls, 1);
      expect(
        fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
        OnboardingAcceptedRunLifecycle.succeeded,
      );
      expect(
        fixture.coordinator.acknowledgeReportShown(
          agentRunId: 'agent_run_positioning_1',
        ),
        isTrue,
      );
      expect(fixture.continuation.acceptedRunFor('user-1'), isNull);
    },
  );

  test(
    'a restored succeeded receipt retries report readback until Run-ready',
    () async {
      final fixture = await _fixture(
        acceptedSucceeded: true,
        savedProfileReads: <InitialPositioningProfileRead>[
          InitialPositioningProfileRead.failure(
            'ONBOARDING_AGENT_REPORT_UNAVAILABLE',
          ),
          _savedProfileSuccess(),
        ],
        reportReadbackRetryInterval: Duration.zero,
      );
      addTearDown(fixture.dispose);

      await fixture.coordinator.start();
      expect(
        fixture.coordinator.state.isReportReadyFor('agent_run_positioning_1'),
        isFalse,
      );
      await _waitForReportReady(fixture);

      expect(fixture.agent.profileReadCalls, 2);
      expect(
        fixture.coordinator.state.isReportReadyFor('agent_run_positioning_1'),
        isTrue,
      );
      expect(
        fixture.coordinator.acknowledgeReportShown(
          agentRunId: 'agent_run_positioning_1',
        ),
        isTrue,
      );
    },
  );

  test('retries report persistence without failing the accepted Run', () async {
    final fixture = await _fixture(
      reportSaveResults: <bool>[false, true],
      reportReadbackRetryInterval: Duration.zero,
    );
    addTearDown(fixture.dispose);

    await _settle(fixture.coordinator);

    expect(
      fixture.coordinator.state.status,
      InitialPositioningTaskStatus.succeeded,
    );
    expect(fixture.sink.saveCalls, 2);
    expect(
      fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
      OnboardingAcceptedRunLifecycle.succeeded,
    );
  });

  test(
    'keeps finalizing while Session completion is temporarily blocked',
    () async {
      final fixture = await _fixture(interruptSessionBeforeCompletion: true);
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.finalizing,
      );
      expect(
        fixture.continuation.acceptedRunFor('user-1')?.lifecycle,
        OnboardingAcceptedRunLifecycle.finalizing,
      );
      expect(fixture.sink.saveCalls, 0);

      fixture.restoreWorkspaceReady();
      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(fixture.sink.saveCalls, 1);
    },
  );

  test('retries a failed succeeded-receipt persistence checkpoint', () async {
    final fixture = await _fixture(failReceiptPersistenceOnce: true);
    addTearDown(fixture.dispose);

    await _settle(fixture.coordinator);

    expect(
      fixture.coordinator.state.status,
      InitialPositioningTaskStatus.finalizing,
    );
    expect(fixture.session.state.requiresInitialPositioning, isFalse);

    fixture.snapshotStore!.failWrites = false;
    await _settle(fixture.coordinator);

    expect(
      fixture.coordinator.state.status,
      InitialPositioningTaskStatus.succeeded,
    );
    expect(
      fixture.coordinator.state.isReportReadyFor('agent_run_positioning_1'),
      isTrue,
    );
  });

  test(
    'cached report does not release an implicit server positioning gate',
    () async {
      final fixture = await _recoveryFixture();
      addTearDown(fixture.dispose);

      expect(fixture.session.state.requiresInitialPositioning, isTrue);
      expect(fixture.continuation.isDeferredFor('user-1'), isTrue);

      await fixture.coordinator.start();

      expect(fixture.session.state.requiresInitialPositioning, isTrue);
      expect(fixture.continuation.isDeferredFor('user-1'), isTrue);
      expect(fixture.api.formalRequests, isEmpty);
      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.idle,
      );
    },
  );

  test(
    'cached report does not override explicit server onboarding requirement',
    () async {
      final fixture = await _recoveryFixture(serverRequiresOnboarding: true);
      addTearDown(fixture.dispose);

      await fixture.coordinator.start();

      expect(fixture.session.state.requiresInitialPositioning, isTrue);
      expect(fixture.continuation.isDeferredFor('user-1'), isTrue);
      expect(fixture.api.formalRequests, isEmpty);
      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.idle,
      );
    },
  );

  test(
    'reads formal report despite transient historical Run read failures',
    () async {
      final fixture = await _fixture(
        reportResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.failure(
            'ONBOARDING_AGENT_RUN_POLL_FAILED',
          ),
          _reportSuccess(),
        ],
        reportReadbackRetryInterval: Duration.zero,
      );
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);
      await _waitForReport(fixture);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(fixture.agent.completeCalls, 0);
      expect(fixture.api.formalRequests, hasLength(1));
      expect(fixture.sink.markdown, contains('已写入的定位报告'));
    },
  );

  test(
    'formal report is independent of expired historical message readback',
    () async {
      final fixture = await _fixture(
        reportResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.failure(
            'ONBOARDING_AGENT_RUN_IN_PROGRESS',
          ),
          InitialPositioningAgentSubmission.failure(
            'ONBOARDING_AGENT_REPORT_UNAVAILABLE',
          ),
          _reportSuccess(),
        ],
        reportReadbackRetryInterval: Duration.zero,
      );
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);
      await _waitForReport(fixture);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(fixture.agent.completeCalls, 0);
      expect(fixture.sink.saveCalls, 1);
      expect(fixture.api.formalRequests, hasLength(1));
    },
  );

  test(
    'completed formal attempt is not failed by a historical Run error',
    () async {
      final fixture = await _fixture(
        reportResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.failure(
            'ONBOARDING_AGENT_RUN_FAILED',
          ),
        ],
        reportReadbackRetryInterval: Duration.zero,
      );
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(fixture.coordinator.state.errorCode, isNull);
      expect(fixture.sink.markdown, isNotNull);
      expect(fixture.session.state.requiresInitialPositioning, isFalse);
    },
  );

  for (final code in const <String>[
    'ONBOARDING_AGENT_RUN_DEGRADED',
    'ONBOARDING_AGENT_RUN_SYSTEM_FALLBACK',
  ]) {
    test('converges terminal completed mode $code', () async {
      final fixture = await _fixture(
        reportResults: <InitialPositioningAgentSubmission>[
          InitialPositioningAgentSubmission.failure(code),
        ],
        reportReadbackRetryInterval: Duration.zero,
      );
      addTearDown(fixture.dispose);

      await _settle(fixture.coordinator);

      expect(
        fixture.coordinator.state.status,
        InitialPositioningTaskStatus.succeeded,
      );
      expect(fixture.coordinator.state.errorCode, isNull);
      expect(fixture.agent.completeCalls, 0);
    });
  }
}

Future<void> _settle(InitialPositioningTaskCoordinator coordinator) async {
  await coordinator.start();
  for (var attempt = 0; attempt < 8; attempt += 1) {
    await Future<void>.delayed(Duration.zero);
    await coordinator.refresh();
    if (coordinator.state.isTerminal) return;
  }
}

Future<void> _waitForReport(_Fixture fixture) async {
  for (
    var attempt = 0;
    attempt < 20 && fixture.sink.markdown == null;
    attempt += 1
  ) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitForReportReady(
  _Fixture fixture, {
  String agentRunId = 'agent_run_positioning_1',
}) async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    await Future<void>.delayed(Duration.zero);
    await fixture.coordinator.refresh();
    if (fixture.coordinator.state.isReportReadyFor(agentRunId)) {
      return;
    }
  }
}

InitialPositioningAgentSubmission _reportSuccess({
  String agentRunId = 'agent_run_positioning_1',
}) {
  final receipt = InitialPositioningRunReceipt(
    threadId: 'thread_positioning_1',
    agentRunId: agentRunId,
    taskId: 'task_positioning_1',
    messageId: 'message_positioning_1',
    status: 'accepted',
  );
  return InitialPositioningAgentSubmission.success(
    InitialPositioningAgentResult(
      threadId: receipt.threadId,
      report: '## 初步定位判断\n适合持续表达。',
      receipt: receipt,
    ),
  );
}

InitialPositioningAttempt _committedRuntimeGapAttempt({
  required DateTime reportUpdatedAt,
}) => InitialPositioningAttempt(
  workspaceId: 'workspace-1',
  state: 'failed_terminal',
  attemptId: 'positioning_attempt_agent_run_positioning_1',
  agentRunId: 'agent_run_positioning_1',
  failureCode: 'AGENT_RUN_TERMINAL',
  reportEvidence: InitialPositioningReportEvidence(
    lastUpdated: reportUpdatedAt,
  ),
  createdAt: DateTime.utc(2026, 8, 16, 9),
  updatedAt: DateTime.utc(2026, 8, 16, 9, 1),
  finalizedAt: DateTime.utc(2026, 8, 16, 9, 1),
);

InitialPositioningProfileRead _savedProfileSuccess() =>
    InitialPositioningProfileRead.success(
      const InitialPositioningProfile(
        workspaceId: 'workspace-1',
        overview: '',
        selfDescription: '',
        positioning: '## 已写入的定位报告\n适合持续表达。',
        conclusions: <InitialPositioningProfileConclusion>[],
      ),
    );

Future<_Fixture> _fixture({
  String runStatus = 'succeeded',
  String agentRunId = 'agent_run_positioning_1',
  List<InitialPositioningAttempt>? currentAttempts,
  InitialPositioningAttempt? createdAttempt,
  bool completedSession = false,
  bool acceptedSucceeded = false,
  OnboardingAcceptedRunReportSource acceptedReportSource =
      OnboardingAcceptedRunReportSource.agentReply,
  String? acceptedFailureCode,
  String? registeredAttemptId,
  InitialPositioningProfileRead? savedProfileRead,
  List<InitialPositioningProfileRead>? savedProfileReads,
  List<InitialPositioningAgentSubmission>? reportResults,
  List<bool>? reportSaveResults,
  List<AppFailure?>? createFailures,
  bool interruptSessionBeforeCompletion = false,
  bool failReceiptPersistenceOnce = false,
  Duration reportReadbackRetryInterval = const Duration(seconds: 3),
}) async {
  assert(!acceptedSucceeded || acceptedFailureCode == null);
  final snapshotStore = failReceiptPersistenceOnce
      ? _ToggleFailingSnapshotStore()
      : null;
  final database = AppDatabase(snapshotStore: snapshotStore);
  final session = SessionStore(
    secureTokenStore: SecureTokenStore(driver: _TokenDriver()),
  );
  await session.applyLoginSuccess(
    tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    snapshot: SafeAuthSessionSnapshot(
      user: const SessionUser(
        userId: 'user-1',
        maskedPhoneNumber: '138****8000',
      ),
      expiresAt: DateTime.utc(2027, 1, 1),
      workspaceStatus: SessionWorkspaceStatus.ready,
      onboardingRequired: true,
      basicPositioningCompleted: completedSession ? true : null,
      positioningStatus: completedSession
          ? SessionPositioningStatus.completed
          : null,
    ),
    verifiedStatus: SessionUserStatus(
      user: const SessionUser(
        userId: 'user-1',
        maskedPhoneNumber: '138****8000',
      ),
      workspace: const SessionWorkspace(
        status: SessionWorkspaceStatus.ready,
        workspaceId: 'workspace-1',
      ),
      onboardingRequired: true,
      basicPositioningCompleted: completedSession ? true : null,
      positioningStatus: completedSession
          ? SessionPositioningStatus.completed
          : null,
    ),
    updatedAt: DateTime.utc(2026, 8, 16, 9),
  );
  final continuation = OnboardingContinuationController(
    repository: OnboardingProgressRepository(dao: AppPreferencesDao(database)),
    now: () => DateTime.utc(2026, 8, 16, 9),
  );
  final receipt = InitialPositioningRunReceipt(
    threadId: 'thread_positioning_1',
    agentRunId: agentRunId,
    taskId: 'task_positioning_1',
    messageId: 'message_positioning_1',
    status: 'accepted',
  );
  expect(
    continuation.saveDraft(
      'user-1',
      const OnboardingProgressSnapshot(
        mode: onboardingBusinessMode,
        stepIndex: 3,
        answers: <String, Object>{
          'customerScope': '全国客户',
          'productDescription': '持续表达的业务',
          'desiredCustomer': '成长中的创作者',
          'customerTalkValue': <String>['行业信息差'],
        },
      ),
    ),
    isTrue,
  );
  expect(continuation.acceptRun('user-1', receipt), isTrue);
  if (registeredAttemptId != null) {
    expect(
      continuation.recordRunRegistration(
        'user-1',
        agentRunId: agentRunId,
        workspaceId: 'workspace-1',
        attemptId: registeredAttemptId,
      ),
      isTrue,
    );
  }
  if (acceptedSucceeded) {
    expect(
      continuation.markRunSucceeded(
        'user-1',
        reportSource: acceptedReportSource,
      ),
      isTrue,
    );
  }
  if (acceptedFailureCode != null) {
    expect(continuation.markRunFailed('user-1', acceptedFailureCode), isTrue);
  }

  final tracker = ChatRunTracker(
    assistantRuntime: legacyAssistantRuntime(
      _SucceededRunPort(status: runStatus),
    ),
    preferences: AppPreferencesDao(database),
    userScope: 'user-1',
    pollInterval: const Duration(milliseconds: 1),
  );
  await tracker.start();
  final api = _OnboardingApi(
    agentRunId: agentRunId,
    currentAttempts: currentAttempts,
    createdAttempt: createdAttempt,
    createFailures: createFailures,
  );
  if (interruptSessionBeforeCompletion) {
    var interrupted = false;
    api.onCurrentAttempt = (attempt) {
      if (attempt.isCompleted && !interrupted) {
        interrupted = true;
        session.requireWorkspaceRecovery(
          updatedAt: DateTime.utc(2026, 8, 16, 9, 1),
        );
      }
    };
  }
  final sink = _ReportSink(
    saveResults: reportSaveResults,
    afterSuccessfulSave: failReceiptPersistenceOnce
        ? () => snapshotStore!.failWrites = true
        : null,
  );
  final agent = _AcceptedAgent.sequence(
    reportResults ??
        <InitialPositioningAgentSubmission>[
          _reportSuccess(agentRunId: agentRunId),
        ],
    savedProfileRead: savedProfileRead,
    savedProfileReads: savedProfileReads,
  );
  final coordinator = InitialPositioningTaskCoordinator(
    onboardingApi: api,
    positioningAgent: agent,
    sessionStore: session,
    reportSink: sink,
    continuation: continuation,
    taskTracker: tracker,
    now: () => DateTime.utc(2026, 8, 16, 9, 1),
    reportReadbackRetryInterval: reportReadbackRetryInterval,
  );
  return _Fixture(
    api: api,
    agent: agent,
    continuation: continuation,
    coordinator: coordinator,
    session: session,
    sink: sink,
    snapshotStore: snapshotStore,
    tracker: tracker,
  );
}

Future<_Fixture> _recoveryFixture({
  bool serverRequiresOnboarding = false,
}) async {
  final database = AppDatabase();
  final session = SessionStore(
    secureTokenStore: SecureTokenStore(driver: _TokenDriver()),
  );
  await session.applyLoginSuccess(
    tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
    snapshot: SafeAuthSessionSnapshot(
      user: const SessionUser(
        userId: 'user-1',
        maskedPhoneNumber: '138****8000',
      ),
      expiresAt: DateTime.utc(2027, 1, 1),
      workspaceStatus: SessionWorkspaceStatus.ready,
      onboardingRequired: serverRequiresOnboarding,
    ),
    verifiedStatus: SessionUserStatus(
      user: const SessionUser(
        userId: 'user-1',
        maskedPhoneNumber: '138****8000',
      ),
      workspace: const SessionWorkspace(
        status: SessionWorkspaceStatus.ready,
        workspaceId: 'workspace-1',
      ),
      onboardingRequired: serverRequiresOnboarding ? true : null,
      basicPositioningCompleted: false,
      positioningStatus: SessionPositioningStatus.inProgress,
    ),
    updatedAt: DateTime.utc(2026, 8, 16, 9),
  );
  final continuation = OnboardingContinuationController(
    repository: OnboardingProgressRepository(dao: AppPreferencesDao(database)),
    now: () => DateTime.utc(2026, 8, 16, 9),
  );
  expect(
    continuation.defer(
      'user-1',
      const OnboardingProgressSnapshot(
        mode: onboardingBusinessMode,
        stepIndex: 1,
        answers: <String, Object>{'customerScope': '全国客户'},
      ),
    ),
    isTrue,
  );
  final tracker = ChatRunTracker(
    assistantRuntime: legacyAssistantRuntime(const _SucceededRunPort()),
    preferences: AppPreferencesDao(database),
    userScope: 'user-1',
  );
  final api = _OnboardingApi();
  final sink = _ReportSink();
  final agent = _AcceptedAgent(
    InitialPositioningAgentSubmission.failure('NOT_USED'),
  );
  final coordinator = InitialPositioningTaskCoordinator(
    onboardingApi: api,
    positioningAgent: agent,
    sessionStore: session,
    reportSink: sink,
    continuation: continuation,
    taskTracker: tracker,
  );
  return _Fixture(
    api: api,
    agent: agent,
    continuation: continuation,
    coordinator: coordinator,
    session: session,
    sink: sink,
    tracker: tracker,
  );
}

final class _Fixture {
  const _Fixture({
    required this.api,
    required this.agent,
    required this.continuation,
    required this.coordinator,
    required this.session,
    required this.sink,
    this.snapshotStore,
    required this.tracker,
  });

  final _OnboardingApi api;
  final _AcceptedAgent agent;
  final OnboardingContinuationController continuation;
  final InitialPositioningTaskCoordinator coordinator;
  final SessionStore session;
  final _ReportSink sink;
  final _ToggleFailingSnapshotStore? snapshotStore;
  final ChatRunTracker tracker;

  void restoreWorkspaceReady() {
    session.refreshUserStatus(
      status: const SessionUserStatus(
        user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
        workspace: SessionWorkspace(
          status: SessionWorkspaceStatus.ready,
          workspaceId: 'workspace-1',
        ),
        onboardingRequired: true,
        basicPositioningCompleted: false,
        positioningStatus: SessionPositioningStatus.inProgress,
      ),
      updatedAt: DateTime.utc(2026, 8, 16, 9, 2),
    );
  }

  void dispose() {
    coordinator.dispose();
    continuation.dispose();
    tracker.dispose();
  }
}

final class _OnboardingApi
    implements
        OnboardingApiPort,
        OnboardingDefaultContentLineReadPort,
        OnboardingInitialPositioningPort {
  _OnboardingApi({
    String agentRunId = 'agent_run_positioning_1',
    List<InitialPositioningAttempt>? currentAttempts,
    InitialPositioningAttempt? createdAttempt,
    List<AppFailure?>? createFailures,
    List<AppFailure?>? currentFailures,
  }) : _currentAttempts = List<InitialPositioningAttempt>.of(
         currentAttempts ??
             <InitialPositioningAttempt>[
               const InitialPositioningAttempt(
                 workspaceId: 'workspace-1',
                 state: 'not_started',
               ),
               InitialPositioningAttempt(
                 workspaceId: 'workspace-1',
                 state: 'completed',
                 attemptId: 'positioning_attempt_$agentRunId',
                 agentRunId: agentRunId,
               ),
             ],
       ),
       _createdAttempt =
           createdAttempt ??
           InitialPositioningAttempt(
             workspaceId: 'workspace-1',
             state: 'running',
             attemptId: 'positioning_attempt_$agentRunId',
             agentRunId: agentRunId,
           ),
       _createFailures = List<AppFailure?>.of(createFailures ?? const []),
       _currentFailures = List<AppFailure?>.of(currentFailures ?? const []);

  final List<CreateFirstContentLineRequest> requests =
      <CreateFirstContentLineRequest>[];
  final List<({String workspaceId, String agentRunId})> formalRequests =
      <({String workspaceId, String agentRunId})>[];
  final List<InitialPositioningAttempt> _currentAttempts;
  final InitialPositioningAttempt _createdAttempt;
  final List<AppFailure?> _createFailures;
  final List<AppFailure?> _currentFailures;
  int defaultLineReads = 0;
  InitialPositioningAttempt? _latestAttempt;
  void Function(InitialPositioningAttempt attempt)? onCurrentAttempt;
  Completer<void>? createGate;

  @override
  Future<ApiResult<CreateFirstContentLineResult>> createFirstContentLine({
    required CreateFirstContentLineRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    requests.add(request);
    return ApiResult<CreateFirstContentLineResult>.failure(
      error: const AppFailure(
        code: 'UNEXPECTED_LEGACY_ONBOARDING_WRITE',
        category: AppFailureCategory.api,
        message: 'The formal flow must not use the legacy write',
        userMessageKey: 'onboarding.legacyWrite',
      ),
      idempotencyStore: idempotencyStore,
    );
  }

  @override
  Future<ApiResult<InitialPositioningAttempt>> createInitialPositioningAttempt({
    required String workspaceId,
    required String agentRunId,
  }) async {
    formalRequests.add((workspaceId: workspaceId, agentRunId: agentRunId));
    await createGate?.future;
    if (_createFailures.isNotEmpty) {
      final failure = _createFailures.removeAt(0);
      if (failure != null) {
        return ApiResult<InitialPositioningAttempt>.failure(
          error: failure,
          idempotencyStore: SubmissionKeyStore.empty,
        );
      }
    }
    _latestAttempt = _createdAttempt;
    return ApiResult<InitialPositioningAttempt>.success(
      data: _createdAttempt,
      status: 202,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<InitialPositioningAttempt>> currentInitialPositioning({
    required String workspaceId,
  }) async {
    if (_currentFailures.isNotEmpty) {
      final failure = _currentFailures.removeAt(0);
      if (failure != null) {
        return ApiResult<InitialPositioningAttempt>.failure(
          error: failure,
          idempotencyStore: SubmissionKeyStore.empty,
        );
      }
    }
    final value = _currentAttempts.isNotEmpty
        ? _currentAttempts.removeAt(0)
        : _latestAttempt ?? _createdAttempt;
    _latestAttempt = value;
    onCurrentAttempt?.call(value);
    return ApiResult<InitialPositioningAttempt>.success(
      data: value,
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<OnboardingDefaultContentLineRead>>
  readDefaultContentLine() async {
    defaultLineReads += 1;
    return ApiResult<OnboardingDefaultContentLineRead>.success(
      data: const OnboardingDefaultContentLineRead(
        contentLine: OnboardingContentLine(
          contentLineId: 'legacy-content-line-1',
          name: '不应读取的旧内容线',
          industry: 'legacy',
          status: 'active',
          version: 1,
          isDefault: true,
          isPlaceholder: false,
        ),
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _AcceptedAgent
    implements
        InitialPositioningAgentPort,
        InitialPositioningAgentAcceptedRunPort {
  _AcceptedAgent(this.result, {InitialPositioningProfileRead? savedProfileRead})
    : _results = null,
      _savedProfileReads = null,
      _savedProfileRead = savedProfileRead ?? _savedProfileSuccess();

  _AcceptedAgent.sequence(
    List<InitialPositioningAgentSubmission> results, {
    InitialPositioningProfileRead? savedProfileRead,
    List<InitialPositioningProfileRead>? savedProfileReads,
  }) : _savedProfileReads = savedProfileReads,
       assert(results.isNotEmpty),
       result = results.last,
       _results = List<InitialPositioningAgentSubmission>.of(results),
       _savedProfileRead = savedProfileRead ?? _savedProfileSuccess();

  final InitialPositioningAgentSubmission result;
  final List<InitialPositioningAgentSubmission>? _results;
  final InitialPositioningProfileRead _savedProfileRead;
  final List<InitialPositioningProfileRead>? _savedProfileReads;
  int completeCalls = 0;
  int profileReadCalls = 0;
  int startCalls = 0;
  int submitCalls = 0;

  @override
  Future<InitialPositioningAgentSubmission> completeAccepted(
    InitialPositioningRunReceipt receipt,
  ) async {
    final index = completeCalls;
    completeCalls += 1;
    final results = _results;
    if (results == null || index >= results.length) return result;
    return results[index];
  }

  @override
  Future<InitialPositioningProfileRead> readSavedProfile() async {
    final index = profileReadCalls++;
    final reads = _savedProfileReads;
    return reads == null
        ? _savedProfileRead
        : reads[index.clamp(0, reads.length - 1)];
  }

  @override
  Future<InitialPositioningAgentAcceptance> start(String prompt) async {
    startCalls += 1;
    return InitialPositioningAgentAcceptance.failure('NOT_USED');
  }

  @override
  Future<InitialPositioningAgentSubmission> submit(String prompt) async {
    submitCalls += 1;
    return InitialPositioningAgentSubmission.failure('NOT_USED');
  }
}

final class _ReportSink implements InitialPositioningReportSink {
  _ReportSink({List<bool>? saveResults, this.afterSuccessfulSave})
    : _saveResults = List<bool>.of(saveResults ?? const <bool>[true]);

  final List<bool> _saveResults;
  final void Function()? afterSuccessfulSave;
  String? markdown;
  int saveCalls = 0;

  @override
  Future<bool> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) async {
    saveCalls += 1;
    final saved = _saveResults.isEmpty ? true : _saveResults.removeAt(0);
    if (!saved) return false;
    this.markdown = markdown;
    afterSuccessfulSave?.call();
    return true;
  }
}

final class _ToggleFailingSnapshotStore extends LocalDatabaseSnapshotStore {
  _ToggleFailingSnapshotStore() : super(file: File('unused-positioning.json'));

  bool failWrites = false;

  @override
  LocalDatabaseSnapshot? load() => null;

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    if (failWrites) throw const FileSystemException('forced failure');
  }
}

final class _SucceededRunPort implements ProjectRunFixture {
  const _SucceededRunPort({this.status = 'succeeded'});

  final String status;

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async => ApiResult<AgentRunSnapshot>.success(
    data: AgentRunSnapshot(
      agentRunId: agentRunId,
      workspaceId: 'workspace-1',
      threadId: 'thread_positioning_1',
      taskId: 'task_positioning_1',
      status: status,
      error: status == 'failed'
          ? AgentRunPublicError(
              code: 'WORKSPACE_VERSION_CONFLICT',
              retryable: false,
            )
          : null,
      workspaceVersion: 1,
      workspaceBindingVersion: 1,
      contextGeneration: 1,
      usage: const AgentRunUsage(
        measurementStatus: 'unavailable',
        inputTokens: null,
        outputTokens: null,
        imageCount: null,
        videoSeconds: null,
        accountedCredits: null,
        policyVersion: null,
      ),
      toolTrace: const <AgentRunToolTrace>[],
      createdAt: DateTime.utc(2026, 8, 16, 9),
      updatedAt: DateTime.utc(2026, 8, 16, 9, 1),
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final class _TokenDriver implements SecureTokenDriver {
  @override
  Future<bool> clear({required String service}) async => true;

  @override
  Future<SecureTokenCredential?> read({required String service}) async => null;

  @override
  Future<bool> write({
    required String service,
    required String username,
    required String password,
  }) async => true;
}
