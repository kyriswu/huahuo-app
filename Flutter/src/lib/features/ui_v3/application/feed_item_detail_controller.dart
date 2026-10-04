import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../chat/application/chat_run_tracker.dart';
import '../../recordings/application/recording_batch_transcription_controller.dart';
import '../../recordings/application/recording_processing_tracker.dart';
import '../../recordings/data/recording_api.dart';
import '../data/note_file_agent_client.dart';
import '../data/automatic_outline_recovery_store.dart';
import '../data/outline_repository.dart';
import '../data/sprout_repository.dart';
import '../domain/feed_item_models.dart';
import '../domain/profile_activity_models.dart';
import 'knowledge_library_controller.dart';
import 'knowledge_note_port.dart';
import 'profile_hub_controller.dart';

enum V3LinkedMaterialScope { mine, subscribed, square }

enum V3OutlineTaskStatus { notStarted, running, succeeded, failed }

enum V3DerivedTaskStatus { idle, running, succeeded, failed }

extension V3LinkedMaterialScopeX on V3LinkedMaterialScope {
  String get label => switch (this) {
    V3LinkedMaterialScope.mine => '我的内容',
    V3LinkedMaterialScope.subscribed => '已订阅',
    V3LinkedMaterialScope.square => '知识世界',
  };
}

String _sproutFailureMessage(String code) => switch (code) {
  'AGENT_HNOTE_EXACT_REVISION_REQUIRED' => '笔记同步完成后才能生成深度洞察。',
  'AGENT_SYNC_UNAVAILABLE' => '云端同步暂不可用，请稍后重试。',
  'AGENT_SYNC_FAILED' => '笔记同步未完成，请稍后重试。',
  'AGENT_SYNC_SUPERSEDED' => '笔记内容刚刚更新，正在重新同步，请再试一次。',
  'SKILL_INSTALLATION_REQUIRED' => '深度洞察能力尚未安装。',
  'SKILL_INSTALLATION_DISABLED' => '深度洞察能力当前已停用。',
  'AGENT_PROFILE_NOT_SELECTABLE' ||
  'SKILL_SELECTION_NOT_CANDIDATE' => '深度洞察能力尚未发布。',
  'FAYA_WORKSPACE_REQUIRED' => '请登录并等待工作空间准备完成后再试。',
  'FAYA_SOURCE_NOTE_REQUIRED' ||
  'FAYA_SOURCE_REVISION_REQUIRED' ||
  'FAYA_SOURCE_READ_FAILED' => '笔记同步完成后才能生成深度洞察。',
  'FAYA_SOURCE_REVISION_CHANGED' => '笔记内容已更新，请刷新后再生成深度洞察。',
  'FAYA_SOURCE_NOTE_EMPTY' => '笔记内容为空，无法生成深度洞察报告。',
  'FAYA_RUN_SUBMIT_FAILED' ||
  'FAYA_RUN_POLL_FAILED' ||
  'FAYA_RUN_POLL_TIMEOUT' => '深度洞察请求暂时无法完成，请重试。',
  'FAYA_GERMINATION_CONFLICT' ||
  'FAYA_OUTLINE_CHANGED' => '笔记内容已更新，请刷新后再生成深度洞察。',
  'FAYA_RESULT_CONTRACT_INVALID' => '深度洞察结果未能正确保存，请重试。',
  _ => '暂时无法生成深度洞察报告，请重试。',
};

String _outlineFailureMessage(String code) => switch (code) {
  'OUTLINE_HNOTE_EXACT_REVISION_REQUIRED' ||
  'OUTLINE_SOURCE_READ_FAILED' => '资产尚未完成云端同步，请稍后重试。',
  'OUTLINE_SYNC_UNAVAILABLE' => '云端同步暂不可用，请稍后重试。',
  'OUTLINE_SYNC_FAILED' => '资产同步未完成，请稍后重试。',
  'OUTLINE_SYNC_SUPERSEDED' => '资产内容刚刚更新，正在重新同步，请再试一次。',
  'OUTLINE_SYNC_NOT_ALLOWED' => '该资产为只读内容，不能生成个人纲要。',
  'OUTLINE_SYNC_CONFLICT' ||
  'OUTLINE_SOURCE_REVISION_CHANGED' ||
  'OUTLINE_WRITE_CONFLICT' => '资产内容已更新，请刷新后重试。',
  'OUTLINE_SOURCE_EMPTY' => '原始内容为空，无法生成纲要。',
  'OUTLINE_WORKSPACE_REQUIRED' => '请登录并等待工作空间准备完成后再试。',
  'OUTLINE_CAPABILITY_NOT_PUBLISHED' => '纲要能力当前未发布，请稍后再试。',
  'OUTLINE_RUN_SUBMIT_FAILED' ||
  'OUTLINE_RUN_POLL_FAILED' ||
  'OUTLINE_BACKEND_UNAVAILABLE' => '纲要请求暂时无法完成，请重试。',
  'OUTLINE_RESULT_CONTRACT_INVALID' => '纲要结果未能正确保存，请重试。',
  'WORKSPACE_NOT_READY' => '工作空间尚未准备完成，原始转写已保留，请稍后重试生成纲要。',
  'NOTE_RECORDING_OUTLINE_FAILED' => '录音纲要写入笔记失败，请稍后重试。',
  'RECORDING_OUTLINE_FAILED' => '录音自动纲要生成失败。',
  'RECORDING_OUTLINE_RETRY_FAILED' => '录音纲要重试未能提交，请稍后再试。',
  'RECORDING_OUTLINE_RETRY_RESPONSE_INVALID' => '录音纲要重试响应无效，请稍后再试。',
  _ => '暂时无法生成纲要，请重试。',
};

typedef RecordingOutlinePollDelay = Future<void> Function(Duration duration);

final feedItemDetailControllerProvider = ChangeNotifierProvider.autoDispose
    .family<FeedItemDetailController, String>((ref, itemId) {
      final library = ref.watch(knowledgeLibraryControllerProvider.notifier);
      final item = library.noteForId(itemId);
      final mayUseBackendRecordingOutline =
          item == null || item.usesBackendRecordingOutline;
      final controller = FeedItemDetailController.withDependencies(
        itemId: itemId,
        library: library,
        sproutRepository: ref.read(sproutRepositoryProvider),
        profileHub: ref.read(profileHubControllerProvider),
        outlineRepository: ref.read(outlineRepositoryProvider),
        runTracker: ref.read(chatRunTrackerProvider),
        recordingApi: mayUseBackendRecordingOutline
            ? ref.read(recordingApiProvider)
            : null,
        recordingProcessingRetryPort: mayUseBackendRecordingOutline
            ? ref.read(recordingProcessingTrackerProvider)
            : null,
        recordingOutlineRetryLifecyclePort: mayUseBackendRecordingOutline
            ? ref.read(recordingBatchTranscriptionControllerProvider)
            : null,
        taskOrchestrator: ref.read(taskOrchestratorProvider),
        activityMetrics: ref.read(runtimeActivityMetricsProvider),
      );
      library.addListener(controller.refreshFromLibrary);
      final tracker = ref.read(chatRunTrackerProvider);
      tracker.addListener(controller.refreshFromTaskTracker);
      controller.refreshFromTaskTracker();
      ref.onDispose(() {
        library.removeListener(controller.refreshFromLibrary);
        tracker.removeListener(controller.refreshFromTaskTracker);
      });
      return controller;
    });

final class FeedItemDetailController extends ChangeNotifier {
  FeedItemDetailController(
    String itemId,
    KnowledgeLibraryController library, [
    SproutRepository? sproutRepository,
    ProfileHubController? profileHub,
    OutlineRepository? outlineRepository,
    DerivedPartRunTrackingPort? runTracker,
  ]) : this.withDependencies(
         itemId: itemId,
         library: library,
         sproutRepository: sproutRepository,
         profileHub: profileHub,
         outlineRepository: outlineRepository,
         runTracker: runTracker,
       );

