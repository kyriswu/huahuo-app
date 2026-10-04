import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/di/media_cache_providers.dart';
import 'package:huahuoai_app/app/di/database_providers.dart';
import 'dart:async';
import 'dart:io';

import 'package:huahuoai_app/app/di/auth_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_bootstrap_controller.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/app/performance/performance_policy.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/core/device/device_identity_store.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/agent/application/mobile_agent_capability_controller.dart';
import 'package:huahuoai_app/features/ingestion/data/material_ingestion_store.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/note_file_agent_client.dart';
import 'package:huahuoai_app/features/ui_v3/data/voiceprint_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/voiceprint_profile_repository.dart';
import 'package:huahuoai_app/features/ui_v3/application/deep_positioning_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_brand_mark.dart';

void main() {
  testWidgets(
    'Canvas backing dependencies survive equivalent session refresh',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'canvas-provider-identity-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      const probe = ValueKey('canvas-provider-probe');
      await tester.pumpWidget(
        AppProviders(
          snapshotStoreFactory: () async => LocalDatabaseSnapshotStore(
            file: File('${root.path}/metadata.json'),
          ),
          deviceIdentityStore: _fixedDeviceIdentityStore(),
          runtimeClientMetadata: const RuntimeClientMetadata(
            version: '0.1.0',
            buildNumber: '1',
            platform: 'ios',
            locale: 'zh-CN',
            timeZone: 'Asia/Shanghai',
          ),
          child: const SizedBox(key: probe),
        ),
      );
      await tester.pump();
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(probe)),
        listen: false,
      );
      void restore(String workspace) {
        container
            .read(sessionStoreProvider)
            .restoreFromUserStatus(
              status: SessionUserStatus(
                user: const SessionUser(
                  userId: 'canvas-scope-user',
                  maskedPhoneNumber: '138****8000',
                ),
                workspace: SessionWorkspace(
                  status: SessionWorkspaceStatus.ready,
                  workspaceId: workspace,
                ),
              ),
              restoredAt: DateTime.utc(2026, 9, 16),
            );
      }

      restore('canvas-workspace-a');
      final notePort = container.read(knowledgeNotePortProvider);
      final folderPort = container.read(workspaceFolderPortProvider);
      final syncFactory = container.read(workspaceContentSyncFactoryProvider);
      restore('canvas-workspace-a');
      expect(container.read(knowledgeNotePortProvider), same(notePort));
      expect(container.read(workspaceFolderPortProvider), same(folderPort));
      expect(
        container.read(workspaceContentSyncFactoryProvider),
        same(syncFactory),
      );
      restore('canvas-workspace-b');
      expect(container.read(knowledgeNotePortProvider), isNot(same(notePort)));
      expect(
        container.read(workspaceFolderPortProvider),
        isNot(same(folderPort)),
      );
      expect(
        container.read(workspaceContentSyncFactoryProvider),
        isNot(same(syncFactory)),
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('report sink follows the account controller identity', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('positioning-sink-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    const probeKey = ValueKey('positioning-report-sink-probe');
    await tester.pumpWidget(
      AppProviders(
        snapshotStoreFactory: () async => LocalDatabaseSnapshotStore(
          file: File('${root.path}/metadata.json'),
        ),
        deviceIdentityStore: _fixedDeviceIdentityStore(),
        runtimeClientMetadata: const RuntimeClientMetadata(
          version: '0.1.0',
          buildNumber: '1',
          platform: 'ios',
          locale: 'zh-CN',
          timeZone: 'Asia/Shanghai',
        ),
        child: const SizedBox(key: probeKey),
      ),
    );
    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(probeKey)),
      listen: false,
    );
    final anonymousSink = container.read(initialPositioningReportSinkProvider);
    expect(
      anonymousSink,
      same(container.read(deepPositioningControllerProvider.notifier)),
    );

    container
        .read(sessionStoreProvider)
        .restoreFromUserStatus(
          status: const SessionUserStatus(
            user: SessionUser(
              userId: 'positioning-user',
              maskedPhoneNumber: '138****8000',
            ),
            workspace: SessionWorkspace(
              status: SessionWorkspaceStatus.ready,
              workspaceId: 'workspace-1',
            ),
            onboardingRequired: true,
          ),
          restoredAt: DateTime.utc(2026, 9, 8),
        );
    await tester.pump();
    final authenticatedSink = container.read(
      initialPositioningReportSinkProvider,
    );
    expect(authenticatedSink, isNot(same(anonymousSink)));
    expect(
      authenticatedSink,
      same(container.read(deepPositioningControllerProvider.notifier)),
    );
    expect(
      await authenticatedSink.saveInitialReport(
        markdown: '## 基础定位\n当前账号的定位报告。',
        savedAt: DateTime.utc(2026, 9, 8),
      ),
      isTrue,
    );
    await tester.pump();
    expect(
      container.read(initialPositioningReportSinkProvider),
      same(authenticatedSink),
    );
    expect(
      container.read(deepPositioningControllerProvider).result?.markdown,
      contains('当前账号'),
    );
  });

  test('derived projection matching rejects stale visible content', () {
    final note = V3FeedItem(
      id: 'note-1',
      title: '标题',
      source: V3MaterialSource.documentImport,
      createdAt: DateTime.utc(2026, 8, 28),
      rawBody: '原文',
      summaryBody: '新纲要',
      sproutReport: V3SproutReport(
        id: 'sprout-1',
        noteId: 'note-1',
        title: '点火',
        markdown: '新点火',
        generatedAt: DateTime.utc(2026, 8, 28),
      ),
    );

    expect(
      hasExpectedDerivedPartProjection(note, NoteFileAgentPart.outline, '新纲要'),
      isTrue,
    );
    expect(
      hasExpectedDerivedPartProjection(
        note,
        NoteFileAgentPart.germination,
        '新点火',
      ),
      isTrue,
    );
    expect(
      hasExpectedDerivedPartProjection(note, NoteFileAgentPart.outline, '旧纲要'),
      isFalse,
    );
  });

  test('runtime thought graph stays on the local test database', () {
    expect(huahuoRemoteGraphContentNavigationEnabled, isFalse);
    expect(
      resolveRuntimeGraphId(
        configuredWorkspaceId: 'diagnostic-workspace',
        sessionWorkspaceId: 'authenticated-workspace',
      ),
      isNull,
    );
  });

  test('demo auth requires debug and an explicit flag', () {
    expect(huahuoV3DemoAuthBypassEnabled, isFalse);
    expect(
      resolveHuahuoDebugOnlyFlag(isDebugBuild: true, explicitlyEnabled: true),
      isTrue,
    );
    expect(
      resolveHuahuoDebugOnlyFlag(isDebugBuild: true, explicitlyEnabled: false),
      isFalse,
    );
    expect(
      resolveHuahuoDebugOnlyFlag(isDebugBuild: false, explicitlyEnabled: true),
      isFalse,
    );
  });

  test('runtime time zone only accepts UTC or IANA identifiers', () {
    expect(resolveHuahuoUserTimeZone('Asia/Shanghai'), 'Asia/Shanghai');
    expect(resolveHuahuoUserTimeZone('CST'), 'UTC');
    expect(resolveHuahuoUserTimeZone(null), 'UTC');
    expect(isHuahuoIanaTimeZone('Asia/Shanghai'), isTrue);
    expect(isHuahuoIanaTimeZone('UTC'), isTrue);
    expect(isHuahuoIanaTimeZone('CST'), isFalse);
  });

  test('native time zone bridge only accepts IANA identifiers', () async {
    const channel = MethodChannel('huahuoai/device_timezone');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var nativeTimeZone = 'Asia/Shanghai';
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getTimeZone');
      return nativeTimeZone;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(
      await readHuahuoPlatformIanaTimeZone(channel: channel),
      'Asia/Shanghai',
    );

    nativeTimeZone = 'CST';
    expect(await readHuahuoPlatformIanaTimeZone(channel: channel), isNull);
  });

  test('runtime metadata bounds optional native dependencies', () async {
    final stuckTimeZone = Completer<String?>();
    final stuckPackage = Completer<RuntimePackageMetadata>();

    final fallback = await resolveRuntimeClientMetadata(
      readNativeTimeZone: () => stuckTimeZone.future,
      readPackageMetadata: () => stuckPackage.future,
      dartTimeZoneName: 'CST',
      platform: 'ios',
      locale: 'zh-CN',
      timeout: const Duration(milliseconds: 1),
      fallbackVersion: 'fallback-version',
      fallbackBuildNumber: 'fallback-build',
    );

    expect(fallback.version, 'fallback-version');
    expect(fallback.buildNumber, 'fallback-build');
    expect(fallback.timeZone, 'UTC');
    expect(fallback.timeZoneIsFallback, isTrue);

    final resolved = await resolveRuntimeClientMetadata(
      readNativeTimeZone: () async => 'Asia/Shanghai',
      readPackageMetadata: () async =>
          const RuntimePackageMetadata(version: '3.1.4', buildNumber: '159'),
      dartTimeZoneName: 'CST',
      platform: 'android',
      locale: 'zh-CN',
    );
    expect(resolved.clientVersion, '3.1.4+159');
    expect(resolved.timeZone, 'Asia/Shanghai');
    expect(resolved.timeZoneIsFallback, isFalse);
  });

  test('release API configuration requires an explicit HTTPS URL', () {
    expect(
      () => resolveHuahuoApiBaseUrl(isDebugBuild: false, configuredValue: ''),
      throwsA(isA<StateError>()),
    );
    expect(
      () => resolveHuahuoApiBaseUrl(
        isDebugBuild: false,
        configuredValue: 'http://api.example.com',
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      resolveHuahuoApiBaseUrl(
        isDebugBuild: false,
        configuredValue: 'https://api.example.com',
      ).toString(),
      'https://api.example.com',
    );
  });

  test('recording API requires a clean HTTPS origin', () {
    expect(
      resolveRecordingApiBaseUrl(
        configuredValue: 'https://recording.chuda.cc',
      ).toString(),
      'https://recording.chuda.cc',
    );
    expect(
      resolveRecordingApiBaseUrl(
        configuredValue: 'https://recordings.example.com',
      ).toString(),
      'https://recordings.example.com',
    );
    for (final value in <String>[
      '',
      'http://101.201.70.18',
      'http://101.201.70.18:18080',
      'http://39.107.250.25',
      'http://101.201.70.18.evil.test',
      'http://user@101.201.70.18',
      'http://101.201.70.18/proxy',
      'http://101.201.70.18?token=secret',
    ]) {
      expect(
        () => resolveRecordingApiBaseUrl(configuredValue: value),
        throwsA(isA<StateError>()),
        reason: value,
      );
    }
  });

  test(
    'internal recording provider survives upload state notifications',
    () async {
      final database = AppDatabase();
      final apiClient = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: _testDeviceId,
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => null,
        ),
        transport: _QueueTransport(responses: const <ApiTransportResponse>[]),
      );
      final uploadController = RecordingUploadController(
        uploadClient: UploadClient(
          apiClient: apiClient,
          objectTransport: const _UnusedObjectUploadTransport(),
        ),
        draftStore: UploadDraftStore(database: database),
        recordingApi: RecordingApi(apiClient: apiClient),
        localRecordingRepository: LocalRecordingRepository(
          database: database,
          fileStorage: const UnavailableFileStoragePort(),
        ),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          recordingUploadControllerProvider.overrideWith(
            (ref) => uploadController,
          ),
        ],
      );
      addTearDown(container.dispose);

      final before = container.read(internalRecordingControllerProvider);
      final result = await uploadController.uploadPrivateAudio(
        input: RecordingPrivateAudioInput(
          jobId: 'invalid-internal-job',
          localFileId: 'invalid-internal-file',
          appPrivateUri: '',
          fileName: '',
          mimeType: 'application/octet-stream',
          sizeBytes: 0,
          durationSeconds: 0,
          contentHash: 'invalid',
          recordedAt: DateTime.utc(2026, 9, 3),
          title: 'invalid',
        ),
        fileSource: RecordingFileSource.internalRecording,
      );

      expect(result, isNull);
      expect(
        uploadController.state.lastErrorCode,
        'RECORDING_UPLOAD_NOT_READY',
      );
      expect(container.read(internalRecordingControllerProvider), same(before));
    },
  );

  test('live ASR origin prefers its define then the recording origin', () {
    final recordingBaseUrl = Uri.parse('https://chuda.cc');

    expect(
      resolveLiveTranscriptionBackendBaseUrl(
        configuredValue: 'https://asr.example.com',
        recordingApiBaseUrl: recordingBaseUrl,
      ).toString(),
      'https://asr.example.com',
    );
    expect(
      resolveLiveTranscriptionBackendBaseUrl(
        configuredValue: '',
        recordingApiBaseUrl: recordingBaseUrl,
      ),
      recordingBaseUrl,
    );
  });

  test(
    'unconfigured debug API fails closed without public network access',
    () async {
      final container = ProviderContainer(
        overrides: [resolvedDeviceIdProvider.overrideWithValue(_testDeviceId)],
      );
      addTearDown(container.dispose);

      final client = container.read(apiClientProvider);
      final recordingClient = container.read(recordingApiClientProvider);
      final authController = container.read(authControllerProvider);
      final voiceGatewayBaseUrl = container.read(voiceGatewayBaseUrlProvider);
      final liveBackendBaseUrl = container.read(
        liveTranscriptionBackendBaseUrlProvider,
      );
      final liveCredentialApi =
          container.read(liveTranscriptionCredentialProvider)
              as LiveTranscriptionApi;

      expect(
        client.config.baseUrl.toString(),
        'https://api.unconfigured.invalid',
      );
      expect(recordingClient.config.baseUrl.toString(), 'https://chuda.cc');
      expect(
        voiceGatewayBaseUrl.toString(),
        'https://api.unconfigured.invalid/voice-gateway/',
      );
      expect(liveBackendBaseUrl.toString(), 'https://chuda.cc');
      expect(liveCredentialApi.apiClient, same(recordingClient));
      expect(liveCredentialApi.apiClient.config.onAuthExpired, isNull);
      expect(liveCredentialApi.apiClient.config.refreshAccessToken, isNull);
      expect(client.config.onAuthExpired, isNotNull);
      expect(client.config.refreshAccessToken, isNotNull);
      expect(client.transport, isA<UnconfiguredApiTransport>());
      expect(recordingClient.transport, same(client.transport));
      final unavailable = await client.transport.send(
        ApiTransportRequest(
          url: client.config.baseUrl,
          method: 'GET',
          headers: const <String, String>{'X-Trace-Id': 'trace-unconfigured'},
        ),
      );
      expect(unavailable.status, HttpStatus.serviceUnavailable);
      expect(
        (unavailable.body! as Map<String, Object?>)['error'],
        containsPair('code', 'API_BASE_URL_UNCONFIGURED'),
      );
      expect(client.config.deviceId, _testDeviceId);
      expect(client.config.deviceId, isNot('flutter-device'));
      expect(authController.configuredDeviceId, client.config.deviceId);
      expect(client.config.platform, anyOf('ios', 'android'));
      expect(client.config.timeZone, isNotEmpty);
    },
  );

  test(
    'local numeric marker is never exposed as an API bearer token',
    () async {
      final driver = _FakeSecureTokenDriver();
      final container = ProviderContainer(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue(_testDeviceId),
          secureTokenDriverProvider.overrideWithValue(driver),
        ],
      );
      addTearDown(container.dispose);

      final tokenStore = container.read(secureTokenStoreProvider);
      final writeResult = await tokenStore.setTokens(localNumericAuthTokens);
      expect(writeResult.ok, isTrue);
      final sessionStore = container.read(sessionStoreProvider);
      sessionStore.restoreFromUserStatus(
        status: localNumericAuthUserStatus(),
        restoredAt: DateTime.utc(2026, 7, 28),
      );
      final config = container.read(apiClientProvider).config;

      expect(await config.getAccessToken?.call(), isNull);
      await config.onAuthExpired?.call(
        const AppFailure(
          code: 'UNAUTHORIZED',
          category: AppFailureCategory.auth,
          message: 'unauthorized',
          userMessageKey: 'auth.expired',
        ),
      );

      expect(sessionStore.state.authState, SessionAuthState.authenticated);
      expect(driver.credential, isNotNull);
    },
  );

  test('apiClientProvider rejects an unresolved device identity', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      () => container.read(apiClientProvider),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'DEVICE_IDENTITY_NOT_RESOLVED',
        ),
      ),
    );
  });

  test(
    'image cache observes scope identity rather than session notifications',
    () async {
      final session = SessionStore(
        secureTokenStore: SecureTokenStore(driver: _FakeSecureTokenDriver()),
      );
      void restore(String userId, String workspaceId) {
        session.restoreFromUserStatus(
          status: SessionUserStatus(
            user: SessionUser(userId: userId, maskedPhoneNumber: '138****8000'),
            workspace: SessionWorkspace(
              status: SessionWorkspaceStatus.ready,
              workspaceId: workspaceId,
            ),
          ),
          restoredAt: DateTime.utc(2026, 9, 11),
        );
      }

      restore('image-user-a', 'image-workspace-a');
      final container = ProviderContainer(
        overrides: [
          sessionStoreProvider.overrideWith((ref) => session),
          resolvedDeviceIdProvider.overrideWithValue('image-cache-test'),
        ],
      );
      addTearDown(container.dispose);
      container.listen(resourceImageCacheProvider, (_, __) {});
      final initial = container.read(resourceImageCacheProvider);
      restore('image-user-a', 'image-workspace-a');
      expect(container.read(resourceImageCacheProvider), same(initial));
      restore('image-user-a', 'image-workspace-b');
      final otherWorkspace = container.read(resourceImageCacheProvider);
      expect(otherWorkspace, isNot(same(initial)));
      await expectLater(
        initial.load('resource'),
        throwsA(
          predicate<Object>(
            (error) =>
                error.toString().contains('RESOURCE_IMAGE_CACHE_DISPOSED'),
          ),
        ),
      );
      restore('image-user-b', 'image-workspace-b');
      expect(
        container.read(resourceImageCacheProvider),
        isNot(same(otherWorkspace)),
      );
      await expectLater(
        otherWorkspace.load('resource'),
        throwsA(
          predicate<Object>(
            (error) =>
                error.toString().contains('RESOURCE_IMAGE_CACHE_DISPOSED'),
          ),
        ),
      );
    },
  );

  test('account and workspace changes invalidate private data scopes', () {
    final session = SessionStore(
      secureTokenStore: SecureTokenStore(driver: _FakeSecureTokenDriver()),
    );
    final container = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWith((ref) => session),
        knowledgeLibraryCacheScopeProvider.overrideWith((ref) {
          return knowledgeLibraryWorkspaceCacheScope(
            ref.watch(authenticatedUserDataScopeProvider),
            ref.watch(sessionStoreProvider).state,
          );
        }),
        materialIngestionOwnerScopeProvider.overrideWith((ref) {
          return knowledgeLibraryWorkspaceCacheScope(
            ref.watch(authenticatedUserDataScopeProvider),
            ref.watch(sessionStoreProvider).state,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final scopeEvents = <String>[];
    final materialScopeEvents = <String>[];
    container.listen<String>(
      authenticatedUserDataScopeProvider,
      (_, next) => scopeEvents.add(next),
      fireImmediately: true,
    );
    container.listen<String>(
      materialIngestionOwnerScopeProvider,
      (_, next) => materialScopeEvents.add(next),
      fireImmediately: true,
    );

    expect(container.read(knowledgeLibraryCacheScopeProvider), 'anonymous');
    expect(container.read(materialIngestionOwnerScopeProvider), 'anonymous');

    session.restoreFromUserStatus(
      status: const SessionUserStatus(
        user: SessionUser(userId: 'user-a', maskedPhoneNumber: '138****8000'),
        workspace: SessionWorkspace(
          status: SessionWorkspaceStatus.ready,
          workspaceId: 'workspace-a',
        ),
      ),
      restoredAt: DateTime.utc(2026, 7, 14),
    );

    expect(
      container.read(knowledgeLibraryCacheScopeProvider),
      'user-a\u0000workspace-a',
    );
    expect(
      container.read(materialIngestionOwnerScopeProvider),
      'user-a\u0000workspace-a',
    );

    session.restoreFromUserStatus(
      status: const SessionUserStatus(
        user: SessionUser(userId: 'user-a', maskedPhoneNumber: '138****8000'),
        workspace: SessionWorkspace(
          status: SessionWorkspaceStatus.ready,
          workspaceId: 'workspace-b',
        ),
      ),
      restoredAt: DateTime.utc(2026, 7, 15),
    );

    expect(
      container.read(knowledgeLibraryCacheScopeProvider),
      'user-a\u0000workspace-b',
    );
    expect(
      container.read(materialIngestionOwnerScopeProvider),
      'user-a\u0000workspace-b',
    );
    expect(scopeEvents, <String>['anonymous', 'user-a']);
    expect(materialScopeEvents, <String>[
      'anonymous',
      'user-a\u0000workspace-a',
      'user-a\u0000workspace-b',
    ]);
  });

  test('document import provider survives knowledge content notifications', () {
    final library = KnowledgeLibraryController();
    final container = ProviderContainer(
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith((ref) => library),
      ],
    );
    addTearDown(container.dispose);

    final importController = container.read(v3DocumentImportControllerProvider);
    final note = library.notes.first;
    library.updateNote(note.copyWith(title: '${note.title} updated'));

    expect(
      identical(
        container.read(v3DocumentImportControllerProvider),
        importController,
      ),
      isTrue,
    );
  });

  test(
    'mobile Agent identity ignores a same-binding session profile refresh',
    () {
      final session = SessionStore(
        secureTokenStore: SecureTokenStore(driver: _FakeSecureTokenDriver()),
      );
      session.restoreFromUserStatus(
        status: const SessionUserStatus(
          user: SessionUser(
            userId: 'user-agent-binding',
            maskedPhoneNumber: '138****8000',
            displayName: '初始名称',
          ),
          workspace: SessionWorkspace(
            status: SessionWorkspaceStatus.ready,
            workspaceId: 'workspace-agent-binding',
          ),
        ),
        restoredAt: DateTime.utc(2026, 8, 18, 10),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          sessionStoreProvider.overrideWith((ref) => session),
        ],
      );
      addTearDown(container.dispose);
      final bindings = <String>[];
      container.listen<MobileAgentRuntimeIdentity>(
        mobileAgentRuntimeIdentityProvider,
        (_, next) => bindings.add(next.bindingKey),
        fireImmediately: true,
      );

      session.restoreFromUserStatus(
        status: const SessionUserStatus(
          user: SessionUser(
            userId: 'user-agent-binding',
            maskedPhoneNumber: '138****8000',
            displayName: '同步后的名称',
          ),
          workspace: SessionWorkspace(
            status: SessionWorkspaceStatus.ready,
            workspaceId: 'workspace-agent-binding',
          ),
        ),
        restoredAt: DateTime.utc(2026, 8, 18, 10, 1),
      );

      expect(bindings, <String>[
        'user-agent-binding\u0000workspace-agent-binding\u0000false',
      ]);
    },
  );

  test('chat API survives Mobile Agent capability notifications', () async {
    final container = ProviderContainer(
      overrides: [resolvedDeviceIdProvider.overrideWithValue(_testDeviceId)],
    );
    addTearDown(container.dispose);

    final chatApi = container.read(chatRepositoryProvider);
    final capability = container.read(
      mobileAgentCapabilityControllerProvider.notifier,
    );

    await capability.ensureFeature('test.provider-stability');

    expect(identical(container.read(chatRepositoryProvider), chatApi), isTrue);
  });

  test(
    'voiceprint sync service coalesces requests and preserves local data on failure',
    () async {
      final database = AppDatabase();
      final dao = UserMetadataDao(database)
        ..upsertVoiceprintProfile(
          userScope: 'voice-sync-user',
          profileId: 'vp-local',
          name: '本地名称',
          enrolledAt: '2026-07-20T09:00:00.000Z',
          updatedAt: '2026-07-20T09:00:00.000Z',
          isDemo: false,
        );
      final repository = VoiceprintProfileRepository(
        dao: dao,
        userScope: 'voice-sync-user',
      );
      final firstResponse =
          Completer<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>();
      final api = _VoiceprintSyncApi(
        <Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>>[
          firstResponse.future,
          Future.value(
            VoiceprintApiResult.failure(
              voiceprintApiFailure('NETWORK_REQUEST_FAILED', retryable: true),
            ),
          ),
        ],
      );
      final service = VoiceprintProfileSyncService(
        api: api,
        repository: repository,
      );

      final first = service.sync();
      final duplicate = service.sync();
      expect(identical(first, duplicate), isTrue);
      expect(api.listCalls, 1);
      firstResponse.complete(
        VoiceprintApiResult.success(<VoiceprintRemoteProfile>[
          VoiceprintRemoteProfile(
            profileId: 'vp-local',
            speakerNick: 'vpr-opaque-local',
            status: VoiceprintRemoteProfileStatus.active,
            referenceVersion: 2,
            registeredAt: DateTime.utc(2026, 7, 20, 9),
            updatedAt: DateTime.utc(2026, 7, 24, 9),
          ),
          VoiceprintRemoteProfile(
            profileId: 'vp-restored',
            speakerNick: 'vpr-opaque-restored',
            status: VoiceprintRemoteProfileStatus.active,
            referenceVersion: 1,
            registeredAt: DateTime.utc(2026, 7, 24, 8),
            updatedAt: DateTime.utc(2026, 7, 24, 8),
          ),
        ]),
      );
      expect(await first, isTrue);
      expect(repository.loadProfiles(), hasLength(2));
      expect(
        repository
            .loadProfiles()
            .singleWhere((profile) => profile.id == 'vp-local')
            .name,
        '本地名称',
      );
      expect(
        repository.loadProfiles().map((profile) => profile.name),
        isNot(contains('vpr-opaque-restored')),
      );

      expect(await service.sync(), isFalse);
      expect(api.listCalls, 2);
      expect(repository.loadProfiles(), hasLength(2));
    },
  );

  test('voiceprint sync provider is recreated for an account change', () {
    final session =
        SessionStore(
          secureTokenStore: SecureTokenStore(driver: _FakeSecureTokenDriver()),
        )..refreshUserStatus(
          status: const SessionUserStatus(
            user: SessionUser(
              userId: 'voice-user-a',
              maskedPhoneNumber: '138****8000',
            ),
            workspace: SessionWorkspace(status: SessionWorkspaceStatus.ready),
          ),
          updatedAt: DateTime.utc(2026, 7, 24),
        );
    final container = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWith((ref) => session),
        voiceprintApiProvider.overrideWithValue(_VoiceprintSyncApi(const [])),
      ],
    );
    addTearDown(container.dispose);

    final first = container.read(voiceprintProfileSyncServiceProvider);
    session.refreshUserStatus(
      status: const SessionUserStatus(
        user: SessionUser(
          userId: 'voice-user-b',
          maskedPhoneNumber: '139****9000',
        ),
        workspace: SessionWorkspace(status: SessionWorkspaceStatus.ready),
      ),
      updatedAt: DateTime.utc(2026, 7, 24, 1),
    );

    expect(
      identical(container.read(voiceprintProfileSyncServiceProvider), first),
      isFalse,
    );
  });

  test(
    'recording-card binding provider survives hardware state notifications',
    () async {
      final hardwareController = RecordingCardController(
        port: const UnavailableRecordingCardPort(),
        localRecordingRepository: LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: const UnavailableFileStoragePort(),
        ),
        platformPermissionsPort: const MethodChannelPlatformPermissionsPort(),
      );
      final container = ProviderContainer(
        overrides: [
          recordingCardControllerProvider.overrideWith(
            (ref) => hardwareController,
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        recordingCardCloudBindingControllerProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final bindingController = container.read(
        recordingCardCloudBindingControllerProvider,
      );
      await hardwareController.connect();
      await Future<void>.delayed(Duration.zero);

      expect(
        identical(
          container.read(recordingCardCloudBindingControllerProvider),
          bindingController,
        ),
        isTrue,
      );
    },
  );

  test(
    'app bootstrap provider restores an anonymous session after setup',
    () async {
      final container = ProviderContainer(
        overrides: [
          secureTokenDriverProvider.overrideWith(
            (ref) => _FakeSecureTokenDriver(),
          ),
          resolvedDeviceIdProvider.overrideWithValue(_testDeviceId),
        ],
      );
      addTearDown(container.dispose);

      final bootstrap = container.read(appBootstrapControllerProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(bootstrap.state.status, AppBootstrapStatus.ready);
      expect(
        identical(container.read(appBootstrapControllerProvider), bootstrap),
        isTrue,
      );
      expect(
        container.read(sessionStoreProvider).state.authState,
        SessionAuthState.anonymous,
      );
    },
  );

  test(
    'cold bootstrap refreshes before an explicit bearer can expire',
    () async {
      final driver = _FakeSecureTokenDriver(
        credential: const SecureTokenCredential(
          username: SecureTokenStore.tokenUsername,
          password: '{"accessToken":"old-access","refreshToken":"old-refresh"}',
        ),
      );
      final transport = _QueueTransport(
        responses: const [
          ApiTransportResponse(
            status: 401,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{'code': 'AUTH_SESSION_EXPIRED'},
            },
          ),
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'accessToken': 'rotated-access',
                'refreshToken': 'rotated-refresh',
                'tokenType': 'Bearer',
                'expiresIn': 7200,
                'rotated': true,
              },
            },
          ),
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'user': <String, Object?>{
                  'userId': 'user-1',
                  'phoneMasked': '138****8000',
                },
                'workspace': <String, Object?>{
                  'workspaceId': 'workspace-1',
                  'status': 'ready',
                },
                'runningTaskCount': 0,
                'onboardingRequired': false,
                'basicPositioningCompleted': true,
                'timeZone': 'UTC',
              },
            },
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          secureTokenDriverProvider.overrideWith((ref) => driver),
          apiTransportProvider.overrideWith((ref) => transport),
          resolvedDeviceIdProvider.overrideWithValue(_testDeviceId),
          runtimeClientMetadataProvider.overrideWithValue(
            const RuntimeClientMetadata(
              version: '0.1.0',
              buildNumber: '1',
              platform: 'ios',
              locale: 'zh-CN',
              timeZone: 'UTC',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final bootstrap = container.read(appBootstrapControllerProvider);
      for (
        var attempt = 0;
        attempt < 20 && bootstrap.state.status != AppBootstrapStatus.ready;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(bootstrap.state.status, AppBootstrapStatus.ready);
      expect(
        container.read(sessionStoreProvider).state.authState,
        SessionAuthState.authenticated,
      );
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/me/status',
        '/api/v1/auth/refresh',
        '/api/v1/me/status',
      ]);
      expect(
        transport.requests.map((request) => request.headers['Authorization']),
        <String?>['Bearer old-access', null, 'Bearer rotated-access'],
      );
    },
  );

  test(
    'apiClientProvider expires an active session after explicit main-site expiry',
    () async {
      final driver = _FakeSecureTokenDriver(
        credential: const SecureTokenCredential(
          username: SecureTokenStore.tokenUsername,
          password: '{"accessToken":"access","refreshToken":"refresh"}',
        ),
      );
      final transport = _QueueTransport(
        responses: const [
          ApiTransportResponse(
            status: 401,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{'code': 'AUTH_SESSION_EXPIRED'},
            },
          ),
          ApiTransportResponse(
            status: 401,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{'code': 'TOKEN_EXPIRED'},
            },
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          secureTokenDriverProvider.overrideWith((ref) => driver),
          apiTransportProvider.overrideWith((ref) => transport),
          resolvedDeviceIdProvider.overrideWithValue(_testDeviceId),
        ],
      );
      addTearDown(container.dispose);

      final sessionStore = container.read(sessionStoreProvider);
      sessionStore.restoreFromUserStatus(
        status: const SessionUserStatus(
          user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
          workspace: SessionWorkspace(
            status: SessionWorkspaceStatus.ready,
            workspaceId: 'workspace-1',
          ),
        ),
        restoredAt: DateTime.utc(2026, 8, 8),
      );
      final result = await container
          .read(apiClientProvider)
          .request<int>(
            ApiRequestOptions<int>(endpointId: 'meStatus', parseData: (_) => 1),
          );

      expect(result.ok, isFalse);
      expect(result.authExpired, isTrue);
      expect(transport.requests, hasLength(2));
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/me/status',
        '/api/v1/auth/refresh',
      ]);
      expect(
        await container.read(secureTokenStoreProvider).getTokens(),
        isA<SecureTokenResult<AuthTokens?>>().having(
          (result) => result.value,
          'stored tokens',
          isNull,
        ),
      );
      expect(sessionStore.state.authState, SessionAuthState.expired);
      expect(sessionStore.selectRoute().type, SessionRouteType.auth);
    },
  );

  test(
    'apiClientProvider persists rotation and replays with new bearer',
    () async {
      final driver = _FakeSecureTokenDriver(
        credential: const SecureTokenCredential(
          username: SecureTokenStore.tokenUsername,
          password: '{"accessToken":"old-access","refreshToken":"old-refresh"}',
        ),
      );
      final transport = _QueueTransport(
        responses: const [
          ApiTransportResponse(
            status: 401,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{'code': 'UNAUTHORIZED'},
            },
          ),
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'accessToken': 'rotated-access',
                'refreshToken': 'rotated-refresh',
                'tokenType': 'Bearer',
                'expiresIn': 7200,
                'rotated': true,
              },
            },
          ),
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{'count': 1},
            },
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          secureTokenDriverProvider.overrideWith((ref) => driver),
          apiTransportProvider.overrideWith((ref) => transport),
          resolvedDeviceIdProvider.overrideWithValue(_testDeviceId),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(apiClientProvider)
          .request<int>(
            ApiRequestOptions<int>(
              endpointId: 'meStatus',
              parseData: (value) =>
                  (value as Map<String, Object?>)['count'] as int?,
            ),
          );

      expect(result.ok, isTrue);
      expect(result.data, 1);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/me/status',
        '/api/v1/auth/refresh',
        '/api/v1/me/status',
      ]);
      expect(
        transport.requests.map((request) => request.headers['Authorization']),
        <String?>['Bearer old-access', null, 'Bearer rotated-access'],
      );
      final stored = await container.read(secureTokenStoreProvider).getTokens();
      expect(stored.value?.accessToken, 'rotated-access');
      expect(stored.value?.refreshToken, 'rotated-refresh');
    },
  );

  test('recording origin 401 does not expire the main session', () async {
    final driver = _FakeSecureTokenDriver(
      credential: const SecureTokenCredential(
        username: SecureTokenStore.tokenUsername,
        password: '{"accessToken":"access","refreshToken":"refresh"}',
      ),
    );
    final transport = _QueueTransport(
      responses: [
        const ApiTransportResponse(
          status: 401,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{'code': 'UNAUTHORIZED'},
          },
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        secureTokenDriverProvider.overrideWith((ref) => driver),
        apiTransportProvider.overrideWith((ref) => transport),
        resolvedDeviceIdProvider.overrideWithValue(_testDeviceId),
      ],
    );
    addTearDown(container.dispose);

    final sessionStore = container.read(sessionStoreProvider);
    sessionStore.restoreFromUserStatus(
      status: const SessionUserStatus(
        user: SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
        workspace: SessionWorkspace(
          status: SessionWorkspaceStatus.ready,
          workspaceId: 'workspace-1',
        ),
      ),
      restoredAt: DateTime.utc(2026, 8, 1),
    );

    final client = container.read(recordingApiClientProvider);
    final result = await client.request<int>(
      ApiRequestOptions<int>(endpointId: 'recordings', parseData: (_) => 1),
    );

    expect(result.ok, isFalse);
    expect(result.authExpired, isFalse);
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.headers['Authorization'], 'Bearer access');
    expect(driver.credential, isNotNull);
    expect(sessionStore.state.authState, SessionAuthState.authenticated);
    expect(sessionStore.state.lastAuthErrorCode, isNull);
    expect(sessionStore.selectRoute().type, SessionRouteType.v3);
  });

  test(
    'appDatabaseProvider can recover metadata through snapshot override',
    () async {
      final root = await Directory.systemTemp.createTemp('huahuo-provider-db-');
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      final snapshot = LocalDatabaseSnapshotStore(
        file: File('${root.path}/local-recording-metadata.json'),
        backend: LocalDatabaseSnapshotBackend.json,
      );
      final first = ProviderContainer(
        overrides: [
          localDatabaseSnapshotStoreProvider.overrideWithValue(snapshot),
        ],
      );
      expect(first.read(appDatabaseProvider).usesWorkerPersistence, isFalse);

      first.read(appDatabaseProvider).upsertRecord(
        LocalTableName.localRecordings,
        'recording-1',
        <String, Object?>{
          'recording_id': 'recording-1',
          'source': 'localImport',
          'status': 'localOnly',
          'format': 'm4a',
          'local_file_state': 'ready',
          'app_private_uri': 'app-private://recordings/local-a/source.m4a',
          'display_name': 'Meeting.m4a',
          'duration_seconds': 90,
          'size_bytes': 2048,
          'is_favorite': false,
          'tag_ids': const <String>[],
          'created_at': '2026-07-01T09:00:00.000Z',
          'updated_at': '2026-07-01T09:00:00.000Z',
        },
      );
      first.dispose();

      final second = ProviderContainer(
        overrides: [
          localDatabaseSnapshotStoreProvider.overrideWithValue(snapshot),
        ],
      );
      addTearDown(second.dispose);

      expect(
        second
            .read(appDatabaseProvider)
            .getRecord<LocalDatabaseRecord>(
              LocalTableName.localRecordings,
              'recording-1',
            )?['display_name'],
        'Meeting.m4a',
      );
    },
  );

  test(
    'SQLite provider uses worker unless rollback flag is disabled',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-provider-worker-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshot = LocalDatabaseSnapshotStore(
        file: File('${root.path}/local.sqlite'),
        backend: LocalDatabaseSnapshotBackend.sqlite,
      );
      final enabled = ProviderContainer(
        overrides: <Override>[
          localDatabaseSnapshotStoreProvider.overrideWithValue(snapshot),
        ],
      );
      addTearDown(enabled.dispose);
      expect(enabled.read(appDatabaseProvider).usesWorkerPersistence, isTrue);
      expect(enabled.read(databaseWorkerRuntimeProvider).configured, isTrue);

      final disabled = ProviderContainer(
        overrides: <Override>[
          localDatabaseSnapshotStoreProvider.overrideWithValue(snapshot),
          performanceFeatureFlagsProvider.overrideWithValue(
            const PerformanceFeatureFlags(databaseWorkerEnabled: false),
          ),
        ],
      );
      addTearDown(disabled.dispose);
      expect(disabled.read(appDatabaseProvider).usesWorkerPersistence, isFalse);
      expect(disabled.read(databaseWorkerRuntimeProvider).configured, isFalse);
    },
  );

  testWidgets('AppProviders times out stuck snapshot bootstrap', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      AppProviders(
        snapshotStoreFactory: () {
          attempts += 1;
          return Completer<LocalDatabaseSnapshotStore>().future;
        },
        snapshotStoreTimeout: const Duration(milliseconds: 1),
        deviceIdentityStore: _fixedDeviceIdentityStore(),
        runtimeClientMetadata: const RuntimeClientMetadata(
          version: '0.1.0',
          buildNumber: '1',
          platform: 'android',
          locale: 'zh-CN',
          timeZone: 'Asia/Shanghai',
        ),
        child: const SizedBox.shrink(),
      ),
    );

    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();

    expect(find.text('初始化失败'), findsOneWidget);
    expect(find.text('LOCAL_DATABASE_INIT_TIMEOUT'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('初始化失败'), findsNothing);

    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();
    expect(find.text('LOCAL_DATABASE_INIT_TIMEOUT'), findsOneWidget);
  });

  testWidgets('AppProviders dependency wait keeps the static launch identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppProviders(
        snapshotStoreFactory: () =>
            Completer<LocalDatabaseSnapshotStore>().future,
        snapshotStoreTimeout: const Duration(milliseconds: 1),
        deviceIdentityStore: _fixedDeviceIdentityStore(),
        runtimeClientMetadata: const RuntimeClientMetadata(
          version: '0.1.0',
          buildNumber: '1',
          platform: 'ios',
          locale: 'zh-CN',
          timeZone: 'Asia/Shanghai',
        ),
        child: const SizedBox.shrink(),
      ),
    );

    expect(find.text('无限花火'), findsNothing);
    expect(find.text('正在初始化'), findsNothing);
    expect(find.text('正在准备无限花火'), findsNothing);
    final lockup = tester.widget<Image>(find.byType(Image));
    expect(
      (lockup.image as AssetImage).assetName,
      V3LaunchBrandLockup.androidAssetPath,
    );
    expect(lockup.width, V3LaunchBrandLockup.markDimension);
    expect(lockup.height, V3LaunchBrandLockup.lockupHeight);

    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();
    expect(find.text('初始化失败'), findsOneWidget);
  });

  testWidgets(
    'AppProviders exposes resolved device identity to startup children',
    (tester) async {
      const secureStorageChannel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(
        () => messenger.setMockMethodCallHandler(secureStorageChannel, null),
      );
      messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
        return switch (call.method) {
          'read' => null,
          'readAll' => const <String, String>{},
          'containsKey' => false,
          'write' || 'delete' || 'deleteAll' => true,
          _ => null,
        };
      });
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('huahuo-provider-bootstrap-'),
      );
      if (root == null) {
        throw StateError('TEST_TEMP_DIRECTORY_UNAVAILABLE');
      }
      addTearDown(() async {
        await tester.runAsync(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });
      });
      final snapshot = LocalDatabaseSnapshotStore(
        file: File('${root.path}/local-recording-metadata.json'),
        backend: LocalDatabaseSnapshotBackend.json,
      );

      await tester.pumpWidget(
        AppProviders(
          snapshotStoreFactory: () async => snapshot,
          deviceIdentityStore: _fixedDeviceIdentityStore(),
          runtimeClientMetadata: const RuntimeClientMetadata(
            version: '0.1.0',
            buildNumber: '1',
            platform: 'android',
            locale: 'zh-CN',
            timeZone: 'Asia/Shanghai',
          ),
          child: const _StartupProviderProbe(),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text(_testDeviceId), findsOneWidget);
    },
  );
}

