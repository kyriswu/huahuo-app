import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../data/digital_twin_api.dart';
import '../data/digital_twin_material_store.dart';
import '../domain/digital_twin_material.dart';
import '../domain/digital_twin_operation.dart';
import '../domain/document_change_proposal_models.dart';

final class DigitalTwinMaterialController extends ChangeNotifier {
  DigitalTwinMaterialController({
    required DigitalTwinMaterialStore store,
    DigitalTwinApiPort? api,
    DigitalTwinApiPort Function()? apiFactory,
    required this.resolveSource,
    TaskOrchestrator? orchestrator,
    RuntimeActivityMetrics? activityMetrics,
    DiagnosticLogger? diagnosticLogger,
  }) : _store = store,
       _logger = diagnosticLogger,
       _apiFactory = apiFactory ?? (() => api!) {
    if (orchestrator != null && activityMetrics != null) {
      _poller = OrchestratedPoller(
        orchestrator: orchestrator,
        spec: TaskSpec(
          key: 'digital-twin:material-queue',
          owner: 'digital-twin-material-queue',
          priority: TaskPriority.userVisible,
          resources: {TaskResource.network},
          foregroundOnly: true,
          deadline: Duration(seconds: 30),
          retryable: true,
          replaceExisting: true,
        ),
        interval: const Duration(seconds: 3),
        maxBackoff: const Duration(seconds: 30),
        activityMetrics: activityMetrics,
        metricsOwner: 'digital-twin.material-queue',
        poll: (token) async {
          token.throwIfCancelled();
          if (++_attempts > 200) {
            observationPaused = true;
            _notify();
            return false;
          }
          await refresh(cancelled: () => token.isCancelled);
          token.throwIfCancelled();
          if (errorCode != null) throw DigitalTwinApiException(errorCode!);
          return !_disposed &&
              _active &&
              items.any(
                (item) => const {
                  DigitalTwinMaterialStatus.generating,
                  DigitalTwinMaterialStatus.awaitingVersionVerification,
                  DigitalTwinMaterialStatus.waitingSource,
                  DigitalTwinMaterialStatus.submitting,
                }.contains(item.status),
              );
        },
      );
    }
  }

  final DigitalTwinMaterialStore _store;
  final DiagnosticLogger? _logger;
  final DigitalTwinApiPort Function() _apiFactory;
  DigitalTwinApiPort get _api => _apiFactory();
  final Future<DigitalTwinMaterialSource?> Function(DigitalTwinMaterial)
  resolveSource;
  OrchestratedPoller? _poller;
  bool _disposed = false;
  bool _active = false;
  static final Object _defaultActivityOwner = Object();
  final Set<Object> _activityOwners = {};
  bool _refreshing = false;
  Completer<void>? _refreshCompletion;
  int _attempts = 0;
  bool isSubmitting = false;
  bool observationPaused = false;
  String? errorCode;

  List<DigitalTwinMaterial> get items => _store.read();
  Set<String> get pendingNoteIds => {
    for (final item in items)
      if (!item.isTerminal && item.referenceKind == 'note') item.referenceId,
  };

  Future<bool> enqueue({
    required String referenceId,
    required String title,
    String referenceKind = 'note',
    String revisionHint = '',
  }) async {
    if (_disposed || referenceId.trim().isEmpty) return false;
    final identity = jsonEncode([
      referenceKind,
      referenceId.trim(),
      revisionHint,
    ]);
    final id = sha256.convert(utf8.encode(identity)).toString();
    final existing = items.where((item) => item.id == id).firstOrNull;
    try {
      await _store.save(
        existing != null && existing.status != DigitalTwinMaterialStatus.removed
            ? existing
            : DigitalTwinMaterial(
                id: id,
                referenceKind: referenceKind,
                referenceId: referenceId.trim(),
                title: title,
                createdAt: DateTime.now().toUtc(),
              ),
      );
      errorCode = null;
      _log('enqueued', material: _item(id));
      _notify();
      return !_disposed;
    } catch (error) {
      errorCode = 'DIGITAL_TWIN_QUEUE_SAVE_FAILED';
      _log('enqueue', material: _item(id), failure: error, code: errorCode);
      _notify();
      return false;
    }
  }

