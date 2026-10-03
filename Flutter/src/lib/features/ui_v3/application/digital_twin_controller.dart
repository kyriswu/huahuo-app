import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/database/app_database.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../data/digital_twin_api.dart'
    show DigitalTwinApiPort, DigitalTwinPreparedRegenerationPort;
import '../data/digital_twin_material_store.dart';
import '../domain/digital_twin_models.dart';
import '../domain/digital_twin_material.dart';
import '../domain/digital_twin_operation.dart';
import '../domain/document_change_proposal_models.dart';
import '../domain/positioning_lifecycle.dart';

typedef DigitalTwinArchiveExporter = Future<bool> Function(Uint8List bytes);

const digitalTwinConfirmationBatchLimit = 20;

bool _isTwinFileId(String id) => !const {
  'social_positioning',
  'positioning',
  positioningReportOwner,
}.contains(id);

enum DigitalTwinControllerPhase {
  idle,
  loading,
  ready,
  revising,
  confirming,
  restoring,
  savingSchedule,
  loadingVersion,
  failed,
}

final class DigitalTwinConfirmationSelection {
  DigitalTwinConfirmationSelection._({
    required this.identity,
    required List<DocumentChangeProposalSnapshot> proposals,
  }) : proposals = List.unmodifiable(proposals);

  final String identity;
  final List<DocumentChangeProposalSnapshot> proposals;
}

final class DigitalTwinProposalReview {
  const DigitalTwinProposalReview({
    required this.snapshot,
    this.versions = const <DigitalTwinProposalVersion>[],
    this.diff = const <DocumentProposalDiffHunk>[],
    this.candidateMarkdown,
    this.selectedHunkIds = const <String>{},
    this.inspectedVersion,
    this.requestedVersion,
    this.loadingDetails = false,
    this.errorCode,
  });

  final DocumentChangeProposalSnapshot snapshot;
  final List<DigitalTwinProposalVersion> versions;
  final List<DocumentProposalDiffHunk> diff;
  final String? candidateMarkdown;
  final Set<String> selectedHunkIds;
  final int? inspectedVersion;
  final int? requestedVersion;
  final bool loadingDetails;
  final String? errorCode;

  bool get detailsLoaded => candidateMarkdown != null || diff.isNotEmpty;
  bool get detailsUsable =>
      detailsLoaded &&
      !loadingDetails &&
      errorCode == null &&
      requestedVersion == null;

  int get visibleVersion =>
      inspectedVersion ?? snapshot.proposal.proposalVersion;

  bool get isViewingCurrent =>
      visibleVersion == snapshot.proposal.proposalVersion;

  String? get currentDiffBundleId {
    for (final version in versions) {
      if (version.proposalVersion == snapshot.proposal.proposalVersion) {
        return version.diffBundleId;
      }
    }
    return null;
  }

  DigitalTwinProposalReview copyWith({
    DocumentChangeProposalSnapshot? snapshot,
    List<DigitalTwinProposalVersion>? versions,
    List<DocumentProposalDiffHunk>? diff,
    Object? candidateMarkdown = _unset,
    Set<String>? selectedHunkIds,
    Object? inspectedVersion = _unset,
    Object? requestedVersion = _unset,
    bool? loadingDetails,
    Object? errorCode = _unset,
  }) => DigitalTwinProposalReview(
    snapshot: snapshot ?? this.snapshot,
    versions: versions ?? this.versions,
    diff: diff ?? this.diff,
    candidateMarkdown: identical(candidateMarkdown, _unset)
        ? this.candidateMarkdown
        : candidateMarkdown as String?,
    selectedHunkIds: selectedHunkIds ?? this.selectedHunkIds,
    inspectedVersion: identical(inspectedVersion, _unset)
        ? this.inspectedVersion
        : inspectedVersion as int?,
    requestedVersion: identical(requestedVersion, _unset)
        ? this.requestedVersion
        : requestedVersion as int?,
    loadingDetails: loadingDetails ?? this.loadingDetails,
    errorCode: identical(errorCode, _unset)
        ? this.errorCode
        : errorCode as String?,
  );
}

final class DigitalTwinControllerState {
  const DigitalTwinControllerState({
    this.phase = DigitalTwinControllerPhase.idle,
    this.reviews = const <DigitalTwinProposalReview>[],
    this.versions = const <DigitalTwinVersion>[],
    this.previewFiles = const <DigitalTwinLogicalFile>[],
    this.selectedFileId,
    this.selectedProposalId,
    this.current,
    this.schedule,
    this.confirmation,
    this.versionDetail,
    this.comparison,
    this.archiveVersionId,
    this.archiveSizeBytes,
    this.errorCode,
  });

  final DigitalTwinControllerPhase phase;
  final DigitalTwinCurrent? current;
  final DigitalTwinSchedule? schedule;
  final List<DigitalTwinProposalReview> reviews;
  final List<DigitalTwinVersion> versions;
  final String? selectedFileId;
  final String? selectedProposalId;
  final DigitalTwinConfirmation? confirmation;
  final DigitalTwinVersionDetail? versionDetail;
  final List<DigitalTwinLogicalFile> previewFiles;
  final DigitalTwinVersionComparison? comparison;
  final String? archiveVersionId;
  final int? archiveSizeBytes;
  final String? errorCode;

  bool get isBusy => switch (phase) {
    DigitalTwinControllerPhase.loading ||
    DigitalTwinControllerPhase.revising ||
    DigitalTwinControllerPhase.confirming ||
    DigitalTwinControllerPhase.restoring ||
    DigitalTwinControllerPhase.savingSchedule ||
    DigitalTwinControllerPhase.loadingVersion => true,
    _ => false,
  };

  DigitalTwinLogicalFile? get selectedFile {
    final files = current?.files ?? const <DigitalTwinLogicalFile>[];
    for (final file in files) {
      if (file.id == selectedFileId) return file;
    }
    return files.isEmpty ? null : files.first;
  }

  DigitalTwinProposalReview? get selectedReview {
    for (final review in reviews) {
      if (review.snapshot.proposal.proposalId == selectedProposalId) {
        return review;
      }
    }
    return null;
  }

  int get readyProposalCount =>
      reviews.any(
            (review) => const {
              DocumentProposalState.generating,
              DocumentProposalState.applying,
            }.contains(review.snapshot.proposal.state),
          ) ||
          reviews.any(
            (review) =>
                _reviewCanConfirm(review.snapshot.proposal) &&
                (!review.isViewingCurrent ||
                    review.loadingDetails ||
                    review.errorCode != null ||
                    review.requestedVersion != null),
          )
      ? 0
      : reviews
            .where((review) => _reviewCanConfirm(review.snapshot.proposal))
            .length;

  int get selectedHunkCount => reviews.fold<int>(
    0,
    (count, review) => count + review.selectedHunkIds.length,
  );

  bool get canRejectSelected =>
      !isBusy &&
      selectedReview != null &&
      !selectedReview!.loadingDetails &&
      selectedReview!.requestedVersion == null &&
      selectedReview!.isViewingCurrent &&
      const {
        DocumentProposalState.ready,
        DocumentProposalState.stale,
        DocumentProposalState.applyFailed,
      }.contains(selectedReview!.snapshot.proposal.state);

  bool get canRegenerateSelected =>
      !isBusy &&
      selectedReview != null &&
      !selectedReview!.loadingDetails &&
      selectedReview!.requestedVersion == null &&
      selectedReview!.isViewingCurrent &&
      const {
        DocumentProposalState.generationFailed,
        DocumentProposalState.stale,
        DocumentProposalState.applyFailed,
      }.contains(selectedReview!.snapshot.proposal.state);

  bool get canRevise {
    final selected = reviews.where(
      (review) => review.selectedHunkIds.isNotEmpty,
    );
    if (selected.isNotEmpty) {
      return selected.every(
        (review) =>
            review.snapshot.proposal.state == DocumentProposalState.ready &&
            review.detailsUsable &&
            review.isViewingCurrent,
      );
    }
    final review = selectedReview;
    return review != null &&
        review.snapshot.proposal.state == DocumentProposalState.ready &&
        review.detailsUsable &&
        review.isViewingCurrent;
  }

  DigitalTwinControllerState copyWith({
    DigitalTwinControllerPhase? phase,
    Object? current = _unset,
    Object? schedule = _unset,
    List<DigitalTwinProposalReview>? reviews,
    List<DigitalTwinVersion>? versions,
    Object? selectedFileId = _unset,
    Object? selectedProposalId = _unset,
    Object? confirmation = _unset,
    Object? versionDetail = _unset,
    List<DigitalTwinLogicalFile>? previewFiles,
    Object? comparison = _unset,
    Object? archiveVersionId = _unset,
    Object? archiveSizeBytes = _unset,
    Object? errorCode = _unset,
  }) => DigitalTwinControllerState(
    phase: phase ?? this.phase,
    current: identical(current, _unset)
        ? this.current
        : current as DigitalTwinCurrent?,
    schedule: identical(schedule, _unset)
        ? this.schedule
        : schedule as DigitalTwinSchedule?,
    reviews: reviews ?? this.reviews,
    versions: versions ?? this.versions,
    selectedFileId: identical(selectedFileId, _unset)
        ? this.selectedFileId
        : selectedFileId as String?,
    selectedProposalId: identical(selectedProposalId, _unset)
        ? this.selectedProposalId
        : selectedProposalId as String?,
    confirmation: identical(confirmation, _unset)
        ? this.confirmation
        : confirmation as DigitalTwinConfirmation?,
    versionDetail: identical(versionDetail, _unset)
        ? this.versionDetail
        : versionDetail as DigitalTwinVersionDetail?,
    previewFiles: previewFiles ?? this.previewFiles,
    comparison: identical(comparison, _unset)
        ? this.comparison
        : comparison as DigitalTwinVersionComparison?,
    archiveVersionId: identical(archiveVersionId, _unset)
        ? this.archiveVersionId
        : archiveVersionId as String?,
    archiveSizeBytes: identical(archiveSizeBytes, _unset)
        ? this.archiveSizeBytes
        : archiveSizeBytes as int?,
    errorCode: identical(errorCode, _unset)
        ? this.errorCode
        : errorCode as String?,
  );
}

