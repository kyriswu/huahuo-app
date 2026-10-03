import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_api.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_progress_repository.dart';
import 'package:huahuoai_app/features/ui_v3/application/deep_positioning_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/positioning_lifecycle_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/positioning_update_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/document_change_proposal_models.dart';

void main() {
  test(
    'restores captured candidate for latest persisted Run without a binding',
    () async {
      final fixture = _Fixture();
      fixture.store.values = [
        for (var index = 0; index < 6; index++)
          PositioningUpdateCheckpoint(
            runId: 'earlier-run-$index',
            createdAt: DateTime.utc(2026, 9, 17, 17, 20, index),
            stage: PositioningUpdateStage.waitingForCandidate,
          ),
        PositioningUpdateCheckpoint(
          runId: 'run-1',
          createdAt: DateTime.utc(2026, 9, 17, 17, 30),
          stage: PositioningUpdateStage.waitingForCandidate,
        ),
      ];
      fixture.updates.snapshot = _capturedProposal();
      fixture.updates.onApply = () => fixture.remote.report = _report('新报告');
      fixture.restart();

      await fixture.coordinator.reconcile();

      expect(fixture.updates.applied.single.runId, 'run-1');
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.updated,
      );
      expect(fixture.coordinator.latestUpdate?.proposalId, 'proposal-1');
      expect(fixture.reports.result?.markdown, '新报告');
      fixture.restart();
      await fixture.coordinator.reconcile();
      expect(fixture.updates.applied, hasLength(1));
    },
  );

  test(
    'discovers captured source Run without any local task receipt',
    () async {
      final fixture = _Fixture();
      fixture.updates.snapshot = _capturedProposal();
      fixture.updates.onApply = () => fixture.remote.report = _report('新报告');

      await fixture.coordinator.reconcile();

      expect(fixture.coordinator.latestUpdate?.runId, 'run-1');
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.updated,
      );
      expect(fixture.updates.applied, hasLength(1));
    },
  );

  test(
    'captured apply receipt recovers after response loss without binding',
    () async {
      final fixture = _Fixture();
      fixture.updates.snapshot = _capturedProposal();
      fixture.updates.loseResponse = true;
      fixture.updates.onApply = () => fixture.remote.report = _report('新报告');

      await fixture.coordinator.reconcile();
      final originalKey = fixture.store.values.single.idempotencyKey;
      fixture.restart();
      await fixture.coordinator.reconcile();

      expect(fixture.coordinator.latestUpdate?.idempotencyKey, originalKey);
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.updated,
      );
      expect(fixture.updates.applied, hasLength(1));
      expect(fixture.updates.snapshot?.proposal.runId, isNull);
    },
  );

  test(
    'generation binding cannot replace missing positioning source',
    () async {
      final fixture = _Fixture();
      fixture.updates.snapshot = _proposal(sourceRunId: null);

      await fixture.coordinator.reconcile();

      expect(fixture.updates.applied, isEmpty);
      expect(fixture.coordinator.checkpoints, isEmpty);
      expect(fixture.coordinator.errorCode, 'POSITIONING_SOURCE_UNVERIFIED');
    },
  );

  test(
    'verified completion persistence retries without generating another Run',
    () async {
      final fixture = _Fixture()..attemptState = 'completed';
      fixture.store.failCompletion = true;
      await fixture.coordinator.reconcile();
      expect(
        fixture.coordinator.errorCode,
        'POSITIONING_COMPLETION_SAVE_FAILED',
      );
      expect(fixture.coordinator.canStartBasic, isFalse);
      fixture.store.failCompletion = false;
      fixture.attemptState = 'not_started';
      await fixture.coordinator.reconcile();
      expect(fixture.store.basicCompleted, isTrue);
      expect(fixture.coordinator.canStartBasic, isFalse);
    },
  );

  test(
    'recovering an old proposal does not hide a newer pending Run',
    () async {
      final fixture = _Fixture();
      fixture.store.values = [
        PositioningUpdateCheckpoint(
          runId: 'new-run',
          createdAt: DateTime.utc(2026, 9, 17),
        ),
      ];
      fixture.restart();
      fixture.updates.snapshot = _proposal();
      await fixture.coordinator.reconcile();
      expect(fixture.coordinator.latestUpdate?.runId, 'new-run');
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.waitingForCandidate,
      );
    },
  );

  test('metadata-only change requires full formal content readback', () async {
    final fixture = _Fixture();
    const oldContent = '---\nsubject: old\n---\n# 定位报告\n相同正文';
    const newContent = '---\nsubject: new\n---\n# 定位报告\n相同正文';
    fixture.remote.report = workspaceProfilePositioningReport({
      'positioning': oldContent,
    }, fallback: DateTime.utc(2026));
    fixture.updates.snapshot = _proposal();
    fixture.updates.candidate = newContent;
    await fixture.coordinator.reconcile();
    expect(
      fixture.coordinator.latestUpdate?.stage,
      PositioningUpdateStage.awaitingReadback,
    );
    expect(fixture.reports.result?.markdown, '# 定位报告\n相同正文');
    fixture.remote.report = workspaceProfilePositioningReport({
      'positioning': newContent,
    }, fallback: DateTime.utc(2026, 9, 17));
    await fixture.coordinator.reconcile();
    expect(
      fixture.coordinator.latestUpdate?.stage,
      PositioningUpdateStage.updated,
    );
  });

  test(
    'verified completion survives a later regressed attempt and restart',
    () async {
      final fixture = _Fixture()..attemptState = 'completed';
      await fixture.coordinator.reconcile();
      expect(fixture.store.basicCompleted, isTrue);
      fixture.attemptState = 'not_started';
      fixture.restart();
      await fixture.coordinator.reconcile();
      expect(fixture.coordinator.access, InitialPositioningAccess.recovering);
      expect(fixture.coordinator.canStartBasic, isFalse);
    },
  );

  test('onboarding answers and receipts are workspace-scoped', () {
    final dao = AppPreferencesDao(AppDatabase());
    final first = OnboardingProgressRepository(
      dao: dao,
      workspaceId: 'workspace-a',
    );
    final second = OnboardingProgressRepository(
      dao: dao,
      workspaceId: 'workspace-b',
    );
    expect(
      first.save(
        userId: 'user',
        snapshot: const OnboardingProgressSnapshot(
          mode: onboardingBusinessMode,
          answers: {'customerScope': '全国客户'},
        ),
        updatedAt: DateTime.utc(2026),
      ),
      isTrue,
    );
    expect(first.load('user').answers, isNotEmpty);
    expect(second.load('user').answers, isEmpty);
  });
  test(
    'cloud-only formal report restores completion despite a failed attempt',
    () async {
      final fixture = _Fixture();
      fixture.remote.report = _report('正式报告');
      fixture.attemptState = 'failed_terminal';
      await fixture.coordinator.reconcile();
      expect(fixture.coordinator.access, InitialPositioningAccess.completed);
      expect(fixture.coordinator.canStartBasic, isFalse);
      expect(fixture.completions, 1);
      expect(fixture.reports.result?.markdown, '正式报告');
    },
  );

  test(
    'not-started cloud plus no report is the only fresh start path',
    () async {
      final fixture = _Fixture();
      await fixture.coordinator.reconcile();
      expect(fixture.coordinator.canStartBasic, isTrue);
      fixture.pending = true;
      await fixture.coordinator.reconcile();
      expect(fixture.coordinator.access, InitialPositioningAccess.running);
      expect(fixture.coordinator.canStartBasic, isFalse);
    },
  );

  test(
    'cross-device running attempt is observed without a local receipt',
    () async {
      final fixture = _Fixture()..attemptState = 'running';
      await fixture.coordinator.reconcile();
      expect(fixture.coordinator.access, InitialPositioningAccess.running);
      expect(fixture.coordinator.canStartBasic, isFalse);
    },
  );

  test('completed attempt with unreadable report stays in recovery', () async {
    final fixture = _Fixture()..attemptState = 'completed';
    await fixture.coordinator.reconcile();
    expect(fixture.coordinator.access, InitialPositioningAccess.recovering);
    expect(fixture.coordinator.canStartBasic, isFalse);
    fixture.remote.report = _report('迟到的正式报告');
    await fixture.coordinator.continueRecovery();
    expect(fixture.coordinator.access, InitialPositioningAccess.completed);
  });

  test(
    'failure retry is allowed only after a successful no-report read',
    () async {
      final fixture = _Fixture()..attemptState = 'failed_retryable';
      fixture.remote.unavailable = true;
      await fixture.coordinator.reconcile();
      expect(fixture.coordinator.canStartBasic, isFalse);
      fixture.remote.unavailable = false;
      await fixture.coordinator.reconcile();
      expect(
        fixture.coordinator.access,
        InitialPositioningAccess.retryableFailure,
      );
    },
  );

  test(
    'verified cache remains readable but never counts as fresh readback',
    () async {
      final fixture = _Fixture();
      fixture.remote.report = _report('正式缓存');
      await fixture.coordinator.reconcile();
      fixture.remote.unavailable = true;
      expect(await fixture.reports.refreshForReportPresentation(), isFalse);
      await fixture.coordinator.reconcile();
      expect(
        fixture.reports.reportRead.origin,
        PositioningReportOrigin.verifiedCache,
      );
      expect(fixture.coordinator.canStartBasic, isFalse);
      expect(fixture.reports.result?.markdown, '正式缓存');
    },
  );

  test('legacy success text cannot prove canonical completion', () async {
    final fixture = _Fixture();
    await fixture.repository.saveInitialReport(
      markdown: '旧 Assistant 内容',
      savedAt: DateTime.utc(2026, 1, 1),
    );
    fixture.remote.unavailable = true;
    await fixture.coordinator.reconcile();
    expect(
      fixture.reports.reportRead.origin,
      PositioningReportOrigin.legacyCache,
    );
    expect(fixture.coordinator.access, InitialPositioningAccess.unavailable);
    expect(fixture.completions, 0);
  });

  test(
    'apply persists exact identity before mutation and verifies formal body',
    () async {
      final fixture = _Fixture();
      fixture.updates.snapshot = _proposal();
      fixture.updates.onApply = () {
        final saved = fixture.store.values.single;
        expect(saved.stage, PositioningUpdateStage.applying);
        expect(saved.proposalId, 'proposal-1');
        expect(saved.proposalVersion, 1);
        expect(saved.etag, '"dcp:proposal-1:1"');
        expect(saved.idempotencyKey, isNotEmpty);
        fixture.remote.report = _report('新报告');
      };
      await fixture.coordinator.reconcile();
      expect(fixture.updates.applied.length, 1);
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.updated,
      );
    },
  );

  test(
    'lost accepted response survives restart and never applies twice',
    () async {
      final fixture = _Fixture();
      fixture.updates.snapshot = _proposal();
      fixture.updates.loseResponse = true;
      fixture.updates.onApply = () => fixture.remote.report = _report('新报告');
      await fixture.coordinator.reconcile();
      final originalKey = fixture.store.values.single.idempotencyKey;
      expect(originalKey, isNotNull);
      fixture.restart();
      await fixture.coordinator.reconcile();
      expect(fixture.updates.applied.length, 1);
      expect(fixture.coordinator.latestUpdate?.idempotencyKey, originalKey);
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.updated,
      );
    },
  );

  test('lost unaccepted response retries with the same key and ETag', () async {
    final fixture = _Fixture();
    fixture.updates.snapshot = _proposal();
    fixture.updates.rejectTransport = true;
    await fixture.coordinator.reconcile();
    fixture.updates.rejectTransport = false;
    fixture.updates.onApply = () => fixture.remote.report = _report('新报告');
    await fixture.coordinator.reconcile();
    expect(fixture.updates.applied.length, 2);
    expect(
      fixture.updates.applied.first.idempotencyKey,
      fixture.updates.applied.last.idempotencyKey,
    );
    expect(
      fixture.updates.applied.first.etag,
      fixture.updates.applied.last.etag,
    );
    expect(
      fixture.coordinator.latestUpdate?.stage,
      PositioningUpdateStage.updated,
    );
  });

  test(
    'applied receipt with old report or cache waits for canonical readback',
    () async {
      final fixture = _Fixture();
      fixture.remote.report = _report('旧报告');
      fixture.updates.snapshot = _proposal();
      await fixture.coordinator.reconcile();
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.awaitingReadback,
      );
      fixture.remote.unavailable = true;
      await fixture.coordinator.reconcile();
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.awaitingReadback,
      );
      fixture.remote.unavailable = false;
      fixture.remote.report = _report('新报告');
      await fixture.coordinator.reconcile();
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.updated,
      );
      expect(fixture.updates.applied.length, 1);
    },
  );

  test(
    'candidate version race blocks application without overwriting report',
    () async {
      final fixture = _Fixture();
      fixture.remote.report = _report('旧报告');
      fixture.updates.snapshot = _proposal();
      fixture.updates.changeBeforeApply = true;
      await fixture.coordinator.reconcile();
      expect(fixture.updates.applied, isEmpty);
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.blocked,
      );
      expect(fixture.reports.result?.markdown, '旧报告');
    },
  );

  test(
    'unverified history and other-owner proposals are never auto-applied',
    () async {
      final fixture = _Fixture();
      fixture.updates.snapshot = _proposal();
      fixture.updates.validSource = false;
      await fixture.coordinator.reconcile();
      expect(fixture.updates.applied, isEmpty);
      fixture.updates.validSource = true;
      fixture.updates.snapshot = _proposal(owner: 'other-owner');
      await fixture.coordinator.reconcile();
      expect(fixture.updates.applied, isEmpty);
    },
  );

  test(
    'only explicit unchanged candidate is no-change, absence is not',
    () async {
      final fixture = _Fixture();
      fixture.updates.snapshot = _proposal(hasChanges: false);
      await fixture.coordinator.reconcile();
      expect(
        fixture.coordinator.latestUpdate?.stage,
        PositioningUpdateStage.noChanges,
      );
      expect(fixture.updates.applied, isEmpty);
    },
  );

  test(
    'scope changes during source verification discard late mutation',
    () async {
      final fixture = _Fixture();
      fixture.updates.snapshot = _proposal();
      fixture.updates.onVerify = () => fixture.current = false;
      await fixture.coordinator.reconcile();
      expect(fixture.updates.applied, isEmpty);
      expect(fixture.store.values, isEmpty);
    },
  );

  test('persistence failure never sends apply', () async {
    final fixture = _Fixture();
    fixture.updates.snapshot = _proposal();
    fixture.store.fail = true;
    await fixture.coordinator.reconcile();
    expect(fixture.updates.applied, isEmpty);
  });

  test(
    'report and operation journals isolate both account and workspace',
    () async {
      final database = AppDatabase();
      final dao = AppPreferencesDao(database);
      final first = PreferencePositioningUpdateStore(
        dao,
        'account-a\u0000workspace-a',
      );
      final second = PreferencePositioningUpdateStore(
        dao,
        'account-b\u0000workspace-a',
      );
      final third = PreferencePositioningUpdateStore(
        dao,
        'account-a\u0000workspace-b',
      );
      await first.save([
        PositioningUpdateCheckpoint(
          runId: 'run-1',
          createdAt: DateTime.utc(2026),
        ),
      ]);
      expect(first.load(), hasLength(1));
      expect(second.load(), isEmpty);
      expect(third.load(), isEmpty);
    },
  );
}

