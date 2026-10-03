import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_sync_service.dart';
import 'package:huahuoai_app/features/ui_v3/data/workspace_content_sync_store.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test('durable upsert is claimed before delivery and retains retry', () async {
    final journal = _MemorySyncJournal();
    final service = KnowledgeNoteSyncService(journal);
    final note = _note(localRevision: 3);

    final result = await service.synchronize(
      local: note,
      readCurrent: (_) => note,
      flushPersistence: () async {
        journal.events.add('flush');
        return true;
      },
      deliver: (current, identity) async {
        journal.events.add('deliver:$identity');
        return const KnowledgeNoteSyncResult(
          outcome: KnowledgeNoteSyncOutcome.unavailable,
          errorCode: 'NETWORK_UNAVAILABLE',
        );
      },
      recordFailure: _failure,
    );

    expect(result.outcome, KnowledgeNoteSyncOutcome.unavailable);
    expect(journal.events, <String>[
      'flush',
      'enqueue:upsert:3',
      'claim:op-upsert-3',
      'deliver:op-upsert-3',
      'retry:op-upsert-3:NETWORK_UNAVAILABLE',
    ]);
    expect(journal.succeeded, isEmpty);
  });

  test('superseded upsert durably queues the current revision first', () async {
    final journal = _MemorySyncJournal();
    final service = KnowledgeNoteSyncService(journal);
    final stale = _note(localRevision: 1);
    final current = _note(localRevision: 2);
    var deliveries = 0;

    final result = await service.synchronize(
      local: stale,
      readCurrent: (_) => current,
      flushPersistence: () async => true,
      deliver: (_, __) async {
        deliveries += 1;
        return const KnowledgeNoteSyncResult(
          outcome: KnowledgeNoteSyncOutcome.synced,
        );
      },
      recordFailure: _failure,
    );

    expect(result.outcome, KnowledgeNoteSyncOutcome.superseded);
    expect(deliveries, 0);
    expect(journal.enqueued.map((value) => value.localRevision), <int>[1, 2]);
    expect(journal.succeeded.single.localRevision, 1);
  });

  test(
    'terminal tombstone failure is acknowledged and rotation completes',
    () async {
      final journal = _MemorySyncJournal();
      final service = KnowledgeNoteSyncService(journal);
      final note = _note(
        localRevision: 4,
        remoteNoteId: 'remote-note',
        etag: '"revision-4"',
      );
      final completed = <String>[];

      final result = await service.tombstone(
        localNoteId: note.id,
        local: note,
        readCurrent: (_) => note,
        flushPersistence: () async => true,
        fallbackDelete: (_) async => throw StateError('unexpected fallback'),
        idempotencyKeyFor: (subject) => 'delete:$subject',
        deliver: (_, __) async => const KnowledgeNoteDeleteResult(
          outcome: KnowledgeNoteDeleteOutcome.persistenceFailed,
          errorCode: 'PRECONDITION_FAILED',
        ),
        completeMutation: (remoteNoteId, etag) {
          completed.add('$remoteNoteId|$etag');
        },
      );

      expect(result.errorCode, 'PRECONDITION_FAILED');
      expect(journal.retried, isEmpty);
      expect(
        journal.succeeded.single.kind,
        KnowledgeNoteOutboxCommandKind.tombstone,
      );
      expect(completed, <String>['remote-note|"revision-4"']);
    },
  );

  test('recovery delivers a previously queued tombstone', () async {
    final journal = _MemorySyncJournal();
    final note = _note(
      localRevision: 5,
      remoteNoteId: 'remote-note',
      etag: '"revision-5"',
    );
    journal.enqueued.add(
      const KnowledgeNoteOutboxCommand(
        operationId: 'recovered-delete',
        kind: KnowledgeNoteOutboxCommandKind.tombstone,
        localNoteId: 'note-1',
        localRevision: 5,
        attemptCount: 1,
        remoteNoteId: 'remote-note',
        etag: '"revision-5"',
        idempotencyKey: 'delete-key',
      ),
    );
    final service = KnowledgeNoteSyncService(journal);
    var delivered = false;

    await service.recover(
      notes: const <V3FeedItem>[],
      readCurrent: (_) => note,
      flushPersistence: () async => true,
      deliverUpsert: (_, __) async => throw StateError('unexpected upsert'),
      deliverTombstone: (_, key) async {
        delivered = key == 'delete-key';
        return const KnowledgeNoteDeleteResult(
          outcome: KnowledgeNoteDeleteOutcome.deleted,
        );
      },
      recordFailure: _failure,
      recordCommandError: (_, __) {},
      completeMutation: (_, __) {},
      isDisposed: () => false,
    );

    expect(delivered, isTrue);
    expect(journal.succeeded.single.operationId, 'recovered-delete');
  });

  test(
    'inbox skips processed events and acknowledges unique receipts',
    () async {
      final journal = _MemorySyncJournal()
        ..inboxDisposition = KnowledgeNoteInboxDisposition.alreadyProcessed;
      final service = KnowledgeNoteSyncService(journal);

      expect(
        await service.admitEvent(
          eventId: 'event-1',
          occurredAt: DateTime.utc(2026, 8, 31),
        ),
        isFalse,
      );
      await service.markEventsProcessed(<String>[
        'event-1',
        'event-1',
        'event-2',
      ]);

      expect(journal.processedEvents, <String>['event-1', 'event-2']);
    },
  );
}

