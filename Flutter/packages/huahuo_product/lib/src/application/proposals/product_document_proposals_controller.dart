import '../../domain/creations/product_creation.dart';
import '../../domain/product_result.dart';
import '../../domain/proposals/product_document_proposal.dart';
import 'product_document_proposals_state.dart';

part 'product_document_proposals_loading.dart';

typedef ProductProposalsListener = void Function();
typedef ProductProposalKeyFactory = String Function(String action);
typedef ProductProposalDelay = Future<void> Function(Duration duration);

final class ProductDocumentProposalsController {
  ProductDocumentProposalsController(
    this._repository, {
    ProductProposalKeyFactory? keyFactory,
    ProductProposalDelay? delay,
    this.pollInterval = const Duration(seconds: 2),
    this.maxPollAttempts = 20,
  }) : _keyFactory = keyFactory ?? _defaultKey,
       _delay = delay ?? Future<void>.delayed;

  final ProductDocumentProposalsRepository _repository;
  final ProductProposalKeyFactory _keyFactory;
  final ProductProposalDelay _delay;
  final Duration pollInterval;
  final int maxPollAttempts;
  final Set<ProductProposalsListener> _listeners = {};
  final Map<String, String> _pendingKeys = {};
  ProductDocumentProposalsState _state = ProductDocumentProposalsState.idle();
  int _generation = 0;
  int _listSequence = 0;
  int _detailSequence = 0;
  bool _disposed = false;

  ProductDocumentProposalsState get state => _state;

