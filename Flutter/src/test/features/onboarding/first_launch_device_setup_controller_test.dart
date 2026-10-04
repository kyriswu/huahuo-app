import 'package:huahuoai_app/app/di/database_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/onboarding/application/first_launch_device_setup_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/first_launch_device_setup_repository.dart';
import 'package:huahuoai_app/features/onboarding/application/content_line_onboarding_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/initial_positioning_agent.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_progress_repository.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';

void main() {
  for (final firstLogin in [true, false]) {
    test(
      'startup provider uses firstLogin=$firstLogin before registration',
      () async {
        final dao = AppPreferencesDao(AppDatabase());
        final session = SessionStore(
          secureTokenStore: SecureTokenStore(driver: _MemoryTokenDriver()),
        );
        await session.applyLoginSuccess(
          firstLoginThisSession: firstLogin,
          tokens: const AuthTokens(
            accessToken: 'access',
            refreshToken: 'refresh',
          ),
          snapshot: SafeAuthSessionSnapshot(
            user: const SessionUser(
              userId: 'user-1',
              maskedPhoneNumber: '138****8000',
            ),
            expiresAt: DateTime.utc(2027),
            workspaceStatus: SessionWorkspaceStatus.ready,
            onboardingRequired: true,
          ),
          verifiedStatus: const SessionUserStatus(
            user: SessionUser(
              userId: 'user-1',
              maskedPhoneNumber: '138****8000',
            ),
            workspace: SessionWorkspace(
              status: SessionWorkspaceStatus.ready,
              workspaceId: 'workspace-1',
            ),
            onboardingRequired: true,
          ),
          updatedAt: DateTime.utc(2026, 9, 8),
        );
        final continuation = OnboardingContinuationController(
          repository: OnboardingProgressRepository(dao: dao),
        );
        final container = ProviderContainer(
          overrides: [
            sessionStoreProvider.overrideWith((ref) => session),
            appPreferencesDaoProvider.overrideWithValue(dao),
            onboardingContinuationControllerProvider.overrideWith(
              (ref) => continuation,
            ),
          ],
        );
        addTearDown(container.dispose);
        final controller = container.read(
          firstLaunchDeviceSetupControllerProvider,
        );
        expect(
          controller.phase,
          firstLogin
              ? FirstLaunchJourneyPhase.positioningRequired
              : FirstLaunchJourneyPhase.notStarted,
        );
        if (!firstLogin) {
          expect(
            continuation.defer(
              'user-1',
              OnboardingProgressSnapshot(deferredAt: DateTime.utc(2026, 9, 1)),
            ),
            isTrue,
          );
          expect(continuation.isDeferredFor('user-1'), isTrue);
          expect(controller.phase, FirstLaunchJourneyPhase.notStarted);
        }
        continuation.acceptRun(
          'user-1',
          const InitialPositioningRunReceipt(
            threadId: 'thread-1',
            agentRunId: 'agent_run_1',
            taskId: 'task-1',
            messageId: 'message-1',
            status: 'accepted',
          ),
          workspaceId: 'workspace-1',
        );
        expect(
          controller.phase,
          firstLogin
              ? FirstLaunchJourneyPhase.positioningRequired
              : FirstLaunchJourneyPhase.notStarted,
        );
        continuation.recordRunRegistration(
          'user-1',
          agentRunId: 'agent_run_1',
          workspaceId: 'workspace-1',
          attemptId: 'attempt-1',
        );
        expect(
          controller.phase,
          firstLogin
              ? FirstLaunchJourneyPhase.voiceprintRequired
              : FirstLaunchJourneyPhase.notStarted,
        );
        expect(
          continuation.acceptedRunFor('user-1')?.isBackendRegistered,
          isTrue,
        );
      },
    );
  }

  test('submission failure exits intake without claiming acceptance', () {
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.beginPositioning();
    expect(controller.finishPositioning(FirstLaunchStepStatus.failed), isTrue);
    expect(
      controller.finishPositioning(FirstLaunchStepStatus.deferred),
      isTrue,
    );
    expect(controller.phase, FirstLaunchJourneyPhase.voiceprintRequired);
    expect(
      controller.snapshot.positioning.status,
      FirstLaunchStepStatus.failed,
    );
  });
  test('each independent exit advances exactly one step in order', () {
    for (final positioning in [
      FirstLaunchStepStatus.submitted,
      FirstLaunchStepStatus.succeeded,
      FirstLaunchStepStatus.deferred,
      FirstLaunchStepStatus.failed,
    ]) {
      for (final voiceprint in [
        FirstLaunchStepStatus.succeeded,
        FirstLaunchStepStatus.deferred,
        FirstLaunchStepStatus.failed,
      ]) {
        for (final card in [
          FirstLaunchStepStatus.succeeded,
          FirstLaunchStepStatus.deferred,
          FirstLaunchStepStatus.failed,
        ]) {
          final controller = _controller();
          expect(controller.beginPositioning(), isTrue);
          expect(controller.phase, FirstLaunchJourneyPhase.positioningRequired);
          expect(controller.finishVoiceprint(voiceprint), isFalse);
          expect(
            controller.finishRecordingCard(card, serialNumber: 'CARD-1'),
            isFalse,
          );
          expect(controller.finishPositioning(positioning), isTrue);
          expect(controller.phase, FirstLaunchJourneyPhase.voiceprintRequired);
          expect(controller.finishVoiceprint(voiceprint), isTrue);
          expect(
            controller.phase,
            FirstLaunchJourneyPhase.recordingCardRequired,
          );
          expect(
            controller.finishRecordingCard(card, serialNumber: 'CARD-1'),
            isTrue,
          );
          expect(controller.snapshot.isComplete, isTrue);
          expect(controller.requiresBlockingJourney, isFalse);
          expect(controller.snapshot.positioning.status, positioning);
          expect(controller.snapshot.voiceprint.status, voiceprint);
          expect(controller.snapshot.recordingCard.status, card);
          expect(
            controller.snapshot.recordingCardSerial,
            card == FirstLaunchStepStatus.succeeded ? 'CARD-1' : null,
          );
          controller.dispose();
        }
      }
    }
  });

  test(
    'report failure after later steps never rewinds or alters their outcomes',
    () {
      var now = DateTime.utc(2026, 9, 5);
      final controller = _controller(now: () => now);
      addTearDown(controller.dispose);
      controller.finishPositioning(FirstLaunchStepStatus.submitted);
      controller.finishVoiceprint(FirstLaunchStepStatus.deferred);
      controller.finishRecordingCard(
        FirstLaunchStepStatus.failed,
        errorCode: 'CARD_FAILED',
      );
      final voiceprint = controller.snapshot.voiceprint;
      final card = controller.snapshot.recordingCard;
      now = now.add(const Duration(minutes: 3));
      expect(
        controller.finishPositioning(
          FirstLaunchStepStatus.failed,
          errorCode: 'RUN_FAILED',
        ),
        isTrue,
      );
      expect(
        controller.snapshot.positioning.status,
        FirstLaunchStepStatus.submitted,
      );
      expect(controller.snapshot.positioning.errorCode, isNull);
      expect(identical(controller.snapshot.voiceprint, voiceprint), isTrue);
      expect(identical(controller.snapshot.recordingCard, card), isTrue);
      expect(controller.phase, FirstLaunchJourneyPhase.completed);
      controller.syncAccount(userId: 'user-1', positioningRequired: true);
      expect(controller.phase, FirstLaunchJourneyPhase.completed);
    },
  );

  test('restart restores each unfinished step without firstLogin', () {
    final repository = _repository(AppPreferencesDao(AppDatabase()), 'user-1');
    final first = FirstLaunchDeviceSetupController(repository: repository);
    first.beginPositioning();
    first.dispose();
    final second = FirstLaunchDeviceSetupController(repository: repository);
    second.syncAccount(userId: 'user-1');
    expect(second.requiresPositioning, isTrue);
    second.finishPositioning(FirstLaunchStepStatus.submitted);
    second.dispose();
    final third = FirstLaunchDeviceSetupController(repository: repository);
    expect(third.phase, FirstLaunchJourneyPhase.voiceprintRequired);
    third.finishVoiceprint(FirstLaunchStepStatus.failed);
    third.dispose();
    final fourth = FirstLaunchDeviceSetupController(repository: repository);
    expect(fourth.phase, FirstLaunchJourneyPhase.recordingCardRequired);
    fourth.dispose();
  });

  test(
    'standalone registration cannot admit a returning account to startup',
    () {
      final controller = _controller();
      addTearDown(controller.dispose);
      controller.syncAccount(userId: 'user-1');
      expect(controller.requiresBlockingJourney, isFalse);
      controller.syncAccount(
        userId: 'user-1',
        initialPositioningAccepted: true,
      );
      expect(controller.phase, FirstLaunchJourneyPhase.notStarted);
      expect(controller.snapshot.hasStarted, isFalse);
      controller.syncAccount(
        userId: 'user-1',
        positioningRequired: true,
        initialPositioningAccepted: true,
      );
      expect(controller.phase, FirstLaunchJourneyPhase.voiceprintRequired);
      expect(
        controller.snapshot.positioning.status,
        FirstLaunchStepStatus.submitted,
      );
    },
  );

  test(
    'account revisions reject delayed results even after logout and same-user login',
    () {
      final dao = AppPreferencesDao(AppDatabase());
      final controller = FirstLaunchDeviceSetupController.accountScoped(
        repositoryForUser: (userId) => _repository(dao, userId),
      );
      addTearDown(controller.dispose);
      controller.syncAccount(userId: 'user-1', positioningRequired: true);
      final revision = controller.accountRevision;
      controller.syncAccount(userId: 'user-2', positioningRequired: true);
      expect(
        controller.finishPositioning(
          FirstLaunchStepStatus.submitted,
          expectedAccountRevision: revision,
        ),
        isFalse,
      );
      controller.syncAccount(userId: null);
      controller.syncAccount(userId: 'user-1');
      expect(
        controller.finishPositioning(
          FirstLaunchStepStatus.submitted,
          expectedAccountRevision: revision,
        ),
        isFalse,
      );
      expect(controller.requiresPositioning, isTrue);
    },
  );

  test(
    'card success requires a safe serial; failure and deferral never invent one',
    () {
      final controller = _controller();
      addTearDown(controller.dispose);
      controller.finishPositioning(FirstLaunchStepStatus.submitted);
      controller.finishVoiceprint(FirstLaunchStepStatus.deferred);
      for (final serial in [null, '   ', 'CARD\u0000']) {
        expect(
          controller.finishRecordingCard(
            FirstLaunchStepStatus.succeeded,
            serialNumber: serial,
          ),
          isFalse,
        );
      }
      expect(
        controller.finishRecordingCard(FirstLaunchStepStatus.deferred),
        isTrue,
      );
      expect(controller.snapshot.recordingCardSerial, isNull);
    },
  );
}

FirstLaunchDeviceSetupRepository _repository(
  AppPreferencesDao dao,
  String userId,
) => FirstLaunchDeviceSetupRepository(dao: dao, userScope: userId);

FirstLaunchDeviceSetupController _controller({DateTime Function()? now}) =>
    FirstLaunchDeviceSetupController(
      repository: _repository(AppPreferencesDao(AppDatabase()), 'user-1'),
      now: now,
    );

final class _MemoryTokenDriver implements SecureTokenDriver {
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
