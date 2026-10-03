import 'dart:async';
import 'dart:typed_data';

import 'package:huahuo_product/huahuo_product.dart';
import 'package:test/test.dart';

void main() {
  test('binds Workspace, resolves draft Proposal and loads review', () async {
    final twin = _TwinRepository();
    final proposals = _ProposalRepository();
    final controller = ProductDigitalTwinController(twin, proposals);

    await controller.bindWorkspace('workspace-1');

    expect(controller.state.status, ProductDigitalTwinStatus.ready);
    expect(controller.state.current?.activeDraft?.id, 'draft-1');
    expect(controller.state.selectedFileId, 'life_experiences');
    expect(controller.state.selectedProposal?.id, 'proposal-1');
    expect(controller.state.review?.candidateMarkdown, '# 新内容');
    expect(
      controller.state.proposalVersions.map((version) => version.version),
      [2, 1],
    );
    expect(proposals.detailCalls, 1);
    expect(proposals.reviewCalls, 1);
  });

  test('Workspace replacement discards an older response', () async {
    final first = CompleterProductResult<ProductDigitalTwinCurrent>();
    final twin = _TwinRepository(firstCurrent: first.future);
    final controller = ProductDigitalTwinController(
      twin,
      _ProposalRepository(),
    );

    final oldLoad = controller.bindWorkspace('workspace-old');
    final newLoad = controller.bindWorkspace('workspace-new');
    first.complete(ProductResult.success(_current('workspace-old')));
    await Future.wait([oldLoad, newLoad]);

    expect(controller.state.workspaceId, 'workspace-new');
    expect(controller.state.current?.workspaceId, 'workspace-new');
  });

  test('executes schedule, revision and terminal confirmation', () async {
    final twin = _TwinRepository();
    final proposals = _ProposalRepository();
    final controller = ProductDigitalTwinController(
      twin,
      proposals,
      delay: (_) async {},
      keyFactory: (action) => 'key-${action.hashCode}',
    );
    await controller.bindWorkspace('workspace-1');

    final scheduled = await controller.saveSchedule(
      const ProductDigitalTwinScheduleDraft(
        enabled: true,
        intervalDays: 14,
        preferredLocalTime: '10:30',
        timezone: 'Asia/Shanghai',
        instruction: '回顾近期资料',
      ),
    );
    controller.toggleHunk('hunk-1');
    final revised = await controller.reviseSelected('调整这一段');
    final confirmed = await controller.confirmReady();

    expect(scheduled, true);
    expect(twin.scheduleUpdates, 1);
    expect(revised, true);
    expect(proposals.reviseCalls, 1);
    expect(confirmed, true);
    expect(twin.confirmCalls, 1);
    expect(controller.state.confirmation?.isTerminal, true);
  });

  test('previews, compares, downloads and restores a version', () async {
    final twin = _TwinRepository();
    final proposals = _ProposalRepository();
    final controller = ProductDigitalTwinController(
      twin,
      proposals,
      delay: (_) async {},
    );
    await controller.bindWorkspace('workspace-1');

    expect(await controller.inspectVersion('version-2'), true);
    expect(await controller.inspectProposalVersion(1), true);
    expect(controller.state.review?.proposalVersion, 1);
    expect(controller.state.canRevise, false);
    expect(await controller.compareVersion('version-2'), true);
    final archive = await controller.downloadVersion('version-2');
    expect(await controller.restoreVersion('version-2'), true);

    expect(controller.state.versionDetail?.profileCount, 1);
    expect(controller.state.comparison?.baseVersion.id, 'version-1');
    expect(archive?.bytes, Uint8List.fromList([0x50, 0x4b, 3, 4]));
    expect(twin.restoreCalls, 1);
    expect(proposals.restoreDetailCalls, 2);
    expect(controller.state.proposalVersions, isNotEmpty);
  });
}

final class CompleterProductResult<T> {
  final _completer = Completer<ProductResult<T>>();
  Future<ProductResult<T>> get future => _completer.future;
  void complete(ProductResult<T> value) => _completer.complete(value);
}

final class _TwinRepository implements ProductDigitalTwinRepository {
  _TwinRepository({this.firstCurrent});
  final Future<ProductResult<ProductDigitalTwinCurrent>>? firstCurrent;
  var currentCalls = 0;
  var scheduleUpdates = 0;
  var confirmCalls = 0;
  var restoreCalls = 0;

  @override
  Future<ProductResult<ProductDigitalTwinCurrent>> current(String workspaceId) {
    currentCalls++;
    if (currentCalls == 1 && firstCurrent != null) return firstCurrent!;
    return Future.value(ProductResult.success(_current(workspaceId)));
  }