final class DigitalTwinController extends ChangeNotifier {
  DigitalTwinController(
    this._api, {
    this.pollInterval = const Duration(seconds: 1),
    this.maxPollAttempts = 600,
    TaskOrchestrator? taskOrchestrator,
    RuntimeActivityMetrics? activityMetrics,
    this.onConfirmationCreated,
    this.onConfirmationAccepted,
    this.onConfirmationSettled,
    this.onRevisionEvent,
    this.onProposalReplaced,
    DigitalTwinMaterialStore? recoveryStore,
    List<DigitalTwinRevisionEvent> initialRevisionEvents = const [],
  }) : _taskOrchestrator = taskOrchestrator,
       _activityMetrics = activityMetrics,
       _recoveryStore =
           recoveryStore ??
           DigitalTwinMaterialStore(
             database: AppDatabase(),
             scope: 'ephemeral-controller',
           ),
       _revisionEvents = List.of(initialRevisionEvents) {
    _acceptedConfirmationId = _recoveryStore.pendingConfirmationId;
    _state = _state.copyWith(confirmation: _recoveryStore.lastReport);
    if (_revisionEvents.isEmpty)
      _revisionEvents.addAll(_recoveryStore.revisionEvents);
  }

  final DigitalTwinApiPort _api;
  final Duration pollInterval;
  final int maxPollAttempts;
  final TaskOrchestrator? _taskOrchestrator;
  final RuntimeActivityMetrics? _activityMetrics;
  final DigitalTwinMaterialStore _recoveryStore;
  final Future<void> Function(String, List<String>)? onConfirmationAccepted;
  final Future<void> Function(String)? onConfirmationSettled;
  final Future<void> Function(DigitalTwinRevisionEvent)? onRevisionEvent;
  final Future<void> Function(String, String)? onProposalReplaced;
  final List<DigitalTwinRevisionEvent> _revisionEvents;
  List<DigitalTwinRevisionEvent> get revisionEvents =>
      List.unmodifiable(_revisionEvents);

  DigitalTwinProposalCommand? revisionCommandForEvent(
    DigitalTwinRevisionEvent event,
  ) => _recoveryStore.revisionArchive
      .where(
        (record) => '${record.command.idempotencyKey}:user' == event.eventId,
      )
      .firstOrNull
      ?.command;

  List<DigitalTwinRevisionRecord> revisionRecordsForVersion(
    DigitalTwinVersionDetail version,
  ) => _recoveryStore.revisionArchive
      .where((record) {
        final receipt = record.command.receipt?.proposal;
        return record.state == 'settled' &&
            receipt != null &&
            version.proposalResults.any(
              (outcome) =>
                  outcome.proposalId == receipt.proposalId &&
                  receipt.proposalVersion <= outcome.proposalVersion,
            );
      })
      .toList(growable: false);

  bool hasRevisionEvidence(DigitalTwinProposalReview review) =>
      _recoveryStore.revisionArchive.any((record) {
        final receipt = record.command.receipt?.proposal;
        return record.state == 'settled' &&
            receipt != null &&
            receipt.failureCode == null &&
            (record.command.operation != DigitalTwinProposalOperation.revise ||
                receipt.proposalVersion >
                    record.command.proposal.proposal.proposalVersion) &&
            review.detailsUsable &&
            review.isViewingCurrent &&
            review.snapshot.proposal.state == DocumentProposalState.ready &&
            receipt.proposalId == review.snapshot.proposal.proposalId &&
            receipt.proposalVersion == review.visibleVersion;
      });
  final Future<void> Function(
    DigitalTwinImportSource source,
    String confirmationId,
  )?
  onConfirmationCreated;
  DigitalTwinImportSource? _importSource;
  DigitalTwinDistillationTask? _distillationTask;
  OrchestratedPoller? _importPoller;
  List<String>? _importProposalIds;
  List<String>? _reviewScopeProposalIds;
  bool _importWaiting = false;
  String? _acceptedConfirmationId;

  DigitalTwinImportSource? get importSource => _importSource;
  DigitalTwinDistillationTask? get distillationTask => _distillationTask;
  bool get importWaiting => _importWaiting;
  bool get hasIndependentReview => _reviewScopeProposalIds != null;
  bool get hasPendingConfirmation =>
      _acceptedConfirmationId != null ||
      _recoveryStore.pendingConfirmationId != null ||
      _recoveryStore.pendingConfirmationCommand != null;
  bool get hasPendingEdits => _recoveryStore.pendingProposalCommands.isNotEmpty;
  bool get hasPendingRestore => _recoveryStore.pendingRestoreCommand != null;
  bool get hasUnresolvedMutation =>
      hasPendingConfirmation || hasPendingEdits || hasPendingRestore;
  DigitalTwinRestore? get lastRestore => _recoveryStore.lastRestore;
  bool get canRestoreVersion => !_state.isBusy && !hasUnresolvedMutation;

  Future<bool> openOverview() async {
    if (_state.isBusy) return false;
    if (hasUnresolvedMutation && (!await load() || hasUnresolvedMutation))
      return false;
    return load(importSource: null, reviewProposalIds: null);
  }

  final Map<String, _DigitalTwinProposalPoll> _proposalPolls =
      <String, _DigitalTwinProposalPoll>{};
  _DigitalTwinConfirmationPoll? _confirmationPoll;
  DigitalTwinControllerState _state = const DigitalTwinControllerState();
  int _generation = 0;
  bool _disposed = false;
  bool _pollingRouteActive = true;
  static final Object _defaultPollingOwner = Object();
  final Set<Object> _pollingOwners = {_defaultPollingOwner};

  DigitalTwinControllerState get state => _state;

  void setPollingRouteActive(bool active, {Object? owner}) {
    if (_disposed) return;
    final identity = owner ?? _defaultPollingOwner;
    if (active) {
      _pollingOwners.add(identity);
    } else {
      _pollingOwners.remove(identity);
    }
    final effectiveActive = _pollingOwners.isNotEmpty;
    if (_pollingRouteActive == effectiveActive) return;
    _pollingRouteActive = effectiveActive;
    if (effectiveActive && _importWaiting) {
      _importPoller?.start();
    } else if (!effectiveActive) {
      _importPoller?.stop();
    }
    for (final run in _proposalPolls.values) {
      if (effectiveActive) {
        if (!run.completer.isCompleted) run.poller?.start();
      } else {
        run.poller?.stop();
      }
    }
    final confirmation = _confirmationPoll;
    if (confirmation != null && !confirmation.completer.isCompleted) {
      if (effectiveActive) {
        confirmation.poller?.start();
      } else {
        confirmation.poller?.stop();
      }
    }
  }

