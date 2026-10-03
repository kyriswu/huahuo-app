import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:test/test.dart';

void main() {
  test('polls generation to a complete immutable review', () async {
    final repository = _Repository()
      ..lists.add(
        Future.value(
          ProductResult.success(
            _page([_proposal(ProductProposalLifecycle.generating, etag: null)]),
          ),
        ),
      )
      ..details.addAll([
        Future.value(
          ProductResult.success(_proposal(ProductProposalLifecycle.generating)),
        ),
        Future.value(
          ProductResult.success(
            _proposal(ProductProposalLifecycle.ready, rowVersion: 2),
          ),
        ),
      ])
      ..reviews.add(ProductResult.success(_review()));
    final controller = ProductDocumentProposalsController(
      repository,
      delay: (_) async {},
      maxPollAttempts: 2,
    );
    addTearDown(controller.dispose);

    await controller.bindWorkspace('workspace-1');
    await controller.select('proposal-1');

    expect(controller.state.detailStatus, ProductProposalDetailStatus.ready);
    expect(controller.state.pollAttempt, 1);
    expect(controller.state.review?.candidateMarkdown, '# 新正文');
    expect(controller.state.review?.hunks.single.id, 'hunk-1');
    expect(controller.state.selected?.etag, _etag(2));
  });

  test('recognizes no-change and bounded-poll failure states', () async {
    final noChangeRepository = _Repository()
      ..lists.add(
        Future.value(
          ProductResult.success(
            _page([_proposal(ProductProposalLifecycle.ready, etag: null)]),
          ),
        ),
      )
      ..details.add(
        Future.value(
          ProductResult.success(
            _proposal(ProductProposalLifecycle.ready, hasChanges: false),
          ),
        ),
      );
    final noChange = ProductDocumentProposalsController(noChangeRepository);
    addTearDown(noChange.dispose);
    await noChange.bindWorkspace('workspace-1');
    await noChange.select('proposal-1');
    expect(noChange.state.detailStatus, ProductProposalDetailStatus.noChanges);

    final pollingRepository = _Repository()
      ..lists.add(
        Future.value(
          ProductResult.success(
            _page([_proposal(ProductProposalLifecycle.generating, etag: null)]),
          ),
        ),
      )
      ..details.addAll([
        Future.value(
          ProductResult.success(_proposal(ProductProposalLifecycle.generating)),
        ),
        Future.value(
          ProductResult.success(
            _proposal(ProductProposalLifecycle.generating, rowVersion: 2),
          ),
        ),
      ]);
    final polling = ProductDocumentProposalsController(
      pollingRepository,
      delay: (_) async {},
      maxPollAttempts: 1,
    );
    addTearDown(polling.dispose);
    await polling.bindWorkspace('workspace-1');
    await polling.select('proposal-1');
    expect(polling.state.errorCode, 'DOCUMENT_PROPOSAL_POLL_TIMEOUT');
    expect(polling.state.retryable, isTrue);
  });

  test('create and apply retries reuse stable intent keys', () async {
    final repository = _Repository()
      ..lists.add(Future.value(ProductResult.success(_page([]))))
      ..creates.addAll([
        const ProductResult.failure(
          code: 'OFFLINE',
          message: '网络不可用',
          retryable: true,
        ),
        ProductResult.success(_proposal(ProductProposalLifecycle.ready)),
      ])
      ..reviews.add(ProductResult.success(_review()))
      ..applies.addAll([
        const ProductResult.failure(
          code: 'OFFLINE',
          message: '网络不可用',
          retryable: true,
        ),
        ProductResult.success(
          _proposal(ProductProposalLifecycle.applied, rowVersion: 3),
        ),
      ]);
    var sequence = 0;
    final controller = ProductDocumentProposalsController(
      repository,
      keyFactory: (_) => 'key-${++sequence}',
    );
    addTearDown(controller.dispose);
    await controller.bindWorkspace('workspace-1', creation: _creation());

    expect(await controller.create('优化表达'), isFalse);
    expect(await controller.create('优化表达'), isTrue);
    expect(repository.createKeys, ['key-1', 'key-1']);

    expect(await controller.apply(), isFalse);
    expect(await controller.apply(), isTrue);
    expect(repository.applyKeys, ['key-2', 'key-2']);
    expect(
      controller.state.selected?.lifecycle,
      ProductProposalLifecycle.applied,
    );
  });

  test(
    'supports revise selections, stale rebase, reject, and cancel',
    () async {
      final repository = _Repository()
        ..lists.add(
          Future.value(
            ProductResult.success(
              _page([_proposal(ProductProposalLifecycle.stale, etag: null)]),
            ),
          ),
        )
        ..details.add(
          Future.value(
            ProductResult.success(_proposal(ProductProposalLifecycle.stale)),
          ),
        )
        ..rebases.add(
          ProductResult.success(
            _proposal(ProductProposalLifecycle.ready, rowVersion: 2),
          ),
        )
        ..revisions.add(
          ProductResult.success(
            _proposal(ProductProposalLifecycle.ready, rowVersion: 3),
          ),
        )
        ..rejects.add(
          ProductResult.success(
            _proposal(ProductProposalLifecycle.rejected, rowVersion: 4),
          ),
        )
        ..reviews.addAll([
          ProductResult.success(_review()),
          ProductResult.success(_review(version: 2)),
        ]);
      final controller = ProductDocumentProposalsController(repository);
      addTearDown(controller.dispose);
      await controller.bindWorkspace('workspace-1');
      await controller.select('proposal-1');

      expect(await controller.rebase(), isTrue);
      controller.toggleHunk('hunk-1');
      expect(await controller.revise('只调整选中段落'), isTrue);
      expect(repository.revisionSelections.single.single.hunkId, 'hunk-1');
      expect(await controller.reject(), isTrue);

      final cancelRepository = _Repository()
        ..lists.add(
          Future.value(
            ProductResult.success(
              _page([
                _proposal(ProductProposalLifecycle.generating, etag: null),
              ]),
            ),
          ),
        )
        ..details.add(
          Future.value(
            ProductResult.success(
              _proposal(ProductProposalLifecycle.generating),
            ),
          ),
        )
        ..cancels.add(
          ProductResult.success(
            _proposal(ProductProposalLifecycle.rejected, rowVersion: 2),
          ),
        );
      final cancel = ProductDocumentProposalsController(
        cancelRepository,
        maxPollAttempts: 0,
      );
      addTearDown(cancel.dispose);
      await cancel.bindWorkspace('workspace-1');
      await cancel.select('proposal-1');
      expect(await cancel.cancel(), isTrue);
    },
  );

  test('suppresses an old Workspace list response after replacement', () async {
    final first = Completer<ProductResult<ProductDocumentProposalPage>>();
    final second = Completer<ProductResult<ProductDocumentProposalPage>>();
    final repository = _Repository()
      ..lists.addAll([first.future, second.future]);
    final controller = ProductDocumentProposalsController(repository);
    addTearDown(controller.dispose);

    final oldLoad = controller.bindWorkspace('workspace-1');
    final replacement = controller.bindWorkspace('workspace-2');
    second.complete(ProductResult.success(_page([])));
    await replacement;
    first.complete(
      ProductResult.success(
        _page([_proposal(ProductProposalLifecycle.ready, etag: null)]),
      ),
    );
    await oldLoad;

    expect(controller.state.workspaceId, 'workspace-2');
    expect(controller.state.status, ProductProposalsStatus.empty);
  });

  test('remote review verifies candidate bytes and SHA-256', () async {
    final valid = RemoteProductDocumentProposalsRepository(
      _api(
        _QueueTransport([
          _success(_diff()),
          _success(_candidate()),
          _success(_versions()),
        ]),
      ),
    );
    final review = await valid.review(
      workspaceId: 'workspace-1',
      proposalId: 'proposal-1',
    );
    expect(review.isSuccess, isTrue);
    expect(review.data?.candidateMarkdown, 'abc');
    expect(review.data?.diffBundleId, 'bundle-1');

    final invalid = RemoteProductDocumentProposalsRepository(
      _api(
        _QueueTransport([
          _success(_diff()),
          _success(_candidate(text: 'abd')),
          _success(_versions()),
        ]),
      ),
    );
    final corrupted = await invalid.review(
      workspaceId: 'workspace-1',
      proposalId: 'proposal-1',
    );
    expect(corrupted.code, 'DOCUMENT_PROPOSAL_CANDIDATE_INTEGRITY');
  });
}

