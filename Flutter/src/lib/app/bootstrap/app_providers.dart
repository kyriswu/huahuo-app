import 'package:huahuoai_app/app/di/account_usage_providers.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../di/auth_providers.dart';
import '../di/native_port_providers.dart';
import '../../features/ingestion/data/internal_recording_session_store.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/api/api_client.dart';
import '../../core/api/scoped_read_cache.dart';
import '../../core/api/upload_client.dart';
import '../../core/auth/session_store.dart';
import '../../core/database/app_database.dart';
import '../../core/database/app_preferences_dao.dart';
import '../../core/database/creation_canvas_history_dao.dart';
import '../../core/database/creation_canvas_draft_dao.dart';
import '../../core/database/diagnostic_log_dao.dart';
import '../../core/database/profile_workspace_dao.dart';
import '../../core/database/recording_dao.dart';
import '../../core/database/user_metadata_dao.dart';
import '../../core/database/v3_deposit_dao.dart';
import '../../core/device/device_identity_store.dart';
import '../../core/diagnostics/diagnostic_export_service.dart';
import '../../core/diagnostics/diagnostic_logger.dart';
import '../../core/native/native_playback_port.dart';
import '../../core/native/recording_card_native_port.dart';
import '../../core/native/voice_recorder_port.dart';
import '../../core/storage/file_storage_port.dart';
import '../../core/storage/private_media_path_resolver.dart';
import '../../core/storage/private_recording_path_resolver.dart';
import '../../core/storage/upload_draft_store.dart';
import '../../shared/ui_v3/v3_brand_mark.dart';
import '../../features/backend_contracts/data/backend_contract_api.dart';
import '../../features/billing/data/account_usage_repository.dart';
import '../../features/book_work/application/mobile_book_work_controller.dart';
import '../../features/book_work/data/mobile_book_work_port.dart';
import '../../features/chat/data/chat_thread_alias_repository.dart';
import '../../features/chat/application/chat_run_tracker.dart';
import '../../features/chat/data/chat_api.dart';
import '../../features/chat/data/remote_project_assistant_runtime.dart';
import '../../features/chat/domain/assistant_runtime.dart';
import '../../features/chat/data/authenticated_resource_image_cache.dart';
import '../../features/notifications/data/notification_api.dart';
import '../../features/notifications/application/notification_controller.dart';
import '../../features/notifications/application/push_navigation_controller.dart';
import '../../features/notifications/application/push_registration_controller.dart';
import '../../features/notifications/application/push_runtime_controller.dart';
import '../../features/notifications/data/push_device_api.dart';
import '../../features/notifications/infrastructure/jpush_provider.dart';
import '../../features/notifications/infrastructure/push_provider.dart';
import '../../features/ingestion/application/internal_recording_controller.dart';
import '../../features/ingestion/application/material_ingestion_coordinator.dart';
import '../../features/ingestion/data/material_ingestion_api.dart';
import '../../features/ingestion/data/material_ingestion_store.dart';
import '../../features/recording_card/application/recording_card_controller.dart';
import '../../features/recording_card/application/recording_card_account_binding_controller.dart';
import '../../features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import '../../features/recording_card/application/recording_card_file_presentation.dart';
import '../../features/recording_card/application/recording_card_quick_wifi_coordinator.dart';
import '../../features/recording_card/data/recording_card_account_binding_repository.dart';
import '../../features/recording_card/data/recording_card_auto_sync_store.dart';
import '../../features/recording_card/data/recording_card_connection_history_store.dart';
import '../../features/recording_card/domain/recording_card_account_binding.dart';
import '../../features/recording_card/domain/recording_card_sync_ledger.dart';
import '../../features/recordings/application/recording_batch_transcription_controller.dart';
import '../../features/recordings/application/recording_detail_controller.dart';
import '../../features/recordings/application/recording_library_controller.dart';
import '../../features/recordings/application/recording_playback_controller.dart';
import '../../features/recordings/application/recording_processing_tracker.dart';
import '../../features/recordings/application/recording_transcription_receipt_projector.dart';
import '../../features/recordings/application/recording_upload_controller.dart';
import '../../features/recordings/data/local_playback_position_store.dart';
import '../../features/recordings/data/local_recording_repository.dart';
import '../../features/recordings/domain/recording_library.dart'
    show RecordingLibrarySource, RecordingFileSource;
import '../../features/recordings/data/recording_batch_transcription_store.dart';
import '../../features/recordings/data/recording_api.dart';
import '../../features/recordings/data/recording_transcription_receipt_store.dart';
import '../../features/recordings/domain/recording_batch_transcription.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/settings/application/app_appearance_controller.dart';
import '../../features/settings/data/app_appearance_repository.dart';
import '../../features/transcription/application/live_transcript_controller.dart';
import '../../features/transcription/data/live_transcription_api.dart';
import '../../features/transcription/data/tencent_live_asr_port.dart';
import '../../features/ui_v3/application/v3_material_upload_controller.dart';
import '../../features/ui_v3/application/v3_document_import_controller.dart';
import '../../features/ui_v3/application/v3_media_import_controller.dart';
import '../../features/ui_v3/application/deep_positioning_controller.dart';
import '../../features/ui_v3/application/digital_twin_controller.dart';
import '../../features/ui_v3/application/digital_twin_material_controller.dart';
import '../../features/ui_v3/data/digital_twin_material_store.dart';
import '../../features/ui_v3/domain/digital_twin_material.dart';
import '../../features/ui_v3/application/daily_topic_controller.dart';
import '../../features/ui_v3/application/canvas_autosave_coordinator.dart';
import '../../features/ui_v3/application/script_draft_controller.dart';
import '../../features/ui_v3/application/feed_aggregation_controller.dart';
import '../../features/ui_v3/application/knowledge_library_controller.dart';
import '../../features/ui_v3/application/knowledge_note_port.dart';
import '../../features/ui_v3/application/workspace_folder_port.dart';
import '../../features/ui_v3/application/note_relation_controller.dart';
import '../../features/ui_v3/application/subscription_port.dart';
import '../../features/ui_v3/application/workspace_search_controller.dart';
import '../../features/ui_v3/application/knowledge_document_export_service.dart';
import '../../features/ui_v3/application/note_append_controller.dart';
import '../../features/ui_v3/application/note_metrics_controller.dart';
import '../../features/ui_v3/application/photo_album_controller.dart';
import '../../features/ui_v3/application/profile_hub_controller.dart';
import '../../features/ui_v3/application/profile_workspace_controller.dart';
import '../../features/ui_v3/data/knowledge_user_metadata_repository.dart';
import '../../features/ui_v3/data/creation_canvas_history_port.dart';
import '../../features/ui_v3/data/creation_canvas_draft_repository.dart';
import '../../features/ui_v3/data/script_draft_api.dart';
import '../../features/ui_v3/data/deep_positioning_repository.dart';
import '../../features/ui_v3/data/document_change_proposal_api.dart';
import '../../features/ui_v3/data/digital_twin_api.dart';
import '../../features/ui_v3/data/feed_aggregation_repository.dart';
import '../../features/ui_v3/data/graph_repository.dart';
import '../../features/ui_v3/data/hotspot_note_repository.dart';
import '../../features/ui_v3/data/mirofish_graph_api.dart';
import '../../features/ui_v3/data/profile_workspace_repository.dart';
import '../../features/ui_v3/data/photo_album_repository.dart';
import '../../features/ui_v3/data/v3_deposit_repository.dart';
import '../../features/ui_v3/data/voiceprint_api.dart';
import '../../features/ui_v3/data/voiceprint_profile_repository.dart';
import '../../features/ui_v3/data/v3_document_import_store.dart';
import '../../features/ui_v3/data/automatic_outline_recovery_store.dart';
import '../../features/ui_v3/data/note_file_agent_client.dart';
import '../../features/ui_v3/data/note_metrics_repository.dart';
import '../lifecycle/app_activity_coordinator.dart';
import '../runtime/database_worker_runtime.dart';
import '../runtime/runtime_provider_module.dart';
import '../../features/ui_v3/data/workspace_content_sync.dart';
import '../../features/ui_v3/data/workspace_content_sync_store.dart';
import '../../features/ui_v3/domain/feed_item_models.dart';
import '../../features/ui_v3/domain/voiceprint_profile.dart';
import 'core_provider_module.dart';
import 'upload_recovery_bootstrap.dart';

export 'core_provider_module.dart';

// resident-provider: Preserves the daily topic controller state machine across route transitions.
final dailyTopicControllerProvider =
    ChangeNotifierProvider<DailyTopicController>((ref) {
      final sessionStore = ref.read(sessionStoreProvider);
      final controller = DailyTopicController(
        port: RemoteDailyTopicPort(
          DailyTopicRecommendationClient(ref.watch(apiClientProvider)),
        ),
        preferences: ref.watch(appPreferencesDaoProvider),
        userScope: ref.watch(authenticatedUserDataScopeProvider),
        workspaceId: () => sessionStore.state.workspace?.workspaceId,
        workspaceReady: () {
          final state = sessionStore.state;
          return state.authState == SessionAuthState.authenticated &&
              state.workspaceStatus == SessionWorkspaceStatus.ready &&
              state.workspace?.workspaceId?.trim().isNotEmpty == true;
        },
        cacheTtl: () => ref.read(appCachePolicyProvider).cacheTtl,
      );
      unawaited(controller.initialize());
      return controller;
    });

// resident-provider: Shares one backend contract api dependency for the full account session.
final backendContractApiProvider = Provider<BackendContractApiPort>((ref) {
  return BackendContractApi(apiClient: ref.watch(apiClientProvider));
});

// resident-provider: Shares one miro fish graph api dependency for the full account session.
final miroFishGraphApiProvider = Provider<MiroFishGraphApiPort>((ref) {
  return MiroFishGraphApi(apiClient: ref.watch(apiClientProvider));
});

// resident-provider: Shares one account-scoped remote graph repository identity across dependent controllers.
final remoteGraphRepositoryProvider = Provider<GraphRepository>((ref) {
  return ApiGraphRepository(api: ref.watch(miroFishGraphApiProvider));
});

const huahuoRemoteGraphContentNavigationEnabled = false;

String? resolveRuntimeGraphId({
  required String configuredWorkspaceId,
  required String? sessionWorkspaceId,
}) {
  if (!huahuoRemoteGraphContentNavigationEnabled) return null;
  final explicit = configuredWorkspaceId.trim();
  if (explicit.isNotEmpty) return explicit;
  final sessionValue = sessionWorkspaceId?.trim();
  return sessionValue == null || sessionValue.isEmpty ? null : sessionValue;
}

// resident-provider: Shares one account-scoped local database snapshot store identity across dependent controllers.
final localDatabaseSnapshotStoreProvider =
    Provider<LocalDatabaseSnapshotStore?>((ref) {
      return null;
    });

// resident-provider: Preserves the app database dependency identity across route changes.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final runtime = ref.watch(databaseWorkerRuntimeProvider);
  final useWorker = runtime.configured;
  return AppDatabase(
    snapshotStore: ref.watch(localDatabaseSnapshotStoreProvider),
    metrics: ref.watch(databaseMetricsProvider),
    writeWorker: useWorker ? runtime : null,
    writeQueue: useWorker ? runtime.writeQueue : null,
  );
});

// resident-provider: Preserves the database worker runtime dependency identity across route changes.
final databaseWorkerRuntimeProvider = Provider<DatabaseWorkerRuntime>((ref) {
  final runtime = DatabaseWorkerRuntime(
    snapshotStore: ref.watch(localDatabaseSnapshotStoreProvider),
    enabled: ref.watch(
      performanceFeatureFlagsProvider.select(
        (flags) => flags.databaseWorkerEnabled,
      ),
    ),
    metrics: ref.watch(databaseMetricsProvider),
  );
  ref.onDispose(() {
    unawaited(() async {
      try {
        await runtime.dispose();
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'huahuo database runtime',
            context: ErrorDescription(
              'while disposing the database worker runtime',
            ),
          ),
        );
      }
    }());
  });
  return runtime;
});

// resident-provider: Shares one account-scoped app preferences dao identity across dependent controllers.
final appPreferencesDaoProvider = Provider<AppPreferencesDao>((ref) {
  final runtime = ref.watch(databaseWorkerRuntimeProvider);
  return AppPreferencesDao(
    ref.watch(appDatabaseProvider),
    worker: runtime,
    writeQueue: runtime.writeQueue,
  );
});

// resident-provider: Retains only successfully committed automatic-Outline journals across scoped coordinator rebuilds.
final automaticOutlineRecoveryStoreRegistryProvider =
    Provider<AutomaticOutlineRecoveryStoreRegistry>((ref) {
      return AutomaticOutlineRecoveryStoreRegistry(
        ref.watch(appPreferencesDaoProvider),
      );
    });

// resident-provider: Shares one account-and-Workspace automatic-Outline recovery authority across repository, tracker and coordinator.
final automaticOutlineRecoveryStoreProvider =
    Provider<AutomaticOutlineRecoveryStorePort?>((ref) {
      final accountScope = ref.watch(authenticatedUserDataScopeProvider).trim();
      final workspaceScope = ref
          .watch(
            sessionStoreProvider.select(
              (store) => readyWorkspaceId(store.state),
            ),
          )
          ?.trim();
      if (accountScope.isEmpty ||
          workspaceScope == null ||
          workspaceScope.isEmpty) {
        return null;
      }
      return ref
          .watch(automaticOutlineRecoveryStoreRegistryProvider)
          .scoped(accountScope: accountScope, workspaceScope: workspaceScope);
    });

