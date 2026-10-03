import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/proposals/widgets/desktop_document_proposals_workspace.dart';
import 'package:huahuo_product/huahuo_product.dart';

void main() {
  testWidgets('reviews, selects a hunk, revises, and applies', (tester) async {
    final repository = _Repository()
      ..listResults.add(ProductResult.success(_page([_proposal(etag: null)])))
      ..detailResults.add(ProductResult.success(_proposal()))
      ..reviewResults.addAll([
        ProductResult.success(_review()),
        ProductResult.success(_review(version: 2, markdown: '# 修订正文')),
      ])
      ..reviseResults.add(ProductResult.success(_proposal(rowVersion: 2)))
      ..applyResults.add(
        ProductResult.success(
          _proposal(lifecycle: ProductProposalLifecycle.applied, rowVersion: 3),
        ),
      );
    await _pump(tester, repository, creation: _creation());

    await tester.tap(find.byKey(const ValueKey('proposal-item-proposal-1')));
    await tester.pumpAndSettle();
    expect(find.text('# 候选正文'), findsOneWidget);
    expect(find.text('+ 新正文'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('proposal-hunk-hunk-1')));
    await tester.tap(find.byKey(const ValueKey('proposal-revise')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('proposal-instruction')),
      '只改选中的段落',
    );
    await tester.tap(
      find.byKey(const ValueKey('proposal-instruction-confirm')),
    );
    await tester.pumpAndSettle();

    expect(repository.reviseInstructions.single, '只改选中的段落');
    expect(repository.reviseSelections.single.single.hunkId, 'hunk-1');
    expect(find.text('# 修订正文'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('proposal-apply')));
    await tester.pumpAndSettle();
    expect(find.text('已应用'), findsOneWidget);
  });

  testWidgets('creates, inspects a version, and rejects', (tester) async {
    final repository = _Repository()
      ..listResults.add(ProductResult.success(_page([])))
      ..createResults.add(ProductResult.success(_proposal()))
      ..reviewResults.addAll([
        ProductResult.success(_review()),
        ProductResult.success(_review(version: 1, markdown: '# 历史候选')),
      ])
      ..versionResults.add(
        ProductResult.success([
          ProductProposalVersion(
            proposalId: 'proposal-1',
            version: 1,
            baseHash: _hash,
            candidateHash: _hash,
            candidateSizeBytes: 12,
            diffBundleId: 'bundle-1',
            createdAt: DateTime.utc(2026, 9, 3),
          ),
        ]),
      )
      ..rejectResults.add(
        ProductResult.success(
          _proposal(
            lifecycle: ProductProposalLifecycle.rejected,
            rowVersion: 2,
          ),
        ),
      );
    await _pump(tester, repository, creation: _creation());

    await tester.tap(find.byKey(const ValueKey('proposal-empty-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('proposal-instruction')),
      '增强开头吸引力',
    );
    await tester.tap(
      find.byKey(const ValueKey('proposal-instruction-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repository.createInstructions.single, '增强开头吸引力');

    await tester.tap(find.byKey(const ValueKey('proposal-versions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('proposal-version-1')));
    await tester.pumpAndSettle();
    expect(find.text('# 历史候选'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('proposal-reject')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('proposal-reject-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('已拒绝'), findsOneWidget);
  });

  testWidgets('cancels generation and rebases a stale proposal', (
    tester,
  ) async {
    final generating = _Repository()
      ..listResults.add(
        ProductResult.success(
          _page([
            _proposal(
              lifecycle: ProductProposalLifecycle.generating,
              etag: null,
            ),
          ]),
        ),
      )
      ..detailResults.add(
        ProductResult.success(
          _proposal(lifecycle: ProductProposalLifecycle.generating),
        ),
      )
      ..cancelResults.add(
        ProductResult.success(
          _proposal(
            lifecycle: ProductProposalLifecycle.rejected,
            rowVersion: 2,
          ),
        ),
      );
    await _pump(tester, generating, creation: _creation());
    await tester.tap(find.byKey(const ValueKey('proposal-item-proposal-1')));
    await tester.pump();
    expect(find.byKey(const ValueKey('proposal-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('proposal-cancel')));
    await tester.pumpAndSettle();
    expect(generating.cancelCount, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(generating.detailResults, isEmpty);

    final stale = _Repository()
      ..listResults.add(
        ProductResult.success(
          _page([
            _proposal(lifecycle: ProductProposalLifecycle.stale, etag: null),
          ]),
        ),
      )
      ..detailResults.add(
        ProductResult.success(
          _proposal(lifecycle: ProductProposalLifecycle.stale),
        ),
      )
      ..rebaseResults.add(ProductResult.success(_proposal(rowVersion: 2)))
      ..reviewResults.add(ProductResult.success(_review(version: 2)));
    await _pump(tester, stale, creation: _creation());
    await tester.tap(find.byKey(const ValueKey('proposal-item-proposal-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('proposal-rebase')));
    await tester.pumpAndSettle();
    expect(stale.rebaseCount, 1);
    expect(find.byKey(const ValueKey('proposal-apply')), findsOneWidget);
  });

  testWidgets('retries list failure and opens Creation without a target', (
    tester,
  ) async {
    final repository = _Repository()
      ..listResults.addAll([
        const ProductResult.failure(
          code: 'OFFLINE',
          message: '网络不可用',
          retryable: true,
        ),
        ProductResult.success(_page([])),
      ]);
    var openedCreations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopDocumentProposalsWorkspace(
            workspaceId: 'workspace-1',
            repository: repository,
            initialCreation: null,
            onOpenCreations: () => openedCreations++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('网络不可用'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('proposal-retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('proposal-open-creations')));
    expect(openedCreations, 1);
  });

  testWidgets('compact back returns to the preserved list', (tester) async {
    tester.view.physicalSize = const Size(760, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository()
      ..listResults.add(ProductResult.success(_page([_proposal(etag: null)])))
      ..detailResults.add(ProductResult.success(_proposal()))
      ..reviewResults.add(ProductResult.success(_review()));
    await _pump(tester, repository, creation: _creation());

    await tester.tap(find.byKey(const ValueKey('proposal-item-proposal-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proposal-back')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('proposal-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('proposal-item-proposal-1')),
      findsOneWidget,
    );
  });
}

Future<void> _pump(
  WidgetTester tester,
  ProductDocumentProposalsRepository repository, {
  ProductCreationDocument? creation,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DesktopDocumentProposalsWorkspace(
          workspaceId: 'workspace-1',
          repository: repository,
          initialCreation: creation,
          onOpenCreations: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _hash =
    'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

ProductDocumentProposal _proposal({
  ProductProposalLifecycle lifecycle = ProductProposalLifecycle.ready,
  int rowVersion = 1,
  String? etag = 'present',
}) => ProductDocumentProposal(
  id: 'proposal-1',
  version: rowVersion,
  rowVersion: rowVersion,
  lifecycle: lifecycle,
  ownerKind: 'creation',
  ownerId: 'creation-1',
  part: 'raw',
  basePartRevisionId: 'raw-1',
  baseHash: _hash,
  candidateAvailable: lifecycle == ProductProposalLifecycle.ready,
  hasChanges: true,
  createdAt: DateTime.utc(2026, 9, 3),
  updatedAt: DateTime.utc(2026, 9, 3, 1),
  etag: etag == null ? null : '"dcp:proposal-1:$rowVersion"',
);

ProductDocumentProposalPage _page(List<ProductDocumentProposal> items) =>
    ProductDocumentProposalPage(items: items);

ProductProposalReview _review({int version = 1, String markdown = '# 候选正文'}) =>
    ProductProposalReview(
      proposalId: 'proposal-1',
      proposalVersion: version,
      candidateHash: _hash,
      candidateMarkdown: markdown,
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
            ProductProposalDiffChange(operation: 'delete', text: '旧正文'),
            ProductProposalDiffChange(operation: 'insert', text: '新正文'),
          ],
        ),
      ],
      diffBundleId: 'bundle-1',
    );

ProductCreationDocument _creation() => ProductCreationDocument(
  summary: ProductCreationSummary(
    id: 'creation-1',
    title: '第一篇',
    lifecycle: 'active',
    revisionId: 'creation-revision-1',
    revision: 1,
    partRevisionIds: const {'raw': 'raw-1'},
    etag: 'creation-etag',
  ),
  rawMarkdown: '# 初稿',
  rawPartRevisionId: 'raw-1',
  rawPartEtag: 'raw-etag',
);

final class _Repository implements ProductDocumentProposalsRepository {
  final listResults = <ProductResult<ProductDocumentProposalPage>>[];
  final detailResults = <ProductResult<ProductDocumentProposal>>[];
  final createResults = <ProductResult<ProductDocumentProposal>>[];
  final reviewResults = <ProductResult<ProductProposalReview>>[];
  final versionResults = <ProductResult<List<ProductProposalVersion>>>[];
  final applyResults = <ProductResult<ProductDocumentProposal>>[];
  final rejectResults = <ProductResult<ProductDocumentProposal>>[];
  final cancelResults = <ProductResult<ProductDocumentProposal>>[];
  final rebaseResults = <ProductResult<ProductDocumentProposal>>[];
  final reviseResults = <ProductResult<ProductDocumentProposal>>[];
  final createInstructions = <String>[];
  final reviseInstructions = <String>[];
  final reviseSelections = <List<ProductProposalHunkSelection>>[];
  int cancelCount = 0;
  int rebaseCount = 0;

  @override
  Future<ProductResult<ProductDocumentProposal>> apply({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => applyResults.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposal>> cancel({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async {
    cancelCount++;
    return cancelResults.removeAt(0);
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> createForCreation({
    required String workspaceId,
    required ProductCreationDocument creation,
    required String instruction,
    required String idempotencyKey,
  }) async {
    createInstructions.add(instruction);
    return createResults.removeAt(0);
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> detail({
    required String workspaceId,
    required String proposalId,
  }) async => detailResults.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposalPage>> list({
    required String workspaceId,
    String? ownerKind,
    String? ownerId,
    String? cursor,
  }) async => listResults.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposal>> rebase({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async {
    rebaseCount++;
    return rebaseResults.removeAt(0);
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> reject({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => rejectResults.removeAt(0);

  @override
  Future<ProductResult<ProductProposalReview>> review({
    required String workspaceId,
    required String proposalId,
    int? proposalVersion,
  }) async => reviewResults.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposal>> revise({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String instruction,
    required List<ProductProposalHunkSelection> selectedHunks,
    required String idempotencyKey,
  }) async {
    reviseInstructions.add(instruction);
    reviseSelections.add(selectedHunks);
    return reviseResults.removeAt(0);
  }

  @override
  Future<ProductResult<List<ProductProposalVersion>>> versions({
    required String workspaceId,
    required String proposalId,
  }) async => versionResults.removeAt(0);
}
