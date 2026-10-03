import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_worker_schema.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('disabled feature flag creates no file or isolate connection', () async {
    final root = await Directory.systemTemp.createTemp('db-worker-disabled-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final file = File('${root.path}/worker.sqlite');

    final worker = await DatabaseWorker.start(file: file, enabled: false);
    final health = await worker.health();

    expect(worker.isEnabled, isFalse);
    expect(health.enabled, isFalse);
    expect(health.connectionGeneration, 0);
    expect(await file.exists(), isFalse);
    await worker.dispose();
    expect(worker.isDisposed, isTrue);
  });

  test(
    'worker reuses one WAL connection and prepared incremental SQL',
    () async {
      final harness = await _WorkerHarness.create('incremental');
      addTearDown(harness.dispose);
      final firstHealth = await harness.worker.health();

      await harness.worker.upsertRecordBatch(
        table: LocalTableName.appPreferences,
        records: const <String, LocalDatabaseRecord>{
          'preference-a': <String, Object?>{
            'preference_key': 'appearance',
            'value': 'light',
          },
          'preference-b': <String, Object?>{
            'preference_key': 'quality',
            'value': 'balanced',
          },
        },
      );
      expect(
        await harness.worker.listRecords(LocalTableName.appPreferences),
        hasLength(2),
      );
      expect(
        await harness.worker.deleteRecord(
          table: LocalTableName.appPreferences,
          key: 'preference-a',
        ),
        isTrue,
      );

      final secondHealth = await harness.worker.health();
      expect(firstHealth.isReady, isTrue);
      expect(firstHealth.workerIdentity, isNot(Isolate.current.hashCode));
      expect(
        secondHealth.connectionGeneration,
        firstHealth.connectionGeneration,
      );
      expect(secondHealth.workerIdentity, firstHealth.workerIdentity);
      expect(secondHealth.preparedStatementCount, 17);
      expect(
        secondHealth.commandsHandled,
        greaterThan(firstHealth.commandsHandled),
      );
      expect(
        secondHealth.indexes,
        containsAll(DatabaseWorkerSchema.requiredIndexes),
      );

      await harness.worker.dispose();
      final raw = sqlite.sqlite3.open(harness.file.path);
      addTearDown(raw.close);
      expect(_pragmaText(raw, 'journal_mode'), 'wal');
      expect(
        raw
            .select(
              'SELECT record_key FROM local_records WHERE table_name = ?',
              <Object?>[LocalTableName.appPreferences.dbName],
            )
            .map((row) => '${row['record_key']}'),
        <String>['preference-b'],
      );
    },
  );

  test('Chat and derived checkpoints update one run row at a time', () async {
    final harness = await _WorkerHarness.create('checkpoints');
    addTearDown(harness.dispose);
    final createdAt = DateTime.utc(2026, 8, 31, 9);

    await harness.worker.upsertChatRunCheckpoint(
      ChatRunCheckpoint(
        userScope: 'user:alpha',
        runId: 'agent-run-1',
        kind: ChatRunCheckpointKind.chat,
        status: 'running',
        eventSequence: 8,
        threadId: 'thread-1',
        scene: 'general',
        purpose: 'general',
        createdAt: createdAt,
        updatedAt: createdAt,
        publicState: const <String, Object?>{
          'kind': 'chat',
          'agentRunId': 'agent-run-1',
          'threadId': 'thread-1',
          'status': 'running',
        },
      ),
    );
    await harness.worker.upsertChatRunCheckpoint(
      ChatRunCheckpoint(
        userScope: 'user:alpha',
        runId: 'derived-run-1',
        kind: ChatRunCheckpointKind.derived,
        status: 'queued',
        eventSequence: 0,
        localNoteId: 'note-1',
        targetPart: 'summary',
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    await harness.worker.upsertChatRunCheckpoint(
      ChatRunCheckpoint(
        userScope: 'user:alpha',
        runId: 'agent-run-1',
        kind: ChatRunCheckpointKind.chat,
        status: 'completed',
        eventSequence: 12,
        threadId: 'thread-1',
        scene: 'general',
        purpose: 'general',
        createdAt: createdAt.add(const Duration(hours: 1)),
        updatedAt: createdAt.add(const Duration(seconds: 10)),
        role: ChatRunCheckpointRole.ledger,
        publicState: const <String, Object?>{
          'kind': 'chat',
          'taskId': 'agent-run-1',
          'threadId': 'thread-1',
          'status': 'completed',
        },
      ),
    );

    final rows = await harness.worker.listChatRunCheckpoints('user:alpha');
    expect(rows, hasLength(2));
    final chat = rows.singleWhere((row) => row.runId == 'agent-run-1');
    final derived = rows.singleWhere((row) => row.runId == 'derived-run-1');
    expect(chat.status, 'completed');
    expect(chat.eventSequence, 12);
    expect(chat.createdAt, createdAt);
    expect(chat.role, ChatRunCheckpointRole.ledger);
    expect(chat.publicState['taskId'], 'agent-run-1');
    expect(chat.publicState.toString(), isNot(contains('assistant')));
    expect(derived.status, 'queued');
    expect(derived.localNoteId, 'note-1');
    expect(
      await harness.worker.deleteChatRunCheckpoint(
        userScope: 'user:alpha',
        runId: 'agent-run-1',
      ),
      isTrue,
    );
    expect(
      await harness.worker.listChatRunCheckpoints('user:alpha'),
      hasLength(1),
    );

    final firstClose = harness.worker.dispose();
    final secondClose = harness.worker.dispose();
    expect(identical(secondClose, firstClose), isTrue);
    await firstClose;
    final raw = sqlite.sqlite3.open(harness.file.path);
    addTearDown(raw.close);
    final columns = raw
        .select('PRAGMA table_info(chat_run_checkpoints)')
        .map((row) => '${row['name']}')
        .toSet();
    expect(columns, isNot(contains('message_text')));
    expect(columns, isNot(contains('ledger_json')));
    expect(columns, isNot(contains('payload_json')));
    expect(
      columns,
      containsAll(<String>['checkpoint_role', 'public_state_json']),
    );
  });

  test('a failed Chat checkpoint diff rolls back every row', () async {
    final harness = await _WorkerHarness.create('checkpoint-rollback');
    addTearDown(harness.dispose);
    final createdAt = DateTime.utc(2026, 8, 31, 9);
    await harness.worker.applyChatRunCheckpointChanges(
      userScope: 'user:atomic',
      upserts: <ChatRunCheckpoint>[
        _chatCheckpoint(
          userScope: 'user:atomic',
          runId: 'run-1',
          status: 'running',
          updatedAt: createdAt,
        ),
        _chatCheckpoint(
          userScope: 'user:atomic',
          runId: 'run-2',
          status: 'running',
          updatedAt: createdAt,
        ),
      ],
      deletions: const <String>[],
    );
    final raw = sqlite.sqlite3.open(harness.file.path);
    raw.execute(
      'CREATE TRIGGER fail_second_checkpoint_update '
      'BEFORE UPDATE ON chat_run_checkpoints '
      "WHEN NEW.run_id = 'run-2' "
      "BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
    );
    raw.close();

    await expectLater(
      harness.worker.applyChatRunCheckpointChanges(
        userScope: 'user:atomic',
        upserts: <ChatRunCheckpoint>[
          _chatCheckpoint(
            userScope: 'user:atomic',
            runId: 'run-1',
            status: 'finalizing',
            updatedAt: createdAt.add(const Duration(seconds: 1)),
          ),
          _chatCheckpoint(
            userScope: 'user:atomic',
            runId: 'run-2',
            status: 'finalizing',
            updatedAt: createdAt.add(const Duration(seconds: 1)),
          ),
        ],
        deletions: const <String>[],
      ),
      throwsA(isA<DatabaseWorkerException>()),
    );

    final rows = await harness.worker.listChatRunCheckpoints('user:atomic');
    expect(rows.map((row) => row.status), everyElement('running'));
  });

  test('multi-table record mutations roll back as one transaction', () async {
    final harness = await _WorkerHarness.create('record-batch-rollback');
    addTearDown(harness.dispose);
    await harness.worker.applyRecordMutations(
      schemaVersion: localDatabaseSchemaVersion,
      mutations: const <LocalDatabaseMutation>[
        LocalDatabaseMutation.upsert(
          table: LocalTableName.appPreferences,
          key: 'record-1',
          value: <String, Object?>{
            'preference_key': 'record-1',
            'value': 'before-1',
          },
        ),
        LocalDatabaseMutation.upsert(
          table: LocalTableName.profileTodos,
          key: 'record-2',
          value: <String, Object?>{
            'user_scope': 'user-1',
            'todo_id': 'record-2',
            'title': 'before-2',
          },
        ),
      ],
    );
    final raw = sqlite.sqlite3.open(harness.file.path);
    raw.execute(
      'CREATE TRIGGER fail_second_record_update '
      'BEFORE UPDATE ON local_records '
      "WHEN NEW.record_key = 'record-2' "
      "BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
    );
    raw.close();

    await expectLater(
      harness.worker.applyRecordMutations(
        schemaVersion: localDatabaseSchemaVersion,
        mutations: const <LocalDatabaseMutation>[
          LocalDatabaseMutation.upsert(
            table: LocalTableName.appPreferences,
            key: 'record-1',
            value: <String, Object?>{
              'preference_key': 'record-1',
              'value': 'after-1',
            },
          ),
          LocalDatabaseMutation.upsert(
            table: LocalTableName.profileTodos,
            key: 'record-2',
            value: <String, Object?>{
              'user_scope': 'user-1',
              'todo_id': 'record-2',
              'title': 'after-2',
            },
          ),
        ],
      ),
      throwsA(isA<DatabaseWorkerException>()),
    );

    expect(
      (await harness.worker.listRecords(
        LocalTableName.appPreferences,
      )).single['value'],
      'before-1',
    );
    expect(
      (await harness.worker.listRecords(
        LocalTableName.profileTodos,
      )).single['title'],
      'before-2',
    );
  });

  test(
    'projection replacement is atomic and survives worker restart',
    () async {
      final harness = await _WorkerHarness.create('projection-recovery');
      addTearDown(harness.dispose);
      await harness.worker.applyRecordMutations(
        schemaVersion: localDatabaseSchemaVersion,
        mutations: const <LocalDatabaseMutation>[
          LocalDatabaseMutation.upsert(
            table: LocalTableName.appPreferences,
            key: 'keep-1',
            value: <String, Object?>{
              'preference_key': 'keep-1',
              'value': 'old-1',
            },
          ),
          LocalDatabaseMutation.upsert(
            table: LocalTableName.appPreferences,
            key: 'keep-2',
            value: <String, Object?>{
              'preference_key': 'keep-2',
              'value': 'old-2',
            },
          ),
        ],
      );
      final raw = sqlite.sqlite3.open(harness.file.path);
      raw.execute(
        'CREATE TRIGGER interrupt_projection_replace '
        'BEFORE DELETE ON local_records '
        "WHEN OLD.record_key = 'keep-2' "
        "BEGIN SELECT RAISE(ABORT, 'simulated interruption'); END",
      );
      raw.close();

      await expectLater(
        harness.worker.replaceAllRecords(
          schemaVersion: localDatabaseSchemaVersion,
          tables: const <LocalTableName, Map<String, LocalDatabaseRecord>>{
            LocalTableName.appPreferences: <String, LocalDatabaseRecord>{
              'replacement': <String, Object?>{
                'preference_key': 'replacement',
                'value': 'new',
              },
            },
          },
        ),
        throwsA(isA<DatabaseWorkerException>()),
      );
      expect(
        await harness.worker.listRecords(LocalTableName.appPreferences),
        hasLength(2),
      );

      final cleanup = sqlite.sqlite3.open(harness.file.path);
      cleanup.execute('DROP TRIGGER interrupt_projection_replace');
      cleanup.close();
      await harness.worker.replaceAllRecords(
        schemaVersion: localDatabaseSchemaVersion,
        tables: const <LocalTableName, Map<String, LocalDatabaseRecord>>{
          LocalTableName.appPreferences: <String, LocalDatabaseRecord>{
            'replacement': <String, Object?>{
              'preference_key': 'replacement',
              'value': 'new',
            },
          },
        },
      );
      await harness.worker.dispose();

      final recovered = await DatabaseWorker.start(file: harness.file);
      addTearDown(recovered.dispose);
      final records = await recovered.listRecords(
        LocalTableName.appPreferences,
      );
      expect(records, hasLength(1));
      expect(records.single['value'], 'new');
    },
  );

  test('V3 checkpoint rows gain V4 public state without replacement', () {
    final root = Directory.systemTemp.createTempSync('db-worker-v3-');
    addTearDown(() => root.deleteSync(recursive: true));
    final raw = sqlite.sqlite3.open('${root.path}/worker.sqlite');
    addTearDown(raw.close);
    raw.execute(
      'CREATE TABLE chat_run_checkpoints('
      'user_scope TEXT NOT NULL, run_id TEXT NOT NULL, kind TEXT NOT NULL, '
      'status TEXT NOT NULL, event_sequence INTEGER NOT NULL DEFAULT 0, '
      'thread_id TEXT, scene TEXT, purpose TEXT, local_note_id TEXT, '
      'target_part TEXT, failure_code TEXT, created_at TEXT NOT NULL, '
      'updated_at TEXT NOT NULL, PRIMARY KEY(user_scope, run_id))',
    );
    raw.execute(
      'INSERT INTO chat_run_checkpoints('
      'user_scope, run_id, kind, status, created_at, updated_at'
      ") VALUES ('user:alpha', 'run-legacy', 'chat', 'running', "
      "'2026-08-31T09:00:00Z', '2026-08-31T09:00:00Z')",
    );
    raw.execute('PRAGMA user_version = 3');

    DatabaseWorkerSchema.migrate(raw);

    final row = raw.select('SELECT * FROM chat_run_checkpoints').single;
    expect(_pragmaInt(raw, 'user_version'), 4);
    expect(row['run_id'], 'run-legacy');
    expect(row['checkpoint_role'], 'active');
    expect(row['public_state_json'], '{}');
  });

  test('outbox lease recovery and inbox dedupe remain reliable', () async {
    final harness = await _WorkerHarness.create('sync');
    addTearDown(harness.dispose);
    final createdAt = DateTime.utc(2026, 8, 31, 10);
    final entry = DatabaseOutboxEntry(
      operationId: 'operation-1',
      userScope: 'user:alpha',
      topic: 'note_sync',
      dedupeKey: 'note-1-revision-2',
      payload: <String, Object?>{'note_id': 'note-1', 'revision': 2},
      availableAt: _outboxTime,
      createdAt: _outboxTime,
    );

    expect(await harness.worker.enqueueOutbox(entry), isTrue);
    expect(await harness.worker.enqueueOutbox(entry), isFalse);
    expect(
      await harness.worker.enqueueOutbox(
        DatabaseOutboxEntry(
          operationId: 'operation-duplicate-dedupe',
          userScope: 'user:alpha',
          topic: 'note_sync',
          dedupeKey: 'note-1-revision-2',
          payload: <String, Object?>{'note_id': 'note-1', 'revision': 2},
          availableAt: _outboxTime,
          createdAt: _outboxTime,
        ),
      ),
      isFalse,
    );

    final firstClaim = await harness.worker.claimOutbox(
      userScope: 'user:alpha',
      now: createdAt,
      leaseDuration: const Duration(seconds: 30),
    );
    expect(firstClaim.single.attemptCount, 1);
    expect(firstClaim.single.payload['revision'], 2);
    expect(
      await harness.worker.claimOutbox(
        userScope: 'user:alpha',
        now: createdAt.add(const Duration(seconds: 10)),
      ),
      isEmpty,
    );

    final recoveredClaim = await harness.worker.claimOutbox(
      userScope: 'user:alpha',
      now: createdAt.add(const Duration(seconds: 31)),
    );
    expect(recoveredClaim.single.attemptCount, 2);
    expect(
      await harness.worker.markOutboxRetry(
        operationId: 'operation-1',
        availableAt: createdAt.add(const Duration(minutes: 3)),
        updatedAt: createdAt.add(const Duration(seconds: 32)),
        errorCode: 'NETWORK_RETRY',
      ),
      isTrue,
    );
    expect(
      await harness.worker.claimOutbox(
        userScope: 'user:alpha',
        now: createdAt.add(const Duration(minutes: 2)),
      ),
      isEmpty,
    );
    final retryClaim = await harness.worker.claimOutbox(
      userScope: 'user:alpha',
      now: createdAt.add(const Duration(minutes: 3)),
    );
    expect(retryClaim.single.attemptCount, 3);
    expect(
      await harness.worker.markOutboxSucceeded(
        operationId: 'operation-1',
        updatedAt: createdAt.add(const Duration(minutes: 3, seconds: 1)),
      ),
      isTrue,
    );
    expect(
      await harness.worker.markOutboxRetry(
        operationId: 'operation-1',
        availableAt: createdAt.add(const Duration(minutes: 4)),
        updatedAt: createdAt.add(const Duration(minutes: 3, seconds: 2)),
        errorCode: 'LATE_RETRY',
      ),
      isFalse,
    );

    expect(
      await harness.worker.acceptInbox(
        userScope: 'user:alpha',
        eventId: 'event-1',
        topic: 'note_sync',
        receivedAt: createdAt,
      ),
      isTrue,
    );
    expect(
      await harness.worker.acceptInbox(
        userScope: 'user:alpha',
        eventId: 'event-1',
        topic: 'note_sync',
        receivedAt: createdAt,
      ),
      isFalse,
    );
    expect(
      await harness.worker.markInboxProcessed(
        userScope: 'user:alpha',
        eventId: 'event-1',
        processedAt: createdAt.add(const Duration(seconds: 1)),
      ),
      isTrue,
    );

    await harness.worker.dispose();
    final raw = sqlite.sqlite3.open(harness.file.path);
    addTearDown(raw.close);
    expect(
      raw.select(
        'SELECT state, attempt_count FROM sync_outbox '
        'WHERE operation_id = ?',
        <Object?>['operation-1'],
      ).single['state'],
      'completed',
    );
    expect(raw.select('SELECT * FROM sync_outbox_payloads'), isEmpty);
    expect(
      raw.select('SELECT processed_at FROM sync_inbox').single['processed_at'],
      isNotNull,
    );
  });

  test('outbox claims are scoped and inbox admission resumes safely', () async {
    final harness = await _WorkerHarness.create('sync-scope');
    addTearDown(harness.dispose);
    Future<void> enqueue(String operationId, String topic) async {
      await harness.worker.enqueueOutbox(
        DatabaseOutboxEntry(
          operationId: operationId,
          userScope: 'user:alpha',
          topic: topic,
          dedupeKey: operationId,
          payload: <String, Object?>{'operation': operationId},
          availableAt: _outboxTime,
          createdAt: _outboxTime,
        ),
      );
    }

    await enqueue('note-operation-1', 'knowledge_note_v1');
    await enqueue('note-operation-2', 'knowledge_note_v1');
    await enqueue('upload-operation-1', 'media_upload_v1');

    final exact = await harness.worker.claimOutbox(
      userScope: 'user:alpha',
      topic: 'knowledge_note_v1',
      operationId: 'note-operation-2',
      now: _outboxTime,
    );
    expect(exact.map((entry) => entry.operationId), <String>[
      'note-operation-2',
    ]);
    expect(
      await harness.worker.markOutboxSucceeded(
        operationId: exact.single.operationId,
        updatedAt: _outboxTime,
      ),
      isTrue,
    );

    final notes = await harness.worker.claimOutbox(
      userScope: 'user:alpha',
      topic: 'knowledge_note_v1',
      now: _outboxTime,
    );
    expect(notes.map((entry) => entry.operationId), <String>[
      'note-operation-1',
    ]);
    final uploads = await harness.worker.claimOutbox(
      userScope: 'user:alpha',
      topic: 'media_upload_v1',
      now: _outboxTime,
    );
    expect(uploads.map((entry) => entry.operationId), <String>[
      'upload-operation-1',
    ]);

    expect(
      await harness.worker.beginInbox(
        userScope: 'user:alpha',
        eventId: 'workspace-event-1',
        topic: 'knowledge_note_v1',
        receivedAt: _outboxTime,
      ),
      DatabaseInboxDisposition.accepted,
    );
    expect(
      await harness.worker.beginInbox(
        userScope: 'user:alpha',
        eventId: 'workspace-event-1',
        topic: 'knowledge_note_v1',
        receivedAt: _outboxTime,
      ),
      DatabaseInboxDisposition.resume,
    );
    expect(
      await harness.worker.markInboxProcessed(
        userScope: 'user:alpha',
        eventId: 'workspace-event-1',
        processedAt: _outboxTime,
      ),
      isTrue,
    );
    expect(
      await harness.worker.beginInbox(
        userScope: 'user:alpha',
        eventId: 'workspace-event-1',
        topic: 'knowledge_note_v1',
        receivedAt: _outboxTime,
      ),
      DatabaseInboxDisposition.alreadyProcessed,
    );
  });

  test('interrupted migration rolls back and the next open recovers', () async {
    final root = await Directory.systemTemp.createTemp('db-worker-migrate-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final file = File('${root.path}/worker.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(
      'CREATE TABLE local_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    raw.execute(
      'CREATE TABLE local_records('
      'table_name TEXT NOT NULL, record_key TEXT NOT NULL, '
      'payload_json TEXT NOT NULL, PRIMARY KEY(table_name, record_key))',
    );

    expect(
      () => DatabaseWorkerSchema.migrate(
        raw,
        afterStep: (step) {
          if (step == 2) throw StateError('simulated interruption');
        },
      ),
      throwsStateError,
    );
    expect(_pragmaInt(raw, 'user_version'), 0);
    expect(
      raw.select(
        "SELECT name FROM sqlite_master WHERE name = 'chat_run_checkpoints'",
      ),
      isEmpty,
    );

    final recovered = DatabaseWorkerSchema.migrate(raw);
    expect(recovered.isValid, isTrue);
    expect(recovered.schemaVersion, databaseWorkerSchemaVersion);
    expect(recovered.journalMode, 'wal');
    expect(
      recovered.indexes,
      containsAll(DatabaseWorkerSchema.requiredIndexes),
    );
    raw.close();

    final worker = await DatabaseWorker.start(file: file);
    expect((await worker.health()).isReady, isTrue);
    await worker.dispose();
  });
}

final _outboxTime = DateTime.utc(2026, 8, 31, 10);

ChatRunCheckpoint _chatCheckpoint({
  required String userScope,
  required String runId,
  required String status,
  required DateTime updatedAt,
}) => ChatRunCheckpoint(
  userScope: userScope,
  runId: runId,
  kind: ChatRunCheckpointKind.chat,
  status: status,
  eventSequence: 0,
  threadId: 'thread-$runId',
  scene: 'general',
  purpose: 'general',
  createdAt: DateTime.utc(2026, 8, 31, 9),
  updatedAt: updatedAt,
  publicState: <String, Object?>{
    'kind': 'chat',
    'agentRunId': runId,
    'threadId': 'thread-$runId',
    'scene': 'general',
    'purpose': 'general',
    'status': status,
    'createdAt': DateTime.utc(2026, 8, 31, 9).toIso8601String(),
    'toolTrace': const <Object?>[],
  },
);

final class _WorkerHarness {
  _WorkerHarness._({
    required this.root,
    required this.file,
    required this.worker,
  });

  final Directory root;
  final File file;
  final DatabaseWorker worker;
  var _disposed = false;

  static Future<_WorkerHarness> create(String name) async {
    final root = await Directory.systemTemp.createTemp('db-worker-$name-');
    final file = File('${root.path}/worker.sqlite');
    final worker = await DatabaseWorker.start(file: file);
    return _WorkerHarness._(root: root, file: file, worker: worker);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!worker.isDisposed) await worker.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

int _pragmaInt(sqlite.Database database, String pragma) {
  final value = database.select('PRAGMA $pragma').first.values.first;
  return value is int ? value : int.parse('$value');
}

String _pragmaText(sqlite.Database database, String pragma) {
  return '${database.select('PRAGMA $pragma').first.values.first}'
      .toLowerCase();
}
