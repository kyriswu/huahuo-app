import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test(
    'long scoped worker keys preserve writes, isolation and deletes',
    () async {
      final root = await Directory.systemTemp.createTemp('long-worker-key-');
      final file = File('${root.path}/local.sqlite');
      final persistence = LocalDatabaseSnapshotStore(
        file: file,
        backend: LocalDatabaseSnapshotBackend.sqlite,
      );
      final worker = await DatabaseWorker.start(file: file);
      final queue = DatabaseWriteQueue();
      addTearDown(() async {
        await queue.dispose();
        await worker.dispose();
        await root.delete(recursive: true);
      });
      final database = AppDatabase(
        snapshotStore: persistence,
        writeWorker: worker,
        writeQueue: queue,
      );
      final longKey = 'digital-twin-material:${'a' * 230}';
      final otherKey = '${longKey}b';
      const table = LocalTableName.materialIngestionDrafts;
      database.upsertRecord(table, longKey, {'state': 'pending'});
      database.upsertRecord(table, longKey, {'state': 'ready'});
      database.upsertRecord(table, otherKey, {'state': 'other'});
      database.upsertRecord(LocalTableName.appPreferences, longKey, {
        'state': 'different-table',
      });
      await database.flushPersistence();
      final reopened = AppDatabase(snapshotStore: persistence);
      expect(
        reopened.getRecord<LocalDatabaseRecord>(table, longKey)?['state'],
        'ready',
      );
      expect(
        reopened.getRecord<LocalDatabaseRecord>(table, otherKey)?['state'],
        'other',
      );
      database.deleteRecord(table, longKey);
      await database.flushPersistence();
      final afterDelete = AppDatabase(snapshotStore: persistence);
      expect(
        afterDelete.getRecord<LocalDatabaseRecord>(table, longKey),
        isNull,
      );
      expect(
        afterDelete.getRecord<LocalDatabaseRecord>(table, otherKey),
        isNotNull,
      );
      expect(
        afterDelete.getRecord<LocalDatabaseRecord>(
          LocalTableName.appPreferences,
          longKey,
        )?['state'],
        'different-table',
      );
    },
  );

  test('schema v16 declares durable account-owned metadata', () {
    final draftTable = getAppDatabaseSchema().tables.singleWhere(
      (table) => table.name == LocalTableName.creationCanvasDrafts,
    );

    expect(localDatabaseSchemaVersion, 16);
    expect(draftTable.columns, contains('shared_metadata_json'));
    final recordingTable = getAppDatabaseSchema().tables.singleWhere(
      (table) => table.name == LocalTableName.localRecordings,
    );
    expect(recordingTable.columns, contains('user_scope'));
    final cardLedgerTable = getAppDatabaseSchema().tables.singleWhere(
      (table) => table.name == LocalTableName.recordingCardFileLedger,
    );
    expect(
      cardLedgerTable.columns,
      containsAll(<String>[
        'planned_native_file_id',
        'sync_origin',
        'resume_requested',
      ]),
    );
  });
  group('AppDatabase', () {
    test('recording DAO isolates same logical recording id by user scope', () {
      final database = AppDatabase();
      final userA = RecordingDao(database, userScope: 'user-a');
      final userB = RecordingDao(database, userScope: 'user-b');
      const recordingId = 'local-shared-id';

      userA.upsertLocalRecording(recordingId, <String, Object?>{
        'recording_id': recordingId,
        'display_name': 'A.m4a',
      });
      userB.upsertLocalRecording(recordingId, <String, Object?>{
        'recording_id': recordingId,
        'display_name': 'B.m4a',
      });
      database.upsertRecord(
        LocalTableName.localRecordings,
        'legacy-unowned-recording',
        const <String, Object?>{
          'recording_id': 'legacy-unowned-recording',
          'display_name': 'Legacy.m4a',
        },
      );

      expect(userA.getLocalRecording(recordingId)?['display_name'], 'A.m4a');
      expect(userB.getLocalRecording(recordingId)?['display_name'], 'B.m4a');
      expect(userA.listLocalRecordings(), hasLength(1));
      expect(userB.listLocalRecordings(), hasLength(1));
    });

    test('schema never stores audio blobs', () {
      expect(
        appDatabaseSchema.tables.every(
          (table) => table.storesAudioBlob == false,
        ),
        isTrue,
      );
    });

    test('schema exposes local recording metadata columns and indexes', () {
      final localRecordings = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.localRecordings,
      );

      expect(
        localRecordings.columns,
        containsAll(<String>[
          'recording_id',
          'app_private_uri',
          'display_name',
          'duration_seconds',
          'size_bytes',
          'tag_ids',
        ]),
      );
      final recordingCardManifest = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.recordingCardDownloadedManifest,
      );
      expect(
        recordingCardManifest.columns,
        containsAll(<String>['local_state', 'local_deleted_at']),
      );
      expect(
        appDatabaseSchema.indexes.map((index) => index.name),
        containsAll(<String>[
          'idx_local_recordings_source_status_recorded_at',
          'idx_device_local_mappings_device_file',
          'idx_recording_card_manifest_device_file',
          'idx_local_recording_upload_drafts_local_file_stage',
          'idx_local_recording_tags_name',
          'idx_local_recording_trash_deleted_at',
        ]),
      );
      final transferRecords = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.localTransferRecords,
      );
      expect(
        transferRecords.columns,
        containsAll(<String>[
          'workspace_scope',
          'primary_item_id',
          'job_id',
          'note_id',
          'last_phase',
          'observation_started_at',
          'last_authoritative_progress_at',
          'observation_deadline_at',
          'waiting_reason',
          'item_payload_json',
          'staged_native_file_id',
          'staged_file_format',
          'staged_size_bytes',
          'staged_content_hash',
        ]),
      );
      final cardLedger = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.recordingCardFileLedger,
      );
      expect(
        cardLedger.columns,
        containsAll(<String>[
          'user_scope',
          'card_sn_digest',
          'source_signature',
          'local_state',
          'card_state',
          'local_deleted_at',
          'retryability',
          'next_retry_at',
        ]),
      );
      final cardCheckpoints = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.recordingCardSyncCheckpoints,
      );
      expect(
        cardCheckpoints.columns,
        containsAll(<String>[
          'user_scope',
          'card_sn_digest',
          'last_successful_auto_sync_at',
          'last_directory_read_at',
          'committed_through_recorded_at',
          'committed_snapshot_hash',
        ]),
      );
      final transcriptionReceipts = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.recordingTranscriptionReceipts,
      );
      expect(
        transcriptionReceipts.columns,
        containsAll(<String>[
          'user_scope',
          'file_identity',
          'content_hash',
          'local_recording_id',
          'remote_recording_id',
          'note_id',
          'transcript_completed_at',
          'asset_ready_at',
          'outline_completed_at',
        ]),
      );
      final canvasDrafts = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.creationCanvasDrafts,
      );
      expect(
        canvasDrafts.columns,
        containsAll(<String>[
          'user_scope',
          'title',
          'markdown',
          'document_json',
          'document_format_version',
          'linked_materials_json',
          'source_topic_id',
          'source_title',
          'revision',
          'created_at',
          'updated_at',
        ]),
      );
      expect(
        appDatabaseSchema.indexes.map((index) => index.name),
        containsAll(<String>[
          'idx_creation_canvas_drafts_scope_updated_at',
          'idx_asset_classifications_scope_category',
          'idx_creation_canvas_history_scope_updated_at',
          'idx_profile_todos_scope_due_at',
          'idx_usage_sessions_scope_started_at',
          'idx_recording_card_bindings_scope_claim',
          'idx_growth_ledger_scope_first_deposited_at',
          'idx_recording_card_ledger_scope_card_source',
          'idx_recording_card_checkpoints_scope_card',
          'idx_transcription_receipts_scope_file',
          'idx_transcription_receipts_scope_remote_recording',
          'idx_chat_entry_bindings_scope_entry_opened',
        ]),
      );
      expect(
        userScopedLocalTables,
        containsAll(<LocalTableName>[
          LocalTableName.recordingCardFileLedger,
          LocalTableName.recordingCardSyncCheckpoints,
          LocalTableName.recordingTranscriptionReceipts,
          LocalTableName.chatEntryThreadBindings,
        ]),
      );
      final chatEntryBindings = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.chatEntryThreadBindings,
      );
      expect(chatEntryBindings.columns, <String>[
        'user_scope',
        'workspace_scope',
        'scene',
        'entry_kind',
        'entry_id',
        'thread_id',
        'agent_profile_id',
        'bound_at',
        'last_opened_at',
      ]);
      final recordingCardBindings = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.recordingCardAccountBindings,
      );
      expect(recordingCardBindings.columns, <String>[
        'user_scope',
        'opaque_claim',
        'bound_at',
        'updated_at',
      ]);
      expect(
        userScopedLocalTables,
        contains(LocalTableName.recordingCardAccountBindings),
      );
      final classifications = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.assetClassifications,
      );
      expect(
        classifications.columns,
        containsAll(<String>['knowledge_secondary_labels', 'is_demo']),
      );
      expect(userScopedLocalTables, contains(LocalTableName.growthLedger));
      final depositFolders = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.depositFolders,
      );
      expect(depositFolders.columns, contains('parent_folder_id'));
      expect(
        appDatabaseSchema.indexes.map((index) => index.name),
        contains('idx_deposit_folders_scope_parent_updated_at'),
      );
      final history = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.creationCanvasHistory,
      );
      expect(
        history.columns,
        containsAll(<String>[
          'history_id',
          'note_id',
          'document_json',
          'document_format_version',
          'revision',
          'linked_materials_json',
        ]),
      );
      final appPreferences = appDatabaseSchema.tables.singleWhere(
        (table) => table.name == LocalTableName.appPreferences,
      );
      expect(
        appPreferences.columns,
        containsAll(<String>['preference_key', 'value', 'updated_at']),
      );
      expect(appPreferences.columns, isNot(contains('user_scope')));
      expect(
        userScopedLocalTables,
        isNot(contains(LocalTableName.appPreferences)),
      );
    });

    test('rejects records containing audio content or sensitive paths', () {
      final db = AppDatabase();

      expect(
        () => db.upsertRecord(
          LocalTableName.localRecordings,
          'recording-1',
          const <String, Object?>{
            'recording_id': 'recording-1',
            'audioContent': 'base64-bytes',
          },
        ),
        throwsStateError,
      );

      expect(
        () => db.upsertRecord(
          LocalTableName.localRecordings,
          'recording-2',
          const <String, Object?>{
            'recording_id': 'recording-2',
            'local_path': '/Users/run/private.wav',
          },
        ),
        throwsStateError,
      );

      expect(
        () => db.upsertRecord(
          LocalTableName.localRecordings,
          'recording-3',
          const <String, Object?>{
            'recording_id': 'recording-3',
            'audio_bytes': <int>[1, 2, 3],
          },
        ),
        throwsStateError,
      );
    });

    test('allows only staged-verified Wi-Fi format refinement', () {
      for (final evidenceFormat in <String?>[null, 'wav', 'mp3']) {
        final dao = RecordingDao(AppDatabase());
        const contentHash =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        void write(String format, {required bool completed}) {
          final staged = !completed && evidenceFormat != null;
          dao.upsertRecordingCardWifiBatchItem(
            transferId: 'wifi-format-transfer',
            batchId: 'wifi-format-batch',
            deviceFingerprint: 'card-fingerprint-1',
            deviceIdentity: 'card-fingerprint-1',
            deviceFileId: 'card-file-1',
            deviceFilename: '20260902123249',
            localFileKey: 'card-20260902123249',
            itemOrder: 0,
            expectedSizeBytes: 4096,
            attemptCount: 1,
            batchStage: 'registering',
            stage: completed ? 'completed' : 'verifying',
            idempotencyKey: 'wifi-format-idempotency',
            createdAt: '2026-09-16T15:33:00Z',
            updatedAt: '2026-09-16T15:33:00Z',
            fileFormat: format,
            contentHash: completed ? contentHash : null,
            localRecordingId: completed ? 'local-recording-1' : null,
            stagedNativeFileId: staged
                ? 'card-11111111111111111111111111111111'
                : null,
            stagedFileFormat: staged ? evidenceFormat : null,
            stagedSizeBytes: staged ? 4096 : null,
            stagedContentHash: staged ? contentHash : null,
          );
        }

        write('unknown', completed: false);
        if (evidenceFormat == 'mp3') {
          write('mp3', completed: true);
          final row = dao.listRecordingCardWifiBatchItems().single;
          expect(row['file_format'], 'mp3');
          expect(row['stage'], 'completed');
          expect(() => write('wav', completed: true), throwsStateError);
        } else {
          expect(() => write('mp3', completed: true), throwsStateError);
          expect(
            dao.listRecordingCardWifiBatchItems().single['file_format'],
            'unknown',
          );
        }
      }
    });

    test('persists only safe recording-card Wi-Fi batch recovery rows', () {
      final db = AppDatabase();
      final dao = RecordingDao(db);
      const createdAt = '2026-07-15T09:00:00.000Z';
      const updatedAt = '2026-07-15T09:01:00.000Z';
      dao.upsertRecordingCardWifiBatchItem(
        transferId: 'wifi-transfer-1',
        batchId: 'wifi-batch-1',
        deviceFingerprint: 'card-fingerprint-1',
        deviceIdentity: 'serial:FW920001',
        deviceFileId: 'card-file-1',
        deviceFilename: '20260715090000.mp3',
        localFileKey: 'card-20260715090000',
        itemOrder: 0,
        expectedSizeBytes: 71172,
        attemptCount: 1,
        batchStage: 'transferring',
        stage: 'transferring',
        idempotencyKey: 'wifi-idempotency-1',
        createdAt: createdAt,
        updatedAt: updatedAt,
        fileFormat: 'mp3',
        mimeType: 'audio/mpeg',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        stagedNativeFileId: 'card-11111111111111111111111111111111',
        stagedFileFormat: 'm4a',
        stagedSizeBytes: 71170,
        stagedContentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      db.upsertRecord(
        LocalTableName.localTransferRecords,
        'legacy-upload-1',
        const <String, Object?>{
          'transfer_id': 'legacy-upload-1',
          'stage': 'uploading',
          'updated_at': updatedAt,
        },
      );

      final rows = dao.listRecordingCardWifiBatchItems();
      expect(rows, hasLength(1));
      expect(rows.single['batch_id'], 'wifi-batch-1');
      expect(rows.single['device_identity'], 'serial:FW920001');
      expect(rows.single['created_at'], createdAt);
      expect(rows.single['file_format'], 'mp3');
      expect(rows.single['expected_size_bytes'], 71172);
      expect(
        rows.single['content_hash'],
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(
        rows.single['staged_native_file_id'],
        'card-11111111111111111111111111111111',
      );
      expect(rows.single['staged_file_format'], 'm4a');
      expect(rows.single['staged_size_bytes'], 71170);
      expect(
        rows.single['staged_content_hash'],
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(rows.single.keys, isNot(contains('ssid')));
      expect(rows.single.keys, isNot(contains('password')));
      expect(rows.single.keys, isNot(contains('app_private_uri')));

      expect(
        () => dao.upsertRecordingCardWifiBatchItem(
          transferId: 'wifi-transfer-invalid',
          batchId: 'wifi-batch-invalid',
          deviceFingerprint: 'card-fingerprint-1',
          deviceIdentity: 'serial:FW920001',
          deviceFileId: 'card-file-2',
          deviceFilename: '20260715090100.mp3',
          localFileKey: 'card-20260715090100',
          itemOrder: 1,
          expectedSizeBytes: 4096,
          attemptCount: 1,
          batchStage: 'transferring',
          stage: 'staged',
          idempotencyKey: 'wifi-idempotency-invalid',
          createdAt: createdAt,
          updatedAt: updatedAt,
          stagedNativeFileId: 'card-22222222222222222222222222222222',
        ),
        throwsArgumentError,
      );
      expect(
        dao.listRecordingCardWifiBatchItems(batchId: 'wifi-batch-invalid'),
        isEmpty,
      );

      dao.deleteRecordingCardWifiBatch('wifi-batch-1');
      expect(dao.listRecordingCardWifiBatchItems(), isEmpty);
      expect(
        db.getRecord<LocalDatabaseRecord>(
          LocalTableName.localTransferRecords,
          'legacy-upload-1',
        ),
        isNotNull,
      );
    });

    test('recovers safe local recording metadata from snapshot file', () async {
      final root = await Directory.systemTemp.createTemp('huahuo-db-snapshot-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshotFile = File('${root.path}/local-db.json');
      final first = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
      );

      first.upsertRecord(LocalTableName.localRecordings, 'recording-1', {
        'recording_id': 'recording-1',
        'source': 'localImport',
        'status': 'localOnly',
        'format': 'm4a',
        'local_file_state': 'ready',
        'app_private_uri': 'app-private://recordings/local-a/source.m4a',
        'display_name': 'Meeting.m4a',
        'duration_seconds': 90,
        'size_bytes': 2048,
        'is_favorite': true,
        'tag_ids': <String>['customer'],
        'created_at': '2026-07-01T09:00:00.000Z',
        'updated_at': '2026-07-01T09:00:00.000Z',
      });
      first.upsertRecord(LocalTableName.localRecordingUploadDrafts, 'draft-1', {
        'draft_id': 'draft-1',
        'local_file_id': 'recording-1',
        'stage': 'localReady',
        'updated_at': '2026-07-01T09:00:00.000Z',
      });

      final recovered = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
      );

      expect(
        recovered.getRecord<LocalDatabaseRecord>(
          LocalTableName.localRecordings,
          'recording-1',
        )?['app_private_uri'],
        'app-private://recordings/local-a/source.m4a',
      );
      expect(
        recovered.listRecords(LocalTableName.localRecordingUploadDrafts),
        hasLength(1),
      );
      expect(snapshotFile.readAsStringSync(), isNot(contains('/Users/')));
      expect(snapshotFile.readAsStringSync(), isNot(contains('audioContent')));
    });

    test('migrates a version-1 snapshot to metadata schema v7', () async {
      final root = await Directory.systemTemp.createTemp('huahuo-db-v1-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshotFile = File('${root.path}/local-db.json');
      snapshotFile.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'tables': <String, Object?>{
            LocalTableName.localRecordings.dbName: <String, Object?>{
              'recording-legacy': <String, Object?>{
                'recording_id': 'recording-legacy',
                'display_name': 'Legacy.m4a',
              },
            },
          },
        }),
      );

      final database = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
      );

      expect(database.schemaVersion, localDatabaseSchemaVersion);
      expect(
        database.getRecord<LocalDatabaseRecord>(
          LocalTableName.localRecordings,
          'recording-legacy',
        )?['display_name'],
        'Legacy.m4a',
      );
      expect(database.listRecords(LocalTableName.voiceprintProfiles), isEmpty);
      expect(database.listRecords(LocalTableName.chatThreadAliases), isEmpty);
      expect(
        database.listRecords(LocalTableName.knowledgeItemUserMetadata),
        isEmpty,
      );
      expect(
        database.listRecords(LocalTableName.knowledgeViewPreferences),
        isEmpty,
      );
      expect(
        database.listRecords(LocalTableName.creationCanvasDrafts),
        isEmpty,
      );
      expect(
        jsonDecode(snapshotFile.readAsStringSync())['schemaVersion'],
        localDatabaseSchemaVersion,
      );
    });

    test(
      'migrates a version-2 snapshot to knowledge metadata schema v7',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-db-v2-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshotFile = File('${root.path}/local-db.json');
        snapshotFile.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 2,
            'tables': <String, Object?>{
              LocalTableName.voiceprintProfiles.dbName: <String, Object?>{
                'voiceprint:legacy': <String, Object?>{
                  'user_scope': 'account-a',
                  'profile_id': 'legacy',
                  'name': '旧声纹',
                },
              },
            },
          }),
        );

        final database = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
        );

        expect(database.schemaVersion, localDatabaseSchemaVersion);
        expect(
          database.listRecords(LocalTableName.voiceprintProfiles),
          hasLength(1),
        );
        expect(
          database.listRecords(LocalTableName.knowledgeItemUserMetadata),
          isEmpty,
        );
        expect(
          database.listRecords(LocalTableName.knowledgeViewPreferences),
          isEmpty,
        );
        expect(
          database.listRecords(LocalTableName.creationCanvasDrafts),
          isEmpty,
        );
      },
    );

    test(
      'migrates a version-3 snapshot to creation-canvas schema v7',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-db-v3-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshotFile = File('${root.path}/local-db.json');
        snapshotFile.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 3,
            'tables': <String, Object?>{
              LocalTableName.localRecordings.dbName: <String, Object?>{
                'recording-v3': <String, Object?>{
                  'recording_id': 'recording-v3',
                  'display_name': 'V3.m4a',
                },
              },
              LocalTableName.knowledgeViewPreferences.dbName: <String, Object?>{
                'knowledge-view-v3': <String, Object?>{
                  'user_scope': 'account-a',
                  'preference_key': 'knowledge_card_display_mode',
                  'card_mode': 'compact',
                  'updated_at': '2026-07-19T00:00:00.000Z',
                },
              },
            },
          }),
        );

        final database = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
        );

        expect(database.schemaVersion, localDatabaseSchemaVersion);
        expect(
          database.getRecord<LocalDatabaseRecord>(
            LocalTableName.localRecordings,
            'recording-v3',
          )?['display_name'],
          'V3.m4a',
        );
        expect(
          database.listRecords(LocalTableName.knowledgeViewPreferences),
          hasLength(1),
        );
        expect(
          database.listRecords(LocalTableName.creationCanvasDrafts),
          isEmpty,
        );
        expect(
          jsonDecode(snapshotFile.readAsStringSync())['schemaVersion'],
          localDatabaseSchemaVersion,
        );
      },
    );

    test(
      'migrates a version-4 draft row to structured-document schema v7',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-db-v4-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshotFile = File('${root.path}/local-db.json');
        snapshotFile.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 4,
            'tables': <String, Object?>{
              LocalTableName.creationCanvasDrafts.dbName: <String, Object?>{
                'creation-canvas:legacy': <String, Object?>{
                  'user_scope': 'account-a',
                  'title': '旧画布',
                  'markdown': '旧 Markdown',
                  'source_topic_id': null,
                  'source_title': null,
                  'revision': 2,
                  'created_at': '2026-07-20T00:00:00.000Z',
                  'updated_at': '2026-07-20T00:05:00.000Z',
                },
              },
            },
          }),
        );

        final database = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
        );

        expect(database.schemaVersion, localDatabaseSchemaVersion);
        final row = database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.creationCanvasDrafts,
            )
            .single;
        expect(row['title'], '旧画布');
        expect(row['markdown'], '旧 Markdown');
        expect(row, isNot(contains('document_json')));
        expect(row, isNot(contains('document_format_version')));
        expect(row, isNot(contains('linked_materials_json')));
        expect(
          jsonDecode(snapshotFile.readAsStringSync())['schemaVersion'],
          localDatabaseSchemaVersion,
        );
      },
    );

    test('migrates a version-5 snapshot to current feature tables', () async {
      final root = await Directory.systemTemp.createTemp('huahuo-db-v5-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshotFile = File('${root.path}/local-db.json');
      snapshotFile.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 5,
          'tables': <String, Object?>{
            LocalTableName.creationCanvasDrafts.dbName: <String, Object?>{
              'creation-canvas:v5': <String, Object?>{
                'user_scope': 'account-a',
                'title': 'V5 画布',
                'markdown': '保留正文',
                'document_json': '{"ops":[{"insert":"保留正文\\n"}]}',
                'document_format_version': 1,
                'linked_materials_json': '[]',
                'revision': 4,
                'created_at': '2026-07-20T00:00:00.000Z',
                'updated_at': '2026-07-20T00:05:00.000Z',
              },
            },
          },
        }),
      );

      final database = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
      );

      expect(database.schemaVersion, localDatabaseSchemaVersion);
      expect(
        database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.creationCanvasDrafts,
            )
            .single['title'],
        'V5 画布',
      );
      expect(
        database.listRecords(LocalTableName.assetClassifications),
        isEmpty,
      );
      expect(
        database.listRecords(LocalTableName.creationCanvasHistory),
        isEmpty,
      );
      expect(database.listRecords(LocalTableName.profileTodos), isEmpty);
      expect(database.listRecords(LocalTableName.usageSessions), isEmpty);
      expect(database.listRecords(LocalTableName.appPreferences), isEmpty);
      expect(
        jsonDecode(snapshotFile.readAsStringSync())['schemaVersion'],
        localDatabaseSchemaVersion,
      );
    });

    test(
      'migrates a version-6 snapshot to device preferences schema v7',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-db-v6-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshotFile = File('${root.path}/local-db.json');
        snapshotFile.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 6,
            'tables': <String, Object?>{
              LocalTableName.profileTodos.dbName: <String, Object?>{
                'todo-v6': <String, Object?>{
                  'user_scope': 'account-a',
                  'todo_id': 'todo-v6',
                  'title': '保留待办',
                },
              },
            },
          }),
        );

        final database = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
        );

        expect(database.schemaVersion, localDatabaseSchemaVersion);
        expect(
          database
              .listRecords<LocalDatabaseRecord>(LocalTableName.profileTodos)
              .single['title'],
          '保留待办',
        );
        expect(database.listRecords(LocalTableName.appPreferences), isEmpty);
        expect(
          jsonDecode(snapshotFile.readAsStringSync())['schemaVersion'],
          localDatabaseSchemaVersion,
        );
      },
    );

    test(
      'migrates a version-7 snapshot to account binding schema v8',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-db-v7-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshotFile = File('${root.path}/local-db.json');
        snapshotFile.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 7,
            'tables': <String, Object?>{
              LocalTableName.appPreferences.dbName: <String, Object?>{
                'appearance.preset': <String, Object?>{
                  'preference_key': 'appearance.preset',
                  'value': 'dark',
                  'updated_at': '2026-07-24T00:00:00.000Z',
                },
              },
            },
          }),
        );

        final database = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
        );

        expect(database.schemaVersion, localDatabaseSchemaVersion);
        expect(
          database
              .listRecords<LocalDatabaseRecord>(LocalTableName.appPreferences)
              .single['value'],
          'dark',
        );
        expect(
          database.listRecords(LocalTableName.recordingCardAccountBindings),
          isEmpty,
        );
      },
    );

    test(
      'migrates v8 asset categories and backfills growth idempotently',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-db-v8-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshotFile = File('${root.path}/local-db.json');
        snapshotFile.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 8,
            'tables': <String, Object?>{
              LocalTableName.assetClassifications.dbName: <String, Object?>{
                'legacy-single': <String, Object?>{
                  'user_scope': 'account-a',
                  'content_id': 'note-a',
                  'category': 'expressionTendency',
                  'created_at': '2026-07-20T00:00:00.000Z',
                  'updated_at': '2026-07-21T00:00:00.000Z',
                },
              },
              LocalTableName.depositRecords.dbName: <String, Object?>{
                'legacy-deposit-a': <String, Object?>{
                  'user_scope': 'account-a',
                  'content_id': 'note-a',
                  'deposited_at': '2026-07-18T08:00:00.000Z',
                  'updated_at': '2026-07-18T08:00:00.000Z',
                },
                'duplicate-deposit-a': <String, Object?>{
                  'user_scope': 'account-a',
                  'content_id': 'note-a',
                  'deposited_at': '2026-07-19T08:00:00.000Z',
                  'updated_at': '2026-07-19T08:00:00.000Z',
                },
                'legacy-deposit-b': <String, Object?>{
                  'user_scope': 'account-a',
                  'content_id': 'note-b',
                  'deposited_at': 'invalid-old-timestamp',
                  'updated_at': '2026-07-20T08:00:00.000Z',
                },
              },
              LocalTableName.knowledgeLibraryMemberships.dbName:
                  <String, Object?>{
                    'membership-b': <String, Object?>{
                      'user_scope': 'account-a',
                      'content_id': 'note-b',
                      'collection': 'deposits',
                      'created_at': '2026-07-17T07:00:00.000Z',
                    },
                  },
            },
          }),
        );

        final database = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
        );
        final migrated = database
            .listRecords<LocalDatabaseRecord>(
              LocalTableName.assetClassifications,
            )
            .single;

        expect(database.schemaVersion, localDatabaseSchemaVersion);
        expect(migrated['category'], 'expression');
        expect(migrated['knowledge_secondary_labels'], isEmpty);
        expect(migrated['is_demo'], isFalse);
        final growthByContent = <String, LocalDatabaseRecord>{
          for (final row in database.listRecords<LocalDatabaseRecord>(
            LocalTableName.growthLedger,
          ))
            row['content_id']! as String: row,
        };
        expect(growthByContent, hasLength(2));
        expect(
          growthByContent['note-a']?['first_deposited_at'],
          '2026-07-18T08:00:00.000Z',
        );
        expect(
          growthByContent['note-b']?['first_deposited_at'],
          '2026-07-17T07:00:00.000Z',
        );

        final reopened = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
        );
        final reopenedGrowth = reopened.listRecords<LocalDatabaseRecord>(
          LocalTableName.growthLedger,
        );
        expect(reopenedGrowth, hasLength(2));
        expect(
          reopenedGrowth.singleWhere(
            (row) => row['content_id'] == 'note-a',
          )['first_deposited_at'],
          '2026-07-18T08:00:00.000Z',
        );
      },
    );

    test('migrates a v12 snapshot through additive schema v15', () async {
      final root = await Directory.systemTemp.createTemp('huahuo-db-v12-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshotFile = File('${root.path}/local-db.json');
      snapshotFile.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 12,
          'tables': <String, Object?>{
            LocalTableName.localRecordings.dbName: <String, Object?>{
              'recording-a': <String, Object?>{
                'user_scope': 'account-a',
                'recording_id': 'recording-a',
                'display_name': 'meeting.m4a',
                'updated_at': '2026-09-01T08:00:00.000Z',
              },
            },
            LocalTableName.localTransferRecords.dbName: <String, Object?>{
              'transfer-a': <String, Object?>{
                'user_scope': 'account-a',
                'transfer_id': 'transfer-a',
                'transfer_kind': 'recording_card_auto_sync',
                'stage': 'queued',
                'updated_at': '2026-09-01T08:00:00.000Z',
              },
            },
          },
        }),
      );

      final database = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
      );

      expect(database.schemaVersion, localDatabaseSchemaVersion);
      expect(
        database.listRecords(LocalTableName.localRecordings),
        hasLength(1),
      );
      expect(
        database.listRecords(LocalTableName.localTransferRecords),
        hasLength(1),
      );
      expect(
        database.listRecords(LocalTableName.recordingCardFileLedger),
        isEmpty,
      );
      expect(
        database.listRecords(LocalTableName.recordingCardSyncCheckpoints),
        isEmpty,
      );
      expect(
        database.listRecords(LocalTableName.recordingTranscriptionReceipts),
        isEmpty,
      );
      expect(
        database.listRecords(LocalTableName.chatEntryThreadBindings),
        isEmpty,
      );
    });

    test(
      'drops ambiguous v14 Chat entry bindings during v15 migration',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-db-v14-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final snapshotFile = File('${root.path}/local-db.json');
        snapshotFile.writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 14,
            'tables': <String, Object?>{
              LocalTableName.chatEntryThreadBindings.dbName: <String, Object?>{
                'legacy-binding': <String, Object?>{
                  'user_scope': 'account-a',
                  'scene': 'feed_ai',
                  'entry_kind': 'asset',
                  'entry_id': 'asset-a',
                  'thread_id': 'thread-a',
                  'agent_profile_id': 'self_media_creation_standard',
                  'bound_at': '2026-09-09T08:00:00.000Z',
                  'last_opened_at': '2026-09-09T08:00:00.000Z',
                },
              },
            },
          }),
        );

        final database = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
        );

        expect(database.schemaVersion, 16);
        expect(
          database.listRecords(LocalTableName.chatEntryThreadBindings),
          isEmpty,
        );
      },
    );

    test('v16 backfills recording-card resume intent conservatively', () {
      final database = AppDatabase(schemaVersion: 15);
      database.upsertRecord(
        LocalTableName.recordingCardFileLedger,
        'legacy-syncing',
        const <String, Object?>{'local_state': 'syncing'},
      );
      database.upsertRecord(
        LocalTableName.recordingCardFileLedger,
        'legacy-synced',
        const <String, Object?>{'local_state': 'synced'},
      );

      final migration = database.runMigrations(16);

      expect(migration.ok, isTrue);
      expect(
        database.getRecord<LocalDatabaseRecord>(
          LocalTableName.recordingCardFileLedger,
          'legacy-syncing',
        )?['resume_requested'],
        isTrue,
      );
      expect(
        database.getRecord<LocalDatabaseRecord>(
          LocalTableName.recordingCardFileLedger,
          'legacy-synced',
        )?['resume_requested'],
        isFalse,
      );
    });

    test('migrates v9 folders to root hierarchy metadata', () async {
      final root = await Directory.systemTemp.createTemp('huahuo-db-v9-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final snapshotFile = File('${root.path}/local-db.json');
      snapshotFile.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 9,
          'tables': <String, Object?>{
            LocalTableName.depositFolders.dbName: <String, Object?>{
              'folder-a': <String, Object?>{
                'user_scope': 'account-a',
                'folder_id': 'folder-a',
                'name': '历史资料',
                'created_at': '2026-07-26T00:00:00.000Z',
                'updated_at': '2026-07-26T00:00:00.000Z',
              },
            },
            LocalTableName.depositRecords.dbName: <String, Object?>{
              'note-a': <String, Object?>{
                'user_scope': 'account-a',
                'content_id': 'note-a',
                'folder_id': 'folder-a',
                'deposited_at': '2026-07-26T00:00:00.000Z',
                'updated_at': '2026-07-26T00:00:00.000Z',
              },
            },
          },
        }),
      );

      final database = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
      );
      final folder = database
          .listRecords<LocalDatabaseRecord>(LocalTableName.depositFolders)
          .single;
      final deposit = database
          .listRecords<LocalDatabaseRecord>(LocalTableName.depositRecords)
          .single;

      expect(database.schemaVersion, localDatabaseSchemaVersion);
      expect(folder['parent_folder_id'], isNull);
      expect(deposit['folder_id'], 'folder-a');

      final reopened = AppDatabase(
        snapshotStore: LocalDatabaseSnapshotStore(file: snapshotFile),
      );
      expect(reopened.schemaVersion, localDatabaseSchemaVersion);
      expect(
        reopened
            .listRecords<LocalDatabaseRecord>(LocalTableName.depositFolders)
            .single['parent_folder_id'],
        isNull,
      );
    });

    test(
      'user-scoped cleanup removes only the normalized matching account across every scoped table',
      () {
        final database = AppDatabase();

        for (final table in userScopedLocalTables) {
          database.upsertRecord(
            table,
            'account-a:${table.dbName}',
            <String, Object?>{
              'user_scope': 'account-a',
              'marker': 'account-a:${table.dbName}',
            },
          );
          database.upsertRecord(
            table,
            'account-b:${table.dbName}',
            <String, Object?>{
              'user_scope': 'account-b',
              'marker': 'account-b:${table.dbName}',
            },
          );
          database.upsertRecord(
            table,
            'legacy:${table.dbName}',
            <String, Object?>{'marker': 'legacy:${table.dbName}'},
          );
        }
        database.upsertRecord(
          LocalTableName.diagnosticLogs,
          'unscoped-table-row',
          const <String, Object?>{
            'user_scope': 'account-a',
            'marker': 'unscoped-table-row',
          },
        );

        final result = database.clearUserScopedLocalData('  account-a  ');

        expect(result.ok, isTrue);
        expect(result.value?.scope, 'account-a');
        expect(result.value?.clearedRows, userScopedLocalTables.length);
        for (final table in userScopedLocalTables) {
          final records = database.listRecords<LocalDatabaseRecord>(table);
          expect(
            records.map((record) => record['marker']),
            unorderedEquals(<String>[
              'account-b:${table.dbName}',
              'legacy:${table.dbName}',
            ]),
            reason:
                '${table.dbName} must retain other-account and unscoped rows',
          );
        }
        expect(
          database
              .listRecords<LocalDatabaseRecord>(
                LocalTableName.voiceprintProfiles,
              )
              .singleWhere(
                (record) => record['user_scope'] == 'account-b',
              )['marker'],
          'account-b:voiceprint_profiles',
        );
        expect(
          database
              .listRecords<LocalDatabaseRecord>(
                LocalTableName.chatThreadAliases,
              )
              .singleWhere(
                (record) => record['user_scope'] == 'account-b',
              )['marker'],
          'account-b:chat_thread_aliases',
        );
        expect(
          database
              .listRecords<LocalDatabaseRecord>(LocalTableName.diagnosticLogs)
              .single['marker'],
          'unscoped-table-row',
        );
        expect(
          () => database.clearUserScopedLocalData('   '),
          throwsArgumentError,
        );
      },
    );

    test(
      'recovers safe local recording metadata from an atomic JSON snapshot',
      () async {
        final root = await Directory.systemTemp.createTemp('huahuo-db-json-');
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });
        final snapshotFile = File('${root.path}/local-db.json');
        final first = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(
            file: snapshotFile,
            backend: LocalDatabaseSnapshotBackend.json,
          ),
        );

        first.upsertRecord(LocalTableName.localRecordings, 'recording-1', {
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
          'tag_ids': <String>['customer'],
          'created_at': '2026-07-01T09:00:00.000Z',
          'updated_at': '2026-07-01T09:00:00.000Z',
        });

        final recovered = AppDatabase(
          snapshotStore: LocalDatabaseSnapshotStore(
            file: snapshotFile,
            backend: LocalDatabaseSnapshotBackend.json,
          ),
        );

        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localRecordings,
            'recording-1',
          )?['display_name'],
          'Meeting.m4a',
        );
        final encodedSnapshot = snapshotFile.readAsStringSync();
        expect(encodedSnapshot, isNot(contains('audioContent')));
        expect(encodedSnapshot, isNot(contains('/Users/')));
        expect(File('${snapshotFile.path}.part').existsSync(), isFalse);

        final decoded = jsonDecode(encodedSnapshot) as Map<String, dynamic>;
        final tables = decoded['tables'] as Map<String, dynamic>;
        final recordings =
            tables[LocalTableName.localRecordings.dbName]
                as Map<String, dynamic>;
        final persisted = recordings['recording-1'] as Map<String, dynamic>;
        expect(decoded['schemaVersion'], localDatabaseSchemaVersion);
        expect(persisted['display_name'], 'Meeting.m4a');
        expect(persisted.keys, isNot(contains('audioContent')));
      },
    );

    test('outer transaction saves one snapshot for nested mutations', () async {
      final root = await Directory.systemTemp.createTemp('huahuo-db-tx-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final store = _CountingSnapshotStore(
        file: File('${root.path}/local-db.json'),
      );
      final db = AppDatabase(snapshotStore: store);

      final result = db.withTransaction<void>((transaction) {
        transaction.upsertRecord(
          LocalTableName.localTransferRecords,
          'transfer-1',
          const <String, Object?>{'transfer_id': 'transfer-1'},
        );
        transaction.upsertRecord(
          LocalTableName.localTransferRecords,
          'transfer-2',
          const <String, Object?>{'transfer_id': 'transfer-2'},
        );
        transaction.withTransaction<void>((nested) {
          nested.upsertRecord(
            LocalTableName.localTransferRecords,
            'transfer-3',
            const <String, Object?>{'transfer_id': 'transfer-3'},
          );
        });
      });

      expect(result.ok, isTrue);
      expect(store.saveCount, 1);
      expect(
        AppDatabase(
          snapshotStore: store,
        ).listRecords(LocalTableName.localTransferRecords),
        hasLength(3),
      );
    });

    test('failed transaction restores rows and writes rollback once', () async {
      final root = await Directory.systemTemp.createTemp('huahuo-db-rollback-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final store = _CountingSnapshotStore(
        file: File('${root.path}/local-db.json'),
      );
      final db = AppDatabase(snapshotStore: store);
      db.upsertRecord(
        LocalTableName.localTransferRecords,
        'transfer-1',
        const <String, Object?>{'transfer_id': 'transfer-1', 'stage': 'queued'},
      );
      store.resetCounts();

      final result = db.withTransaction<void>((transaction) {
        transaction.upsertRecord(
          LocalTableName.localTransferRecords,
          'transfer-1',
          const <String, Object?>{
            'transfer_id': 'transfer-1',
            'stage': 'transferring',
          },
        );
        transaction.upsertRecord(
          LocalTableName.localTransferRecords,
          'transfer-2',
          const <String, Object?>{'transfer_id': 'transfer-2'},
        );
        throw StateError('rollback');
      });

      expect(result.ok, isFalse);
      expect(store.saveCount, 1);
      expect(
        db.getRecord<LocalDatabaseRecord>(
          LocalTableName.localTransferRecords,
          'transfer-1',
        )?['stage'],
        'queued',
      );
      expect(
        db.getRecord<LocalDatabaseRecord>(
          LocalTableName.localTransferRecords,
          'transfer-2',
        ),
        isNull,
      );
      final recovered = AppDatabase(snapshotStore: store);
      expect(
        recovered.getRecord<LocalDatabaseRecord>(
          LocalTableName.localTransferRecords,
          'transfer-1',
        )?['stage'],
        'queued',
      );
    });

    test(
      'sqlite ordinary upsert preserves unrelated rows across restart',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'huahuo-db-incremental-upsert-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final sqliteFile = File('${root.path}/local-db.sqlite');
        final store = LocalDatabaseSnapshotStore(
          file: sqliteFile,
          backend: LocalDatabaseSnapshotBackend.sqlite,
        );
        final db = AppDatabase(snapshotStore: store);
        db.upsertRecord(
          LocalTableName.localTransferRecords,
          'transfer-1',
          const <String, Object?>{
            'transfer_id': 'transfer-1',
            'stage': 'queued',
          },
        );
        _insertExternalSqliteRecord(
          sqliteFile,
          table: LocalTableName.localTransferRecords,
          key: 'external-1',
          value: const <String, Object?>{
            'transfer_id': 'external-1',
            'stage': 'external',
          },
        );

        db.upsertRecord(
          LocalTableName.localTransferRecords,
          'transfer-1',
          const <String, Object?>{
            'transfer_id': 'transfer-1',
            'stage': 'transferring',
          },
        );

        final raw = sqlite.sqlite3.open(sqliteFile.path);
        try {
          expect(
            raw.select('SELECT record_key FROM local_records'),
            hasLength(2),
          );
          expect(
            raw.select(
              'SELECT payload_json FROM local_records '
              'WHERE table_name = ? AND record_key = ?',
              <Object?>[
                LocalTableName.localTransferRecords.dbName,
                'external-1',
              ],
            ).single['payload_json'],
            contains('external'),
          );
        } finally {
          raw.close();
        }

        final recovered = AppDatabase(snapshotStore: store);
        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localTransferRecords,
            'transfer-1',
          )?['stage'],
          'transferring',
        );
        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localTransferRecords,
            'external-1',
          )?['stage'],
          'external',
        );
      },
    );

    test(
      'sqlite ordinary delete removes only its key across restart',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'huahuo-db-incremental-delete-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final sqliteFile = File('${root.path}/local-db.sqlite');
        final store = LocalDatabaseSnapshotStore(
          file: sqliteFile,
          backend: LocalDatabaseSnapshotBackend.sqlite,
        );
        final db = AppDatabase(snapshotStore: store);
        db.upsertRecord(
          LocalTableName.localTransferRecords,
          'transfer-delete',
          const <String, Object?>{'transfer_id': 'transfer-delete'},
        );
        db.upsertRecord(
          LocalTableName.localTransferRecords,
          'transfer-keep',
          const <String, Object?>{'transfer_id': 'transfer-keep'},
        );
        db.upsertRecord(
          LocalTableName.localRecordings,
          'recording-keep',
          const <String, Object?>{'recording_id': 'recording-keep'},
        );
        _insertExternalSqliteRecord(
          sqliteFile,
          table: LocalTableName.localTransferRecords,
          key: 'external-keep',
          value: const <String, Object?>{'transfer_id': 'external-keep'},
        );

        expect(
          db.deleteRecord(
            LocalTableName.localTransferRecords,
            'transfer-delete',
          ),
          isTrue,
        );

        final raw = sqlite.sqlite3.open(sqliteFile.path);
        try {
          expect(
            raw.select('SELECT record_key FROM local_records'),
            hasLength(3),
          );
          expect(
            raw.select(
              'SELECT record_key FROM local_records '
              'WHERE table_name = ? AND record_key = ?',
              <Object?>[
                LocalTableName.localTransferRecords.dbName,
                'transfer-delete',
              ],
            ),
            isEmpty,
          );
        } finally {
          raw.close();
        }

        final recovered = AppDatabase(snapshotStore: store);
        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localTransferRecords,
            'transfer-delete',
          ),
          isNull,
        );
        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localTransferRecords,
            'transfer-keep',
          ),
          isNotNull,
        );
        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localTransferRecords,
            'external-keep',
          ),
          isNotNull,
        );
        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localRecordings,
            'recording-keep',
          ),
          isNotNull,
        );
      },
    );

    test(
      'sqlite transaction preserves externally added unrelated rows',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'huahuo-db-transaction-batch-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final sqliteFile = File('${root.path}/local-db.sqlite');
        final store = LocalDatabaseSnapshotStore(
          file: sqliteFile,
          backend: LocalDatabaseSnapshotBackend.sqlite,
        );
        final database = AppDatabase(snapshotStore: store);
        database.upsertRecord(
          LocalTableName.localTransferRecords,
          'transaction-update',
          const <String, Object?>{
            'transfer_id': 'transaction-update',
            'stage': 'queued',
          },
        );
        _insertExternalSqliteRecord(
          sqliteFile,
          table: LocalTableName.localTransferRecords,
          key: 'external-transaction-row',
          value: const <String, Object?>{
            'transfer_id': 'external-transaction-row',
            'stage': 'external',
          },
        );

        final result = database.withTransaction<void>((transaction) {
          transaction.upsertRecord(
            LocalTableName.localTransferRecords,
            'transaction-update',
            const <String, Object?>{
              'transfer_id': 'transaction-update',
              'stage': 'complete',
            },
          );
          transaction.upsertRecord(
            LocalTableName.localTransferRecords,
            'transaction-create',
            const <String, Object?>{
              'transfer_id': 'transaction-create',
              'stage': 'complete',
            },
          );
        });

        expect(result.ok, isTrue);
        final raw = sqlite.sqlite3.open(sqliteFile.path);
        try {
          expect(
            raw.select(
              'SELECT record_key FROM local_records WHERE table_name = ? '
              'AND record_key = ?',
              <Object?>[
                LocalTableName.localTransferRecords.dbName,
                'external-transaction-row',
              ],
            ),
            hasLength(1),
          );
          expect(
            raw.select('SELECT record_key FROM local_records'),
            hasLength(3),
          );
        } finally {
          raw.close();
        }
        final recovered = AppDatabase(snapshotStore: store);
        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localTransferRecords,
            'transaction-update',
          )?['stage'],
          'complete',
        );
        expect(
          recovered.getRecord<LocalDatabaseRecord>(
            LocalTableName.localTransferRecords,
            'external-transaction-row',
          ),
          isNotNull,
        );
      },
    );

    test('SQLite bootstrap projection never creates schema on read', () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-db-read-only-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final file = File('${root.path}/empty.sqlite');
      sqlite.sqlite3.open(file.path).close();
      final store = LocalDatabaseSnapshotStore(
        file: file,
        backend: LocalDatabaseSnapshotBackend.sqlite,
      );

      expect(store.load(), isNull);

      final raw = sqlite.sqlite3.open(
        file.path,
        mode: sqlite.OpenMode.readOnly,
      );
      addTearDown(raw.close);
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('local_metadata', 'local_records')",
        ),
        isEmpty,
      );
    });

    test('sqlite checkpoint upsert preserves every unrelated row', () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-db-checkpoint-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final sqliteFile = File('${root.path}/local-db.sqlite');
      final store = LocalDatabaseSnapshotStore(
        file: sqliteFile,
        backend: LocalDatabaseSnapshotBackend.sqlite,
      );
      final db = AppDatabase(snapshotStore: store);
      db.upsertRecord(
        LocalTableName.localRecordings,
        'recording-1',
        const <String, Object?>{'recording_id': 'recording-1'},
      );
      db.upsertRecord(
        LocalTableName.localTransferRecords,
        'transfer-1',
        const <String, Object?>{'transfer_id': 'transfer-1', 'stage': 'queued'},
      );
      db.upsertRecord(
        LocalTableName.localTransferRecords,
        'transfer-2',
        const <String, Object?>{'transfer_id': 'transfer-2', 'stage': 'queued'},
      );

      db.upsertCheckpointRecord(
        LocalTableName.localTransferRecords,
        'transfer-1',
        const <String, Object?>{'transfer_id': 'transfer-1', 'stage': 'staged'},
      );

      final raw = sqlite.sqlite3.open(sqliteFile.path);
      addTearDown(raw.close);
      expect(raw.select('SELECT record_key FROM local_records'), hasLength(3));
      expect(
        raw.select(
          'SELECT payload_json FROM local_records '
          'WHERE table_name = ? AND record_key = ?',
          <Object?>[LocalTableName.localTransferRecords.dbName, 'transfer-2'],
        ).single['payload_json'],
        contains('queued'),
      );
      final recovered = AppDatabase(snapshotStore: store);
      expect(
        recovered.getRecord<LocalDatabaseRecord>(
          LocalTableName.localTransferRecords,
          'transfer-1',
        )?['stage'],
        'staged',
      );
      expect(
        recovered.getRecord<LocalDatabaseRecord>(
          LocalTableName.localRecordings,
          'recording-1',
        ),
        isNotNull,
      );
    });

    test(
      'worker-backed writes clear and migration never use sync snapshot writes',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'app-database-worker-backed-',
        );
        final file = File('${root.path}/local.sqlite');
        final store = _RejectingSyncWriteStore(file: file);
        final worker = await DatabaseWorker.start(file: file);
        final queue = DatabaseWriteQueue();
        addTearDown(() async {
          if (!queue.isDisposed) await queue.dispose();
          if (!worker.isDisposed) await worker.dispose();
          if (await root.exists()) await root.delete(recursive: true);
        });
        final database = AppDatabase(
          schemaVersion: 8,
          snapshotStore: store,
          writeWorker: worker,
          writeQueue: queue,
        );
        final userA = RecordingDao(database, userScope: 'worker-user-a');
        final userB = RecordingDao(database, userScope: 'worker-user-b');
        const at = '2026-08-31T09:00:00.000Z';
        final baseRecord = <String, Object?>{
          'recording_id': 'shared-recording',
          'source': 'localImport',
          'status': 'localOnly',
          'format': 'm4a',
          'local_file_state': 'ready',
          'app_private_uri': 'app-private://recordings/shared/source.m4a',
          'display_name': 'Shared.m4a',
          'duration_seconds': 20,
          'size_bytes': 1024,
          'created_at': at,
          'updated_at': at,
        };
        userA.upsertLocalRecording('shared-recording', baseRecord);
        userB.upsertLocalRecording('shared-recording', baseRecord);
        final transaction = database.withTransaction<void>((db) {
          db.upsertRecord(
            LocalTableName.profileTodos,
            'todo-a',
            const <String, Object?>{
              'user_scope': 'worker-user-a',
              'todo_id': 'todo-a',
              'title': 'A',
              'created_at': at,
              'updated_at': at,
            },
          );
          db.upsertRecord(
            LocalTableName.profileTodos,
            'todo-b',
            const <String, Object?>{
              'user_scope': 'worker-user-b',
              'todo_id': 'todo-b',
              'title': 'B',
              'created_at': at,
              'updated_at': at,
            },
          );
        });
        expect(transaction.ok, isTrue);

        final cleared = database.clearUserScopedLocalData('worker-user-a');
        expect(cleared.value?.clearedRows, 2);
        expect(userA.listLocalRecordings(), isEmpty);
        expect(userB.listLocalRecordings(), hasLength(1));
        expect(database.runMigrations(localDatabaseSchemaVersion).ok, isTrue);
        await database.flushPersistence();

        expect(store.syncWriteCalls, 0);
        final recordings = await worker.listRecords(
          LocalTableName.localRecordings,
        );
        expect(recordings, hasLength(1));
        expect(recordings.single['user_scope'], 'worker-user-b');
        final todos = await worker.listRecords(LocalTableName.profileTodos);
        expect(todos, hasLength(1));
        expect(todos.single['todo_id'], 'todo-b');
        final raw = sqlite.sqlite3.open(file.path);
        addTearDown(raw.close);
        expect(
          raw.select(
            'SELECT value FROM local_metadata WHERE key = ?',
            <Object?>['schemaVersion'],
          ).single['value'],
          '$localDatabaseSchemaVersion',
        );
      },
    );

    test('worker failure is returned by flush without sync fallback', () async {
      final queue = DatabaseWriteQueue();
      final store = _RejectingSyncWriteStore(
        file: File('unused-worker.sqlite'),
      );
      final database = AppDatabase(
        snapshotStore: store,
        writeWorker: const _FailingWriteWorker(),
        writeQueue: queue,
      );
      addTearDown(queue.dispose);

      database.upsertRecord(
        LocalTableName.appPreferences,
        'preference-worker-failure',
        const <String, Object?>{
          'preference_key': 'worker.failure',
          'value': 'visible-before-flush',
          'updated_at': '2026-08-31T09:00:00.000Z',
        },
      );
      expect(
        database.getRecord<LocalDatabaseRecord>(
          LocalTableName.appPreferences,
          'preference-worker-failure',
        )?['value'],
        'visible-before-flush',
      );

      await expectLater(
        database.flushPersistence(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'injected worker failure',
          ),
        ),
      );
      expect(store.syncWriteCalls, 0);
    });

    test('purges all recording related metadata but preserves shared tags', () {
      final db = AppDatabase();
      final dao = RecordingDao(db);
      const at = '2026-07-01T09:00:00.000Z';

      dao.upsertLocalRecording('recording-1', const <String, Object?>{
        'recording_id': 'recording-1',
        'source': 'localImport',
        'status': 'localOnly',
        'format': 'm4a',
        'local_file_state': 'ready',
        'app_private_uri': 'app-private://recordings/local-a/source.m4a',
        'display_name': 'Meeting.m4a',
        'duration_seconds': 90,
        'size_bytes': 2048,
        'created_at': at,
        'updated_at': at,
      });
      dao.upsertLocalRecording('recording-2', const <String, Object?>{
        'recording_id': 'recording-2',
        'source': 'localImport',
        'status': 'localOnly',
        'format': 'm4a',
        'local_file_state': 'ready',
        'app_private_uri': 'app-private://recordings/local-b/source.m4a',
        'display_name': 'Shared.m4a',
        'duration_seconds': 30,
        'size_bytes': 1024,
        'created_at': at,
        'updated_at': at,
      });
      dao.upsertTag('tag-a', const <String, Object?>{
        'tag_id': 'tag-a',
        'name': 'tag-a',
        'created_at': at,
        'updated_at': at,
      });
      dao.upsertTag('tag-shared', const <String, Object?>{
        'tag_id': 'tag-shared',
        'name': 'tag-shared',
        'created_at': at,
        'updated_at': at,
      });
      dao.replaceTagLinks('recording-1', const <String>[
        'tag-a',
        'tag-shared',
      ], at);
      dao.replaceTagLinks('recording-2', const <String>['tag-shared'], at);
      dao.upsertTrash(
        recordingId: 'recording-1',
        deletedAt: at,
        retentionUntil: '2026-07-31T09:00:00.000Z',
      );
      db.upsertRecord(LocalTableName.localRecordingPlayback, 'recording-1', {
        'recording_id': 'recording-1',
        'position_seconds': 12,
        'updated_at': at,
      });
      dao.upsertUploadDraft(
        draftId: 'draft-1',
        localFileId: 'recording-1',
        stage: 'localReady',
        updatedAt: at,
      );
      db.upsertRecord(
        LocalTableName.localRecordingRecoveryCheckpoints,
        'checkpoint-1',
        const <String, Object?>{
          'checkpoint_id': 'checkpoint-1',
          'local_file_id': 'recording-1',
          'checkpoint_type': 'upload',
          'accepted_bytes': 2048,
          'updated_at': at,
        },
      );
      db.upsertRecord(LocalTableName.localTransferRecords, 'transfer-1', {
        'transfer_id': 'transfer-1',
        'recording_id': 'recording-1',
        'stage': 'upload',
        'idempotency_key': 'idem-1',
        'updated_at': at,
      });
      dao.upsertDeviceLocalMapping(
        deviceId: 'device-1',
        deviceFileKey: 'file-1',
        localRecordingId: 'recording-1',
        syncStatus: 'downloaded',
        updatedAt: at,
      );
      dao.upsertDownloadedManifest(
        deviceFileId: 'device-file-1',
        deviceFingerprint: 'device-fingerprint',
        deviceFilename: 'Meeting.m4a',
        localFileId: 'recording-1',
        appPrivateUri: 'app-private://recordings/local-a/source.m4a',
        expectedSizeBytes: 2048,
        actualSizeBytes: 2048,
        durationSeconds: 90,
        contentHash: 'abc123',
        downloadedAt: at,
        updatedAt: at,
      );

      dao.purgeRelatedMetadata('recording-1');

      expect(dao.getLocalRecording('recording-1'), isNull);
      expect(
        db.getRecord<LocalDatabaseRecord>(
          LocalTableName.localRecordingTrash,
          'recording-1',
        ),
        isNull,
      );
      expect(
        db.listRecords<LocalDatabaseRecord>(
          LocalTableName.localRecordingTagLinks,
        ),
        contains(
          predicate<LocalDatabaseRecord>(
            (record) => record['recording_id'] == 'recording-2',
          ),
        ),
      );
      expect(
        db.listRecords<LocalDatabaseRecord>(
          LocalTableName.localRecordingTagLinks,
        ),
        isNot(
          contains(
            predicate<LocalDatabaseRecord>(
              (record) => record['recording_id'] == 'recording-1',
            ),
          ),
        ),
      );
      expect(
        db.getRecord<LocalDatabaseRecord>(
          LocalTableName.localRecordingTags,
          'tag-a',
        ),
        isNull,
      );
      expect(
        db.getRecord<LocalDatabaseRecord>(
          LocalTableName.localRecordingTags,
          'tag-shared',
        ),
        isNotNull,
      );
      for (final table in <LocalTableName>[
        LocalTableName.localRecordingPlayback,
        LocalTableName.localRecordingUploadDrafts,
        LocalTableName.localRecordingRecoveryCheckpoints,
        LocalTableName.localTransferRecords,
        LocalTableName.deviceLocalRecordingMappings,
        LocalTableName.recordingCardDownloadedManifest,
      ]) {
        expect(db.listRecords(table), isEmpty, reason: table.dbName);
      }
    });
  });
}