  void addListener(ProductProposalsListener listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(ProductProposalsListener listener) {
    _listeners.remove(listener);
  }

  Future<void> bindWorkspace(
    String? workspaceId, {
    ProductCreationDocument? creation,
  }) async {
    final id = workspaceId?.trim();
    if (id == null || id.isEmpty) {
      reset();
      return;
    }
    if (_state.workspaceId == id &&
        _state.targetCreation?.summary.id == creation?.summary.id &&
        _state.targetCreation?.rawPartRevisionId ==
            creation?.rawPartRevisionId &&
        _state.status != ProductProposalsStatus.idle) {
      return;
    }
    _generation++;
    _listSequence = 0;
    _detailSequence = 0;
    _pendingKeys.clear();
    _emit(
      ProductDocumentProposalsState(
        workspaceId: id,
        targetCreation: creation,
        status: ProductProposalsStatus.loading,
        items: const [],
        nextCursor: null,
        loadingMore: false,
        selected: null,
        detailStatus: ProductProposalDetailStatus.idle,
        review: null,
        versions: const [],
        selectedHunkIds: const {},
        busyAction: null,
        pollAttempt: 0,
        errorCode: null,
        errorMessage: null,
        retryable: false,
      ),
    );
    await _loadFirst(id, _generation);
  }

  Future<void> reload() async {
    final workspaceId = _state.workspaceId;
    if (workspaceId != null) await _loadFirst(workspaceId, _generation);
  }

  Future<void> loadMore() async {
    final workspaceId = _state.workspaceId;
    final cursor = _state.nextCursor;
    if (workspaceId == null || cursor == null || _state.loadingMore) return;
    final generation = _generation;
    final sequence = ++_listSequence;
    _emit(_state.copyWith(loadingMore: true, clearError: true));
    final result = await _guard(
      () => _repository.list(
        workspaceId: workspaceId,
        ownerKind: _ownerKind,
        ownerId: _ownerId,
        cursor: cursor,
      ),
    );
    if (!_acceptList(generation, sequence, workspaceId)) return;
    final page = result.data;
    if (!result.isSuccess || page == null) {
      _emit(
        _state.copyWith(
          loadingMore: false,
          errorCode: result.code,
          errorMessage: result.message,
          retryable: result.retryable,
        ),
      );
      return;
    }
    final items = <String, ProductDocumentProposal>{
      for (final item in _state.items) item.id: item,
      for (final item in page.items) item.id: item,
    }.values.toList();
    _emit(
      _state.copyWith(
        items: items,
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        loadingMore: false,
        clearError: true,
      ),
    );
  }

  Future<void> select(String proposalId) async {
    final id = proposalId.trim();
    final workspaceId = _state.workspaceId;
    if (workspaceId == null || id.isEmpty) return;
    final generation = _generation;
    final sequence = ++_detailSequence;
    _emit(
      _state.copyWith(
        selected: _state.items.where((item) => item.id == id).firstOrNull,
        detailStatus: ProductProposalDetailStatus.loading,
        clearReview: true,
        clearError: true,
      ),
    );
    final result = await _guard(
      () => _repository.detail(workspaceId: workspaceId, proposalId: id),
    );
    if (!_acceptDetail(generation, sequence, id)) return;
    final proposal = result.data;
    if (!result.isSuccess || proposal == null) {
      _detailFailure(result);
      return;
    }
    await _present(proposal, generation, sequence, allowPoll: true);
  }

  Future<void> refreshSelected() async {
    final id = _state.selected?.id;
    if (id != null) await select(id);
  }

  void resetSelectionForView() {
    _detailSequence++;
    _emit(
      _state.copyWith(clearSelection: true, clearBusy: true, clearError: true),
    );
  }

  Future<bool> create(String instruction) async {
    final workspaceId = _state.workspaceId;
    final creation = _state.targetCreation;
    final normalized = instruction.trim();
    if (workspaceId == null ||
        creation == null ||
        _state.isBusy ||
        !_validInstruction(normalized)) {
      return false;
    }
    final action =
        'create:${creation.summary.id}:${creation.rawPartRevisionId}:'
        '${normalized.hashCode}';
    final key = _pendingKeys.putIfAbsent(action, () => _keyFactory(action));
    final generation = _generation;
    _emit(_state.copyWith(busyAction: action, clearError: true));
    final result = await _guard(
      () => _repository.createForCreation(
        workspaceId: workspaceId,
        creation: creation,
        instruction: normalized,
        idempotencyKey: key,
      ),
    );
    if (!_acceptMutation(generation, workspaceId, action)) return false;
    final proposal = result.data;
    if (!result.isSuccess || proposal == null) {
      _mutationFailure(result);
      return false;
    }
    _pendingKeys.remove(action);
    final sequence = ++_detailSequence;
    _emit(_state.copyWith(clearBusy: true));
    await _present(proposal, generation, sequence, allowPoll: true);
    return true;
  }

  Future<bool> apply() => _mutate(
    'apply',
    allowed: (proposal) => proposal.canApply,
    request: (workspaceId, proposal, key) => _repository.apply(
      workspaceId: workspaceId,
      proposal: proposal,
      idempotencyKey: key,
    ),
  );

  Future<bool> reject() => _mutate(
    'reject',
    allowed: (proposal) => proposal.canReject,
    request: (workspaceId, proposal, key) => _repository.reject(
      workspaceId: workspaceId,
      proposal: proposal,
      idempotencyKey: key,
    ),
  );

  Future<bool> cancel() => _mutate(
    'cancel',
    allowed: (proposal) => proposal.canCancel,
    request: (workspaceId, proposal, key) => _repository.cancel(
      workspaceId: workspaceId,
      proposal: proposal,
      idempotencyKey: key,
    ),
  );

  Future<bool> rebase() => _mutate(
    'rebase',
    allowed: (proposal) => proposal.canRebase,
    request: (workspaceId, proposal, key) => _repository.rebase(
      workspaceId: workspaceId,
      proposal: proposal,
      idempotencyKey: key,
    ),
  );

  Future<bool> revise(String instruction) {
    final normalized = instruction.trim();
    if (!_validInstruction(normalized)) return Future.value(false);
    final review = _state.review;
    final bundleId = review?.diffBundleId;
    final selections = bundleId == null
        ? const <ProductProposalHunkSelection>[]
        : [
            for (final hunk in review!.hunks)
              if (_state.selectedHunkIds.contains(hunk.id))
                ProductProposalHunkSelection(
                  diffBundleId: bundleId,
                  hunkId: hunk.id,
                  quotedText: hunk.quotedText,
                ),
          ];
    return _mutate(
      'revise:${normalized.hashCode}:${_state.selectedHunkIds.join(',')}',
      allowed: (proposal) => proposal.canRevise,
      request: (workspaceId, proposal, key) => _repository.revise(
        workspaceId: workspaceId,
        proposal: proposal,
        instruction: normalized,
        selectedHunks: selections,
        idempotencyKey: key,
      ),
    );
  }

  void toggleHunk(String hunkId) {
    final review = _state.review;
    if (review == null ||
        review.diffBundleId == null ||
        !review.hunks.any((hunk) => hunk.id == hunkId) ||
        _state.isBusy) {
      return;
    }
    final selected = Set<String>.of(_state.selectedHunkIds);
    selected.contains(hunkId) ? selected.remove(hunkId) : selected.add(hunkId);
    _emit(_state.copyWith(selectedHunkIds: selected, clearError: true));
  }

  Future<void> showVersion(int version) async {
    final proposal = _state.selected;
    if (proposal == null || version < 1) return;
    await _loadReview(
      proposal,
      _generation,
      _detailSequence,
      proposalVersion: version,
    );
  }

  Future<void> loadVersions() async {
    final workspaceId = _state.workspaceId;
    final proposal = _state.selected;
    if (workspaceId == null || proposal == null || _state.isBusy) return;
    const action = 'versions';
    final generation = _generation;
    final sequence = _detailSequence;
    _emit(_state.copyWith(busyAction: action, clearError: true));
    final result = await _guard(
      () => _repository.versions(
        workspaceId: workspaceId,
        proposalId: proposal.id,
      ),
    );
    if (!_acceptDetail(generation, sequence, proposal.id)) return;
    final versions = result.data;
    if (!result.isSuccess || versions == null) {
      _mutationFailure(result);
      return;
    }
    final sorted = List<ProductProposalVersion>.of(versions)
      ..sort((left, right) => right.version.compareTo(left.version));
    _emit(_state.copyWith(versions: sorted, clearBusy: true, clearError: true));
  }

  Future<bool> _mutate(
    String verb, {
    required bool Function(ProductDocumentProposal proposal) allowed,
    required Future<ProductResult<ProductDocumentProposal>> Function(
      String workspaceId,
      ProductDocumentProposal proposal,
      String key,
    )
    request,
  }) async {
    final workspaceId = _state.workspaceId;
    final proposal = _state.selected;
    if (workspaceId == null ||
        proposal == null ||
        proposal.etag == null ||
        _state.isBusy ||
        !allowed(proposal)) {
      return false;
    }
    final action = '$verb:${proposal.id}:${proposal.rowVersion}';
    final key = _pendingKeys.putIfAbsent(action, () => _keyFactory(action));
    final generation = _generation;
    _emit(_state.copyWith(busyAction: action, clearError: true));
    final result = await _guard(() => request(workspaceId, proposal, key));
    if (!_acceptMutation(generation, workspaceId, action)) return false;
    final next = result.data;
    if (!result.isSuccess || next == null) {
      _mutationFailure(result);
      return false;
    }
    _pendingKeys.remove(action);
    final sequence = ++_detailSequence;
    _emit(_state.copyWith(clearBusy: true));
    await _present(next, generation, sequence, allowPoll: true);
    return true;
  }

  Future<void> _present(
    ProductDocumentProposal proposal,
    int generation,
    int sequence, {
    required bool allowPoll,
  }) async {
    _upsertSelected(proposal);
    if (proposal.lifecycle.isPolling) {
      _emit(
        _state.copyWith(
          detailStatus: ProductProposalDetailStatus.polling,
          pollAttempt: 0,
          clearReview: true,
          clearError: true,
        ),
      );
      if (allowPoll) await _poll(proposal, generation, sequence);
      return;
    }
    if (proposal.lifecycle == ProductProposalLifecycle.ready) {
      if (proposal.hasChanges == false) {
        _emit(
          _state.copyWith(
            detailStatus: ProductProposalDetailStatus.noChanges,
            clearReview: true,
            clearError: true,
          ),
        );
      } else if (proposal.candidateAvailable) {
        await _loadReview(proposal, generation, sequence);
      } else {
        _detailFailure(
          const ProductResult.failure(
            code: 'DOCUMENT_PROPOSAL_CANDIDATE_MISSING',
            message: '提案候选内容尚未就绪，请刷新后重试',
            retryable: true,
          ),
        );
      }
      return;
    }
    _emit(
      _state.copyWith(
        detailStatus: ProductProposalDetailStatus.terminal,
        clearReview: true,
        clearError: true,
      ),
    );
  }

  Future<void> _loadReview(
    ProductDocumentProposal proposal,
    int generation,
    int sequence, {
    int? proposalVersion,
  }) async {
    final workspaceId = _state.workspaceId;
    if (workspaceId == null) return;
    _emit(
      _state.copyWith(
        detailStatus: ProductProposalDetailStatus.reviewLoading,
        clearReview: true,
        clearError: true,
      ),
    );
    final result = await _guard(
      () => _repository.review(
        workspaceId: workspaceId,
        proposalId: proposal.id,
        proposalVersion: proposalVersion,
      ),
    );
    if (!_acceptDetail(generation, sequence, proposal.id)) return;
    final review = result.data;
    if (!result.isSuccess || review == null) {
      _detailFailure(result);
      return;
    }
    _emit(
      _state.copyWith(
        detailStatus: ProductProposalDetailStatus.ready,
        review: review,
        selectedHunkIds: const {},
        clearError: true,
      ),
    );
  }

  void reset() {
    _generation++;
    _listSequence = 0;
    _detailSequence = 0;
    _pendingKeys.clear();
    _emit(ProductDocumentProposalsState.idle());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listeners.clear();
  }

  void _emit(ProductDocumentProposalsState next) {
    if (_disposed) return;
    _state = next;
    for (final listener in List<ProductProposalsListener>.of(_listeners)) {
      listener();
    }
  }
}
