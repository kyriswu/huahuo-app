import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/ui_v3/application/digital_twin_material_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/digital_twin_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/digital_twin_material_store.dart';
import 'package:huahuoai_app/features/ui_v3/domain/digital_twin_material.dart';
import 'package:huahuoai_app/features/ui_v3/domain/document_change_proposal_models.dart';

const _source = DigitalTwinMaterialSource(
  workspaceId: 'workspace-1',
  noteId: 'note-1',
  rawPartRevisionId: 'raw-1',
  title: '材料',
);

void main() {
  test(
    'material read failures retain public codes and safe diagnostics',
    () async {
      final database = AppDatabase();
      final dao = DiagnosticLogDao(database);
      final logger = DiagnosticLogger(dao: dao);
      final store = DigitalTwinMaterialStore(
        database: database,
        scope: 'diagnostic-account',
      );
      final api = _MaterialApi();
      final controller = DigitalTwinMaterialController(
        store: store,
        api: api,
        resolveSource: (_) async => _source,
        diagnosticLogger: logger,
      );
      addTearDown(() {
        controller.dispose();
        logger.dispose();
      });
      await controller.enqueue(
        referenceId: 'note-1',
        title: 'PRIVATE_MATERIAL_TITLE',
      );
      await controller.submit([controller.items.single.id]);
      final proposalIds = controller.items.single.proposalIds;
      api.readErrorCode = 'DOCUMENT_PROPOSAL_ETAG_MISSING';
      await controller.refresh();
      expect(controller.errorCode, 'DOCUMENT_PROPOSAL_ETAG_MISSING');
      expect(controller.items.single.errorCode, controller.errorCode);
      final failure = dao.query().firstWhere(
        (entry) => entry.redactedMetadata['stage'] == 'refresh',
      );
      expect(failure.redactedMetadata['error_code'], controller.errorCode);
      expect(
        failure.redactedMetadata['exception_type'],
        'DocumentChangeProposalException',
      );
      expect(
        failure.redactedMetadata.toString(),
        isNot(contains('PRIVATE_MATERIAL_TITLE')),
      );
      api.readErrorCode = null;
      await controller.refresh();
      expect(controller.errorCode, isNull);
      expect(controller.items.single.errorCode, isNull);
      expect(controller.items.single.proposalIds, proposalIds);
    },
  );

  for (final recovering in [false, true]) {
    test(
      'simulator worker persists long-scope materials (recovery=$recovering)',
      () async {
        final root = await Directory.systemTemp.createTemp('twin-real-worker-');
        final file = File('${root.path}/materials.sqlite');
        final persistence = LocalDatabaseSnapshotStore(
          file: file,
          backend: LocalDatabaseSnapshotBackend.sqlite,
        );
        final worker = await DatabaseWorker.start(file: file);
        final queue = DatabaseWriteQueue();
        final database = AppDatabase(
          snapshotStore: persistence,
          writeWorker: worker,
          writeQueue: queue,
        );
        final scope = 'user_${'a' * 64}:workspace_user_${'a' * 64}';
        final store = DigitalTwinMaterialStore(
          database: database,
          scope: scope,
        );
        final api = _MaterialApi()
          ..state = DocumentProposalState.ready
          ..hasChanges = false;
        final controller = _controller(store, api);
        addTearDown(() async {
          controller.dispose();
          await queue.dispose();
          await worker.dispose();
          await root.delete(recursive: true);
        });
        if (recovering) {
          await store.saveAll([
            DigitalTwinMaterial(
              id: 'b' * 64,
              referenceKind: 'note',
              referenceId: 'note-1',
              title: '已有材料',
              createdAt: DateTime.utc(2026, 9, 7),
              status: DigitalTwinMaterialStatus.noChanges,
              source: _source,
              proposalIds: {
                for (final kind in digitalTwinMaterialProfileKinds)
                  kind: 'proposal-$kind',
              },
              errorCode: 'DIGITAL_TWIN_MATERIAL_READ_FAILED',
            ),
          ]);
        } else {
          expect(
            await controller.enqueue(referenceId: 'note-1', title: '新材料'),
            isTrue,
          );
          final afterEnqueue = DigitalTwinMaterialStore(
            database: AppDatabase(snapshotStore: persistence),
            scope: scope,
          );
          expect(
            afterEnqueue.read().single.status,
            DigitalTwinMaterialStatus.awaitingConfirmation,
          );
          expect(api.creates, isEmpty);
          await controller.submit([controller.items.single.id]);
        }
        final proposalIds = controller.items.single.proposalIds;
        await controller.refresh();
        expect(controller.errorCode, isNull);
        expect(controller.items.single.errorCode, isNull);
        expect(
          controller.items.single.status,
          DigitalTwinMaterialStatus.noChanges,
        );
        expect(controller.items.single.proposalIds, proposalIds);
        expect(api.creates.length, recovering ? 0 : 3);
        await store.appendRevision(
          DigitalTwinRevisionEvent(
            proposalId: proposalIds.values.first,
            text: '保留已经提交的修订要求',
            isUser: true,
            eventId: 'revision-1',
          ),
        );
        final reopened = DigitalTwinMaterialStore(
          database: AppDatabase(snapshotStore: persistence),
          scope: scope,
        );
        expect(
          reopened.read().single.status,
          DigitalTwinMaterialStatus.noChanges,
        );
        expect(reopened.read().single.errorCode, isNull);
        expect(reopened.read().single.proposalIds, proposalIds);
        expect(reopened.revisionEvents.single.text, '保留已经提交的修订要求');
      },
    );
  }

  for (final alreadyObserving in [false, true]) {
    test(
      'second audit: submission restarts without a leaked owner ($alreadyObserving)',
      () async {
        final orchestrator = TaskOrchestrator();
        final metrics = RuntimeActivityMetrics();
        final controller = DigitalTwinMaterialController(
          store: DigitalTwinMaterialStore(
            database: AppDatabase(),
            scope: 'submission-owner',
          ),
          api: _MaterialApi(),
          resolveSource: (_) async => null,
          orchestrator: orchestrator,
          activityMetrics: metrics,
        );
        addTearDown(() {
          controller.dispose();
          orchestrator.dispose();
          metrics.dispose();
        });
        await controller.enqueue(referenceId: 'source-delayed', title: '已选择材料');
        if (alreadyObserving)
          await controller.submit([controller.items.single.id]);
        final sheet = Object();
        controller.setActive(true, owner: sheet);
        await Future<void>.delayed(Duration.zero);
        expect(metrics.current.activePollers, alreadyObserving ? 1 : 0);
        await controller.submit([controller.items.single.id]);
        await Future<void>.delayed(Duration.zero);
        expect(metrics.current.activePollers, 1);
        controller.setActive(false, owner: sheet);
        expect(metrics.current.activePollers, 0);
      },
    );
  }
  test(
    'audit: material sheet keeps observing while parent is covered and resumes paused observation',
    () async {
      final orchestrator = TaskOrchestrator();
      final metrics = RuntimeActivityMetrics();
      final controller = DigitalTwinMaterialController(
        store: DigitalTwinMaterialStore(
          database: AppDatabase(),
          scope: 'visible-sheet',
        ),
        api: _MaterialApi(),
        resolveSource: (_) async => null,
        orchestrator: orchestrator,
        activityMetrics: metrics,
      );
      addTearDown(() {
        controller.dispose();
        orchestrator.dispose();
        metrics.dispose();
      });
      await controller.enqueue(referenceId: 'waiting-note', title: '等待同步');
      await controller.submit([controller.items.single.id]);
      final sheet = Object();
      controller.setActive(true);
      controller.setActive(true, owner: sheet);
      controller.setActive(false);
      await Future<void>.delayed(Duration.zero);
      expect(metrics.current.activePollers, 1);
      controller.observationPaused = true;
      controller.setActive(true, owner: sheet);
      expect(controller.observationPaused, isFalse);
      controller.setActive(false, owner: sheet);
      expect(metrics.current.activePollers, 0);
    },
  );
  _auditCases();
  test(
    'queue is durable, account isolated and never submits before approval',
    () async {
      final directory = await Directory.systemTemp.createTemp('twin-material-');
      addTearDown(() => directory.delete(recursive: true));
      final persistence = LocalDatabaseSnapshotStore(
        file: File('${directory.path}/materials.sqlite'),
        backend: LocalDatabaseSnapshotBackend.sqlite,
      );
      final database = AppDatabase(snapshotStore: persistence);
      final store = DigitalTwinMaterialStore(
        database: database,
        scope: 'account-1:workspace-1',
      );
      final api = _MaterialApi();
      final controller = _controller(store, api);
      addTearDown(controller.dispose);
      expect(
        await controller.enqueue(referenceId: 'local-1', title: '材料'),
        isTrue,
      );
      expect(
        await controller.enqueue(referenceId: 'local-1', title: '材料'),
        isTrue,
      );
      await controller.refresh();
      expect(api.creates, isEmpty);
      expect(
        DigitalTwinMaterialStore(
          database: AppDatabase(snapshotStore: persistence),
          scope: 'account-1:workspace-1',
        ).read(),
        hasLength(1),
      );
      expect(
        DigitalTwinMaterialStore(
          database: database,
          scope: 'account-2:workspace-1',
        ).read(),
        isEmpty,
      );
      expect(
        DigitalTwinMaterialStore(
          database: database,
          scope: 'account-1:workspace-2',
        ).read(),
        isEmpty,
      );
      expect(await controller.remove(controller.items.single.id), isTrue);
      expect(
        await controller.enqueue(referenceId: 'local-1', title: '材料'),
        isTrue,
      );
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.awaitingConfirmation,
      );
    },
  );

  test(
    'delayed refresh preserves a concurrently replaced proposal identity',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'account',
      );
      final api = _MaterialApi();
      final controller = _controller(store, api);
      addTearDown(controller.dispose);
      await controller.enqueue(referenceId: 'note-1', title: '材料');
      await controller.submit([controller.items.single.id]);
      final previousId = controller.items.single.proposalIds.values.first;
      final gate = Completer<void>();
      api.readGate = gate;
      final refreshing = controller.refresh();
      await store.replaceProposal(previousId, 'replacement-1');
      gate.complete();
      await refreshing;
      expect(
        controller.items.single.proposalIds.values,
        contains('replacement-1'),
      );
      expect(
        controller.items.single.proposalIds.values,
        isNot(contains(previousId)),
      );
    },
  );

  test('source not ready remains resumable without remote creation', () async {
    final store = DigitalTwinMaterialStore(
      database: AppDatabase(),
      scope: 'account',
    );
    final api = _MaterialApi();
    var sourceReady = false;
    final controller = DigitalTwinMaterialController(
      store: store,
      api: api,
      resolveSource: (_) async => sourceReady ? _source : null,
    );
    addTearDown(controller.dispose);
    await controller.enqueue(
      referenceId: 'job-1',
      referenceKind: 'recording_job',
      title: '录音',
    );
    await controller.submit([controller.items.single.id]);
    expect(
      controller.items.single.status,
      DigitalTwinMaterialStatus.waitingSource,
    );
    expect(api.creates, isEmpty);
    sourceReady = true;
    await controller.refresh();
    expect(controller.items.single.proposalIds, hasLength(3));
  });

  test(
    'partial submission resumes accepted request with frozen source and stable keys',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'account',
      );
      final api = _MaterialApi()..loseSecondResponse = true;
      final first = _controller(store, api);
      await first.enqueue(referenceId: 'local-1', title: '材料');
      final id = first.items.single.id;
      await first.submit([id]);
      expect(first.items.single.proposalIds, hasLength(1));
      expect(
        first.items.single.status,
        DigitalTwinMaterialStatus.partialFailure,
      );
      expect(api.created, hasLength(2));
      first.dispose();
      final resumed = DigitalTwinMaterialController(
        store: store,
        api: api,
        resolveSource: (_) async =>
            throw StateError('Frozen source must be reused'),
      );
      addTearDown(resumed.dispose);
      await resumed.submit([id]);
      expect(api.created, hasLength(3));
      expect(resumed.items.single.proposalIds, hasLength(3));
      expect(api.creates[1], api.creates[2]);
      expect(resumed.items.single.source?.rawPartRevisionId, 'raw-1');
    },
  );

  test(
    'approved selection excludes materials queued later and deduplicates source entry types',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'account',
      );
      final api = _MaterialApi();
      final controller = _controller(store, api);
      addTearDown(controller.dispose);
      await controller.enqueue(referenceId: 'local-1', title: '材料');
      final frozen = [controller.items.single.id];
      await controller.enqueue(
        referenceId: 'link-1',
        referenceKind: 'ingestion',
        title: '同一材料',
      );
      await controller.submit(frozen);
      expect(
        controller.items.last.status,
        DigitalTwinMaterialStatus.awaitingConfirmation,
      );
      await controller.submit([controller.items.last.id]);
      expect(api.created, hasLength(3));
      expect(
        controller.items.first.proposalIds,
        controller.items.last.proposalIds,
      );
    },
  );

  test(
    'generating, changed, unchanged and failed candidates project truthful states',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'account',
      );
      final api = _MaterialApi();
      final controller = _controller(store, api);
      addTearDown(controller.dispose);
      await controller.enqueue(referenceId: 'local-1', title: '材料');
      await controller.submit([controller.items.single.id]);
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.generating,
      );
      api.state = DocumentProposalState.ready;
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.reviewReady,
      );
      api.failureId = api.created.values.first;
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.partialFailure,
      );
      api.failureId = null;
      api.hasChanges = false;
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.noChanges,
      );
      api.hasChanges = true;
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.reviewReady,
      );
    },
  );

  test(
    'applied is not completed until all applied proposals have formal version evidence',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'account',
      );
      final api = _MaterialApi();
      final controller = _controller(store, api);
      addTearDown(controller.dispose);
      await controller.enqueue(referenceId: 'local-1', title: '材料');
      await controller.submit([controller.items.single.id]);
      api.state = DocumentProposalState.applied;
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.awaitingVersionVerification,
      );
      api.formalIds.add(api.created.values.first);
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.awaitingVersionVerification,
      );
      api.formalIds.addAll(api.created.values);
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.completed,
      );
      expect(controller.items.single.versionId, 'version-1');
    },
  );

  test(
    'confirmation and revision checkpoints survive store recreation; regenerated IDs replace old mapping',
    () async {
      final database = AppDatabase();
      final store = DigitalTwinMaterialStore(
        database: database,
        scope: 'account',
      );
      final api = _MaterialApi();
      final controller = _controller(store, api);
      addTearDown(controller.dispose);
      await controller.enqueue(referenceId: 'local-1', title: '材料');
      await controller.submit([controller.items.single.id]);
      final proposalId = controller.items.single.proposalIds.values.first;
      await store.recordConfirmation('confirmation-1', [proposalId]);
      await store.appendRevision(
        DigitalTwinRevisionEvent(
          proposalId: proposalId,
          text: '删掉没有依据的经历',
          isUser: true,
        ),
      );
      final restored = DigitalTwinMaterialStore(
        database: database,
        scope: 'account',
      );
      expect(restored.pendingConfirmationId, 'confirmation-1');
      expect(restored.pendingProposalIds, [proposalId]);
      await restored.recordConfirmation('confirmation-1', []);
      expect(restored.pendingProposalIds, [proposalId]);
      expect(restored.revisionEvents.single.text, '删掉没有依据的经历');
      await restored.replaceProposal(proposalId, 'replacement-1');
      expect(
        restored.read().single.proposalIds.values,
        contains('replacement-1'),
      );
      expect(
        restored.read().single.proposalIds.values,
        isNot(contains(proposalId)),
      );
      await restored.settleConfirmation('confirmation-1');
      expect(restored.pendingConfirmationId, isNull);
      expect(restored.read().single.confirmationId, isNull);
    },
  );
}

