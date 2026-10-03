import '../creations/product_creation.dart';
import '../product_result.dart';

enum ProductProposalLifecycle {
  generating,
  ready,
  applying,
  applied,
  rejected,
  stale,
  generationFailed,
  applyFailed;

  bool get isPolling => this == generating || this == applying;

  bool get isTerminal => switch (this) {
    applied || rejected || generationFailed => true,
    _ => false,
  };
}

final class ProductDocumentProposal {
  const ProductDocumentProposal({
    required this.id,
    required this.version,
    required this.rowVersion,
    required this.lifecycle,
    required this.ownerKind,
    required this.ownerId,
    required this.part,
    required this.basePartRevisionId,
    required this.baseHash,
    required this.candidateAvailable,
    required this.createdAt,
    required this.updatedAt,
    this.etag,
    this.hasChanges,
    this.failureCode,
    this.failureRetryable = false,
    this.appliedPartRevisionId,
    this.runId,
    this.runState,
  });

  final String id;
  final int version;
  final int rowVersion;
  final ProductProposalLifecycle lifecycle;
  final String ownerKind;
  final String ownerId;
  final String part;
  final String basePartRevisionId;
  final String baseHash;
  final bool candidateAvailable;
  final bool? hasChanges;
  final String? failureCode;
  final bool failureRetryable;
  final String? appliedPartRevisionId;
  final String? runId;
  final String? runState;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? etag;

  bool get canApply =>
      lifecycle == ProductProposalLifecycle.ready && hasChanges == true;
  bool get canCancel => lifecycle == ProductProposalLifecycle.generating;
  bool get canReject =>
      lifecycle == ProductProposalLifecycle.ready ||
      lifecycle == ProductProposalLifecycle.applyFailed ||
      lifecycle == ProductProposalLifecycle.stale;
  bool get canRebase => lifecycle == ProductProposalLifecycle.stale;
  bool get canRevise => canReject;
}

final class ProductDocumentProposalPage {
  ProductDocumentProposalPage({
    required Iterable<ProductDocumentProposal> items,
    this.nextCursor,
  }) : items = List.unmodifiable(items);

  final List<ProductDocumentProposal> items;
  final String? nextCursor;
}

final class ProductProposalDiffChange {
  const ProductProposalDiffChange({
    required this.operation,
    required this.text,
  });

  final String operation;
  final String text;
}

final class ProductProposalDiffHunk {
  ProductProposalDiffHunk({
    required this.id,
    required this.oldStart,
    required this.oldLines,
    required this.newStart,
    required this.newLines,
    required Iterable<ProductProposalDiffChange> changes,
  }) : changes = List.unmodifiable(changes);

  final String id;
  final int oldStart;
  final int oldLines;
  final int newStart;
  final int newLines;
  final List<ProductProposalDiffChange> changes;

  String get quotedText => changes
      .where((change) => change.operation == 'delete')
      .map((change) => change.text)
      .join('\n');
}

final class ProductProposalDiffSummary {
  const ProductProposalDiffSummary({
    required this.hunks,
    required this.insertedLines,
    required this.deletedLines,
    required this.changedLines,
    required this.hasChanges,
  });

  final int hunks;
  final int insertedLines;
  final int deletedLines;
  final int changedLines;
  final bool hasChanges;
}

final class ProductProposalReview {
  ProductProposalReview({
    required this.proposalId,
    required this.proposalVersion,
    required this.candidateHash,
    required this.candidateMarkdown,
    required this.summary,
    required Iterable<ProductProposalDiffHunk> hunks,
    this.diffBundleId,
  }) : hunks = List.unmodifiable(hunks);

  final String proposalId;
  final int proposalVersion;
  final String candidateHash;
  final String candidateMarkdown;
  final ProductProposalDiffSummary summary;
  final List<ProductProposalDiffHunk> hunks;
  final String? diffBundleId;
}

final class ProductProposalVersion {
  const ProductProposalVersion({
    required this.proposalId,
    required this.version,
    required this.baseHash,
    required this.createdAt,
    this.candidateHash,
    this.candidateSizeBytes,
    this.diffBundleId,
    this.runId,
  });

  final String proposalId;
  final int version;
  final String baseHash;
  final String? candidateHash;
  final int? candidateSizeBytes;
  final String? diffBundleId;
  final String? runId;
  final DateTime createdAt;
}

final class ProductProposalHunkSelection {
  const ProductProposalHunkSelection({
    required this.diffBundleId,
    required this.hunkId,
    required this.quotedText,
  });

  final String diffBundleId;
  final String hunkId;
  final String quotedText;
}

abstract interface class ProductDocumentProposalsRepository {
  Future<ProductResult<ProductDocumentProposalPage>> list({
    required String workspaceId,
    String? ownerKind,
    String? ownerId,
    String? cursor,
  });

  Future<ProductResult<ProductDocumentProposal>> detail({
    required String workspaceId,
    required String proposalId,
  });

  Future<ProductResult<ProductDocumentProposal>> createForCreation({
    required String workspaceId,
    required ProductCreationDocument creation,
    required String instruction,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductProposalReview>> review({
    required String workspaceId,
    required String proposalId,
    int? proposalVersion,
  });

  Future<ProductResult<List<ProductProposalVersion>>> versions({
    required String workspaceId,
    required String proposalId,
  });

  Future<ProductResult<ProductDocumentProposal>> apply({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductDocumentProposal>> reject({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductDocumentProposal>> cancel({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductDocumentProposal>> rebase({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  });

  Future<ProductResult<ProductDocumentProposal>> revise({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String instruction,
    required List<ProductProposalHunkSelection> selectedHunks,
    required String idempotencyKey,
  });
}

final class UnavailableProductDocumentProposalsRepository
    implements ProductDocumentProposalsRepository {
  const UnavailableProductDocumentProposalsRepository();

  ProductResult<T> _unavailable<T>() => const ProductResult.failure(
    code: 'PRODUCT_PROPOSALS_UNAVAILABLE',
    message: '文档提案服务尚未配置',
  );

  @override
  Future<ProductResult<ProductDocumentProposal>> apply({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductDocumentProposal>> cancel({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductDocumentProposal>> createForCreation({
    required String workspaceId,
    required ProductCreationDocument creation,
    required String instruction,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductDocumentProposal>> detail({
    required String workspaceId,
    required String proposalId,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductDocumentProposalPage>> list({
    required String workspaceId,
    String? ownerKind,
    String? ownerId,
    String? cursor,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductDocumentProposal>> rebase({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductDocumentProposal>> reject({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductProposalReview>> review({
    required String workspaceId,
    required String proposalId,
    int? proposalVersion,
  }) async => _unavailable();

  @override
  Future<ProductResult<ProductDocumentProposal>> revise({
    required String workspaceId,
    required ProductDocumentProposal proposal,
    required String instruction,
    required List<ProductProposalHunkSelection> selectedHunks,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ProductResult<List<ProductProposalVersion>>> versions({
    required String workspaceId,
    required String proposalId,
  }) async => _unavailable();
}