// resident-provider: Shares one account-scoped device app appearance repository identity across dependent controllers.
final deviceAppAppearanceRepositoryProvider = Provider<AppAppearanceRepository>(
  (ref) {
    return AppAppearanceRepository(dao: ref.watch(appPreferencesDaoProvider));
  },
);

// resident-provider: Shares one scoped photo album repository identity across account controllers.
final scopedPhotoAlbumRepositoryProvider = Provider<PhotoAlbumRepository>((
  ref,
) {
  ref.watch(authenticatedUserDataScopeProvider);
  final workspaceId = ref
      .watch(sessionStoreProvider)
      .state
      .workspace
      ?.workspaceId;
  return RemotePhotoAlbumRepository(
    apiClient: ref.watch(apiClientProvider),
    workspaceId: () => workspaceId,
  );
});

// resident-provider: Shares one scoped note metrics repository identity across account controllers.
final scopedNoteMetricsRepositoryProvider = Provider<NoteMetricsRepository>((
  ref,
) {
  ref.watch(authenticatedUserDataScopeProvider);
  final workspaceId = ref
      .watch(sessionStoreProvider)
      .state
      .workspace
      ?.workspaceId;
  return RemoteNoteMetricsRepository(
    apiClient: ref.watch(apiClientProvider),
    workspaceId: () => workspaceId,
  );
});

// resident-provider: Shares one scoped note metrics read cache identity across account controllers.
final scopedNoteMetricsReadCacheProvider = Provider<ScopedReadCache?>((ref) {
  final session = ref.watch(sessionStoreProvider).state;
  final workspaceId = session.workspace?.workspaceId?.trim();
  final userScope = ref.watch(authenticatedUserDataScopeProvider);
  if (session.authState != SessionAuthState.authenticated ||
      session.workspaceStatus != SessionWorkspaceStatus.ready ||
      workspaceId == null ||
      workspaceId.isEmpty ||
      userScope == 'anonymous') {
    return null;
  }
  return ScopedReadCache(
    dao: ref.watch(appPreferencesDaoProvider),
    userScope: userScope,
    workspaceScope: workspaceId,
    fallbackTtl: ref.watch(appCachePolicyProvider).cacheTtl,
  );
});

// resident-provider: Shares one account-scoped user metadata dao identity across dependent controllers.
final userMetadataDaoProvider = Provider<UserMetadataDao>((ref) {
  return UserMetadataDao(ref.watch(appDatabaseProvider));
});

// resident-provider: Shares one account-scoped creation canvas draft dao identity across dependent controllers.
final creationCanvasDraftDaoProvider = Provider<CreationCanvasDraftDao>((ref) {
  final runtime = ref.watch(databaseWorkerRuntimeProvider);
  return CreationCanvasDraftDao(
    ref.watch(appDatabaseProvider),
    worker: runtime,
    writeQueue: runtime.writeQueue,
  );
});

// resident-provider: Shares one account-scoped creation canvas history dao identity across dependent controllers.
final creationCanvasHistoryDaoProvider = Provider<CreationCanvasHistoryDao>((
  ref,
) {
  return CreationCanvasHistoryDao(ref.watch(appDatabaseProvider));
});

// resident-provider: Shares one scoped creation canvas history port dependency for the full account session.
final scopedCreationCanvasHistoryPortProvider =
    Provider<CreationCanvasHistoryPort>((ref) {
      ref.watch(authenticatedUserDataScopeProvider);
      return DatabaseCreationCanvasHistoryPort(
        ref.watch(creationCanvasHistoryDaoProvider),
      );
    });

// resident-provider: Shares one account-scoped creation canvas draft repository identity across dependent controllers.
final creationCanvasDraftRepositoryProvider =
    Provider<CreationCanvasDraftStore>((ref) {
      final repository = CreationCanvasDraftRepository(
        dao: ref.watch(creationCanvasDraftDaoProvider),
        userScope: ref.watch(authenticatedUserDataScopeProvider),
      );
      ref.onDispose(repository.dispose);
      return repository;
    });

// resident-provider: Shares one free-creation script transport across the account session.
final scriptDraftGenerationPortProvider = Provider<ScriptDraftGenerationPort>((
  ref,
) {
  try {
    return ScriptDraftApi(ref.watch(apiClientProvider));
  } on StateError catch (error) {
    if (error.message == 'DEVICE_IDENTITY_NOT_RESOLVED') {
      return const UnavailableScriptDraftGenerationPort();
    }
    rethrow;
  }
});

// resident-provider: Shares one account-scoped profile workspace dao identity across dependent controllers.
final profileWorkspaceDaoProvider = Provider<ProfileWorkspaceDao>((ref) {
  return ProfileWorkspaceDao(ref.watch(appDatabaseProvider));
});

// resident-provider: Shares one scoped profile workspace repository identity across account controllers.
final scopedProfileWorkspaceRepositoryProvider =
    Provider<ProfileWorkspaceRepository>((ref) {
      return ProfileWorkspaceRepository(
        dao: ref.watch(profileWorkspaceDaoProvider),
        userScope: ref.watch(authenticatedUserDataScopeProvider),
      );
    });

// resident-provider: Shares one account-scoped voiceprint profile repository identity across dependent controllers.
final voiceprintProfileRepositoryProvider =
    Provider<VoiceprintProfileRepository>((ref) {
      return VoiceprintProfileRepository(
        dao: ref.watch(userMetadataDaoProvider),
        userScope: ref.watch(authenticatedUserDataScopeProvider),
      );
    });

// resident-provider: Shares one account-scoped chat thread alias repository identity across dependent controllers.
final chatThreadAliasRepositoryProvider = Provider<ChatThreadAliasRepository>((
  ref,
) {
  final workspaceScope = ref.watch(
    sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
  );
  return ChatThreadAliasRepository(
    dao: ref.watch(userMetadataDaoProvider),
    preferencesDao: ref.watch(appPreferencesDaoProvider),
    userScope: ref.watch(authenticatedUserDataScopeProvider),
    workspaceScope: workspaceScope,
  );
});

// resident-provider: Shares one account-scoped v3 deposit dao identity across dependent controllers.
final v3DepositDaoProvider = Provider<V3DepositDao>((ref) {
  return V3DepositDao(ref.watch(appDatabaseProvider));
});

// resident-provider: Shares one account-scoped v3 deposit repository identity across dependent controllers.
final v3DepositRepositoryProvider = Provider<V3DepositRepository>((ref) {
  final userId = ref.watch(sessionStoreProvider).state.user?.userId;
  final userScope = userId == null || userId.trim().isEmpty
      ? V3DepositRepository.defaultUserScope
      : 'user:${userId.trim()}';
  return V3DepositRepository(
    dao: ref.watch(v3DepositDaoProvider),

    userScope: userScope,
  );
});

// resident-provider: Shares one scoped Knowledge metadata repository identity across account controllers.
final scopedKnowledgeUserMetadataRepositoryProvider =
    Provider<KnowledgeUserMetadataRepository>((ref) {
      return KnowledgeUserMetadataRepository(
        dao: ref.watch(userMetadataDaoProvider),
        userScope: ref.watch(authenticatedUserDataScopeProvider),
      );
    });

// resident-provider: Shares one knowledge document export service dependency for the full account session.
final knowledgeDocumentExportServiceProvider =
    Provider<KnowledgeDocumentExportService>((ref) {
      ref.watch(
        appActivityCoordinatorProvider.select(
          (activity) => (activity.state.route, activity.state.activeTab),
        ),
      );
      final service = FileKnowledgeDocumentExportService(
        taskOrchestrator: ref.watch(taskOrchestratorProvider),
      );
      ref.onDispose(service.dispose);
      return service;
    });

// resident-provider: Shares one voice recorder port dependency for the full account session.
final voiceRecorderPortProvider = Provider<VoiceRecorderPort>((ref) {
  return MethodChannelVoiceRecorderPort(
    nativeRecorderDirectoryScope: () => ref
        .read(privateRecordingPathResolverProvider)
        .nativeRecorderDirectoryScope,
  );
});

// resident-provider: Shares one file storage port dependency for the full account session.
final fileStoragePortProvider = Provider<FileStoragePort>((ref) {
  return PathProviderFileStoragePort(
    pathResolver: ref.watch(privateRecordingPathResolverProvider),
    privateAudioSourceResolver: ref
        .watch(privateMediaPathResolverProvider)
        .resolveFile,
    durationProbe: _probeAudioDuration,
  );
});

// resident-provider: Preserves the private recording path resolver dependency identity across route changes.
final privateRecordingPathResolverProvider =
    Provider<PrivateRecordingPathResolver>((ref) {
      return PrivateRecordingPathResolver(
        accountScope: ref.watch(authenticatedRecordingUserScopeProvider),
      );
    });

// resident-provider: Preserves the private media path resolver dependency identity across route changes.
final privateMediaPathResolverProvider = Provider<PrivateMediaPathResolver>((
  ref,
) {
  return PrivateMediaPathResolver();
});

// resident-provider: Shares one account-scoped local recording repository identity across dependent controllers.
final localRecordingRepositoryProvider = Provider<LocalRecordingRepository>((
  ref,
) {
  final accountScope = ref.watch(authenticatedRecordingUserScopeProvider);
  return LocalRecordingRepository(
    database: ref.watch(appDatabaseProvider),
    fileStorage: ref.watch(fileStoragePortProvider),
    accountScope: accountScope,
    requireAuthenticatedAccount: true,
    uploadDraftStore: ref.watch(uploadDraftStoreProvider),
    deletionLedger: _RecordingCardLocalDeletionLedgerAdapter(
      ref.watch(recordingCardAutoSyncStoreProvider),
    ),
    recoveryPathResolver: ref.watch(privateRecordingPathResolverProvider),
  );
});

// resident-provider: Preserves the recording library controller state machine across route transitions.
final recordingLibraryControllerProvider =
    ChangeNotifierProvider<RecordingLibraryController>((ref) {
      return RecordingLibraryController(
        repository: ref.watch(localRecordingRepositoryProvider),
        nativeFilePort: ref.watch(nativeFilePortProvider),
      );
    });

// resident-provider: Shares one account-scoped playback position store across playback controller variants.
final recordingPlaybackPositionStoreProvider =
    Provider<RecordingPlaybackPositionStore>((ref) {
      return LocalRecordingPlaybackPositionStore(
        dao: RecordingDao(
          ref.watch(appDatabaseProvider),
          userScope:
              ref.watch(authenticatedRecordingUserScopeProvider) ??
              '__signed_out_recording_scope__',
        ),
      );
    });

// resident-provider: Preserves the recording playback controller state machine across route transitions.
final recordingPlaybackControllerProvider =
    ChangeNotifierProvider<RecordingPlaybackController>((ref) {
      return RecordingPlaybackController(
        playbackPort: JustAudioPlaybackPort(
          resolvePrivateAudioFile: ref
              .watch(privateRecordingPathResolverProvider)
              .resolveFile,
        ),
        positionStore: ref.watch(recordingPlaybackPositionStoreProvider),
      );
    });

// resident-provider: Shares one account-scoped upload draft store identity across dependent controllers.
final uploadDraftStoreProvider = Provider<UploadDraftStore>((ref) {
  return UploadDraftStore(
    database: ref.watch(appDatabaseProvider),
    accountScope: ref.watch(authenticatedRecordingUserScopeProvider),
    requireAuthenticatedAccount: true,
  );
});

// resident-provider: Shares one object upload transport dependency for the full account session.
final objectUploadTransportProvider = Provider<ObjectUploadTransport>((ref) {
  final recordingResolver = ref.watch(privateRecordingPathResolverProvider);
  final mediaResolver = ref.watch(privateMediaPathResolverProvider);
  return HttpObjectUploadTransport(
    openRead: (uri) =>
        _openPrivateUploadReadStream(uri, recordingResolver, mediaResolver),
  );
});

// resident-provider: Shares one upload client dependency for the full account session.
final uploadClientProvider = Provider<UploadClient>((ref) {
  return UploadClient(
    apiClient: ref.watch(apiClientProvider),
    objectTransport: ref.watch(objectUploadTransportProvider),
  );
});

// resident-provider: Shares one recording upload client dependency for the full account session.
final recordingUploadClientProvider = Provider<UploadClient>((ref) {
  return UploadClient(
    apiClient: ref.watch(recordingApiClientProvider),
    objectTransport: ref.watch(objectUploadTransportProvider),
  );
});

// resident-provider: Preserves the voice gateway base url dependency identity across route changes.
final voiceGatewayBaseUrlProvider = Provider<Uri>((ref) {
  return _voiceGatewayBaseUrl(ref.watch(apiClientProvider));
});

// resident-provider: Preserves the live transcription backend base url dependency identity across route changes.
final liveTranscriptionBackendBaseUrlProvider = Provider<Uri?>((ref) {
  const configured = String.fromEnvironment(
    'HUAHUO_LIVE_TRANSCRIPTION_BACKEND_BASE_URL',
  );
  return resolveLiveTranscriptionBackendBaseUrl(
    configuredValue: configured,
    recordingApiBaseUrl: ref.watch(recordingApiClientProvider).config.baseUrl,
  );
});