DigitalTwinMaterialController _controller(
  DigitalTwinMaterialStore store,
  _MaterialApi api,
) => DigitalTwinMaterialController(
  store: store,
  api: api,
  resolveSource: (_) async => _source,
);

void _auditCases() {
  test(
    'audit: multi-audio intents persist together and share single-job identity',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'account',
      );
      final api = _MaterialApi();
      final controller = _controller(store, api);
      addTearDown(controller.dispose);
      expect(
        await controller.enqueueRecordingJobs({'job-a': 'A', 'job-b': 'B'}),
        isTrue,
      );
      expect(store.read(), hasLength(2));
      expect(
        store.read().every(
          (item) =>
              item.status == DigitalTwinMaterialStatus.awaitingConfirmation,
        ),
        isTrue,
      );
      await controller.enqueue(
        referenceKind: 'recording_job',
        referenceId: 'job-a',
        title: 'A',
      );
      expect(store.read(), hasLength(2));
      expect(api.creates, isEmpty);
    },
  );
  test(
    'audit: batch approval survives interruption before later materials start',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'audit',
      );
      final api = _MaterialApi()..readGate = Completer<void>();
      final first = _controller(store, api);
      await first.enqueue(referenceId: 'note-a', title: 'A');
      await first.enqueue(referenceId: 'note-b', title: 'B');
      final selection = first.items.map((item) => item.id).toList();
      final submitting = first.submit(selection);
      while (api.creates.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      first.dispose();
      api.readGate!.complete();
      await submitting;
      final resumed = _controller(store, api);
      addTearDown(resumed.dispose);
      await resumed.refresh();
      expect(
        resumed.items.last.status,
        isNot(DigitalTwinMaterialStatus.awaitingConfirmation),
        reason:
            'B was approved in the same batch and should remain approved after restart',
      );
    },
  );

  test(
    'audit: later target submission preserves a concurrently regenerated candidate',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'audit',
      );
      final api = _MaterialApi();
      final controller = _controller(store, api);
      addTearDown(controller.dispose);
      await controller.enqueue(referenceId: 'note-a', title: 'A');
      final gate = Completer<void>();
      var blocked = false;
      controller.addListener(() {
        if (!blocked && controller.items.single.proposalIds.length == 1) {
          blocked = true;
          api.readGate = gate;
        }
      });
      final submitting = controller.submit([controller.items.single.id]);
      while (api.creates.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      final previous = controller.items.single.proposalIds.values.first;
      await store.replaceProposal(previous, 'regenerated-candidate');
      gate.complete();
      await submitting;
      expect(
        controller.items.single.proposalIds.values,
        contains('regenerated-candidate'),
        reason:
            'an acknowledged replacement must not be overwritten by the next target receipt',
      );
    },
  );

  test(
    'audit: completed material remains resolvable after twenty newer formal versions',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'audit',
      );
      final api = _OlderVersionApi();
      final controller = DigitalTwinMaterialController(
        store: store,
        api: api,
        resolveSource: (_) async => _source,
      );
      addTearDown(controller.dispose);
      await controller.enqueue(referenceId: 'note-a', title: 'A');
      await controller.submit([controller.items.single.id]);
      api.state = DocumentProposalState.applied;
      api.formalIds.addAll(api.created.values);
      await controller.refresh();
      expect(
        controller.items.single.status,
        DigitalTwinMaterialStatus.completed,
        reason:
            'all candidates have a real formal version; newer versions must not hide that evidence',
      );
    },
  );
}

