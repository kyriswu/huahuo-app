import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'app_database.dart';
import 'database_worker_schema.dart';

final class DatabaseWorkerException implements Exception {
  const DatabaseWorkerException(this.code);

  final String code;

  @override
  String toString() => 'DatabaseWorkerException($code)';
}

final class DatabaseWorkerHealth {
  const DatabaseWorkerHealth({
    required this.enabled,
    required this.schemaVersion,
    required this.journalMode,
    required this.connectionGeneration,
    required this.workerIdentity,
    required this.commandsHandled,
    required this.preparedStatementCount,
    required this.indexes,
  });

  const DatabaseWorkerHealth.disabled()
    : enabled = false,
      schemaVersion = 0,
      journalMode = 'disabled',
      connectionGeneration = 0,
      workerIdentity = 0,
      commandsHandled = 0,
      preparedStatementCount = 0,
      indexes = const <String>[];

  final bool enabled;
  final int schemaVersion;
  final String journalMode;
  final int connectionGeneration;
  final int workerIdentity;
  final int commandsHandled;
  final int preparedStatementCount;
  final List<String> indexes;

  bool get isReady =>
      enabled &&
      schemaVersion == databaseWorkerSchemaVersion &&
      journalMode == 'wal' &&
      indexes.toSet().containsAll(DatabaseWorkerSchema.requiredIndexes);

  factory DatabaseWorkerHealth._fromMessage(Map<Object?, Object?> message) {
    return DatabaseWorkerHealth(
      enabled: message['enabled'] == true,
      schemaVersion: _messageInt(message['schemaVersion']),
      journalMode: '${message['journalMode']}',
      connectionGeneration: _messageInt(message['connectionGeneration']),
      workerIdentity: _messageInt(message['workerIdentity']),
      commandsHandled: _messageInt(message['commandsHandled']),
      preparedStatementCount: _messageInt(message['preparedStatementCount']),
      indexes: List<String>.unmodifiable(
        (message['indexes'] as List<Object?>? ?? const <Object?>[]).map(
          (value) => '$value',
        ),
      ),
    );
  }
}

enum ChatRunCheckpointKind {
  chat('chat'),
  derived('derived');

  const ChatRunCheckpointKind(this.wireName);

  final String wireName;

  static ChatRunCheckpointKind fromWireName(String value) => switch (value) {
    'chat' => ChatRunCheckpointKind.chat,
    'derived' => ChatRunCheckpointKind.derived,
    _ => throw const DatabaseWorkerException(
      'DATABASE_WORKER_INVALID_CHECKPOINT_KIND',
    ),
  };
}

enum ChatRunCheckpointRole {
  active('active'),
  ledger('ledger');

  const ChatRunCheckpointRole(this.wireName);

  final String wireName;

  static ChatRunCheckpointRole fromWireName(String value) => switch (value) {
    'active' => ChatRunCheckpointRole.active,
    'ledger' => ChatRunCheckpointRole.ledger,
    _ => throw const DatabaseWorkerException(
      'DATABASE_WORKER_INVALID_CHECKPOINT_ROLE',
    ),
  };
}

final class ChatRunCheckpoint {
  const ChatRunCheckpoint({
    required this.userScope,
    required this.runId,
    required this.kind,
    required this.status,
    required this.eventSequence,
    required this.createdAt,
    required this.updatedAt,
    this.role = ChatRunCheckpointRole.active,
    this.publicState = const <String, Object?>{},
    this.threadId,
    this.scene,
    this.purpose,
    this.localNoteId,
    this.targetPart,
    this.failureCode,
  });

  final String userScope;
  final String runId;
  final ChatRunCheckpointKind kind;
  final String status;
  final int eventSequence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ChatRunCheckpointRole role;
  final Map<String, Object?> publicState;
  final String? threadId;
  final String? scene;
  final String? purpose;
  final String? localNoteId;
  final String? targetPart;
  final String? failureCode;

  Map<String, Object?> _toMessage() => <String, Object?>{
    'userScope': userScope,
    'runId': runId,
    'kind': kind.wireName,
    'status': status,
    'eventSequence': eventSequence,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'role': role.wireName,
    'publicStateJson': jsonEncode(publicState),
    'threadId': threadId,
    'scene': scene,
    'purpose': purpose,
    'localNoteId': localNoteId,
    'targetPart': targetPart,
    'failureCode': failureCode,
  };

  factory ChatRunCheckpoint._fromMessage(Map<Object?, Object?> message) {
    return ChatRunCheckpoint(
      userScope: '${message['userScope']}',
      runId: '${message['runId']}',
      kind: ChatRunCheckpointKind.fromWireName('${message['kind']}'),
      status: '${message['status']}',
      eventSequence: _messageInt(message['eventSequence']),
      createdAt: DateTime.parse('${message['createdAt']}').toUtc(),
      updatedAt: DateTime.parse('${message['updatedAt']}').toUtc(),
      role: ChatRunCheckpointRole.fromWireName('${message['role']}'),
      publicState: Map<String, Object?>.unmodifiable(
        _decodeJsonMap('${message['publicStateJson']}'),
      ),
      threadId: _messageNullableString(message['threadId']),
      scene: _messageNullableString(message['scene']),
      purpose: _messageNullableString(message['purpose']),
      localNoteId: _messageNullableString(message['localNoteId']),
      targetPart: _messageNullableString(message['targetPart']),
      failureCode: _messageNullableString(message['failureCode']),
    );
  }
}

final class DatabaseOutboxEntry {
  const DatabaseOutboxEntry({
    required this.operationId,
    required this.userScope,
    required this.topic,
    required this.dedupeKey,
    required this.payload,
    required this.availableAt,
    required this.createdAt,
  });

  final String operationId;
  final String userScope;
  final String topic;
  final String dedupeKey;
  final Map<String, Object?> payload;
  final DateTime availableAt;
  final DateTime createdAt;
}

final class ClaimedDatabaseOutboxEntry {
  const ClaimedDatabaseOutboxEntry({
    required this.operationId,
    required this.userScope,
    required this.topic,
    required this.dedupeKey,
    required this.payload,
    required this.attemptCount,
    required this.leaseUntil,
    required this.createdAt,
  });

  final String operationId;
  final String userScope;
  final String topic;
  final String dedupeKey;
  final Map<String, Object?> payload;
  final int attemptCount;
  final DateTime leaseUntil;
  final DateTime createdAt;

  factory ClaimedDatabaseOutboxEntry._fromMessage(
    Map<Object?, Object?> message,
  ) {
    return ClaimedDatabaseOutboxEntry(
      operationId: '${message['operationId']}',
      userScope: '${message['userScope']}',
      topic: '${message['topic']}',
      dedupeKey: '${message['dedupeKey']}',
      payload: Map<String, Object?>.unmodifiable(
        _decodeJsonMap('${message['payloadJson']}'),
      ),
      attemptCount: _messageInt(message['attemptCount']),
      leaseUntil: DateTime.parse('${message['leaseUntil']}').toUtc(),
      createdAt: DateTime.parse('${message['createdAt']}').toUtc(),
    );
  }
}

