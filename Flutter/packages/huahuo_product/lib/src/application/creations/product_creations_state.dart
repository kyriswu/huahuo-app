import '../../domain/creations/product_creation.dart';

enum ProductCreationsStatus { idle, loading, empty, ready, failure }

enum ProductCreationDetailStatus { idle, loading, ready, failure }

enum ProductCreationRevisionsStatus { idle, loading, ready, failure }

final class ProductCreationsState {
  const ProductCreationsState({
    required this.workspaceId,
    required this.status,
    required this.items,
    required this.selectedId,
    required this.detailStatus,
    required this.document,
    required this.titleDraft,
    required this.markdownDraft,
    required this.revisionsStatus,
    required this.revisions,
    required this.busyAction,
    required this.errorCode,
    required this.errorMessage,
    required this.retryable,
  });

  const ProductCreationsState.idle()
    : this(
        workspaceId: null,
        status: ProductCreationsStatus.idle,
        items: const <ProductCreationSummary>[],
        selectedId: null,
        detailStatus: ProductCreationDetailStatus.idle,
        document: null,
        titleDraft: '',
        markdownDraft: '',
        revisionsStatus: ProductCreationRevisionsStatus.idle,
        revisions: const <ProductCreationRevision>[],
        busyAction: null,
        errorCode: null,
        errorMessage: null,
        retryable: false,
      );

  final String? workspaceId;
  final ProductCreationsStatus status;
  final List<ProductCreationSummary> items;
  final String? selectedId;
  final ProductCreationDetailStatus detailStatus;
  final ProductCreationDocument? document;
  final String titleDraft;
  final String markdownDraft;
  final ProductCreationRevisionsStatus revisionsStatus;
  final List<ProductCreationRevision> revisions;
  final String? busyAction;
  final String? errorCode;
  final String? errorMessage;
  final bool retryable;

  bool get isDirty {
    final current = document;
    return current != null &&
        (titleDraft != current.summary.title ||
            markdownDraft != current.rawMarkdown);
  }

  ProductCreationsState copyWith({
    String? workspaceId,
    ProductCreationsStatus? status,
    List<ProductCreationSummary>? items,
    String? selectedId,
    ProductCreationDetailStatus? detailStatus,
    ProductCreationDocument? document,
    String? titleDraft,
    String? markdownDraft,
    ProductCreationRevisionsStatus? revisionsStatus,
    List<ProductCreationRevision>? revisions,
    String? busyAction,
    String? errorCode,
    String? errorMessage,
    bool? retryable,
    bool clearSelection = false,
    bool clearDocument = false,
    bool clearRevisions = false,
    bool clearBusy = false,
    bool clearError = false,
  }) => ProductCreationsState(
    workspaceId: workspaceId ?? this.workspaceId,
    status: status ?? this.status,
    items: List.unmodifiable(items ?? this.items),
    selectedId: clearSelection ? null : selectedId ?? this.selectedId,
    detailStatus: detailStatus ?? this.detailStatus,
    document: clearDocument ? null : document ?? this.document,
    titleDraft: clearDocument ? '' : titleDraft ?? this.titleDraft,
    markdownDraft: clearDocument ? '' : markdownDraft ?? this.markdownDraft,
    revisionsStatus: clearRevisions
        ? ProductCreationRevisionsStatus.idle
        : revisionsStatus ?? this.revisionsStatus,
    revisions: clearRevisions
        ? const <ProductCreationRevision>[]
        : List.unmodifiable(revisions ?? this.revisions),
    busyAction: clearBusy ? null : busyAction ?? this.busyAction,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    retryable: clearError ? false : retryable ?? this.retryable,
  );
}
