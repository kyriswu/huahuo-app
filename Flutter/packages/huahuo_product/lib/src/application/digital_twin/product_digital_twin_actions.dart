part of 'product_digital_twin_controller.dart';

extension ProductDigitalTwinActions on ProductDigitalTwinController {
  Future<bool> saveSchedule(ProductDigitalTwinScheduleDraft draft) async {
    final workspaceId = _state.workspaceId;
    if (workspaceId == null || _state.isBusy) return false;
    final action =
        'schedule:${draft.enabled}:${draft.intervalDays}:'
        '${draft.preferredLocalTime}:${draft.timezone}:${draft.instruction}';
    final generation = _generation;
    _emit(_state.copyWith(busyAction: 'schedule', clearError: true));
    final result = await _guard(
      () => _repository.updateSchedule(
        workspaceId,
        draft,
        idempotencyKey: _actionKey(action),
      ),
    );
    if (!_accept(generation, workspaceId)) return false;
    final schedule = result.data;
    if (!result.isSuccess || schedule == null) {
      _actionFailure(result);
      return false;
    }
    _completeAction(action);
    _emit(
      _state.copyWith(schedule: schedule, clearBusy: true, clearError: true),
    );
    return true;
  }

  Future<bool> inspectProposalVersion(int proposalVersion) async {
    final workspaceId = _state.workspaceId;
    final proposalId = _state.selectedProposalId;
    if (workspaceId == null ||
        proposalId == null ||
        !_state.proposalVersions.any(
          (version) => version.version == proposalVersion,
        ) ||
        _state.isBusy) {
      return false;
    }
    final sequence = ++_selectionSequence;
    _emit(_state.copyWith(busyAction: 'review', clearError: true));
    final result = await _guard(
      () => _proposals.review(
        workspaceId: workspaceId,
        proposalId: proposalId,
        proposalVersion: proposalVersion,
      ),
    );
    if (!_acceptSelection(sequence, proposalId)) return false;
    final review = result.data;
    if (!result.isSuccess || review == null) {
      _actionFailure(result);
      return false;
    }
    _emit(
      _state.copyWith(
        review: review,
        selectedHunkIds: const {},
        clearBusy: true,
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> reviseSelected(String instruction) async {
    final workspaceId = _state.workspaceId;
    final proposal = _state.selectedProposal;
    final review = _state.review;
    final normalized = instruction.trim();
    if (workspaceId == null ||
        proposal == null ||
        review == null ||
        !proposal.canRevise ||
        normalized.isEmpty ||
        utf8.encode(normalized).length > 32 * 1024 ||
        _state.isBusy) {
      return false;
    }
    final selected = <ProductProposalHunkSelection>[];
    if (_state.selectedHunkIds.isNotEmpty) {
      final bundle = review.diffBundleId;
      if (bundle == null) return false;
      for (final hunk in review.hunks) {
        if (_state.selectedHunkIds.contains(hunk.id)) {
          selected.add(
            ProductProposalHunkSelection(
              diffBundleId: bundle,
              hunkId: hunk.id,
              quotedText: hunk.quotedText,
            ),
          );
        }
      }
    }
    final action = 'revise:${proposal.id}:${proposal.version}:$normalized';
    final generation = _generation;
    _emit(_state.copyWith(busyAction: 'revise', clearError: true));
    var result = await _guard(
      () => _proposals.revise(
        workspaceId: workspaceId,
        proposal: proposal,
        instruction: normalized,
        selectedHunks: selected,
        idempotencyKey: _actionKey(action),
      ),
    );
    if (!_accept(generation, workspaceId)) return false;
    var updated = result.data;
    if (!result.isSuccess || updated == null) {
      _actionFailure(result);
      return false;
    }
    for (
      var attempt = 0;
      updated!.lifecycle.isPolling && attempt < maxPollAttempts;
      attempt++
    ) {
      await _delay(pollInterval);
      if (!_accept(generation, workspaceId)) return false;
      result = await _guard(
        () => _proposals.detail(
          workspaceId: workspaceId,
          proposalId: proposal.id,
        ),
      );
      updated = result.data;
      if (!result.isSuccess || updated == null) {
        _actionFailure(result);
        return false;
      }
    }
    if (updated.lifecycle.isPolling) {
      _actionFailure(
        const ProductResult.failure(
          code: 'DIGITAL_TWIN_REVISION_TIMEOUT',
          message: '提案仍在生成，可稍后刷新查看',
          retryable: true,
        ),
      );
      return false;
    }
    _completeAction(action);
    await reload();
    return _state.status == ProductDigitalTwinStatus.ready ||
        _state.status == ProductDigitalTwinStatus.empty;
  }

  Future<bool> confirmReady() async {
    final workspaceId = _state.workspaceId;
    final proposals = _state.proposals
        .where((proposal) => proposal.canApply)
        .take(20)
        .toList(growable: false);
    if (workspaceId == null || proposals.isEmpty || _state.isBusy) {
      return false;
    }
    final action =
        'confirm:${proposals.map((item) => '${item.id}:${item.version}').join(',')}';
    final generation = _generation;
    _emit(_state.copyWith(busyAction: 'confirm', clearError: true));
    var result = await _guard(
      () => _repository.confirm(
        workspaceId,
        proposals,
        idempotencyKey: _actionKey(action),
      ),
    );
    if (!_accept(generation, workspaceId)) return false;
    var confirmation = result.data;
    if (!result.isSuccess || confirmation == null) {
      _actionFailure(result);
      return false;
    }
    _emit(_state.copyWith(confirmation: confirmation));
    for (
      var attempt = 0;
      !confirmation!.isTerminal && attempt < maxPollAttempts;
      attempt++
    ) {
      await _delay(pollInterval);
      if (!_accept(generation, workspaceId)) return false;
      result = await _guard(
        () => _repository.confirmation(workspaceId, confirmation!.id),
      );
      confirmation = result.data;
      if (!result.isSuccess || confirmation == null) {
        _actionFailure(result);
        return false;
      }
      _emit(_state.copyWith(confirmation: confirmation));
    }
    if (!confirmation.isTerminal) {
      _actionFailure(
        const ProductResult.failure(
          code: 'DIGITAL_TWIN_CONFIRMATION_TIMEOUT',
          message: '确认仍在处理，可稍后刷新查看',
          retryable: true,
        ),
      );
      return false;
    }
    _completeAction(action);
    await reload();
    _emit(_state.copyWith(confirmation: confirmation, clearBusy: true));
    return confirmation.appliedCount > 0;
  }

  Future<bool> inspectVersion(String versionId) async {
    final workspaceId = _state.workspaceId;
    if (workspaceId == null || _state.isBusy) return false;
    final generation = _generation;
    _emit(_state.copyWith(busyAction: 'version', clearError: true));
    final detailFuture = _guard(
      () => _repository.version(workspaceId, versionId),
    );
    final previewFuture = _guard(
      () => _repository.preview(workspaceId, versionId),
    );
    final detailResult = await detailFuture;
    final previewResult = await previewFuture;
    if (!_accept(generation, workspaceId)) return false;
    final detail = detailResult.data;
    final files = previewResult.data;
    if (!detailResult.isSuccess || detail == null) {
      _actionFailure(detailResult);
      return false;
    }
    if (!previewResult.isSuccess || files == null) {
      _actionFailure(previewResult);
      return false;
    }
    _emit(
      _state.copyWith(
        versionDetail: detail,
        previewFiles: files,
        clearBusy: true,
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> compareVersion(String versionId) async {
    final workspaceId = _state.workspaceId;
    final target = _state.versions
        .where((item) => item.id == versionId)
        .firstOrNull;
    if (workspaceId == null || target == null || _state.isBusy) return false;
    final previous = _state.versions
        .where((item) => item.number < target.number)
        .fold<ProductDigitalTwinVersion?>(
          null,
          (best, item) =>
              best == null || item.number > best.number ? item : best,
        );
    if (previous == null) return false;
    final generation = _generation;
    _emit(_state.copyWith(busyAction: 'compare', clearError: true));
    final result = await _guard(
      () => _repository.compare(
        workspaceId,
        baseVersionId: previous.id,
        versionId: target.id,
      ),
    );
    if (!_accept(generation, workspaceId)) return false;
    final comparison = result.data;
    if (!result.isSuccess || comparison == null) {
      _actionFailure(result);
      return false;
    }
    _emit(
      _state.copyWith(
        comparison: comparison,
        clearBusy: true,
        clearError: true,
      ),
    );
    return true;
  }

  Future<ProductDigitalTwinArchive?> downloadVersion(String versionId) async {
    final workspaceId = _state.workspaceId;
    if (workspaceId == null || _state.isBusy) return null;
    final generation = _generation;
    _emit(_state.copyWith(busyAction: 'download', clearError: true));
    final result = await _guard(
      () => _repository.download(workspaceId, versionId),
    );
    if (!_accept(generation, workspaceId)) return null;
    final bytes = result.data;
    if (!result.isSuccess || bytes == null) {
      _actionFailure(result);
      return null;
    }
    _emit(
      _state.copyWith(
        archiveVersionId: versionId,
        archiveSizeBytes: bytes.length,
        clearBusy: true,
        clearError: true,
      ),
    );
    return ProductDigitalTwinArchive(versionId: versionId, bytes: bytes);
  }

  Future<bool> restoreVersion(String versionId) async {
    final workspaceId = _state.workspaceId;
    if (workspaceId == null || _state.isBusy) return false;
    final action = 'restore:$versionId';
    final generation = _generation;
    _emit(_state.copyWith(busyAction: 'restore', clearError: true));
    final result = await _guard(
      () => _repository.restore(
        workspaceId,
        versionId,
        idempotencyKey: _actionKey(action),
      ),
    );
    if (!_accept(generation, workspaceId)) return false;
    final receipt = result.data;
    if (!result.isSuccess || receipt == null) {
      _actionFailure(result);
      return false;
    }
    if (receipt.proposalIds.isEmpty) {
      _actionFailure(
        const ProductResult.failure(
          code: 'DIGITAL_TWIN_RESTORE_EMPTY',
          message: '恢复任务没有生成可审阅提案',
        ),
      );
      return false;
    }
    for (final proposalId in receipt.proposalIds) {
      final terminalResult = await _waitForRestoredProposal(
        workspaceId,
        proposalId,
        generation,
      );
      if (!_accept(generation, workspaceId)) return false;
      final proposal = terminalResult.data;
      if (!terminalResult.isSuccess || proposal == null) {
        _actionFailure(terminalResult);
        return false;
      }
      if (proposal.lifecycle != ProductProposalLifecycle.ready ||
          proposal.failureCode != null) {
        _actionFailure(
          ProductResult.failure(
            code:
                proposal.failureCode ?? 'DIGITAL_TWIN_RESTORE_PROPOSAL_FAILED',
            message: '恢复提案未能进入可审阅状态',
            retryable: proposal.failureRetryable,
          ),
        );
        return false;
      }
    }
    _completeAction(action);
    await reload();
    return _state.status == ProductDigitalTwinStatus.ready ||
        _state.status == ProductDigitalTwinStatus.empty;
  }

  Future<ProductResult<ProductDocumentProposal>> _waitForRestoredProposal(
    String workspaceId,
    String proposalId,
    int generation,
  ) async {
    var result = await _guard(
      () => _proposals.detail(workspaceId: workspaceId, proposalId: proposalId),
    );
    for (var attempt = 0; attempt < maxPollAttempts; attempt++) {
      final proposal = result.data;
      if (!result.isSuccess || proposal == null) return result;
      if (proposal.id != proposalId) {
        return const ProductResult.failure(
          code: 'DIGITAL_TWIN_RESTORE_PROPOSAL_MISMATCH',
          message: '恢复任务返回了不匹配的提案',
          retryable: true,
        );
      }
      if (!proposal.lifecycle.isPolling) return result;
      await _delay(pollInterval);
      if (!_accept(generation, workspaceId)) {
        return const ProductResult.failure(
          code: 'DIGITAL_TWIN_RESTORE_SUPERSEDED',
          message: 'Workspace 已切换',
          retryable: true,
        );
      }
      result = await _guard(
        () =>
            _proposals.detail(workspaceId: workspaceId, proposalId: proposalId),
      );
    }
    final proposal = result.data;
    if (result.isSuccess && proposal != null && !proposal.lifecycle.isPolling) {
      return result;
    }
    return const ProductResult.failure(
      code: 'DIGITAL_TWIN_RESTORE_TIMEOUT',
      message: '恢复提案仍在生成，可稍后刷新查看',
      retryable: true,
    );
  }
}