class _OlderVersionApi extends _MaterialApi {
  @override
  Future<List<DigitalTwinVersion>> getVersions() async => [
    for (var number = 21; number >= 2; number--)
      DigitalTwinVersion(
        versionId: 'version-$number',
        versionNumber: number,
        label: 'v$number',
        workspaceVersion: number + 1,
        completionPercent: 20,
        scoringModel: 'profile.v1',
        createdAt: DateTime.utc(2026),
      ),
    version,
  ];

  @override
  Future<DigitalTwinVersionDetail> getVersion(String id) async =>
      id == version.versionId
      ? super.getVersion(id)
      : DigitalTwinVersionDetail(
          version: version,
          operationKey: 'another-confirmation',
          rendererVersion: 'profile_projection.v1',
          profileCount: 3,
          hasPositioning: false,
          proposalResults: const [],
        );
}

class _MaterialApi implements DigitalTwinApiPort, DigitalTwinMaterialApiPort {
  final creates = <String>[];
  final created = <String, String>{};
  final formalIds = <String>{};
  bool loseSecondResponse = false;
  bool hasChanges = true;
  String? failureId;
  String? readErrorCode;
  Completer<void>? readGate;
  DocumentProposalState state = DocumentProposalState.generating;

  @override
  Future<DocumentChangeProposalSnapshot> createMaterialProposal({
    required DigitalTwinMaterialSource source,
    required String profileKind,
    required String idempotencyKey,
  }) async {
    creates.add(idempotencyKey);
    final id = created.putIfAbsent(
      idempotencyKey,
      () => 'proposal-${created.length + 1}',
    );
    if (loseSecondResponse && creates.length == 2) {
      throw const DigitalTwinApiException('NETWORK_UNCERTAIN');
    }
    return getProposal(id);
  }