enum DatabaseInboxDisposition {
  accepted,
  resume,
  alreadyProcessed;

  static DatabaseInboxDisposition fromWireName(String value) => switch (value) {
    'accepted' => DatabaseInboxDisposition.accepted,
    'resume' => DatabaseInboxDisposition.resume,
    'already_processed' => DatabaseInboxDisposition.alreadyProcessed,
    _ => throw const DatabaseWorkerException(
      'DATABASE_WORKER_INVALID_INBOX_DISPOSITION',
    ),
  };
}

abstract interface class DatabaseSyncJournalPort {
  bool get isEnabled;
  bool get isDisposed;

  Future<bool> enqueueOutbox(DatabaseOutboxEntry entry);

  Future<List<ClaimedDatabaseOutboxEntry>> claimOutbox({
    required String userScope,
    required DateTime now,
    Duration leaseDuration = const Duration(minutes: 2),
    int limit = 20,
    String? topic,
    String? operationId,
  });

  Future<bool> markOutboxSucceeded({
    required String operationId,
    required DateTime updatedAt,
  });

  Future<bool> markOutboxRetry({
    required String operationId,
    required DateTime availableAt,
    required DateTime updatedAt,
    required String errorCode,
  });

  Future<DatabaseInboxDisposition> beginInbox({
    required String userScope,
    required String eventId,
    required String topic,
    required DateTime receivedAt,
  });

  Future<bool> markInboxProcessed({
    required String userScope,
    required String eventId,
    required DateTime processedAt,
  });
}

abstract interface class DatabaseRecordWorkerPort {
  bool get isEnabled;
  bool get isDisposed;

  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  });

  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  });

  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  });

  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table);
}

abstract interface class ChatRunCheckpointWorkerPort {
  bool get isEnabled;
  bool get isDisposed;

  Future<void> upsertChatRunCheckpoint(ChatRunCheckpoint checkpoint);

  Future<bool> deleteChatRunCheckpoint({
    required String userScope,
    required String runId,
  });

  Future<void> applyChatRunCheckpointChanges({
    required String userScope,
    required Iterable<ChatRunCheckpoint> upserts,
    required Iterable<String> deletions,
  });

  Future<List<ChatRunCheckpoint>> listChatRunCheckpoints(String userScope);
}

