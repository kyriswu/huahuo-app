import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';

import '../../domain/digital_twin/product_digital_twin.dart';
import '../../domain/product_result.dart';
import '../../domain/proposals/product_document_proposal.dart';

final class RemoteProductDigitalTwinRepository
    implements ProductDigitalTwinRepository {
  RemoteProductDigitalTwinRepository(ApiClient api)
    : _client = DigitalTwinClient(api);

  final DigitalTwinClient _client;

  @override
  Future<ProductResult<ProductDigitalTwinCurrent>> current(
    String workspaceId,
  ) => _map(
    () => _client.current(workspaceId),
    _current,
    'DIGITAL_TWIN_READ_FAILED',
  );

  @override
  Future<ProductResult<ProductDigitalTwinSchedule>> schedule(
    String workspaceId,
  ) => _map(
    () => _client.schedule(workspaceId),
    _schedule,
    'DIGITAL_TWIN_SCHEDULE_READ_FAILED',
  );

  @override
  Future<ProductResult<ProductDigitalTwinSchedule>> updateSchedule(
    String workspaceId,
    ProductDigitalTwinScheduleDraft draft, {
    required String idempotencyKey,
  }) => _map(
    () => _client.updateSchedule(
      workspaceId,
      DigitalTwinScheduleInput(
        enabled: draft.enabled,
        intervalDays: draft.intervalDays,
        preferredLocalTime: draft.preferredLocalTime,
        timezone: draft.timezone,
        instruction: draft.instruction,
      ),
      idempotencyKey: idempotencyKey,
    ),
    _schedule,
    'DIGITAL_TWIN_SCHEDULE_UPDATE_FAILED',
  );

  @override
  Future<ProductResult<ProductDigitalTwinConfirmation>> confirm(
    String workspaceId,
    List<ProductDocumentProposal> proposals, {
    required String idempotencyKey,
  }) {
    final inputs = <DigitalTwinConfirmationProposalInput>[];
    for (final proposal in proposals) {
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
      inputs.add(
        DigitalTwinConfirmationProposalInput(
          proposalId: proposal.id,
          proposalVersion: proposal.version,
          etag: etag,
        ),
      );
    }
    return _map(
      () => _client.createConfirmation(
        workspaceId,
        inputs,
        idempotencyKey: idempotencyKey,
      ),
      _confirmation,
      'DIGITAL_TWIN_CONFIRMATION_FAILED',
    );
  }

  @override
  Future<ProductResult<ProductDigitalTwinConfirmation>> confirmation(
    String workspaceId,
    String confirmationId,
  ) => _map(
    () => _client.confirmation(workspaceId, confirmationId),
    _confirmation,
    'DIGITAL_TWIN_CONFIRMATION_READ_FAILED',
  );

  @override
  Future<ProductResult<List<ProductDigitalTwinVersion>>> versions(
    String workspaceId,
  ) => _map(
    () => _client.versions(workspaceId),
    (items) => List.unmodifiable(items.map(_version)),
    'DIGITAL_TWIN_VERSIONS_FAILED',
  );

  @override
  Future<ProductResult<ProductDigitalTwinVersionDetail>> version(
    String workspaceId,
    String versionId,
  ) => _map(
    () => _client.version(workspaceId, versionId),
    (value) => ProductDigitalTwinVersionDetail(
      version: _version(value.version),
      operationKey: value.operationKey,
      rendererVersion: value.rendererVersion,
      profileCount: value.profileCount,
      hasPositioning: value.hasPositioning,
      proposalResultCount: value.proposalResults.length,
    ),
    'DIGITAL_TWIN_VERSION_FAILED',
  );

  @override
  Future<ProductResult<List<ProductDigitalTwinFile>>> preview(
    String workspaceId,
    String versionId,
  ) => _map(
    () => _client.preview(workspaceId, versionId),
    (items) => List.unmodifiable(items.map(_file)),
    'DIGITAL_TWIN_PREVIEW_FAILED',
  );

  @override
  Future<ProductResult<ProductDigitalTwinComparison>> compare(
    String workspaceId, {
    required String baseVersionId,
    required String versionId,
  }) => _map(
    () => _client.compare(
      workspaceId,
      baseVersionId: baseVersionId,
      versionId: versionId,
    ),
    (value) => ProductDigitalTwinComparison(
      baseVersion: _version(value.baseVersion),
      version: _version(value.version),
      files: value.files.map(
        (file) => ProductDigitalTwinFileComparison(
          id: file.id,
          name: file.name,
          summary: _summary(file.summary),
          hunks: file.hunks.map(_hunk),
        ),
      ),
    ),
    'DIGITAL_TWIN_COMPARE_FAILED',
  );

  @override
  Future<ProductResult<Uint8List>> download(
    String workspaceId,
    String versionId,
  ) => _map(
    () => _client.download(workspaceId, versionId),
    (archive) => Uint8List.fromList(archive.bytes),
    'DIGITAL_TWIN_DOWNLOAD_FAILED',
  );

  @override
  Future<ProductResult<ProductDigitalTwinRestore>> restore(
    String workspaceId,
    String versionId, {
    required String idempotencyKey,
  }) => _map(
    () =>
        _client.restore(workspaceId, versionId, idempotencyKey: idempotencyKey),
    (value) => ProductDigitalTwinRestore(
      taskId: value.taskId,
      versionId: value.versionId,
      state: value.state,
      proposalIds: value.proposalIds,
    ),
    'DIGITAL_TWIN_RESTORE_FAILED',
  );
}