  @override
  Future<DocumentChangeProposalSnapshot> getProposal(String proposalId) async {
    await readGate?.future;
    if (readErrorCode != null)
      throw DocumentChangeProposalException(readErrorCode!);
    return DocumentChangeProposalSnapshot(
      proposal: DocumentChangeProposal(
        proposalId: proposalId,
        proposalVersion: 1,
        rowVersion: 1,
        state: proposalId == failureId
            ? DocumentProposalState.generationFailed
            : state,
        ownerKind: 'profile_conclusion',
        noteId: 'profile-$proposalId',
        rawPartRevisionId: 'profile-base-1',
        candidateAvailable: state != DocumentProposalState.generating,
        hasChanges: hasChanges,
      ),
      etag: '"dcp:$proposalId:1"',
    );
  }

  DigitalTwinVersion get version => DigitalTwinVersion(
    versionId: 'version-1',
    versionNumber: 1,
    label: 'v1',
    workspaceVersion: 2,
    completionPercent: 20,
    scoringModel: 'profile.v1',
    createdAt: DateTime.utc(2026),
  );

  @override
  Future<List<DigitalTwinVersion>> getVersions() async =>
      formalIds.isEmpty ? [] : [version];

  @override
  Future<DigitalTwinVersionDetail> getVersion(String versionId) async =>
      DigitalTwinVersionDetail(
        version: version,
        operationKey: 'confirmation-1',
        rendererVersion: 'profile_projection.v1',
        profileCount: 3,
        hasPositioning: false,
        proposalResults: [
          for (final id in formalIds)
            DigitalTwinConfirmationOutcome(
              proposalId: id,
              proposalVersion: 1,
              state: DocumentProposalState.applied,
            ),
        ],
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