Uri? resolveLiveTranscriptionBackendBaseUrl({
  required String configuredValue,
  required Uri recordingApiBaseUrl,
}) {
  final explicit = configuredValue.trim();
  if (explicit.isNotEmpty) {
    return Uri.tryParse(explicit) ??
        Uri(
          scheme: 'invalid',
          host: 'live-transcription-backend-configuration',
        );
  }
  return recordingApiBaseUrl;
}

// resident-provider: Shares one voiceprint api dependency for the full account session.
final voiceprintApiProvider = Provider<VoiceprintApiPort>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final pathResolver = ref.watch(privateRecordingPathResolverProvider);
  return GatewayVoiceprintApi(
    apiClient: apiClient,
    gatewayBaseUrl: ref.watch(voiceGatewayBaseUrlProvider),
    sampleBytesResolver: (appPrivateUri) async {
      final file = await pathResolver.resolveFile(appPrivateUri);
      if (file == null || !await file.exists()) {
        throw StateError('VOICEPRINT_SAMPLE_MISSING');
      }
      final length = await file.length();
      if (length <= 0 || length > voiceprintWavMaximumBytes) {
        throw StateError('VOICEPRINT_SAMPLE_SIZE_INVALID');
      }
      return file.readAsBytes();
    },
  );
});

// resident-provider: Shares one voiceprint profile sync service dependency for the full account session.
final voiceprintProfileSyncServiceProvider =
    Provider<VoiceprintProfileSyncService>((ref) {
      final sessionStore = ref.read(sessionStoreProvider);
      final repository = ref.watch(voiceprintProfileRepositoryProvider);
      return VoiceprintProfileSyncService(
        api: ref.watch(voiceprintApiProvider),
        repository: repository,
        isScopeActive: () {
          final session = sessionStore.state;
          return session.authState == SessionAuthState.authenticated &&
              session.user?.userId == repository.userScope;
        },
      );
    });

// resident-provider: Preserves the live transcription credential dependency identity across route changes.
final liveTranscriptionCredentialProvider =
    Provider<LiveTranscriptionCredentialPort>((ref) {
      final apiClient = ref.watch(recordingApiClientProvider);
      return LiveTranscriptionApi(
        apiClient: apiClient,
        backendBaseUrl: ref.watch(liveTranscriptionBackendBaseUrlProvider),
      );
    });

// resident-provider: Shares one tencent live asr port dependency for the full account session.
final tencentLiveAsrPortProvider = Provider<TencentLiveAsrPort>((ref) {
  return MethodChannelTencentLiveAsrPort();
});

// resident-provider: Preserves the live transcript controller state machine across route transitions.
final liveTranscriptControllerProvider =
    ChangeNotifierProvider<LiveTranscriptController>((ref) {
      final profileRepository = ref.watch(voiceprintProfileRepositoryProvider);
      List<VoiceprintProfile> profiles() => profileRepository.loadProfiles();
      final controller = LiveTranscriptController(
        credentialPort: ref.watch(liveTranscriptionCredentialProvider),
        asrPort: ref.watch(tencentLiveAsrPortProvider),
        activeVoiceprintProfileId: () {
          for (final profile in profiles()) {
            if (!profile.isDemo) return profile.id;
          }
          return null;
        },
        profileDisplayNameResolver: (profileId) {
          for (final profile in profiles()) {
            if (!profile.isDemo && profile.id == profileId) {
              return profile.name;
            }
          }
          return null;
        },
      );
      final sessionStore = ref.read(sessionStoreProvider);
      final activity = ref.read(appActivityCoordinatorProvider);
      String sessionOwnerScope() {
        final session = sessionStore.state;
        return '${session.user?.userId.trim() ?? ''}\u0000'
            '${session.workspace?.workspaceId?.trim() ?? ''}';
      }

      var activeSessionOwnerScope = sessionOwnerScope();
      void stopActiveAttempt() {
        final current = controller.state;
        final owner = current.owner;
        if (owner == null) return;
        unawaited(controller.stop(owner: owner, attemptId: current.attemptId));
      }

      void clearOnSessionOwnershipChange() {
        final nextScope = sessionOwnerScope();
        if (sessionStore.state.authState != SessionAuthState.authenticated ||
            nextScope != activeSessionOwnerScope) {
          stopActiveAttempt();
        }
        activeSessionOwnerScope = nextScope;
      }

      void stopOnBackground() {
        if (activity.state.visibility == AppVisibility.background) {
          stopActiveAttempt();
        }
      }

      sessionStore.addListener(clearOnSessionOwnershipChange);
      activity.addListener(stopOnBackground);
      ref.onDispose(() {
        sessionStore.removeListener(clearOnSessionOwnershipChange);
        activity.removeListener(stopOnBackground);
      });
      return controller;
    });

Uri _voiceGatewayBaseUrl(ApiClient apiClient) {
  const configured = String.fromEnvironment('HUAHUO_VOICE_GATEWAY_BASE_URL');
  final explicit = configured.trim();
  if (explicit.isNotEmpty) {
    return Uri.tryParse(explicit) ??
        Uri(scheme: 'invalid', host: 'voice-gateway-configuration');
  }
  final base = apiClient.config.baseUrl;
  final normalized = base.toString().endsWith('/')
      ? base
      : Uri.parse('${base.toString()}/');
  return normalized.resolve('voice-gateway/');
}

// resident-provider: Shares one recording api dependency for the full account session.
final recordingApiProvider = Provider<RecordingApiPort>((ref) {
  return RecordingApi(apiClient: ref.watch(recordingApiClientProvider));
});

// resident-provider: Shares one material ingestion api dependency for the full account session.
final materialIngestionApiProvider = Provider<MaterialIngestionApiPort>((ref) {
  final workspaceId = ref.watch(
    sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
  );
  return MaterialIngestionApi(
    apiClient: ref.watch(apiClientProvider),
    workspaceId: () => workspaceId,
  );
});

// resident-provider: Shares one account-scoped material ingestion store identity across dependent controllers.
final materialIngestionStoreProvider = Provider<MaterialIngestionStore>((ref) {
  return MaterialIngestionStore(
    database: ref.watch(appDatabaseProvider),
    ownerScope: ref.watch(materialIngestionOwnerScopeProvider),
  );
});

// resident-provider: Preserves the material ingestion coordinator dependency identity across route changes.
final materialIngestionCoordinatorProvider =
    ChangeNotifierProvider<MaterialIngestionCoordinator>((ref) {
      return MaterialIngestionCoordinator(
        api: ref.watch(materialIngestionApiProvider),
        store: ref.watch(materialIngestionStoreProvider),
        knowledgeLibrary: ref.watch(
          knowledgeLibraryControllerProvider.notifier,
        ),
        logger: ref.watch(diagnosticLoggerProvider),
      );
    });

// resident-provider: Preserves the internal recording controller state machine across route transitions.
final internalRecordingControllerProvider =
    ChangeNotifierProvider<InternalRecordingController>((ref) {
      final materials = ref.watch(
        digitalTwinMaterialControllerProvider.notifier,
      );
      return InternalRecordingController(
        onDistillationJobReady: (jobId, title) => materials.enqueue(
          referenceKind: 'recording_job',
          referenceId: jobId,
          title: title,
        ),
        capture: ref.watch(screenCapturePortProvider),
        sessionStore: InternalRecordingSessionStore(
          database: ref.watch(appDatabaseProvider),
          ownerScope:
              ref.watch(authenticatedRecordingUserScopeProvider) ??
              'signed-out',
        ),
        diagnosticLogger: ref.watch(diagnosticLoggerProvider),
        localRecordingRepository: ref.watch(localRecordingRepositoryProvider),
        uploadController: ref.watch(recordingUploadControllerProvider.notifier),
      );
    });

// resident-provider: Shares one notification api dependency for the full account session.
final notificationApiProvider = Provider<NotificationApiPort>((ref) {
  try {
    final workspaceId = ref.watch(
      sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
    );
    return NotificationApi(
      apiClient: ref.watch(apiClientProvider),
      workspaceId: workspaceId,
    );
  } on StateError catch (error) {
    if (error.message == 'DEVICE_IDENTITY_NOT_RESOLVED') {
      return const UnavailableNotificationApi();
    }
    rethrow;
  }
});

// resident-provider: Shares one notification resolution port dependency for the full account session.
final notificationResolutionPortProvider = Provider<NotificationResolutionPort>(
  (ref) {
    final accountScope = ref.watch(authenticatedUserDataScopeProvider);
    final workspaceId = ref.watch(
      sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
    );
    return PersistentNotificationResolutionPort(
      dao: ref.watch(appPreferencesDaoProvider),
      userScope: '$accountScope\u0000${workspaceId ?? 'workspace-unavailable'}',
    );
  },
);

// resident-provider: Preserves the notification controller state machine across route transitions.
final notificationControllerProvider =
    ChangeNotifierProvider<NotificationController>((ref) {
      return NotificationController(
        api: ref.watch(notificationApiProvider),
        resolution: ref.watch(notificationResolutionPortProvider),
        cacheTtlResolver: () => ref.read(appCachePolicyProvider).cacheTtl,
      );
    });

// resident-provider: Shares one account-scoped resource image cache identity across dependent controllers.
final resourceImageCacheProvider = Provider<AuthenticatedResourceImageCache>((
  ref,
) {
  final workspaceId = ref.watch(
    sessionStoreProvider.select((store) => store.state.workspace?.workspaceId),
  );
  final cache = AuthenticatedResourceImageCache(
    playbackClient: ChatImagePlaybackClient(ref.watch(apiClientProvider)),
    userScope: ref.watch(authenticatedUserDataScopeProvider),
    workspaceScope: workspaceId ?? 'workspace-unavailable',
  );
  ref.onDispose(cache.dispose);
  return cache;
});

