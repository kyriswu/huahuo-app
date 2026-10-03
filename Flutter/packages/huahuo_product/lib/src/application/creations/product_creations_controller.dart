import '../../domain/creations/product_creation.dart';
import '../../domain/product_result.dart';
import 'product_creations_state.dart';

typedef ProductCreationsListener = void Function();
typedef ProductCreationsKeyFactory = String Function(String action);

final class ProductCreationsController {
  ProductCreationsController(
    this._repository, {
    ProductCreationsKeyFactory? keyFactory,
  }) : _keyFactory = keyFactory ?? _defaultKey;

  final ProductCreationsRepository _repository;
  final ProductCreationsKeyFactory _keyFactory;
  final Set<ProductCreationsListener> _listeners = {};
  final Map<String, String> _pendingKeys = {};
  ProductCreationsState _state = const ProductCreationsState.idle();
  int _generation = 0;
  int _listSequence = 0;
  int _detailSequence = 0;
  int _revisionSequence = 0;
  bool _disposed = false;

  ProductCreationsState get state => _state;

  void addListener(ProductCreationsListener listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(ProductCreationsListener listener) {
    _listeners.remove(listener);
  }

  Future<void> bindWorkspace(String? workspaceId) async {
    final id = workspaceId?.trim();
    if (id == null || id.isEmpty) {
      reset();
      return;
    }
    if (_state.workspaceId == id &&
        _state.status != ProductCreationsStatus.idle) {
      return;
    }
    _generation++;
    _listSequence = 0;
    _detailSequence = 0;
    _revisionSequence = 0;
    _pendingKeys.clear();
    _emit(
      ProductCreationsState(
        workspaceId: id,
        status: ProductCreationsStatus.loading,
        items: const [],
        selectedId: null,
        detailStatus: ProductCreationDetailStatus.idle,
        document: null,
        titleDraft: '',
        markdownDraft: '',
        revisionsStatus: ProductCreationRevisionsStatus.idle,
        revisions: const [],
        busyAction: null,
        errorCode: null,
        errorMessage: null,
        retryable: false,
      ),
    );
    await _loadList(id, _generation);
  }

  Future<void> reload() async {
    final id = _state.workspaceId;
    if (id != null) await _loadList(id, _generation);
  }

  Future<void> select(String creationId) async {
    final id = creationId.trim();
    final workspaceId = _state.workspaceId;
    if (workspaceId == null ||
        id.isEmpty ||
        !_state.items.any((item) => item.id == id)) {
      return;
    }
    final generation = _generation;
    final sequence = ++_detailSequence;
    _revisionSequence++;
    _emit(
      _state.copyWith(
        selectedId: id,
        detailStatus: ProductCreationDetailStatus.loading,
        clearDocument: true,
        clearRevisions: true,
        clearError: true,
      ),
    );
    final result = await _guard(() => _repository.document(workspaceId, id));
    if (!_acceptDetail(generation, sequence, id)) return;
    final document = result.data;
    if (!result.isSuccess || document == null) {
      _detailFailure(result);
      return;
    }
    _showDocument(document);
  }

  void updateTitle(String value) {
    if (_state.document == null || _state.busyAction != null) return;
    _emit(_state.copyWith(titleDraft: value, clearError: true));
  }

  void updateMarkdown(String value) {
    if (_state.document == null || _state.busyAction != null) return;
    _emit(_state.copyWith(markdownDraft: value, clearError: true));
  }

  void discardEdits() {
    final document = _state.document;
    if (document == null || _state.busyAction != null) return;
    _emit(
      _state.copyWith(
        titleDraft: document.summary.title,
        markdownDraft: document.rawMarkdown,
        clearError: true,
      ),
    );
  }

  Future<bool> create({required String title, String rawMarkdown = ''}) async {
    final workspaceId = _state.workspaceId;
    final normalizedTitle = title.trim();
    if (workspaceId == null || _state.busyAction != null) return false;
    if (!_validDraft(normalizedTitle, rawMarkdown)) return false;
    final action = 'create:$normalizedTitle:${rawMarkdown.hashCode}';
    final key = _pendingKeys.putIfAbsent(action, () => _keyFactory(action));
    final generation = _generation;
    _emit(_state.copyWith(busyAction: action, clearError: true));
    final result = await _guard(
      () => _repository.create(
        workspaceId: workspaceId,
        title: normalizedTitle,
        rawMarkdown: rawMarkdown,
        idempotencyKey: key,
      ),
    );
    if (!_acceptMutation(generation, workspaceId, action)) return false;
    final document = result.data;
    if (!result.isSuccess || document == null) {
      _mutationFailure(result);
      return false;
    }
    _pendingKeys.remove(action);
    _upsertDocument(document);
    return true;
  }

  Future<bool> save() async {
    final workspaceId = _state.workspaceId;
    final current = _state.document;
    if (workspaceId == null ||
        current == null ||
        _state.busyAction != null ||
        !_state.isDirty) {
      return false;
    }
    final title = _state.titleDraft.trim();
    final markdown = _state.markdownDraft;
    if (!_validDraft(title, markdown)) return false;
    final intent =
        '${current.summary.id}:${current.summary.revisionId}:'
        '$title:${markdown.hashCode}';
    final action = 'save:$intent';
    final titleKey = _pendingKeys.putIfAbsent(
      'title:$intent',
      () => _keyFactory('title:$intent'),
    );
    final contentKey = _pendingKeys.putIfAbsent(
      'content:$intent',
      () => _keyFactory('content:$intent'),
    );
    final generation = _generation;
    _emit(_state.copyWith(busyAction: action, clearError: true));
    final result = await _guard(
      () => _repository.save(
        workspaceId: workspaceId,
        current: current,
        title: title,
        rawMarkdown: markdown,
        titleIdempotencyKey: titleKey,
        contentIdempotencyKey: contentKey,
      ),
    );
    if (!_acceptMutation(generation, workspaceId, action) ||
        _state.selectedId != current.summary.id) {
      return false;
    }
    final document = result.data;
    if (!result.isSuccess || document == null) {
      _mutationFailure(result);
      return false;
    }
    _pendingKeys.remove('title:$intent');
    _pendingKeys.remove('content:$intent');
    _upsertDocument(document);
    return true;
  }

  Future<bool> deleteSelected() => _lifecycleMutation(restore: false);

  Future<bool> restoreSelected() => _lifecycleMutation(restore: true);

  Future<bool> _lifecycleMutation({required bool restore}) async {
    final workspaceId = _state.workspaceId;
    final creation = _state.document?.summary;
    if (workspaceId == null || creation == null || _state.busyAction != null) {
      return false;
    }
    if (restore != creation.isTrashed) return false;
    final verb = restore ? 'restore' : 'delete';
    final action = '$verb:${creation.id}:${creation.revisionId}';
    final key = _pendingKeys.putIfAbsent(action, () => _keyFactory(action));
    final generation = _generation;
    _emit(_state.copyWith(busyAction: action, clearError: true));
    final result = await _guard(
      () => restore
          ? _repository.restore(
              workspaceId: workspaceId,
              creation: creation,
              idempotencyKey: key,
            )
          : _repository.delete(
              workspaceId: workspaceId,
              creation: creation,
              idempotencyKey: key,
            ),
    );
    if (!_acceptMutation(generation, workspaceId, action)) return false;
    if (!result.isSuccess) {
      _mutationFailure(result);
      return false;
    }
    _pendingKeys.remove(action);
    _detailSequence++;
    _revisionSequence++;
    _emit(
      _state.copyWith(
        clearBusy: true,
        clearSelection: true,
        clearDocument: true,
        clearRevisions: true,
        clearError: true,
      ),
    );
    await _loadList(workspaceId, generation);
    return true;
  }

  Future<void> loadRevisions() async {
    final workspaceId = _state.workspaceId;
    final creationId = _state.selectedId;
    if (workspaceId == null || creationId == null) return;
    final generation = _generation;
    final sequence = ++_revisionSequence;
    _emit(
      _state.copyWith(
        revisionsStatus: ProductCreationRevisionsStatus.loading,
        revisions: const [],
        clearError: true,
      ),
    );
    final result = await _guard(
      () => _repository.revisions(
        workspaceId: workspaceId,
        creationId: creationId,
      ),
    );
    if (_disposed ||
        generation != _generation ||
        sequence != _revisionSequence ||
        _state.selectedId != creationId) {
      return;
    }
    final revisions = result.data;
    if (result.isSuccess && revisions != null) {
      final sorted = List<ProductCreationRevision>.of(revisions)
        ..sort((left, right) => right.revision.compareTo(left.revision));
      _emit(
        _state.copyWith(
          revisionsStatus: ProductCreationRevisionsStatus.ready,
          revisions: sorted,
          clearError: true,
        ),
      );
      return;
    }
    _emit(
      _state.copyWith(
        revisionsStatus: ProductCreationRevisionsStatus.failure,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  void resetSelectionForView() {
    _detailSequence++;
    _revisionSequence++;
    _emit(
      _state.copyWith(
        clearSelection: true,
        clearDocument: true,
        clearRevisions: true,
        detailStatus: ProductCreationDetailStatus.idle,
        clearError: true,
      ),
    );
  }

  Future<void> _loadList(String workspaceId, int generation) async {
    final sequence = ++_listSequence;
    _emit(
      _state.copyWith(status: ProductCreationsStatus.loading, clearError: true),
    );
    final result = await _guard(() => _repository.list(workspaceId));
    if (_disposed ||
        generation != _generation ||
        sequence != _listSequence ||
        _state.workspaceId != workspaceId) {
      return;
    }
    final items = result.data;
    if (result.isSuccess && items != null) {
      final sorted = List<ProductCreationSummary>.of(items)
        ..sort((left, right) => right.revision.compareTo(left.revision));
      _emit(
        _state.copyWith(
          status: sorted.isEmpty
              ? ProductCreationsStatus.empty
              : ProductCreationsStatus.ready,
          items: sorted,
          clearError: true,
        ),
      );
      return;
    }
    _emit(
      _state.copyWith(
        status: ProductCreationsStatus.failure,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  bool _validDraft(String title, String markdown) {
    if (title.isNotEmpty && title.length <= 300 && markdown.length <= 2097152) {
      return true;
    }
    _emit(
      _state.copyWith(
        errorCode: 'CREATION_DRAFT_INVALID',
        errorMessage: title.isEmpty ? '请输入创作标题' : '创作内容超出长度限制',
        retryable: false,
      ),
    );
    return false;
  }

  bool _acceptDetail(int generation, int sequence, String id) =>
      !_disposed &&
      generation == _generation &&
      sequence == _detailSequence &&
      _state.selectedId == id;

  bool _acceptMutation(int generation, String workspaceId, String action) =>
      !_disposed &&
      generation == _generation &&
      _state.workspaceId == workspaceId &&
      _state.busyAction == action;

  void _showDocument(ProductCreationDocument document) {
    _emit(
      _state.copyWith(
        selectedId: document.summary.id,
        detailStatus: ProductCreationDetailStatus.ready,
        document: document,
        titleDraft: document.summary.title,
        markdownDraft: document.rawMarkdown,
        clearBusy: true,
        clearError: true,
      ),
    );
  }

  void _upsertDocument(ProductCreationDocument document) {
    final items = List<ProductCreationSummary>.of(_state.items);
    final index = items.indexWhere((item) => item.id == document.summary.id);
    if (index < 0) {
      items.insert(0, document.summary);
    } else {
      items[index] = document.summary;
    }
    _emit(
      _state.copyWith(
        status: ProductCreationsStatus.ready,
        items: items,
        selectedId: document.summary.id,
        detailStatus: ProductCreationDetailStatus.ready,
        document: document,
        titleDraft: document.summary.title,
        markdownDraft: document.rawMarkdown,
        clearBusy: true,
        clearRevisions: true,
        clearError: true,
      ),
    );
  }

  void _detailFailure(ProductResult<Object?> result) {
    _emit(
      _state.copyWith(
        detailStatus: ProductCreationDetailStatus.failure,
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
        code: 'PRODUCT_CREATIONS_UNEXPECTED',
        message: '创作服务暂时不可用，请重试',
        retryable: true,
      );
    }
  }

  void reset() {
    _generation++;
    _listSequence = 0;
    _detailSequence = 0;
    _revisionSequence = 0;
    _pendingKeys.clear();
    _emit(const ProductCreationsState.idle());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listeners.clear();
  }

  void _emit(ProductCreationsState next) {
    if (_disposed) return;
    _state = next;
    for (final listener in List<ProductCreationsListener>.of(_listeners)) {
      listener();
    }
  }
}

String _defaultKey(String action) =>
    'creation-$action-${DateTime.now().toUtc().microsecondsSinceEpoch}';
