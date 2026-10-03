import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/voiceprint_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/voiceprint_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/voiceprint_profile_repository.dart';

void main() {
  test(
    'voiceprint consumes real levels, requires consent, and enrolls remotely',
    () async {
      final recorder = _VoiceprintRecorder();
      final deletedUris = <String>[];
      final api = _VoiceprintApi();
      final port = RemoteVoiceprintPort(
        api: api,
        deleteLocalSample: (uri) async {
          deletedUris.add(uri);
          return true;
        },
        now: () => DateTime.utc(2026, 7, 15, 9),
      );
      final controller = VoiceprintController(
        recorder: recorder,
        port: port,
        initialUserId: 'voice-user-1',
      );

      expect(await controller.start(), isTrue);
      expect(recorder.scene, VoiceRecordingScene.voiceprint);
      recorder.emitLevel(average: .4, peak: .8);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.waveformLevels, hasLength(68));
      expect(controller.state.waveformLevels.last, greaterThan(0));

      recorder.elapsedSeconds = 10;
      expect(await controller.refresh(), isTrue);
      await pumpEventQueue(times: 4);
      expect(controller.state.status, VoiceprintStatus.ready);
      expect(await controller.submit(), isFalse);
      expect(controller.state.errorCode, 'VOICEPRINT_CONSENT_REQUIRED');

      controller.setConsentAccepted(true);
      expect(await controller.submit(), isTrue);
      expect(controller.state.status, VoiceprintStatus.enrolled);
      expect(controller.state.enrollment?.isDemo, isFalse);
      expect(api.enrollRequests.single.speakerNick, '我的声纹');
      expect(deletedUris, <String>['app-private://voiceprint-1.wav']);

      expect(await controller.deleteEnrollment(), isTrue);
      expect(
        api.deleteRequests.single.profileId,
        controller.state.enrollment?.profileId ?? api.lastProfileId,
      );

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'capture enforces 10 seconds and automatically stops at 10 seconds',
    () async {
      final recorder = _VoiceprintRecorder();
      final controller = VoiceprintController(
        recorder: recorder,
        port: SessionMockVoiceprintPort(deleteLocalSample: (_) async => true),
        initialUserId: 'voice-user-2',
      );

      expect(await controller.start(), isTrue);
      recorder.elapsedSeconds = 9;
      await controller.refresh();
      expect(await controller.stop(), isFalse);
      expect(controller.state.status, VoiceprintStatus.recording);
      expect(controller.state.errorCode, 'VOICEPRINT_SAMPLE_TOO_SHORT');

      recorder.elapsedSeconds = 10;
      recorder.draftDurationSeconds = 10;
      await controller.refresh();
      await pumpEventQueue(times: 4);
      expect(recorder.stopCalls, 1);
      expect(controller.state.status, VoiceprintStatus.ready);
      expect(controller.state.elapsedSeconds, 10);

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'accepts a ceil-rounded 11-second draft at the native grace boundary',
    () async {
      final recorder = _VoiceprintRecorder()
        ..draftDurationSeconds = voiceprintWavMaximumReportedSeconds;
      final controller = VoiceprintController(
        recorder: recorder,
        port: SessionMockVoiceprintPort(deleteLocalSample: (_) async => true),
        initialUserId: 'voice-user-grace',
      );

      expect(await controller.start(), isTrue);
      recorder.elapsedSeconds = voiceprintMaximumSeconds;
      expect(await controller.refresh(), isTrue);
      await pumpEventQueue(times: 4);

      expect(controller.state.status, VoiceprintStatus.ready);
      expect(
        controller.state.elapsedSeconds,
        voiceprintWavMaximumReportedSeconds,
      );

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'remote failure keeps the private WAV ready for an explicit retry',
    () async {
      final recorder = _VoiceprintRecorder();
      final deletedUris = <String>[];
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: _VoiceprintApi(failEnroll: true),
          deleteLocalSample: (uri) async {
            deletedUris.add(uri);
            return true;
          },
        ),
        initialUserId: 'voice-user-retry',
      );

      expect(await controller.beginProfileEnrollment(name: '本人'), isTrue);
      recorder.elapsedSeconds = voiceprintMinimumSeconds;
      expect(await controller.refresh(), isTrue);
      await pumpEventQueue(times: 4);
      controller.setConsentAccepted(true);

      expect(await controller.submit(), isFalse);
      expect(controller.state.status, VoiceprintStatus.ready);
      expect(controller.state.errorCode, 'VOICEPRINT_ENROLL_FAILED');
      expect(
        controller.state.draft?.appPrivateUri,
        'app-private://voiceprint-1.wav',
      );
      expect(deletedUris, isEmpty);

      controller.dispose();
      await pumpEventQueue(times: 2);
      expect(deletedUris, <String>['app-private://voiceprint-1.wav']);
      await recorder.close();
    },
  );

  test(
    'session loss cancels active capture and clears enrollment scope',
    () async {
      final recorder = _VoiceprintRecorder();
      final port = SessionMockVoiceprintPort(
        deleteLocalSample: (_) async => true,
      );
      final controller = VoiceprintController(
        recorder: recorder,
        port: port,
        initialUserId: 'voice-user-3',
      );

      expect(await controller.start(), isTrue);
      await controller.syncSession(null);
      expect(recorder.cancelCalls, 1);
      expect(controller.state.status, VoiceprintStatus.idle);
      expect(controller.state.enrollment, isNull);

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'abandoning enrollment clears active capture and a ready private draft',
    () async {
      final recorder = _VoiceprintRecorder();
      final deletedUris = <String>[];
      final controller = VoiceprintController(
        recorder: recorder,
        port: SessionMockVoiceprintPort(
          deleteLocalSample: (uri) async {
            deletedUris.add(uri);
            return true;
          },
        ),
        initialUserId: 'voice-user-abandon',
      );

      expect(await controller.beginProfileEnrollment(name: '待录入声纹'), isTrue);
      expect(controller.state.isCaptureActive, isTrue);
      expect(await controller.abandonEnrollment(), isTrue);
      expect(recorder.cancelCalls, 1);
      expect(controller.state.status, VoiceprintStatus.idle);
      expect(controller.state.pendingProfileName, isNull);

      expect(await controller.beginProfileEnrollment(name: '待录入声纹'), isTrue);
      recorder.elapsedSeconds = voiceprintMinimumSeconds;
      expect(await controller.refresh(), isTrue);
      await pumpEventQueue(times: 4);
      expect(controller.state.status, VoiceprintStatus.ready);
      expect(await controller.abandonEnrollment(), isTrue);
      expect(deletedUris, <String>['app-private://voiceprint-1.wav']);
      expect(controller.state.status, VoiceprintStatus.idle);
      expect(controller.state.draft, isNull);

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'persists multiple named profiles without retaining sample paths',
    () async {
      final recorder = _VoiceprintRecorder();
      final database = AppDatabase();
      final dao = UserMetadataDao(database);
      final repository = VoiceprintProfileRepository(
        dao: dao,
        userScope: 'voice-user-4',
      );
      final deletedUris = <String>[];
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: _VoiceprintApi(),
          deleteLocalSample: (uri) async {
            deletedUris.add(uri);
            return true;
          },
        ),
        profileRepository: repository,
        initialUserId: 'voice-user-4',
        now: () => DateTime.utc(2026, 7, 15, 9),
      );

      for (final name in <String>['主持人', '访谈嘉宾']) {
        expect(await controller.beginProfileEnrollment(name: name), isTrue);
        recorder.elapsedSeconds = 10;
        expect(await controller.refresh(), isTrue);
        await pumpEventQueue(times: 4);
        controller.setConsentAccepted(true);
        expect(await controller.submit(), isTrue);
      }

      expect(controller.state.profiles, hasLength(2));
      expect(
        repository.loadProfiles().map((profile) => profile.name),
        containsAll(<String>['主持人', '访谈嘉宾']),
      );
      expect(
        controller.profileNameError(
          '主持人',
          excludingProfileId: controller.state.profiles
              .singleWhere((profile) => profile.name == '访谈嘉宾')
              .id,
        ),
        '该名称已存在',
      );
      final guest = controller.state.profiles.singleWhere(
        (profile) => profile.name == '访谈嘉宾',
      );
      expect(controller.renameProfile(guest.id, '嘉宾 A'), isTrue);
      expect(
        repository.loadProfiles().map((profile) => profile.name),
        contains('嘉宾 A'),
      );

      final host = controller.state.profiles.singleWhere(
        (profile) => profile.name == '主持人',
      );
      expect(await controller.deleteProfile(host.id), isTrue);
      expect(repository.loadProfiles(), hasLength(1));
      expect(
        VoiceprintProfileRepository(
          dao: dao,
          userScope: 'voice-user-other',
        ).loadProfiles(),
        isEmpty,
      );
      expect(deletedUris, hasLength(2));
      final stored = database.listRecords(LocalTableName.voiceprintProfiles);
      expect(stored.single.keys, isNot(contains('app_private_uri')));
      expect(
        stored.single.values,
        isNot(contains('app-private://voiceprint-1.wav')),
      );

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'deletes historical local demo metadata without a cloud request',
    () async {
      final recorder = _VoiceprintRecorder();
      final database = AppDatabase();
      final dao = UserMetadataDao(database)
        ..upsertVoiceprintProfile(
          userScope: 'voice-user-demo',
          profileId: 'legacy-demo-profile',
          name: '旧声纹',
          enrolledAt: '2026-07-15T09:00:00.000Z',
          updatedAt: '2026-07-15T09:00:00.000Z',
          isDemo: true,
        );
      final api = _VoiceprintApi();
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: api,
          deleteLocalSample: (_) async => true,
        ),
        profileRepository: VoiceprintProfileRepository(
          dao: dao,
          userScope: 'voice-user-demo',
        ),
        initialUserId: 'voice-user-demo',
      );

      expect(controller.state.profiles.single.isDemo, isTrue);
      expect(await controller.deleteProfile('legacy-demo-profile'), isTrue);
      expect(controller.state.profiles, isEmpty);
      expect(api.deleteRequests, isEmpty);

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'rerecord persists the server id and replaces old metadata after success',
    () async {
      final recorder = _VoiceprintRecorder();
      final database = AppDatabase();
      final dao = UserMetadataDao(database)
        ..upsertVoiceprintProfile(
          userScope: 'voice-user-replace',
          profileId: 'vp-server-old',
          name: '本人',
          enrolledAt: '2026-07-15T09:00:00.000Z',
          updatedAt: '2026-07-15T09:00:00.000Z',
          isDemo: false,
        );
      final repository = VoiceprintProfileRepository(
        dao: dao,
        userScope: 'voice-user-replace',
      );
      final api = _VoiceprintApi(serverAssignedProfileId: 'vp-server-new');
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: api,
          deleteLocalSample: (_) async => true,
        ),
        profileRepository: repository,
        initialUserId: 'voice-user-replace',
      );

      expect(
        await controller.beginProfileEnrollment(
          name: '本人',
          profileId: 'vp-server-old',
        ),
        isTrue,
      );
      recorder.elapsedSeconds = voiceprintMinimumSeconds;
      expect(await controller.refresh(), isTrue);
      await pumpEventQueue(times: 4);
      controller.setConsentAccepted(true);
      expect(await controller.submit(), isTrue);

      expect(api.enrollRequests.single.replacementProfileId, 'vp-server-old');
      expect(controller.state.enrollment?.profileId, 'vp-server-new');
      expect(repository.loadProfiles(), hasLength(1));
      expect(repository.loadProfiles().single.id, 'vp-server-new');
      expect(repository.loadProfiles().single.name, '本人');
      expect(
        database
            .listRecords(LocalTableName.voiceprintProfiles)
            .single['profile_id'],
        'vp-server-new',
      );

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'server snapshot preserves local names, restores new profiles, and removes stale real profiles',
    () async {
      final recorder = _VoiceprintRecorder();
      final database = AppDatabase();
      final dao = UserMetadataDao(database)
        ..upsertVoiceprintProfile(
          userScope: 'voice-user-sync',
          profileId: 'vp-keep',
          name: '采访者本人',
          enrolledAt: '2026-07-10T09:00:00.000Z',
          updatedAt: '2026-07-10T09:00:00.000Z',
          isDemo: false,
        )
        ..upsertVoiceprintProfile(
          userScope: 'voice-user-sync',
          profileId: 'vp-stale',
          name: '旧服务器声纹',
          enrolledAt: '2026-07-09T09:00:00.000Z',
          updatedAt: '2026-07-09T09:00:00.000Z',
          isDemo: false,
        )
        ..upsertVoiceprintProfile(
          userScope: 'voice-user-sync',
          profileId: 'demo-local',
          name: '我的声纹',
          enrolledAt: '2026-07-08T09:00:00.000Z',
          updatedAt: '2026-07-08T09:00:00.000Z',
          isDemo: true,
        );
      final repository = VoiceprintProfileRepository(
        dao: dao,
        userScope: 'voice-user-sync',
      );
      final api = _VoiceprintApi(
        listedProfiles: <VoiceprintRemoteProfile>[
          _remoteProfile('vp-keep', speakerNick: 'vpr-secret-keep'),
          _remoteProfile('vp-new', speakerNick: 'vpr-secret-new'),
          _remoteProfile(
            'vp-revoked',
            speakerNick: 'vpr-secret-revoked',
            status: VoiceprintRemoteProfileStatus.revoked,
          ),
        ],
      );
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: api,
          deleteLocalSample: (_) async => true,
        ),
        initialUserId: 'voice-user-sync',
        profileRepository: repository,
      );

      expect(await controller.refreshProfiles(), isTrue);
      final byId = <String, String>{
        for (final profile in controller.state.profiles)
          profile.id: profile.name,
      };
      expect(byId['vp-keep'], '采访者本人');
      expect(byId['vp-new'], '我的声纹 2');
      expect(byId['demo-local'], '我的声纹');
      expect(byId, isNot(contains('vp-stale')));
      expect(byId, isNot(contains('vp-revoked')));
      expect(byId.values.any((name) => name.startsWith('vpr-')), isFalse);

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'failed server snapshot keeps local profiles and exposes retry error',
    () async {
      final recorder = _VoiceprintRecorder();
      final database = AppDatabase();
      final dao = UserMetadataDao(database)
        ..upsertVoiceprintProfile(
          userScope: 'voice-user-sync-failure',
          profileId: 'vp-local',
          name: '本地自定义名称',
          enrolledAt: '2026-07-10T09:00:00.000Z',
          updatedAt: '2026-07-10T09:00:00.000Z',
          isDemo: false,
        );
      final repository = VoiceprintProfileRepository(
        dao: dao,
        userScope: 'voice-user-sync-failure',
      );
      final api = _VoiceprintApi(failList: true);
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: api,
          deleteLocalSample: (_) async => true,
        ),
        initialUserId: 'voice-user-sync-failure',
        profileRepository: repository,
      );

      expect(await controller.refreshProfiles(), isFalse);
      expect(controller.state.errorCode, 'VOICEPRINT_PROFILE_SYNC_FAILED');
      expect(controller.state.profiles.single.name, '本地自定义名称');
      expect(repository.loadProfiles().single.id, 'vp-local');

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'retryable remote delete reuses its key until terminal success',
    () async {
      final api = _VoiceprintApi(
        deleteResults: <VoiceprintApiResult<VoiceprintDeleteReceipt>>[
          VoiceprintApiResult.failure(
            voiceprintApiFailure('NETWORK_REQUEST_FAILED', retryable: true),
          ),
          VoiceprintApiResult.success(
            const VoiceprintDeleteReceipt(profileId: 'vp-delete'),
          ),
          VoiceprintApiResult.success(
            const VoiceprintDeleteReceipt(profileId: 'vp-delete'),
          ),
        ],
      );
      final port = RemoteVoiceprintPort(
        api: api,
        deleteLocalSample: (_) async => true,
        now: () => DateTime.utc(2026, 7, 15, 9),
      )..beginSession('voice-user-delete');

      expect(
        (await port.deleteEnrollment(
          userId: 'voice-user-delete',
          profileId: 'vp-delete',
        )).ok,
        isFalse,
      );
      expect(
        (await port.deleteEnrollment(
          userId: 'voice-user-delete',
          profileId: 'vp-delete',
        )).ok,
        isTrue,
      );
      expect(
        api.deleteRequests[0].idempotencyKey,
        api.deleteRequests[1].idempotencyKey,
      );

      expect(
        (await port.deleteEnrollment(
          userId: 'voice-user-delete',
          profileId: 'vp-delete',
        )).ok,
        isTrue,
      );
      expect(
        api.deleteRequests[2].idempotencyKey,
        isNot(api.deleteRequests[1].idempotencyKey),
      );
    },
  );

  test(
    'page refresh shares the bootstrap sync request and repository boundary',
    () async {
      final recorder = _VoiceprintRecorder();
      final repository = VoiceprintProfileRepository(
        dao: UserMetadataDao(AppDatabase()),
        userScope: 'voice-user-shared-sync',
      );
      final response =
          Completer<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>();
      final serviceApi = _VoiceprintApi(listResult: response.future);
      final pagePortApi = _VoiceprintApi();
      final service = VoiceprintProfileSyncService(
        api: serviceApi,
        repository: repository,
      );
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: pagePortApi,
          deleteLocalSample: (_) async => true,
        ),
        initialUserId: 'voice-user-shared-sync',
        profileRepository: repository,
        profileSyncService: service,
      );

      final bootstrapSync = service.sync();
      final pageSync = controller.refreshProfiles();
      expect(serviceApi.listCalls, 1);
      expect(pagePortApi.listCalls, 0);
      response.complete(
        VoiceprintApiResult.success(<VoiceprintRemoteProfile>[
          _remoteProfile('vp-shared', speakerNick: 'vpr-opaque-shared'),
        ]),
      );

      expect(await bootstrapSync, isTrue);
      expect(await pageSync, isTrue);
      expect(serviceApi.listCalls, 1);
      expect(pagePortApi.listCalls, 0);
      expect(controller.state.profiles.single.id, 'vp-shared');
      expect(controller.state.profiles.single.name, '我的声纹');

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'a GET started before enroll cannot remove the newly saved profile',
    () async {
      final recorder = _VoiceprintRecorder();
      final repository = VoiceprintProfileRepository(
        dao: UserMetadataDao(AppDatabase()),
        userScope: 'voice-user-enroll-race',
      );
      final staleResponse =
          Completer<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>();
      final refreshResponse =
          Completer<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>();
      final syncApi = _VoiceprintApi(
        listResults:
            <Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>>[
              staleResponse.future,
              refreshResponse.future,
            ],
      );
      final service = VoiceprintProfileSyncService(
        api: syncApi,
        repository: repository,
      );
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: _VoiceprintApi(serverAssignedProfileId: 'vp-enrolled-new'),
          deleteLocalSample: (_) async => true,
        ),
        initialUserId: 'voice-user-enroll-race',
        profileRepository: repository,
        profileSyncService: service,
      );

      expect(await controller.beginProfileEnrollment(name: '本人'), isTrue);
      recorder.elapsedSeconds = voiceprintMinimumSeconds;
      expect(await controller.refresh(), isTrue);
      await pumpEventQueue(times: 4);
      controller.setConsentAccepted(true);
      final staleSync = service.sync();
      expect(syncApi.listCalls, 1);

      expect(await controller.submit(), isTrue);
      expect(repository.loadProfiles().single.id, 'vp-enrolled-new');
      staleResponse.complete(
        VoiceprintApiResult.success(const <VoiceprintRemoteProfile>[]),
      );
      expect(await staleSync, isFalse);
      await pumpEventQueue(times: 4);

      expect(syncApi.listCalls, 2);
      expect(repository.loadProfiles().single.id, 'vp-enrolled-new');
      refreshResponse.complete(
        VoiceprintApiResult.success(<VoiceprintRemoteProfile>[
          _remoteProfile('vp-enrolled-new', speakerNick: 'vpr-enrolled-new'),
        ]),
      );
      await pumpEventQueue(times: 4);
      expect(repository.loadProfiles().single.id, 'vp-enrolled-new');
      expect(controller.state.profiles.single.name, '本人');

      controller.dispose();
      await recorder.close();
    },
  );

  test(
    'a GET started before delete cannot restore the deleted profile',
    () async {
      final recorder = _VoiceprintRecorder();
      final database = AppDatabase();
      final dao = UserMetadataDao(database)
        ..upsertVoiceprintProfile(
          userScope: 'voice-user-delete-race',
          profileId: 'vp-delete-race',
          name: '准备删除',
          enrolledAt: '2026-07-15T09:00:00.000Z',
          updatedAt: '2026-07-15T09:00:00.000Z',
          isDemo: false,
        );
      final repository = VoiceprintProfileRepository(
        dao: dao,
        userScope: 'voice-user-delete-race',
      );
      final staleResponse =
          Completer<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>();
      final refreshResponse =
          Completer<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>();
      final syncApi = _VoiceprintApi(
        listResults:
            <Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>>[
              staleResponse.future,
              refreshResponse.future,
            ],
      );
      final service = VoiceprintProfileSyncService(
        api: syncApi,
        repository: repository,
      );
      final controller = VoiceprintController(
        recorder: recorder,
        port: RemoteVoiceprintPort(
          api: _VoiceprintApi(),
          deleteLocalSample: (_) async => true,
        ),
        initialUserId: 'voice-user-delete-race',
        profileRepository: repository,
        profileSyncService: service,
      );

      final staleSync = service.sync();
      expect(syncApi.listCalls, 1);
      expect(await controller.deleteProfile('vp-delete-race'), isTrue);
      expect(repository.loadProfiles(), isEmpty);
      staleResponse.complete(
        VoiceprintApiResult.success(<VoiceprintRemoteProfile>[
          _remoteProfile('vp-delete-race', speakerNick: 'vpr-deleted-stale'),
        ]),
      );
      expect(await staleSync, isFalse);
      await pumpEventQueue(times: 4);

      expect(syncApi.listCalls, 2);
      expect(repository.loadProfiles(), isEmpty);
      refreshResponse.complete(
        VoiceprintApiResult.success(const <VoiceprintRemoteProfile>[]),
      );
      await pumpEventQueue(times: 4);
      expect(repository.loadProfiles(), isEmpty);
      expect(controller.state.profiles, isEmpty);

      controller.dispose();
      await recorder.close();
    },
  );
}