final class DatabaseWorker
    implements
        DatabaseRecordWorkerPort,
        ChatRunCheckpointWorkerPort,
        DatabaseSyncJournalPort,
        LocalDatabaseWriteWorkerPort {
  DatabaseWorker._disabled({required Duration requestTimeout})
    : _enabled = false,
      // Private constructor keeps the public startup name unprefixed.
      // ignore: prefer_initializing_formals
      _requestTimeout = requestTimeout,
      _isolate = null,
      _commands = null,
      _exitFuture = null;

  DatabaseWorker._enabled({
    required Isolate isolate,
    required SendPort commands,
    required Future<void> exitFuture,
    required Duration requestTimeout,
  }) : _enabled = true,
       // Private constructor keeps public startup names unprefixed.
       // ignore: prefer_initializing_formals
       _requestTimeout = requestTimeout,
       // ignore: prefer_initializing_formals
       _isolate = isolate,
       // ignore: prefer_initializing_formals
       _commands = commands,
       // ignore: prefer_initializing_formals
       _exitFuture = exitFuture;

  final bool _enabled;
  final Duration _requestTimeout;
  final Isolate? _isolate;
  final SendPort? _commands;
  final Future<void>? _exitFuture;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  bool get isEnabled => _enabled;

  @override
  bool get isDisposed => _disposed;

  static Future<DatabaseWorker> start({
    required File file,
    bool enabled = true,
    Duration requestTimeout = const Duration(seconds: 8),
    Duration busyTimeout = const Duration(seconds: 5),
  }) async {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be positive',
      );
    }
    if (busyTimeout.isNegative) {
      throw ArgumentError.value(
        busyTimeout,
        'busyTimeout',
        'must not be negative',
      );
    }
    if (!enabled) {
      return DatabaseWorker._disabled(requestTimeout: requestTimeout);
    }

    final startup = ReceivePort();
    final exit = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<List<Object?>>(
        _databaseWorkerMain,
        <Object?>[startup.sendPort, file.path, busyTimeout.inMilliseconds],
        onExit: exit.sendPort,
        debugName: 'huahuo-database-worker',
      );
      final startupMessage = await startup.first.timeout(requestTimeout);
      if (startupMessage is! Map<Object?, Object?> ||
          startupMessage['ok'] != true ||
          startupMessage['commands'] is! SendPort) {
        final code = startupMessage is Map<Object?, Object?>
            ? '${startupMessage['errorCode']}'
            : 'DATABASE_WORKER_START_FAILED';
        isolate.kill(priority: Isolate.immediate);
        throw DatabaseWorkerException(code);
      }
      final exitFuture = exit.first.then<void>((_) {}).whenComplete(exit.close);
      return DatabaseWorker._enabled(
        isolate: isolate,
        commands: startupMessage['commands']! as SendPort,
        exitFuture: exitFuture,
        requestTimeout: requestTimeout,
      );
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      exit.close();
      rethrow;
    } finally {
      startup.close();
    }
  }

  Future<DatabaseWorkerHealth> health() async {
    if (!_enabled) return const DatabaseWorkerHealth.disabled();
    final value = await _request(_WorkerCommand.health);
    return DatabaseWorkerHealth._fromMessage(_messageMap(value));
  }

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) {
    return upsertRecordBatch(
      table: table,
      records: <String, LocalDatabaseRecord>{key: record},
    );
  }

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async {
    if (records.isEmpty) return;
    final encoded = <Map<String, Object?>>[];
    for (final entry in records.entries) {
      _validateRecordKey(entry.key);
      validateLocalDatabaseRecord(entry.value);
      encoded.add(<String, Object?>{
        'key': entry.key,
        'recordJson': jsonEncode(entry.value),
      });
    }
    await _request(_WorkerCommand.upsertRecordBatch, <String, Object?>{
      'table': table.dbName,
      'records': encoded,
    });
  }

  @override
  Future<void> applyRecordMutations({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
  }) {
    return _sendRecordMutations(
      schemaVersion: schemaVersion,
      mutations: mutations,
      replaceAll: false,
    );
  }

  @override
  Future<void> replaceAllRecords({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    return _sendRecordMutations(
      schemaVersion: schemaVersion,
      mutations: <LocalDatabaseMutation>[
        for (final table in tables.entries)
          for (final record in table.value.entries)
            LocalDatabaseMutation.upsert(
              table: table.key,
              key: record.key,
              value: record.value,
            ),
      ],
      replaceAll: true,
    );
  }

  Future<void> _sendRecordMutations({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
    required bool replaceAll,
  }) async {
    if (schemaVersion < 1 || schemaVersion > localDatabaseSchemaVersion) {
      throw ArgumentError.value(schemaVersion, 'schemaVersion');
    }
    final encoded = <Map<String, Object?>>[];
    for (final mutation in mutations) {
      _validateRecordKey(mutation.key);
      final value = mutation.value;
      if (mutation.kind == LocalDatabaseMutationKind.upsert) {
        if (value == null) {
          throw ArgumentError.value(value, 'mutation.value');
        }
        validateLocalDatabaseRecord(value);
      }
      encoded.add(<String, Object?>{
        'kind': mutation.kind.name,
        'table': mutation.table.dbName,
        'key': mutation.key,
        if (value != null) 'recordJson': jsonEncode(value),
      });
    }
    if (encoded.isEmpty && !replaceAll) return;
    await _request(_WorkerCommand.applyRecordMutations, <String, Object?>{
      'schemaVersion': schemaVersion,
      'replaceAll': replaceAll,
      'mutations': encoded,
    });
  }

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async {
    _validateRecordKey(key);
    final value = await _request(_WorkerCommand.deleteRecord, <String, Object?>{
      'table': table.dbName,
      'key': key,
    });
    return value == true;
  }

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async {
    final value = await _request(_WorkerCommand.listRecords, <String, Object?>{
      'table': table.dbName,
    });
    final rows = value as List<Object?>? ?? const <Object?>[];
    return List<LocalDatabaseRecord>.unmodifiable(
      rows.map((row) {
        final message = _messageMap(row);
        return Map<String, Object?>.unmodifiable(
          _decodeJsonMap('${message['recordJson']}'),
        );
      }),
    );
  }

  @override
  Future<void> upsertChatRunCheckpoint(ChatRunCheckpoint checkpoint) async {
    _validateCheckpoint(checkpoint);
    await _request(
      _WorkerCommand.upsertChatRunCheckpoint,
      checkpoint._toMessage(),
    );
  }

  @override
  Future<bool> deleteChatRunCheckpoint({
    required String userScope,
    required String runId,
  }) async {
    _validateIdentifier(userScope, 'userScope');
    _validateIdentifier(runId, 'runId', maxLength: 240);
    final value = await _request(
      _WorkerCommand.deleteChatRunCheckpoint,
      <String, Object?>{'userScope': userScope, 'runId': runId},
    );
    return value == true;
  }

  @override
  Future<void> applyChatRunCheckpointChanges({
    required String userScope,
    required Iterable<ChatRunCheckpoint> upserts,
    required Iterable<String> deletions,
  }) async {
    _validateIdentifier(userScope, 'userScope');
    final encodedUpserts = <Map<String, Object?>>[];
    for (final checkpoint in upserts) {
      _validateCheckpoint(checkpoint);
      if (checkpoint.userScope != userScope) {
        throw ArgumentError.value(
          checkpoint.userScope,
          'checkpoint.userScope',
          'must match userScope',
        );
      }
      encodedUpserts.add(checkpoint._toMessage());
    }
    final encodedDeletions = <String>[];
    for (final runId in deletions) {
      _validateIdentifier(runId, 'runId', maxLength: 240);
      encodedDeletions.add(runId);
    }
    if (encodedUpserts.isEmpty && encodedDeletions.isEmpty) return;
    await _request(
      _WorkerCommand.applyChatRunCheckpointChanges,
      <String, Object?>{
        'userScope': userScope,
        'upserts': encodedUpserts,
        'deletions': encodedDeletions,
      },
    );
  }

  @override
  Future<List<ChatRunCheckpoint>> listChatRunCheckpoints(
    String userScope,
  ) async {
    _validateIdentifier(userScope, 'userScope');
    final value = await _request(
      _WorkerCommand.listChatRunCheckpoints,
      <String, Object?>{'userScope': userScope},
    );
    return List<ChatRunCheckpoint>.unmodifiable(
      (value as List<Object?>? ?? const <Object?>[]).map(
        (item) => ChatRunCheckpoint._fromMessage(_messageMap(item)),
      ),
    );
  }

  @override
  Future<bool> enqueueOutbox(DatabaseOutboxEntry entry) async {
    _validateIdentifier(entry.operationId, 'operationId', maxLength: 240);
    _validateIdentifier(entry.userScope, 'userScope');
    _validateIdentifier(entry.topic, 'topic');
    _validateIdentifier(entry.dedupeKey, 'dedupeKey', maxLength: 240);
    final payloadJson = jsonEncode(entry.payload);
    if (utf8.encode(payloadJson).length > 512 * 1024) {
      throw ArgumentError('payload must encode to at most 512 KiB');
    }
    final value =
        await _request(_WorkerCommand.enqueueOutbox, <String, Object?>{
          'operationId': entry.operationId,
          'userScope': entry.userScope,
          'topic': entry.topic,
          'dedupeKey': entry.dedupeKey,
          'payloadJson': payloadJson,
          'availableAt': entry.availableAt.toUtc().toIso8601String(),
          'createdAt': entry.createdAt.toUtc().toIso8601String(),
        });
    return value == true;
  }

  @override
  Future<List<ClaimedDatabaseOutboxEntry>> claimOutbox({
    required String userScope,
    required DateTime now,
    Duration leaseDuration = const Duration(minutes: 2),
    int limit = 20,
    String? topic,
    String? operationId,
  }) async {
    _validateIdentifier(userScope, 'userScope');
    _validateOptionalIdentifier(topic, 'topic');
    _validateOptionalIdentifier(operationId, 'operationId', maxLength: 240);
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(
        leaseDuration,
        'leaseDuration',
        'must be positive',
      );
    }
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'must be 1-100');
    }
    final utcNow = now.toUtc();
    final leaseUntil = utcNow.add(leaseDuration);
    final value = await _request(_WorkerCommand.claimOutbox, <String, Object?>{
      'userScope': userScope,
      'now': utcNow.toIso8601String(),
      'leaseUntil': leaseUntil.toIso8601String(),
      'limit': limit,
      'topic': topic,
      'operationId': operationId,
    });
    return List<ClaimedDatabaseOutboxEntry>.unmodifiable(
      (value as List<Object?>? ?? const <Object?>[]).map(
        (item) => ClaimedDatabaseOutboxEntry._fromMessage(_messageMap(item)),
      ),
    );
  }

  @override
  Future<bool> markOutboxSucceeded({
    required String operationId,
    required DateTime updatedAt,
  }) async {
    _validateIdentifier(operationId, 'operationId', maxLength: 240);
    final value = await _request(
      _WorkerCommand.markOutboxSucceeded,
      <String, Object?>{
        'operationId': operationId,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      },
    );
    return value == true;
  }

  @override
  Future<bool> markOutboxRetry({
    required String operationId,
    required DateTime availableAt,
    required DateTime updatedAt,
    required String errorCode,
  }) async {
    _validateIdentifier(operationId, 'operationId', maxLength: 240);
    _validateIdentifier(errorCode, 'errorCode');
    final value =
        await _request(_WorkerCommand.markOutboxRetry, <String, Object?>{
          'operationId': operationId,
          'availableAt': availableAt.toUtc().toIso8601String(),
          'updatedAt': updatedAt.toUtc().toIso8601String(),
          'errorCode': errorCode,
        });
    return value == true;
  }

  Future<bool> acceptInbox({
    required String userScope,
    required String eventId,
    required String topic,
    required DateTime receivedAt,
  }) async {
    _validateIdentifier(userScope, 'userScope');
    _validateIdentifier(eventId, 'eventId', maxLength: 240);
    _validateIdentifier(topic, 'topic');
    return await beginInbox(
          userScope: userScope,
          eventId: eventId,
          topic: topic,
          receivedAt: receivedAt,
        ) ==
        DatabaseInboxDisposition.accepted;
  }

  @override
  Future<DatabaseInboxDisposition> beginInbox({
    required String userScope,
    required String eventId,
    required String topic,
    required DateTime receivedAt,
  }) async {
    _validateIdentifier(userScope, 'userScope');
    _validateIdentifier(eventId, 'eventId', maxLength: 240);
    _validateIdentifier(topic, 'topic');
    final value = await _request(_WorkerCommand.beginInbox, <String, Object?>{
      'userScope': userScope,
      'eventId': eventId,
      'topic': topic,
      'receivedAt': receivedAt.toUtc().toIso8601String(),
    });
    return DatabaseInboxDisposition.fromWireName('$value');
  }

  @override
  Future<bool> markInboxProcessed({
    required String userScope,
    required String eventId,
    required DateTime processedAt,
  }) async {
    _validateIdentifier(userScope, 'userScope');
    _validateIdentifier(eventId, 'eventId', maxLength: 240);
    final value =
        await _request(_WorkerCommand.markInboxProcessed, <String, Object?>{
          'userScope': userScope,
          'eventId': eventId,
          'processedAt': processedAt.toUtc().toIso8601String(),
        });
    return value == true;
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    final future = _dispose();
    _disposeFuture = future;
    return future;
  }

  Future<void> _dispose() async {
    if (!_enabled) {
      _disposed = true;
      return;
    }
    try {
      await _requestRaw(_WorkerCommand.close, const <String, Object?>{});
      await _exitFuture!.timeout(_requestTimeout);
      _disposed = true;
    } on TimeoutException {
      _isolate?.kill(priority: Isolate.immediate);
      _disposed = true;
      throw const DatabaseWorkerException('DATABASE_WORKER_CLOSE_TIMEOUT');
    } catch (_) {
      _isolate?.kill(priority: Isolate.immediate);
      _disposed = true;
      rethrow;
    }
  }

  Future<Object?> _request(
    _WorkerCommand command, [
    Map<String, Object?> payload = const <String, Object?>{},
  ]) {
    if (!_enabled) {
      return Future<Object?>.error(
        const DatabaseWorkerException('DATABASE_WORKER_DISABLED'),
      );
    }
    if (_disposeFuture != null || _disposed) {
      return Future<Object?>.error(
        const DatabaseWorkerException('DATABASE_WORKER_CLOSED'),
      );
    }
    return _requestRaw(command, payload);
  }

  Future<Object?> _requestRaw(
    _WorkerCommand command,
    Map<String, Object?> payload,
  ) async {
    final response = ReceivePort();
    try {
      _commands!.send(<String, Object?>{
        'command': command.name,
        'payload': payload,
        'replyTo': response.sendPort,
      });
      final message = await response.first.timeout(_requestTimeout);
      final envelope = _messageMap(message);
      if (envelope['ok'] != true) {
        throw DatabaseWorkerException(
          '${envelope['errorCode'] ?? 'DATABASE_WORKER_OPERATION_FAILED'}',
        );
      }
      return envelope['value'];
    } on TimeoutException {
      throw const DatabaseWorkerException('DATABASE_WORKER_REQUEST_TIMEOUT');
    } finally {
      response.close();
    }
  }
}

