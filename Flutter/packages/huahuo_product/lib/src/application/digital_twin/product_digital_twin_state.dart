import 'dart:typed_data';

import '../../domain/digital_twin/product_digital_twin.dart';
import '../../domain/proposals/product_document_proposal.dart';

enum ProductDigitalTwinStatus { idle, loading, empty, ready, failure }

final class ProductDigitalTwinState {
  ProductDigitalTwinState({
    required this.workspaceId,
    required this.status,
    required this.current,
    required this.schedule,
    required Iterable<ProductDocumentProposal> proposals,
    required Iterable<ProductDigitalTwinVersion> versions,
    required this.selectedFileId,
    required this.selectedProposalId,
    required this.review,
    required Iterable<ProductProposalVersion> proposalVersions,
    required Set<String> selectedHunkIds,
    required this.confirmation,
    required this.versionDetail,
    required Iterable<ProductDigitalTwinFile> previewFiles,
    required this.comparison,
    required this.archiveVersionId,
    required this.archiveSizeBytes,
    required this.busyAction,
    required this.errorCode,
    required this.errorMessage,
    required this.retryable,
  }) : proposals = List.unmodifiable(proposals),
       versions = List.unmodifiable(versions),
       proposalVersions = List.unmodifiable(proposalVersions),
       selectedHunkIds = Set.unmodifiable(selectedHunkIds),
       previewFiles = List.unmodifiable(previewFiles);

  ProductDigitalTwinState.idle()
    : this(
        workspaceId: null,
        status: ProductDigitalTwinStatus.idle,
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

  final String? workspaceId;
  final ProductDigitalTwinStatus status;
  final ProductDigitalTwinCurrent? current;
  final ProductDigitalTwinSchedule? schedule;
  final List<ProductDocumentProposal> proposals;
  final List<ProductDigitalTwinVersion> versions;
  final String? selectedFileId;
  final String? selectedProposalId;
  final ProductProposalReview? review;
  final List<ProductProposalVersion> proposalVersions;
  final Set<String> selectedHunkIds;
  final ProductDigitalTwinConfirmation? confirmation;
  final ProductDigitalTwinVersionDetail? versionDetail;
  final List<ProductDigitalTwinFile> previewFiles;
  final ProductDigitalTwinComparison? comparison;
  final String? archiveVersionId;
  final int? archiveSizeBytes;
  final String? busyAction;
  final String? errorCode;
  final String? errorMessage;
  final bool retryable;

  bool get isBusy => busyAction != null;
  ProductDigitalTwinFile? get selectedFile =>
      current?.files.where((file) => file.id == selectedFileId).firstOrNull;
  ProductDocumentProposal? get selectedProposal => proposals
      .where((proposal) => proposal.id == selectedProposalId)
      .firstOrNull;
  int get readyProposalCount =>
      proposals.where((proposal) => proposal.canApply).length;
  bool get isViewingCurrentProposalVersion =>
      review != null && review!.proposalVersion == selectedProposal?.version;
  bool get canRevise =>
      selectedProposal?.canRevise == true && isViewingCurrentProposalVersion;

  ProductDigitalTwinState copyWith({
    ProductDigitalTwinStatus? status,
    ProductDigitalTwinCurrent? current,
    ProductDigitalTwinSchedule? schedule,
    Iterable<ProductDocumentProposal>? proposals,
    Iterable<ProductDigitalTwinVersion>? versions,
    String? selectedFileId,
    String? selectedProposalId,
    ProductProposalReview? review,
    Iterable<ProductProposalVersion>? proposalVersions,
    Set<String>? selectedHunkIds,
    ProductDigitalTwinConfirmation? confirmation,
    ProductDigitalTwinVersionDetail? versionDetail,
    Iterable<ProductDigitalTwinFile>? previewFiles,
    ProductDigitalTwinComparison? comparison,
    String? archiveVersionId,
    int? archiveSizeBytes,
    String? busyAction,
    String? errorCode,
    String? errorMessage,
    bool? retryable,
    bool clearSelection = false,
    bool clearReview = false,
    bool clearConfirmation = false,
    bool clearVersion = false,
    bool clearArchive = false,
    bool clearBusy = false,
    bool clearError = false,
  }) => ProductDigitalTwinState(
    workspaceId: workspaceId,
    status: status ?? this.status,
    current: current ?? this.current,
    schedule: schedule ?? this.schedule,
    proposals: proposals ?? this.proposals,
    versions: versions ?? this.versions,
    selectedFileId: clearSelection
        ? null
        : selectedFileId ?? this.selectedFileId,
    selectedProposalId: clearSelection
        ? null
        : selectedProposalId ?? this.selectedProposalId,
    review: clearSelection || clearReview ? null : review ?? this.review,
    proposalVersions: clearSelection || clearReview
        ? const []
        : proposalVersions ?? this.proposalVersions,
    selectedHunkIds: clearSelection || clearReview
        ? const {}
        : selectedHunkIds ?? this.selectedHunkIds,
    confirmation: clearConfirmation ? null : confirmation ?? this.confirmation,
    versionDetail: clearVersion ? null : versionDetail ?? this.versionDetail,
    previewFiles: clearVersion ? const [] : previewFiles ?? this.previewFiles,
    comparison: clearVersion ? null : comparison ?? this.comparison,
    archiveVersionId: clearArchive
        ? null
        : archiveVersionId ?? this.archiveVersionId,
    archiveSizeBytes: clearArchive
        ? null
        : archiveSizeBytes ?? this.archiveSizeBytes,
    busyAction: clearBusy ? null : busyAction ?? this.busyAction,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    retryable: clearError ? false : retryable ?? this.retryable,
  );
}

final class ProductDigitalTwinArchive {
  ProductDigitalTwinArchive({required this.versionId, required Uint8List bytes})
    : bytes = Uint8List.fromList(bytes);
  final String versionId;
  final Uint8List bytes;
}