DeepPositioningResult _report(String markdown) => DeepPositioningResult(
  markdown: markdown,
  savedAt: DateTime.utc(2026, 9, 17),
  formalVerified: true,
);

DocumentChangeProposalSnapshot _proposal({
  DocumentProposalState state = DocumentProposalState.ready,
  int version = 1,
  bool hasChanges = true,
  String owner = positioningReportOwner,
  String? runId = 'run-1',
  String? sourceRunId = 'run-1',
}) => DocumentChangeProposalSnapshot(
  etag: '"dcp:proposal-1:$version"',
  proposal: DocumentChangeProposal(
    proposalId: 'proposal-1',
    proposalVersion: version,
    rowVersion: version,
    state: state,
    noteId: owner,
    rawPartRevisionId: 'base-1',
    candidateAvailable: true,
    ownerKind: 'workspace_standard_file',
    hasChanges: hasChanges,
    runId: runId,
    ownerMetadata: {if (sourceRunId != null) 'sourceRunId': sourceRunId},
    appliedPartRevisionId: state == DocumentProposalState.applied
        ? 'revision-2'
        : null,
    appliedOwnerRevisionId: state == DocumentProposalState.applied
        ? 'revision-2'
        : null,
  ),
);

DocumentChangeProposalSnapshot _capturedProposal() =>
    DocumentChangeProposalSnapshot(
      etag: '"dcp:proposal-1:1"',
      proposal: DocumentChangeProposal.fromValue({
        'proposalId': 'proposal-1',
        'proposalVersion': 1,
        'rowVersion': 1,
        'state': 'ready',
        'target': {
          'ownerRef': {
            'kind': 'workspace_standard_file',
            'id': positioningReportOwner,
          },
          'part': 'raw',
          'basePartRevisionId': 'base-1',
          'metadata': {'sourceRunId': 'run-1', 'digitalTwinDraftId': 'draft-1'},
        },
        'run': {'bindingState': 'pending'},
        'candidateAvailable': true,
        'hasChanges': true,
        'createdAt': '2026-09-17T17:33:10.802586Z',
      }),
    );

