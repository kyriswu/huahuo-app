import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/database/database_worker.dart';
import '../../core/database/database_write_queue.dart';
import '../../core/performance/database_metrics.dart';

typedef DatabaseWorkerStarter = Future<DatabaseWorker> Function(File file);

final class DatabaseWorkerRuntime
    implements
        DatabaseRecordWorkerPort,
        ChatRunCheckpointWorkerPort,
        DatabaseSyncJournalPort,
        LocalDatabaseWriteWorkerPort {
  DatabaseWorkerRuntime({
    required LocalDatabaseSnapshotStore? snapshotStore,
    required bool enabled,
    required DatabaseMetrics metrics,
    DatabaseWorkerStarter? startWorker,
  }) : _file =
           enabled &&
               snapshotStore?.backend == LocalDatabaseSnapshotBackend.sqlite
           ? snapshotStore!.file
           : null,
       _metrics = metrics,
       _startWorker = startWorker ?? _defaultStartWorker,
       writeQueue = DatabaseWriteQueue(metrics: metrics);

  final File? _file;
  final DatabaseMetrics _metrics;
  final DatabaseWorkerStarter _startWorker;
  final DatabaseWriteQueue writeQueue;
  DatabaseWorker? _worker;
  Future<void>? _startFuture;
  Future<void>? _disposeFuture;
  final Completer<void> _activation = Completer<void>();
  var _disposeRequested = false;
  var _disposed = false;
  String? _startupFailureCode;

  bool get configured => _file != null;
  String? get startupFailureCode => _startupFailureCode;

  @override
  bool get isEnabled => !_disposed && _worker?.isEnabled == true;

  @override
  bool get isDisposed => _disposed;

  Future<void> start() {
    if (!_activation.isCompleted) _activation.complete();
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    final file = _file;
    if (file == null || _disposeRequested) return;
    final stopwatch = Stopwatch()..start();
    var success = false;
    try {
      final worker = await _startWorker(file);
      if (_disposeRequested) {
        await worker.dispose();
        return;
      }
      _worker = worker;
      _startupFailureCode = null;
      success = worker.isEnabled;
    } on Object {
      _startupFailureCode = 'DATABASE_WORKER_START_FAILED';
    } finally {
      _metrics.record(
        operation: 'worker_start',
        table: 'runtime',
        queueWait: Duration.zero,
        execute: stopwatch.elapsed,
        rows: 0,
        reason: 'post_first_frame',
        callerFeature: 'app_runtime',
        isWrite: false,
        success: success,
      );
    }
  }

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) => _requireWorker().upsertRecord(table: table, key: key, record: record);

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) => _requireWorker().upsertRecordBatch(table: table, records: records);

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) => _requireWorker().deleteRecord(table: table, key: key);

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) =>
      _requireWorker().listRecords(table);

  @override
  Future<void> applyRecordMutations({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
  }) async {
    final worker = await _workerAfterActivation();
    await worker.applyRecordMutations(
      schemaVersion: schemaVersion,
      mutations: mutations,
    );
  }

  @override
  Future<void> replaceAllRecords({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) async {
    final worker = await _workerAfterActivation();
    await worker.replaceAllRecords(
      schemaVersion: schemaVersion,
      tables: tables,
    );
  }

  @override
  Future<void> upsertChatRunCheckpoint(ChatRunCheckpoint checkpoint) =>
      _requireWorker().upsertChatRunCheckpoint(checkpoint);

  @override
  Future<bool> deleteChatRunCheckpoint({
    required String userScope,
    required String runId,
  }) => _requireWorker().deleteChatRunCheckpoint(
    userScope: userScope,
    runId: runId,
  );

  @override
  Future<void> applyChatRunCheckpointChanges({
    required String userScope,
    required Iterable<ChatRunCheckpoint> upserts,
    required Iterable<String> deletions,
  }) => _requireWorker().applyChatRunCheckpointChanges(
    userScope: userScope,
    upserts: upserts,
    deletions: deletions,
  );

  @override
  Future<List<ChatRunCheckpoint>> listChatRunCheckpoints(String userScope) =>
      _requireWorker().listChatRunCheckpoints(userScope);

  @override
  Future<bool> enqueueOutbox(DatabaseOutboxEntry entry) async {
    final worker = await _workerAfterActivation();
    return worker.enqueueOutbox(entry);
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
    final worker = await _workerAfterActivation();
    return worker.claimOutbox(
      userScope: userScope,
      now: now,
      leaseDuration: leaseDuration,
      limit: limit,
      topic: topic,
      operationId: operationId,
    );
  }

  @override
  Future<bool> markOutboxSucceeded({
    required String operationId,
    required DateTime updatedAt,
  }) async {
    final worker = await _workerAfterActivation();
    return worker.markOutboxSucceeded(
      operationId: operationId,
      updatedAt: updatedAt,
    );
  }

  @override
  Future<bool> markOutboxRetry({
    required String operationId,
    required DateTime availableAt,
    required DateTime updatedAt,
    required String errorCode,
  }) async {
    final worker = await _workerAfterActivation();
    return worker.markOutboxRetry(
      operationId: operationId,
      availableAt: availableAt,
      updatedAt: updatedAt,
      errorCode: errorCode,
    );
  }

  @override
  Future<DatabaseInboxDisposition> beginInbox({
    required String userScope,
    required String eventId,
    required String topic,
    required DateTime receivedAt,
  }) async {
    final worker = await _workerAfterActivation();
    return worker.beginInbox(
      userScope: userScope,
      eventId: eventId,
      topic: topic,
      receivedAt: receivedAt,
    );
  }

  @override
  Future<bool> markInboxProcessed({
    required String userScope,
    required String eventId,
    required DateTime processedAt,
  }) async {
    final worker = await _workerAfterActivation();
    return worker.markInboxProcessed(
      userScope: userScope,
      eventId: eventId,
      processedAt: processedAt,
    );
  }

  DatabaseWorker _requireWorker() {
    final worker = _worker;
    if (_disposed || worker == null || !worker.isEnabled || worker.isDisposed) {
      throw StateError('DATABASE_WORKER_UNAVAILABLE');
    }
    return worker;
  }

  Future<DatabaseWorker> _workerAfterActivation() async {
    await _activation.future;
    final starting = _startFuture;
    if (starting == null) throw StateError('DATABASE_WORKER_UNAVAILABLE');
    await starting;
    return _requireWorker();
  }

  Future<void> flush() => writeQueue.flush();

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposeRequested = true;
    if (!_activation.isCompleted) _activation.complete();
    await _startFuture;
    Object? firstError;
    StackTrace? firstStack;
    try {
      await writeQueue.dispose();
    } catch (error, stack) {
      firstError = error;
      firstStack = stack;
    }
    try {
      await _worker?.dispose();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    _disposed = true;
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }
}