// resident-provider: Preserves the chat run tracker dependency identity across route changes.
final chatRunTrackerProvider = ChangeNotifierProvider<ChatRunTracker>((ref) {
  final accountScope = ref.watch(authenticatedUserDataScopeProvider);
  final sessionStore = ref.read(sessionStoreProvider);
  final workspaceScope = ref.watch(
    sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
  );
  final trackerScope = chatRunTrackerWorkspaceScope(
    accountScope: accountScope,
    workspaceScope: workspaceScope,
  );
  final automaticOutlineRecovery = ref.watch(
    automaticOutlineRecoveryStoreProvider,
  );
  AssistantRuntimePort assistantRuntime = const UnavailableAssistantRuntime();
  AssistantRuntimeStreamPort? assistantRuntimeStream;
  NoteFileAgentRunStatusPort? fileAgentRuns;
  NoteFileAgentClient? fileAgentClient;
  RecordingApiPort? recordingApi;
  try {
    final apiClient = ref.watch(apiClientProvider);
    final remoteAssistantRuntime = RemoteProjectAssistantRuntime(apiClient);
    assistantRuntime = remoteAssistantRuntime;
    assistantRuntimeStream = remoteAssistantRuntime;
    fileAgentClient = NoteFileAgentClient(
      apiClient: apiClient,
      workspaceId: () => workspaceScope,
    );
    fileAgentRuns = fileAgentClient;
    recordingApi = ref.watch(recordingApiProvider);
  } on StateError catch (error) {
    if (error.message != 'DEVICE_IDENTITY_NOT_RESOLVED') rethrow;
  }
  var providerActive = true;
  bool ownsTrackerScope() {
    final state = sessionStore.state;
    return providerActive &&
        authenticatedRuntimeUserId(state) == accountScope &&
        readyWorkspaceId(state) == workspaceScope;
  }

  final tracker = ChatRunTracker(
    assistantRuntime: assistantRuntime,
    assistantRuntimeStream: assistantRuntimeStream,
    diagnosticLogger: ref.watch(diagnosticLoggerProvider),
    fileAgentRuns: fileAgentRuns,
    recordingApi: recordingApi,
    preferences: ref.watch(appPreferencesDaoProvider),
    userScope: trackerScope,
    checkpointPersistence: ChatRunCheckpointPersistence(
      worker: ref.watch(databaseWorkerRuntimeProvider),
      writeQueue: ref.watch(databaseWorkerRuntimeProvider).writeQueue,
    ),
    runtimeActivityMetrics: ref.watch(runtimeActivityMetricsProvider),
    taskOrchestrator: ref.watch(taskOrchestratorProvider),
    chatSseAuthoritative: ref.watch(
      performanceFeatureFlagsProvider.select(
        (flags) => flags.chatSseAuthoritative,
      ),
    ),
    onTerminal: () async {
      if (!ownsTrackerScope()) return;
      await ref.read(notificationControllerProvider).load(forceRemote: true);
    },
    onDerivedPartTerminal: (completion) async {
      if (!ownsTrackerScope()) return false;
      var refreshed = true;
      if (completion.status == 'succeeded') {
        final expectedRevision = completion.outputPartRevisionId?.trim();
        final client = fileAgentClient;
        if (expectedRevision == null ||
            expectedRevision.isEmpty ||
            client == null) {
          return false;
        }
        final output = await client.readCurrentPart(
          completion.remoteNoteId,
          completion.targetPart,
        );
        if (!ownsTrackerScope()) return false;
        if (output.partRevisionId != expectedRevision) return false;
        final library = ref.read(knowledgeLibraryControllerProvider);
        refreshed = await library.refreshRemoteDerivedParts(
          completion.localNoteId,
        );
        if (!ownsTrackerScope() ||
            !refreshed ||
            !hasExpectedDerivedPartProjection(
              library.noteForId(completion.localNoteId),
              completion.targetPart,
              output.markdown,
            )) {
          return false;
        }
      }
      if (!ownsTrackerScope()) return false;
      final operationId = completion.operationId?.trim();
      if (completion.targetPart == NoteFileAgentPart.outline &&
          isAutomaticOutlineOperationId(operationId)) {
        final inputRevision = completion.inputPartRevisionId?.trim();
        final targetRevision = completion.targetPartRevisionId?.trim();
        final outputRevision = completion.outputPartRevisionId?.trim();
        if (automaticOutlineRecovery == null ||
            workspaceScope == null ||
            workspaceScope.isEmpty ||
            inputRevision == null ||
            inputRevision.isEmpty ||
            targetRevision == null ||
            targetRevision.isEmpty ||
            (completion.status == 'succeeded' &&
                (outputRevision == null || outputRevision.isEmpty))) {
          return false;
        }
        final persisted = await automaticOutlineRecovery.putTerminal(
          AutomaticOutlineTerminalRecord(
            attemptId: automaticOutlineAttemptId(
              workspaceScope: workspaceScope,
              remoteNoteId: completion.remoteNoteId,
              inputRawRevisionId: inputRevision,
              targetOutlineRevisionId: targetRevision,
            ),
            remoteNoteId: completion.remoteNoteId,
            operationId: operationId!,
            inputRawRevisionId: inputRevision,
            targetOutlineRevisionId: targetRevision,
            status: completion.status,
            fileAgentRunId: completion.fileAgentRunId,
            outputOutlineRevisionId: outputRevision,
            recordedAt: DateTime.now().toUtc(),
          ),
        );
        if (!ownsTrackerScope() || !persisted) return false;
      }
      ref
          .read(v3DocumentImportStoreProvider)
          .markOutlineTerminal(
            fileAgentRunId: completion.fileAgentRunId,
            status: completion.status,
            failureCode: completion.failureCode,
          );
      // The document-import provider observes the tracker after construction.
      // Reading it here would create a tracker -> page -> tracker cycle.
      return completion.status == 'succeeded' ? refreshed : true;
    },
    onRecordingOutlineTerminal: (completion) async {
      if (!ownsTrackerScope()) return false;
      final expectedRevision = completion.outputPartRevisionId?.trim();
      final client = fileAgentClient;
      if (completion.status != 'succeeded' ||
          expectedRevision == null ||
          expectedRevision.isEmpty ||
          client == null) {
        return false;
      }
      final output = await client.readCurrentPart(
        completion.remoteNoteId,
        NoteFileAgentPart.outline,
      );
      if (!ownsTrackerScope() ||
          output.partRevisionId != expectedRevision ||
          output.markdown.trim().isEmpty) {
        return false;
      }
      final library = ref.read(knowledgeLibraryControllerProvider);
      final refreshed = await library.refreshRemoteDerivedParts(
        completion.localNoteId,
      );
      if (!ownsTrackerScope()) return false;
      final note = library.noteForId(completion.localNoteId);
      final projected =
          refreshed &&
          note?.remoteNoteId?.trim() == completion.remoteNoteId &&
          note?.outlinePartRevisionId?.trim() == expectedRevision &&
          note?.summaryBody?.trim().isNotEmpty == true &&
          hasExpectedDerivedPartProjection(
            note,
            NoteFileAgentPart.outline,
            output.markdown,
          );
      if (!projected) return false;
      final receiptProjector = ref.read(
        recordingTranscriptionReceiptProjectorProvider,
      );
      final processingState = ref
          .read(recordingProcessingTrackerProvider)
          .state;
      await receiptProjector.applyProcessingState(processingState);
      if (!ownsTrackerScope()) return false;
      await receiptProjector.applyOutlineCompleted(
        remoteRecordingId: completion.recordingId,
        noteId: completion.remoteNoteId,
      );
      return ownsTrackerScope();
    },
  );
  ref.onDispose(() => providerActive = false);
  return tracker;
});

String chatRunTrackerWorkspaceScope({
  required String accountScope,
  required String? workspaceScope,
}) {
  final normalizedAccount = accountScope.trim();
  final normalizedWorkspace = workspaceScope?.trim();
  if (normalizedAccount.isEmpty ||
      normalizedAccount == 'anonymous' ||
      normalizedWorkspace == null ||
      normalizedWorkspace.isEmpty) {
    return 'anonymous';
  }
  final identity = jsonEncode(<String>[normalizedAccount, normalizedWorkspace]);
  final digest = sha256.convert(utf8.encode(identity));
  return 'chat-workspace-sha256-v1:$digest';
}

bool hasExpectedDerivedPartProjection(
  V3FeedItem? note,
  NoteFileAgentPart targetPart,
  String expectedMarkdown,
) {
  if (note == null) return false;
  final visibleMarkdown = switch (targetPart) {
    NoteFileAgentPart.outline => note.summaryBody,
    NoteFileAgentPart.germination =>
      note.sproutReport?.markdown ?? note.sproutTopic,
    NoteFileAgentPart.raw => note.rawBody,
  };
  return visibleMarkdown?.trim() == expectedMarkdown.trim();
}

// resident-provider: Keeps the foreground chat thread id value consistent across sibling route consumers.
/// In-memory only: identifies the currently visible conversation for Push UI.
final foregroundChatThreadIdProvider = StateProvider<String?>((ref) => null);

// resident-provider: Preserves the recording processing tracker dependency identity across route changes.
final ChangeNotifierProvider<RecordingProcessingTracker>
recordingProcessingTrackerProvider =
    ChangeNotifierProvider<RecordingProcessingTracker>((ref) {
      final sessionStore = ref.read(sessionStoreProvider);
      final accountScope = ref.watch(authenticatedRecordingUserScopeProvider);
      final workspaceScope = ref.watch(
        sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
      );
      final receiptProjector = ref.watch(
        recordingTranscriptionReceiptProjectorProvider,
      );
      final tracker = RecordingProcessingTracker(
        recordingApi: ref.watch(recordingApiProvider),
        draftStore: ref.watch(uploadDraftStoreProvider),
        accountScope: accountScope,
        workspaceScope: workspaceScope,
        activeAccountScope: () {
          final state = sessionStore.state;
          if (state.authState != SessionAuthState.authenticated) return null;
          final userId = state.user?.userId.trim();
          return userId == null || userId.isEmpty ? null : userId;
        },
        activeWorkspaceScope: () => readyWorkspaceId(sessionStore.state),
        onDetailChanged: (detail) async {
          if (authenticatedRuntimeUserId(sessionStore.state) != accountScope ||
              readyWorkspaceId(sessionStore.state) != workspaceScope) {
            return false;
          }
          final refreshed = await _refreshRecordingNoteProjection(
            ref.read(knowledgeLibraryControllerProvider),
            detail,
          );
          if (!refreshed || !detail.hasCloudAsset) return refreshed;
          final noteId = detail.noteRef?.noteId.trim();
          if (noteId == null || noteId.isEmpty) return false;
          final note = ref
              .read(knowledgeLibraryControllerProvider)
              .notes
              .where((candidate) => candidate.remoteNoteId?.trim() == noteId)
              .firstOrNull;
          if (note == null || note.isReadOnly) return false;
          final taskTracker = ref.read(chatRunTrackerProvider);
          await taskTracker.rememberKnowledgeAssetSubject(
            localNoteId: note.id,
            subjectTitle: note.title,
          );
          await taskTracker.trackRecordingOutline(
            recordingId: detail.recording.recordingId,
            localNoteId: note.id,
            remoteNoteId: noteId,
          );
          await ref
              .read(recordingBatchTranscriptionControllerProvider)
              .applyOutlineStatusForRecording(
                recordingId: detail.recording.recordingId,
                status: RecordingBatchOutlineStatus.generating,
                taskId: detail.noteOutlineTask?.taskId,
              );
          return true;
        },
      );
      tracker.attachPollingRuntime(
        orchestrator: ref.read(taskOrchestratorProvider),
        activityMetrics: ref.read(runtimeActivityMetricsProvider),
      );
      var disposed = false;
      var projectionTail = Future<void>.value();
      void projectReceipts() {
        final snapshot = tracker.state;
        projectionTail = projectionTail
            .then((_) async {
              if (disposed) return;
              await receiptProjector.applyProcessingState(snapshot);
            })
            .catchError((Object _) {});
      }

      tracker.addListener(projectReceipts);
      ref.onDispose(() {
        disposed = true;
        tracker.removeListener(projectReceipts);
      });
      return tracker;
    });

Future<bool> _refreshRecordingNoteProjection(
  KnowledgeLibraryController library,
  RecordingDetail detail,
) async {
  final noteRef = detail.noteRef;
  final noteId = noteRef?.noteId.trim();
  final rawPartRevisionId = noteRef?.rawPartRevisionId.trim();
  final recordingId = detail.recording.recordingId.trim();
  if (noteId == null ||
      noteId.isEmpty ||
      rawPartRevisionId == null ||
      rawPartRevisionId.isEmpty ||
      recordingId.isEmpty) {
    return !detail.hasCloudAsset;
  }
  V3FeedItem? findCanonicalNote() {
    return library.notes
        .where((candidate) => candidate.remoteNoteId?.trim() == noteId)
        .firstOrNull;
  }

  var note = findCanonicalNote();
  if (note == null || note.rawPartRevisionId?.trim() != rawPartRevisionId) {
    await library.synchronizeWorkspaceContent();
    note = findCanonicalNote();
  }
  if (note == null || note.isReadOnly) return false;
  if (note.recordingId != recordingId ||
      note.minutesStatus != detail.recording.minutesStatus ||
      note.summaryStatus != detail.recording.summaryStatus) {
    library.updateNote(
      note.copyWith(
        recordingId: recordingId,
        minutesStatus: detail.recording.minutesStatus,
        summaryStatus: detail.recording.summaryStatus,
      ),
    );
  }
  if (!await library.flushPersistenceResult()) return false;
  final projected = library.noteForId(note.id);
  return projected?.remoteNoteId?.trim() == noteId &&
      projected?.rawPartRevisionId?.trim() == rawPartRevisionId;
}

// resident-provider: Preserves the recording upload controller state machine across route transitions.
final ChangeNotifierProvider<RecordingUploadController>
recordingUploadControllerProvider =
    ChangeNotifierProvider<RecordingUploadController>((ref) {
      final sessionStore = ref.read(sessionStoreProvider);
      final accountScope = ref.watch(authenticatedRecordingUserScopeProvider);
      return RecordingUploadController(
        uploadClient: ref.watch(recordingUploadClientProvider),
        draftStore: ref.watch(uploadDraftStoreProvider),
        recordingApi: ref.watch(recordingApiProvider),
        localRecordingRepository: ref.watch(localRecordingRepositoryProvider),
        diagnosticLogger: ref.watch(diagnosticLoggerProvider),
        activeWorkspaceId: () => sessionStore.state.workspace?.workspaceId,
        accountScope: accountScope,
        processingPort: ref.watch(recordingProcessingTrackerProvider.notifier),
        activeAccountScope: () {
          final state = sessionStore.state;
          if (state.authState != SessionAuthState.authenticated) return null;
          final userId = state.user?.userId.trim();
          return userId == null || userId.isEmpty ? null : userId;
        },
      );
    });

// resident-provider: Shares durable account-scoped transcription completion receipts across library and batch views.
final recordingTranscriptionReceiptStoreProvider =
    ChangeNotifierProvider<RecordingTranscriptionReceiptStore>((ref) {
      return RecordingTranscriptionReceiptStore(
        database: ref.watch(appDatabaseProvider),
        accountScope: ref.watch(authenticatedUserDataScopeProvider),
      );
    });

// resident-provider: Projects every account-owned single or batch recording completion into the same durable receipt contract.
final recordingTranscriptionReceiptProjectorProvider =
    Provider<RecordingTranscriptionReceiptProjector>((ref) {
      return RecordingTranscriptionReceiptProjector(
        store: ref.watch(recordingTranscriptionReceiptStoreProvider.notifier),
        accountScope: ref.watch(authenticatedUserDataScopeProvider),
        localItemLookup: ref.watch(localRecordingRepositoryProvider).findById,
      );
    });

// resident-provider: Shares candidate classification against the canonical upload and processing authorities.
final recordingTranscriptionCandidateFactoryProvider =
    Provider<RecordingTranscriptionCandidateFactory>((ref) {
      return RecordingTranscriptionCandidateFactory(
        draftStore: ref.watch(uploadDraftStoreProvider),
        processing: ref.watch(recordingProcessingTrackerProvider.notifier),
      );
    });

// resident-provider: Shares one durable batch store for the active account and Workspace scope.
final recordingBatchTranscriptionStoreProvider =
    Provider<RecordingBatchTranscriptionStore>((ref) {
      final workspaceScope = ref.watch(
        sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
      );
      return RecordingBatchTranscriptionStore(
        database: ref.watch(appDatabaseProvider),
        accountScope: ref.watch(authenticatedUserDataScopeProvider),
        workspaceScope: workspaceScope ?? 'workspace-unavailable',
      );
    });