final class _Fixture {
  _Fixture() {
    repository = PersistentDeepPositioningRepository(
      dao: AppPreferencesDao(AppDatabase()),
      userScope: 'account\u0000workspace',
      remote: remote,
    );
    reports = DeepPositioningController(repository);
    coordinator = _create();
    addTearDown(() {
      coordinator.dispose();
      reports.dispose();
    });
  }
  final remote = _Remote();
  final store = _Store();
  final updates = _Updates();
  late final PersistentDeepPositioningRepository repository;
  late final DeepPositioningController reports;
  late PositioningLifecycleCoordinator coordinator;
  String attemptState = 'not_started';
  bool pending = false;
  bool current = true;
  int completions = 0;

  PositioningLifecycleCoordinator _create() => PositioningLifecycleCoordinator(
    scope: 'account\u0000workspace',
    workspaceId: 'workspace',
    isCurrent: () => current,
    reports: reports,
    updates: updates,
    store: store,
    readAttempt: () async => InitialPositioningAttempt(
      workspaceId: 'workspace',
      state: attemptState,
    ),
    hasLocalPending: () => pending,
    markBasicCompleted: () => completions++,
  );
  void restart() {
    coordinator.dispose();
    coordinator = _create();
  }
}

final class _Remote implements DeepPositioningRemotePort {
  DeepPositioningResult? report;
  bool unavailable = false;
  @override
  Future<DeepPositioningResult?> loadReport() async {
    if (unavailable) throw StateError('offline');
    return report;
  }
}

