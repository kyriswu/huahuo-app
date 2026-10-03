import 'package:sqlite3/sqlite3.dart' as sqlite;

const databaseWorkerSchemaVersion = 4;

typedef DatabaseWorkerMigrationHook = void Function(int completedStep);

final class DatabaseWorkerSchemaHealth {
  const DatabaseWorkerSchemaHealth({
    required this.schemaVersion,
    required this.journalMode,
    required this.tables,
    required this.indexes,
  });

  final int schemaVersion;
  final String journalMode;
  final Set<String> tables;
  final Set<String> indexes;

  bool get isValid =>
      schemaVersion == databaseWorkerSchemaVersion &&
      journalMode == 'wal' &&
      tables.containsAll(DatabaseWorkerSchema.requiredTables) &&
      indexes.containsAll(DatabaseWorkerSchema.requiredIndexes);
}

final class DatabaseWorkerSchema {
  const DatabaseWorkerSchema._();

  static const requiredTables = <String>{
    'local_metadata',
    'local_records',
    'chat_run_checkpoints',
    'sync_outbox',
    'sync_outbox_payloads',
    'sync_inbox',
  };

  static const requiredIndexes = <String>{
    'idx_local_records_table',
    'idx_chat_run_checkpoints_scope_status_updated',
    'idx_chat_run_checkpoints_scope_thread',
    'idx_sync_outbox_due',
    'idx_sync_outbox_dedupe',
    'idx_sync_inbox_topic_received',
  };

  static DatabaseWorkerSchemaHealth migrate(
    sqlite.Database database, {
    int busyTimeoutMilliseconds = 5000,
    DatabaseWorkerMigrationHook? afterStep,
  }) {
    if (busyTimeoutMilliseconds < 0) {
      throw ArgumentError.value(
        busyTimeoutMilliseconds,
        'busyTimeoutMilliseconds',
        'must not be negative',
      );
    }
    database.execute('PRAGMA busy_timeout = $busyTimeoutMilliseconds');
    database.execute('PRAGMA foreign_keys = ON');
    final journalMode = _journalMode(database, enableWal: true);
    if (journalMode != 'wal') {
      throw StateError('DATABASE_WORKER_WAL_UNAVAILABLE');
    }

    database.execute('BEGIN IMMEDIATE');
    try {
      final currentVersion = _userVersion(database);
      if (currentVersion > databaseWorkerSchemaVersion) {
        throw StateError('DATABASE_WORKER_SCHEMA_TOO_NEW');
      }
      if (currentVersion < 1) {
        _migrateToV1(database);
        afterStep?.call(1);
      }
      if (currentVersion < 2) {
        _migrateToV2(database);
        afterStep?.call(2);
      }
      if (currentVersion < 3) {
        _migrateToV3(database);
        afterStep?.call(3);
      }
      if (currentVersion < 4) {
        _migrateToV4(database);
        afterStep?.call(4);
      }
      database.execute('PRAGMA user_version = $databaseWorkerSchemaVersion');
      database.execute('COMMIT');
    } catch (_) {
      try {
        database.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
    return inspect(database);
  }

  static DatabaseWorkerSchemaHealth inspect(sqlite.Database database) {
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => '${row['name']}')
        .toSet();
    final indexes = database
        .select("SELECT name FROM sqlite_master WHERE type = 'index'")
        .map((row) => '${row['name']}')
        .toSet();
    return DatabaseWorkerSchemaHealth(
      schemaVersion: _userVersion(database),
      journalMode: _journalMode(database),
      tables: Set<String>.unmodifiable(tables),
      indexes: Set<String>.unmodifiable(indexes),
    );
  }

  static void _migrateToV1(sqlite.Database database) {
    database.execute(
      'CREATE TABLE IF NOT EXISTS local_metadata ('
      'key TEXT PRIMARY KEY, '
      'value TEXT NOT NULL'
      ')',
    );
    database.execute(
      'CREATE TABLE IF NOT EXISTS local_records ('
      'table_name TEXT NOT NULL, '
      'record_key TEXT NOT NULL, '
      'payload_json TEXT NOT NULL, '
      'PRIMARY KEY(table_name, record_key)'
      ')',
    );
    database.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_records_table '
      'ON local_records(table_name)',
    );
  }