KnowledgeNoteSyncResult _failure(V3FeedItem note, String errorCode) =>
    KnowledgeNoteSyncResult(
      outcome: KnowledgeNoteSyncOutcome.failed,
      note: note,
      errorCode: errorCode,
    );

V3FeedItem _note({
  required int localRevision,
  String? remoteNoteId,
  String? etag,
}) => V3FeedItem(
  id: 'note-1',
  title: 'Note',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 8, 31),
  rawBody: 'Body',
  localRevision: localRevision,
  remoteNoteId: remoteNoteId,
  noteRevisionId: remoteNoteId == null ? null : 'note-revision',
  rawPartRevisionId: remoteNoteId == null ? null : 'raw-revision',
  etag: etag,
  contentCursor: remoteNoteId == null ? null : '5',
  syncState: NoteSyncState.pending,
);

final class _MemorySyncJournal implements KnowledgeNoteSyncJournal {
  final List<String> events = <String>[];
  final List<KnowledgeNoteOutboxCommand> enqueued =
      <KnowledgeNoteOutboxCommand>[];
  final List<KnowledgeNoteOutboxCommand> succeeded =
      <KnowledgeNoteOutboxCommand>[];
  final List<KnowledgeNoteOutboxCommand> retried =
      <KnowledgeNoteOutboxCommand>[];
  final List<String> processedEvents = <String>[];
  KnowledgeNoteInboxDisposition inboxDisposition =
      KnowledgeNoteInboxDisposition.accepted;

  @override
  String get workspaceId => 'workspace-1';

  @override
  Future<KnowledgeNoteOutboxCommand> enqueueUpsert({
    required String localNoteId,
    required int localRevision,
  }) async {
    final command = KnowledgeNoteOutboxCommand(
      operationId: 'op-upsert-$localRevision',
      kind: KnowledgeNoteOutboxCommandKind.upsert,
      localNoteId: localNoteId,
      localRevision: localRevision,
      attemptCount: 0,
    );
    enqueued.add(command);
    events.add('enqueue:upsert:$localRevision');
    return command;
  }

  @override
  Future<KnowledgeNoteOutboxCommand> enqueueTombstone({
    required String localNoteId,
    required int localRevision,
    required String remoteNoteId,
    required String etag,
    required String idempotencyKey,
  }) async {
    final command = KnowledgeNoteOutboxCommand(
      operationId: 'op-tombstone-$localRevision',
      kind: KnowledgeNoteOutboxCommandKind.tombstone,
      localNoteId: localNoteId,
      localRevision: localRevision,
      attemptCount: 0,
      remoteNoteId: remoteNoteId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    );
    enqueued.add(command);
    events.add('enqueue:tombstone:$localRevision');
    return command;
  }

  @override
  Future<List<KnowledgeNoteOutboxCommand>> claim({
    String? operationId,
    int limit = 20,
  }) async {
    events.add('claim:${operationId ?? 'all'}');
    return enqueued
        .where(
          (command) =>
              operationId == null || command.operationId == operationId,
        )
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<void> markSucceeded(KnowledgeNoteOutboxCommand command) async {
    succeeded.add(command);
    events.add('success:${command.operationId}');
  }

  @override
  Future<void> markRetry(
    KnowledgeNoteOutboxCommand command, {
    required String errorCode,
  }) async {
    retried.add(command);
    events.add('retry:${command.operationId}:$errorCode');
  }

  @override
  Future<KnowledgeNoteInboxDisposition> beginEvent({
    required String eventId,
    required DateTime occurredAt,
  }) async => inboxDisposition;

  @override
  Future<void> markEventProcessed(String eventId) async {
    processedEvents.add(eventId);
  }
}