const _testDeviceId = 'flutter-test-device-000001';

DeviceIdentityStore _fixedDeviceIdentityStore() {
  return DeviceIdentityStore(
    driver: _FakeDeviceIdentityDriver(),
    generateDeviceId: () => _testDeviceId,
  );
}

final class _QueueTransport implements ApiTransport {
  _QueueTransport({required List<ApiTransportResponse> responses})
    : _responses = List<ApiTransportResponse>.from(responses);

  final List<ApiTransportResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}

final class _UnusedObjectUploadTransport implements ObjectUploadTransport {
  const _UnusedObjectUploadTransport();

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) {
    throw StateError('unexpected object upload');
  }
}

final class _VoiceprintSyncApi implements VoiceprintApiPort {
  _VoiceprintSyncApi(
    List<Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>> responses,
  ) : _responses = List.of(responses);

  final List<Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>>
  _responses;
  int listCalls = 0;

  @override
  Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>> listProfiles() {
    listCalls += 1;
    if (_responses.isEmpty) {
      return Future.value(
        VoiceprintApiResult.success(const <VoiceprintRemoteProfile>[]),
      );
    }
    return _responses.removeAt(0);
  }

  @override
  Future<VoiceprintApiResult<VoiceprintRemoteProfile>> enroll(
    VoiceprintEnrollRequest request,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<VoiceprintApiResult<VoiceprintDeleteReceipt>> deleteProfile(
    VoiceprintDeleteRequest request,
  ) {
    throw UnimplementedError();
  }
}

final class _FakeSecureTokenDriver implements SecureTokenDriver {
  _FakeSecureTokenDriver({this.credential});

  SecureTokenCredential? credential;

  @override
  SecureTokenCredential? read({required String service}) => credential;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) {
    credential = SecureTokenCredential(username: username, password: password);
    return true;
  }

  @override
  bool clear({required String service}) {
    credential = null;
    return true;
  }
}

final class _FakeDeviceIdentityDriver implements DeviceIdentityDriver {
  String? value;

  @override
  String? read({required String key}) => value;

  @override
  bool write({required String key, required String value}) {
    this.value = value;
    return true;
  }
}

class _StartupProviderProbe extends ConsumerWidget {
  const _StartupProviderProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(apiClientProvider);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(client.config.deviceId),
    );
  }
}
