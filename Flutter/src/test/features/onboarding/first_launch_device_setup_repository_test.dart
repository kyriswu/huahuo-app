import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/onboarding/application/first_launch_device_setup_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/first_launch_device_setup_repository.dart';

void main() {
  test(
    'v5 round trip preserves independent outcomes and isolates accounts',
    () {
      final dao = AppPreferencesDao(AppDatabase());
      final accountA = FirstLaunchDeviceSetupRepository(
        dao: dao,
        userScope: 'user-a',
      );
      final accountB = FirstLaunchDeviceSetupRepository(
        dao: dao,
        userScope: 'user-b',
      );
      final controller = FirstLaunchDeviceSetupController(repository: accountA);
      addTearDown(controller.dispose);
      controller.finishPositioning(FirstLaunchStepStatus.submitted);
      controller.finishVoiceprint(
        FirstLaunchStepStatus.failed,
        errorCode: 'ENROLL_FAILED',
      );
      controller.finishRecordingCard(FirstLaunchStepStatus.deferred);
      final restored = accountA.load();
      expect(restored.phase, FirstLaunchJourneyPhase.completed);
      expect(restored.positioning.status, FirstLaunchStepStatus.submitted);
      expect(restored.voiceprint.status, FirstLaunchStepStatus.failed);
      expect(restored.voiceprint.errorCode, 'ENROLL_FAILED');
      expect(restored.recordingCardSerial, isNull);
      expect(accountB.load().hasStarted, isFalse);
      final encoded = dao.readValue(accountA.preferenceKey)!;
      expect((jsonDecode(encoded) as Map)['version'], 5);
      expect(accountA.preferenceKey, isNot(contains('user-a')));
      expect(encoded, isNot(contains('user-a')));
    },
  );

  test(
    'v3 migration preserves actual successes and removes report wait gate',
    () {
      final dao = AppPreferencesDao(AppDatabase());
      final repository = FirstLaunchDeviceSetupRepository(
        dao: dao,
        userScope: 'user-a',
      );
      final now = DateTime.utc(2026, 9, 5);
      for (final phase in [
        'reportQueuedNotice',
        'voiceprintRequired',
        'recordingCardRequired',
        'recordingCardConnected',
        'completed',
      ]) {
        final count =
            [
              'reportQueuedNotice',
              'voiceprintRequired',
              'recordingCardRequired',
              'recordingCardConnected',
              'completed',
            ].indexOf(phase) +
            1;
        _seed(dao, repository, {
          'version': 3,
          'phase': phase,
          'startedAt': now.toIso8601String(),
          if (count >= 2) 'reportNoticeAcknowledgedAt': now.toIso8601String(),
          if (count >= 3) 'voiceprintCompletedAt': now.toIso8601String(),
          if (count >= 4) 'recordingCardConnectedAt': now.toIso8601String(),
          if (count >= 4) 'recordingCardSerial': 'CARD-1',
          if (count >= 5) 'completedAt': now.toIso8601String(),
        });
        final restored = repository.load();
        expect(restored.isConsistent, isTrue);
        expect(
          restored.phase,
          count < 3
              ? FirstLaunchJourneyPhase.voiceprintRequired
              : count == 3
              ? FirstLaunchJourneyPhase.recordingCardRequired
              : FirstLaunchJourneyPhase.completed,
        );
        expect(
          restored.voiceprint.status,
          count >= 3
              ? FirstLaunchStepStatus.succeeded
              : FirstLaunchStepStatus.active,
        );
        expect(repository.save(snapshot: restored, updatedAt: now), isTrue);
        expect(
          (jsonDecode(dao.readValue(repository.preferenceKey)!)
              as Map)['version'],
          5,
        );
      }
    },
  );

  test(
    'v2 viewed-only flags cannot count as successful enrollment or connection',
    () {
      final dao = AppPreferencesDao(AppDatabase());
      final repository = FirstLaunchDeviceSetupRepository(
        dao: dao,
        userScope: 'user-a',
      );
      _seed(dao, repository, {
        'version': 2,
        'autoPresentationClaimed': true,
        'voiceprintGuideViewed': true,
        'recordingCardGuideViewed': true,
        'claimedAt': DateTime.utc(2026, 9, 5).toIso8601String(),
      });
      final restored = repository.load();
      expect(restored.phase, FirstLaunchJourneyPhase.voiceprintRequired);
      expect(restored.voiceprint.hasExited, isFalse);
      expect(restored.recordingCard.hasExited, isFalse);
    },
  );

  test('corrupt checkpoints restore a traversable unfinished journey', () {
    final dao = AppPreferencesDao(AppDatabase());
    final repository = FirstLaunchDeviceSetupRepository(
      dao: dao,
      userScope: 'user-a',
    );
    dao.upsertValue(
      preferenceKey: repository.preferenceKey,
      value: '{bad-json',
      updatedAt: DateTime.utc(2026, 9, 5).toIso8601String(),
    );
    expect(
      repository.load().phase,
      FirstLaunchJourneyPhase.positioningRequired,
    );
    final controller = FirstLaunchDeviceSetupController(repository: repository);
    addTearDown(controller.dispose);
    expect(
      controller.finishPositioning(FirstLaunchStepStatus.deferred),
      isTrue,
    );
    expect(controller.phase, FirstLaunchJourneyPhase.voiceprintRequired);
  });

  test(
    'reverse transitions and unproven card success cannot overwrite progress',
    () {
      final dao = AppPreferencesDao(AppDatabase());
      final repository = FirstLaunchDeviceSetupRepository(
        dao: dao,
        userScope: 'user-a',
      );
      final controller = FirstLaunchDeviceSetupController(
        repository: repository,
      );
      addTearDown(controller.dispose);
      controller.finishPositioning(FirstLaunchStepStatus.deferred);
      controller.finishVoiceprint(FirstLaunchStepStatus.deferred);
      final snapshot = controller.snapshot;
      final now = DateTime.now().toUtc();
      expect(
        repository.save(
          snapshot: const FirstLaunchDeviceSetupSnapshot(),
          updatedAt: now,
        ),
        isFalse,
      );
      expect(
        repository.save(
          snapshot: snapshot.copyWith(
            recordingCard: FirstLaunchStepSnapshot(
              status: FirstLaunchStepStatus.succeeded,
              updatedAt: now,
            ),
          ),
          updatedAt: now,
        ),
        isFalse,
      );
      expect(
        repository.load().phase,
        FirstLaunchJourneyPhase.recordingCardRequired,
      );
    },
  );
}

void _seed(
  AppPreferencesDao dao,
  FirstLaunchDeviceSetupRepository repository,
  Map<String, Object?> payload,
) {
  dao.upsertValue(
    preferenceKey: repository.preferenceKey,
    value: jsonEncode(payload),
    updatedAt: DateTime.utc(2026, 9, 5).toIso8601String(),
  );
}
