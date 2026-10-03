import 'dart:typed_data';

import '../product_result.dart';
import '../proposals/product_document_proposal.dart';

final class ProductDigitalTwinLevel {
  const ProductDigitalTwinLevel({
    required this.value,
    required this.name,
    required this.completionPercent,
    required this.scoringModel,
  });
  final int value;
  final String name;
  final int completionPercent;
  final String scoringModel;
}

final class ProductDigitalTwinSource {
  const ProductDigitalTwinSource({
    required this.id,
    required this.kind,
    this.noteId,
    this.part,
    this.partRevisionId,
    this.messageId,
  });
  final String id;
  final String kind;
  final String? noteId;
  final String? part;
  final String? partRevisionId;
  final String? messageId;
}

final class ProductDigitalTwinConclusion {
  ProductDigitalTwinConclusion({
    required this.id,
    required this.profileKind,
    required this.state,
    required this.revision,
    required this.markdown,
    required this.sourceReviewNeeded,
    required Iterable<ProductDigitalTwinSource> sources,
    this.updatedAt,
  }) : sources = List.unmodifiable(sources);
  final String id;
  final String profileKind;
  final String state;
  final int revision;
  final String markdown;
  final bool sourceReviewNeeded;
  final List<ProductDigitalTwinSource> sources;
  final DateTime? updatedAt;
}

final class ProductDigitalTwinFile {
  ProductDigitalTwinFile({
    required this.id,
    required this.name,
    required this.exists,
    required this.markdown,
    required Iterable<ProductDigitalTwinConclusion> conclusions,
    required this.pendingCount,
    required Iterable<String> pendingProposalIds,
  }) : conclusions = List.unmodifiable(conclusions),
       pendingProposalIds = List.unmodifiable(pendingProposalIds);
  final String id;
  final String name;
  final bool exists;
  final String markdown;
  final List<ProductDigitalTwinConclusion> conclusions;
  final int pendingCount;
  final List<String> pendingProposalIds;
  int get sourceCount =>
      conclusions.fold(0, (sum, conclusion) => sum + conclusion.sources.length);
}

final class ProductDigitalTwinDraftItem {
  ProductDigitalTwinDraftItem({
    required this.proposalId,
    required this.proposalVersion,
    required this.etag,
    required this.lifecycle,
    required Iterable<String> fileIds,
    this.hasChanges,
    this.failureCode,
  }) : fileIds = List.unmodifiable(fileIds);
  final String proposalId;
  final int proposalVersion;
  final String etag;
  final ProductProposalLifecycle lifecycle;
  final List<String> fileIds;
  final bool? hasChanges;
  final String? failureCode;
}

final class ProductDigitalTwinDraft {
  ProductDigitalTwinDraft({
    required this.id,
    required this.revision,
    required this.etag,
    required this.state,
    required Iterable<ProductDigitalTwinDraftItem> items,
  }) : items = List.unmodifiable(items);
  final String id;
  final int revision;
  final String etag;
  final String state;
  final List<ProductDigitalTwinDraftItem> items;
}

final class ProductDigitalTwinVersion {
  const ProductDigitalTwinVersion({
    required this.id,
    required this.number,
    required this.label,
    required this.workspaceVersion,
    required this.completionPercent,
    required this.scoringModel,
    required this.createdAt,
    this.confirmationTaskId,
  });
  final String id;
  final int number;
  final String label;
  final String? confirmationTaskId;
  final int workspaceVersion;
  final int completionPercent;
  final String scoringModel;
  final DateTime createdAt;
}

final class ProductDigitalTwinCurrent {
  ProductDigitalTwinCurrent({
    required this.workspaceId,
    required this.agentProfileId,
    required this.state,
    required this.level,
    required this.pendingReviewCount,
    required Iterable<ProductDigitalTwinFile> files,
    required this.updatedAt,
    this.activeDraft,
    this.currentVersion,
  }) : files = List.unmodifiable(files);
  final String workspaceId;
  final String agentProfileId;
  final String state;
  final ProductDigitalTwinLevel level;
  final int pendingReviewCount;
  final ProductDigitalTwinDraft? activeDraft;
  final List<ProductDigitalTwinFile> files;
  final ProductDigitalTwinVersion? currentVersion;
  final DateTime updatedAt;
}