enum _WorkerCommand {
  health,
  upsertRecordBatch,
  applyRecordMutations,
  deleteRecord,
  listRecords,
  upsertChatRunCheckpoint,
  deleteChatRunCheckpoint,
  applyChatRunCheckpointChanges,
  listChatRunCheckpoints,
  enqueueOutbox,
  claimOutbox,
  markOutboxSucceeded,
  markOutboxRetry,
  acceptInbox,
  beginInbox,
  markInboxProcessed,
  close;

  static _WorkerCommand? parse(Object? value) {
    for (final command in values) {
      if (command.name == value) return command;
    }
    return null;
  }
}

Future<void> _databaseWorkerMain(List<Object?> bootstrap) async {
  final startup = bootstrap[0]! as SendPort;
  final path = '${bootstrap[1]}';
  final busyTimeoutMilliseconds = _messageInt(bootstrap[2]);
  sqlite.Database? database;
  _WorkerStatements? statements;
  ReceivePort? commands;
  try {
    File(path).parent.createSync(recursive: true);
    database = sqlite.sqlite3.open(path);
    DatabaseWorkerSchema.migrate(
      database,
      busyTimeoutMilliseconds: busyTimeoutMilliseconds,
    );
    statements = _WorkerStatements(database);
    commands = ReceivePort();
    startup.send(<String, Object?>{'ok': true, 'commands': commands.sendPort});
  } catch (error) {
    statements?.close();
    database?.close();
    commands?.close();
    startup.send(<String, Object?>{
      'ok': false,
      'errorCode': _safeWorkerErrorCode(error),
    });
    return;
  }

  final state = _WorkerState(database, statements);
  await for (final raw in commands) {
    final request = raw is Map<Object?, Object?>
        ? raw
        : const <Object?, Object?>{};
    final replyTo = request['replyTo'];
    if (replyTo is! SendPort) continue;
    final command = _WorkerCommand.parse(request['command']);
    final payload = request['payload'] is Map<Object?, Object?>
        ? request['payload']! as Map<Object?, Object?>
        : const <Object?, Object?>{};
    if (command == null) {
      replyTo.send(const <String, Object?>{
        'ok': false,
        'errorCode': 'DATABASE_WORKER_UNKNOWN_COMMAND',
      });
      continue;
    }
    try {
      state.commandsHandled += 1;
      final value = state.handle(command, payload);
      replyTo.send(<String, Object?>{'ok': true, 'value': value});
      if (command == _WorkerCommand.close) break;
    } catch (error) {
      replyTo.send(<String, Object?>{
        'ok': false,
        'errorCode': _safeWorkerErrorCode(error),
      });
    }
  }
  commands.close();
  statements.close();
  database.close();
}