final class _CountingSnapshotStore extends LocalDatabaseSnapshotStore {
  _CountingSnapshotStore({required super.file});

  int saveCount = 0;

  void resetCounts() {
    saveCount = 0;
  }

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    saveCount += 1;
    super.save(schemaVersion: schemaVersion, tables: tables);
  }
}

final class _RejectingSyncWriteStore extends LocalDatabaseSnapshotStore {
  _RejectingSyncWriteStore({required super.file})
    : super(backend: LocalDatabaseSnapshotBackend.sqlite);

  var syncWriteCalls = 0;

  @override
  LocalDatabaseSnapshot? load() => null;

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    syncWriteCalls += 1;
    throw StateError('synchronous snapshot write is forbidden');
  }

  @override
  void upsertRecord({
    required int schemaVersion,
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord value,
  }) {
    syncWriteCalls += 1;
    throw StateError('synchronous record write is forbidden');
  }

  @override
  void deleteRecord({
    required int schemaVersion,
    required LocalTableName table,
    required String key,
  }) {
    syncWriteCalls += 1;
    throw StateError('synchronous record delete is forbidden');
  }
}

final class _FailingWriteWorker implements LocalDatabaseWriteWorkerPort {
  const _FailingWriteWorker();

  @override
  bool get isDisposed => false;

  @override
  Future<void> applyRecordMutations({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
  }) async => throw StateError('injected worker failure');

  @override
  Future<void> replaceAllRecords({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) async => throw StateError('injected worker failure');
}

void _insertExternalSqliteRecord(
  File file, {
  required LocalTableName table,
  required String key,
  required LocalDatabaseRecord value,
}) {
  final db = sqlite.sqlite3.open(file.path);
  try {
    db.execute(
      'INSERT INTO local_records(table_name, record_key, payload_json) '
      'VALUES (?, ?, ?)',
      <Object?>[table.dbName, key, jsonEncode(value)],
    );
  } finally {
    db.close();
  }
}