  Future<bool> load({
    String? preferredProposalId,
    Object? importSource = _unset,
    Object? reviewProposalIds = _unset,
    String? confirmationTaskId,
  }) async {
    _acceptedConfirmationId =
        _recoveryStore.pendingConfirmationId ?? _acceptedConfirmationId;
    var pendingCommand = _recoveryStore.pendingConfirmationCommand;
    if (_recoveryStore.pendingConfirmationId == null &&
        pendingCommand != null &&
        pendingCommand.proposals.any(
          (snapshot) => isPositioningProposal(snapshot.proposal),
        )) {
      await _recoveryStore.rejectConfirmationCommand(
        pendingCommand,
        'POSITIONING_OWNER_INDEPENDENT',
      );
      pendingCommand = null;
    }
    final pendingRestore = _recoveryStore.pendingRestoreCommand;
    if (pendingRestore != null &&
        reviewProposalIds is List<String> &&
        !setEquals(
          reviewProposalIds.toSet(),
          pendingRestore.receipt?.proposalIds.toSet() ?? <String>{},
        )) {
      _emit(_state.copyWith(errorCode: 'DIGITAL_TWIN_RESTORE_IN_PROGRESS'));
      return false;
    }
    if (pendingCommand != null &&
        reviewProposalIds is List<String> &&
        !setEquals(
          reviewProposalIds.toSet(),
          pendingCommand.proposalIds.toSet(),
        )) {
      _emit(
        _state.copyWith(errorCode: 'DIGITAL_TWIN_CONFIRMATION_IN_PROGRESS'),
      );
      return false;
    }
    if ((!identical(importSource, _unset) ||
            !identical(reviewProposalIds, _unset)) &&
        _acceptedConfirmationId != null &&
        confirmationTaskId != _acceptedConfirmationId &&
        (importSource is! DigitalTwinImportSource ||
            importSource.confirmationTaskId != _acceptedConfirmationId)) {
      _emit(
        _state.copyWith(errorCode: 'DIGITAL_TWIN_CONFIRMATION_IN_PROGRESS'),
      );
      return false;
    }
    if (!identical(importSource, _unset)) {
      _importSource = importSource as DigitalTwinImportSource?;
      _reviewScopeProposalIds = null;
      _distillationTask = null;
      _acceptedConfirmationId = _importSource?.confirmationTaskId;
      _importWaiting = false;
      _state = _state.copyWith(confirmation: null);
    }
    if (!identical(reviewProposalIds, _unset)) {
      _reviewScopeProposalIds = reviewProposalIds == null
          ? null
          : List<String>.unmodifiable(reviewProposalIds as List<String>);
    }
    if (confirmationTaskId != null)
      _acceptedConfirmationId = confirmationTaskId;
    if (pendingCommand != null) {
      _importSource = pendingCommand.source;
      _reviewScopeProposalIds = pendingCommand.proposalIds;
      _acceptedConfirmationId = _recoveryStore.pendingConfirmationId;
    }
    final generation = _beginGeneration();
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.loading,
        errorCode: null,
      ),
    );
    try {
      final confirmationId = _acceptedConfirmationId;
      final recoveredConfirmation =
          confirmationId == null && pendingCommand == null
          ? null
          : await _recoverConfirmation(pendingCommand);
      _ensureActive(generation);
      if (recoveredConfirmation != null) {
        _emit(_state.copyWith(confirmation: recoveredConfirmation));
        if (recoveredConfirmation.isTerminal &&
            recoveredConfirmation.appliedCount > 0 &&
            recoveredConfirmation.version == null) {
          throw const DigitalTwinApiException(
            'DIGITAL_TWIN_PROJECTION_PENDING',
          );
        }
      }
      await _recoverProposalCommands(generation);
      final restored = await _recoverRestore(generation);
      final values = await Future.wait<Object>(<Future<Object>>[
        _api.getCurrent(),
        _api.getSchedule(),
        _api.getVersions(),
      ]);
      _ensureActive(generation);
      var current = values[0] as DigitalTwinCurrent;
      final schedule = values[1] as DigitalTwinSchedule;
      var versions = values[2] as List<DigitalTwinVersion>;
      final confirmedVersion = recoveredConfirmation?.version;
      for (
        var attempt = 0;
        confirmedVersion != null &&
            (current.currentVersion?.versionNumber ?? -1) <
                confirmedVersion.versionNumber &&
            attempt < 2;
        attempt += 1
      ) {
        await Future<void>.delayed(pollInterval);
        _ensureActive(generation);
        current = await _api.getCurrent();
        versions = await _api.getVersions();
        _ensureActive(generation);
      }
      if (confirmedVersion != null &&
          ((current.currentVersion?.versionNumber ?? -1) <
                  confirmedVersion.versionNumber ||
              !versions.any(
                (version) => version.versionId == confirmedVersion.versionId,
              ))) {
        _emit(
          _state.copyWith(
            current: current,
            schedule: schedule,
            versions: versions,
          ),
        );
        throw const DigitalTwinApiException('DIGITAL_TWIN_PROJECTION_PENDING');
      }
      final source = _importSource;
      final snapshots = _reviewScopeProposalIds != null
          ? await _readIndependentReview(generation)
          : source == null
          ? await _readIndependentReview(generation, current: current)
          : await _readImport(source, generation);
      _ensureActive(generation);
      if (source != null) {
        current = await _api.getCurrent();
        _ensureActive(generation);
      }
      final reviews = <DigitalTwinProposalReview>[
        for (final snapshot in snapshots)
          if (_review(snapshot.proposal.proposalId) case final previous?
              when previous.snapshot.etag == snapshot.etag &&
                  previous.snapshot.proposal.proposalVersion ==
                      snapshot.proposal.proposalVersion)
            previous.copyWith(snapshot: snapshot, loadingDetails: false)
          else
            DigitalTwinProposalReview(snapshot: snapshot),
      ];
      current = _withReviewAssociations(current, reviews);
      final selectedFileId = _selectedReviewFileId(current, reviews);
      final selectedProposalId = _selectedProposalId(
        current,
        reviews,
        selectedFileId,
        preferredProposalId ?? _state.selectedProposalId,
      );
      _emit(
        _state.copyWith(
          phase: DigitalTwinControllerPhase.ready,
          current: current,
          schedule: schedule,
          reviews: reviews,
          versions: versions,
          selectedFileId: selectedFileId,
          selectedProposalId: selectedProposalId,
          errorCode: null,
        ),
      );
      if (selectedProposalId != null) {
        await _hydrateProposal(selectedProposalId, generation);
      }
      if (recoveredConfirmation?.isTerminal == true) {
        await _recoveryStore.settleConfirmation(
          recoveredConfirmation!.confirmationTaskId,
        );
        await onConfirmationSettled?.call(
          recoveredConfirmation.confirmationTaskId,
        );
        _acceptedConfirmationId = null;
      }
      if (restored != null) {
        await _recoveryStore.settleRestore(restored);
        _ensureActive(generation);
        final receipt = restored.receipt!;
        if (receipt.state == 'failed' || receipt.proposalIds.isEmpty) {
          _emit(
            _state.copyWith(
              errorCode: receipt.state == 'failed'
                  ? receipt.proposalIds.isEmpty
                        ? 'DIGITAL_TWIN_RESTORE_FAILED'
                        : 'DIGITAL_TWIN_RESTORE_PARTIAL'
                  : 'DIGITAL_TWIN_RESTORE_NO_CANDIDATES',
            ),
          );
        }
      }
      _startImportObservation(generation);
      if (recoveredConfirmation != null &&
          !recoveredConfirmation.isTerminal &&
          _taskOrchestrator != null &&
          _activityMetrics != null &&
          pollInterval > Duration.zero) {
        unawaited(_resumeConfirmation(recoveredConfirmation, generation));
      }
      return true;
    } on _DigitalTwinSuperseded {
      return false;
    } catch (error) {
      if (_isActive(generation)) {
        _importWaiting = false;
        _emit(
          _state.copyWith(
            phase: DigitalTwinControllerPhase.failed,
            errorCode: _errorCode(error),
          ),
        );
      }
      return false;
    }
  }

  Future<List<DocumentChangeProposalSnapshot>> _readIndependentReview(
    int generation, {
    DigitalTwinCurrent? current,
  }) async {
    final ids = <String>{
      ..._reviewScopeProposalIds ??
          <String>{
            ...(current ?? _state.current)?.activeProposalIds ??
                const <String>[],
            for (final file
                in (current ?? _state.current)?.files ??
                    const <DigitalTwinLogicalFile>[])
              ...file.pendingProposalIds,
          }.toList(),
      for (final command in _recoveryStore.pendingProposalCommands)
        command.currentProposalId,
    };
    final snapshots = (await Future.wait(
      ids.map(_api.getProposal),
    )).where((snapshot) => !isPositioningProposal(snapshot.proposal)).toList();
    _ensureActive(generation);
    _importWaiting = snapshots.any(
      (snapshot) =>
          snapshot.proposal.state == DocumentProposalState.generating ||
          snapshot.proposal.state == DocumentProposalState.applying,
    );
    return snapshots
        .where(
          (snapshot) =>
              snapshot.proposal.state != DocumentProposalState.applied &&
              snapshot.proposal.state != DocumentProposalState.rejected,
        )
        .toList(growable: false);
  }

  Future<List<DocumentChangeProposalSnapshot>> _readImport(
    DigitalTwinImportSource source,
    int generation, {
    AppTaskCancellationToken? token,
  }) async {
    final task = await _api.getDistillationTask(source.taskId);
    _ensureActive(generation);
    token?.throwIfCancelled();
    if (task.status != 'succeeded' && !task.isFailed) {
      _distillationTask = task;
      _importWaiting = true;
      return const <DocumentChangeProposalSnapshot>[];
    }
    final knownIds = _importProposalIds;
    final received = knownIds == null
        ? await _api.getImportProposals(source.noteId)
        : await Future.wait(knownIds.map(_api.getProposal));
    final proposals = received
        .where((snapshot) => !isPositioningProposal(snapshot.proposal))
        .toList();
    _ensureActive(generation);
    token?.throwIfCancelled();
    if (task.status == 'succeeded' && proposals.isNotEmpty) {
      _importProposalIds = proposals
          .map((snapshot) => snapshot.proposal.proposalId)
          .toList(growable: false);
    }
    _distillationTask = task;
    _importWaiting =
        proposals.any(
          (snapshot) =>
              snapshot.proposal.state == DocumentProposalState.generating ||
              snapshot.proposal.state == DocumentProposalState.applying,
        ) ||
        (!task.isFailed && (task.status != 'succeeded' || proposals.isEmpty));
    return proposals
        .where(
          (snapshot) =>
              snapshot.proposal.state != DocumentProposalState.applied &&
              snapshot.proposal.state != DocumentProposalState.rejected,
        )
        .toList(growable: false);
  }

  void _startImportObservation(int generation) {
    _importPoller?.dispose();
    _importPoller = null;
    final source = _importSource;
    if (!_importWaiting ||
        _taskOrchestrator == null ||
        _activityMetrics == null ||
        pollInterval == Duration.zero) {
      return;
    }
    var attempts = 0;
    final stableId = _stableProposalPollId(
      source?.taskId ?? _reviewScopeProposalIds?.join(':') ?? 'workspace',
    );
    _importPoller = OrchestratedPoller(
      orchestrator: _taskOrchestrator,
      spec: TaskSpec(
        key: 'digital-twin:material:$stableId',
        owner: 'digital-twin-material',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        deadline: const Duration(seconds: 30),
        retryable: true,
        replaceExisting: true,
      ),
      interval: const Duration(seconds: 3),
      maxBackoff: const Duration(seconds: 30),
      activityMetrics: _activityMetrics,
      metricsOwner: 'digital-twin.material.$stableId',
      poll: (token) async {
        token.throwIfCancelled();
        if (!_isActive(generation)) return false;
        attempts += 1;
        if (attempts > 200) {
          _importWaiting = false;
          _emit(_state.copyWith(errorCode: 'DIGITAL_TWIN_OBSERVATION_PAUSED'));
          return false;
        }
        await _recoverProposalCommands(generation);
        var current = await _api.getCurrent();
        token.throwIfCancelled();
        final snapshots = source == null
            ? await _readIndependentReview(generation, current: current)
            : await _readImport(source, generation, token: token);
        token.throwIfCancelled();
        _ensureActive(generation);
        final reviews = <DigitalTwinProposalReview>[
          for (final snapshot in snapshots)
            if (_review(snapshot.proposal.proposalId) case final existing?
                when existing.snapshot.proposal.rowVersion ==
                    snapshot.proposal.rowVersion)
              existing
            else
              DigitalTwinProposalReview(snapshot: snapshot),
        ];
        current = _withReviewAssociations(current, reviews);
        _emit(
          _state.copyWith(
            current: current,
            reviews: reviews,
            selectedFileId: _selectedReviewFileId(current, reviews),
            selectedProposalId: _selectedProposalId(
              current,
              reviews,
              _selectedReviewFileId(current, reviews),
              _state.selectedProposalId,
            ),
            errorCode: null,
          ),
        );
        final selected = _state.selectedProposalId;
        if (selected != null) await _hydrateProposal(selected, generation);
        return _importWaiting;
      },
    );
    if (_pollingRouteActive) _importPoller!.start();
  }

  Future<bool> rejectSelectedProposal({
    DocumentChangeProposalSnapshot? selection,
  }) async {
    if (!_state.canRejectSelected || hasUnresolvedMutation) return false;
    final snapshot = _state.selectedReview!.snapshot;
    if (selection != null &&
        (selection.proposal.proposalId != snapshot.proposal.proposalId ||
            selection.etag != snapshot.etag))
      return false;
    final generation = _beginGeneration();
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.revising,
        errorCode: null,
      ),
    );
    try {
      await _api.rejectProposal(
        proposal: snapshot,
        idempotencyKey:
            'digital-twin-reject-${snapshot.proposal.proposalId}-${snapshot.proposal.rowVersion}',
      );
      _ensureActive(generation);
      return load();
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
      return false;
    } finally {
      if (_isActive(generation) && _importWaiting) {
        _startImportObservation(generation);
      }
    }
  }

  Future<bool> regenerateSelected(
    String instruction, {
    DocumentChangeProposalSnapshot? selection,
  }) async {
    if (!_state.canRegenerateSelected || hasUnresolvedMutation) return false;
    final previous = _state.selectedReview!.snapshot;
    if (selection != null &&
        (selection.proposal.proposalId != previous.proposal.proposalId ||
            selection.etag != previous.etag))
      return false;
    final generation = _beginGeneration();
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.revising,
        errorCode: null,
      ),
    );
    try {
      final command = DigitalTwinProposalCommand(
        operation: DigitalTwinProposalOperation.regenerate,
        proposal: previous,
        instruction: instruction.trim(),
        idempotencyKey:
            'digital-twin-regenerate-${previous.proposal.proposalId}-${previous.proposal.rowVersion}-${sha256.convert(utf8.encode(instruction.trim()))}',
      );
      await _recoveryStore.prepareProposalCommands([command]);
      _syncRevisionEvents();
      _ensureActive(generation);
      final replacement = await _dispatchProposalCommand(command);
      _ensureActive(generation);
      if (_reviewScopeProposalIds != null) {
        _reviewScopeProposalIds = [
          ..._reviewScopeProposalIds!.where(
            (id) => id != previous.proposal.proposalId,
          ),
          replacement.proposal.proposalId,
        ];
      }
      final reviews = [
        ..._state.reviews.where(
          (review) =>
              review.snapshot.proposal.proposalId !=
              replacement.proposal.proposalId,
        ),
        DigitalTwinProposalReview(snapshot: replacement),
      ];
      _emit(
        _state.copyWith(
          reviews: reviews,
          selectedProposalId: replacement.proposal.proposalId,
        ),
      );
      _emit(
        _state.copyWith(
          reviews: _state.reviews
              .where(
                (review) =>
                    review.snapshot.proposal.proposalId !=
                    previous.proposal.proposalId,
              )
              .toList(),
        ),
      );
      final settled = await _pollProposal(replacement, generation);
      await _finishProposalCommand(command, settled);
      _ensureActive(generation);
      _replaceReview(DigitalTwinProposalReview(snapshot: settled));
      _importWaiting =
          settled.proposal.state == DocumentProposalState.generating;
      if (_importSource == null && _reviewScopeProposalIds == null) {
        _reviewScopeProposalIds = [settled.proposal.proposalId];
      }
      _emit(_state.copyWith(phase: DigitalTwinControllerPhase.ready));
      await _hydrateProposal(settled.proposal.proposalId, generation);
      _startImportObservation(generation);
      return true;
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
      return false;
    } finally {
      if (_isActive(generation) && _importWaiting) {
        _startImportObservation(generation);
      }
    }
  }

  Future<bool> rejectUnchanged() async {
    if (_state.isBusy || hasUnresolvedMutation) return false;
    final unchanged = _state.reviews
        .where(
          (review) =>
              review.snapshot.proposal.state == DocumentProposalState.ready &&
              review.snapshot.proposal.hasChanges == false,
        )
        .toList(growable: false);
    if (unchanged.isEmpty) return false;
    final generation = _beginGeneration();
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.confirming,
        errorCode: null,
      ),
    );
    try {
      for (final review in unchanged) {
        await _api.rejectProposal(
          proposal: review.snapshot,
          idempotencyKey:
              'digital-twin-reject-${review.snapshot.proposal.proposalId}-${review.snapshot.proposal.rowVersion}',
        );
        _ensureActive(generation);
      }
      return load();
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
      return false;
    } finally {
      if (_isActive(generation) && _importWaiting) {
        _startImportObservation(generation);
      }
    }
  }

  Future<void> selectFile(String fileId) async {
    if (!_isTwinFileId(fileId)) return;
    final current = _state.current;
    if (current == null || !current.files.any((file) => file.id == fileId)) {
      return;
    }
    final file = current.files.firstWhere((file) => file.id == fileId);
    final proposalId = file.pendingProposalIds.isEmpty
        ? null
        : file.pendingProposalIds.first;
    _emit(
      _state.copyWith(selectedFileId: fileId, selectedProposalId: proposalId),
    );
    if (proposalId != null) await selectProposal(proposalId);
  }

  Future<void> selectProposal(String proposalId) async {
    if (!_state.reviews.any(
      (review) => review.snapshot.proposal.proposalId == proposalId,
    )) {
      return;
    }
    _emit(_state.copyWith(selectedProposalId: proposalId));
    await _hydrateSelection(proposalId);
  }

  Future<void> prepareReviewDetails() async {
    final generation = _generation;
    final ids = _state.reviews
        .where((review) => !review.detailsLoaded && !review.loadingDetails)
        .map((review) => review.snapshot.proposal.proposalId)
        .toList(growable: false);
    for (final id in ids) {
      if (!_isActive(generation)) return;
      try {
        await _hydrateProposal(id, generation);
      } on _DigitalTwinSuperseded {
        return;
      }
    }
  }

  Future<void> retryProposalDetails(String proposalId) async {
    final review = _review(proposalId);
    if (review == null) return;
    await _hydrateSelection(
      proposalId,
      proposalVersion: review.requestedVersion ?? review.visibleVersion,
    );
  }

  void toggleHunk(String hunkId) {
    final proposalId = _state.selectedProposalId;
    if (proposalId == null) return;
    final review = _review(proposalId);
    if (review == null ||
        !review.detailsUsable ||
        !review.isViewingCurrent ||
        !review.diff.any((hunk) => hunk.hunkId == hunkId)) {
      return;
    }
    final selected = <String>{...review.selectedHunkIds};
    selected.contains(hunkId) ? selected.remove(hunkId) : selected.add(hunkId);
    _replaceReview(
      review.copyWith(selectedHunkIds: Set<String>.unmodifiable(selected)),
    );
  }

  Future<void> inspectProposalVersion(
    String proposalId,
    int proposalVersion,
  ) async {
    final review = _review(proposalId);
    if (review == null ||
        !review.versions.any(
          (version) => version.proposalVersion == proposalVersion,
        )) {
      return;
    }
    await _hydrateSelection(proposalId, proposalVersion: proposalVersion);
  }

  Future<void> _hydrateSelection(
    String proposalId, {
    int? proposalVersion,
  }) async {
    try {
      await _hydrateProposal(
        proposalId,
        _generation,
        proposalVersion: proposalVersion,
      );
    } on _DigitalTwinSuperseded {
      return;
    }
  }

  Future<bool> reviseSelected(String instruction) async {
    if (instruction.trim().isEmpty) return false;
    if (_state.isBusy || !_state.canRevise || hasUnresolvedMutation)
      return false;
    final proposalId = _state.selectedProposalId;
    var selectedReview = proposalId == null ? null : _review(proposalId);
    if (selectedReview == null) return false;
    if (!selectedReview.detailsLoaded) {
      await _hydrateProposal(proposalId!, _generation);
      selectedReview = _review(proposalId);
    }
    final selected = _state.reviews
        .where((review) => review.selectedHunkIds.isNotEmpty)
        .toList(growable: false);
    final targets = selected.isEmpty
        ? <DigitalTwinProposalReview>[selectedReview!]
        : selected;
    if (targets.any(
      (review) =>
          review.snapshot.proposal.state != DocumentProposalState.ready ||
          (review.selectedHunkIds.isNotEmpty &&
              review.currentDiffBundleId == null),
    )) {
      _fail('DIGITAL_TWIN_PROPOSAL_DIFF_UNAVAILABLE');
      return false;
    }
    final generation = _beginGeneration();
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.revising,
        errorCode: null,
      ),
    );
    try {
      final commands = targets
          .map((review) => _revisionCommand(review, instruction))
          .toList();
      await _recoveryStore.prepareProposalCommands(commands);
      _syncRevisionEvents();
      _ensureActive(generation);
      final failures = await Future.wait<String?>(
        commands.map((command) => _reviseReview(command, generation)),
      );
      _ensureActive(generation);
      final loaded = await load(preferredProposalId: proposalId);
      if (!loaded) return false;
      final failure = failures.whereType<String>().firstOrNull;
      if (failure != null) _fail(failure);
      return failure == null;
    } on _DigitalTwinSuperseded {
      return false;
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
      return false;
    } finally {
      if (_isActive(generation) && _importWaiting) {
        _startImportObservation(generation);
      }
    }
  }

  Future<String?> _reviseReview(
    DigitalTwinProposalCommand command,
    int generation,
  ) async {
    try {
      final proposalId = command.proposal.proposal.proposalId;
      var snapshot = await _dispatchProposalCommand(command);
      _ensureActive(generation);
      final current = _review(proposalId);
      if (current != null) {
        _replaceReview(
          snapshot.proposal.proposalVersion ==
                  current.snapshot.proposal.proposalVersion
              ? current.copyWith(snapshot: snapshot)
              : DigitalTwinProposalReview(snapshot: snapshot),
        );
      }
      snapshot = await _pollProposal(snapshot, generation);
      await _finishProposalCommand(command, snapshot);
      if (snapshot.proposal.state != DocumentProposalState.ready ||
          snapshot.proposal.failureCode != null) {
        return snapshot.proposal.failureCode ?? 'DIGITAL_TWIN_REVISION_FAILED';
      }
      return null;
    } on _DigitalTwinSuperseded {
      rethrow;
    } catch (error) {
      return _errorCode(error);
    }
  }

  DigitalTwinConfirmationSelection? captureConfirmationSelection() {
    if (_state.isBusy || hasPendingEdits || hasPendingRestore) return null;
    if (hasPendingConfirmation) {
      return DigitalTwinConfirmationSelection._(
        identity:
            'confirmation:${_recoveryStore.pendingConfirmationId ?? _acceptedConfirmationId ?? _recoveryStore.pendingConfirmationCommand!.idempotencyKey}',
        proposals: const [],
      );
    }
    if (_state.readyProposalCount == 0) return null;
    final reviews = _state.reviews
        .where((review) => _reviewCanConfirm(review.snapshot.proposal))
        .toList(growable: false);
    if (reviews.isEmpty || reviews.any((review) => !review.isViewingCurrent)) {
      return null;
    }
    final snapshots = reviews.map((review) => review.snapshot).toList()
      ..sort(
        (left, right) =>
            left.proposal.proposalId.compareTo(right.proposal.proposalId),
      );
    return DigitalTwinConfirmationSelection._(
      identity: _confirmationKey(snapshots, _importSource),
      proposals: snapshots
          .take(digitalTwinConfirmationBatchLimit)
          .toList(growable: false),
    );
  }

  Future<bool> confirmReady({
    DigitalTwinConfirmationSelection? selection,
  }) async {
    if (_state.isBusy) return false;
    final currentSelection = captureConfirmationSelection();
    final frozen = selection ?? currentSelection;
    if (frozen == null || frozen.identity != currentSelection?.identity) {
      _emit(
        _state.copyWith(
          errorCode: 'DIGITAL_TWIN_CONFIRMATION_SELECTION_CHANGED',
        ),
      );
      return false;
    }
    final ready = frozen.proposals;
    final generation = _beginGeneration();
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.confirming,
        errorCode: null,
      ),
    );
    try {
      final source = _importSource;
      if (!hasPendingConfirmation) {
        final latest = await Future.wait(
          ready.map(
            (snapshot) => _api.getProposal(snapshot.proposal.proposalId),
          ),
        );
        _ensureActive(generation);
        if (_confirmationKey(latest, source) !=
                _confirmationKey(ready, source) ||
            latest.any((snapshot) => !_reviewCanConfirm(snapshot.proposal))) {
          await load();
          _emit(
            _state.copyWith(
              errorCode: 'DIGITAL_TWIN_CONFIRMATION_SELECTION_CHANGED',
            ),
          );
          return false;
        }
      }
      var command = _recoveryStore.pendingConfirmationCommand;
      if (!hasPendingConfirmation) {
        command = DigitalTwinConfirmationCommand(
          proposals: ready,
          idempotencyKey: _confirmationKey(ready, source),
          source: source,
        );
        await _recoveryStore.prepareConfirmation(command);
        _ensureActive(generation);
      }
      var confirmation = await _recoverConfirmation(command);
      _ensureActive(generation);
      _acceptedConfirmationId = confirmation.confirmationTaskId;
      _emit(_state.copyWith(confirmation: confirmation));
      _ensureActive(generation);
      if (_taskOrchestrator != null &&
          _activityMetrics != null &&
          pollInterval > Duration.zero &&
          !confirmation.isTerminal) {
        confirmation = await _pollConfirmationWithRuntime(
          confirmation,
          generation,
        );
      } else {
        for (
          var attempt = 0;
          !confirmation.isTerminal && attempt < maxPollAttempts;
          attempt += 1
        ) {
          await Future<void>.delayed(pollInterval);
          _ensureActive(generation);
          confirmation = await _api.getConfirmation(
            confirmation.confirmationTaskId,
          );
          await _recoveryStore.recordConfirmationReport(
            confirmation,
            updateCurrent:
                _isActive(generation) &&
                _recoveryStore.pendingConfirmationId ==
                    confirmation.confirmationTaskId,
          );
          _ensureActive(generation);
          _emit(_state.copyWith(confirmation: confirmation));
        }
      }
      if (!confirmation.isTerminal) {
        throw const DigitalTwinApiException(
          'DIGITAL_TWIN_CONFIRMATION_TIMEOUT',
        );
      }
      final loaded = await load();
      if (loaded) _emit(_state.copyWith(confirmation: confirmation));
      if (loaded && confirmation.isTerminal) _acceptedConfirmationId = null;
      return loaded &&
          confirmation.state == 'report_ready' &&
          confirmation.appliedCount > 0 &&
          confirmation.version != null;
    } on _DigitalTwinSuperseded {
      return false;
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
      return false;
    } finally {
      if (_isActive(generation) && _importWaiting) {
        _startImportObservation(generation);
      }
    }
  }

  Future<bool> saveSchedule(DigitalTwinScheduleDraft draft) async {
    if (_state.isBusy) return false;
    final generation = _generation;
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.savingSchedule,
        errorCode: null,
      ),
    );
    try {
      final schedule = await _api.updateSchedule(
        draft,
        idempotencyKey: _key('schedule', '${draft.intervalDays}'),
      );
      _ensureActive(generation);
      _emit(
        _state.copyWith(
          phase: DigitalTwinControllerPhase.ready,
          schedule: schedule,
        ),
      );
      return true;
    } on _DigitalTwinSuperseded {
      return false;
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
      return false;
    }
  }

  Future<bool> inspectVersion(String versionId) async {
    if (_state.isBusy) return false;
    final generation = _generation;
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.loadingVersion,
        errorCode: null,
      ),
    );
    try {
      final values = await Future.wait<Object>(<Future<Object>>[
        _api.getVersion(versionId),
        _api.getPreview(versionId),
      ]);
      _ensureActive(generation);
      _emit(
        _state.copyWith(
          phase: DigitalTwinControllerPhase.ready,
          versionDetail: values[0] as DigitalTwinVersionDetail,
          previewFiles: values[1] as List<DigitalTwinLogicalFile>,
          comparison: null,
        ),
      );
      return true;
    } on _DigitalTwinSuperseded {
      return false;
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
      return false;
    }
  }

  Future<bool> compareVersion(String versionId) async {
    final target = _version(versionId);
    if (target == null) return false;
    DigitalTwinVersion? base;
    for (final version in _state.versions) {
      if (version.versionNumber < target.versionNumber &&
          (base == null || version.versionNumber > base.versionNumber)) {
        base = version;
      }
    }
    if (base == null) return false;
    if (_state.isBusy) return false;
    final generation = _generation;
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.loadingVersion,
        errorCode: null,
      ),
    );
    try {
      final comparison = await _api.compareVersions(
        baseVersionId: base.versionId,
        versionId: versionId,
      );
      _ensureActive(generation);
      _emit(
        _state.copyWith(
          phase: DigitalTwinControllerPhase.ready,
          comparison: comparison,
        ),
      );
      return true;
    } on _DigitalTwinSuperseded {
      return false;
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
      return false;
    }
  }

  Future<bool> pullVersion(
    String versionId, {
    DigitalTwinArchiveExporter? export,
  }) async {
    try {
      final bytes = await _api.downloadVersion(versionId);
      if (export != null && !await export(bytes)) {
        _fail('DIGITAL_TWIN_EXPORT_FAILED');
        return false;
      }
      _emit(
        _state.copyWith(
          archiveVersionId: versionId,
          archiveSizeBytes: bytes.length,
          errorCode: null,
        ),
      );
      return true;
    } catch (error) {
      _fail(_errorCode(error));
      return false;
    }
  }

  Future<bool> restoreVersion(String versionId) async {
    if (_state.isBusy || hasPendingConfirmation || hasPendingEdits) {
      _emit(_state.copyWith(errorCode: 'DIGITAL_TWIN_OPERATION_IN_PROGRESS'));
      return false;
    }
    final pending = _recoveryStore.pendingRestoreCommand;
    if (pending != null && pending.versionId != versionId) {
      _emit(_state.copyWith(errorCode: 'DIGITAL_TWIN_RESTORE_IN_PROGRESS'));
      return false;
    }
    final basis = jsonEncode({
      'versionId': versionId,
      'operationId': _key('restore', versionId),
      'currentVersionId': _state.current?.currentVersion?.versionId,
      'files': [
        for (final file
            in _state.current?.files ?? const <DigitalTwinLogicalFile>[])
          {'id': file.id, 'markdown': file.markdown},
      ],
    });
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.restoring,
        errorCode: null,
      ),
    );
    try {
      await _recoveryStore.prepareRestore(
        pending ??
            DigitalTwinRestoreCommand(
              versionId: versionId,
              idempotencyKey:
                  'digital-twin-restore-${sha256.convert(utf8.encode(basis))}',
            ),
      );
      if (_disposed) return false;
      final loaded = await load();
      return loaded &&
          lastRestore?.versionId == versionId &&
          lastRestore?.state == 'proposals_created' &&
          lastRestore!.proposalIds.isNotEmpty &&
          _state.errorCode == null;
    } catch (error) {
      if (!_disposed) _fail(_errorCode(error));
      return false;
    }
  }

  Future<DigitalTwinRestoreCommand?> _recoverRestore(int generation) async {
    var command = _recoveryStore.pendingRestoreCommand;
    if (command == null) return null;
    if (command.receipt == null ||
        !const {
          'proposals_created',
          'failed',
        }.contains(command.receipt!.state)) {
      final receipt = await _api.restoreVersion(
        command.versionId,
        idempotencyKey: command.idempotencyKey,
      );
      await _recoveryStore.recordRestoreReceipt(command, receipt);
      command = command.withReceipt(receipt);
    }
    _ensureActive(generation);
    final receipt = command.receipt!;
    if (!const {'proposals_created', 'failed'}.contains(receipt.state)) {
      throw const DigitalTwinApiException('DIGITAL_TWIN_RESTORE_PENDING');
    }
    _importSource = null;
    _reviewScopeProposalIds = List.unmodifiable(receipt.proposalIds);
    return command;
  }

  void clearVersionInspection() {
    _emit(
      _state.copyWith(
        versionDetail: null,
        previewFiles: const <DigitalTwinLogicalFile>[],
        comparison: null,
      ),
    );
  }

  Future<void> _hydrateProposal(
    String proposalId,
    int generation, {
    int? proposalVersion,
  }) async {
    var review = _review(proposalId);
    if (review == null || review.loadingDetails) return;
    final requestedVersion =
        proposalVersion ?? review.requestedVersion ?? review.visibleVersion;
    if (review.detailsUsable && review.visibleVersion == requestedVersion)
      return;
    if (review.snapshot.proposal.state == DocumentProposalState.generating &&
        requestedVersion == review.snapshot.proposal.proposalVersion) {
      return;
    }
    _replaceReview(
      review.copyWith(
        loadingDetails: true,
        requestedVersion: requestedVersion,
        errorCode: null,
      ),
    );
    try {
      final versions = review.versions.isEmpty
          ? await _api.getProposalVersions(proposalId)
          : review.versions;
      _ensureActive(generation);
      final diff = await _readAllDiff(proposalId, requestedVersion, generation);
      final candidate = await _readAllCandidate(
        proposalId,
        requestedVersion,
        generation,
      );
      review = _review(proposalId);
      if (review == null) return;
      _replaceReview(
        review.copyWith(
          versions: versions,
          diff: diff,
          candidateMarkdown: candidate,
          inspectedVersion: requestedVersion,
          requestedVersion: null,
          selectedHunkIds: review.selectedHunkIds,
          loadingDetails: false,
          errorCode: null,
        ),
      );
    } on _DigitalTwinSuperseded {
      rethrow;
    } catch (error) {
      review = _review(proposalId);
      if (review != null) {
        _replaceReview(
          review.copyWith(loadingDetails: false, errorCode: _errorCode(error)),
        );
      }
    }
  }

  Future<List<DocumentProposalDiffHunk>> _readAllDiff(
    String proposalId,
    int proposalVersion,
    int generation,
  ) async {
    final hunks = <DocumentProposalDiffHunk>[];
    String? cursor;
    do {
      final page = await _api.getProposalDiff(
        proposalId: proposalId,
        proposalVersion: proposalVersion,
        cursor: cursor,
      );
      _ensureActive(generation);
      hunks.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    return List<DocumentProposalDiffHunk>.unmodifiable(hunks);
  }

  Future<String> _readAllCandidate(
    String proposalId,
    int proposalVersion,
    int generation,
  ) async {
    final chunks = StringBuffer();
    String? cursor;
    do {
      final chunk = await _api.getProposalCandidate(
        proposalId: proposalId,
        proposalVersion: proposalVersion,
        cursor: cursor,
      );
      _ensureActive(generation);
      chunks.write(chunk.text);
      cursor = chunk.nextCursor;
    } while (cursor != null);
    return chunks.toString();
  }

  Future<DocumentChangeProposalSnapshot> _pollProposal(
    DocumentChangeProposalSnapshot snapshot,
    int generation,
  ) async {
    if (_taskOrchestrator != null &&
        _activityMetrics != null &&
        pollInterval > Duration.zero &&
        snapshot.proposal.state == DocumentProposalState.generating) {
      return _pollProposalWithRuntime(snapshot, generation);
    }
    for (
      var attempt = 0;
      snapshot.proposal.state == DocumentProposalState.generating &&
          attempt < maxPollAttempts;
      attempt += 1
    ) {
      await Future<void>.delayed(pollInterval);
      _ensureActive(generation);
      snapshot = await _api.getProposal(snapshot.proposal.proposalId);
      _ensureActive(generation);
      final review = _review(snapshot.proposal.proposalId);
      if (review != null) _replaceReview(review.copyWith(snapshot: snapshot));
    }
    return snapshot;
  }

  Future<DocumentChangeProposalSnapshot> _pollProposalWithRuntime(
    DocumentChangeProposalSnapshot snapshot,
    int generation,
  ) {
    final proposalId = snapshot.proposal.proposalId;
    final previous = _proposalPolls.remove(proposalId);
    previous?.poller?.dispose();
    if (previous != null && !previous.completer.isCompleted) {
      previous.completer.complete(previous.snapshot);
    }
    final run = _DigitalTwinProposalPoll(
      snapshot: snapshot,
      generation: generation,
    );
    final stableId = _stableProposalPollId(proposalId);
    // performance-rfc: digital-twin-proposal-poll
    run.poller = OrchestratedPoller(
      orchestrator: _taskOrchestrator!,
      spec: TaskSpec(
        key: 'digital-twin:proposal:$stableId',
        owner: 'digital-twin-proposal',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        deadline: const Duration(seconds: 30),
        retryable: true,
        replaceExisting: true,
      ),
      interval: pollInterval,
      maxBackoff: pollInterval > const Duration(seconds: 30)
          ? pollInterval
          : const Duration(seconds: 30),
      activityMetrics: _activityMetrics,
      metricsOwner: 'digital-twin.proposal.$stableId',
      poll: (token) => _pollProposalOnce(run, token),
    );
    _proposalPolls[proposalId] = run;
    if (_pollingRouteActive) run.poller!.start();
    return run.completer.future;
  }

  Future<bool> _pollProposalOnce(
    _DigitalTwinProposalPoll run,
    AppTaskCancellationToken token,
  ) async {
    token.throwIfCancelled();
    if (!_isActive(run.generation)) {
      _completeProposalPoll(run);
      return false;
    }
    if (run.attempts >= maxPollAttempts) {
      _completeProposalPoll(run);
      return false;
    }
    run.attempts += 1;
    final snapshot = await _api.getProposal(run.snapshot.proposal.proposalId);
    token.throwIfCancelled();
    if (!_isActive(run.generation)) {
      _completeProposalPoll(run);
      return false;
    }
    run.snapshot = snapshot;
    final review = _review(snapshot.proposal.proposalId);
    if (review != null) _replaceReview(review.copyWith(snapshot: snapshot));
    if (snapshot.proposal.state != DocumentProposalState.generating ||
        run.attempts >= maxPollAttempts) {
      _completeProposalPoll(run);
      return false;
    }
    return true;
  }

  void _completeProposalPoll(_DigitalTwinProposalPoll run) {
    if (!run.completer.isCompleted) run.completer.complete(run.snapshot);
  }

  Future<DigitalTwinConfirmation> _pollConfirmationWithRuntime(
    DigitalTwinConfirmation snapshot,
    int generation,
  ) {
    final previous = _confirmationPoll;
    previous?.poller?.dispose();
    if (previous != null && !previous.completer.isCompleted) {
      previous.completer.complete(previous.snapshot);
    }
    final run = _DigitalTwinConfirmationPoll(
      snapshot: snapshot,
      generation: generation,
    );
    final stableId = _stableProposalPollId(snapshot.confirmationTaskId);
    // performance-rfc: digital-twin-confirmation-poll
    run.poller = OrchestratedPoller(
      orchestrator: _taskOrchestrator!,
      spec: TaskSpec(
        key: 'digital-twin:confirmation:$stableId',
        owner: 'digital-twin-confirmation',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        deadline: const Duration(seconds: 30),
        retryable: true,
        replaceExisting: true,
      ),
      interval: pollInterval,
      maxBackoff: pollInterval > const Duration(seconds: 30)
          ? pollInterval
          : const Duration(seconds: 30),
      activityMetrics: _activityMetrics,
      metricsOwner: 'digital-twin.confirmation.$stableId',
      poll: (token) => _pollConfirmationOnce(run, token),
    );
    _confirmationPoll = run;
    if (_pollingRouteActive) run.poller!.start();
    return run.completer.future;
  }

  Future<bool> _pollConfirmationOnce(
    _DigitalTwinConfirmationPoll run,
    AppTaskCancellationToken token,
  ) async {
    token.throwIfCancelled();
    if (!_isActive(run.generation) || run.attempts >= maxPollAttempts) {
      _completeConfirmationPoll(run);
      return false;
    }
    run.attempts += 1;
    final snapshot = await _api.getConfirmation(
      run.snapshot.confirmationTaskId,
    );
    await _recoveryStore.recordConfirmationReport(
      snapshot,
      updateCurrent:
          _isActive(run.generation) &&
          _recoveryStore.pendingConfirmationId == snapshot.confirmationTaskId,
    );
    token.throwIfCancelled();
    if (!_isActive(run.generation)) {
      _completeConfirmationPoll(run);
      return false;
    }
    run.snapshot = snapshot;
    _emit(_state.copyWith(confirmation: snapshot));
    if (snapshot.isTerminal || run.attempts >= maxPollAttempts) {
      _completeConfirmationPoll(run);
      return false;
    }
    return true;
  }

  void _completeConfirmationPoll(_DigitalTwinConfirmationPoll run) {
    if (!run.completer.isCompleted) run.completer.complete(run.snapshot);
  }

  DigitalTwinProposalReview? _review(String proposalId) {
    for (final review in _state.reviews) {
      if (review.snapshot.proposal.proposalId == proposalId) return review;
    }
    return null;
  }

  DigitalTwinVersion? _version(String versionId) {
    for (final version in _state.versions) {
      if (version.versionId == versionId) return version;
    }
    return null;
  }

  void _replaceReview(DigitalTwinProposalReview replacement) {
    _emit(
      _state.copyWith(
        reviews: <DigitalTwinProposalReview>[
          for (final review in _state.reviews)
            if (review.snapshot.proposal.proposalId ==
                replacement.snapshot.proposal.proposalId)
              replacement
            else
              review,
        ],
      ),
    );
  }

  String? _selectedFileId(DigitalTwinCurrent current, String? preferred) {
    if (preferred != null &&
        current.files.any((file) => file.id == preferred)) {
      return preferred;
    }
    for (final file in current.files) {
      if (file.pendingProposalIds.isNotEmpty) return file.id;
    }
    return current.files.isEmpty ? null : current.files.first.id;
  }

  DigitalTwinCurrent _withReviewAssociations(
    DigitalTwinCurrent current,
    List<DigitalTwinProposalReview> reviews,
  ) {
    final associations = <String, Set<String>>{};
    for (final review in reviews) {
      final proposal = review.snapshot.proposal;
      if (proposal.ownerKind != 'profile_conclusion') continue;
      final fileIds = switch (proposal.ownerMetadata['profileKind']) {
        'user_profile' => const ['life_experiences', 'professional_knowledge'],
        'viewpoints_and_methods' => const [
          'professional_knowledge',
          'viewpoints_insights',
          'methods_processes',
        ],
        'language_and_expression' => const ['expression_habits'],
        _ => const <String>[],
      };
      for (final fileId in fileIds) {
        associations.putIfAbsent(fileId, () => {}).add(proposal.proposalId);
      }
    }
    return DigitalTwinCurrent(
      workspaceId: current.workspaceId,
      agentProfileId: current.agentProfileId,
      state: current.state,
      level: current.level,
      pendingReviewCount: reviews.length,
      pendingProposalCount: reviews.length,
      activeProposalIds: reviews
          .map((review) => review.snapshot.proposal.proposalId)
          .toList(),
      currentVersion: current.currentVersion,
      updatedAt: current.updatedAt,
      files: [
        for (final file in current.files)
          if (_isTwinFileId(file.id))
            DigitalTwinLogicalFile(
              id: file.id,
              name: file.name,
              exists: file.exists,
              markdown: file.markdown,
              conclusions: file.conclusions,
              pendingCount: file.pendingCount,
              pendingProposalIds: {
                ...file.pendingProposalIds.where(
                  (id) => reviews.any(
                    (review) => review.snapshot.proposal.proposalId == id,
                  ),
                ),
                ...?associations[file.id],
              }.toList(),
            ),
      ],
    );
  }

  String? _selectedProposalId(
    DigitalTwinCurrent current,
    List<DigitalTwinProposalReview> reviews,
    String? fileId,
    String? preferred,
  ) {
    final ids = <String>{
      for (final review in reviews) review.snapshot.proposal.proposalId,
    };
    if (preferred != null && ids.contains(preferred)) return preferred;
    for (final file in current.files) {
      if (file.id == fileId) {
        for (final id in file.pendingProposalIds) {
          if (ids.contains(id)) return id;
        }
      }
    }
    return reviews.isEmpty ? null : reviews.first.snapshot.proposal.proposalId;
  }

  String? _selectedReviewFileId(
    DigitalTwinCurrent current,
    List<DigitalTwinProposalReview> reviews,
  ) {
    if (_importSource != null || _reviewScopeProposalIds != null) {
      final proposalIds = reviews
          .map((review) => review.snapshot.proposal.proposalId)
          .toSet();
      final files = current.files.where(
        (file) => file.pendingProposalIds.any(proposalIds.contains),
      );
      if (files.any((file) => file.id == _state.selectedFileId)) {
        return _state.selectedFileId;
      }
      if (files.isNotEmpty) return files.first.id;
    }
    return _selectedFileId(current, _state.selectedFileId);
  }

  void _fail(String code) {
    _emit(
      _state.copyWith(
        phase: DigitalTwinControllerPhase.failed,
        errorCode: code,
      ),
    );
  }

  Future<DigitalTwinConfirmation> _recoverConfirmation(
    DigitalTwinConfirmationCommand? command,
  ) async {
    final generation = _generation;
    final taskId =
        _recoveryStore.pendingConfirmationId ?? _acceptedConfirmationId;
    final ids = command?.proposalIds ?? _recoveryStore.pendingProposalIds;
    if (command != null) await _recoveryStore.prepareConfirmation(command);
    _ensureActive(generation);
    late final DigitalTwinConfirmation report;
    try {
      report = taskId == null
          ? await _api.createConfirmation(
              proposals: command!.proposals,
              idempotencyKey: command.idempotencyKey,
              source: command.source,
            )
          : await _api.getConfirmation(taskId);
    } on DigitalTwinApiException catch (error) {
      if (taskId == null &&
          command != null &&
          const {
            'DOCUMENT_PROPOSAL_ETAG_MISMATCH',
            'DOCUMENT_PROPOSAL_STATE_CONFLICT',
            'IDEMPOTENCY_KEY_CONFLICT',
            'INVALID_ARGUMENT',
          }.contains(error.code))
        await _recoveryStore.rejectConfirmationCommand(command, error.code);
      rethrow;
    }
    final adopted = await _recoveryStore.recordConfirmation(
      report.confirmationTaskId,
      ids,
      idempotencyKey: command?.idempotencyKey,
    );
    await _recoveryStore.recordConfirmationReport(
      report,
      updateCurrent: adopted && _isActive(generation),
    );
    _ensureActive(generation);
    if (!adopted ||
        _recoveryStore.pendingConfirmationId != report.confirmationTaskId) {
      throw const _DigitalTwinSuperseded();
    }
    _acceptedConfirmationId = report.confirmationTaskId;
    await onConfirmationAccepted?.call(report.confirmationTaskId, ids);
    final source = command?.source ?? _importSource;
    if (source != null)
      await onConfirmationCreated?.call(source, report.confirmationTaskId);
    return report;
  }

  DigitalTwinProposalCommand _revisionCommand(
    DigitalTwinProposalReview review,
    String instruction,
  ) {
    final hunks = [
      for (final hunk in review.diff)
        if (review.selectedHunkIds.contains(hunk.hunkId))
          DigitalTwinSelectedHunk(
            proposalVersion: review.snapshot.proposal.proposalVersion,
            diffBundleId: review.currentDiffBundleId!,
            hunkId: hunk.hunkId,
            quotedText: hunk.changes.map((change) => change.text).join('\n'),
          ),
    ];
    final request = jsonEncode([
      review.snapshot.etag,
      instruction.trim(),
      for (final hunk in hunks)
        [hunk.proposalVersion, hunk.diffBundleId, hunk.hunkId, hunk.quotedText],
    ]);
    return DigitalTwinProposalCommand(
      operation: DigitalTwinProposalOperation.revise,
      proposal: review.snapshot,
      instruction: instruction.trim(),
      selectedHunks: hunks,
      idempotencyKey:
          'digital-twin-revise-${review.snapshot.proposal.proposalId}-${sha256.convert(utf8.encode(request))}',
    );
  }

  Future<DocumentChangeProposalSnapshot> _dispatchProposalCommand(
    DigitalTwinProposalCommand original,
  ) async {
    if (isPositioningProposal(original.proposal.proposal))
      throw const DigitalTwinApiException('POSITIONING_OWNER_INDEPENDENT');
    var command =
        _recoveryStore.pendingProposalCommands
            .where((entry) => entry.idempotencyKey == original.idempotencyKey)
            .firstOrNull ??
        original;
    DocumentChangeProposalSnapshot receipt;
    if (command.receipt != null) {
      receipt = await _api.getProposal(command.currentProposalId);
    } else if (command.operation == DigitalTwinProposalOperation.revise) {
      receipt = await _api.reviseProposal(
        proposal: command.proposal,
        instruction: command.instruction,
        selectedHunks: command.selectedHunks,
        idempotencyKey: command.idempotencyKey,
      );
    } else {
      final api = _api;
      if (api is DigitalTwinPreparedRegenerationPort) {
        final preparedApi = api as DigitalTwinPreparedRegenerationPort;
        if (command.preparedBody == null) {
          command = command.withPreparedBody(
            await preparedApi.prepareRegeneration(
              proposal: command.proposal,
              instruction: command.instruction,
            ),
          );
          await _recoveryStore.recordPreparedProposal(command);
        }
        if (_disposed) throw const _DigitalTwinSuperseded();
        receipt = await preparedApi.submitRegeneration(
          body: command.preparedBody!,
          idempotencyKey: command.idempotencyKey,
        );
      } else {
        receipt = await api.regenerateProposal(
          proposal: command.proposal,
          instruction: command.instruction,
          idempotencyKey: command.idempotencyKey,
        );
      }
    }
    await _recoveryStore.recordProposalReceipt(command, receipt);
    if (_disposed) return receipt;
    if (command.operation == DigitalTwinProposalOperation.regenerate) {
      final previousId = command.proposal.proposal.proposalId;
      await onProposalReplaced?.call(previousId, receipt.proposal.proposalId);
      if (command.proposal.proposal.state !=
          DocumentProposalState.generationFailed) {
        final previous = await _api.getProposal(previousId);
        if (previous.proposal.state != DocumentProposalState.rejected) {
          await _api.rejectProposal(
            proposal: command.proposal,
            idempotencyKey:
                'digital-twin-reject-$previousId-${command.proposal.proposal.rowVersion}',
          );
        }
      }
      if (_reviewScopeProposalIds != null) {
        _reviewScopeProposalIds = _reviewScopeProposalIds!
            .map((id) => id == previousId ? receipt.proposal.proposalId : id)
            .toSet()
            .toList();
      }
      if (_importProposalIds != null) {
        _importProposalIds = _importProposalIds!
            .map((id) => id == previousId ? receipt.proposal.proposalId : id)
            .toSet()
            .toList();
      }
    }
    return receipt;
  }

  Future<void> _finishProposalCommand(
    DigitalTwinProposalCommand command,
    DocumentChangeProposalSnapshot snapshot,
  ) async {
    final proposal = snapshot.proposal;
    if (proposal.state == DocumentProposalState.generating ||
        proposal.state == DocumentProposalState.applying)
      return;
    final success =
        proposal.state == DocumentProposalState.ready &&
        proposal.failureCode == null;
    final expectedVersion =
        command.operation == DigitalTwinProposalOperation.revise
        ? command.proposal.proposal.proposalVersion + 1
        : 1;
    await _recoveryStore.finishProposalCommand(
      command,
      success && proposal.proposalVersion > expectedVersion
          ? '本次修订要求与回执已保存；候选现为 v${proposal.proposalVersion}，期间已有后续修订。请查看历史版本并重新审阅后确认。'
          : success
          ? '候选已更新为 v${proposal.proposalVersion}，请审阅后确认；正式内容尚未改变。'
          : '候选处理状态：${proposal.state.name}（${proposal.failureCode ?? '请重新审阅'}）。修订要求已保存。',
    );
    _syncRevisionEvents();
  }

  Future<void> _recoverProposalCommands(int generation) async {
    final commands = _recoveryStore.pendingProposalCommands;
    if (commands.isEmpty) return;
    await _recoveryStore.prepareProposalCommands(commands);
    _syncRevisionEvents();
    for (final command in commands) {
      if (isPositioningProposal(command.proposal.proposal)) {
        await _recoveryStore.finishProposalCommand(
          command,
          '定位报告已迁移至独立页面，旧数字孪生操作不再重放。',
        );
        _syncRevisionEvents();
        continue;
      }
      try {
        final receipt = await _dispatchProposalCommand(command);
        await _finishProposalCommand(command, receipt);
        _ensureActive(generation);
      } on _DigitalTwinSuperseded {
        rethrow;
      } catch (error) {
        if (error is DigitalTwinApiException &&
            const {
              'DOCUMENT_PROPOSAL_ETAG_MISMATCH',
              'DOCUMENT_CANDIDATE_EXPIRED',
              'IDEMPOTENCY_KEY_CONFLICT',
            }.contains(error.code)) {
          await _recoveryStore.finishProposalCommand(
            command,
            '本次请求的前置条件已变化（${error.code}）。要求和已收到的回执均已保存，请查看历史并基于最新候选重新审阅。',
          );
          _syncRevisionEvents();
        } else {
          rethrow;
        }
      }
    }
  }

  void _syncRevisionEvents() {
    _revisionEvents
      ..clear()
      ..addAll(_recoveryStore.revisionEvents);
    if (!_disposed) notifyListeners();
  }

  Future<void> _resumeConfirmation(
    DigitalTwinConfirmation confirmation,
    int generation,
  ) async {
    try {
      final result = await _pollConfirmationWithRuntime(
        confirmation,
        generation,
      );
      _ensureActive(generation);
      if (result.isTerminal) await load();
    } on _DigitalTwinSuperseded {
      return;
    } catch (error) {
      if (_isActive(generation)) _fail(_errorCode(error));
    }
  }

  String _key(String operation, String target) =>
      'digital-twin-$operation-$target-${DateTime.now().microsecondsSinceEpoch}';

  String _confirmationKey(
    Iterable<DocumentChangeProposalSnapshot> snapshots,
    DigitalTwinImportSource? source,
  ) {
    final references =
        snapshots
            .map(
              (snapshot) =>
                  '${snapshot.proposal.proposalId}:${snapshot.proposal.proposalVersion}:${snapshot.etag}',
            )
            .toList()
          ..sort();
    final request = jsonEncode({
      'references': references,
      if (source != null) 'sourceTaskId': source.taskId,
      if (source != null) 'triggerId': source.resourceId,
    });
    return 'digital-twin-confirm-${sha256.convert(utf8.encode(request))}';
  }

  String _errorCode(Object error) => switch (error) {
    DigitalTwinApiException value => value.code,
    DocumentChangeProposalException value => value.code,
    FormatException _ => 'DIGITAL_TWIN_RESPONSE_INVALID',
    _ => 'DIGITAL_TWIN_UNAVAILABLE',
  };

  bool _isActive(int generation) => !_disposed && generation == _generation;

  int _beginGeneration() {
    _importProposalIds = null;
    _generation += 1;
    _cancelProposalPolls();
    return _generation;
  }

  void _cancelProposalPolls() {
    _importPoller?.dispose();
    _importPoller = null;
    for (final run in _proposalPolls.values) {
      run.poller?.dispose();
      _completeProposalPoll(run);
    }
    _proposalPolls.clear();
    final confirmation = _confirmationPoll;
    confirmation?.poller?.dispose();
    if (confirmation != null) _completeConfirmationPoll(confirmation);
    _confirmationPoll = null;
  }

  void _ensureActive(int generation) {
    if (!_isActive(generation)) throw const _DigitalTwinSuperseded();
  }

  void _emit(DigitalTwinControllerState value) {
    if (_disposed) return;
    final reviews = value.reviews
        .where((review) => !isPositioningProposal(review.snapshot.proposal))
        .toList();
    final current = value.current;
    final comparison = value.comparison;
    _state = value.copyWith(
      reviews: reviews,
      current: current == null
          ? null
          : _withReviewAssociations(current, reviews),
      previewFiles: value.previewFiles
          .where((file) => _isTwinFileId(file.id))
          .toList(),
      comparison: comparison == null
          ? null
          : DigitalTwinVersionComparison(
              baseVersion: comparison.baseVersion,
              version: comparison.version,
              files: comparison.files
                  .where((file) => _isTwinFileId(file.id))
                  .toList(),
            ),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _cancelProposalPolls();
    super.dispose();
  }
}

const _unset = Object();

final class _DigitalTwinSuperseded implements Exception {
  const _DigitalTwinSuperseded();
}

final class _DigitalTwinProposalPoll {
  _DigitalTwinProposalPoll({required this.snapshot, required this.generation});

  DocumentChangeProposalSnapshot snapshot;
  final int generation;
  final Completer<DocumentChangeProposalSnapshot> completer =
      Completer<DocumentChangeProposalSnapshot>();
  int attempts = 0;
  OrchestratedPoller? poller;
}

final class _DigitalTwinConfirmationPoll {
  _DigitalTwinConfirmationPoll({
    required this.snapshot,
    required this.generation,
  });

  DigitalTwinConfirmation snapshot;
  final int generation;
  final Completer<DigitalTwinConfirmation> completer =
      Completer<DigitalTwinConfirmation>();
  int attempts = 0;
  OrchestratedPoller? poller;
}

bool _proposalCanConfirm(DocumentProposalState state) =>
    state == DocumentProposalState.ready ||
    state == DocumentProposalState.applyFailed;

bool _reviewCanConfirm(DocumentChangeProposal proposal) =>
    _proposalCanConfirm(proposal.state) &&
    proposal.candidateAvailable &&
    proposal.hasChanges != false;

String _stableProposalPollId(String value) {
  final digest = sha256.convert(utf8.encode(value)).toString();
  return digest.substring(0, 16);
}