final class _WorkerState {
  _WorkerState(this.database, this.statements)
    : connectionGeneration = DateTime.now().microsecondsSinceEpoch,
      workerIdentity = Isolate.current.hashCode;

  final sqlite.Database database;
  final _WorkerStatements statements;
  final int connectionGeneration;
  final int workerIdentity;
  int commandsHandled = 0;

  Object? handle(_WorkerCommand command, Map<Object?, Object?> payload) {
    switch (command) {
      case _WorkerCommand.health:
        return _health();
      case _WorkerCommand.upsertRecordBatch:
        _upsertRecordBatch(payload);
        return null;
      case _WorkerCommand.applyRecordMutations:
        _applyRecordMutations(payload);
        return null;
      case _WorkerCommand.deleteRecord:
        return _deleteRecord(payload);
      case _WorkerCommand.listRecords:
        return _listRecords(payload);
      case _WorkerCommand.upsertChatRunCheckpoint:
        _upsertCheckpoint(payload);
        return null;
      case _WorkerCommand.deleteChatRunCheckpoint:
        return _deleteCheckpoint(payload);
      case _WorkerCommand.applyChatRunCheckpointChanges:
        _applyCheckpointChanges(payload);
        return null;
      case _WorkerCommand.listChatRunCheckpoints:
        return _listCheckpoints(payload);
      case _WorkerCommand.enqueueOutbox:
        return _enqueueOutbox(payload);
      case _WorkerCommand.claimOutbox:
        return _claimOutbox(payload);
      case _WorkerCommand.markOutboxSucceeded:
        return _markOutboxSucceeded(payload);
      case _WorkerCommand.markOutboxRetry:
        return _markOutboxRetry(payload);
      case _WorkerCommand.acceptInbox:
        return _acceptInbox(payload);
      case _WorkerCommand.beginInbox:
        return _beginInbox(payload);
      case _WorkerCommand.markInboxProcessed:
        return _markInboxProcessed(payload);
      case _WorkerCommand.close:
        return null;
    }
  }

  Map<String, Object?> _health() {
    final schema = DatabaseWorkerSchema.inspect(database);
    return <String, Object?>{
      'enabled': true,
      'schemaVersion': schema.schemaVersion,
      'journalMode': schema.journalMode,
      'connectionGeneration': connectionGeneration,
      'workerIdentity': workerIdentity,
      'commandsHandled': commandsHandled,
      'preparedStatementCount': statements.count,
      'indexes': schema.indexes.toList(growable: false)..sort(),
    };
  }

  void _upsertRecordBatch(Map<Object?, Object?> payload) {
    final table = _workerString(payload['table'], 'table', maxLength: 96);
    final rawRecords = payload['records'];
    if (rawRecords is! List<Object?> || rawRecords.isEmpty) {
      throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_RECORDS');
    }
    _transaction(() {
      statements.metadataUpsert.execute(<Object?>[
        'schemaVersion',
        localDatabaseSchemaVersion.toString(),
      ]);
      for (final raw in rawRecords) {
        final recordMessage = _messageMap(raw);
        final key = _workerRecordKey(recordMessage['key']);
        final recordJson = '${recordMessage['recordJson']}';
        final record = _decodeJsonMap(recordJson);
        validateLocalDatabaseRecord(record);
        statements.localRecordUpsert.execute(<Object?>[
          table,
          key,
          jsonEncode(record),
        ]);
      }
    });
  }

  void _applyRecordMutations(Map<Object?, Object?> payload) {
    final schemaVersion = _messageInt(payload['schemaVersion']);
    if (schemaVersion < 1 || schemaVersion > localDatabaseSchemaVersion) {
      throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_APP_SCHEMA');
    }
    final replaceAll = payload['replaceAll'] == true;
    final rawMutations = payload['mutations'];
    if (rawMutations is! List<Object?> || rawMutations.isEmpty && !replaceAll) {
      throw const DatabaseWorkerException(
        'DATABASE_WORKER_INVALID_RECORD_MUTATIONS',
      );
    }
    final mutations = <LocalDatabaseMutation>[];
    for (final raw in rawMutations) {
      final message = _messageMap(raw);
      final kind = switch (message['kind']) {
        'upsert' => LocalDatabaseMutationKind.upsert,
        'delete' => LocalDatabaseMutationKind.delete,
        _ => throw const DatabaseWorkerException(
          'DATABASE_WORKER_INVALID_RECORD_MUTATION_KIND',
        ),
      };
      final table = _workerTable(message['table']);
      final key = _workerRecordKey(message['key']);
      if (kind == LocalDatabaseMutationKind.delete) {
        mutations.add(LocalDatabaseMutation.delete(table: table, key: key));
        continue;
      }
      final record = _decodeJsonMap('${message['recordJson']}');
      validateLocalDatabaseRecord(record);
      mutations.add(
        LocalDatabaseMutation.upsert(table: table, key: key, value: record),
      );
    }
    _transaction(() {
      if (replaceAll) database.execute('DELETE FROM local_records');
      statements.metadataUpsert.execute(<Object?>[
        'schemaVersion',
        schemaVersion.toString(),
      ]);
      for (final mutation in mutations) {
        switch (mutation.kind) {
          case LocalDatabaseMutationKind.upsert:
            statements.localRecordUpsert.execute(<Object?>[
              mutation.table.dbName,
              mutation.key,
              jsonEncode(mutation.value),
            ]);
          case LocalDatabaseMutationKind.delete:
            statements.localRecordDelete.execute(<Object?>[
              mutation.table.dbName,
              mutation.key,
            ]);
        }
      }
    });
  }

  bool _deleteRecord(Map<Object?, Object?> payload) {
    final table = _workerString(payload['table'], 'table', maxLength: 96);
    final key = _workerRecordKey(payload['key']);
    return _transaction(() {
      statements.metadataUpsert.execute(<Object?>[
        'schemaVersion',
        localDatabaseSchemaVersion.toString(),
      ]);
      statements.localRecordDelete.execute(<Object?>[table, key]);
      return _changedRows(database) > 0;
    });
  }

  List<Map<String, Object?>> _listRecords(Map<Object?, Object?> payload) {
    final table = _workerString(payload['table'], 'table', maxLength: 96);
    return statements.localRecordList
        .select(<Object?>[table])
        .map((row) => <String, Object?>{'recordJson': '${row['payload_json']}'})
        .toList(growable: false);
  }

  void _upsertCheckpoint(Map<Object?, Object?> payload) {
    final checkpoint = _workerCheckpoint(payload);
    _writeCheckpoint(checkpoint);
  }

