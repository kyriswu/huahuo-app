import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/runtime/database_worker_runtime.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/performance/database_metrics.dart';

void main() {
  test('custom and disabled stores retain synchronous fallback', () async {
    final directory = await Directory.systemTemp.createTemp('db-runtime-off-');
    addTearDown(() => directory.delete(recursive: true));
    final runtime = DatabaseWorkerRuntime(
      snapshotStore: LocalDatabaseSnapshotStore(
        file: File('${directory.path}/snapshot.json'),
      ),
      enabled: true,
      metrics: DatabaseMetrics(),
    );

    expect(runtime.configured, isFalse);
    await runtime.start();
    expect(runtime.isEnabled, isFalse);
    await runtime.dispose();
    expect(runtime.isDisposed, isTrue);
  });

  test(
    'starts one worker on the configured SQLite file and forwards ports',
    () async {
      final directory = await Directory.systemTemp.createTemp('db-runtime-on-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/app.sqlite');
      final metrics = DatabaseMetrics();
      final runtime = DatabaseWorkerRuntime(
        snapshotStore: LocalDatabaseSnapshotStore(
          file: file,
          backend: LocalDatabaseSnapshotBackend.sqlite,
        ),
        enabled: true,
        metrics: metrics,
      );
      addTearDown(runtime.dispose);

      expect(runtime.isEnabled, isFalse);
      await runtime.start();
      expect(runtime.isEnabled, isTrue);
      await runtime.upsertRecord(
        table: LocalTableName.appPreferences,
        key: 'preference:test',
        record: const <String, Object?>{'value': 'ready'},
      );
      final records = await runtime.listRecords(LocalTableName.appPreferences);
      expect(records, hasLength(1));
      expect(records.single['value'], 'ready');

      final now = DateTime.utc(2026, 8, 31);
      final checkpoint = ChatRunCheckpoint(
        userScope: 'user-1',
        runId: 'run-1',
        kind: ChatRunCheckpointKind.chat,
        status: 'running',
        eventSequence: 4,
        createdAt: now,
        updatedAt: now,
        threadId: 'thread-1',
        scene: 'chat',
        purpose: 'conversation',
      );
      await runtime.upsertChatRunCheckpoint(checkpoint);
      expect(await runtime.listChatRunCheckpoints('user-1'), hasLength(1));
      final operation = DatabaseOutboxEntry(
        operationId: 'runtime-note-operation',
        userScope: 'user-1',
        topic: 'knowledge_note_v1',
        dedupeKey: 'runtime-note-operation',
        payload: const <String, Object?>{'version': 1},
        availableAt: now,
        createdAt: now,
      );
      expect(await runtime.enqueueOutbox(operation), isTrue);
      final claimed = await runtime.claimOutbox(
        userScope: 'user-1',
        topic: 'knowledge_note_v1',
        operationId: operation.operationId,
        now: now,
      );
      expect(claimed.single.operationId, operation.operationId);
      expect(
        await runtime.beginInbox(
          userScope: 'user-1',
          eventId: 'runtime-event-1',
          topic: 'knowledge_note_v1',
          receivedAt: now,
        ),
        DatabaseInboxDisposition.accepted,
      );
      expect(
        await runtime.beginInbox(
          userScope: 'user-1',
          eventId: 'runtime-event-1',
          topic: 'knowledge_note_v1',
          receivedAt: now,
        ),
        DatabaseInboxDisposition.resume,
      );
      expect(metrics.snapshot().byOperation['worker_start'], 1);
    },
  );

  test('dispose drains the queue before closing the worker', () async {
    final directory = await Directory.systemTemp.createTemp(
      'db-runtime-drain-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final runtime = DatabaseWorkerRuntime(
      snapshotStore: LocalDatabaseSnapshotStore(
        file: File('${directory.path}/app.sqlite'),
        backend: LocalDatabaseSnapshotBackend.sqlite,
      ),
      enabled: true,
      metrics: DatabaseMetrics(),
    );
    await runtime.start();
    final release = Completer<void>();
    var completed = false;
    unawaited(
      runtime.writeQueue.enqueue(
        key: 'pending',
        operation: () async {
          await release.future;
          completed = true;
        },
      ),
    );

    final disposing = runtime.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(runtime.isDisposed, isFalse);
    release.complete();
    await disposing;

    expect(completed, isTrue);
    expect(runtime.writeQueue.isDisposed, isTrue);
    expect(runtime.isDisposed, isTrue);
  });

  test('queued mutation waits for explicit post-frame activation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'db-runtime-activation-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/app.sqlite');
    final runtime = DatabaseWorkerRuntime(
      snapshotStore: LocalDatabaseSnapshotStore(
        file: file,
        backend: LocalDatabaseSnapshotBackend.sqlite,
      ),
      enabled: true,
      metrics: DatabaseMetrics(),
    );
    addTearDown(runtime.dispose);

    var completed = false;
    final mutation = runtime
        .applyRecordMutations(
          schemaVersion: localDatabaseSchemaVersion,
          mutations: const <LocalDatabaseMutation>[
            LocalDatabaseMutation.upsert(
              table: LocalTableName.appPreferences,
              key: 'activation-test',
              value: <String, Object?>{
                'preference_key': 'activation.test',
                'value': 'ready',
              },
            ),
          ],
        )
        .whenComplete(() => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(await file.exists(), isFalse);

    await runtime.start();
    await mutation;
    expect(completed, isTrue);
    expect(
      (await runtime.listRecords(
        LocalTableName.appPreferences,
      )).single['value'],
      'ready',
    );
  });

  test('startup failure is retained by queue flush', () async {
    final directory = await Directory.systemTemp.createTemp(
      'db-runtime-start-failure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final runtime = DatabaseWorkerRuntime(
      snapshotStore: LocalDatabaseSnapshotStore(
        file: File('${directory.path}/app.sqlite'),
        backend: LocalDatabaseSnapshotBackend.sqlite,
      ),
      enabled: true,
      metrics: DatabaseMetrics(),
      startWorker: (_) async => throw StateError('injected startup failure'),
    );
    final queued = runtime.writeQueue.enqueue(
      key: 'startup-failure',
      operation: () => runtime.applyRecordMutations(
        schemaVersion: localDatabaseSchemaVersion,
        mutations: const <LocalDatabaseMutation>[
          LocalDatabaseMutation.delete(
            table: LocalTableName.appPreferences,
            key: 'missing',
          ),
        ],
      ),
    );
    await runtime.start();

    await expectLater(queued, throwsStateError);
    await expectLater(runtime.writeQueue.flush(), throwsStateError);
    expect(runtime.startupFailureCode, 'DATABASE_WORKER_START_FAILED');
    await runtime.dispose();
  });

  testWidgets('background flush reports the original queued failure', (
    tester,
  ) async {
    final runtime = DatabaseWorkerRuntime(
      snapshotStore: null,
      enabled: false,
      metrics: DatabaseMetrics(),
    );
    final runtimeProvider = Provider<DatabaseWorkerRuntime>((_) => runtime);
    final foregroundProvider = StateProvider<bool>((_) => true);
    FlutterErrorDetails? reported;
    final previousHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      reported ??= details;
    };
    addTearDown(() => FlutterError.onError = previousHandler);

    await tester.pumpWidget(
      ProviderScope(
        child: DatabaseWorkerActivation(
          runtimeProvider: runtimeProvider,
          foregroundProvider: foregroundProvider,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SizedBox)),
    );
    final release = Completer<void>();
    final original = StateError('original queued failure');
    final queued = runtime.writeQueue.enqueue(
      key: 'lifecycle-failure',
      operation: () async {
        await release.future;
        throw original;
      },
    );
    unawaited(queued.catchError((_) {}));
    final queuedExpectation = expectLater(queued, throwsA(same(original)));

    container.read(foregroundProvider.notifier).state = false;
    await tester.pump();
    release.complete();
    await tester.pump();
    await queuedExpectation;
    final details = reported;

    expect(details, isNotNull);
    expect(details!.exception, same(original));
    expect(details.stack, isNotNull);
    expect(
      details.context.toString(),
      contains('flushing database writes for app backgrounding'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.dispose();
  });
}
