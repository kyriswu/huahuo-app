import '../../domain/product_result.dart';
import '../../domain/support/product_support.dart';

enum ProductSupportStatus { idle, loading, ready, failure }

typedef ProductSupportListener = void Function();

final class ProductSupportState {
  const ProductSupportState({
    required this.status,
    required this.catalog,
    required this.query,
    required this.categoryId,
    required this.article,
    required this.legalDocument,
    required this.contentLoading,
    required this.errorMessage,
    required this.retryable,
  });

  const ProductSupportState.idle()
    : this(
        status: ProductSupportStatus.idle,
        catalog: null,
        query: '',
        categoryId: null,
        article: null,
        legalDocument: null,
        contentLoading: false,
        errorMessage: null,
        retryable: false,
      );

  final ProductSupportStatus status;
  final ProductSupportCatalog? catalog;
  final String query;
  final String? categoryId;
  final ProductSupportArticle? article;
  final ProductLegalDocument? legalDocument;
  final bool contentLoading;
  final String? errorMessage;
  final bool retryable;

  List<ProductSupportArticleSummary> get filteredArticles => List.unmodifiable(
    (catalog?.articles ?? const <ProductSupportArticleSummary>[]).where(
      (item) =>
          (categoryId == null || item.categoryId == categoryId) &&
          item.matches(query),
    ),
  );

  ProductSupportState copyWith({
    ProductSupportStatus? status,
    ProductSupportCatalog? catalog,
    String? query,
    String? categoryId,
    ProductSupportArticle? article,
    ProductLegalDocument? legalDocument,
    bool? contentLoading,
    String? errorMessage,
    bool? retryable,
    bool clearCategory = false,
    bool clearArticle = false,
    bool clearLegal = false,
    bool clearError = false,
  }) => ProductSupportState(
    status: status ?? this.status,
    catalog: catalog ?? this.catalog,
    query: query ?? this.query,
    categoryId: clearCategory ? null : categoryId ?? this.categoryId,
    article: clearArticle ? null : article ?? this.article,
    legalDocument: clearLegal ? null : legalDocument ?? this.legalDocument,
    contentLoading: contentLoading ?? this.contentLoading,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    retryable: clearError ? false : retryable ?? this.retryable,
  );
}

final class ProductSupportController {
  ProductSupportController(this._repository);

  final ProductSupportRepository _repository;
  final Set<ProductSupportListener> _listeners = {};
  ProductSupportState _state = const ProductSupportState.idle();
  int _generation = 0;
  int _contentSequence = 0;
  bool _disposed = false;

  ProductSupportState get state => _state;

  void addListener(ProductSupportListener listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(ProductSupportListener listener) {
    _listeners.remove(listener);
  }

  Future<void> load() async {
    final generation = ++_generation;
    _emit(
      _state.copyWith(status: ProductSupportStatus.loading, clearError: true),
    );
    final result = await _guard(_repository.loadCatalog);
    if (_disposed || generation != _generation) return;
    final catalog = result.data;
    if (result.isSuccess && catalog != null) {
      _emit(
        _state.copyWith(
          status: ProductSupportStatus.ready,
          catalog: catalog,
          clearError: true,
        ),
      );
    } else {
      _emit(
        _state.copyWith(
          status: ProductSupportStatus.failure,
          errorMessage: result.message,
          retryable: result.retryable,
        ),
      );
    }
  }

  void setQuery(String value) {
    _emit(_state.copyWith(query: value, clearArticle: true, clearLegal: true));
  }

  void selectCategory(String? categoryId) {
    final valid =
        categoryId == null ||
        _state.catalog?.categories.any((item) => item.id == categoryId) == true;
    if (!valid) return;
    _emit(
      _state.copyWith(
        categoryId: categoryId,
        clearCategory: categoryId == null,
        clearArticle: true,
        clearLegal: true,
      ),
    );
  }

  Future<void> openArticle(String articleId) async {
    if (_state.catalog?.articles.any((item) => item.id == articleId) != true) {
      return;
    }
    final generation = _generation;
    final sequence = ++_contentSequence;
    _emit(
      _state.copyWith(
        contentLoading: true,
        clearArticle: true,
        clearLegal: true,
        clearError: true,
      ),
    );
    final result = await _guard(() => _repository.loadArticle(articleId));
    if (!_accept(generation, sequence)) return;
    if (result.isSuccess && result.data != null) {
      _emit(
        _state.copyWith(
          article: result.data,
          contentLoading: false,
          clearError: true,
        ),
      );
    } else {
      _contentFailure(result);
    }
  }

  Future<void> openLegal(ProductLegalDocumentKind kind) async {
    final generation = _generation;
    final sequence = ++_contentSequence;
    _emit(
      _state.copyWith(
        contentLoading: true,
        clearArticle: true,
        clearLegal: true,
        clearError: true,
      ),
    );
    final result = await _guard(() => _repository.loadLegal(kind));
    if (!_accept(generation, sequence)) return;
    if (result.isSuccess && result.data != null) {
      _emit(
        _state.copyWith(
          legalDocument: result.data,
          contentLoading: false,
          clearError: true,
        ),
      );
    } else {
      _contentFailure(result);
    }
  }

  void closeContent() {
    _contentSequence++;
    _emit(
      _state.copyWith(
        contentLoading: false,
        clearArticle: true,
        clearLegal: true,
        clearError: true,
      ),
    );
  }

  bool _accept(int generation, int sequence) =>
      !_disposed && generation == _generation && sequence == _contentSequence;

  void _contentFailure(ProductResult<Object?> result) {
    _emit(
      _state.copyWith(
        contentLoading: false,
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
        code: 'PRODUCT_SUPPORT_UNEXPECTED',
        message: '帮助内容暂时无法读取',
        retryable: true,
      );
    }
  }

  void reset() {
    _generation++;
    _contentSequence = 0;
    _emit(const ProductSupportState.idle());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listeners.clear();
  }

  void _emit(ProductSupportState next) {
    if (_disposed) return;
    _state = next;
    for (final listener in List<ProductSupportListener>.of(_listeners)) {
      listener();
    }
  }
}