  void _writeCheckpoint(ChatRunCheckpoint checkpoint) {
    statements.checkpointUpsert.execute(<Object?>[
      checkpoint.userScope,
      checkpoint.runId,
      checkpoint.kind.wireName,
      checkpoint.status,
      checkpoint.eventSequence,
      checkpoint.threadId,
      checkpoint.scene,
      checkpoint.purpose,
      checkpoint.localNoteId,
      checkpoint.targetPart,
      checkpoint.failureCode,
      checkpoint.createdAt.toIso8601String(),
      checkpoint.updatedAt.toIso8601String(),
      checkpoint.role.wireName,
      jsonEncode(checkpoint.publicState),
    ]);
  }

  void _applyCheckpointChanges(Map<Object?, Object?> payload) {
    final userScope = _workerIdentifier(payload['userScope'], 'userScope');
    final rawUpserts = payload['upserts'];
    final rawDeletions = payload['deletions'];
    if (rawUpserts is! List<Object?> || rawDeletions is! List<Object?>) {
      throw const DatabaseWorkerException(
        'DATABASE_WORKER_INVALID_CHECKPOINT_CHANGES',
      );
    }
    final upserts = <ChatRunCheckpoint>[];
    for (final raw in rawUpserts) {
      final checkpoint = _workerCheckpoint(_messageMap(raw));
      if (checkpoint.userScope != userScope) {
        throw const DatabaseWorkerException(
          'DATABASE_WORKER_CHECKPOINT_SCOPE_MISMATCH',
        );
      }
      upserts.add(checkpoint);
    }
    final deletions = <String>[
      for (final raw in rawDeletions)
        _workerIdentifier(raw, 'runId', maxLength: 240),
    ];
    _transaction(() {
      for (final checkpoint in upserts) {
        _writeCheckpoint(checkpoint);
      }
      for (final runId in deletions) {
        statements.checkpointDelete.execute(<Object?>[userScope, runId]);
      }
    });
  }

  bool _deleteCheckpoint(Map<Object?, Object?> payload) {
    final userScope = _workerIdentifier(payload['userScope'], 'userScope');
    final runId = _workerIdentifier(payload['runId'], 'runId', maxLength: 240);
    statements.checkpointDelete.execute(<Object?>[userScope, runId]);
    return _changedRows(database) > 0;
  }

  List<Map<String, Object?>> _listCheckpoints(Map<Object?, Object?> payload) {
    final userScope = _workerIdentifier(payload['userScope'], 'userScope');
    return statements.checkpointList
        .select(<Object?>[userScope])
        .map(_checkpointRowMessage)
        .toList(growable: false);
  }

  bool _enqueueOutbox(Map<Object?, Object?> payload) {
    final operationId = _workerIdentifier(
      payload['operationId'],
      'operationId',
      maxLength: 240,
    );
    final userScope = _workerIdentifier(payload['userScope'], 'userScope');
    final topic = _workerIdentifier(payload['topic'], 'topic');
    final dedupeKey = _workerIdentifier(
      payload['dedupeKey'],
      'dedupeKey',
      maxLength: 240,
    );
    final payloadJson = _workerPayloadJson(payload['payloadJson']);
    final availableAt = _workerTimestamp(payload['availableAt'], 'availableAt');
    final createdAt = _workerTimestamp(payload['createdAt'], 'createdAt');
    return _transaction(() {
      statements.outboxInsert.execute(<Object?>[
        operationId,
        userScope,
        topic,
        dedupeKey,
        'pending',
        0,
        availableAt,
        createdAt,
        createdAt,
      ]);
      final inserted = _changedRows(database) > 0;
      if (!inserted) return false;
      statements.outboxPayloadInsert.execute(<Object?>[
        operationId,
        payloadJson,
      ]);
      return true;
    });
  }

  List<Map<String, Object?>> _claimOutbox(Map<Object?, Object?> payload) {
    final userScope = _workerIdentifier(payload['userScope'], 'userScope');
    final topic = _workerOptionalIdentifier(payload['topic'], 'topic');
    final operationId = _workerOptionalIdentifier(
      payload['operationId'],
      'operationId',
      maxLength: 240,
    );
    final now = _workerTimestamp(payload['now'], 'now');
    final leaseUntil = _workerTimestamp(payload['leaseUntil'], 'leaseUntil');
    final limit = _messageInt(payload['limit']);
    if (limit < 1 || limit > 100) {
      throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_LIMIT');
    }
    return _transaction(() {
      final rows = statements.outboxClaimCandidates.select(<Object?>[
        userScope,
        topic,
        topic,
        operationId,
        operationId,
        now,
        now,
        limit,
      ]);
      final claimed = <Map<String, Object?>>[];
      for (final row in rows) {
        final operationId = '${row['operation_id']}';
        statements.outboxClaim.execute(<Object?>[
          leaseUntil,
          now,
          operationId,
          userScope,
        ]);
        if (_changedRows(database) == 0) continue;
        claimed.add(<String, Object?>{
          'operationId': operationId,
          'userScope': '${row['user_scope']}',
          'topic': '${row['topic']}',
          'dedupeKey': '${row['dedupe_key']}',
          'payloadJson': '${row['payload_json']}',
          'attemptCount': _messageInt(row['attempt_count']) + 1,
          'leaseUntil': leaseUntil,
          'createdAt': '${row['created_at']}',
        });
      }
      return claimed;
    });
  }

  bool _markOutboxSucceeded(Map<Object?, Object?> payload) {
    final operationId = _workerIdentifier(
      payload['operationId'],
      'operationId',
      maxLength: 240,
    );
    final updatedAt = _workerTimestamp(payload['updatedAt'], 'updatedAt');
    return _transaction(() {
      statements.outboxSucceed.execute(<Object?>[updatedAt, operationId]);
      final updated = _changedRows(database) > 0;
      if (updated) {
        statements.outboxPayloadDelete.execute(<Object?>[operationId]);
      }
      return updated;
    });
  }

  bool _markOutboxRetry(Map<Object?, Object?> payload) {
    final operationId = _workerIdentifier(
      payload['operationId'],
      'operationId',
      maxLength: 240,
    );
    final availableAt = _workerTimestamp(payload['availableAt'], 'availableAt');
    final updatedAt = _workerTimestamp(payload['updatedAt'], 'updatedAt');
    final errorCode = _workerIdentifier(payload['errorCode'], 'errorCode');
    statements.outboxRetry.execute(<Object?>[
      availableAt,
      errorCode,
      updatedAt,
      operationId,
    ]);
    return _changedRows(database) > 0;
  }

  bool _acceptInbox(Map<Object?, Object?> payload) {
    return _beginInbox(payload) == 'accepted';
  }