  @override
  Future<ProductResult<ProductDigitalTwinSchedule>> schedule(
    String workspaceId,
  ) async => ProductResult.success(_schedule());

  @override
  Future<ProductResult<List<ProductDigitalTwinVersion>>> versions(
    String workspaceId,
  ) async => ProductResult.success([_version(2), _version(1)]);

  @override
  Future<ProductResult<ProductDigitalTwinSchedule>> updateSchedule(
    String workspaceId,
    ProductDigitalTwinScheduleDraft draft, {
    required String idempotencyKey,
  }) async {
    scheduleUpdates++;
    return ProductResult.success(
      ProductDigitalTwinSchedule(
        enabled: draft.enabled,
        intervalDays: draft.intervalDays,
        preferredLocalTime: draft.preferredLocalTime,
        timezone: draft.timezone,
        instruction: draft.instruction,
        sourceScope: 'workspace',
        version: 1,
      ),
    );
  }

  @override
  Future<ProductResult<ProductDigitalTwinConfirmation>> confirm(
    String workspaceId,
    List<ProductDocumentProposal> proposals, {
    required String idempotencyKey,
  }) async {
    confirmCalls++;
    return ProductResult.success(
      ProductDigitalTwinConfirmation(
        id: 'confirmation-1',
        state: 'report_ready',
        outcomes: const [],
        appliedCount: 1,
        failedCount: 0,
        version: _version(2),
      ),
    );
  }

  @override
  Future<ProductResult<ProductDigitalTwinConfirmation>> confirmation(
    String workspaceId,
    String confirmationId,
  ) async => throw StateError('terminal confirmation should not poll');

  @override
  Future<ProductResult<ProductDigitalTwinVersionDetail>> version(
    String workspaceId,
    String versionId,
  ) async => ProductResult.success(
    ProductDigitalTwinVersionDetail(
      version: _version(2),
      operationKey: 'confirm',
      rendererVersion: 'profile_projection.v1',
      profileCount: 1,
      hasPositioning: true,
      proposalResultCount: 1,
    ),
  );

  @override
  Future<ProductResult<List<ProductDigitalTwinFile>>> preview(
    String workspaceId,
    String versionId,
  ) async => ProductResult.success([_file()]);

  @override
  Future<ProductResult<ProductDigitalTwinComparison>> compare(
    String workspaceId, {
    required String baseVersionId,
    required String versionId,
  }) async => ProductResult.success(
    ProductDigitalTwinComparison(
      baseVersion: _version(1),
      version: _version(2),
      files: const [],
    ),
  );

  @override
  Future<ProductResult<Uint8List>> download(
    String workspaceId,
    String versionId,
  ) async => ProductResult.success(Uint8List.fromList([0x50, 0x4b, 3, 4]));

  @override
  Future<ProductResult<ProductDigitalTwinRestore>> restore(
    String workspaceId,
    String versionId, {
    required String idempotencyKey,
  }) async {
    restoreCalls++;
    return ProductResult.success(
      ProductDigitalTwinRestore(
        taskId: 'restore-1',
        versionId: versionId,
        state: 'proposals_created',
        proposalIds: const ['proposal-2'],
      ),
    );
  }
}

final class _ProposalRepository implements ProductDocumentProposalsRepository {
  var detailCalls = 0;
  var restoreDetailCalls = 0;
  var reviewCalls = 0;
  var reviseCalls = 0;

  @override
  Future<ProductResult<ProductDocumentProposal>> detail({
    required String workspaceId,
    required String proposalId,
  }) async {
    detailCalls++;
    if (proposalId == 'proposal-2') {
      restoreDetailCalls++;
      return ProductResult.success(
        _proposal(
          id: proposalId,
          version: 1,
          lifecycle: restoreDetailCalls == 1
              ? ProductProposalLifecycle.generating
              : ProductProposalLifecycle.ready,
        ),
      );
    }
    return ProductResult.success(_proposal());
  }