  FeedItemDetailController.withDependencies({
    required this.itemId,
    required KnowledgeLibraryController library,
    SproutRepository? sproutRepository,
    ProfileHubController? profileHub,
    OutlineRepository? outlineRepository,
    DerivedPartRunTrackingPort? runTracker,
    RecordingApiPort? recordingApi,
    Duration recordingPollInterval = const Duration(seconds: 3),
    RecordingOutlinePollDelay? recordingPollDelay,
    String Function()? idempotencyKeyFactory,
    RecordingProcessingRetryPort? recordingProcessingRetryPort,
    RecordingOutlineRetryLifecyclePort? recordingOutlineRetryLifecyclePort,
    TaskOrchestrator? taskOrchestrator,
    RuntimeActivityMetrics? activityMetrics,
    this.recordingMaxPollAttempts = 300,
  }) : _library = library,
       _outlineRepository =
           outlineRepository ?? const UnavailableOutlineRepository(),
       _sproutRepository =
           sproutRepository ?? const UnavailableSproutRepository(),
       _profileHub = profileHub ?? ProfileHubController(),
       _runTracker = runTracker,
       _recordingApi = recordingApi,
       _recordingPollInterval = recordingPollInterval,
       _recordingPollDelay = recordingPollDelay ?? Future<void>.delayed,
       _idempotencyKeyFactory = idempotencyKeyFactory,
       _recordingProcessingRetryPort = recordingProcessingRetryPort,
       _recordingOutlineRetryLifecyclePort = recordingOutlineRetryLifecyclePort,
       _taskOrchestrator = taskOrchestrator,
       _activityMetrics = activityMetrics {
    final authoritativeItem = _library.noteForId(itemId);
    _hasAuthoritativeItem = authoritativeItem != null;
    _item = authoritativeItem ?? _fallbackItem(itemId);
    _outlineStatus = _outlineStatusFor(_item);
    final submission = _library.sproutSubmissionFor(itemId);
    _sproutStatus =
        submission?.status ??
        (_isTransientSproutStatus(_item.sproutStatus)
            ? V3SproutTaskStatus.notStarted
            : _item.sproutStatus);
    _sproutErrorCode = submission?.errorCode;
    _trackServerDerivedTasks(_item);
    unawaited(_trackRecordingOutline(_item));
    _restoreLatestDerivedFailure(
      outlinePending:
          !usesBackendRecordingOutline &&
          _isPartPending(NoteFileAgentPart.outline),
      sproutPending: _isPartPending(NoteFileAgentPart.germination),
    );
    _restoreRecordingOutlineFromTracker();
    _ensureRecordingOutlinePolling();
  }

  final String itemId;
  final KnowledgeLibraryController _library;
  final OutlineRepository _outlineRepository;
  final SproutRepository _sproutRepository;
  final ProfileHubController _profileHub;
  final DerivedPartRunTrackingPort? _runTracker;
  final RecordingApiPort? _recordingApi;
  final Duration _recordingPollInterval;
  final RecordingOutlinePollDelay _recordingPollDelay;
  final String Function()? _idempotencyKeyFactory;
  final RecordingProcessingRetryPort? _recordingProcessingRetryPort;
  final RecordingOutlineRetryLifecyclePort? _recordingOutlineRetryLifecyclePort;
  final TaskOrchestrator? _taskOrchestrator;
  final RuntimeActivityMetrics? _activityMetrics;
  final int recordingMaxPollAttempts;
  V3ContentStage _stage = V3ContentStage.raw;
  late V3FeedItem _item;
  bool _hasAuthoritativeItem = false;
  final Set<String> _draftLinkedIds = <String>{};
  V3LinkedMaterialScope _linkedMaterialScope = V3LinkedMaterialScope.mine;
  String _linkedMaterialQuery = '';
  String? _sproutErrorCode;
  V3SproutTaskStatus _sproutStatus = V3SproutTaskStatus.notStarted;
  V3OutlineTaskStatus _outlineStatus = V3OutlineTaskStatus.notStarted;
  String? _outlineErrorCode;
  String? _verifiedRecordingOutlineTaskId;
  String? _verifiedRecordingOutlineRevision;
  String? _recordingOutlineTaskId;
  String? _expectedRecordingOutlineTaskId;
  String? _supersededRecordingOutlineTaskId;
  ({
    String localNoteId,
    String remoteNoteId,
    String inputPartRevisionId,
    String targetPartRevisionId,
    String operationId,
    NoteFileAgentRunSnapshot accepted,
  })?
  _acceptedOutlineAdmission;
  int _outlineOperationSequence = 0;
  int _sproutOperationSequence = 0;
  List<RecordingRetryAction> _recordingOutlineRetryActions =
      const <RecordingRetryAction>[];
  Future<void>? _recordingOutlinePoll;
  OrchestratedPoller? _recordingOutlinePoller;
  int _recordingPollAttempts = 0;
  bool _recordingPollingDesired = false;
  bool _recordingPollingRouteActive = true;
  int _recordingPollGeneration = 0;
  bool _disposed = false;

  V3ContentStage get stage => _stage;
  V3FeedItem get item => _item;
  bool get hasAuthoritativeItem => _hasAuthoritativeItem;
  Set<String> get draftLinkedIds => Set<String>.unmodifiable(_draftLinkedIds);
  V3LinkedMaterialScope get linkedMaterialScope => _linkedMaterialScope;
  String get linkedMaterialQuery => _linkedMaterialQuery;
  String? get sproutErrorCode => _sproutErrorCode;
  V3SproutTaskStatus get sproutStatus => _sproutStatus;
  V3OutlineTaskStatus get outlineStatus => _outlineStatus;
  V3DerivedTaskStatus get outlineTaskStatus => switch (_outlineStatus) {
    V3OutlineTaskStatus.notStarted => V3DerivedTaskStatus.idle,
    V3OutlineTaskStatus.running => V3DerivedTaskStatus.running,
    V3OutlineTaskStatus.succeeded => V3DerivedTaskStatus.succeeded,
    V3OutlineTaskStatus.failed => V3DerivedTaskStatus.failed,
  };
  V3DerivedTaskStatus get sproutTaskStatus => switch (_sproutStatus) {
    V3SproutTaskStatus.notStarted => V3DerivedTaskStatus.idle,
    V3SproutTaskStatus.queued ||
    V3SproutTaskStatus.running => V3DerivedTaskStatus.running,
    V3SproutTaskStatus.succeeded => V3DerivedTaskStatus.succeeded,
    V3SproutTaskStatus.failed => V3DerivedTaskStatus.failed,
  };
  String? get outlineErrorCode => _outlineErrorCode;
  bool get usesBackendRecordingOutline => _item.usesBackendRecordingOutline;
  bool get canGenerateOutline => !usesBackendRecordingOutline;
  bool get canRetryOutline => usesBackendRecordingOutline
      ? _authorizedRecordingRetryAction != null
      : true;

  void setRecordingPollingRouteActive(bool active) {
    if (_disposed || _recordingPollingRouteActive == active) return;
    _recordingPollingRouteActive = active;
    if (!active) {
      _recordingOutlinePoller?.stop();
      return;
    }
    if (_recordingPollingDesired) {
      if (_recordingOutlinePoller == null) {
        _installRecordingOutlinePoller();
      } else {
        _recordingOutlinePoller!.start();
      }
    }
  }

  String? resultPartRevision(V3ContentStage stage) {
    final value = switch (stage) {
      V3ContentStage.raw => _item.rawPartRevisionId,
      V3ContentStage.summary => _item.outlinePartRevisionId,
      V3ContentStage.sprout => _item.germinationPartRevisionId,
    };
    final revision = value?.trim();
    return revision == null || revision.isEmpty ? null : revision;
  }

  Future<Set<String>> verifiedResultTaskIds({
    required V3ContentStage stage,
    required Iterable<String> candidateTaskIds,
  }) async {
    final candidates = <String>{
      for (final value in candidateTaskIds)
        if (value.trim().isNotEmpty) value.trim(),
    };
    final outputRevision = resultPartRevision(stage);
    final remoteNoteId = _item.remoteNoteId?.trim();
    if (candidates.isEmpty ||
        outputRevision == null ||
        remoteNoteId == null ||
        remoteNoteId.isEmpty) {
      return const <String>{};
    }
    final targetPart = switch (stage) {
      V3ContentStage.raw => NoteFileAgentPart.raw,
      V3ContentStage.summary => NoteFileAgentPart.outline,
      V3ContentStage.sprout => NoteFileAgentPart.germination,
    };
    final verified = <String>{};
    final recordingOutlineCandidates = <String>{};
    final tracker = _runTracker;
    if (tracker is AgentTaskLedgerPort) {
      final ledger = tracker as AgentTaskLedgerPort;
      for (final entry in ledger.taskLedger) {
        final matchingIds = entry.resultTaskIds
            .where(candidates.contains)
            .toSet();
        if (matchingIds.isEmpty) continue;
        if (entry.kind == 'recording_outline') {
          recordingOutlineCandidates.addAll(matchingIds);
        }
        if (entry.localNoteId != itemId ||
            entry.targetPart != targetPart ||
            entry.status != 'succeeded' ||
            entry.outputPartRevisionId != outputRevision ||
            entry.remoteNoteId != remoteNoteId) {
          continue;
        }
        if (entry.kind == 'recording_outline' &&
            stage == V3ContentStage.summary &&
            entry.recordingId == _item.recordingId) {
          verified.addAll(matchingIds);
        } else if (entry.kind == 'derived_part') {
          verified.addAll(matchingIds);
        }
      }
    }
    if (tracker is! DerivedPartResultVerificationPort) {
      return Set<String>.unmodifiable(verified);
    }
    final verifier = tracker as DerivedPartResultVerificationPort;
    for (final taskId
        in candidates
            .difference(verified)
            .difference(recordingOutlineCandidates)) {
      final revision = await verifier.verifySucceededDerivedOutputRevision(
        fileAgentRunId: taskId,
        remoteNoteId: remoteNoteId,
        targetPart: targetPart,
      );
      if (_disposed ||
          _item.remoteNoteId?.trim() != remoteNoteId ||
          resultPartRevision(stage) != outputRevision) {
        return const <String>{};
      }
      if (revision == outputRevision) verified.add(taskId);
    }
    return Set<String>.unmodifiable(verified);
  }

