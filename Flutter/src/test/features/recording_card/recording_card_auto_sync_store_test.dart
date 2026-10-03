import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_auto_sync_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_auto_sync.dart';

void main() {
  test('preferences default on/off and remain account isolated', () {
    final database = AppDatabase();
    final first = RecordingCardAutoSyncStore(
      database: database,
      accountScope: 'account-a',
    );
    final second = RecordingCardAutoSyncStore(
      database: database,
      accountScope: 'account-b',
    );

    expect(first.loadPreferences().autoSyncEnabled, isTrue);
    expect(first.loadPreferences().autoTranscriptionEnabled, isFalse);
    first.savePreferences(
      const RecordingCardAutoSyncPreferences(
        autoSyncEnabled: false,
        autoTranscriptionEnabled: true,
      ),
    );

    expect(first.loadPreferences().autoSyncEnabled, isFalse);
    expect(first.loadPreferences().autoTranscriptionEnabled, isTrue);
    expect(second.loadPreferences().autoSyncEnabled, isTrue);
    expect(second.loadPreferences().autoTranscriptionEnabled, isFalse);
  });

  test('interrupted task restores queued without sensitive fields', () {
    final database = AppDatabase();
    final store = RecordingCardAutoSyncStore(
      database: database,
      accountScope: 'account-a',
    );
    final now = DateTime.utc(2026, 7, 26, 9);
    store.saveTask(
      RecordingCardAutoSyncTask(
        taskId: 'recording-card-auto:device:file-1',
        deviceFingerprint: 'safe-device',
        deviceFileId: 'file-1',
        deviceFilename: 'REC001.WAV',
        localFileKey: 'local-file-1',
        order: 0,
        state: RecordingCardAutoSyncTaskState.downloading,
        attemptCount: 1,
        createdAt: now,
        updatedAt: now,
        expectedSizeBytes: 4096,
      ),
    );

    final restored = store.loadTasks().single;
    expect(restored.state, RecordingCardAutoSyncTaskState.queued);
    final persisted = database
        .listRecords<LocalDatabaseRecord>(LocalTableName.localTransferRecords)
        .single;
    expect(persisted.toString(), isNot(contains('ssid')));
    expect(persisted.toString(), isNot(contains('password')));
    expect(persisted.toString(), isNot(contains('app-private://')));
    expect(persisted.toString(), isNot(contains('audioBytes')));

    final cleared = database.clearUserScopedLocalData('account-a');
    expect(cleared.ok, isTrue);
    expect(database.listRecords(LocalTableName.localTransferRecords), isEmpty);
  });

  test('interrupted transcription keeps its durable resume intent', () {
    final database = AppDatabase();
    final store = RecordingCardAutoSyncStore(
      database: database,
      accountScope: 'account-a',
    );
    final now = DateTime.utc(2026, 7, 26, 10);
    store.saveTask(
      RecordingCardAutoSyncTask(
        taskId: 'recording-card-auto:device:file-2',
        deviceFingerprint: 'safe-device',
        deviceFileId: 'file-2',
        deviceFilename: 'REC002.WAV',
        localFileKey: 'local-file-2',
        order: 1,
        state: RecordingCardAutoSyncTaskState.transcribing,
        attemptCount: 1,
        createdAt: now,
        updatedAt: now,
        expectedSizeBytes: 8192,
        localRecordingId: 'local-file-2',
        transcriptionRequested: true,
      ),
    );

    final restored = store.loadTasks().single;

    expect(restored.state, RecordingCardAutoSyncTaskState.queued);
    expect(restored.localRecordingId, 'local-file-2');
    expect(restored.transcriptionRequested, isTrue);
  });

  test('same logical task remains isolated by account-scoped physical key', () {
    final database = AppDatabase();
    final accountA = RecordingCardAutoSyncStore(
      database: database,
      accountScope: 'account-a',
    );
    final accountB = RecordingCardAutoSyncStore(
      database: database,
      accountScope: 'account-b',
    );
    final now = DateTime.utc(2026, 9, 4, 12);
    const taskId = 'recording-card-auto:shared-card:shared-file';

    accountA.saveTask(
      _task(
        taskId: taskId,
        state: RecordingCardAutoSyncTaskState.completed,
        updatedAt: now,
      ),
    );
    accountB.saveTask(
      _task(
        taskId: taskId,
        state: RecordingCardAutoSyncTaskState.failed,
        updatedAt: now.add(const Duration(minutes: 1)),
      ),
    );

    expect(
      accountA.loadTasks().single.state,
      RecordingCardAutoSyncTaskState.completed,
    );
    expect(
      accountB.loadTasks().single.state,
      RecordingCardAutoSyncTaskState.failed,
    );
    expect(
      database.listRecords(LocalTableName.localTransferRecords),
      hasLength(2),
    );
  });

  test('legacy bare task migration never removes a foreign account row', () {
    final database = AppDatabase();
    final store = RecordingCardAutoSyncStore(
      database: database,
      accountScope: 'account-a',
    );
    final now = DateTime.utc(2026, 9, 4, 13);
    const ownedTaskId = 'recording-card-auto:legacy:owned';
    const foreignTaskId = 'recording-card-auto:legacy:foreign';
    final accountAHash = _scopeHash('account-a');
    final accountBHash = _scopeHash('account-b');
    database.upsertRecord(
      LocalTableName.localTransferRecords,
      ownedTaskId,
      _taskRecord(
        taskId: ownedTaskId,
        accountScope: 'account-a',
        scopeHash: accountAHash,
        updatedAt: now,
      ),
    );

    expect(store.loadTasks().single.taskId, ownedTaskId);
    expect(
      database.getRecord(LocalTableName.localTransferRecords, ownedTaskId),
      isNull,
    );
    expect(
      database.getRecord(
        LocalTableName.localTransferRecords,
        '$accountAHash:$ownedTaskId',
      ),
      isNotNull,
    );

    database.upsertRecord(
      LocalTableName.localTransferRecords,
      foreignTaskId,
      _taskRecord(
        taskId: foreignTaskId,
        accountScope: 'account-b',
        scopeHash: accountBHash,
        updatedAt: now,
      ),
    );
    store.saveTask(
      _task(
        taskId: foreignTaskId,
        state: RecordingCardAutoSyncTaskState.completed,
        updatedAt: now.add(const Duration(minutes: 1)),
      ),
    );

    expect(
      database.getRecord<LocalDatabaseRecord>(
        LocalTableName.localTransferRecords,
        foreignTaskId,
      )?['user_scope'],
      'account-b',
    );
    expect(
      store.loadTasks().map((task) => task.taskId),
      contains(foreignTaskId),
    );
  });
}