  String _beginInbox(Map<Object?, Object?> payload) {
    final userScope = _workerIdentifier(payload['userScope'], 'userScope');
    final eventId = _workerIdentifier(
      payload['eventId'],
      'eventId',
      maxLength: 240,
    );
    final topic = _workerIdentifier(payload['topic'], 'topic');
    final receivedAt = _workerTimestamp(payload['receivedAt'], 'receivedAt');
    statements.inboxInsert.execute(<Object?>[
      userScope,
      eventId,
      topic,
      receivedAt,
    ]);
    if (_changedRows(database) > 0) return 'accepted';
    final rows = statements.inboxStatus.select(<Object?>[userScope, eventId]);
    if (rows.isEmpty || '${rows.single['topic']}' != topic) {
      throw const DatabaseWorkerException('DATABASE_WORKER_INBOX_CONFLICT');
    }
    return rows.single['processed_at'] == null ? 'resume' : 'already_processed';
  }

  bool _markInboxProcessed(Map<Object?, Object?> payload) {
    final userScope = _workerIdentifier(payload['userScope'], 'userScope');
    final eventId = _workerIdentifier(
      payload['eventId'],
      'eventId',
      maxLength: 240,
    );
    final processedAt = _workerTimestamp(payload['processedAt'], 'processedAt');
    statements.inboxProcess.execute(<Object?>[processedAt, userScope, eventId]);
    return _changedRows(database) > 0;
  }

  T _transaction<T>(T Function() action) {
    database.execute('BEGIN IMMEDIATE');
    try {
      final value = action();
      database.execute('COMMIT');
      return value;
    } catch (_) {
      try {
        database.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }
}

final class _WorkerStatements {
  _WorkerStatements(sqlite.Database database)
    : metadataUpsert = database.prepare(
        'INSERT INTO local_metadata(key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      ),
      localRecordUpsert = database.prepare(
        'INSERT INTO local_records(table_name, record_key, payload_json) '
        'VALUES (?, ?, ?) ON CONFLICT(table_name, record_key) '
        'DO UPDATE SET payload_json = excluded.payload_json',
      ),
      localRecordDelete = database.prepare(
        'DELETE FROM local_records WHERE table_name = ? AND record_key = ?',
      ),
      localRecordList = database.prepare(
        'SELECT payload_json FROM local_records WHERE table_name = ? '
        'ORDER BY record_key',
      ),
      checkpointUpsert = database.prepare(
        'INSERT INTO chat_run_checkpoints('
        'user_scope, run_id, kind, status, event_sequence, thread_id, scene, '
        'purpose, local_note_id, target_part, failure_code, created_at, updated_at'
        ', checkpoint_role, public_state_json'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(user_scope, run_id) DO UPDATE SET '
        'kind = excluded.kind, status = excluded.status, '
        'event_sequence = excluded.event_sequence, thread_id = excluded.thread_id, '
        'scene = excluded.scene, purpose = excluded.purpose, '
        'local_note_id = excluded.local_note_id, '
        'target_part = excluded.target_part, failure_code = excluded.failure_code, '
        'updated_at = excluded.updated_at, '
        'checkpoint_role = excluded.checkpoint_role, '
        'public_state_json = excluded.public_state_json',
      ),
      checkpointDelete = database.prepare(
        'DELETE FROM chat_run_checkpoints WHERE user_scope = ? AND run_id = ?',
      ),
      checkpointList = database.prepare(
        'SELECT * FROM chat_run_checkpoints WHERE user_scope = ? '
        'ORDER BY updated_at DESC, run_id',
      ),
      outboxInsert = database.prepare(
        'INSERT OR IGNORE INTO sync_outbox('
        'operation_id, user_scope, topic, dedupe_key, state, attempt_count, '
        'available_at, created_at, updated_at'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ),
      outboxPayloadInsert = database.prepare(
        'INSERT INTO sync_outbox_payloads(operation_id, payload_json) '
        'VALUES (?, ?)',
      ),
      outboxClaimCandidates = database.prepare(
        'SELECT o.*, p.payload_json FROM sync_outbox o '
        'JOIN sync_outbox_payloads p ON p.operation_id = o.operation_id '
        'WHERE o.user_scope = ? AND (? IS NULL OR o.topic = ?) '
        'AND (? IS NULL OR o.operation_id = ?) AND ('
        "(o.state IN ('pending', 'retry') AND o.available_at <= ?) OR "
        "(o.state = 'in_flight' AND o.lease_until <= ?)"
        ') ORDER BY o.created_at, o.operation_id LIMIT ?',
      ),
      outboxClaim = database.prepare(
        "UPDATE sync_outbox SET state = 'in_flight', "
        'attempt_count = attempt_count + 1, lease_until = ?, updated_at = ? '
        'WHERE operation_id = ? AND user_scope = ?',
      ),
      outboxSucceed = database.prepare(
        "UPDATE sync_outbox SET state = 'completed', lease_until = NULL, "
        'last_error_code = NULL, updated_at = ? WHERE operation_id = ? '
        "AND state = 'in_flight'",
      ),
      outboxRetry = database.prepare(
        "UPDATE sync_outbox SET state = 'retry', available_at = ?, "
        'lease_until = NULL, last_error_code = ?, updated_at = ? '
        "WHERE operation_id = ? AND state = 'in_flight'",
      ),
      outboxPayloadDelete = database.prepare(
        'DELETE FROM sync_outbox_payloads WHERE operation_id = ?',
      ),
      inboxInsert = database.prepare(
        'INSERT OR IGNORE INTO sync_inbox('
        'user_scope, event_id, topic, received_at'
        ') VALUES (?, ?, ?, ?)',
      ),
      inboxStatus = database.prepare(
        'SELECT topic, processed_at FROM sync_inbox '
        'WHERE user_scope = ? AND event_id = ?',
      ),
      inboxProcess = database.prepare(
        'UPDATE sync_inbox SET processed_at = ? '
        'WHERE user_scope = ? AND event_id = ?',
      );

  final sqlite.PreparedStatement metadataUpsert;
  final sqlite.PreparedStatement localRecordUpsert;
  final sqlite.PreparedStatement localRecordDelete;
  final sqlite.PreparedStatement localRecordList;
  final sqlite.PreparedStatement checkpointUpsert;
  final sqlite.PreparedStatement checkpointDelete;
  final sqlite.PreparedStatement checkpointList;
  final sqlite.PreparedStatement outboxInsert;
  final sqlite.PreparedStatement outboxPayloadInsert;
  final sqlite.PreparedStatement outboxClaimCandidates;
  final sqlite.PreparedStatement outboxClaim;
  final sqlite.PreparedStatement outboxSucceed;
  final sqlite.PreparedStatement outboxRetry;
  final sqlite.PreparedStatement outboxPayloadDelete;
  final sqlite.PreparedStatement inboxInsert;
  final sqlite.PreparedStatement inboxStatus;
  final sqlite.PreparedStatement inboxProcess;

  int get count => 17;

  void close() {
    metadataUpsert.close();
    localRecordUpsert.close();
    localRecordDelete.close();
    localRecordList.close();
    checkpointUpsert.close();
    checkpointDelete.close();
    checkpointList.close();
    outboxInsert.close();
    outboxPayloadInsert.close();
    outboxClaimCandidates.close();
    outboxClaim.close();
    outboxSucceed.close();
    outboxRetry.close();
    outboxPayloadDelete.close();
    inboxInsert.close();
    inboxStatus.close();
    inboxProcess.close();
  }
}

void _validateCheckpoint(ChatRunCheckpoint checkpoint) {
  _validateIdentifier(checkpoint.userScope, 'userScope');
  _validateIdentifier(checkpoint.runId, 'runId', maxLength: 240);
  _validateIdentifier(checkpoint.status, 'status');
  if (checkpoint.eventSequence < 0) {
    throw ArgumentError.value(
      checkpoint.eventSequence,
      'eventSequence',
      'must not be negative',
    );
  }
  _validateOptionalIdentifier(checkpoint.threadId, 'threadId', maxLength: 240);
  _validateOptionalIdentifier(checkpoint.scene, 'scene');
  _validateOptionalIdentifier(checkpoint.purpose, 'purpose');
  _validateOptionalIdentifier(
    checkpoint.localNoteId,
    'localNoteId',
    maxLength: 240,
  );
  _validateOptionalIdentifier(checkpoint.targetPart, 'targetPart');
  _validateOptionalIdentifier(checkpoint.failureCode, 'failureCode');
  final publicStateJson = jsonEncode(checkpoint.publicState);
  if (utf8.encode(publicStateJson).length > 128 * 1024 ||
      jsonDecode(publicStateJson) is! Map) {
    throw ArgumentError.value(
      checkpoint.publicState,
      'publicState',
      'must be a bounded JSON object',
    );
  }
  if (checkpoint.kind == ChatRunCheckpointKind.chat &&
      checkpoint.threadId == null) {
    throw ArgumentError.value(
      checkpoint.threadId,
      'threadId',
      'is required for Chat checkpoints',
    );
  }
  if (checkpoint.kind == ChatRunCheckpointKind.derived &&
      (checkpoint.localNoteId == null || checkpoint.targetPart == null)) {
    throw ArgumentError(
      'localNoteId and targetPart are required for derived checkpoints',
    );
  }
}

ChatRunCheckpoint _workerCheckpoint(Map<Object?, Object?> message) {
  final checkpoint = ChatRunCheckpoint._fromMessage(message);
  try {
    _validateCheckpoint(checkpoint);
  } catch (_) {
    throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_CHECKPOINT');
  }
  return checkpoint;
}

Map<String, Object?> _checkpointRowMessage(sqlite.Row row) {
  return <String, Object?>{
    'userScope': '${row['user_scope']}',
    'runId': '${row['run_id']}',
    'kind': '${row['kind']}',
    'status': '${row['status']}',
    'eventSequence': row['event_sequence'],
    'threadId': row['thread_id'],
    'scene': row['scene'],
    'purpose': row['purpose'],
    'localNoteId': row['local_note_id'],
    'targetPart': row['target_part'],
    'failureCode': row['failure_code'],
    'createdAt': '${row['created_at']}',
    'updatedAt': '${row['updated_at']}',
    'role': '${row['checkpoint_role']}',
    'publicStateJson': '${row['public_state_json']}',
  };
}

int _changedRows(sqlite.Database database) {
  final rows = database.select('SELECT changes()');
  if (rows.isEmpty) return 0;
  return _messageInt(rows.first.values.first);
}

Map<Object?, Object?> _messageMap(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_RESPONSE');
}

int _messageInt(Object? value) {
  if (value is int) return value;
  return int.tryParse('$value') ?? 0;
}

String? _messageNullableString(Object? value) {
  if (value == null) return null;
  final text = '$value';
  return text.isEmpty ? null : text;
}

Map<String, Object?> _decodeJsonMap(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map) {
    throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_JSON');
  }
  return <String, Object?>{
    for (final entry in decoded.entries) '${entry.key}': entry.value,
  };
}

void _validateRecordKey(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 512 ||
      normalized.contains('\u0000')) {
    throw ArgumentError.value(value, 'key', 'must be a bounded record key');
  }
}

String _workerRecordKey(Object? value) {
  final text = '$value';
  try {
    _validateRecordKey(text);
  } catch (_) {
    throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_RECORD_KEY');
  }
  return text.trim();
}

LocalTableName _workerTable(Object? value) {
  final name = _workerString(value, 'table', maxLength: 96);
  for (final table in LocalTableName.values) {
    if (table.dbName == name) return table;
  }
  throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_TABLE');
}

void _validateIdentifier(String value, String name, {int maxLength = 128}) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maxLength ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@+-]*$').hasMatch(normalized)) {
    throw ArgumentError.value(value, name, 'must be a bounded safe identifier');
  }
}