  List<AgentRunToolTrace> get outlineToolTrace => usesBackendRecordingOutline
      ? const <AgentRunToolTrace>[]
      : _toolTraceFor(NoteFileAgentPart.outline);
  List<AgentRunToolTrace> get sproutToolTrace =>
      _toolTraceFor(NoteFileAgentPart.germination);

  void selectStage(V3ContentStage value) {
    if (_stage == value) return;
    _stage = value;
    notifyListeners();
  }

  void toggleDraftMaterial(V3LinkedMaterialRef material) {
    if (!_draftLinkedIds.add(material.id)) _draftLinkedIds.remove(material.id);
    notifyListeners();
  }

  void prepareLinkedMaterials(Iterable<V3LinkedMaterialRef> materials) {
    _draftLinkedIds
      ..clear()
      ..addAll(materials.map((material) => material.id));
    _linkedMaterialScope = V3LinkedMaterialScope.mine;
    _linkedMaterialQuery = '';
    notifyListeners();
  }

  void setLinkedMaterialScope(V3LinkedMaterialScope value) {
    if (_linkedMaterialScope == value) return;
    _linkedMaterialScope = value;
    notifyListeners();
  }

  void setLinkedMaterialQuery(String value) {
    if (_linkedMaterialQuery == value) return;
    _linkedMaterialQuery = value;
    notifyListeners();
  }

  void applyLinkedMaterials(Iterable<V3LinkedMaterialRef> available) {
    if (!_hasAuthoritativeItem) return;
    final next = available
        .where((material) => _draftLinkedIds.contains(material.id))
        .toList(growable: false);
    _item = _item.copyWith(linkedMaterials: next, updatedAt: DateTime.now());
    _draftLinkedIds.clear();
    _library.updateNote(_item);
    notifyListeners();
  }

  Future<bool> startSprout() =>
      _hasAuthoritativeItem ? _startSprout() : Future<bool>.value(false);

  /// Reconciles a late remote write after the detail page is reopened/resumed.
  Future<bool> refreshDerivedParts() async {
    if (_disposed) return false;
    final refreshed = await _library.refreshRemoteDerivedParts(itemId);
    if (_disposed) return false;
    if (!refreshed) {
      _ensureRecordingOutlinePolling();
      return false;
    }
    final current = _library.noteForId(itemId);
    if (current == null) return false;
    _hasAuthoritativeItem = true;
    _item = current;
    _trackServerDerivedTasks(current);
    unawaited(_trackRecordingOutline(current));
    final hasOutline = current.summaryBody?.trim().isNotEmpty == true;
    if (current.usesBackendRecordingOutline) {
      final restored = _restoreRecordingOutlineFromTracker();
      if (!restored.handled) {
        _outlineStatus = _hasLocallyVerifiedRecordingOutline(current)
            ? V3OutlineTaskStatus.succeeded
            : _outlineStatusFor(current);
        _outlineErrorCode = _outlineStatus == V3OutlineTaskStatus.failed
            ? _outlineErrorCode ?? 'RECORDING_OUTLINE_FAILED'
            : null;
      }
    } else if (_outlineStatus != V3OutlineTaskStatus.failed || hasOutline) {
      if (!_isPartPending(NoteFileAgentPart.outline)) {
        _outlineStatus = _outlineStatusFor(current);
        _outlineErrorCode = null;
      }
    }
    final hasSprout = current.sproutReport?.markdown.trim().isNotEmpty == true;
    if (_sproutStatus != V3SproutTaskStatus.failed || hasSprout) {
      if (!_isPartPending(NoteFileAgentPart.germination)) {
        _sproutStatus = _isTransientSproutStatus(current.sproutStatus)
            ? V3SproutTaskStatus.notStarted
            : current.sproutStatus;
        _sproutErrorCode = null;
      }
    }
    notifyListeners();
    _ensureRecordingOutlinePolling();
    return true;
  }

  Future<bool> startOutline() {
    if (!_hasAuthoritativeItem) return Future<bool>.value(false);
    if (usesBackendRecordingOutline) {
      _stage = V3ContentStage.summary;
      _ensureRecordingOutlinePolling();
      notifyListeners();
      return Future<bool>.value(false);
    }
    return _startOutline();
  }

  Future<bool> retryOutline() => !_hasAuthoritativeItem
      ? Future<bool>.value(false)
      : usesBackendRecordingOutline
      ? _retryRecordingOutline()
      : _startOutline();

  Future<bool> _startOutline() async {
    if (_outlineStatus == V3OutlineTaskStatus.running) return false;
    _outlineStatus = V3OutlineTaskStatus.running;
    _outlineErrorCode = null;
    _stage = V3ContentStage.summary;
    notifyListeners();
    try {
      final prepared = await _prepareDerivedPartSource(
        readOnlyCode: 'OUTLINE_SYNC_NOT_ALLOWED',
        missingBindingCode: 'OUTLINE_HNOTE_EXACT_REVISION_REQUIRED',
        conflictCode: 'OUTLINE_SYNC_CONFLICT',
        unavailableCode: 'OUTLINE_SYNC_UNAVAILABLE',
        failedCode: 'OUTLINE_SYNC_FAILED',
        supersededCode: 'OUTLINE_SYNC_SUPERSEDED',
      );
      final retainedAdmission = _pendingAcceptedOutlineAdmissionFor(prepared);
      final operationId =
          retainedAdmission?.operationId ?? _outlineOperationIdFor(prepared);
      final admissionRepository =
          _outlineRepository is AcceptedOutlineRunRepository
          ? _outlineRepository as AcceptedOutlineRunRepository
          : null;
      final accepted =
          retainedAdmission?.accepted ??
          (admissionRepository != null
              ? await admissionRepository.submit(
                  prepared,
                  operationId: operationId,
                )
              : null);
      if (accepted != null) {
        if (retainedAdmission == null &&
            !_acceptedOutlineRunMatches(prepared, accepted)) {
          throw const _DerivedPartPreparationException(
            'DERIVED_TASK_TRACKER_UNAVAILABLE',
          );
        }
        if (retainedAdmission == null) {
          _rememberAcceptedOutlineAdmission(
            prepared,
            accepted,
            operationId: operationId,
          );
        }
        await _trackDerivedPart(prepared, accepted, operationId: operationId);
        if (admissionRepository is OutlineAdmissionTrackingPort) {
          (admissionRepository as OutlineAdmissionTrackingPort)
              .markOutlineAdmissionTracked(accepted);
        }
        _clearAcceptedOutlineAdmission(operationId);
        if (_disposed) return true;
        if (accepted.isTerminal && !accepted.isSuccessful) {
          _failOutline(
            accepted.failureCode ??
                'NOTE_FILE_AGENT_${accepted.status.toUpperCase()}',
          );
          return false;
        }
        _outlineStatus = V3OutlineTaskStatus.running;
        notifyListeners();
        return true;
      }
      final markdown = await _outlineRepository.generate(
        prepared,
        operationId: operationId,
      );
      _item = prepared.copyWith(
        summaryBody: markdown,
        clearOutlinePartRevisionId: true,
        clearSummaryError: true,
        updatedAt: DateTime.now(),
      );
      _outlineStatus = V3OutlineTaskStatus.succeeded;
      _library.updateNote(_item);
      notifyListeners();
      return true;
    } on _DerivedPartPreparationException catch (error) {
      _failOutline(error.code);
      return false;
    } on OutlineGenerationException catch (error) {
      _failOutline(error.code);
      return false;
    } catch (_) {
      _failOutline('OUTLINE_GENERATION_FAILED');
      return false;
    }
  }

  void _failOutline(String code) {
    _outlineStatus = V3OutlineTaskStatus.failed;
    _outlineErrorCode = code;
    if (!_disposed) notifyListeners();
  }

  RecordingRetryAction? get _authorizedRecordingRetryAction {
    final preferredStages = <String>[
      if (_recordingStageFailed(_item.minutesStatus)) 'minutes_generation',
      if (_recordingStageFailed(_item.summaryStatus)) 'summary_generation',
      'recording_note_outline',
    ];
    for (final preferredStage in preferredStages) {
      for (final action in _recordingOutlineRetryActions) {
        if (action.allowed && action.stage == preferredStage) return action;
      }
    }
    return null;
  }

  void _ensureRecordingOutlinePolling() {
    if (_disposed ||
        !usesBackendRecordingOutline ||
        (_outlineStatus == V3OutlineTaskStatus.succeeded &&
            _hasLocallyVerifiedRecordingOutline(_item)) ||
        _recordingApi == null ||
        _item.recordingId?.trim().isNotEmpty != true ||
        _recordingOutlinePoll != null ||
        _recordingOutlinePoller != null) {
      return;
    }
    final generation = ++_recordingPollGeneration;
    if (_taskOrchestrator != null && _activityMetrics != null) {
      _recordingPollingDesired = true;
      _recordingPollAttempts = 0;
      _installRecordingOutlinePoller(generation: generation);
      return;
    }
    final poll = _pollRecordingOutline(generation);
    _recordingOutlinePoll = poll;
    unawaited(
      poll.whenComplete(() {
        if (generation == _recordingPollGeneration) {
          _recordingOutlinePoll = null;
        }
      }),
    );
  }