final class _VoiceprintRecorder
    implements VoiceRecorderPort, VoiceRecorderLevelSource {
  final _levels = StreamController<VoiceLevelSample>.broadcast();
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();

  VoiceRecordingScene? scene;
  int elapsedSeconds = 0;
  int draftDurationSeconds = 10;
  int stopCalls = 0;
  int cancelCalls = 0;

  @override
  Stream<VoiceLevelSample> get levelSamples => _levels.stream;

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  void emitLevel({required double average, required double peak}) {
    _levels.add(
      VoiceLevelSample(
        capturedAt: DateTime.utc(2026, 7, 15, 9),
        average: average,
        peak: peak,
      ),
    );
  }

  Future<void> close() => _levels.close();

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async {
    return VoiceRecorderResult.success(
      const VoiceRecorderPermission(
        state: VoiceRecorderPermissionState.granted,
        canAskAgain: false,
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() => getMicrophonePermission();

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    this.scene = scene;
    elapsedSeconds = 0;
    final session = _session(VoiceRecorderState.recording);
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async {
    if (_snapshot.state == VoiceRecorderState.recording) {
      _snapshot = VoiceRecorderSnapshot(
        state: VoiceRecorderState.recording,
        session: _session(VoiceRecorderState.recording),
      );
    }
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() async {
    stopCalls += 1;
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(
      VoiceRecordingDraft(
        recordingId: 'voiceprint-1',
        appPrivateUri: 'app-private://voiceprint-1.wav',
        fileName: 'voiceprint-1.wav',
        mimeType: 'audio/wav',
        sizeBytes: 320044,
        durationSeconds: draftDurationSeconds,
        sha256: 'a' * 64,
        scene: VoiceRecordingScene.voiceprint,
        sampleRateHz: voiceprintWavSampleRateHz,
        bitDepth: voiceprintWavBitDepth,
        channelCount: voiceprintWavChannelCount,
        recordedAt: DateTime.utc(2026, 7, 15, 9),
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    cancelCalls += 1;
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async {
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async {
    return VoiceRecorderResult.success(_snapshot);
  }

  VoiceRecordingSession _session(VoiceRecorderState state) {
    return VoiceRecordingSession(
      recordingId: 'voiceprint-1',
      scene: scene ?? VoiceRecordingScene.voiceprint,
      state: state,
      startedAt: DateTime.utc(2026, 7, 15, 9),
      elapsedSeconds: elapsedSeconds,
    );
  }
}

final class _VoiceprintApi implements VoiceprintApiPort {
  _VoiceprintApi({
    this.failEnroll = false,
    this.failList = false,
    this.serverAssignedProfileId,
    this.listedProfiles = const <VoiceprintRemoteProfile>[],
    this.listResult,
    List<Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>>?
    listResults,
    List<VoiceprintApiResult<VoiceprintDeleteReceipt>>? deleteResults,
  }) : listResults =
           listResults ??
           <Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>>[],
       deleteResults =
           deleteResults ?? <VoiceprintApiResult<VoiceprintDeleteReceipt>>[];

  final bool failEnroll;
  final bool failList;
  final String? serverAssignedProfileId;
  final List<VoiceprintRemoteProfile> listedProfiles;
  final Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>? listResult;
  final List<Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>>
  listResults;
  final List<VoiceprintApiResult<VoiceprintDeleteReceipt>> deleteResults;
  final List<VoiceprintEnrollRequest> enrollRequests =
      <VoiceprintEnrollRequest>[];
  final List<VoiceprintDeleteRequest> deleteRequests =
      <VoiceprintDeleteRequest>[];
  String? lastProfileId;
  int listCalls = 0;

  @override
  Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>
  listProfiles() async {
    listCalls += 1;
    if (listResults.isNotEmpty) return listResults.removeAt(0);
    if (listResult != null) return listResult!;
    if (failList) {
      return VoiceprintApiResult.failure(
        voiceprintApiFailure('NETWORK_REQUEST_FAILED', retryable: true),
      );
    }
    return VoiceprintApiResult.success(listedProfiles);
  }

  @override
  Future<VoiceprintApiResult<VoiceprintRemoteProfile>> enroll(
    VoiceprintEnrollRequest request,
  ) async {
    enrollRequests.add(request);
    if (failEnroll) {
      return VoiceprintApiResult.failure(
        voiceprintApiFailure('VOICEPRINT_ENROLL_FAILED', retryable: true),
      );
    }
    lastProfileId = serverAssignedProfileId ?? request.profileId;
    return VoiceprintApiResult.success(
      VoiceprintRemoteProfile(
        profileId: lastProfileId!,
        speakerNick: request.speakerNick,
        status: VoiceprintRemoteProfileStatus.active,
        referenceVersion: 1,
        registeredAt: DateTime.utc(2026, 7, 15, 9),
        updatedAt: DateTime.utc(2026, 7, 15, 9),
      ),
    );
  }

  @override
  Future<VoiceprintApiResult<VoiceprintDeleteReceipt>> deleteProfile(
    VoiceprintDeleteRequest request,
  ) async {
    deleteRequests.add(request);
    if (deleteResults.isNotEmpty) return deleteResults.removeAt(0);
    return VoiceprintApiResult.success(
      VoiceprintDeleteReceipt(
        profileId: request.profileId,
        deletedAt: DateTime.utc(2026, 7, 15, 9),
      ),
    );
  }
}

VoiceprintRemoteProfile _remoteProfile(
  String profileId, {
  required String speakerNick,
  VoiceprintRemoteProfileStatus status = VoiceprintRemoteProfileStatus.active,
}) {
  return VoiceprintRemoteProfile(
    profileId: profileId,
    speakerNick: speakerNick,
    status: status,
    referenceVersion: 1,
    registeredAt: DateTime.utc(2026, 7, 15, 9),
    updatedAt: DateTime.utc(2026, 7, 15, 10),
  );
}
