import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../domain/creations/product_creation.dart';
import '../../domain/product_result.dart';
import '../../domain/proposals/product_document_proposal.dart';

final class RemoteProductDocumentProposalsRepository
    implements ProductDocumentProposalsRepository {
  RemoteProductDocumentProposalsRepository(ApiClient api)
    : _client = DocumentProposalClient(api);

  final DocumentProposalClient _client;

  @override
  Future<ProductResult<ProductDocumentProposalPage>> list({
    required String workspaceId,
    String? ownerKind,
    String? ownerId,
    String? cursor,
  }) async {
    try {
      final result = await _client.list(
        workspaceId,
        ownerKind: ownerKind,
        ownerId: ownerId,
        cursor: cursor,
      );
      final page = result.data;
      if (!result.ok || page == null) return _failure(result.error);
      return ProductResult.success(
        ProductDocumentProposalPage(
          items: page.items.map((item) => _proposal(item)),
          nextCursor: page.nextCursor,
        ),
      );
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> detail({
    required String workspaceId,
    required String proposalId,
  }) => _snapshot(() => _client.detail(workspaceId, proposalId));

  @override
  Future<ProductResult<ProductDocumentProposal>> createForCreation({
    required String workspaceId,
    required ProductCreationDocument creation,
    required String instruction,
    required String idempotencyKey,
  }) => _snapshot(
    () => _client.createForCreation(
      workspaceId,
      creationId: creation.summary.id,
      rawPartRevisionId: creation.rawPartRevisionId,
      instruction: instruction,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<ProductProposalReview>> review({
    required String workspaceId,
    required String proposalId,
    int? proposalVersion,
  }) async {
    try {
      final hunks = <ProductProposalDiffHunk>[];
      DocumentProposalDiffSummaryDto? summary;
      int? version;
      String? cursor;
      final seenDiffCursors = <String>{};
      for (var pageCount = 0; pageCount < 100; pageCount++) {
        final result = await _client.diff(
          workspaceId,
          proposalId,
          proposalVersion: proposalVersion,
          cursor: cursor,
        );
        final page = result.data;
        if (!result.ok || page == null) return _failure(result.error);
        summary ??= page.summary;
        version ??= page.proposalVersion;
        if (page.proposalVersion != version) return _pagingFailure();
        hunks.addAll(page.items.map(_hunk));
        cursor = page.nextCursor;
        if (cursor == null) break;
        if (!seenDiffCursors.add(cursor)) return _pagingFailure();
        if (pageCount == 99) return _pagingFailure();
      }

      final candidate = StringBuffer();
      String? candidateHash;
      var expectedOffset = 0;
      cursor = null;
      final seenCandidateCursors = <String>{};
      for (var pageCount = 0; pageCount < 100; pageCount++) {
        final result = await _client.candidate(
          workspaceId,
          proposalId,
          proposalVersion: proposalVersion,
          cursor: cursor,
        );
        final chunk = result.data;
        if (!result.ok || chunk == null) return _failure(result.error);
        if (chunk.proposalVersion != version ||
            chunk.offsetBytes != expectedOffset ||
            (candidateHash != null && candidateHash != chunk.candidateHash)) {
          return _pagingFailure();
        }
        candidateHash = chunk.candidateHash;
        candidate.write(chunk.text);
        expectedOffset += utf8.encode(chunk.text).length;
        if (expectedOffset > documentProposalCandidateMaxBytes) {
          return _pagingFailure();
        }
        cursor = chunk.nextCursor;
        if (cursor == null) break;
        if (!seenCandidateCursors.add(cursor)) return _pagingFailure();
        if (pageCount == 99) return _pagingFailure();
      }

      final markdown = candidate.toString();
      final calculated = 'sha256:${sha256.convert(utf8.encode(markdown))}';
      if (summary == null ||
          version == null ||
          candidateHash == null ||
          calculated != candidateHash) {
        return const ProductResult.failure(
          code: 'DOCUMENT_PROPOSAL_CANDIDATE_INTEGRITY',
          message: '提案候选内容校验失败，请重新加载',
          retryable: true,
        );
      }
      final history = await versions(
        workspaceId: workspaceId,
        proposalId: proposalId,
      );
      if (!history.isSuccess) return _copyFailure(history);
      final matching = history.data
          ?.where((item) => item.version == version)
          .firstOrNull;
      return ProductResult.success(
        ProductProposalReview(
          proposalId: proposalId,
          proposalVersion: version,
          candidateHash: candidateHash,
          candidateMarkdown: markdown,
          summary: _summary(summary),
          hunks: hunks,
          diffBundleId: matching?.diffBundleId,
        ),
      );
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<List<ProductProposalVersion>>> versions({
    required String workspaceId,
    required String proposalId,
  }) async {
    try {
      final result = await _client.versions(workspaceId, proposalId);
      final items = result.data;
      if (!result.ok || items == null) return _failure(result.error);
      return ProductResult.success(
        List.unmodifiable(
          items.map(
            (item) => ProductProposalVersion(
              proposalId: item.proposalId,
              version: item.proposalVersion,
              baseHash: item.baseHash,
              candidateHash: item.candidateHash,
              candidateSizeBytes: item.candidateSizeBytes,
              diffBundleId: item.diffBundleId,
              runId: item.agentRunId,
              createdAt: item.createdAt,
            ),
          ),
        ),
      );
    } on Object {
      return _unexpected();
    }
  }

  @override
  Future<ProductResult<ProductDocumentProposal>> apply({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) => _mutate(
    proposal,
    (etag) => _client.apply(
      workspaceId,
      proposal.id,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<ProductDocumentProposal>> reject({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) => _mutate(
    proposal,
    (etag) => _client.reject(
      workspaceId,
      proposal.id,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<ProductDocumentProposal>> cancel({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) => _mutate(
    proposal,
    (etag) => _client.cancel(
      workspaceId,
      proposal.id,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<ProductDocumentProposal>> rebase({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) => _mutate(
    proposal,
    (etag) => _client.rebase(
      workspaceId,
      proposal.id,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<ProductResult<ProductDocumentProposal>> revise({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String instruction,
    required List<ProductProposalHunkSelection> selectedHunks,
    required String idempotencyKey,
  }) => _mutate(
    proposal,
    (etag) => _client.revise(
      workspaceId,
      proposal.id,
      baseProposalVersion: proposal.version,
      instruction: instruction,
      etag: etag,
      idempotencyKey: idempotencyKey,
      selectedHunks: [
        for (final hunk in selectedHunks)
          (
            diffBundleId: hunk.diffBundleId,
            hunkId: hunk.hunkId,
            quotedText: hunk.quotedText,
          ),
      ],
    ),
  );

  Future<ProductResult<ProductDocumentProposal>> _mutate(
    ProductDocumentProposal proposal,
    Future<ApiResult<DocumentProposalSnapshotDto>> Function(String etag)
    request,
  ) {
    final etag = proposal.etag;
    if (etag == null) {
      return Future.value(
        const ProductResult.failure(
          code: 'DOCUMENT_PROPOSAL_PRECONDITION_REQUIRED',
          message: '提案版本尚未加载，请刷新后重试',
          retryable: true,
        ),
      );
    }
    return _snapshot(() => request(etag));
  }

  Future<ProductResult<ProductDocumentProposal>> _snapshot(
    Future<ApiResult<DocumentProposalSnapshotDto>> Function() request,
  ) async {
    try {
      final result = await request();
      final snapshot = result.data;
      if (!result.ok || snapshot == null) return _failure(result.error);
      return ProductResult.success(
        _proposal(snapshot.proposal, etag: snapshot.etag),
      );
    } on Object {
      return _unexpected();
    }
  }
}

ProductDocumentProposal _proposal(DocumentProposalDto value, {String? etag}) =>
    ProductDocumentProposal(
      id: value.proposalId,
      version: value.proposalVersion,
      rowVersion: value.rowVersion,
      lifecycle: switch (value.state) {
        DocumentProposalStateDto.generating =>
          ProductProposalLifecycle.generating,
        DocumentProposalStateDto.ready => ProductProposalLifecycle.ready,
        DocumentProposalStateDto.applying => ProductProposalLifecycle.applying,
        DocumentProposalStateDto.applied => ProductProposalLifecycle.applied,
        DocumentProposalStateDto.rejected => ProductProposalLifecycle.rejected,
        DocumentProposalStateDto.stale => ProductProposalLifecycle.stale,
        DocumentProposalStateDto.generationFailed =>
          ProductProposalLifecycle.generationFailed,
        DocumentProposalStateDto.applyFailed =>
          ProductProposalLifecycle.applyFailed,
      },
      ownerKind: value.ownerKind,
      ownerId: value.ownerId,
      part: value.part,
      basePartRevisionId: value.basePartRevisionId,
      baseHash: value.baseHash,
      candidateAvailable: value.candidateAvailable,
      hasChanges: value.hasChanges,
      failureCode: value.failureCode,
      failureRetryable: value.failureRetryable ?? false,
      appliedPartRevisionId: value.appliedPartRevisionId,
      runId: value.runId,
      runState: value.runState,
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
      etag: etag,
    );

ProductProposalDiffHunk _hunk(DocumentProposalDiffHunkDto value) =>
    ProductProposalDiffHunk(
      id: value.hunkId,
      oldStart: value.oldStart,
      oldLines: value.oldLines,
      newStart: value.newStart,
      newLines: value.newLines,
      changes: value.changes.map(
        (change) => ProductProposalDiffChange(
          operation: change.operation,
          text: change.text,
        ),
      ),
    );

ProductProposalDiffSummary _summary(DocumentProposalDiffSummaryDto value) =>
    ProductProposalDiffSummary(
      hunks: value.hunks,
      insertedLines: value.insertedLines,
      deletedLines: value.deletedLines,
      changedLines: value.changedLines,
      hasChanges: value.hasChanges,
    );

ProductResult<T> _failure<T>(AppFailure? failure) => ProductResult.failure(
  code: failure?.code ?? 'DOCUMENT_PROPOSAL_REQUEST_FAILED',
  message: failure?.message ?? '文档提案请求失败，请重试',
  retryable: failure?.isRetryable ?? true,
);

ProductResult<T> _copyFailure<T>(ProductResult<Object?> result) =>
    ProductResult.failure(
      code: result.code,
      message: result.message,
      retryable: result.retryable,
    );

ProductResult<T> _pagingFailure<T>() => const ProductResult.failure(
  code: 'DOCUMENT_PROPOSAL_PAGING_INVALID',
  message: '提案分页数据不连续，请重新加载',
  retryable: true,
);

ProductResult<T> _unexpected<T>() => const ProductResult.failure(
  code: 'DOCUMENT_PROPOSAL_UNEXPECTED',
  message: '文档提案服务暂时不可用，请重试',
  retryable: true,
);