  void _installRecordingOutlinePoller({int? generation}) {
    final orchestrator = _taskOrchestrator;
    final activityMetrics = _activityMetrics;
    final recordingId = _item.recordingId?.trim();
    if (_disposed ||
        !_recordingPollingDesired ||
        orchestrator == null ||
        activityMetrics == null ||
        recordingId == null ||
        recordingId.isEmpty ||
        _recordingOutlinePoller != null) {
      return;
    }
    final pollGeneration = generation ?? _recordingPollGeneration;
    final stableId = _stableFeedRecordingPollId('$itemId:$recordingId');
    // performance-rfc: feed-recording-outline-poll
    _recordingOutlinePoller = OrchestratedPoller(
      orchestrator: orchestrator,
      spec: TaskSpec(
        key: 'feed:recording-outline:$stableId',
        owner: 'feed-recording-outline',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        deadline: const Duration(seconds: 30),
        retryable: true,
        replaceExisting: true,
      ),
      interval: _recordingPollInterval,
      maxBackoff: _recordingPollInterval > const Duration(seconds: 30)
          ? _recordingPollInterval
          : const Duration(seconds: 30),
      activityMetrics: activityMetrics,
      metricsOwner: 'feed.recording-outline.$stableId',
      poll: (token) => _pollRecordingOutlineOnce(
        recordingId,
        generation: pollGeneration,
        token: token,
      ),
    );
    if (_recordingPollingRouteActive) _recordingOutlinePoller!.start();
  }

  Future<bool> _pollRecordingOutlineOnce(
    String recordingId, {
    required int generation,
    required AppTaskCancellationToken token,
  }) async {
    token.throwIfCancelled();
    if (_disposed || generation != _recordingPollGeneration) return false;
    if (_recordingPollAttempts >= recordingMaxPollAttempts) {
      _finishRecordingOutlineObservation();
      return false;
    }
    _recordingPollAttempts += 1;
    final result = await _recordingApi!.getRecordingDetail(recordingId);
    token.throwIfCancelled();
    if (_disposed || generation != _recordingPollGeneration) return false;
    final detail = result.data;
    if (!result.ok ||
        detail == null ||
        detail.recording.recordingId != recordingId) {
      if (_recordingPollAttempts >= recordingMaxPollAttempts) {
        _finishRecordingOutlineObservation();
        return false;
      }
      throw StateError(
        result.error?.code ?? 'RECORDING_OUTLINE_DETAIL_READ_FAILED',
      );
    }
    if (!_acceptRecordingOutlineDetail(detail)) return true;
    _recordingOutlineRetryActions = List<RecordingRetryAction>.unmodifiable(
      detail.effectiveRetryActions,
    );
    _updateRecordingLifecycle(detail);
    await _library.refreshRemoteDerivedParts(itemId);
    token.throwIfCancelled();
    if (_disposed || generation != _recordingPollGeneration) return false;
    final current = _library.noteForId(itemId);
    if (current != null) {
      _item = current;
      _trackServerDerivedTasks(current);
    }
    if (_hasExactRecordingOutlineResult(detail, _item)) {
      _verifiedRecordingOutlineTaskId = detail.noteOutlineTask!.taskId;
      _verifiedRecordingOutlineRevision = detail.noteRef!.outlinePartRevisionId!
          .trim();
      _outlineStatus = V3OutlineTaskStatus.succeeded;
      _outlineErrorCode = null;
      _recordingPollingDesired = false;
      notifyListeners();
      return false;
    }
    if (detail.hasOutlineFailure || _authorizedRecordingRetryAction != null) {
      _outlineStatus = V3OutlineTaskStatus.failed;
      _outlineErrorCode =
          detail.outlineFailureCode ?? 'RECORDING_OUTLINE_FAILED';
      _recordingPollingDesired = false;
      notifyListeners();
      return false;
    }
    _outlineStatus = V3OutlineTaskStatus.running;
    _outlineErrorCode = null;
    notifyListeners();
    if (_recordingPollAttempts >= recordingMaxPollAttempts) {
      _finishRecordingOutlineObservation();
      return false;
    }
    return true;
  }

  Future<void> _pollRecordingOutline(int generation) async {
    final recordingId = _item.recordingId!.trim();
    var attempts = 0;
    while (!_disposed &&
        generation == _recordingPollGeneration &&
        attempts < recordingMaxPollAttempts) {
      attempts += 1;
      ApiResult<RecordingDetail> result;
      try {
        result = await _recordingApi!.getRecordingDetail(recordingId);
      } on Object {
        await _recordingPollDelay(_recordingPollInterval);
        continue;
      }
      if (_disposed || generation != _recordingPollGeneration) return;
      final detail = result.data;
      if (!result.ok ||
          detail == null ||
          detail.recording.recordingId != recordingId) {
        await _recordingPollDelay(_recordingPollInterval);
        continue;
      }
      if (!_acceptRecordingOutlineDetail(detail)) {
        await _recordingPollDelay(_recordingPollInterval);
        continue;
      }

      _recordingOutlineRetryActions = List<RecordingRetryAction>.unmodifiable(
        detail.effectiveRetryActions,
      );
      _updateRecordingLifecycle(detail);
      await _library.refreshRemoteDerivedParts(itemId);
      if (_disposed || generation != _recordingPollGeneration) return;
      final current = _library.noteForId(itemId);
      if (current != null) {
        _item = current;
        _trackServerDerivedTasks(current);
      }
      if (_hasExactRecordingOutlineResult(detail, _item)) {
        _verifiedRecordingOutlineTaskId = detail.noteOutlineTask!.taskId;
        _verifiedRecordingOutlineRevision = detail
            .noteRef!
            .outlinePartRevisionId!
            .trim();
        _outlineStatus = V3OutlineTaskStatus.succeeded;
        _outlineErrorCode = null;
        notifyListeners();
        return;
      }
      if (detail.hasOutlineFailure || _authorizedRecordingRetryAction != null) {
        _outlineStatus = V3OutlineTaskStatus.failed;
        _outlineErrorCode =
            detail.outlineFailureCode ?? 'RECORDING_OUTLINE_FAILED';
        notifyListeners();
        return;
      }
      _outlineStatus = V3OutlineTaskStatus.running;
      _outlineErrorCode = null;
      notifyListeners();
      await _recordingPollDelay(_recordingPollInterval);
    }
    if (!_disposed && generation == _recordingPollGeneration) {
      _finishRecordingOutlineObservation();
    }
  }

  void _updateRecordingLifecycle(RecordingDetail detail) {
    final current = _library.noteForId(itemId) ?? _item;
    final recording = detail.recording;
    if (current.recordingId == recording.recordingId &&
        current.minutesStatus == recording.minutesStatus &&
        current.summaryStatus == recording.summaryStatus) {
      return;
    }
    _item = current.copyWith(
      recordingId: recording.recordingId,
      minutesStatus: recording.minutesStatus,
      summaryStatus: recording.summaryStatus,
    );
    _library.updateNote(_item);
  }

  bool _acceptRecordingOutlineDetail(RecordingDetail detail) {
    final taskId = detail.noteOutlineTask?.taskId.trim();
    final publicTaskId = taskId == null || taskId.isEmpty ? null : taskId;
    final tracker = _runTracker;
    if (tracker case final RecordingOutlineRunTrackingPort outlineTracker) {
      if (!outlineTracker.acceptsRecordingOutlineTask(itemId, publicTaskId)) {
        return false;
      }
    }
    final expectedTaskId = _expectedRecordingOutlineTaskId;
    if (expectedTaskId != null && publicTaskId != expectedTaskId) return false;
    final supersededTaskId = _supersededRecordingOutlineTaskId;
    if (supersededTaskId != null &&
        (publicTaskId == null || publicTaskId == supersededTaskId)) {
      return false;
    }
    if (publicTaskId != null) {
      _recordingOutlineTaskId = publicTaskId;
      if (_expectedRecordingOutlineTaskId == publicTaskId) {
        _expectedRecordingOutlineTaskId = null;
      }
    }
    return true;
  }