// resident-provider: Preserves recoverable multi-recording transcription state across route transitions.
final ChangeNotifierProvider<RecordingBatchTranscriptionController>
recordingBatchTranscriptionControllerProvider =
    ChangeNotifierProvider<RecordingBatchTranscriptionController>((ref) {
      final workspaceScope = ref.watch(
        sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
      );
      final processingTracker = ref.watch(
        recordingProcessingTrackerProvider.notifier,
      );
      final outlineTracker = ref.watch(chatRunTrackerProvider.notifier);
      final controller = RecordingBatchTranscriptionController(
        store: ref.watch(recordingBatchTranscriptionStoreProvider),
        receiptStore: ref.watch(
          recordingTranscriptionReceiptStoreProvider.notifier,
        ),
        executionPort: RecordingBatchTranscriptionExecutionAdapter(
          uploadController: ref.watch(
            recordingUploadControllerProvider.notifier,
          ),
          localRecordingRepository: ref.watch(localRecordingRepositoryProvider),
          recordingApi: ref.watch(recordingApiProvider),
          processingRetryPort: processingTracker,
          speakerAutoAdvancePort: processingTracker,
        ),
        accountScope: ref.watch(authenticatedUserDataScopeProvider),
        workspaceScope: workspaceScope ?? 'workspace-unavailable',
        candidateFactory: ref.watch(
          recordingTranscriptionCandidateFactoryProvider,
        ),
      );

      var restored = false;
      var disposed = false;
      String? outlineRevision;

      void projectProcessingTasks() {
        if (!restored || disposed) return;
        unawaited(controller.applyProcessingState(processingTracker.state));
      }

      void projectOutlineCompletion() {
        if (!restored || disposed) return;
        final completion = outlineTracker.lastRecordingOutlineCompletion;
        if (completion == null) return;
        final revision =
            '${completion.trackingTaskId}:${completion.status}:'
            '${completion.publicTaskId ?? ''}:'
            '${completion.outputPartRevisionId ?? ''}:'
            '${completion.failureCode ?? ''}';
        if (outlineRevision == revision) return;
        outlineRevision = revision;
        unawaited(
          controller.applyOutlineStatusForRecording(
            recordingId: completion.recordingId,
            status: completion.status == 'succeeded'
                ? RecordingBatchOutlineStatus.completed
                : RecordingBatchOutlineStatus.failed,
            errorCode: completion.failureCode,
            taskId: completion.publicTaskId,
            observedAt: DateTime.now().toUtc(),
          ),
        );
      }

      processingTracker.addListener(projectProcessingTasks);
      outlineTracker.addListener(projectOutlineCompletion);
      unawaited(
        controller
            .restore()
            .then((_) {
              if (disposed) return;
              restored = true;
              projectProcessingTasks();
              projectOutlineCompletion();
            })
            .catchError((Object error, StackTrace stackTrace) {
              FlutterError.reportError(
                FlutterErrorDetails(
                  exception: error,
                  stack: stackTrace,
                  library: 'huahuo recording batch transcription',
                  context: ErrorDescription(
                    'while restoring durable transcription batches',
                  ),
                ),
              );
            }),
      );
      ref.onDispose(() {
        disposed = true;
        processingTracker.removeListener(projectProcessingTasks);
        outlineTracker.removeListener(projectOutlineCompletion);
        unawaited(
          controller.deactivateForAccountScopeChange().catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: 'huahuo recording batch transcription',
                context: ErrorDescription(
                  'while deactivating a scoped transcription controller',
                ),
              ),
            );
          }),
        );
      });
      return controller;
    });

// resident-provider: Preserves the upload recovery bootstrap dependency identity across route changes.
final uploadRecoveryBootstrapProvider = Provider<UploadRecoveryBootstrap>(
  (ref) {
    final bootstrap = ref.watch(appBootstrapControllerProvider.notifier);
    final session = ref.watch(sessionStoreProvider.notifier);
    final uploadController = ref.watch(
      recordingUploadControllerProvider.notifier,
    );
    final processingTracker = ref.watch(
      recordingProcessingTrackerProvider.notifier,
    );
    final recovery = UploadRecoveryBootstrap(
      bootstrapController: bootstrap,
      sessionStore: session,
      recoverDrafts: () async {
        await uploadController.recoverDrafts();
        await processingTracker.recoverPending();
      },
    );
    scheduleMicrotask(recovery.start);
    ref.onDispose(recovery.dispose);
    return recovery;
  },
  dependencies: <ProviderOrFamily>[
    resolvedDeviceIdProvider,
    localDatabaseSnapshotStoreProvider,
    appBootstrapControllerProvider,
    sessionStoreProvider,
    recordingUploadControllerProvider,
    recordingProcessingTrackerProvider,
  ],
);

// resident-provider: Preserves the material ingestion recovery bootstrap dependency identity across route changes.
final materialIngestionRecoveryBootstrapProvider =
    Provider<UploadRecoveryBootstrap>(
      (ref) {
        final coordinator = ref.watch(
          materialIngestionCoordinatorProvider.notifier,
        );
        final recovery = UploadRecoveryBootstrap(
          bootstrapController: ref.watch(
            appBootstrapControllerProvider.notifier,
          ),
          sessionStore: ref.watch(sessionStoreProvider.notifier),
          recoverDrafts: () async {
            await coordinator.recoverPending();
            await coordinator.refreshMemoryNotes();
          },
        );
        scheduleMicrotask(recovery.start);
        ref.onDispose(recovery.dispose);
        return recovery;
      },
      dependencies: <ProviderOrFamily>[
        resolvedDeviceIdProvider,
        localDatabaseSnapshotStoreProvider,

        appBootstrapControllerProvider,
        sessionStoreProvider,
        materialIngestionCoordinatorProvider,
      ],
    );

// resident-provider: Preserves the v3 material upload controller state machine across route transitions.
final v3MaterialUploadControllerProvider =
    ChangeNotifierProvider<V3MaterialUploadController>((ref) {
      final materials = ref.watch(
        digitalTwinMaterialControllerProvider.notifier,
      );
      return V3MaterialUploadController(
        onDistillationJobReady: (jobId, title) => materials.enqueue(
          referenceKind: 'recording_job',
          referenceId: jobId,
          title: title,
        ),
        nativeFilePort: ref.watch(nativeFilePortProvider),
        repository: ref.watch(localRecordingRepositoryProvider),
        recordingUploadController: ref.watch(
          recordingUploadControllerProvider.notifier,
        ),
      );
    });

// resident-provider: Preserves the v3 document import controller state machine across route transitions.
final v3DocumentImportControllerProvider =
    ChangeNotifierProvider<V3DocumentImportController>((ref) {
      final controller = V3DocumentImportController(
        nativeFilePort: ref.watch(nativeFilePortProvider),
        knowledgeLibrary: ref.watch(
          knowledgeLibraryControllerProvider.notifier,
        ),
        profileHub: ref.read(profileHubControllerProvider),
        store: ref.watch(v3DocumentImportStoreProvider),
        analysisPort: ref.watch(documentAnalysisPortProvider),
        onDistillationNoteReady: (note) => ref
            .read(digitalTwinMaterialControllerProvider)
            .enqueue(
              referenceId: note.id,
              title: note.title,
              revisionHint: note.rawPartRevisionId ?? '',
            ),
      );
      scheduleMicrotask(controller.recoverPending);
      return controller;
    });

// resident-provider: Shares one document analysis port dependency for the full account session.
final documentAnalysisPortProvider = Provider<DocumentAnalysisPort>((ref) {
  try {
    return RemoteDocumentAnalysisPort(
      apiClient: ref.watch(apiClientProvider),
      workspaceId: () =>
          ref.read(sessionStoreProvider).state.workspace?.workspaceId,
    );
  } on StateError catch (error) {
    if (error.message == 'DEVICE_IDENTITY_NOT_RESOLVED') {
      return const UnavailableDocumentAnalysisPort();
    }
    rethrow;
  }
});

// resident-provider: Shares one document change proposal api dependency for the full account session.
final documentChangeProposalApiProvider =
    Provider<DocumentChangeProposalApiPort>((ref) {
      return RemoteDocumentChangeProposalApi(
        apiClient: ref.watch(apiClientProvider),
        workspaceId: () =>
            ref.read(sessionStoreProvider).state.workspace?.workspaceId,
      );
    });

// resident-provider: Shares one digital twin api dependency for the full account session.
final digitalTwinApiProvider = Provider<DigitalTwinApiPort>((ref) {
  final workspaceId = ref.watch(
    sessionStoreProvider.select((store) => store.state.workspace?.workspaceId),
  );
  return RemoteDigitalTwinApi(
    apiClient: ref.watch(apiClientProvider),
    workspaceId: () => workspaceId,
  );
});

final digitalTwinMaterialStoreProvider = Provider<DigitalTwinMaterialStore>((
  ref,
) {
  final owner = ref.watch(materialIngestionOwnerScopeProvider);
  final workspace = ref.watch(
    sessionStoreProvider.select((store) => store.state.workspace?.workspaceId),
  );
  return DigitalTwinMaterialStore(
    database: ref.watch(appDatabaseProvider),
    scope: '$owner:${workspace ?? 'unbound'}',
  );
});

final digitalTwinMaterialControllerProvider =
    ChangeNotifierProvider<DigitalTwinMaterialController>((ref) {
      return DigitalTwinMaterialController(
        store: ref.watch(digitalTwinMaterialStoreProvider),
        diagnosticLogger: ref.read(diagnosticLoggerProvider),
        apiFactory: () => ref.read(digitalTwinApiProvider),
        orchestrator: ref.read(taskOrchestratorProvider),
        activityMetrics: ref.read(runtimeActivityMetricsProvider),
        resolveSource: (material) async {
          final library = ref.read(knowledgeLibraryControllerProvider);
          var noteId = material.referenceId;
          if (material.referenceKind == 'ingestion') {
            final draft = ref
                .read(materialIngestionCoordinatorProvider)
                .drafts
                .where((entry) => entry.id == material.referenceId)
                .firstOrNull;
            if (draft?.isTerminal == true && draft?.noteId == null) {
              throw DigitalTwinApiException(
                draft?.lastErrorCode ?? 'DIGITAL_TWIN_SOURCE_UNAVAILABLE',
              );
            }
            if (draft?.noteId == null) return null;
            noteId = draft!.noteId!;
          } else if (material.referenceKind == 'recording_job') {
            final uploads = ref.read(
              recordingUploadControllerProvider.notifier,
            );
            var draft = uploads.draftForJob(material.referenceId);
            if (draft == null) {
              final local = ref
                  .read(localRecordingRepositoryProvider)
                  .list()
                  .rows
                  .where(
                    (item) => recordingFileJobId(item) == material.referenceId,
                  )
                  .firstOrNull;
              if (local == null)
                throw const DigitalTwinApiException(
                  'DIGITAL_TWIN_LOCAL_SOURCE_MISSING',
                );
              final created = await uploads.uploadLocalRecording(
                item: local,
                sourceScene: 'raw_material',
                fileSource: local.source == RecordingLibrarySource.localImport
                    ? RecordingFileSource.audioImport
                    : RecordingFileSource.recording,
                title: local.displayName,
              );
              if (created == null)
                throw DigitalTwinApiException(
                  uploads.state.lastErrorCode ??
                      'DIGITAL_TWIN_SOURCE_UNAVAILABLE',
                );
              draft = uploads.draftForJob(material.referenceId);
              if (draft == null) return null;
            }
            if (draft.stage == UploadDraftStage.asrFailed ||
                draft.stage == UploadDraftStage.cancelled) {
              throw DigitalTwinApiException(
                draft.lastErrorCode ?? 'DIGITAL_TWIN_SOURCE_UNAVAILABLE',
              );
            }
            final resolvedDraft = draft;
            final receipt = ref
                .read(recordingTranscriptionReceiptStoreProvider)
                .findByLocalRecordingId(resolvedDraft.localRecordingId);
            final note = library.notes
                .where(
                  (entry) =>
                      entry.recordingId == resolvedDraft.localRecordingId ||
                      (resolvedDraft.recordingId != null &&
                          entry.recordingId == resolvedDraft.recordingId),
                )
                .firstOrNull;
            if (receipt?.noteId == null && note?.remoteNoteId == null)
              return null;
            noteId = receipt?.noteId ?? note!.remoteNoteId!;
          }
          final note =
              library.noteForId(noteId) ??
              library.notes
                  .where((entry) => entry.remoteNoteId == noteId)
                  .firstOrNull;
          if (note?.isReadOnly == true) {
            throw const DigitalTwinApiException(
              'DIGITAL_TWIN_SOURCE_NOT_OWNED',
            );
          }
          final remoteId =
              note?.remoteNoteId ??
              (material.referenceKind != 'note' ? noteId : null);
          if (remoteId == null ||
              note?.syncState == NoteSyncState.pending ||
              note?.syncState == NoteSyncState.conflict)
            return null;
          final port = ref.read(knowledgeNotePortProvider);
          if (port is! KnowledgeNoteRemoteDetailPort) return null;
          final result = await (port as KnowledgeNoteRemoteDetailPort).loadNote(
            remoteId,
            localId: note?.id ?? noteId,
            fallback: note,
          );
          final canonical = result.remoteNote;
          if (result.status != KnowledgeNotePortStatus.success ||
              canonical == null) {
            throw DigitalTwinApiException(
              result.errorCode ?? 'DIGITAL_TWIN_SOURCE_UNAVAILABLE',
            );
          }
          final revision = canonical.rawPartRevisionId;
          final workspace = ref
              .read(sessionStoreProvider)
              .state
              .workspace
              ?.workspaceId;
          if (revision == null || workspace == null) return null;
          return DigitalTwinMaterialSource(
            workspaceId: workspace,
            noteId: canonical.remoteNoteId ?? remoteId,
            rawPartRevisionId: revision,
            title: canonical.title,
          );
        },
      );
    });