  Future<bool> enqueueRecordingJobs(Map<String, String> jobs) async {
    if (_disposed || jobs.keys.any((id) => id.trim().isEmpty)) return false;
    try {
      final existing = {for (final item in items) item.id: item};
      await _store.saveAll([
        for (final entry in jobs.entries)
          () {
            final id = sha256
                .convert(
                  utf8.encode(
                    jsonEncode(['recording_job', entry.key.trim(), '']),
                  ),
                )
                .toString();
            final previous = existing[id];
            return previous != null &&
                    previous.status != DigitalTwinMaterialStatus.removed
                ? previous
                : DigitalTwinMaterial(
                    id: id,
                    referenceKind: 'recording_job',
                    referenceId: entry.key.trim(),
                    title: entry.value,
                    createdAt: DateTime.now().toUtc(),
                  );
          }(),
      ]);
      errorCode = null;
      _notify();
      return !_disposed;
    } catch (error) {
      errorCode = 'DIGITAL_TWIN_QUEUE_SAVE_FAILED';
      _log('enqueue_recordings', failure: error, code: errorCode);
      _notify();
      return false;
    }
  }

  Future<bool> remove(String id) async {
    final item = _item(id);
    if (item == null || !item.canRemove || isSubmitting) return false;
    try {
      await _save(item.copyWith(status: DigitalTwinMaterialStatus.removed));
      return true;
    } catch (_) {
      errorCode = 'DIGITAL_TWIN_QUEUE_SAVE_FAILED';
      _notify();
      return false;
    }
  }

  void setActive(bool active, {Object? owner}) {
    if (_disposed) return;
    final identity = owner ?? _defaultActivityOwner;
    if (active) {
      _activityOwners.add(identity);
    } else {
      _activityOwners.remove(identity);
    }
    final effectiveActive = _activityOwners.isNotEmpty;
    if (_active == effectiveActive && !(effectiveActive && observationPaused))
      return;
    _active = effectiveActive;
    if (effectiveActive) {
      resumeObservation();
    } else {
      _poller?.stop();
    }
  }

  void resumeObservation() {
    if (_disposed || !_active) return;
    _attempts = 0;
    observationPaused = false;
    scheduleMicrotask(() {
      if (!_disposed && _active) _poller?.start();
    });
  }

  Future<void> submit(List<String> ids) async {
    if (_disposed || isSubmitting) return;
    await _refreshCompletion?.future;
    if (_disposed || isSubmitting) return;
    isSubmitting = true;
    errorCode = null;
    _notify();
    try {
      await _store.approve(ids.toSet().toList());
      for (final id in ids.toSet()) {
        if (_disposed) return;
        final item = _item(id);
        if (item == null || !item.canSubmit) continue;
        await _submit(item);
      }
    } catch (error) {
      if (!_disposed)
        errorCode = error is DigitalTwinApiException
            ? error.code
            : 'DIGITAL_TWIN_QUEUE_SAVE_FAILED';
    } finally {
      isSubmitting = false;
      _notify();
      resumeObservation();
    }
  }

  Future<void> _submit(DigitalTwinMaterial item) async {
    var current = item;
    try {
      if (_api is! DigitalTwinMaterialApiPort) {
        throw const DigitalTwinApiException(
          'DIGITAL_TWIN_MATERIAL_API_UNAVAILABLE',
        );
      }
      final source = current.source ?? await resolveSource(current);
      if (_disposed) return;
      if (source == null) {
        await _save(
          current.copyWith(
            status: DigitalTwinMaterialStatus.waitingSource,
            clearError: true,
          ),
        );
        return;
      }
      current = await _store.updateMaterial(
        current.id,
        (latest) => latest.copyWith(
          source: source,
          status: DigitalTwinMaterialStatus.submitting,
          clearError: true,
        ),
      );
      _notify();
      for (final kind in digitalTwinMaterialProfileKinds) {
        if (_disposed) return;
        current = _item(item.id)!;
        if (current.proposalIds.containsKey(kind)) continue;
        final snapshot = await (_api as DigitalTwinMaterialApiPort)
            .createMaterialProposal(
              source: source,
              profileKind: kind,
              idempotencyKey:
                  'twin-material-${sha256.convert(utf8.encode(jsonEncode([source.workspaceId, source.noteId, source.rawPartRevisionId])))}-$kind',
            );
        current = await _store.updateMaterial(
          current.id,
          (latest) => latest.copyWith(
            proposalIds: {
              ...latest.proposalIds,
              kind: latest.proposalIds[kind] ?? snapshot.proposal.proposalId,
            },
          ),
        );
        _notify();
        if (_disposed) return;
      }
      await _store.updateMaterial(
        current.id,
        (latest) =>
            latest.copyWith(status: DigitalTwinMaterialStatus.generating),
      );
      _notify();
    } catch (error) {
      if (_disposed) return;
      errorCode = error is DigitalTwinApiException
          ? error.code
          : 'DIGITAL_TWIN_MATERIAL_CONTINUATION_REQUIRED';
      try {
        await _store.updateMaterial(
          current.id,
          (latest) => latest.copyWith(
            status: latest.proposalIds.isEmpty
                ? DigitalTwinMaterialStatus.failed
                : DigitalTwinMaterialStatus.partialFailure,
            errorCode: errorCode,
          ),
        );
        _notify();
      } catch (_) {
        errorCode = 'DIGITAL_TWIN_QUEUE_SAVE_FAILED';
        _notify();
      }
    }
  }