  Future<bool> _retryRecordingOutline() async {
    if (_outlineStatus == V3OutlineTaskStatus.running) return false;
    final api = _recordingApi;
    final recordingId = _item.recordingId?.trim();
    final action = _authorizedRecordingRetryAction;
    if (api == null ||
        recordingId == null ||
        recordingId.isEmpty ||
        action == null) {
      return false;
    }
    final supersededTaskId = _recordingOutlineTaskId;
    _outlineStatus = V3OutlineTaskStatus.running;
    _outlineErrorCode = null;
    _verifiedRecordingOutlineTaskId = null;
    _verifiedRecordingOutlineRevision = null;
    _stage = V3ContentStage.summary;
    notifyListeners();
    ApiResult<RetryRecordingResponse> result;
    try {
      result = await api.retryRecording(
        recordingId: recordingId,
        stage: action.stage,
        idempotencyKey: _nextRecordingRetryIdempotencyKey(recordingId),
      );
    } on Object {
      const code = 'RECORDING_OUTLINE_RETRY_FAILED';
      await _rejectRecordingOutlineRetry(recordingId, code);
      if (!_disposed) {
        _outlineStatus = V3OutlineTaskStatus.failed;
        _outlineErrorCode = code;
        notifyListeners();
      }
      return false;
    }
    if (!result.ok) {
      final code = result.error?.code ?? 'RECORDING_OUTLINE_RETRY_FAILED';
      await _rejectRecordingOutlineRetry(recordingId, code);
      if (!_disposed) {
        _outlineStatus = V3OutlineTaskStatus.failed;
        _outlineErrorCode = code;
        notifyListeners();
      }
      return false;
    }
    final accepted = result.data;
    final taskId = accepted?.taskId?.trim();
    if (accepted == null ||
        accepted.recordingId != recordingId ||
        accepted.stage != action.stage ||
        !accepted.status.isAccepted ||
        taskId == null ||
        taskId.isEmpty ||
        (action.stage == 'recording_note_outline' &&
            taskId == supersededTaskId)) {
      const code = 'RECORDING_OUTLINE_RETRY_RESPONSE_INVALID';
      await _rejectRecordingOutlineRetry(recordingId, code);
      if (!_disposed) {
        _outlineStatus = V3OutlineTaskStatus.failed;
        _outlineErrorCode = code;
        notifyListeners();
      }
      return false;
    }
    final directOutlineRetry = action.stage == 'recording_note_outline';
    final successorBarrierTaskId =
        supersededTaskId ?? (directOutlineRetry ? null : taskId);
    _expectedRecordingOutlineTaskId = directOutlineRetry ? taskId : null;
    _supersededRecordingOutlineTaskId = successorBarrierTaskId;
    await _trackRecordingOutline(
      _item,
      restart: true,
      expectedPublicTaskId: _expectedRecordingOutlineTaskId,
      supersededPublicTaskId: _expectedRecordingOutlineTaskId == null
          ? _supersededRecordingOutlineTaskId
          : null,
    );
    await _acceptRecordingOutlineRetry(
      recordingId,
      retryTaskId: taskId,
      retryStage: action.stage,
      supersededOutlineTaskId: successorBarrierTaskId,
    );
    await _reenrollRecordingProcessingAfterRetry(recordingId);
    if (_disposed) return true;
    _recordingOutlineRetryActions = const <RecordingRetryAction>[];
    _recordingPollGeneration += 1;
    _recordingOutlinePoll = null;
    _recordingOutlinePoller?.dispose();
    _recordingOutlinePoller = null;
    _recordingPollingDesired = false;
    if (_taskOrchestrator == null || _activityMetrics == null) {
      await _recordingPollDelay(_recordingPollInterval);
    }
    if (_disposed) return true;
    _ensureRecordingOutlinePolling();
    return true;
  }

  void _finishRecordingOutlineObservation() {
    _recordingPollingDesired = false;
    if (_outlineStatus == V3OutlineTaskStatus.succeeded &&
        _hasPersistedRecordingOutline(_item)) {
      return;
    }
    if (_outlineStatus == V3OutlineTaskStatus.running &&
        _outlineErrorCode == null) {
      return;
    }
    _outlineStatus = V3OutlineTaskStatus.running;
    _outlineErrorCode = null;
    notifyListeners();
  }

  Future<void> _reenrollRecordingProcessingAfterRetry(
    String recordingId,
  ) async {
    final processingRetryPort = _recordingProcessingRetryPort;
    if (processingRetryPort == null) return;
    try {
      await processingRetryPort.reenrollAfterRetry(recordingId);
    } on Object {
      // The backend retry remains valid even when a local task checkpoint is
      // unavailable. The detail's existing GET loop will still observe it.
    }
  }

  Future<void> _acceptRecordingOutlineRetry(
    String recordingId, {
    required String retryTaskId,
    required String retryStage,
    String? supersededOutlineTaskId,
  }) async {
    try {
      await _recordingOutlineRetryLifecyclePort?.acceptOutlineRetry(
        recordingId: recordingId,
        retryTaskId: retryTaskId,
        retryStage: retryStage,
        supersededOutlineTaskId: supersededOutlineTaskId,
      );
    } on Object {
      // The existing processing tracker and detail poll can reconcile this later.
    }
  }

  Future<void> _rejectRecordingOutlineRetry(
    String recordingId,
    String errorCode,
  ) async {
    try {
      await _recordingOutlineRetryLifecyclePort?.rejectOutlineRetry(
        recordingId: recordingId,
        errorCode: errorCode,
      );
    } on Object {
      // Keep the detail failure visible even if batch persistence is unavailable.
    }
  }

