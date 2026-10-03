import 'dart:async';
import 'dart:convert';

import '../../domain/digital_twin/product_digital_twin.dart';
import '../../domain/product_result.dart';
import '../../domain/proposals/product_document_proposal.dart';
import 'product_digital_twin_state.dart';

part 'product_digital_twin_actions.dart';

typedef ProductDigitalTwinListener = void Function();
typedef ProductDigitalTwinKeyFactory = String Function(String action);
typedef ProductDigitalTwinDelay = Future<void> Function(Duration duration);

final class ProductDigitalTwinController {
  ProductDigitalTwinController(
    this._repository,
    this._proposals, {
    ProductDigitalTwinKeyFactory? keyFactory,
    ProductDigitalTwinDelay? delay,
    this.pollInterval = const Duration(seconds: 2),
    this.maxPollAttempts = 45,
  }) : _keyFactory = keyFactory ?? _defaultKey,
       _delay = delay ?? Future<void>.delayed;

  final ProductDigitalTwinRepository _repository;
  final ProductDocumentProposalsRepository _proposals;
  final ProductDigitalTwinKeyFactory _keyFactory;
  final ProductDigitalTwinDelay _delay;
  final Duration pollInterval;
  final int maxPollAttempts;
  final Set<ProductDigitalTwinListener> _listeners = {};
  final Map<String, String> _pendingKeys = {};
  ProductDigitalTwinState _state = ProductDigitalTwinState.idle();
  int _generation = 0;
  int _selectionSequence = 0;
  bool _disposed = false;

  ProductDigitalTwinState get state => _state;

