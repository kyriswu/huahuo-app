part of 'product_document_proposals_controller.dart';

String _defaultKey(String action) =>
    'proposal-$action-${DateTime.now().toUtc().microsecondsSinceEpoch}';

extension _ProductDocumentProposalsLoading
    on ProductDocumentProposalsController {
  Future<void> _poll(
    ProductDocumentProposal proposal,
    int generation,
    int sequence,
  ) async {
    final workspaceId = _state.workspaceId!;
    for (var attempt = 1; attempt <= maxPollAttempts; attempt++) {
      await _delay(pollInterval);
      if (!_acceptDetail(generation, sequence, proposal.id)) return;
      final result = await _guard(
        () => _repository.detail(
          workspaceId: workspaceId,
          proposalId: proposal.id,
        ),
      );
      if (!_acceptDetail(generation, sequence, proposal.id)) return;
      final next = result.data;
      if (!result.isSuccess || next == null) {
        _detailFailure(result);
        return;
      }
      _emit(_state.copyWith(pollAttempt: attempt));
      if (!next.lifecycle.isPolling) {
        await _present(next, generation, sequence, allowPoll: false);
        return;
      }
      _upsertSelected(next);
    }
    _detailFailure(
      const ProductResult.failure(
        code: 'DOCUMENT_PROPOSAL_POLL_TIMEOUT',
        message: '提案仍在处理中，可稍后继续刷新',
        retryable: true,
      ),
    );
  }

  Future<void> _loadFirst(String workspaceId, int generation) async {
    final sequence = ++_listSequence;
    _emit(
      _state.copyWith(
        status: ProductProposalsStatus.loading,
        loadingMore: false,
        clearCursor: true,
        clearError: true,
      ),
    );
    final result = await _guard(
      () => _repository.list(
        workspaceId: workspaceId,
        ownerKind: _ownerKind,
        ownerId: _ownerId,
      ),
    );
    if (!_acceptList(generation, sequence, workspaceId)) return;
    final page = result.data;
    if (!result.isSuccess || page == null) {
      _emit(
        _state.copyWith(
          status: ProductProposalsStatus.failure,
          errorCode: result.code,
          errorMessage: result.message,
          retryable: result.retryable,
        ),
      );
      return;
    }
    _emit(
      _state.copyWith(
        status: page.items.isEmpty
            ? ProductProposalsStatus.empty
            : ProductProposalsStatus.ready,
        items: page.items,
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        clearError: true,
      ),
    );
  }

  String? get _ownerKind => _state.targetCreation == null ? null : 'creation';
  String? get _ownerId => _state.targetCreation?.summary.id;

  bool _validInstruction(String value) {
    if (value.isNotEmpty && value.length <= 32000) return true;
    _emit(
      _state.copyWith(
        errorCode: 'DOCUMENT_PROPOSAL_INSTRUCTION_INVALID',
        errorMessage: value.isEmpty ? '请输入修改要求' : '修改要求过长',
        retryable: false,
      ),
    );
    return false;
  }

  bool _acceptList(int generation, int sequence, String workspaceId) =>
      !_disposed &&
      generation == _generation &&
      sequence == _listSequence &&
      _state.workspaceId == workspaceId;

  bool _acceptDetail(int generation, int sequence, String proposalId) =>
      !_disposed &&
      generation == _generation &&
      sequence == _detailSequence &&
      _state.selected?.id == proposalId;

  bool _acceptMutation(int generation, String workspaceId, String action) =>
      !_disposed &&
      generation == _generation &&
      _state.workspaceId == workspaceId &&
      _state.busyAction == action;

  void _upsertSelected(ProductDocumentProposal proposal) {
    final items = List<ProductDocumentProposal>.of(_state.items);
    final index = items.indexWhere((item) => item.id == proposal.id);
    index < 0 ? items.insert(0, proposal) : items[index] = proposal;
    _emit(
      _state.copyWith(
        status: ProductProposalsStatus.ready,
        items: items,
        selected: proposal,
        clearBusy: true,
      ),
    );
  }

  void _detailFailure(ProductResult<Object?> result) {
    _emit(
      _state.copyWith(
        detailStatus: ProductProposalDetailStatus.failure,
        clearBusy: true,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  void _mutationFailure(ProductResult<Object?> result) {
    _emit(
      _state.copyWith(
        clearBusy: true,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  Future<ProductResult<T>> _guard<T>(
    Future<ProductResult<T>> Function() action,
  ) async {
    try {
      return await action();
    } on Object {
      return ProductResult<T>.failure(
        code: 'PRODUCT_PROPOSALS_UNEXPECTED',
        message: '文档提案服务暂时不可用，请重试',
        retryable: true,
      );
    }
  }
}