final class ProductDigitalTwinScheduleDraft {
  const ProductDigitalTwinScheduleDraft({
    required this.enabled,
    required this.intervalDays,
    required this.preferredLocalTime,
    required this.timezone,
    required this.instruction,
  });
  final bool enabled;
  final int intervalDays;
  final String preferredLocalTime;
  final String timezone;
  final String instruction;
}

final class ProductDigitalTwinSchedule {
  const ProductDigitalTwinSchedule({
    required this.enabled,
    required this.intervalDays,
    required this.preferredLocalTime,
    required this.timezone,
    required this.instruction,
    required this.sourceScope,
    required this.version,
    this.id,
    this.nextRunAt,
    this.lastFiredAt,
  });
  final String? id;
  final bool enabled;
  final int intervalDays;
  final String preferredLocalTime;
  final String timezone;
  final String instruction;
  final String sourceScope;
  final DateTime? nextRunAt;
  final DateTime? lastFiredAt;
  final int version;
  ProductDigitalTwinScheduleDraft get draft => ProductDigitalTwinScheduleDraft(
    enabled: enabled,
    intervalDays: intervalDays,
    preferredLocalTime: preferredLocalTime,
    timezone: timezone,
    instruction: instruction,
  );
}

final class ProductDigitalTwinConfirmationOutcome {
  const ProductDigitalTwinConfirmationOutcome({
    required this.proposalId,
    required this.proposalVersion,
    this.lifecycle,
    this.failureCode,
  });
  final String proposalId;
  final int proposalVersion;
  final ProductProposalLifecycle? lifecycle;
  final String? failureCode;
}

final class ProductDigitalTwinConfirmation {
  ProductDigitalTwinConfirmation({
    required this.id,
    required this.state,
    required Iterable<ProductDigitalTwinConfirmationOutcome> outcomes,
    required this.appliedCount,
    required this.failedCount,
    this.version,
  }) : outcomes = List.unmodifiable(outcomes);
  final String id;
  final String state;
  final List<ProductDigitalTwinConfirmationOutcome> outcomes;
  final int appliedCount;
  final int failedCount;
  final ProductDigitalTwinVersion? version;
  bool get isTerminal => state == 'report_ready';
}

final class ProductDigitalTwinVersionDetail {
  const ProductDigitalTwinVersionDetail({
    required this.version,
    required this.operationKey,
    required this.rendererVersion,
    required this.profileCount,
    required this.hasPositioning,
    required this.proposalResultCount,
  });
  final ProductDigitalTwinVersion version;
  final String operationKey;
  final String rendererVersion;
  final int profileCount;
  final bool hasPositioning;
  final int proposalResultCount;
}

final class ProductDigitalTwinFileComparison {
  ProductDigitalTwinFileComparison({
    required this.id,
    required this.name,
    required this.summary,
    required Iterable<ProductProposalDiffHunk> hunks,
  }) : hunks = List.unmodifiable(hunks);
  final String id;
  final String name;
  final ProductProposalDiffSummary summary;
  final List<ProductProposalDiffHunk> hunks;
}

final class ProductDigitalTwinComparison {
  ProductDigitalTwinComparison({
    required this.baseVersion,
    required this.version,
    required Iterable<ProductDigitalTwinFileComparison> files,
  }) : files = List.unmodifiable(files);
  final ProductDigitalTwinVersion baseVersion;
  final ProductDigitalTwinVersion version;
  final List<ProductDigitalTwinFileComparison> files;
}