Future<DatabaseWorker> _defaultStartWorker(File file) =>
    DatabaseWorker.start(file: file);

final class DatabaseWorkerActivation extends ConsumerStatefulWidget {
  const DatabaseWorkerActivation({
    required this.runtimeProvider,
    required this.foregroundProvider,
    required this.child,
    super.key,
  });

  final ProviderListenable<DatabaseWorkerRuntime> runtimeProvider;
  final ProviderListenable<bool> foregroundProvider;
  final Widget child;

  @override
  ConsumerState<DatabaseWorkerActivation> createState() =>
      _DatabaseWorkerActivationState();
}

final class _DatabaseWorkerActivationState
    extends ConsumerState<DatabaseWorkerActivation> {
  Future<void>? _backgroundFlush;

  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(widget.foregroundProvider, (_, isForeground) {
      if (!isForeground) _startBackgroundFlush();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(widget.runtimeProvider).start());
    });
  }

  void _startBackgroundFlush() {
    if (_backgroundFlush != null) return;
    final future = _flushForBackground();
    _backgroundFlush = future;
    unawaited(future);
  }

  Future<void> _flushForBackground() async {
    try {
      await ref.read(widget.runtimeProvider).flush();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'huahuo database runtime',
          context: ErrorDescription(
            'while flushing database writes for app backgrounding',
          ),
        ),
      );
    } finally {
      _backgroundFlush = null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