final digitalTwinControllerProvider =
    ChangeNotifierProvider.autoDispose<DigitalTwinController>((ref) {
      final imports = ref.watch(v3DocumentImportStoreProvider);
      final materials = ref.watch(digitalTwinMaterialStoreProvider);
      return DigitalTwinController(
        ref.watch(digitalTwinApiProvider),
        taskOrchestrator: ref.read(taskOrchestratorProvider),
        activityMetrics: ref.read(runtimeActivityMetricsProvider),
        recoveryStore: materials,
        initialRevisionEvents: materials.revisionEvents,
        onConfirmationCreated: (source, confirmationId) async {
          final task = imports
              .listTasks()
              .where(
                (task) =>
                    task.id == source.importTaskId &&
                    task.distillationTaskId == source.taskId,
              )
              .firstOrNull;
          if (task == null ||
              !await imports.saveAllDurably([
                task.copyWith(
                  digitalTwinConfirmationId: confirmationId,
                  updatedAt: DateTime.now().toUtc(),
                ),
              ])) {
            throw const DigitalTwinApiException(
              'DIGITAL_TWIN_CONFIRMATION_SAVE_FAILED',
            );
          }
        },
      );
    });

// resident-provider: Shares one account-scoped v3 document import store identity across dependent controllers.
final v3DocumentImportStoreProvider = Provider<V3DocumentImportStore>((ref) {
  return V3DocumentImportStore(
    database: ref.watch(appDatabaseProvider),
    rootDirectory: getApplicationSupportDirectory,
    ownerScope: ref.watch(materialIngestionOwnerScopeProvider),
  );
});

// resident-provider: Preserves the v3 media import controller state machine across route transitions.
final v3MediaImportControllerProvider =
    ChangeNotifierProvider<V3MediaImportController>((ref) {
      return V3MediaImportController(
        nativeFilePort: ref.watch(nativeFilePortProvider),
        knowledgeLibrary: ref.watch(
          knowledgeLibraryControllerProvider.notifier,
        ),
        profileHub: ref.read(profileHubControllerProvider),
      );
    });

// resident-provider: Preserves the recording detail controller state machine across route transitions.
final recordingDetailControllerProvider =
    ChangeNotifierProvider<RecordingDetailController>((ref) {
      // A detail may contain a complete transcript; discard it on account
      // transition before any route can render the prior user's state.
      final accountScope = ref.watch(authenticatedRecordingUserScopeProvider);
      final sessionStore = ref.read(sessionStoreProvider);
      final processingTracker = ref.watch(
        recordingProcessingTrackerProvider.notifier,
      );
      return RecordingDetailController(
        api: ref.watch(recordingApiProvider),
        processingRetryPort: processingTracker,
        processingObservationPort: processingTracker,
        speakerAutoAdvancePort: processingTracker,
        accountScope: accountScope,
        activeAccountScope: () {
          final state = sessionStore.state;
          if (state.authState != SessionAuthState.authenticated) return null;
          final userId = state.user?.userId.trim();
          return userId == null || userId.isEmpty ? null : userId;
        },
      );
    });

// resident-provider: Keeps the push runtime config value consistent across sibling route consumers.
final pushRuntimeConfigProvider = Provider<PushRuntimeConfig>((ref) {
  return PushRuntimeConfig.fromEnvironment();
});

// resident-provider: Preserves the push provider dependency identity across route changes.
final pushProviderProvider = Provider<PushProvider>((ref) {
  final config = ref.watch(pushRuntimeConfigProvider);
  if (!config.isConfigured) return const UnavailablePushProvider();
  final provider = JPushProvider(
    config: config,
    permissions: ref.watch(platformPermissionsPortProvider),
  );
  ref.onDispose(() => unawaited(provider.dispose()));
  return provider;
});

// resident-provider: Shares one push device api dependency for the full account session.
final pushDeviceApiProvider = Provider<PushDeviceApiPort>((ref) {
  if (!ref.watch(pushProviderProvider).isConfigured) {
    return const UnavailablePushDeviceApi();
  }
  return PushDeviceApi(apiClient: ref.watch(apiClientProvider));
});

// resident-provider: Preserves the push navigation controller state machine across route transitions.
final pushNavigationControllerProvider =
    ChangeNotifierProvider<PushNavigationController>((ref) {
      return PushNavigationController(
        recordingBatchContextResolver: (recordingId) {
          final inMemory = ref
              .read(recordingBatchTranscriptionControllerProvider)
              .notificationBatchContextForRemoteRecording(recordingId);
          final context =
              inMemory ??
              recordingNotificationBatchContext(
                ref
                    .read(recordingBatchTranscriptionStoreProvider)
                    .loadBatches(),
                recordingId,
              );
          return context == null
              ? null
              : (batchId: context.batchId, itemId: context.itemId);
        },
      );
    });

// resident-provider: Preserves the push registration controller state machine across route transitions.
final pushRegistrationControllerProvider =
    ChangeNotifierProvider<PushRegistrationController>((ref) {
      final provider = ref.watch(pushProviderProvider);
      if (!provider.isConfigured) {
        return PushRegistrationController(
          provider: provider,
          api: const UnavailablePushDeviceApi(),
          sessionStore: ref.watch(sessionStoreProvider.notifier),
          deviceId: 'push-unconfigured',
          platform: Platform.isIOS ? 'ios' : 'android',
          appVersion: () async => 'unconfigured',
        );
      }
      return PushRegistrationController(
        provider: provider,
        api: ref.watch(pushDeviceApiProvider),
        sessionStore: ref.watch(sessionStoreProvider.notifier),
        deviceId: ref.watch(resolvedDeviceIdProvider),
        platform: Platform.isIOS ? 'ios' : 'android',
        preferences: ref.watch(appPreferencesDaoProvider),
        appVersion: () async => (await PackageInfo.fromPlatform()).version,
      );
    });

// resident-provider: Preserves the push runtime controller state machine across route transitions.
final pushRuntimeControllerProvider =
    ChangeNotifierProvider<PushRuntimeController>((ref) {
      return PushRuntimeController(
        provider: ref.watch(pushProviderProvider),
        notifications: ref.watch(notificationControllerProvider.notifier),
        navigation: ref.watch(pushNavigationControllerProvider.notifier),
        registration: ref.watch(pushRegistrationControllerProvider.notifier),
        sessionStore: ref.watch(sessionStoreProvider.notifier),
      );
    });

// resident-provider: Shares one recording card port dependency for the full account session.
final recordingCardPortProvider = Provider<RecordingCardPort>((ref) {
  ref.watch(authenticatedRecordingUserScopeProvider);
  final port = MethodChannelRecordingCardPort();
  ref.onDispose(() => unawaited(port.dispose()));
  return port;
});

// resident-provider: Shares one account-scoped recording card connection history store identity across dependent controllers.
final recordingCardConnectionHistoryStoreProvider =
    Provider<RecordingCardConnectionHistoryStore>((ref) {
      return RecordingCardConnectionHistoryStore(
        preferences: ref.watch(appPreferencesDaoProvider),
        accountScope: ref.watch(authenticatedUserDataScopeProvider),
      );
    });

// resident-provider: Shares one account-scoped recording card sn authorization cache identity across dependent controllers.
final recordingCardSnAuthorizationCacheProvider =
    Provider<RecordingCardSnAuthorizationCachePort>((ref) {
      final accountScope = ref.watch(authenticatedRecordingUserScopeProvider);
      if (accountScope == null) {
        return const UnavailableRecordingCardSnAuthorizationCache();
      }
      return SecureRecordingCardSnAuthorizationCache(
        driver: ref.watch(secureTokenDriverProvider),
        accountScope: accountScope,
      );
    });

// resident-provider: Preserves the recording card controller state machine across route transitions.
final recordingCardControllerProvider =
    ChangeNotifierProvider<RecordingCardController>((ref) {
      final authenticatedUserScope = ref.watch(
        authenticatedRecordingUserScopeProvider,
      );
      final recordingCardPort = ref.watch(recordingCardPortProvider);
      final RecordingCardOwnershipProofPort ownershipPort =
          recordingCardPort is RecordingCardOwnershipProofPort
          ? recordingCardPort as RecordingCardOwnershipProofPort
          : const UnavailableRecordingCardOwnershipProofPort();
      return RecordingCardController(
        port: recordingCardPort,
        localRecordingRepository: ref.watch(localRecordingRepositoryProvider),
        syncLedgerPersistence: ref.watch(recordingCardAutoSyncStoreProvider),
        platformPermissionsPort: ref.watch(platformPermissionsPortProvider),
        deviceIdentityStore: ref.watch(deviceIdentityStoreProvider),
        connectionAuthorization: RecordingCardCloudConnectionAuthorization(
          port: ref.watch(recordingCardCloudBindingPortProvider),
          ownership: ownershipPort,
          authenticated: authenticatedUserScope != null,
          authorizationCache: ref.watch(
            recordingCardSnAuthorizationCacheProvider,
          ),
        ),
        connectionHistory: ref.watch(
          recordingCardConnectionHistoryStoreProvider,
        ),
      );
    });

// resident-provider: Shares one account-scoped recording card auto sync store identity across dependent controllers.
final recordingCardAutoSyncStoreProvider = Provider<RecordingCardAutoSyncStore>(
  (ref) {
    return RecordingCardAutoSyncStore(
      database: ref.watch(appDatabaseProvider),
      accountScope: ref.watch(authenticatedUserDataScopeProvider),
    );
  },
);

final class _RecordingCardLocalDeletionLedgerAdapter
    implements LocalRecordingDeletionLedgerPort {
  const _RecordingCardLocalDeletionLedgerAdapter(this._store);

  final RecordingCardAutoSyncStore _store;

  @override
  Iterable<String> deletionInProgressLocalRecordingIds() sync* {
    final seen = <String>{};
    for (final cardSnDigest in _store.loadKnownCardDigests()) {
      for (final entry in _store.loadFileLedger(cardSnDigest)) {
        final localRecordingId = entry.localRecordingId?.trim();
        if (entry.localState == RecordingCardFileLocalState.deleting &&
            localRecordingId != null &&
            localRecordingId.isNotEmpty &&
            seen.add(localRecordingId)) {
          yield localRecordingId;
        }
      }
    }
  }

  @override
  bool canStartUpload(String localRecordingId) {
    final entries = _store.findFileLedgerEntriesByLocalRecordingId(
      localRecordingId,
    );
    return entries.every(
      (entry) => entry.localState != RecordingCardFileLocalState.deleting,
    );
  }

  @override
  bool beginLocalDeletion(String localRecordingId, DateTime at) {
    final entries = _store.findFileLedgerEntriesByLocalRecordingId(
      localRecordingId,
    );
    if (entries.isEmpty) return false;
    _store.saveFileLedgerEntries(
      entries.map((entry) => entry.beginLocalDeletion(at)),
    );
    return true;
  }

  @override
  void finishLocalDeletion(String localRecordingId, DateTime at) {
    final entries = _store.findFileLedgerEntriesByLocalRecordingId(
      localRecordingId,
    );
    _store.saveFileLedgerEntries(
      entries.map((entry) => entry.finishLocalDeletion(at)),
    );
  }

  @override
  void restoreLocalDeletion(String localRecordingId, DateTime at) {
    final entries = _store.findFileLedgerEntriesByLocalRecordingId(
      localRecordingId,
    );
    _store.saveFileLedgerEntries(
      entries.map((entry) => entry.restoreLocalDeletion(at)),
    );
  }
}

final recordingCardAutoSyncCoordinatorProvider =
    ChangeNotifierProvider.autoDispose<RecordingCardAutoSyncCoordinator>((ref) {
      return RecordingCardAutoSyncCoordinator(
        persistence: ref.watch(recordingCardAutoSyncStoreProvider),
        actions: ControllerRecordingCardAutoSyncActions(
          ref.watch(recordingCardControllerProvider.notifier),
        ),
        taskOrchestrator: ref.watch(taskOrchestratorProvider),
        transcriptionPort: DeferredRecordingCardAutoTranscriptionPort(
          () => RecordingUploadAutoTranscriptionPort(
            repository: ref.read(localRecordingRepositoryProvider),
            uploadController: ref.read(
              recordingUploadControllerProvider.notifier,
            ),
            completionPort: ref.read(
              recordingProcessingTrackerProvider.notifier,
            ),
          ),
        ),
        backgroundExecutionPort:
            const MethodChannelRecordingCardBackgroundExecutionPort(),
      );
    });

