import '../../domain/home/product_home.dart';

enum ProductHomeStatus { idle, loading, empty, ready, failure }

typedef ProductHomeListener = void Function();
typedef ProductHomeKeyFactory = String Function(String suggestionId);

final class ProductHomeState {
  const ProductHomeState({
    required this.status,
    required this.workspaceId,
    required this.home,
    required this.acknowledgingSuggestionId,
    required this.errorCode,
    required this.errorMessage,
    required this.retryable,
  });

  const ProductHomeState.idle()
    : this(
        status: ProductHomeStatus.idle,
        workspaceId: null,
        home: null,
        acknowledgingSuggestionId: null,
        errorCode: null,
        errorMessage: null,
        retryable: false,
      );

  final ProductHomeStatus status;
  final String? workspaceId;
  final ProductHome? home;
  final String? acknowledgingSuggestionId;
  final String? errorCode;
  final String? errorMessage;
  final bool retryable;

  ProductHomeState copyWith({
    ProductHomeStatus? status,
    String? workspaceId,
    ProductHome? home,
    String? acknowledgingSuggestionId,
    String? errorCode,
    String? errorMessage,
    bool? retryable,
    bool clearHome = false,
    bool clearAcknowledging = false,
    bool clearError = false,
  }) => ProductHomeState(
    status: status ?? this.status,
    workspaceId: workspaceId ?? this.workspaceId,
    home: clearHome ? null : home ?? this.home,
    acknowledgingSuggestionId: clearAcknowledging
        ? null
        : acknowledgingSuggestionId ?? this.acknowledgingSuggestionId,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    retryable: clearError ? false : retryable ?? this.retryable,
  );
}

final class ProductHomeController {
  ProductHomeController(this._repository, {ProductHomeKeyFactory? keyFactory})
    : _keyFactory = keyFactory ?? _defaultHomeKey;

  final ProductHomeRepository _repository;
  final ProductHomeKeyFactory _keyFactory;
  final Set<ProductHomeListener> _listeners = <ProductHomeListener>{};
  final Map<String, String> _pendingKeys = <String, String>{};
  ProductHomeState _state = const ProductHomeState.idle();
  int _generation = 0;
  int _loadSequence = 0;
  bool _disposed = false;

  ProductHomeState get state => _state;

  void addListener(ProductHomeListener listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(ProductHomeListener listener) {
    _listeners.remove(listener);
  }

  Future<void> bindWorkspace(String? workspaceId) async {
    final normalized = workspaceId?.trim();
    if (normalized == null || normalized.isEmpty) {
      reset();
      return;
    }
    if (_state.workspaceId == normalized &&
        _state.status != ProductHomeStatus.idle) {
      return;
    }
    _generation++;
    _loadSequence = 0;
    _pendingKeys.clear();
    _emit(
      ProductHomeState(
        status: ProductHomeStatus.loading,
        workspaceId: normalized,
        home: null,
        acknowledgingSuggestionId: null,
        errorCode: null,
        errorMessage: null,
        retryable: false,
      ),
    );
    await _load(normalized, generation: _generation);
  }

  Future<void> reload() async {
    final workspaceId = _state.workspaceId;
    if (workspaceId == null) return;
    await _load(workspaceId, generation: _generation);
  }

  Future<bool> acknowledgeSuggestion() async {
    final workspaceId = _state.workspaceId;
    final suggestion = _state.home?.suggestion;
    if (workspaceId == null ||
        suggestion == null ||
        suggestion.acknowledged ||
        _state.acknowledgingSuggestionId != null) {
      return false;
    }
    final generation = _generation;
    final key = _pendingKeys.putIfAbsent(
      suggestion.id,
      () => _keyFactory(suggestion.id),
    );
    _emit(
      _state.copyWith(
        acknowledgingSuggestionId: suggestion.id,
        clearError: true,
      ),
    );
    final result = await _repository.markSuggestionViewed(
      workspaceId: workspaceId,
      suggestionId: suggestion.id,
      idempotencyKey: key,
    );
    if (_disposed || generation != _generation) return false;
    if (result.isSuccess) {
      _pendingKeys.remove(suggestion.id);
      _emit(
        _state.copyWith(
          home: _state.home?.acknowledgeSuggestion(suggestion.id),
          clearAcknowledging: true,
          clearError: true,
        ),
      );
      return true;
    }
    _emit(
      _state.copyWith(
        clearAcknowledging: true,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
    return false;
  }

  Future<void> _load(String workspaceId, {required int generation}) async {
    final sequence = ++_loadSequence;
    _emit(_state.copyWith(status: ProductHomeStatus.loading, clearError: true));
    final result = await _repository.load(workspaceId);
    if (_disposed ||
        generation != _generation ||
        sequence != _loadSequence ||
        _state.workspaceId != workspaceId) {
      return;
    }
    final home = result.data;
    if (result.isSuccess && home != null) {
      _emit(
        _state.copyWith(
          status: home.hasContent
              ? ProductHomeStatus.ready
              : ProductHomeStatus.empty,
          home: home,
          clearError: true,
        ),
      );
      return;
    }
    _emit(
      _state.copyWith(
        status: ProductHomeStatus.failure,
        errorCode: result.code,
        errorMessage: result.message,
        retryable: result.retryable,
      ),
    );
  }

  void reset() {
    _generation++;
    _loadSequence = 0;
    _pendingKeys.clear();
    _emit(const ProductHomeState.idle());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listeners.clear();
  }

  void _emit(ProductHomeState next) {
    if (_disposed) return;
    _state = next;
    for (final listener in List<ProductHomeListener>.of(_listeners)) {
      listener();
    }
  }
}

String _defaultHomeKey(String suggestionId) =>
    'home-viewed-$suggestionId-${DateTime.now().toUtc().microsecondsSinceEpoch}';
