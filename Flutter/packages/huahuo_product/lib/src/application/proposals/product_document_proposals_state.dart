import '../../domain/creations/product_creation.dart';
import '../../domain/proposals/product_document_proposal.dart';

enum ProductProposalsStatus { idle, loading, empty, ready, failure }

enum ProductProposalDetailStatus {
  idle,
  loading,
  polling,
  reviewLoading,
  ready,
  noChanges,
  terminal,
  failure,
}

final class ProductDocumentProposalsState {
  ProductDocumentProposalsState({
    required this.workspaceId,
    required this.targetCreation,
    required this.status,
    required Iterable<ProductDocumentProposal> items,
    required this.nextCursor,
    required this.loadingMore,
    required this.selected,
    required this.detailStatus,
    required this.review,
    required Iterable<ProductProposalVersion> versions,
    required Set<String> selectedHunkIds,
    required this.busyAction,
    required this.pollAttempt,
    required this.errorCode,
    required this.errorMessage,
    required this.retryable,
  }) : items = List.unmodifiable(items),
       versions = List.unmodifiable(versions),
       selectedHunkIds = Set.unmodifiable(selectedHunkIds);

  ProductDocumentProposalsState.idle()
    : this(
        workspaceId: null,
        targetCreation: null,
        status: ProductProposalsStatus.idle,
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
      );

  final String? workspaceId;
  final ProductCreationDocument? targetCreation;
  final ProductProposalsStatus status;
  final List<ProductDocumentProposal> items;
  final String? nextCursor;
  final bool loadingMore;
  final ProductDocumentProposal? selected;
  final ProductProposalDetailStatus detailStatus;
  final ProductProposalReview? review;
  final List<ProductProposalVersion> versions;
  final Set<String> selectedHunkIds;
  final String? busyAction;
  final int pollAttempt;
  final String? errorCode;
  final String? errorMessage;
  final bool retryable;

  bool get canLoadMore => nextCursor != null && !loadingMore;
  bool get isBusy => busyAction != null;

  ProductDocumentProposalsState copyWith({
    String? workspaceId,
    ProductCreationDocument? targetCreation,
    ProductProposalsStatus? status,
    Iterable<ProductDocumentProposal>? items,
    String? nextCursor,
    bool? loadingMore,
    ProductDocumentProposal? selected,
    ProductProposalDetailStatus? detailStatus,
    ProductProposalReview? review,
    Iterable<ProductProposalVersion>? versions,
    Set<String>? selectedHunkIds,
    String? busyAction,
    int? pollAttempt,
    String? errorCode,
    String? errorMessage,
    bool? retryable,
    bool clearCursor = false,
    bool clearSelection = false,
    bool clearReview = false,
    bool clearBusy = false,
    bool clearError = false,
  }) => ProductDocumentProposalsState(
    workspaceId: workspaceId ?? this.workspaceId,
    targetCreation: targetCreation ?? this.targetCreation,
    status: status ?? this.status,
    items: items ?? this.items,
    nextCursor: clearCursor ? null : nextCursor ?? this.nextCursor,
    loadingMore: loadingMore ?? this.loadingMore,
    selected: clearSelection ? null : selected ?? this.selected,
    detailStatus: clearSelection
        ? ProductProposalDetailStatus.idle
        : detailStatus ?? this.detailStatus,
    review: clearSelection || clearReview ? null : review ?? this.review,
    versions: clearSelection || clearReview
        ? const []
        : versions ?? this.versions,
    selectedHunkIds: clearSelection || clearReview
        ? const {}
        : selectedHunkIds ?? this.selectedHunkIds,
    busyAction: clearBusy ? null : busyAction ?? this.busyAction,
    pollAttempt: pollAttempt ?? this.pollAttempt,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    retryable: clearError ? false : retryable ?? this.retryable,
  );
}