Future<ProductResult<R>> _map<T, R>(
  Future<ApiResult<T>> Function() request,
  R Function(T value) convert,
  String fallback,
) async {
  try {
    final result = await request();
    final data = result.data;
    if (!result.ok || data == null) return _failure(result.error, fallback);
    return ProductResult.success(convert(data));
  } on Object {
    return ProductResult.failure(
      code: fallback,
      message: '数字分身服务暂时不可用，请重试',
      retryable: true,
    );
  }
}

ProductResult<T> _failure<T>(AppFailure? failure, String fallback) =>
    ProductResult.failure(
      code: failure?.code ?? fallback,
      message: failure?.message ?? '数字分身请求失败，请重试',
      retryable: failure?.isRetryable ?? true,
    );

ProductDigitalTwinCurrent _current(DigitalTwinCurrentDto value) =>
    ProductDigitalTwinCurrent(
      workspaceId: value.workspaceId,
      agentProfileId: value.agentProfileId,
      state: value.state,
      level: ProductDigitalTwinLevel(
        value: value.level.value,
        name: value.level.name,
        completionPercent: value.level.completionPercent,
        scoringModel: value.level.scoringModel,
      ),
      pendingReviewCount: value.pendingReviewCount,
      activeDraft: value.activeDraft == null
          ? null
          : ProductDigitalTwinDraft(
              id: value.activeDraft!.draftId,
              revision: value.activeDraft!.revision,
              etag: value.activeDraft!.etag,
              state: value.activeDraft!.state,
              items: value.activeDraft!.items.map(
                (item) => ProductDigitalTwinDraftItem(
                  proposalId: item.proposalId,
                  proposalVersion: item.proposalVersion,
                  etag: item.etag,
                  lifecycle: _lifecycle(item.state),
                  fileIds: item.fileIds,
                  hasChanges: item.hasChanges,
                  failureCode: item.failureCode,
                ),
              ),
            ),
      files: value.files.map(_file),
      currentVersion: value.currentVersion == null
          ? null
          : _version(value.currentVersion!),
      updatedAt: value.updatedAt,
    );

ProductDigitalTwinFile _file(DigitalTwinFileDto value) =>
    ProductDigitalTwinFile(
      id: value.id,
      name: value.name,
      exists: value.exists,
      markdown: value.markdown,
      conclusions: value.conclusions.map(
        (item) => ProductDigitalTwinConclusion(
          id: item.conclusionId,
          profileKind: item.profileKind,
          state: item.state,
          revision: item.revision,
          markdown: item.markdown,
          sourceReviewNeeded: item.sourceReviewNeeded,
          sources: item.sources.map(
            (source) => ProductDigitalTwinSource(
              id: source.sourceRefId,
              kind: source.sourceKind,
              noteId: source.noteId,
              part: source.part,
              partRevisionId: source.partRevisionId,
              messageId: source.messageId,
            ),
          ),
          updatedAt: item.updatedAt,
        ),
      ),
      pendingCount: value.pendingCount,
      pendingProposalIds: value.pendingProposalIds,
    );

ProductDigitalTwinSchedule _schedule(DigitalTwinScheduleDto value) =>
    ProductDigitalTwinSchedule(
      id: value.scheduleId,
      enabled: value.enabled,
      intervalDays: value.intervalDays,
      preferredLocalTime: value.preferredLocalTime,
      timezone: value.timezone,
      instruction: value.instruction,
      sourceScope: value.sourceScope,
      nextRunAt: value.nextRunAt,
      lastFiredAt: value.lastFiredAt,
      version: value.version,
    );

ProductDigitalTwinConfirmation _confirmation(
  DigitalTwinConfirmationDto value,
) => ProductDigitalTwinConfirmation(
  id: value.confirmationTaskId,
  state: value.state,
  outcomes: value.outcomes.map(
    (item) => ProductDigitalTwinConfirmationOutcome(
      proposalId: item.proposalId,
      proposalVersion: item.proposalVersion,
      lifecycle: item.state == null ? null : _lifecycle(item.state!),
      failureCode: item.failureCode,
    ),
  ),
  appliedCount: value.appliedCount,
  failedCount: value.failedCount,
  version: value.version == null ? null : _version(value.version!),
);

ProductDigitalTwinVersion _version(DigitalTwinVersionDto value) =>
    ProductDigitalTwinVersion(
      id: value.versionId,
      number: value.versionNumber,
      label: value.label,
      confirmationTaskId: value.confirmationTaskId,
      workspaceVersion: value.workspaceVersion,
      completionPercent: value.completionPercent,
      scoringModel: value.scoringModel,
      createdAt: value.createdAt,
    );

ProductProposalLifecycle _lifecycle(
  DocumentProposalStateDto value,
) => switch (value) {
  DocumentProposalStateDto.generating => ProductProposalLifecycle.generating,
  DocumentProposalStateDto.ready => ProductProposalLifecycle.ready,
  DocumentProposalStateDto.applying => ProductProposalLifecycle.applying,
  DocumentProposalStateDto.applied => ProductProposalLifecycle.applied,
  DocumentProposalStateDto.rejected => ProductProposalLifecycle.rejected,
  DocumentProposalStateDto.stale => ProductProposalLifecycle.stale,
  DocumentProposalStateDto.generationFailed =>
    ProductProposalLifecycle.generationFailed,
  DocumentProposalStateDto.applyFailed => ProductProposalLifecycle.applyFailed,
};

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
