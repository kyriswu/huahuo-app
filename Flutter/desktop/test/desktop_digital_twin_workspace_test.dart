import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/digital_twin/widgets/desktop_digital_twin_workspace.dart';
import 'package:huahuo_product/huahuo_product.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows an explicit no-Workspace state', (tester) async {
    await tester.pumpWidget(
      _app(
        const DesktopDigitalTwinWorkspace(
          workspaceId: null,
          repository: UnavailableProductDigitalTwinRepository(),
          proposalsRepository: UnavailableProductDocumentProposalsRepository(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Workspace 尚未就绪'), findsOneWidget);
  });

  testWidgets('loads files and saves a validated schedule', (tester) async {
    final twin = _TwinRepository();
    await _pump(tester, twin: twin);

    expect(find.text('人生经历'), findsWidgets);
    expect(find.textContaining('# 经历'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('digital-twin-schedule')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用定期更新'));
    await tester.enterText(
      find.byKey(const ValueKey('digital-twin-schedule-instruction')),
      '回顾近期资料',
    );
    await tester.tap(find.byKey(const ValueKey('digital-twin-schedule-save')));
    await tester.pumpAndSettle();

    expect(twin.scheduleUpdates, 1);
    expect(find.text('定期计划已保存'), findsOneWidget);
  });

  testWidgets('reviews a hunk, revises and confirms proposals', (tester) async {
    final twin = _TwinRepository();
    final proposals = _ProposalRepository();
    await _pump(tester, twin: twin, proposals: proposals);

    await tester.tap(find.text('审阅'));
    await tester.pumpAndSettle();
    expect(find.text('# 新内容'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('digital-twin-proposal-version')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('v1').last);
    await tester.pumpAndSettle();
    expect(find.text('# 历史内容'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('digital-twin-revise')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(
      find.byKey(const ValueKey('digital-twin-proposal-version')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('v2 · 当前').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('digital-twin-hunk-hunk-1')));
    await tester.tap(find.byKey(const ValueKey('digital-twin-revise')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('digital-twin-revise-instruction')),
      '调整这一段',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('digital-twin-revise-submit')));
    await tester.pumpAndSettle();
    expect(proposals.reviseCalls, 1);

    await tester.tap(find.byKey(const ValueKey('digital-twin-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('digital-twin-confirm-submit')));
    await tester.pumpAndSettle();
    expect(twin.confirmCalls, 1);
    expect(find.text('确认报告已就绪'), findsOneWidget);
  });

  testWidgets(
    'previews, compares and exposes restore/version archive actions',
    (tester) async {
      final twin = _TwinRepository();
      await _pump(tester, twin: twin);
      await tester.tap(find.text('版本'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('版本操作').first);
      await tester.pumpAndSettle();
      expect(find.text('下载 ZIP'), findsOneWidget);
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(find.text('档案结论 1 项'), findsOneWidget);

      await tester.tap(find.byTooltip('版本操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('与前版比较'));
      await tester.pumpAndSettle();
      expect(find.text('版本 1 → 版本 2'), findsOneWidget);

      await tester.tap(find.byTooltip('版本操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成恢复提案'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('digital-twin-restore-submit')),
      );
      await tester.pumpAndSettle();
      expect(twin.restoreCalls, 1);
    },
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required _TwinRepository twin,
  _ProposalRepository? proposals,
}) async {
  tester.view.physicalSize = const Size(1280, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _app(
      DesktopDigitalTwinWorkspace(
        workspaceId: 'workspace-1',
        repository: twin,
        proposalsRepository: proposals ?? _ProposalRepository(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

final class _TwinRepository implements ProductDigitalTwinRepository {
  var scheduleUpdates = 0;
  var confirmCalls = 0;
  var restoreCalls = 0;
  @override
  Future<ProductResult<ProductDigitalTwinCurrent>> current(
    String workspaceId,
  ) async => ProductResult.success(_current(workspaceId));
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
  var reviseCalls = 0;
  @override
  Future<ProductResult<ProductDocumentProposal>> detail({
    required String workspaceId,
    required String proposalId,
  }) async => ProductResult.success(_proposal(id: proposalId));
  @override
  Future<ProductResult<ProductProposalReview>> review({
    required String workspaceId,
    required String proposalId,
    int? proposalVersion,
  }) async => ProductResult.success(_review(version: proposalVersion ?? 2));
  @override
  Future<ProductResult<ProductDocumentProposal>> revise({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String instruction,
    required List<ProductProposalHunkSelection> selectedHunks,
    required String idempotencyKey,
  }) async {
    reviseCalls++;
    return ProductResult.success(_proposal());
  }

  ProductResult<T> _unused<T>() =>
      const ProductResult.failure(code: 'UNUSED', message: 'unused');
  @override
  Future<ProductResult<ProductDocumentProposal>> apply({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unused();
  @override
  Future<ProductResult<ProductDocumentProposal>> cancel({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unused();
  @override
  Future<ProductResult<ProductDocumentProposal>> createForCreation({
    required String workspaceId,
    required ProductCreationDocument creation,
    required String instruction,
    required String idempotencyKey,
  }) async => _unused();
  @override
  Future<ProductResult<ProductDocumentProposalPage>> list({
    required String workspaceId,
    String? ownerKind,
    String? ownerId,
    String? cursor,
  }) async => _unused();
  @override
  Future<ProductResult<ProductDocumentProposal>> rebase({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unused();
  @override
  Future<ProductResult<ProductDocumentProposal>> reject({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unused();
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

ProductDocumentProposal _proposal({String id = 'proposal-1'}) =>
    ProductDocumentProposal(
      id: id,
      version: 2,
      rowVersion: 3,
      lifecycle: ProductProposalLifecycle.ready,
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
  candidateMarkdown: version == 2 ? '# 新内容' : '# 历史内容',
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