RecordingCardAutoSyncTask _task({
  required String taskId,
  required RecordingCardAutoSyncTaskState state,
  required DateTime updatedAt,
}) {
  return RecordingCardAutoSyncTask(
    taskId: taskId,
    deviceFingerprint: 'shared-card',
    deviceFileId: 'shared-file',
    deviceFilename: 'shared-file.wav',
    localFileKey: 'shared-file-key',
    order: 0,
    state: state,
    attemptCount: 0,
    createdAt: updatedAt,
    updatedAt: updatedAt,
    expectedSizeBytes: 4096,
  );
}

LocalDatabaseRecord _taskRecord({
  required String taskId,
  required String accountScope,
  required String scopeHash,
  required DateTime updatedAt,
}) {
  return <String, Object?>{
    'transfer_id': taskId,
    'transfer_kind': 'recording_card_auto_sync',
    'user_scope': accountScope,
    'batch_id': scopeHash,
    'device_fingerprint': 'legacy-card',
    'device_file_id': 'legacy-file',
    'device_filename': 'legacy-file.wav',
    'local_file_key': 'legacy-file-key',
    'item_order': 0,
    'expected_size_bytes': 4096,
    'attempt_count': 0,
    'stage': 'completed',
    'created_at': updatedAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };
}

String _scopeHash(String accountScope) =>
    sha256.convert(utf8.encode(accountScope)).toString();