  static void _migrateToV2(sqlite.Database database) {
    database.execute(
      'CREATE TABLE IF NOT EXISTS chat_run_checkpoints ('
      'user_scope TEXT NOT NULL, '
      'run_id TEXT NOT NULL, '
      'kind TEXT NOT NULL, '
      'status TEXT NOT NULL, '
      'event_sequence INTEGER NOT NULL DEFAULT 0, '
      'thread_id TEXT, '
      'scene TEXT, '
      'purpose TEXT, '
      'local_note_id TEXT, '
      'target_part TEXT, '
      'failure_code TEXT, '
      'created_at TEXT NOT NULL, '
      'updated_at TEXT NOT NULL, '
      'PRIMARY KEY(user_scope, run_id)'
      ')',
    );
    database.execute(
      'CREATE INDEX IF NOT EXISTS '
      'idx_chat_run_checkpoints_scope_status_updated '
      'ON chat_run_checkpoints(user_scope, status, updated_at)',
    );
    database.execute(
      'CREATE INDEX IF NOT EXISTS idx_chat_run_checkpoints_scope_thread '
      'ON chat_run_checkpoints(user_scope, thread_id)',
    );
  }

  static void _migrateToV3(sqlite.Database database) {
    database.execute(
      'CREATE TABLE IF NOT EXISTS sync_outbox ('
      'operation_id TEXT PRIMARY KEY, '
      'user_scope TEXT NOT NULL, '
      'topic TEXT NOT NULL, '
      'dedupe_key TEXT NOT NULL, '
      'state TEXT NOT NULL, '
      'attempt_count INTEGER NOT NULL DEFAULT 0, '
      'available_at TEXT NOT NULL, '
      'lease_until TEXT, '
      'last_error_code TEXT, '
      'created_at TEXT NOT NULL, '
      'updated_at TEXT NOT NULL'
      ')',
    );
    database.execute(
      'CREATE TABLE IF NOT EXISTS sync_outbox_payloads ('
      'operation_id TEXT PRIMARY KEY, '
      'payload_json TEXT NOT NULL, '
      'FOREIGN KEY(operation_id) REFERENCES sync_outbox(operation_id) '
      'ON DELETE CASCADE'
      ')',
    );
    database.execute(
      'CREATE TABLE IF NOT EXISTS sync_inbox ('
      'user_scope TEXT NOT NULL, '
      'event_id TEXT NOT NULL, '
      'topic TEXT NOT NULL, '
      'received_at TEXT NOT NULL, '
      'processed_at TEXT, '
      'PRIMARY KEY(user_scope, event_id)'
      ')',
    );
    database.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_outbox_due '
      'ON sync_outbox(user_scope, state, available_at, lease_until)',
    );
    database.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_outbox_dedupe '
      'ON sync_outbox(user_scope, topic, dedupe_key)',
    );
    database.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_inbox_topic_received '
      'ON sync_inbox(user_scope, topic, received_at)',
    );
  }

  static void _migrateToV4(sqlite.Database database) {
    final columns = database
        .select('PRAGMA table_info(chat_run_checkpoints)')
        .map((row) => '${row['name']}')
        .toSet();
    if (!columns.contains('checkpoint_role')) {
      database.execute(
        "ALTER TABLE chat_run_checkpoints ADD COLUMN checkpoint_role TEXT NOT NULL DEFAULT 'active'",
      );
    }
    if (!columns.contains('public_state_json')) {
      database.execute(
        "ALTER TABLE chat_run_checkpoints ADD COLUMN public_state_json TEXT NOT NULL DEFAULT '{}'",
      );
    }
  }

  static int _userVersion(sqlite.Database database) {
    final rows = database.select('PRAGMA user_version');
    if (rows.isEmpty) return 0;
    final value = rows.first.values.first;
    return value is int ? value : int.tryParse('$value') ?? 0;
  }

  static String _journalMode(
    sqlite.Database database, {
    bool enableWal = false,
  }) {
    final rows = database.select(
      enableWal ? 'PRAGMA journal_mode = WAL' : 'PRAGMA journal_mode',
    );
    if (rows.isEmpty) return 'unknown';
    return '${rows.first.values.first}'.toLowerCase();
  }
}