  Future<void> refresh({bool Function()? cancelled}) async {
    if (_disposed || _refreshing || isSubmitting) return;
    _refreshing = true;
    final completion = Completer<void>();
    _refreshCompletion = completion;
    bool stopped() => _disposed || (cancelled?.call() ?? false);
    String? refreshError;
    try {
      for (final item in items) {
        if (stopped()) return;
        try {
          if (item.canSubmit &&
              const {
                DigitalTwinMaterialStatus.waitingSource,
                DigitalTwinMaterialStatus.submitting,
              }.contains(item.status)) {
            isSubmitting = true;
            try {
              await _submit(item);
            } finally {
              isSubmitting = false;
            }
            continue;
          }
          if (const {
                DigitalTwinMaterialStatus.removed,
                DigitalTwinMaterialStatus.completed,
              }.contains(item.status) ||
              item.proposalIds.isEmpty)
            continue;
          final snapshots = <DocumentChangeProposalSnapshot>[];
          for (final id in item.proposalIds.values) {
            if (stopped()) return;
            snapshots.add(await _api.getProposal(id));
          }
          if (stopped()) return;
          final states = snapshots.map((entry) => entry.proposal);
          final working = states.any(
            (entry) => const {
              DocumentProposalState.generating,
              DocumentProposalState.applying,
            }.contains(entry.state),
          );
          final failed = states.any(
            (entry) => const {
              DocumentProposalState.generationFailed,
              DocumentProposalState.applyFailed,
              DocumentProposalState.stale,
            }.contains(entry.state),
          );
          final ready = states.any(
            (entry) =>
                entry.state == DocumentProposalState.ready &&
                entry.hasChanges != false,
          );
          final applied = states
              .where((entry) => entry.state == DocumentProposalState.applied)
              .toList();
          String? versionId;
          if (applied.isNotEmpty && !working && !ready) {
            var evidence = _item(item.id)!.confirmedVersions;
            bool hasEvidence(DocumentChangeProposal entry) =>
                evidence.containsKey(
                  digitalTwinAppliedEvidenceKey(
                    entry.proposalId,
                    entry.proposalVersion,
                  ),
                );
            for (final taskId in item.confirmationTaskIds) {
              if (applied.every(hasEvidence)) break;
              if (stopped()) return;
              final report = await _api.getConfirmation(taskId);
              if (stopped()) return;
              await _store.recordConfirmationReport(
                report,
                updateCurrent: item.confirmationId == report.confirmationTaskId,
              );
              evidence = _item(item.id)!.confirmedVersions;
            }
            final missing = applied
                .where((entry) => !hasEvidence(entry))
                .map((entry) => entry.proposalId)
                .toSet();
            versionId = missing.isEmpty
                ? (_item(item.id)!.versionId ??
                      evidence[digitalTwinAppliedEvidenceKey(
                        applied.first.proposalId,
                        applied.first.proposalVersion,
                      )])
                : null;
            final versions = missing.isEmpty
                ? const <DigitalTwinVersion>[]
                : await _api.getVersions();
            if (stopped()) return;
            DigitalTwinVersion? newestEvidence;
            final discovered = <String, String>{};
            for (final version in versions) {
              if (stopped()) return;
              final detail = await _api.getVersion(version.versionId);
              final previousMissingCount = missing.length;
              missing.removeWhere(
                (id) => detail.proposalResults.any(
                  (result) =>
                      result.proposalId == id &&
                      result.state == DocumentProposalState.applied &&
                      result.failureCode == null &&
                      applied.any(
                        (entry) =>
                            entry.proposalId == id &&
                            entry.proposalVersion == result.proposalVersion,
                      ),
                ),
              );
              for (final entry in applied) {
                if (detail.proposalResults.any(
                  (result) =>
                      result.proposalId == entry.proposalId &&
                      result.proposalVersion == entry.proposalVersion &&
                      result.state == DocumentProposalState.applied &&
                      result.failureCode == null,
                )) {
                  discovered[digitalTwinAppliedEvidenceKey(
                        entry.proposalId,
                        entry.proposalVersion,
                      )] =
                      version.versionId;
                }
              }
              if (missing.length < previousMissingCount &&
                  (newestEvidence == null ||
                      version.versionNumber > newestEvidence.versionNumber)) {
                newestEvidence = version;
              }
              if (missing.isEmpty) {
                versionId = newestEvidence?.versionId;
                break;
              }
            }
            if (discovered.isNotEmpty && !stopped()) {
              await _store.updateMaterial(
                item.id,
                (latest) => latest.copyWith(
                  confirmedVersions: {
                    ...latest.confirmedVersions,
                    ...discovered,
                  },
                  versionId: versionId,
                ),
              );
            }
          }
          if (stopped()) return;
          final status = working
              ? DigitalTwinMaterialStatus.generating
              : failed ||
                    item.proposalIds.length <
                        digitalTwinMaterialProfileKinds.length
              ? DigitalTwinMaterialStatus.partialFailure
              : ready
              ? DigitalTwinMaterialStatus.reviewReady
              : applied.isNotEmpty
              ? (versionId == null
                    ? DigitalTwinMaterialStatus.awaitingVersionVerification
                    : DigitalTwinMaterialStatus.completed)
              : DigitalTwinMaterialStatus.noChanges;
          final latest = _item(item.id);
          if (latest == null ||
              !mapEquals(latest.proposalIds, item.proposalIds))
            continue;
          await _save(
            latest.copyWith(
              status: status,
              versionId: versionId,
              clearError: !failed,
              errorCode: failed
                  ? states
                        .where((entry) => entry.failureCode != null)
                        .firstOrNull
                        ?.failureCode
                  : null,
            ),
          );
        } catch (error) {
          if (stopped()) return;
          refreshError = switch (error) {
            DigitalTwinApiException value => value.code,
            DocumentChangeProposalException value => value.code,
            _ => 'DIGITAL_TWIN_MATERIAL_READ_FAILED',
          };
          _log('refresh', material: item, failure: error, code: refreshError);
          try {
            await _store.updateMaterial(
              item.id,
              (latest) => latest.copyWith(errorCode: refreshError),
            );
          } catch (_) {
            refreshError = 'DIGITAL_TWIN_QUEUE_SAVE_FAILED';
          }
        }
      }
      errorCode = refreshError;
    } catch (error) {
      if (!stopped())
        errorCode = error is DigitalTwinApiException
            ? error.code
            : 'DIGITAL_TWIN_MATERIAL_READ_FAILED';
    } finally {
      _refreshing = false;
      if (!completion.isCompleted) completion.complete();
      if (identical(_refreshCompletion, completion)) _refreshCompletion = null;
      _notify();
    }
  }