  @override
  Future<ProductResult<ProductProposalReview>> review({
    required String workspaceId,
    required String proposalId,
    int? proposalVersion,
  }) async {
    reviewCalls++;
    return ProductResult.success(_review(version: proposalVersion ?? 2));
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> revise({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String instruction,
    required List<ProductProposalHunkSelection> selectedHunks,
    required String idempotencyKey,
  }) async {
    reviseCalls++;
    return ProductResult.success(_proposal(version: 3));
  }

  ProductResult<T> unavailable<T>() =>
      const ProductResult.failure(code: 'UNUSED', message: 'unused');
  @override
  Future<ProductResult<ProductDocumentProposal>> apply({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => unavailable();
  @override
  Future<ProductResult<ProductDocumentProposal>> cancel({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => unavailable();
  @override
  Future<ProductResult<ProductDocumentProposal>> createForCreation({
    required String workspaceId,
    required ProductCreationDocument creation,
    required String instruction,
    required String idempotencyKey,
  }) async => unavailable();
  @override
  Future<ProductResult<ProductDocumentProposalPage>> list({
    required String workspaceId,
    String? ownerKind,
    String? ownerId,
    String? cursor,
  }) async => unavailable();
  @override
  Future<ProductResult<ProductDocumentProposal>> rebase({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => unavailable();
  @override
  Future<ProductResult<ProductDocumentProposal>> reject({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => unavailable();
  @override
  Future<ProductResult<List<ProductProposalVersion>>> versions({
    required String workspaceId,
    required String proposalId,
  }) async => ProductResult.success([
    _proposalVersion(proposalId, 2),
    _proposalVersion(proposalId, 1),
  ]);
}

ProductDigitalTwinCurrent _current(String workspaceId) =>
    ProductDigitalTwinCurrent(
      workspaceId: workspaceId,
      agentProfileId: 'data_body',
      state: 'pending_review',
      level: const ProductDigitalTwinLevel(
        value: 2,
        name: '成长中',
        completionPercent: 60,
        scoringModel: 'positioning.v1',
      ),
      pendingReviewCount: 1,
      activeDraft: ProductDigitalTwinDraft(
        id: 'draft-1',
        revision: 4,
        etag: 'sha256:draft',
        state: 'pending_review',
        items: [
          ProductDigitalTwinDraftItem(
            proposalId: 'proposal-1',
            proposalVersion: 2,
            etag: '"dcp:proposal-1:3"',
            lifecycle: ProductProposalLifecycle.ready,
            fileIds: const ['life_experiences'],
            hasChanges: true,
          ),
        ],
      ),
      files: [_file()],
      currentVersion: _version(2),
      updatedAt: DateTime.utc(2026, 9, 3),
    );

ProductDigitalTwinFile _file() => ProductDigitalTwinFile(
  id: 'life_experiences',
  name: '人生经历',
  exists: true,
  markdown: '# 经历',
  conclusions: const [],
  pendingCount: 1,
  pendingProposalIds: const ['proposal-1'],
);

ProductDigitalTwinVersion _version(int number) => ProductDigitalTwinVersion(
  id: 'version-$number',
  number: number,
  label: '版本 $number',
  workspaceVersion: number,
  completionPercent: 60,
  scoringModel: 'positioning.v1',
  createdAt: DateTime.utc(2026, 9, number),
);

ProductDigitalTwinSchedule _schedule() => const ProductDigitalTwinSchedule(
  enabled: false,
  intervalDays: 7,
  preferredLocalTime: '09:00',
  timezone: 'Asia/Shanghai',
  instruction: '回顾最近资料',
  sourceScope: 'workspace',
  version: 0,
);

ProductDocumentProposal _proposal({
  String id = 'proposal-1',
  int version = 2,
  ProductProposalLifecycle lifecycle = ProductProposalLifecycle.ready,
}) => ProductDocumentProposal(
  id: id,
  version: version,
  rowVersion: 3,
  lifecycle: lifecycle,
  ownerKind: 'profile_conclusion',
  ownerId: 'conclusion-1',
  part: 'raw',
  basePartRevisionId: 'revision-1',
  baseHash: 'sha256:base',
  candidateAvailable: true,
  hasChanges: true,
  createdAt: DateTime.utc(2026, 9, 3),
  updatedAt: DateTime.utc(2026, 9, 3),
  etag: '"dcp:$id:3"',
);

ProductProposalVersion _proposalVersion(String proposalId, int version) =>
    ProductProposalVersion(
      proposalId: proposalId,
      version: version,
      baseHash: 'sha256:base-$version',
      candidateHash: 'sha256:candidate-$version',
      candidateSizeBytes: 20,
      diffBundleId: 'bundle-$version',
      createdAt: DateTime.utc(2026, 9, version),
    );

ProductProposalReview _review({int version = 2}) => ProductProposalReview(
  proposalId: 'proposal-1',
  proposalVersion: version,
  candidateHash: 'sha256:candidate',
  candidateMarkdown: '# 新内容',
  summary: const ProductProposalDiffSummary(
    hunks: 1,
    insertedLines: 1,
    deletedLines: 1,
    changedLines: 2,
    hasChanges: true,
  ),
  hunks: [
    ProductProposalDiffHunk(
      id: 'hunk-1',
      oldStart: 1,
      oldLines: 1,
      newStart: 1,
      newLines: 1,
      changes: const [
        ProductProposalDiffChange(operation: 'delete', text: '旧内容'),
        ProductProposalDiffChange(operation: 'insert', text: '新内容'),
      ],
    ),
  ],
  diffBundleId: 'bundle-1',
);