// resident-provider: Keeps a user-started quick Wi-Fi transfer independent of route and sheet lifetimes.
final recordingCardQuickWifiCoordinatorProvider =
    ChangeNotifierProvider<RecordingCardQuickWifiCoordinator>((ref) {
      final card = ref.watch(recordingCardControllerProvider.notifier);
      final automaticSync = ref.watch(
        recordingCardAutoSyncCoordinatorProvider.notifier,
      );
      final library = ref.watch(recordingLibraryControllerProvider.notifier);
      return RecordingCardQuickWifiCoordinator(
        runtime: ControllerRecordingCardQuickWifiRuntime(
          controller: card,
          automaticSync: automaticSync,
          candidateResolver: (directory, cardSnDigest) {
            return buildRecordingCardFilePresentations(
                  directory: directory,
                  ledger: ref
                      .read(recordingCardAutoSyncStoreProvider)
                      .loadFileLedger(cardSnDigest),
                  cardSnDigest: cardSnDigest,
                  card: card.state,
                  localRecordingLookup: library.findById,
                  localInventoryLoaded: library.state.hasVerifiedInventory,
                )
                .where((item) => item.status.isAutomaticCandidate)
                .map((item) {
                  return item.file;
                })
                .toList(growable: false);
          },
        ),
      );
    });

// resident-provider: Shares one recording card cloud binding port dependency for the full account session.
final recordingCardCloudBindingPortProvider =
    Provider<RecordingCardCloudBindingPort>((ref) {
      return const UnavailableRecordingCardCloudBindingRepository();
    });

// resident-provider: Preserves the recording card cloud binding controller state machine across route transitions.
final recordingCardCloudBindingControllerProvider =
    ChangeNotifierProvider<RecordingCardCloudBindingController>((ref) {
      final session = ref.watch(sessionStoreProvider).state;
      final recordingCardPort = ref.watch(recordingCardPortProvider);
      final RecordingCardOwnershipProofPort ownershipPort =
          recordingCardPort is RecordingCardOwnershipProofPort
          ? recordingCardPort as RecordingCardOwnershipProofPort
          : const UnavailableRecordingCardOwnershipProofPort();
      final controller = RecordingCardCloudBindingController(
        port: ref.watch(recordingCardCloudBindingPortProvider),
        hardware: RecordingCardControllerCloudBindingHardware(
          ref.read(recordingCardControllerProvider),
          ownershipPort,
        ),
        authenticated:
            session.authState == SessionAuthState.authenticated &&
            session.user != null,
        authorizationCache: ref.watch(
          recordingCardSnAuthorizationCacheProvider,
        ),
        onUnbound: () async {
          final recordingCard = ref.read(recordingCardControllerProvider);
          if (recordingCard
              .state
              .snapshot
              .deviceState
              .isOperationallyConnected) {
            await recordingCard.disconnect();
          }
        },
      );
      return controller;
    });

// resident-provider: Shares one note append port dependency for the full account session.
final noteAppendPortProvider = Provider<NoteAppendPort>((ref) {
  return const UnavailableNoteAppendPort();
});

// resident-provider: Preserves the note append controller state machine across route transitions.
final noteAppendControllerProvider =
    ChangeNotifierProvider<NoteAppendController>((ref) {
      // Watching the owner scope makes all demo append state session-bound.
      ref.watch(authenticatedUserDataScopeProvider);
      return NoteAppendController(
        knowledgeLibrary: ref.watch(
          knowledgeLibraryControllerProvider.notifier,
        ),
        port: ref.watch(noteAppendPortProvider),
      );
    });

// resident-provider: Shares one account-scoped diagnostic log dao identity across dependent controllers.
final diagnosticLogDaoProvider = Provider<DiagnosticLogDao>((ref) {
  final runtime = ref.watch(databaseWorkerRuntimeProvider);
  return DiagnosticLogDao(
    ref.watch(appDatabaseProvider),
    worker: runtime,
    writeQueue: runtime.writeQueue,
  );
});

// resident-provider: Preserves the diagnostic logger dependency identity across route changes.
final diagnosticLoggerProvider = Provider<DiagnosticLogger>((ref) {
  final activity = ref.watch(appActivityCoordinatorProvider.notifier);
  final logger = DiagnosticLogger(
    dao: ref.watch(diagnosticLogDaoProvider),
    flushInterval: const Duration(seconds: 1),
    canDeferFlush: () => activity.state.isForeground,
  );
  ref.listen<bool>(
    appActivityCoordinatorProvider.select(
      (coordinator) => coordinator.state.isForeground,
    ),
    (_, foreground) {
      if (foreground) return;
      try {
        logger.flush();
      } catch (_) {}
    },
  );
  ref.onDispose(logger.dispose);
  return logger;
});

// resident-provider: Shares one diagnostic export service dependency for the full account session.
final diagnosticExportServiceProvider = Provider<DiagnosticExportService>((
  ref,
) {
  return DiagnosticExportService(
    dao: ref.watch(diagnosticLogDaoProvider),
    performanceSnapshot: () {
      final compressed = ref.read(resourceImageCacheProvider);
      return ref
          .read(appPerformanceRuntimeProvider)
          .capture(
            compressedImageCache: <String, Object?>{
              'available': true,
              'currentEntries': compressed.memoryEntryCount,
              'currentBytes': compressed.memoryBytes,
              'maximumBytes': compressed.memoryLimitBytes,
              'diskMaximumBytes': compressed.diskLimitBytes,
            },
          );
    },
  );
});

class AppProviders extends StatelessWidget {
  const AppProviders({
    required this.child,
    this.snapshotStoreFactory,
    this.snapshotStoreTimeout = const Duration(seconds: 8),
    this.deviceIdentityStore,
    this.deviceIdentityTimeout = const Duration(seconds: 8),
    this.runtimeClientMetadata,
    super.key,
  });

  final Widget child;
  final Future<LocalDatabaseSnapshotStore> Function()? snapshotStoreFactory;
  final Duration snapshotStoreTimeout;
  final DeviceIdentityStore? deviceIdentityStore;
  final Duration deviceIdentityTimeout;
  final RuntimeClientMetadata? runtimeClientMetadata;

  @override
  Widget build(BuildContext context) {
    return _AppProvidersBootstrap(
      snapshotStoreFactory: snapshotStoreFactory,
      snapshotStoreTimeout: snapshotStoreTimeout,
      deviceIdentityStore: deviceIdentityStore,
      deviceIdentityTimeout: deviceIdentityTimeout,
      runtimeClientMetadata: runtimeClientMetadata,
      child: child,
    );
  }
}

class _AppProvidersBootstrap extends StatefulWidget {
  const _AppProvidersBootstrap({
    required this.child,
    required this.snapshotStoreFactory,
    required this.snapshotStoreTimeout,
    required this.deviceIdentityStore,
    required this.deviceIdentityTimeout,
    required this.runtimeClientMetadata,
  });

  final Widget child;
  final Future<LocalDatabaseSnapshotStore> Function()? snapshotStoreFactory;
  final Duration snapshotStoreTimeout;
  final DeviceIdentityStore? deviceIdentityStore;
  final Duration deviceIdentityTimeout;
  final RuntimeClientMetadata? runtimeClientMetadata;

  @override
  State<_AppProvidersBootstrap> createState() => _AppProvidersBootstrapState();
}

class _AppProvidersBootstrapState extends State<_AppProvidersBootstrap> {
  LocalDatabaseSnapshotStore? _snapshotStore;
  Object? _snapshotError;
  String? _deviceId;
  Object? _deviceIdentityError;
  RuntimeClientMetadata? _runtimeMetadata;
  List<Override>? _rootOverrides;

  @override
  void initState() {
    super.initState();
    _resolveSnapshotStore();
    _resolveDeviceIdentity();
    _runtimeMetadata = widget.runtimeClientMetadata;
    if (_runtimeMetadata == null) _resolveRuntimeMetadata();
  }

  Future<void> _resolveSnapshotStore() async {
    try {
      final factory = widget.snapshotStoreFactory ?? _defaultSnapshotStore;
      final snapshotStore = await factory().timeout(
        widget.snapshotStoreTimeout,
      );
      if (!mounted) return;
      setState(() {
        _snapshotStore = snapshotStore;
        _snapshotError = null;
      });
    } on TimeoutException {
      if (!mounted) return;
      _logBootstrapFailure(
        stage: 'local_database',
        code: 'LOCAL_DATABASE_INIT_TIMEOUT',
      );
      setState(() {
        _snapshotError = 'LOCAL_DATABASE_INIT_TIMEOUT';
      });
    } catch (error) {
      if (!mounted) return;
      _logBootstrapFailure(
        stage: 'local_database',
        code: _safeBootstrapError(error),
      );
      setState(() {
        _snapshotError = error;
      });
    }
  }

  Future<void> _resolveDeviceIdentity() async {
    try {
      final DeviceIdentityStore store =
          widget.deviceIdentityStore ?? _defaultDeviceIdentityStore();
      final deviceId = await store.resolve().timeout(
        widget.deviceIdentityTimeout,
      );
      if (!mounted) return;
      setState(() {
        _deviceId = deviceId;
        _deviceIdentityError = null;
      });
    } on TimeoutException {
      if (!mounted) return;
      _logBootstrapFailure(
        stage: 'device_identity',
        code: 'DEVICE_IDENTITY_INIT_TIMEOUT',
      );
      setState(() {
        _deviceIdentityError = 'DEVICE_IDENTITY_INIT_TIMEOUT';
      });
    } catch (error) {
      if (!mounted) return;
      _logBootstrapFailure(
        stage: 'device_identity',
        code: _safeBootstrapError(
          error,
          fallback: 'DEVICE_IDENTITY_INIT_FAILED',
        ),
      );
      setState(() {
        _deviceIdentityError = error;
      });
    }
  }

  void _retryFailedDependencies() {
    final retryDeviceIdentity = _deviceIdentityError != null;
    final retrySnapshotStore = _snapshotError != null;
    if (!retryDeviceIdentity && !retrySnapshotStore) return;
    debugPrint(
      'HUAHUO_BOOTSTRAP_RETRY '
      'device_identity=$retryDeviceIdentity '
      'local_database=$retrySnapshotStore',
    );
    setState(() {
      if (retryDeviceIdentity) _deviceIdentityError = null;
      if (retrySnapshotStore) _snapshotError = null;
    });
    if (retryDeviceIdentity) _resolveDeviceIdentity();
    if (retrySnapshotStore) _resolveSnapshotStore();
  }

  Future<void> _resolveRuntimeMetadata() async {
    final metadata = await resolveRuntimeClientMetadata(
      readNativeTimeZone: readHuahuoPlatformIanaTimeZone,
      readPackageMetadata: () async {
        final package = await PackageInfo.fromPlatform();
        return RuntimePackageMetadata(
          version: package.version,
          buildNumber: package.buildNumber,
        );
      },
      dartTimeZoneName: DateTime.now().timeZoneName,
      platform: Platform.isIOS ? 'ios' : 'android',
      locale: Platform.localeName.replaceAll('_', '-'),
    );
    if (!mounted) return;
    setState(() => _runtimeMetadata = metadata);
  }