const _hashA =
    'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hashAbc =
    'sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

String _etag(int rowVersion) => '"dcp:proposal-1:$rowVersion"';

ProductDocumentProposal _proposal(
  ProductProposalLifecycle lifecycle, {
  int rowVersion = 1,
  bool? hasChanges = true,
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
  baseHash: _hashA,
  candidateAvailable: lifecycle == ProductProposalLifecycle.ready,
  hasChanges: hasChanges,
  createdAt: DateTime.utc(2026, 9, 3),
  updatedAt: DateTime.utc(2026, 9, 3, 1),
  etag: etag == null ? null : _etag(rowVersion),
);

ProductDocumentProposalPage _page(List<ProductDocumentProposal> items) =>
    ProductDocumentProposalPage(items: items);

ProductProposalReview _review({int version = 1}) => ProductProposalReview(
  proposalId: 'proposal-1',
  proposalVersion: version,
  candidateHash: _hashAbc,
  candidateMarkdown: '# 新正文',
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
  rawPartEtag: 'raw-etag-1',
);

final class _Repository implements ProductDocumentProposalsRepository {
  final lists = <Future<ProductResult<ProductDocumentProposalPage>>>[];
  final details = <Future<ProductResult<ProductDocumentProposal>>>[];
  final creates = <ProductResult<ProductDocumentProposal>>[];
  final reviews = <ProductResult<ProductProposalReview>>[];
  final versionResults = <ProductResult<List<ProductProposalVersion>>>[];
  final applies = <ProductResult<ProductDocumentProposal>>[];
  final rejects = <ProductResult<ProductDocumentProposal>>[];
  final cancels = <ProductResult<ProductDocumentProposal>>[];
  final rebases = <ProductResult<ProductDocumentProposal>>[];
  final revisions = <ProductResult<ProductDocumentProposal>>[];
  final createKeys = <String>[];
  final applyKeys = <String>[];
  final revisionSelections = <List<ProductProposalHunkSelection>>[];

  @override
  Future<ProductResult<ProductDocumentProposal>> apply({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async {
    applyKeys.add(idempotencyKey);
    return applies.removeAt(0);
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> cancel({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => cancels.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposal>> createForCreation({
    required String workspaceId,
    required ProductCreationDocument creation,
    required String instruction,
    required String idempotencyKey,
  }) async {
    createKeys.add(idempotencyKey);
    return creates.removeAt(0);
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> detail({
    required String workspaceId,
    required String proposalId,
  }) => details.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposalPage>> list({
    required String workspaceId,
    String? ownerKind,
    String? ownerId,
    String? cursor,
  }) => lists.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposal>> rebase({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => rebases.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposal>> reject({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => rejects.removeAt(0);

  @override
  Future<ProductResult<ProductProposalReview>> review({
    required String workspaceId,
    required String proposalId,
    int? proposalVersion,
  }) async => reviews.removeAt(0);

  @override
  Future<ProductResult<ProductDocumentProposal>> revise({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String instruction,
    required List<ProductProposalHunkSelection> selectedHunks,
    required String idempotencyKey,
  }) async {
    revisionSelections.add(selectedHunks);
    return revisions.removeAt(0);
  }

  @override
  Future<ProductResult<List<ProductProposalVersion>>> versions({
    required String workspaceId,
    required String proposalId,
  }) async => versionResults.removeAt(0);
}

Map<String, Object?> _diff() => <String, Object?>{
  'schema': 'huahuo.document-diff.v1',
  'proposalId': 'proposal-1',
  'proposalVersion': 1,
  'base': <String, Object?>{'partRevisionId': 'raw-1', 'hash': _hashA},
  'candidate': <String, Object?>{'hash': _hashAbc, 'sizeBytes': 3},
  'algorithm': <String, Object?>{
    'name': 'myers',
    'version': '1',
    'granularity': 'line',
    'fallbackUsed': false,
  },
  'summary': <String, Object?>{
    'hunks': 0,
    'insertedLines': 0,
    'deletedLines': 0,
    'changedLines': 0,
    'hasChanges': true,
  },
  'items': <Object?>[],
};

Map<String, Object?> _candidate({String text = 'abc'}) => <String, Object?>{
  'schema': 'huahuo.document-candidate-chunk.v1',
  'proposalId': 'proposal-1',
  'proposalVersion': 1,
  'candidateHash': _hashAbc,
  'offsetBytes': 0,
  'text': text,
};

Map<String, Object?> _versions() => <String, Object?>{
  'items': <Object?>[
    <String, Object?>{
      'proposalId': 'proposal-1',
      'proposalVersion': 1,
      'baseHash': _hashA,
      'candidateHash': _hashAbc,
      'candidateSizeBytes': 3,
      'diffBundleId': 'bundle-1',
      'createdAt': '2026-09-03T03:00:00Z',
      'links': <String, Object?>{
        'self': '/versions/1',
        'diff': '/versions/1/diff',
        'candidate': '/versions/1/candidate',
      },
    },
  ],
};

ApiClient _api(ApiTransport transport) => ApiClientFactory.create(
  baseUrl: Uri.parse('https://api.example.test'),
  runtime: const ApiClientRuntime(
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'macos',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
  ),
  transport: transport,
  getAccessToken: () => 'access',
);

ApiTransportResponse _success(Object data) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{'success': true, 'data': data},
);

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this.responses);

  final List<ApiTransportResponse> responses;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      responses.removeAt(0);
}