final class ProductDigitalTwinRestore {
  ProductDigitalTwinRestore({
    required this.taskId,
    required this.versionId,
    required this.state,
    required Iterable<String> proposalIds,
  }) : proposalIds = List.unmodifiable(proposalIds);
  final String taskId;
  final String versionId;
  final String state;
  final List<String> proposalIds;
}

abstract interface class ProductDigitalTwinRepository {
  Future<ProductResult<ProductDigitalTwinCurrent>> current(String workspaceId);
  Future<ProductResult<ProductDigitalTwinSchedule>> schedule(
    String workspaceId,
  );
  Future<ProductResult<ProductDigitalTwinSchedule>> updateSchedule(
    String workspaceId,
    ProductDigitalTwinScheduleDraft draft, {
    required String idempotencyKey,
  });
  Future<ProductResult<ProductDigitalTwinConfirmation>> confirm(
    String workspaceId,
    List<ProductDocumentProposal> proposals, {
    required String idempotencyKey,
  });
  Future<ProductResult<ProductDigitalTwinConfirmation>> confirmation(
    String workspaceId,
    String confirmationId,
  );
  Future<ProductResult<List<ProductDigitalTwinVersion>>> versions(
    String workspaceId,
  );
  Future<ProductResult<ProductDigitalTwinVersionDetail>> version(
    String workspaceId,
    String versionId,
  );
  Future<ProductResult<List<ProductDigitalTwinFile>>> preview(
    String workspaceId,
    String versionId,
  );
  Future<ProductResult<ProductDigitalTwinComparison>> compare(
    String workspaceId, {
    required String baseVersionId,
    required String versionId,
  });
  Future<ProductResult<Uint8List>> download(
    String workspaceId,
    String versionId,
  );
  Future<ProductResult<ProductDigitalTwinRestore>> restore(
    String workspaceId,
    String versionId, {
    required String idempotencyKey,
  });
}

final class UnavailableProductDigitalTwinRepository
    implements ProductDigitalTwinRepository {
  const UnavailableProductDigitalTwinRepository();
  ProductResult<T> _failure<T>() => const ProductResult.failure(
    code: 'DIGITAL_TWIN_UNAVAILABLE',
    message: '数字分身服务尚未配置',
  );
  @override
  Future<ProductResult<ProductDigitalTwinComparison>> compare(
    String workspaceId, {
    required String baseVersionId,
    required String versionId,
  }) async => _failure();
  @override
  Future<ProductResult<ProductDigitalTwinConfirmation>> confirm(
    String workspaceId,
    List<ProductDocumentProposal> proposals, {
    required String idempotencyKey,
  }) async => _failure();
  @override
  Future<ProductResult<ProductDigitalTwinConfirmation>> confirmation(
    String workspaceId,
    String confirmationId,
  ) async => _failure();
  @override
  Future<ProductResult<ProductDigitalTwinCurrent>> current(
    String workspaceId,
  ) async => _failure();
  @override
  Future<ProductResult<Uint8List>> download(
    String workspaceId,
    String versionId,
  ) async => _failure();
  @override
  Future<ProductResult<List<ProductDigitalTwinFile>>> preview(
    String workspaceId,
    String versionId,
  ) async => _failure();
  @override
  Future<ProductResult<ProductDigitalTwinRestore>> restore(
    String workspaceId,
    String versionId, {
    required String idempotencyKey,
  }) async => _failure();
  @override
  Future<ProductResult<ProductDigitalTwinSchedule>> schedule(
    String workspaceId,
  ) async => _failure();
  @override
  Future<ProductResult<ProductDigitalTwinSchedule>> updateSchedule(
    String workspaceId,
    ProductDigitalTwinScheduleDraft draft, {
    required String idempotencyKey,
  }) async => _failure();
  @override
  Future<ProductResult<ProductDigitalTwinVersionDetail>> version(
    String workspaceId,
    String versionId,
  ) async => _failure();
  @override
  Future<ProductResult<List<ProductDigitalTwinVersion>>> versions(
    String workspaceId,
  ) async => _failure();
}