  @override
  Widget build(BuildContext context) {
    final snapshotStore = _snapshotStore;
    final snapshotError = _snapshotError;
    final deviceId = _deviceId;
    final deviceIdentityError = _deviceIdentityError;
    final runtimeMetadata = _runtimeMetadata;
    if (deviceIdentityError != null) {
      return _BootstrapDependencyStatus(
        message: _safeBootstrapError(
          deviceIdentityError,
          fallback: 'DEVICE_IDENTITY_INIT_FAILED',
        ),
        onRetry: _retryFailedDependencies,
      );
    }
    if (snapshotError != null) {
      return _BootstrapDependencyStatus(
        message: _safeBootstrapError(snapshotError),
        onRetry: _retryFailedDependencies,
      );
    }
    if (deviceId == null) {
      return const _BootstrapDependencyStatus(message: 'DEVICE_IDENTITY_INIT');
    }
    if (snapshotStore == null) {
      return const _BootstrapDependencyStatus(message: 'LOCAL_DATABASE_INIT');
    }
    if (runtimeMetadata == null) {
      return const _BootstrapDependencyStatus(message: 'CLIENT_METADATA_INIT');
    }
    final rootOverrides = _rootOverrides ??= [
      resolvedDeviceIdProvider.overrideWithValue(deviceId),
      runtimeClientMetadataProvider.overrideWithValue(runtimeMetadata),
      localDatabaseSnapshotStoreProvider.overrideWithValue(snapshotStore),
      knowledgeLibraryDemoFixturesEnabledProvider.overrideWithValue(false),
      knowledgeLibraryAutoSyncOwnedChangesProvider.overrideWithValue(true),
      knowledgeLibraryCacheScopeProvider.overrideWith((ref) {
        return knowledgeLibraryWorkspaceCacheScope(
          ref.watch(authenticatedUserDataScopeProvider),
          ref.watch(sessionStoreProvider).state,
        );
      }),
      knowledgeLibraryRemoteCacheTtlProvider.overrideWith((ref) {
        return () => ref.read(appCachePolicyProvider).cacheTtl;
      }),
      knowledgeNoteSyncJournalProvider.overrideWith((ref) {
        final userScope = ref.watch(authenticatedUserDataScopeProvider);
        final workspaceId = ref.watch(
          sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
        );
        final runtime = ref.watch(databaseWorkerRuntimeProvider);
        if (userScope == 'anonymous' ||
            workspaceId == null ||
            !runtime.configured) {
          return null;
        }
        return DatabaseKnowledgeNoteSyncJournal(
          database: runtime,
          userScope: userScope,
          workspaceId: workspaceId,
        );
      }),
      workspaceContentSyncFactoryProvider.overrideWith((ref) {
        final userScope = ref.watch(authenticatedUserDataScopeProvider);
        final workspaceId = ref.watch(
          sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
        );
        if (userScope == 'anonymous' || workspaceId == null) {
          return (KnowledgeLibraryController _) => null;
        }
        final remote = ApiWorkspaceContentSyncRemotePort.fromApiClient(
          ref.watch(apiClientProvider),
        );
        final store = WorkspaceContentSyncStore(
          preferences: ref.watch(appPreferencesDaoProvider),
          userScope: userScope,
          workspaceId: workspaceId,
        );
        return (controller) => WorkspaceContentSync(
          remote: remote,
          store: store,
          workspaceId: workspaceId,
          readProjection: () => controller.notes,
          readProjectionCursor: () => controller.workspaceContentCursor,
          applyProjection: controller.applyWorkspaceContentProjection,
          applyFolderProjection: controller.applyWorkspaceFolderProjection,
          noteSyncJournal: ref.watch(knowledgeNoteSyncJournalProvider),
        );
      }),
      workspaceFolderPortProvider.overrideWith((ref) {
        final workspaceId = ref.watch(
          sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
        );
        return ApiWorkspaceFolderPort(
          apiClient: ref.watch(apiClientProvider),
          workspaceId: () => workspaceId,
        );
      }),
      knowledgeNotePortProvider.overrideWith((ref) {
        final workspaceId = ref.watch(
          sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
        );
        return RemoteKnowledgeNotePort(
          apiClient: ref.watch(apiClientProvider),
          workspaceId: () => workspaceId,
        );
      }),
      topicCollisionRunPortProvider.overrideWith((ref) {
        return RemoteTopicCollisionRunPort(
          TopicCollisionClient(ref.watch(apiClientProvider)),
        );
      }),
      feedAggregationControllerProvider.overrideWith((ref) {
        final sessionStore = ref.read(sessionStoreProvider);
        return FeedAggregationController(
          library: ref.watch(knowledgeLibraryControllerProvider.notifier),
          profileHub: ref.read(profileHubControllerProvider),
          repository: ref.read(feedAggregationRepositoryProvider),
          topicCollisionRuns: ref.watch(topicCollisionRunPortProvider),
          diagnosticLogger: ref.watch(diagnosticLoggerProvider),
          preferences: ref.watch(appPreferencesDaoProvider),
          userScope: ref.watch(authenticatedUserDataScopeProvider),
          workspaceId: () => sessionStore.state.workspace?.workspaceId,
          workspaceReady: () {
            final state = sessionStore.state;
            return state.authState == SessionAuthState.authenticated &&
                state.workspaceStatus == SessionWorkspaceStatus.ready &&
                state.workspace?.workspaceId?.trim().isNotEmpty == true;
          },
        );
      }),
      mobileSubscriptionPortProvider.overrideWith((ref) {
        final privateScope = ref.watch(knowledgeLibraryCacheScopeProvider);
        final workspaceId = privateScope == 'anonymous'
            ? null
            : ref.watch(
                sessionStoreProvider.select(
                  (store) => readyWorkspaceId(store.state),
                ),
              );
        return RemoteMobileSubscriptionPort(
          apiClient: ref.watch(apiClientProvider),
          workspaceId: () => workspaceId,
        );
      }),
      mobileWorkspaceSearchPortProvider.overrideWith((ref) {
        return RemoteMobileWorkspaceSearchPort(
          apiClient: ref.watch(apiClientProvider),
          workspaceId: () =>
              ref.read(sessionStoreProvider).state.workspace?.workspaceId,
        );
      }),
      mobileNoteRelationPortProvider.overrideWith((ref) {
        return RemoteMobileNoteRelationPort(
          apiClient: ref.watch(apiClientProvider),
          workspaceId: () =>
              ref.read(sessionStoreProvider).state.workspace?.workspaceId,
        );
      }),
      accountUsageRepositoryProvider.overrideWith((ref) {
        final identity = ref.watch(
          sessionStoreProvider.select(
            (store) => (
              store.state.authState,
              store.state.user?.userId,
              store.state.workspace?.workspaceId,
            ),
          ),
        );
        return RemoteAccountUsageRepository(
          client: AccountUsageClient(ref.watch(apiClientProvider)),
          workspaceClient: WorkspaceLifecycleClient(
            ref.watch(apiClientProvider),
          ),
          workspaceId: () => identity.$3,
        );
      }),
      recordingCardCloudBindingPortProvider.overrideWith((ref) {
        return RemoteRecordingCardCloudBindingRepository(
          ref.watch(apiClientProvider),
        );
      }),
      mobileBookWorkPortProvider.overrideWith((ref) {
        return RemoteMobileBookWorkPort(ref.watch(apiClientProvider));
      }),
      mobileBookWorkIdentityProvider.overrideWith((ref) {
        final session = ref.watch(sessionStoreProvider).state;
        if (session.authState != SessionAuthState.authenticated) {
          return const MobileBookWorkIdentity.anonymous();
        }
        return MobileBookWorkIdentity(
          userId: session.user?.userId,
          workspaceId: session.workspace?.workspaceId,
        );
      }),

      materialIngestionOwnerScopeProvider.overrideWith((ref) {
        return knowledgeLibraryWorkspaceCacheScope(
          ref.watch(authenticatedUserDataScopeProvider),
          ref.watch(sessionStoreProvider).state,
        );
      }),
      settingsControllerProvider.overrideWith((ref) {
        return SettingsController(
          permissionsPort: ref.watch(platformPermissionsPortProvider),
          diagnosticLogDao: ref.watch(diagnosticLogDaoProvider),
          diagnosticLogger: ref.watch(diagnosticLoggerProvider),
          diagnosticExportService: ref.watch(diagnosticExportServiceProvider),
          requestNotificationPermission: () async {
            final granted = await ref
                .read(pushRegistrationControllerProvider.notifier)
                .requestPermission();
            if (granted) {
              await ref.read(pushRuntimeControllerProvider.notifier).start();
            }
            return granted;
          },
        );
      }),
      appAppearanceRepositoryProvider.overrideWith((ref) {
        return ref.watch(deviceAppAppearanceRepositoryProvider);
      }),
      photoAlbumRepositoryProvider.overrideWith((ref) {
        return ref.watch(scopedPhotoAlbumRepositoryProvider);
      }),
      noteMetricsRepositoryProvider.overrideWith((ref) {
        return ref.watch(scopedNoteMetricsRepositoryProvider);
      }),
      assetGrowthPeriodRepositoryProvider.overrideWith((ref) {
        return AssetGrowthPeriodRepository(
          dao: ref.watch(appPreferencesDaoProvider),
          userScope: ref.watch(authenticatedUserDataScopeProvider),
        );
      }),
      noteMetricsReadCacheProvider.overrideWith((ref) {
        return ref.watch(scopedNoteMetricsReadCacheProvider);
      }),
      photoAlbumNativeFilePortProvider.overrideWith((ref) {
        return ref.watch(nativeFilePortProvider);
      }),
      photoAlbumMetadataCacheProvider.overrideWith((ref) {
        final userScope = ref.watch(authenticatedUserDataScopeProvider);
        final workspaceId = ref
            .watch(sessionStoreProvider)
            .state
            .workspace
            ?.workspaceId
            ?.trim();
        if (userScope == 'anonymous' ||
            workspaceId == null ||
            workspaceId.isEmpty) {
          return null;
        }
        return PhotoAlbumMetadataCache(
          preferences: ref.watch(appPreferencesDaoProvider),
          ownerScope: '$userScope\u0000$workspaceId',
        );
      }),
      knowledgeDepositRepositoryProvider.overrideWith((ref) {
        return ref.watch(v3DepositRepositoryProvider);
      }),
      knowledgeUserMetadataRepositoryProvider.overrideWith((ref) {
        return ref.watch(scopedKnowledgeUserMetadataRepositoryProvider);
      }),
      hotspotNoteRepositoryProvider.overrideWith((ref) {
        return ApiHotspotNoteRepository(ref.watch(apiClientProvider));
      }),
      profileWorkspaceRepositoryProvider.overrideWith((ref) {
        return ref.watch(scopedProfileWorkspaceRepositoryProvider);
      }),
      deepPositioningRepositoryProvider.overrideWith((ref) {
        final userScope = ref.watch(authenticatedUserDataScopeProvider);
        final workspaceId = ref.watch(
          sessionStoreProvider.select(
            (store) => store.state.workspace?.workspaceId?.trim(),
          ),
        );
        if (userScope == 'anonymous' ||
            workspaceId == null ||
            workspaceId.isEmpty) {
          return const UnavailableDeepPositioningRepository();
        }
        final session = ref.read(sessionStoreProvider);
        final userId = session.state.user?.userId;
        var valid = true;
        void invalidateScope() {
          if (session.state.user?.userId != userId ||
              session.state.workspace?.workspaceId?.trim() != workspaceId ||
              session.state.authState != SessionAuthState.authenticated)
            valid = false;
        }

        session.addListener(invalidateScope);
        ref.onDispose(() {
          valid = false;
          session.removeListener(invalidateScope);
        });
        return PersistentDeepPositioningRepository(
          dao: ref.watch(appPreferencesDaoProvider),
          userScope: '$userScope\u0000$workspaceId',
          remote: WorkspaceProfileDeepPositioningRemote(
            workspaceId: workspaceId,
            isCurrent: () => valid,
            workspaceClient: WorkspaceLifecycleClient(
              ref.watch(apiClientProvider),
            ),
          ),
        );
      }),
      initialPositioningReportSinkProvider.overrideWith((ref) {
        return ref.watch(deepPositioningControllerProvider.notifier);
      }),
      creationCanvasHistoryPortProvider.overrideWith((ref) {
        return ref.watch(scopedCreationCanvasHistoryPortProvider);
      }),
      graphIdProvider.overrideWith((ref) {
        const configured = String.fromEnvironment('HUAHUO_WORKSPACE_ID');
        return resolveRuntimeGraphId(
          configuredWorkspaceId: configured,
          sessionWorkspaceId: ref
              .watch(sessionStoreProvider)
              .state
              .workspace
              ?.workspaceId,
        );
      }),
      graphRepositoryProvider.overrideWith((ref) {
        if (ref.watch(graphIdProvider) == null) return null;
        return ref.watch(remoteGraphRepositoryProvider);
      }),
    ];
    return ProviderScope(overrides: rootOverrides, child: widget.child);
  }
}

DeviceIdentityStore _defaultDeviceIdentityStore() {
  return DeviceIdentityStore(
    driver: ResilientDeviceIdentityDriver(
      primary: const FlutterSecureDeviceIdentityDriver(),
      fallback: ApplicationSupportDeviceIdentityDriver(),
    ),
  );
}

Future<LocalDatabaseSnapshotStore> _defaultSnapshotStore() async {
  final documents = await getApplicationDocumentsDirectory();
  return LocalDatabaseSnapshotStore(
    file: File('${documents.path}/recordings/local-recording-metadata.sqlite'),
    backend: LocalDatabaseSnapshotBackend.sqlite,
  );
}

Future<Stream<List<int>>> _openPrivateUploadReadStream(
  String appPrivateUri,
  PrivateRecordingPathResolver recordingResolver,
  PrivateMediaPathResolver mediaResolver,
) async {
  final file = appPrivateUri.startsWith('app-private-media://')
      ? await mediaResolver.resolveFile(appPrivateUri)
      : await recordingResolver.resolveFile(appPrivateUri);
  if (file == null) {
    throw StateError('UPLOAD_PRIVATE_MEDIA_URI_UNSAFE');
  }
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError('UPLOAD_PRIVATE_MEDIA_FILE_MISSING');
  }
  return file.openRead();
}

Future<int?> _probeAudioDuration(File file) async {
  final player = AudioPlayer();
  try {
    final duration = await player.setFilePath(file.path);
    final milliseconds = duration?.inMilliseconds ?? 0;
    final seconds = (milliseconds + 999) ~/ 1000;
    return seconds > 0 ? seconds : null;
  } finally {
    await player.dispose();
  }
}

class _BootstrapDependencyStatus extends StatelessWidget {
  const _BootstrapDependencyStatus({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (message.endsWith('_INIT')) {
      return const ColoredBox(
        color: Color(0xFFFFFFFF),
        child: V3LaunchBrandLockup(),
      );
    }
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final surface = dark ? const Color(0xFF111817) : const Color(0xFFFFFFFF);
    final foreground = dark ? const Color(0xFFF3F7F5) : const Color(0xFF111827);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const V3BrandMark(dimension: 112),
                const SizedBox(height: 18),
                Text(
                  '初始化失败',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: foreground.withValues(alpha: .62)),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 12),
                  TextButton(onPressed: onRetry, child: const Text('重试')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _safeBootstrapError(
  Object error, {
  String fallback = 'LOCAL_DATABASE_INIT_FAILED',
}) {
  final text = error.toString();
  return RegExp(r'^[A-Z0-9_]{2,64}$').hasMatch(text) ? text : fallback;
}

void _logBootstrapFailure({required String stage, required String code}) {
  debugPrint('HUAHUO_BOOTSTRAP_FAILURE stage=$stage code=$code');
}