void _validateOptionalIdentifier(
  String? value,
  String name, {
  int maxLength = 128,
}) {
  if (value == null) return;
  _validateIdentifier(value, name, maxLength: maxLength);
}

String _workerIdentifier(Object? value, String name, {int maxLength = 128}) {
  final text = '$value';
  try {
    _validateIdentifier(text, name, maxLength: maxLength);
  } catch (_) {
    throw const DatabaseWorkerException('DATABASE_WORKER_INVALID_IDENTIFIER');
  }
  return text.trim();
}

String? _workerOptionalIdentifier(
  Object? value,
  String name, {
  int maxLength = 128,
}) {
  if (value == null) return null;
  return _workerIdentifier(value, name, maxLength: maxLength);
}

String _workerString(Object? value, String name, {int maxLength = 128}) {
  final text = '$value'.trim();
  if (text.isEmpty || text.length > maxLength || text.contains('\u0000')) {
    throw DatabaseWorkerException(
      'DATABASE_WORKER_INVALID_${name.toUpperCase()}',
    );
  }
  return text;
}

String _workerTimestamp(Object? value, String name) {
  final text = '$value';
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    throw DatabaseWorkerException(
      'DATABASE_WORKER_INVALID_${name.toUpperCase()}',
    );
  }
  return parsed.toUtc().toIso8601String();
}

String _workerPayloadJson(Object? value) {
  final text = '$value';
  if (utf8.encode(text).length > 512 * 1024) {
    throw const DatabaseWorkerException('DATABASE_WORKER_PAYLOAD_TOO_LARGE');
  }
  _decodeJsonMap(text);
  return text;
}

String _safeWorkerErrorCode(Object error) {
  if (error is DatabaseWorkerException) return error.code;
  if (error is StateError) {
    final text = error.message;
    if (RegExp(r'^[A-Z0-9_]{3,80}$').hasMatch(text)) {
      return text;
    }
  }
  if (error is sqlite.SqliteException) {
    return 'DATABASE_WORKER_SQLITE_FAILED';
  }
  return 'DATABASE_WORKER_OPERATION_FAILED';
}