  DigitalTwinMaterial? _item(String id) =>
      items.where((item) => item.id == id).firstOrNull;

  Future<void> _save(DigitalTwinMaterial item) async {
    if (_disposed) return;
    final previous = _item(item.id);
    try {
      await _store.save(item);
    } catch (error) {
      _log(
        'persist_material_state',
        material: item,
        failure: error,
        code: 'DIGITAL_TWIN_QUEUE_SAVE_FAILED',
      );
      throw const DigitalTwinApiException('DIGITAL_TWIN_QUEUE_SAVE_FAILED');
    }
    if (previous?.status != item.status ||
        previous?.errorCode != item.errorCode) {
      _log('state_saved', material: item, code: item.errorCode);
    }
    _notify();
  }

  void _log(
    String stage, {
    DigitalTwinMaterial? material,
    Object? failure,
    String? code,
  }) {
    final logger = _logger;
    if (logger == null || logger.isDisposed) return;
    try {
      logger.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.assets,
          severity: code == null
              ? DiagnosticSeverity.info
              : DiagnosticSeverity.warning,
          safeSummary: code == null
              ? 'Digital twin material state saved'
              : 'Digital twin material operation failed',
          correlationId: material == null
              ? null
              : 'digital-twin:${material.id}',
          flushImmediately: true,
          metadata: {
            'component': 'digital_twin_material',
            'stage': stage,
            'material_id': material?.id,
            'material_status': material?.status.name,
            'proposal_count': material?.proposalIds.length,
            'source_note_id': material?.source?.noteId,
            'error_code': code,
            'exception_type': failure?.runtimeType.toString(),
          },
        ),
      );
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poller?.dispose();
    super.dispose();
  }
}