  String _nextRecordingRetryIdempotencyKey(String recordingId) {
    final custom = _idempotencyKeyFactory?.call();
    if (custom != null && custom.trim().isNotEmpty) return custom.trim();
    return 'idem-recording-outline-retry-$recordingId-'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}';
  }

  Future<bool> _startSprout() async {
    if (_sproutStatus == V3SproutTaskStatus.running) return false;
    final operationId = _nextSproutOperationId();
    _library.beginSproutSubmission(noteId: itemId, operationId: operationId);
    _sproutErrorCode = null;
    _sproutStatus = V3SproutTaskStatus.running;
    _stage = V3ContentStage.sprout;
    if (!_disposed) notifyListeners();
    try {
      final prepared = await _prepareDerivedPartSource(
        readOnlyCode: 'AGENT_HNOTE_EXACT_REVISION_REQUIRED',
        missingBindingCode: 'AGENT_HNOTE_EXACT_REVISION_REQUIRED',
        conflictCode: 'FAYA_SOURCE_REVISION_CHANGED',
        unavailableCode: 'AGENT_SYNC_UNAVAILABLE',
        failedCode: 'AGENT_SYNC_FAILED',
        supersededCode: 'AGENT_SYNC_SUPERSEDED',
      );
      final accepted = _sproutRepository is AcceptedSproutRunRepository
          ? await (_sproutRepository as AcceptedSproutRunRepository).submit(
              prepared,
              operationId: operationId,
            )
          : null;
      if (accepted != null) {
        await _trackDerivedPart(prepared, accepted, operationId: operationId);
        _library.finishSproutSubmission(
          noteId: itemId,
          operationId: operationId,
        );
        if (accepted.isTerminal && !accepted.isSuccessful) {
          _failSprout(
            accepted.failureCode ??
                'NOTE_FILE_AGENT_${accepted.status.toUpperCase()}',
            operationId: operationId,
          );
          return false;
        }
        _sproutStatus = V3SproutTaskStatus.running;
        if (!_disposed) notifyListeners();
        return true;
      }
      final report = await _sproutRepository.generate(
        prepared,
        operationId: operationId,
      );
      _item = prepared.copyWith(
        sproutStatus: V3SproutTaskStatus.succeeded,
        sproutReport: report,
        sproutTopic: report.title,
        clearGerminationPartRevisionId: true,
        clearSproutError: true,
        updatedAt: report.generatedAt,
      );
      _sproutStatus = V3SproutTaskStatus.succeeded;
      _library.updateNote(_item);
      _library.finishSproutSubmission(noteId: itemId, operationId: operationId);
      _profileHub.recordActivity(
        V3ProfileActivity(
          id: report.id,
          occurredAt: report.generatedAt,
          type: V3ProfileActivityType.sprout,
          title: report.title,
          feedItemId: _item.id,
          route: '/v3/feed/items/${Uri.encodeComponent(_item.id)}?stage=sprout',
        ),
      );
      if (!_disposed) notifyListeners();
      return true;
    } on _DerivedPartPreparationException catch (error) {
      _failSprout(error.code, operationId: operationId);
      return false;
    } on SproutGenerationException catch (error) {
      _sproutErrorCode = error.code;
      _failSprout(error.code, operationId: operationId);
      return false;
    } catch (_) {
      _failSprout('SPROUT_GENERATION_FAILED', operationId: operationId);
      return false;
    }
  }

  void _failSprout(String code, {String? operationId}) {
    if (operationId != null) {
      _library.failSproutSubmission(
        noteId: itemId,
        operationId: operationId,
        errorCode: code,
      );
    }
    _sproutErrorCode = code;
    _sproutStatus = V3SproutTaskStatus.failed;
    if (!_disposed) notifyListeners();
  }

  Future<bool> retrySprout() =>
      _hasAuthoritativeItem ? _startSprout() : Future<bool>.value(false);

  Future<void> _trackDerivedPart(
    V3FeedItem note,
    NoteFileAgentRunSnapshot accepted, {
    required String operationId,
  }) async {
    final tracker = _runTracker;
    final remoteNoteId = note.remoteNoteId?.trim();
    if (tracker == null || remoteNoteId == null || remoteNoteId.isEmpty) {
      throw const _DerivedPartPreparationException(
        'DERIVED_TASK_TRACKER_UNAVAILABLE',
      );
    }
    try {
      if (tracker is AgentTaskSubjectMetadataPort) {
        await (tracker as AgentTaskSubjectMetadataPort)
            .rememberKnowledgeAssetSubject(
              localNoteId: note.id,
              subjectTitle: note.title,
            );
      }
      await tracker.trackDerivedPart(
        fileAgentRunId: accepted.fileAgentRunId,
        agentRunId: accepted.agentRunId,
        status: accepted.status,
        localNoteId: note.id,
        remoteNoteId: remoteNoteId,
        targetPart: accepted.targetPart,
        inputPartRevisionId: accepted.inputPartRevisionId,
        targetPartRevisionId: accepted.targetPartRevisionId,
        operationId: operationId,
      );
    } on Object {
      throw const _DerivedPartPreparationException(
        'DERIVED_TASK_TRACKER_UNAVAILABLE',
      );
    }
    final ledger = tracker is AgentTaskLedgerPort
        ? tracker as AgentTaskLedgerPort
        : null;
    if (ledger != null &&
        !ledger.taskLedger.any(
          (task) =>
              task.taskId == accepted.fileAgentRunId &&
              task.kind == 'derived_part' &&
              task.localNoteId == note.id &&
              task.remoteNoteId == accepted.noteId &&
              task.targetPart == accepted.targetPart &&
              task.inputPartRevisionId == accepted.inputPartRevisionId &&
              task.targetPartRevisionId == accepted.targetPartRevisionId &&
              task.operationId == operationId &&
              task.agentRunId == accepted.agentRunId,
        )) {
      throw const _DerivedPartPreparationException(
        'DERIVED_TASK_TRACKER_UNAVAILABLE',
      );
    }
  }

  bool _isPartPending(NoteFileAgentPart part) =>
      _runTracker?.isDerivedPartPending(itemId, part) ?? false;

  List<AgentRunToolTrace> _toolTraceFor(NoteFileAgentPart part) =>
      _runTracker?.derivedPartToolTrace(itemId, part) ??
      const <AgentRunToolTrace>[];

  void refreshFromTaskTracker() {
    if (_disposed) return;
    final outlinePending =
        !usesBackendRecordingOutline &&
        _isPartPending(NoteFileAgentPart.outline);
    final sproutPending = _isPartPending(NoteFileAgentPart.germination);
    var changed = false;
    if (usesBackendRecordingOutline) {
      changed = _restoreRecordingOutlineFromTracker().changed || changed;
    }
    if (outlinePending && _outlineStatus != V3OutlineTaskStatus.running) {
      _outlineStatus = V3OutlineTaskStatus.running;
      _outlineErrorCode = null;
      changed = true;
    }
    if (sproutPending && _sproutStatus != V3SproutTaskStatus.running) {
      _sproutStatus = V3SproutTaskStatus.running;
      _sproutErrorCode = null;
      changed = true;
    }
    changed =
        _restoreLatestDerivedSuccess(
          outlinePending: outlinePending,
          sproutPending: sproutPending,
        ) ||
        changed;
    changed =
        _restoreLatestDerivedFailure(
          outlinePending: outlinePending,
          sproutPending: sproutPending,
        ) ||
        changed;
    if (changed) notifyListeners();
  }

  bool _restoreLatestDerivedSuccess({
    required bool outlinePending,
    required bool sproutPending,
  }) {
    var changed = false;
    final outlineTerminal = outlinePending || usesBackendRecordingOutline
        ? null
        : _latestDerivedTerminal(NoteFileAgentPart.outline);
    final outlineRevision = outlineTerminal?.outputPartRevisionId?.trim();
    if (outlineTerminal?.status == 'succeeded' &&
        outlineRevision != null &&
        outlineRevision.isNotEmpty &&
        _item.outlinePartRevisionId?.trim() == outlineRevision &&
        _item.summaryBody?.trim().isNotEmpty == true &&
        (_outlineStatus != V3OutlineTaskStatus.succeeded ||
            _outlineErrorCode != null)) {
      _outlineStatus = V3OutlineTaskStatus.succeeded;
      _outlineErrorCode = null;
      changed = true;
    }

    final sproutTerminal = sproutPending
        ? null
        : _latestDerivedTerminal(NoteFileAgentPart.germination);
    final germinationRevision = sproutTerminal?.outputPartRevisionId?.trim();
    if (sproutTerminal?.status == 'succeeded' &&
        germinationRevision != null &&
        germinationRevision.isNotEmpty &&
        _item.germinationPartRevisionId?.trim() == germinationRevision &&
        _item.sproutReport?.markdown.trim().isNotEmpty == true &&
        (_sproutStatus != V3SproutTaskStatus.succeeded ||
            _sproutErrorCode != null)) {
      _sproutStatus = V3SproutTaskStatus.succeeded;
      _sproutErrorCode = null;
      changed = true;
    }
    return changed;
  }

  bool _restoreLatestDerivedFailure({
    required bool outlinePending,
    required bool sproutPending,
  }) {
    var changed = false;
    final outlineTerminal = outlinePending
        ? null
        : _latestDerivedTerminal(NoteFileAgentPart.outline);
    if (outlineTerminal != null &&
        outlineTerminal.status != 'succeeded' &&
        !usesBackendRecordingOutline &&
        _outlineStatus != V3OutlineTaskStatus.succeeded) {
      final errorCode =
          outlineTerminal.failureCode ??
          'NOTE_FILE_AGENT_${outlineTerminal.status.toUpperCase()}';
      if (_outlineStatus != V3OutlineTaskStatus.failed ||
          _outlineErrorCode != errorCode) {
        _outlineStatus = V3OutlineTaskStatus.failed;
        _outlineErrorCode = errorCode;
        changed = true;
      }
    }
    final sproutTerminal =
        sproutPending || _library.sproutSubmissionFor(itemId) != null
        ? null
        : _latestDerivedTerminal(NoteFileAgentPart.germination);
    if (sproutTerminal != null &&
        sproutTerminal.status != 'succeeded' &&
        _sproutStatus != V3SproutTaskStatus.succeeded &&
        _item.sproutReport == null) {
      final errorCode =
          sproutTerminal.failureCode ??
          'NOTE_FILE_AGENT_${sproutTerminal.status.toUpperCase()}';
      if (_sproutStatus == V3SproutTaskStatus.failed &&
          _sproutErrorCode == errorCode) {
        return changed;
      }
      _sproutStatus = V3SproutTaskStatus.failed;
      _sproutErrorCode = errorCode;
      changed = true;
    }
    return changed;
  }

  ({
    String status,
    String? failureCode,
    String? outputPartRevisionId,
    String? operationId,
  })?
  _latestDerivedTerminal(NoteFileAgentPart targetPart) {
    final tracker = _runTracker;
    if (tracker == null) return null;
    if (tracker is AgentTaskLedgerPort) {
      final ledger = tracker as AgentTaskLedgerPort;
      AgentTaskLedgerEntry? latest;
      for (final entry in ledger.taskLedger) {
        if (entry.kind != 'derived_part' ||
            entry.localNoteId != itemId ||
            entry.targetPart != targetPart ||
            !entry.isTerminal) {
          continue;
        }
        if (!_isCurrentAutomaticOutlineTerminal(
          targetPart: targetPart,
          status: entry.status,
          operationId: entry.operationId,
          remoteNoteId: entry.remoteNoteId,
          inputRevisionId: entry.inputPartRevisionId,
          targetRevisionId: entry.targetPartRevisionId,
        )) {
          continue;
        }
        if (latest == null || entry.createdAt.isAfter(latest.createdAt)) {
          latest = entry;
        }
      }
      if (latest != null) {
        return (
          status: latest.status,
          failureCode: latest.failureCode,
          outputPartRevisionId: latest.outputPartRevisionId,
          operationId: latest.operationId,
        );
      }
      if (targetPart == NoteFileAgentPart.outline) return null;
    }
    final completion = tracker.lastDerivedCompletion;
    if (completion == null ||
        completion.localNoteId != itemId ||
        completion.targetPart != targetPart) {
      return null;
    }
    if (!_isCurrentAutomaticOutlineTerminal(
      targetPart: targetPart,
      status: completion.status,
      operationId: completion.operationId,
      remoteNoteId: completion.remoteNoteId,
      inputRevisionId: completion.inputPartRevisionId,
      targetRevisionId: completion.targetPartRevisionId,
    )) {
      return null;
    }
    return (
      status: completion.status,
      failureCode: completion.failureCode,
      outputPartRevisionId: completion.outputPartRevisionId,
      operationId: completion.operationId,
    );
  }

  bool _isCurrentAutomaticOutlineTerminal({
    required NoteFileAgentPart targetPart,
    required String status,
    required String? operationId,
    required String? remoteNoteId,
    required String? inputRevisionId,
    required String? targetRevisionId,
  }) {
    if (targetPart != NoteFileAgentPart.outline ||
        status == 'succeeded' ||
        !isAutomaticOutlineOperationId(operationId)) {
      return true;
    }
    return remoteNoteId?.trim() == _item.remoteNoteId?.trim() &&
        inputRevisionId?.trim() == _item.rawPartRevisionId?.trim() &&
        targetRevisionId?.trim() == _item.outlinePartRevisionId?.trim();
  }

  Future<void> _trackRecordingOutline(
    V3FeedItem item, {
    bool restart = false,
    String? expectedPublicTaskId,
    String? supersededPublicTaskId,
  }) async {
    final tracker = _runTracker;
    final recordingId = item.recordingId?.trim();
    final remoteNoteId = item.remoteNoteId?.trim();
    if (tracker is! RecordingOutlineRunTrackingPort ||
        !item.usesBackendRecordingOutline ||
        recordingId == null ||
        recordingId.isEmpty ||
        remoteNoteId == null ||
        remoteNoteId.isEmpty) {
      return;
    }
    if (tracker is AgentTaskSubjectMetadataPort) {
      await (tracker as AgentTaskSubjectMetadataPort)
          .rememberKnowledgeAssetSubject(
            localNoteId: item.id,
            subjectTitle: item.title,
          );
    }
    await (tracker as RecordingOutlineRunTrackingPort).trackRecordingOutline(
      recordingId: recordingId,
      localNoteId: item.id,
      remoteNoteId: remoteNoteId,
      restart: restart,
      expectedPublicTaskId: expectedPublicTaskId,
      supersededPublicTaskId: supersededPublicTaskId,
    );
  }

  ({bool handled, bool changed}) _restoreRecordingOutlineFromTracker() {
    if (!usesBackendRecordingOutline) return (handled: false, changed: false);
    final tracker = _runTracker;
    var changed = false;
    if (tracker is RecordingOutlineRunTrackingPort &&
        (tracker as RecordingOutlineRunTrackingPort).isRecordingOutlinePending(
          itemId,
        )) {
      if (_outlineStatus != V3OutlineTaskStatus.running ||
          _outlineErrorCode != null) {
        _outlineStatus = V3OutlineTaskStatus.running;
        _outlineErrorCode = null;
        changed = true;
      }
      return (handled: true, changed: changed);
    }
    if (tracker is! AgentTaskLedgerPort) {
      return (handled: false, changed: changed);
    }
    AgentTaskLedgerEntry? latest;
    for (final entry in (tracker as AgentTaskLedgerPort).taskLedger) {
      if (entry.kind != 'recording_outline' ||
          entry.localNoteId != itemId ||
          entry.recordingId != _item.recordingId ||
          entry.targetPart != NoteFileAgentPart.outline ||
          !entry.isTerminal) {
        continue;
      }
      if (latest == null || entry.createdAt.isAfter(latest.createdAt)) {
        latest = entry;
      }
    }
    if (latest == null) return (handled: false, changed: changed);
    final latestPublicTaskId = latest.publicTaskId?.trim();
    if (latestPublicTaskId != null && latestPublicTaskId.isNotEmpty) {
      _recordingOutlineTaskId = latestPublicTaskId;
      if (_expectedRecordingOutlineTaskId == latestPublicTaskId) {
        _expectedRecordingOutlineTaskId = null;
      }
    }
    final outputRevision = latest.outputPartRevisionId?.trim();
    final exactSucceeded =
        latest.status == 'succeeded' &&
        outputRevision != null &&
        outputRevision.isNotEmpty &&
        _item.outlinePartRevisionId?.trim() == outputRevision &&
        _item.summaryBody?.trim().isNotEmpty == true;
    final nextStatus = exactSucceeded
        ? V3OutlineTaskStatus.succeeded
        : latest.status == 'succeeded'
        ? V3OutlineTaskStatus.running
        : V3OutlineTaskStatus.failed;
    final nextError = nextStatus == V3OutlineTaskStatus.failed
        ? latest.failureCode ?? 'RECORDING_OUTLINE_FAILED'
        : null;
    if (_outlineStatus != nextStatus || _outlineErrorCode != nextError) {
      _outlineStatus = nextStatus;
      _outlineErrorCode = nextError;
      changed = true;
    }
    if (exactSucceeded) {
      _verifiedRecordingOutlineTaskId = latest.publicTaskId ?? latest.taskId;
      _verifiedRecordingOutlineRevision = outputRevision;
    }
    return (handled: true, changed: changed);
  }

  bool _hasLocallyVerifiedRecordingOutline(V3FeedItem item) =>
      _verifiedRecordingOutlineTaskId != null &&
      _verifiedRecordingOutlineRevision != null &&
      item.outlinePartRevisionId?.trim() == _verifiedRecordingOutlineRevision &&
      item.summaryBody?.trim().isNotEmpty == true;

  static bool _hasExactRecordingOutlineResult(
    RecordingDetail detail,
    V3FeedItem item,
  ) {
    final task = detail.noteOutlineTask;
    final noteRef = detail.noteRef;
    final outputRevision = noteRef?.outlinePartRevisionId?.trim();
    return task?.isSuccessful == true &&
        noteRef?.noteId.trim() == item.remoteNoteId?.trim() &&
        outputRevision != null &&
        outputRevision.isNotEmpty &&
        item.outlinePartRevisionId?.trim() == outputRevision &&
        item.summaryBody?.trim().isNotEmpty == true;
  }

  void _trackServerDerivedTasks(V3FeedItem item) {
    final tracker = _runTracker;
    final remoteNoteId = item.remoteNoteId?.trim();
    if (tracker == null || remoteNoteId == null || remoteNoteId.isEmpty) return;
    for (final task in item.activeDerivedTasks) {
      if (task.isTerminal) continue;
      if (item.usesBackendRecordingOutline &&
          task.stage == V3DerivedTaskStage.outline) {
        continue;
      }
      unawaited(_enrollServerDerivedTask(item, remoteNoteId, task));
    }
  }

  Future<void> _enrollServerDerivedTask(
    V3FeedItem item,
    String remoteNoteId,
    V3ActiveDerivedTask task,
  ) async {
    final tracker = _runTracker;
    if (tracker == null) return;
    if (tracker is AgentTaskSubjectMetadataPort) {
      await (tracker as AgentTaskSubjectMetadataPort)
          .rememberKnowledgeAssetSubject(
            localNoteId: item.id,
            subjectTitle: item.title,
          );
    }
    await tracker.trackDerivedPart(
      fileAgentRunId: task.fileAgentRunId,
      agentRunId: task.agentRunId,
      status: task.status,
      localNoteId: item.id,
      remoteNoteId: remoteNoteId,
      targetPart: switch (task.stage) {
        V3DerivedTaskStage.outline => NoteFileAgentPart.outline,
        V3DerivedTaskStage.sprout => NoteFileAgentPart.germination,
      },
    );
  }

  Future<V3FeedItem> _prepareDerivedPartSource({
    required String readOnlyCode,
    required String missingBindingCode,
    required String conflictCode,
    required String unavailableCode,
    required String failedCode,
    required String supersededCode,
  }) async {
    if (!_hasAuthoritativeItem) {
      throw _DerivedPartPreparationException(missingBindingCode);
    }
    var candidate = _library.noteForId(itemId) ?? _item;
    _item = candidate;
    if (candidate.isReadOnly) {
      throw _DerivedPartPreparationException(readOnlyCode);
    }
    if (_hasExactRemoteBinding(candidate)) return candidate;
    if (candidate.syncState == NoteSyncState.synced) {
      candidate = candidate.copyWith(syncState: NoteSyncState.pending);
      _item = candidate;
      _library.updateNote(candidate);
    }
    final sync = await _library.syncNote(candidate.id);
    candidate = sync.note ?? _library.noteForId(candidate.id) ?? candidate;
    _item = candidate;
    if (sync.outcome == KnowledgeNoteSyncOutcome.conflict) {
      throw _DerivedPartPreparationException(conflictCode);
    }
    if (sync.outcome == KnowledgeNoteSyncOutcome.unavailable) {
      throw _DerivedPartPreparationException(unavailableCode);
    }
    if (sync.outcome == KnowledgeNoteSyncOutcome.superseded) {
      throw _DerivedPartPreparationException(supersededCode);
    }
    if (sync.outcome != KnowledgeNoteSyncOutcome.synced) {
      throw _DerivedPartPreparationException(failedCode);
    }
    if (!_hasExactRemoteBinding(candidate)) {
      throw _DerivedPartPreparationException(missingBindingCode);
    }
    return candidate;
  }

  bool _hasExactRemoteBinding(V3FeedItem candidate) =>
      candidate.syncState == NoteSyncState.synced &&
      candidate.remoteNoteId?.trim().isNotEmpty == true &&
      candidate.rawPartRevisionId?.trim().isNotEmpty == true;

  String _outlineOperationIdFor(V3FeedItem candidate) {
    final retained = _acceptedOutlineAdmission;
    if (retained != null &&
        retained.localNoteId == candidate.id &&
        retained.remoteNoteId == candidate.remoteNoteId?.trim() &&
        retained.inputPartRevisionId == candidate.rawPartRevisionId?.trim() &&
        retained.targetPartRevisionId ==
            candidate.outlinePartRevisionId?.trim()) {
      return retained.operationId;
    }
    _acceptedOutlineAdmission = null;
    final repository = _outlineRepository;
    if (repository is PendingOutlineAdmissionPort) {
      final pendingOperation = (repository as PendingOutlineAdmissionPort)
          .pendingOutlineOperationId(candidate)
          ?.trim();
      if (pendingOperation != null && pendingOperation.isNotEmpty) {
        return pendingOperation;
      }
    }
    return _nextOutlineOperationId();
  }

  PendingOutlineAdmission? _pendingAcceptedOutlineAdmissionFor(
    V3FeedItem candidate,
  ) {
    final remoteNoteId = candidate.remoteNoteId?.trim();
    final rawRevisionId = candidate.rawPartRevisionId?.trim();
    final retained = _acceptedOutlineAdmission;
    if (retained != null &&
        retained.localNoteId == candidate.id &&
        retained.remoteNoteId == remoteNoteId &&
        retained.inputPartRevisionId == rawRevisionId) {
      return PendingOutlineAdmission(
        operationId: retained.operationId,
        accepted: retained.accepted,
      );
    }
    _acceptedOutlineAdmission = null;
    final repository = _outlineRepository;
    if (repository is! PendingOutlineAdmissionPort) return null;
    final pending = (repository as PendingOutlineAdmissionPort)
        .pendingOutlineAdmission(candidate);
    final accepted = pending?.accepted;
    if (accepted == null ||
        accepted.noteId != remoteNoteId ||
        accepted.inputPartRevisionId != rawRevisionId) {
      return null;
    }
    return pending;
  }

  bool _acceptedOutlineRunMatches(
    V3FeedItem note,
    NoteFileAgentRunSnapshot accepted,
  ) =>
      accepted.noteId == note.remoteNoteId?.trim() &&
      accepted.inputPart == NoteFileAgentPart.raw &&
      accepted.inputPartRevisionId == note.rawPartRevisionId?.trim() &&
      accepted.targetPart == NoteFileAgentPart.outline &&
      accepted.targetPartRevisionId == note.outlinePartRevisionId?.trim();

  void _rememberAcceptedOutlineAdmission(
    V3FeedItem note,
    NoteFileAgentRunSnapshot accepted, {
    required String operationId,
  }) {
    _acceptedOutlineAdmission = (
      localNoteId: note.id,
      remoteNoteId: accepted.noteId,
      inputPartRevisionId: accepted.inputPartRevisionId,
      targetPartRevisionId: accepted.targetPartRevisionId,
      operationId: operationId,
      accepted: accepted,
    );
  }

  void _clearAcceptedOutlineAdmission(String operationId) {
    if (_acceptedOutlineAdmission?.operationId == operationId) {
      _acceptedOutlineAdmission = null;
    }
  }

  String _nextOutlineOperationId() {
    _outlineOperationSequence += 1;
    return 'outline-${item.id}-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_outlineOperationSequence';
  }

  String _nextSproutOperationId() {
    _sproutOperationSequence += 1;
    return 'sprout-${item.id}-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_sproutOperationSequence';
  }

  void refreshFromLibrary() {
    if (_disposed) return;
    final sproutPending = _isPartPending(NoteFileAgentPart.germination);
    final submission = _library.sproutSubmissionFor(itemId);
    var submissionChanged = false;
    if (!sproutPending &&
        submission != null &&
        (_sproutStatus != submission.status ||
            _sproutErrorCode != submission.errorCode)) {
      _sproutStatus = submission.status;
      _sproutErrorCode = submission.errorCode;
      submissionChanged = true;
    }
    final libraryItem = _library.noteForId(itemId);
    if (libraryItem == null || identical(libraryItem, _item)) {
      if (submissionChanged) notifyListeners();
      return;
    }
    _hasAuthoritativeItem = true;
    final priorOutlineTerminal = _latestDerivedTerminal(
      NoteFileAgentPart.outline,
    );
    final replacesAutomaticFailure =
        _outlineStatus == V3OutlineTaskStatus.failed &&
        priorOutlineTerminal?.status != 'succeeded' &&
        isAutomaticOutlineOperationId(priorOutlineTerminal?.operationId) &&
        (_item.rawPartRevisionId != libraryItem.rawPartRevisionId ||
            _item.outlinePartRevisionId != libraryItem.outlinePartRevisionId);
    _item = libraryItem;
    _trackServerDerivedTasks(libraryItem);
    unawaited(_trackRecordingOutline(libraryItem));
    final hasOutline = libraryItem.summaryBody?.trim().isNotEmpty == true;
    if (libraryItem.usesBackendRecordingOutline) {
      final restored = _restoreRecordingOutlineFromTracker();
      if (!restored.handled) {
        _outlineStatus = _hasLocallyVerifiedRecordingOutline(libraryItem)
            ? V3OutlineTaskStatus.succeeded
            : _outlineStatusFor(libraryItem);
        _outlineErrorCode = _outlineStatus == V3OutlineTaskStatus.failed
            ? _outlineErrorCode ?? 'RECORDING_OUTLINE_FAILED'
            : null;
      }
    } else if (!_isPartPending(NoteFileAgentPart.outline) &&
        (_outlineStatus != V3OutlineTaskStatus.failed ||
            hasOutline ||
            replacesAutomaticFailure)) {
      _outlineStatus = _outlineStatusFor(libraryItem);
      _outlineErrorCode = null;
    }
    final hasSprout =
        libraryItem.sproutReport?.markdown.trim().isNotEmpty == true;
    if (!sproutPending &&
        (_sproutStatus != V3SproutTaskStatus.failed || hasSprout)) {
      _sproutStatus =
          submission?.status ??
          (_isTransientSproutStatus(libraryItem.sproutStatus)
              ? V3SproutTaskStatus.notStarted
              : libraryItem.sproutStatus);
      _sproutErrorCode = submission?.errorCode;
    }
    notifyListeners();
    _ensureRecordingOutlinePolling();
  }

  String? get outlineFailureMessage => _outlineErrorCode == null
      ? null
      : _outlineFailureMessage(_outlineErrorCode!);

  String? get sproutFailureMessage => _sproutErrorCode == null
      ? null
      : _sproutFailureMessage(_sproutErrorCode!);

  static V3FeedItem _fallbackItem(String id) {
    return V3FeedItem(
      id: id,
      title: '资料正在同步',
      source: V3MaterialSource.note,
      createdAt: DateTime.now().subtract(const Duration(days: 1, hours: 2)),
      rawBody: '',
      summaryBody: null,
      summaryError: null,
    );
  }

  static V3OutlineTaskStatus _outlineStatusFor(V3FeedItem item) {
    if (item.usesBackendRecordingOutline) {
      if (_recordingStageFailed(item.minutesStatus) ||
          _recordingStageFailed(item.summaryStatus)) {
        return V3OutlineTaskStatus.failed;
      }
      if (_hasPersistedRecordingOutline(item) &&
          _recordingStageAllowsPersistedOutline(item.minutesStatus) &&
          _recordingStageAllowsPersistedOutline(item.summaryStatus)) {
        return V3OutlineTaskStatus.succeeded;
      }
      return V3OutlineTaskStatus.running;
    }
    return item.summaryBody?.trim().isNotEmpty == true
        ? V3OutlineTaskStatus.succeeded
        : V3OutlineTaskStatus.notStarted;
  }

  static bool _recordingStageFailed(String? value) => const <String>{
    'failed',
    'error',
    'timeout',
    'timed_out',
    'cancelled',
    'canceled',
  }.contains(value?.trim().toLowerCase().replaceAll('-', '_'));

  static bool _recordingStageAllowsPersistedOutline(String? value) {
    final normalized = value?.trim().toLowerCase().replaceAll('-', '_');
    if (normalized == null || normalized.isEmpty) return true;
    return const <String>{
      'succeeded',
      'success',
      'completed',
      'done',
      'finished',
    }.contains(normalized);
  }

  static bool _hasPersistedRecordingOutline(V3FeedItem item) =>
      item.syncState == NoteSyncState.synced &&
      item.remoteNoteId?.trim().isNotEmpty == true &&
      item.outlinePartRevisionId?.trim().isNotEmpty == true &&
      item.summaryBody?.trim().isNotEmpty == true;

  static bool _isTransientSproutStatus(V3SproutTaskStatus status) =>
      status == V3SproutTaskStatus.failed ||
      status == V3SproutTaskStatus.running;

  @override
  void dispose() {
    _disposed = true;
    _recordingPollGeneration += 1;
    _recordingPollingDesired = false;
    _recordingOutlinePoller?.dispose();
    _recordingOutlinePoller = null;
    super.dispose();
  }
}

String _stableFeedRecordingPollId(String value) {
  final digest = sha256.convert(utf8.encode(value)).toString();
  return digest.substring(0, 16);
}

final class _DerivedPartPreparationException implements Exception {
  const _DerivedPartPreparationException(this.code);

  final String code;
}