final class _Store
    implements PositioningUpdateStore, PositioningCompletionStore {
  bool failCompletion = false;
  List<PositioningUpdateCheckpoint> values = [];
  bool fail = false;
  @override
  bool basicCompleted = false;
  @override
  Future<void> recordBasicCompletion() async {
    if (failCompletion) throw StateError('storage unavailable');
    basicCompleted = true;
  }

  @override
  List<PositioningUpdateCheckpoint> load() => values.toList();
  @override
  Future<void> save(List<PositioningUpdateCheckpoint> checkpoints) async {
    if (fail) throw StateError('storage unavailable');
    values = checkpoints.toList();
  }
}

final class _Updates implements PositioningUpdatePort {
  String candidate = '新报告';
  DocumentChangeProposalSnapshot? snapshot;
  final applied = <PositioningUpdateCheckpoint>[];
  bool validSource = true;
  bool loseResponse = false;
  bool rejectTransport = false;
  bool changeBeforeApply = false;
  int latestReads = 0;
  void Function()? onApply;
  void Function()? onVerify;
  @override
  Future<DocumentChangeProposalSnapshot?> latest() async {
    latestReads++;
    if (changeBeforeApply && latestReads > 1) return _proposal(version: 2);
    return snapshot;
  }

  @override
  Future<DocumentChangeProposalSnapshot> get(String proposalId) async =>
      snapshot!;
  @override
  Future<String> runStatus(String runId) async => 'succeeded';
  @override
  Future<bool> verifySource(DocumentChangeProposal proposal) async {
    onVerify?.call();
    return validSource;
  }

  @override
  Future<String> candidateDigest(DocumentChangeProposal proposal) async =>
      positioningContentDigest(candidate);
  @override
  Future<DocumentChangeProposalSnapshot> apply(
    PositioningUpdateCheckpoint checkpoint,
  ) async {
    applied.add(checkpoint);
    if (rejectTransport)
      throw const DocumentChangeProposalException('NETWORK_UNAVAILABLE');
    onApply?.call();
    final current = snapshot!.proposal;
    snapshot = _proposal(
      state: DocumentProposalState.applied,
      runId: current.runId,
      sourceRunId: current.ownerMetadata['sourceRunId'] as String?,
    );
    if (loseResponse)
      throw const DocumentChangeProposalException('NETWORK_UNAVAILABLE');
    return snapshot!;
  }
}