  void addListener(ProductDigitalTwinListener listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(ProductDigitalTwinListener listener) {
    _listeners.remove(listener);
  }

  Future<void> bindWorkspace(String? workspaceId) async {
    final id = workspaceId?.trim();
    if (id == null || id.isEmpty) {
      reset();
      return;
    }
    if (_state.workspaceId == id &&
        _state.status != ProductDigitalTwinStatus.idle) {
      return;
    }
    _generation++;
    _selectionSequence = 0;
    _pendingKeys.clear();
    _emit(_initial(id, ProductDigitalTwinStatus.loading));
    await _load(id, _generation);
  }

  Future<void> reload() async {
    final workspaceId = _state.workspaceId;
    if (workspaceId == null) return;
    final generation = ++_generation;
    _selectionSequence++;
    _emit(
      _state.copyWith(
        status: ProductDigitalTwinStatus.loading,
        clearBusy: true,
        clearError: true,
      ),
    );
    await _load(workspaceId, generation);
  }

  Future<void> _load(String workspaceId, int generation) async {
    final currentFuture = _guard(() => _repository.current(workspaceId));
    final scheduleFuture = _guard(() => _repository.schedule(workspaceId));
    final versionsFuture = _guard(() => _repository.versions(workspaceId));
    final currentResult = await currentFuture;
    final scheduleResult = await scheduleFuture;
    final versionsResult = await versionsFuture;
    if (!_accept(generation, workspaceId)) return;
    final current = currentResult.data;
    final schedule = scheduleResult.data;
    final versions = versionsResult.data;
    if (!currentResult.isSuccess || current == null) {
      _loadFailure(currentResult);
      return;
    }
    if (!scheduleResult.isSuccess || schedule == null) {
      _loadFailure(scheduleResult);
      return;
    }
    if (!versionsResult.isSuccess || versions == null) {
      _loadFailure(versionsResult);
      return;
    }
    final draftItems = current.activeDraft?.items ?? const [];
    final proposalResults = await Future.wait(
      draftItems.map(
        (item) => _guard(
          () => _proposals.detail(
            workspaceId: workspaceId,
            proposalId: item.proposalId,
          ),
        ),
      ),
    );
    if (!_accept(generation, workspaceId)) return;
    final proposals = <ProductDocumentProposal>[];
    for (var index = 0; index < proposalResults.length; index++) {
      final result = proposalResults[index];
      final proposal = result.data;
      final draft = draftItems[index];
      if (!result.isSuccess || proposal == null) {
        _loadFailure(result);
        return;
      }
      if (proposal.version != draft.proposalVersion ||
          proposal.etag != draft.etag) {
        _loadFailure(
          const ProductResult.failure(
            code: 'DIGITAL_TWIN_DRAFT_STALE',
            message: '数字分身草稿已更新，请重新加载',
            retryable: true,
          ),
        );
        return;
      }
      proposals.add(proposal);
    }
    final selectedFileId = _selectFileId(current, _state.selectedFileId);
    final selectedProposalId = _selectProposalId(
      current,
      proposals,
      selectedFileId,
      _state.selectedProposalId,
    );
    _emit(
      _state.copyWith(
        status: current.files.isEmpty
            ? ProductDigitalTwinStatus.empty
            : ProductDigitalTwinStatus.ready,
        current: current,
        schedule: schedule,
        proposals: proposals,
        versions: versions,
        selectedFileId: selectedFileId,
        selectedProposalId: selectedProposalId,
        clearReview: true,
        clearBusy: true,
        clearError: true,
      ),
    );
    if (selectedProposalId != null) {
      await selectProposal(selectedProposalId);
    }
  }

  Future<void> selectFile(String fileId) async {
    final current = _state.current;
    if (current == null || !current.files.any((file) => file.id == fileId)) {
      return;
    }
    final file = current.files.firstWhere((item) => item.id == fileId);
    final proposalId = file.pendingProposalIds
        .where((id) => _state.proposals.any((item) => item.id == id))
        .firstOrNull;
    _selectionSequence++;
    _emit(
      _state.copyWith(
        selectedFileId: fileId,
        selectedProposalId: proposalId,
        clearReview: true,
        clearError: true,
      ),
    );
    if (proposalId != null) await selectProposal(proposalId);
  }

  Future<void> selectProposal(String proposalId) async {
    final workspaceId = _state.workspaceId;
    final proposal = _state.proposals
        .where((item) => item.id == proposalId)
        .firstOrNull;
    if (workspaceId == null || proposal == null) return;
    final sequence = ++_selectionSequence;
    _emit(
      _state.copyWith(
        selectedProposalId: proposalId,
        busyAction: 'review',
        clearReview: true,
        clearError: true,
      ),
    );
    if (proposal.lifecycle == ProductProposalLifecycle.generating) {
      _emit(_state.copyWith(clearBusy: true));
      return;
    }
    final reviewFuture = _guard(
      () => _proposals.review(workspaceId: workspaceId, proposalId: proposalId),
    );
    final versionsFuture = _guard(
      () =>
          _proposals.versions(workspaceId: workspaceId, proposalId: proposalId),
    );
    final result = await reviewFuture;
    final versionsResult = await versionsFuture;
    if (!_acceptSelection(sequence, proposalId)) return;
    final review = result.data;
    if (!result.isSuccess || review == null) {
      _actionFailure(result);
      return;
    }
    final versions = versionsResult.data;
    if (!versionsResult.isSuccess || versions == null) {
      _actionFailure(versionsResult);
      return;
    }
    _emit(
      _state.copyWith(
        review: review,
        proposalVersions: List<ProductProposalVersion>.of(versions)
          ..sort((left, right) => right.version.compareTo(left.version)),
        selectedHunkIds: const {},
        clearBusy: true,
        clearError: true,
      ),
    );
  }

  void toggleHunk(String hunkId) {
    final review = _state.review;
    if (!_state.isViewingCurrentProposalVersion ||
        review == null ||
        !review.hunks.any((hunk) => hunk.id == hunkId)) {
      return;
    }
    final selection = {..._state.selectedHunkIds};
    selection.contains(hunkId)
        ? selection.remove(hunkId)
        : selection.add(hunkId);
    _emit(_state.copyWith(selectedHunkIds: selection));
  }

  void clearVersionInspection() {
    _emit(_state.copyWith(clearVersion: true));
  }

  void reset() {
    _generation++;
    _selectionSequence++;
    _pendingKeys.clear();
    _emit(ProductDigitalTwinState.idle());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listeners.clear();
    _pendingKeys.clear();
  }

  Future<ProductResult<T>> _guard<T>(
    Future<ProductResult<T>> Function() request,
  ) async {
    try {
      return await request();
    } on Object {
      return const ProductResult.failure(
        code: 'DIGITAL_TWIN_UNEXPECTED',
        message: '数字分身服务暂时不可用，请重试',
        retryable: true,
      );
    }
  }

  bool _accept(int generation, String workspaceId) =>
      !_disposed &&
      generation == _generation &&
      workspaceId == _state.workspaceId;
  bool _acceptSelection(int sequence, String proposalId) =>
      !_disposed &&
      sequence == _selectionSequence &&
      proposalId == _state.selectedProposalId;

  void _loadFailure(ProductResult<Object?> result) {
    _emit(
      _state.copyWith(
        status: ProductDigitalTwinStatus.failure,
        clearBusy: true,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  void _actionFailure(ProductResult<Object?> result) {
    _emit(
      _state.copyWith(
        clearBusy: true,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  void _emit(ProductDigitalTwinState value) {
    if (_disposed) return;
    _state = value;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  ProductDigitalTwinState _initial(
    String workspaceId,
    ProductDigitalTwinStatus status,
  ) => ProductDigitalTwinState(
    workspaceId: workspaceId,
    status: status,
    current: null,
    schedule: null,
    proposals: const [],
    versions: const [],
    selectedFileId: null,
    selectedProposalId: null,
    review: null,
    proposalVersions: const [],
    selectedHunkIds: const {},
    confirmation: null,
    versionDetail: null,
    previewFiles: const [],
    comparison: null,
    archiveVersionId: null,
    archiveSizeBytes: null,
    busyAction: null,
    errorCode: null,
    errorMessage: null,
    retryable: false,
  );

  String? _selectFileId(ProductDigitalTwinCurrent current, String? preferred) {
    if (preferred != null &&
        current.files.any((file) => file.id == preferred)) {
      return preferred;
    }
    return current.files.firstOrNull?.id;
  }

  String? _selectProposalId(
    ProductDigitalTwinCurrent current,
    List<ProductDocumentProposal> proposals,
    String? fileId,
    String? preferred,
  ) {
    if (preferred != null && proposals.any((item) => item.id == preferred)) {
      return preferred;
    }
    final file = current.files.where((item) => item.id == fileId).firstOrNull;
    return file?.pendingProposalIds
        .where((id) => proposals.any((item) => item.id == id))
        .firstOrNull;
  }

  String _actionKey(String action) =>
      _pendingKeys.putIfAbsent(action, () => _keyFactory(action));

  void _completeAction(String action) => _pendingKeys.remove(action);

  static String _defaultKey(String action) {
    final digest = base64Url.encode(utf8.encode(action)).replaceAll('=', '');
    return 'digital-twin-$digest-${DateTime.now().microsecondsSinceEpoch}';
  }
}
