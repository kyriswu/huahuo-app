import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../recordings/application/recording_detail_controller.dart';
import '../../recordings/application/recording_processing_tracker.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/domain/recording_detail.dart';
import '../../recordings/domain/recording_library.dart';
import '../application/knowledge_library_controller.dart';
import '../domain/feed_item_models.dart';

typedef V3TranscriptionOrigin = RecordingFileSource;

enum V3TranscriptionPendingActivity { waitingForUpload, uploading, processing }

class V3TranscriptionPendingSurface extends StatelessWidget {
  const V3TranscriptionPendingSurface({
    required this.phase,
    required this.onBack,
    this.errorCode,
    this.onRetry,
    this.title = '转写详情',
    this.failureTitle = '暂时无法开始转写',
    this.progress,
    this.activity = V3TranscriptionPendingActivity.processing,
    super.key,
  });

  final String phase;
  final String? errorCode;
  final VoidCallback onBack;
  final VoidCallback? onRetry;
  final String title;
  final String failureTitle;
  final double? progress;
  final V3TranscriptionPendingActivity activity;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final failed = errorCode != null;
    final waiting = activity == V3TranscriptionPendingActivity.waitingForUpload;
    return V3PageScaffold(
      title: title,
      subtitle: failed ? '转写准备失败' : phase,
      fallbackRoute: '/v3/feed',
      backBehavior: V3BackBehavior.fallbackOnly,
      onBack: onBack,
      bottomBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!failed && !waiting)
            V3LongRunningTaskNotice(
              onReturn: onBack,
              message: activity == V3TranscriptionPendingActivity.uploading
                  ? '上传和转写可能需要较长时间，可先返回其他界面，稍后从「消息通知」重新进入查看。'
                  : '处理可能需要较长时间，可先返回其他界面，稍后从「消息通知」重新进入查看。',
            )
          else if (!failed)
            Text(
              '录音已保存在本地，尚未提交转写。',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted, fontSize: 12, height: 1.4),
            ),
          if ((failed || waiting) && onRetry != null)
            V3PrimaryButton(
              key: const ValueKey('transcription-pending-retry'),
              label: waiting && !failed ? '上传并转写' : '重试',
              icon: Icons.refresh_rounded,
              onPressed: onRetry!,
            ),
        ],
      ),
      children: [
        const SizedBox(height: 24),
        V3Card(
          key: const ValueKey('transcription-pending-surface'),
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: failed
                          ? colors.danger.withValues(alpha: .12)
                          : colors.surfaceMuted,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      failed
                          ? Icons.error_outline_rounded
                          : Icons.graphic_eq_rounded,
                      color: failed ? colors.danger : colors.ink,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          failed
                              ? failureTitle
                              : switch (activity) {
                                  V3TranscriptionPendingActivity
                                      .waitingForUpload =>
                                    '等待上传',
                                  V3TranscriptionPendingActivity.uploading =>
                                    '正在上传',
                                  V3TranscriptionPendingActivity.processing =>
                                    '正在转写',
                                },
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          failed ? _recordingFailureMessage(errorCode!) : phase,
                          key: const ValueKey('transcription-pending-phase'),
                          style: TextStyle(
                            color: failed ? colors.danger : colors.muted,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!failed && !waiting) ...[
                const SizedBox(height: 18),
                LinearProgressIndicator(
                  key: const ValueKey('transcription-pending-progress'),
                  value: progress,
                ),
                const SizedBox(height: 10),
                Text(
                  '语音转写完成后会先写入云端笔记，写入成功后再生成纲要。',
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class V3TranscriptionJobPage extends ConsumerWidget {
  const V3TranscriptionJobPage({
    required this.jobId,
    required this.source,
    this.destination = V3ContentStage.summary,
    super.key,
  });

  final String jobId;
  final RecordingFileSource source;
  final V3ContentStage destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upload = ref.watch(recordingUploadControllerProvider);
    final tracker = ref.watch(recordingProcessingTrackerProvider);
    final activeDraft = upload.state.activeDraft?.draftId == jobId
        ? upload.state.activeDraft
        : null;
    final objectUploadProgress = upload.state.progressForDraft(jobId);
    final draft =
        activeDraft ?? ref.read(uploadDraftStoreProvider).getDraft(jobId);
    final task = tracker.state.taskForDraft(jobId);
    final jobFailure = upload.state.failureCodesByJobId[jobId];
    final uploading = upload.state.activeJobIds.contains(jobId);
    final resolvedSource = draft == null
        ? source
        : RecordingFileSource.fromRoute(
            draft.entrySource ?? draft.recordingSource,
          );
    final recordingId = draft?.recordingId?.trim();
    if (recordingId != null && recordingId.isNotEmpty) {
      return V3TranscriptionDetailPage(
        key: ValueKey<String>('transcription-detail-$recordingId'),
        recordingId: recordingId,
        origin: resolvedSource,
        destination: destination,
      );
    }

    final validJobId = RegExp(
      r'^draft-[A-Za-z0-9][A-Za-z0-9._-]{0,191}$',
    ).hasMatch(jobId);
    final projectedStatus = draft == null
        ? uploading
              ? RecordingFileJobStatus.uploading
              : RecordingFileJobStatus.failed
        : recordingFileJobStatusForDraft(draft, processingTask: task);
    final activeStatus = jobFailure != null
        ? RecordingFileJobStatus.failed
        : uploading
        ? RecordingFileJobStatus.uploading
        : activeDraft == null
        ? projectedStatus
        : upload.state.status ?? projectedStatus;
    final uploadOwnsByteProgress =
        objectUploadProgress != null && objectUploadProgress.totalBytes > 0;
    final uploadFraction = uploadOwnsByteProgress
        ? (objectUploadProgress.bytesSent / objectUploadProgress.totalBytes)
              .clamp(0.0, 1.0)
              .toDouble()
        : null;
    final uploadProgressDetails = uploadOwnsByteProgress
        ? <String>[
            '${_formatUploadBytes(objectUploadProgress.bytesSent)} / '
                '${_formatUploadBytes(objectUploadProgress.totalBytes)}',
            if (objectUploadProgress.bytesPerSecond > 0)
              '${_formatUploadBytes(objectUploadProgress.bytesPerSecond.round())}/s',
            if (objectUploadProgress.estimatedRemainingSeconds != null)
              '剩余 ${_formatUploadEta(objectUploadProgress.estimatedRemainingSeconds!)}',
          ].join(' · ')
        : null;
    final errorCode = !validJobId
        ? 'RECORDING_JOB_ID_INVALID'
        : jobFailure ??
              (draft == null
                  ? uploading
                        ? null
                        : 'RECORDING_PROCESSING_CHECKPOINT_MISSING'
                  : activeStatus == RecordingFileJobStatus.failed
                  ? (activeDraft == null ? null : upload.state.lastErrorCode) ??
                        draft.lastErrorCode ??
                        'RECORDING_UPLOAD_FAILED'
                  : null);
    final waiting = errorCode == null && !uploading && task == null;
    final phase = waiting
        ? '录音保留在本地，点击开始或继续上传后转写'
        : task == null
        ? switch (activeStatus) {
            RecordingFileJobStatus.uploading =>
              '${resolvedSource.label}正在上传'
                  '${uploadProgressDetails == null ? '' : ' · $uploadProgressDetails'}',
            RecordingFileJobStatus.processing => '服务端正在转写录音',
            RecordingFileJobStatus.ready => '正在打开转写与纲要',
            RecordingFileJobStatus.failed => '录音处理失败',
          }
        : switch (task.phase) {
            RecordingProcessingPhase.transcribing => '服务端正在转写录音',
            RecordingProcessingPhase.storingCloudNote => '转写完成，正在写入云端笔记',
            RecordingProcessingPhase.completed => '正在打开转写与纲要',
            RecordingProcessingPhase.failed => '录音处理失败',
          };
    return V3TranscriptionPendingSurface(
      title: '${resolvedSource.label}转写',
      phase: phase,
      errorCode: errorCode,
      activity: waiting
          ? V3TranscriptionPendingActivity.waitingForUpload
          : V3TranscriptionPendingActivity.uploading,
      progress: activeStatus == RecordingFileJobStatus.uploading
          ? uploadFraction
          : null,
      onBack: () => _leaveTranscriptionJob(context),
      onRetry: (errorCode != null || waiting) && draft != null && !uploading
          ? () => unawaited(
              ref.read(recordingUploadControllerProvider).retryJob(jobId),
            )
          : null,
    );
  }
}

String _formatUploadBytes(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB'];
  var value = bytes < 0 ? 0.0 : bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final precision = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unit]}';
}

String _formatUploadEta(int seconds) {
  final safeSeconds = seconds < 0 ? 0 : seconds;
  if (safeSeconds < 60) return '${safeSeconds}s';
  final minutes = safeSeconds ~/ 60;
  final remainingSeconds = safeSeconds % 60;
  if (minutes < 60) return '${minutes}m ${remainingSeconds}s';
  return '${minutes ~/ 60}h ${minutes % 60}m';
}

void _leaveTranscriptionJob(BuildContext context) {
  unawaited(returnToPreviousRoute(context, fallbackRoute: '/v3/feed'));
}

class V3TranscriptionDetailPage extends ConsumerStatefulWidget {
  const V3TranscriptionDetailPage({
    required this.recordingId,
    this.origin = V3TranscriptionOrigin.monologue,
    this.destination = V3ContentStage.summary,
    super.key,
  });

  final String recordingId;
  final V3TranscriptionOrigin origin;
  final V3ContentStage destination;

  @override
  ConsumerState<V3TranscriptionDetailPage> createState() =>
      _V3TranscriptionDetailPageState();
}

class _V3TranscriptionDetailPageState
    extends ConsumerState<V3TranscriptionDetailPage>
    with AppActivityRouteAware<V3TranscriptionDetailPage> {
  static const _cloudAssetRefreshAttempts = 30;
  static const _cloudAssetRefreshInterval = Duration(seconds: 2);

  String? _automaticAssetOpenKey;
  final Map<String, OrchestratedPoller> _cloudAssetRefreshPollers =
      <String, OrchestratedPoller>{};
  final Map<String, int> _cloudAssetRefreshCounts = <String, int>{};
  final Set<String> _completedCloudAssetRefreshKeys = <String>{};
  late RecordingDetailController _recordingDetailController;
  bool _projectionEffectsScheduled = false;

  @override
  void initState() {
    super.initState();
    _recordingDetailController = ref.read(recordingDetailControllerProvider);
    _bindRecordingDetailController(_recordingDetailController);
    ref.listenManual<RecordingDetailController>(
      recordingDetailControllerProvider,
      (_, next) {
        if (identical(_recordingDetailController, next)) return;
        _recordingDetailController = next;
        _bindRecordingDetailController(next);
        _automaticAssetOpenKey = null;
        _disposeCloudAssetPollers();
        scheduleMicrotask(_load);
        _scheduleProjectionEffects();
      },
    );
    ref.listenManual<String?>(
      authenticatedRecordingUserScopeProvider,
      _onAccountScopeChanged,
      fireImmediately: true,
    );
    ref.listenManual<RecordingDetailState>(
      recordingDetailControllerProvider.select(
        (controller) => controller.state,
      ),
      (_, __) => _scheduleProjectionEffects(),
      fireImmediately: true,
    );
    ref.listenManual<KnowledgeLibraryController>(
      knowledgeLibraryControllerProvider,
      (_, __) => _scheduleProjectionEffects(),
      fireImmediately: true,
    );
  }

  void _bindRecordingDetailController(RecordingDetailController controller) {
    controller
      ..attachPollingRuntime(
        orchestrator: ref.read(taskOrchestratorProvider),
        activityMetrics: ref.read(runtimeActivityMetricsProvider),
      )
      ..setPollingRouteActive(activityRouteCanRun);
  }

  @override
  void didUpdateWidget(covariant V3TranscriptionDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recordingId != widget.recordingId ||
        oldWidget.origin != widget.origin) {
      _automaticAssetOpenKey = null;
      _disposeCloudAssetPollers();
      scheduleMicrotask(_load);
      _scheduleProjectionEffects();
    }
  }

  void _onAccountScopeChanged(String? previous, String? next) {
    if (previous == next) return;
    _automaticAssetOpenKey = null;
    _disposeCloudAssetPollers();
    if (next != null) scheduleMicrotask(_load);
    _scheduleProjectionEffects();
  }

  void _load() {
    if (!mounted ||
        ref.read(authenticatedRecordingUserScopeProvider) == null ||
        !_isSafeRecordingId(widget.recordingId)) {
      return;
    }
    final controller = ref.read(recordingDetailControllerProvider);
    if (!identical(controller, _recordingDetailController)) {
      _recordingDetailController = controller;
      _bindRecordingDetailController(controller);
    }
    unawaited(controller.loadAndPoll(widget.recordingId));
  }

  void _scheduleProjectionEffects() {
    if (_projectionEffectsScheduled) return;
    _projectionEffectsScheduled = true;
    scheduleMicrotask(() {
      _projectionEffectsScheduled = false;
      if (!mounted) return;
      _runProjectionEffects();
    });
  }

  void _runProjectionEffects() {
    final accountScope = ref.read(authenticatedRecordingUserScopeProvider);
    final state = ref.read(recordingDetailControllerProvider).state;
    final visibleState =
        accountScope != null && state.accountScope == accountScope
        ? state
        : RecordingDetailState.initial();
    final detail = visibleState.detail;
    final library = ref.read(knowledgeLibraryControllerProvider);
    _scheduleCloudAssetRefresh(detail, visibleState.accountScope);
    final authoritativeAssetRoute = _cloudAssetRoute(library, detail);
    _scheduleAutomaticAssetOpen(
      authoritativeAssetRoute,
      detail: detail,
      ownerScope: visibleState.accountScope,
    );
  }

  @override
  Widget build(BuildContext context) {
    final accountScope = ref.watch(authenticatedRecordingUserScopeProvider);
    final state = ref.watch(recordingDetailControllerProvider).state;
    final visibleState =
        accountScope != null && state.accountScope == accountScope
        ? state
        : RecordingDetailState.initial();
    final validId = _isSafeRecordingId(widget.recordingId);
    final detail = visibleState.detail;
    final library = ref.watch(knowledgeLibraryControllerProvider);
    final canonicalNote = _canonicalRecordingNote(library, detail);
    final completedAssetRoute = _cloudAssetRoute(library, detail);
    final assetHandoffPhase = _recordingAssetHandoffPhase(
      detail,
      assetReady: completedAssetRoute != null,
    );
    final subtitle = !validId
        ? '录音标识无效'
        : detail == null
        ? _controllerStatusLabel(visibleState.status)
        : assetHandoffPhase ?? _recordingDetailStatusLabel(detail);

    return V3PageScaffold(
      title: '转写详情',
      subtitle: subtitle,
      fallbackRoute: '/v3/feed',
      backBehavior: V3BackBehavior.fallbackOnly,
      trailing: IconButton(
        key: const ValueKey<String>('transcription-view-asset-top'),
        tooltip: '查看资产',
        icon: const Icon(Icons.inventory_2_outlined),
        onPressed: completedAssetRoute == null
            ? null
            : () => _openCompletedAsset(context, completedAssetRoute),
      ),
      bottomBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (validId && detail != null && !detail.shouldStopPolling)
            V3LongRunningTaskNotice(
              key: const ValueKey<String>('transcription-background'),
              onReturn: _leaveInBackground,
            ),
        ],
      ),
      children: [
        if (!validId)
          const _DetailErrorCard(errorCode: 'RECORDING_ROUTE_ID_INVALID')
        else ...[
          _RecordingStatusCard(
            state: visibleState,
            assetHandoffPhase: assetHandoffPhase,
          ),
          if (visibleState.lastErrorCode != null) ...[
            const SizedBox(height: 14),
            _DetailErrorCard(errorCode: visibleState.lastErrorCode!),
          ],
          if (detail == null) ...[
            const SizedBox(height: 42),
            const Center(child: CircularProgressIndicator.adaptive()),
          ] else ...[
            const SizedBox(height: 16),
            _RecordingBody(detail: detail, canonicalNote: canonicalNote),
            if (detail.hasFinalTranscriptFact && detail.hasOutlineFailure) ...[
              const SizedBox(height: 14),
              _OutlineFailureNotice(canRetry: detail.canRetryOutline),
            ],
            if (_allowedRetryActions(detail).isNotEmpty) ...[
              const SizedBox(height: 18),
              _RetryActions(
                detail: detail,
                isRetrying:
                    visibleState.status ==
                    RecordingDetailControllerStatus.retrying,
              ),
            ],
          ],
        ],
      ],
    );
  }

  void _leaveInBackground() {
    unawaited(returnToPreviousRoute(context, fallbackRoute: '/v3/feed'));
  }

  String? _cloudAssetRoute(
    KnowledgeLibraryController library,
    RecordingDetail? detail,
  ) {
    if (detail == null || !detail.hasCloudAsset) return null;
    final noteRef = detail.noteRef;
    if (noteRef == null) return null;
    final noteId = noteRef.noteId;
    final note = _canonicalRecordingNote(library, detail);
    if (note == null ||
        note.remoteNoteId != noteId ||
        note.rawPartRevisionId != noteRef.rawPartRevisionId ||
        note.recordingId != detail.recording.recordingId ||
        note.syncState != NoteSyncState.synced ||
        !library.isDeposited(note.id)) {
      return null;
    }
    return '/v3/feed/items/${Uri.encodeComponent(note.id)}'
        '?stage=${widget.destination.name}';
  }

  void _scheduleCloudAssetRefresh(RecordingDetail? detail, String? ownerScope) {
    if (detail == null || ownerScope == null || !detail.hasCloudAsset) return;
    final noteRef = detail.noteRef;
    if (noteRef == null) return;
    final refreshKey = _recordingScopeKey(
      ownerScope,
      '${detail.recording.recordingId}:${noteRef.noteId}:${noteRef.rawPartRevisionId}',
    );
    if (_cloudAssetRefreshPollers.containsKey(refreshKey)) return;
    final stableId = _stableTranscriptionPollId(refreshKey);
    // performance-rfc: transcription-cloud-asset-poll
    final poller = OrchestratedPoller(
      orchestrator: ref.read(taskOrchestratorProvider),
      spec: TaskSpec(
        key: 'transcription:cloud-asset:$stableId',
        owner: 'transcription-cloud-asset',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{
          TaskResource.network,
          TaskResource.database,
        },
        foregroundOnly: true,
        deadline: const Duration(seconds: 30),
        retryable: true,
        replaceExisting: true,
      ),
      interval: _cloudAssetRefreshInterval,
      maxBackoff: const Duration(seconds: 30),
      activityMetrics: ref.read(runtimeActivityMetricsProvider),
      metricsOwner: 'transcription.cloud-asset.$stableId',
      poll: (token) => _refreshCloudAssetOnce(
        refreshKey: refreshKey,
        detail: detail,
        ownerScope: ownerScope,
        token: token,
      ),
    );
    _cloudAssetRefreshPollers[refreshKey] = poller;
    _cloudAssetRefreshCounts[refreshKey] = 0;
    if (activityRouteCanRun) poller.start();
  }

  Future<bool> _refreshCloudAssetOnce({
    required String refreshKey,
    required RecordingDetail detail,
    required String ownerScope,
    required AppTaskCancellationToken token,
  }) async {
    token.throwIfCancelled();
    if (detail.noteRef == null ||
        !mounted ||
        !_isCurrentRecordingAccountScope(ownerScope)) {
      _completedCloudAssetRefreshKeys.add(refreshKey);
      return false;
    }
    final previousAttempts = _cloudAssetRefreshCounts[refreshKey] ?? 0;
    if (previousAttempts >= _cloudAssetRefreshAttempts) {
      _completedCloudAssetRefreshKeys.add(refreshKey);
      return false;
    }
    final attempts = previousAttempts + 1;
    _cloudAssetRefreshCounts[refreshKey] = attempts;
    final library = ref.read(knowledgeLibraryControllerProvider);
    await library.reconcileRemoteNotesForChatReference();
    token.throwIfCancelled();
    if (!mounted || !_isCurrentRecordingAccountScope(ownerScope)) {
      _completedCloudAssetRefreshKeys.add(refreshKey);
      return false;
    }
    _applyRecordingAssetProvenance(library, detail);
    if (_cloudAssetRoute(library, detail) != null ||
        attempts >= _cloudAssetRefreshAttempts) {
      _completedCloudAssetRefreshKeys.add(refreshKey);
      return false;
    }
    return true;
  }

  @override
  void onActivityRouteBecameActive() {
    _recordingDetailController.setPollingRouteActive(true);
    for (final entry in _cloudAssetRefreshPollers.entries) {
      if (!_completedCloudAssetRefreshKeys.contains(entry.key)) {
        entry.value.start();
      }
    }
    _scheduleProjectionEffects();
  }

  @override
  void onActivityRouteBecameInactive() {
    _recordingDetailController.setPollingRouteActive(false);
    for (final poller in _cloudAssetRefreshPollers.values) {
      poller.stop();
    }
  }

  @override
  void dispose() {
    _recordingDetailController.setPollingRouteActive(false);
    _disposeCloudAssetPollers();
    super.dispose();
  }

  void _disposeCloudAssetPollers() {
    for (final poller in _cloudAssetRefreshPollers.values) {
      poller.dispose();
    }
    _cloudAssetRefreshPollers.clear();
    _cloudAssetRefreshCounts.clear();
    _completedCloudAssetRefreshKeys.clear();
  }

  void _applyRecordingAssetProvenance(
    KnowledgeLibraryController library,
    RecordingDetail detail,
  ) {
    final noteRef = detail.noteRef;
    if (noteRef == null) return;
    final note = library.noteForId(noteRef.noteId);
    if (note == null ||
        note.remoteNoteId != noteRef.noteId ||
        note.rawPartRevisionId != noteRef.rawPartRevisionId) {
      return;
    }
    final source = switch (widget.origin) {
      RecordingFileSource.recording => V3MaterialSource.mediaImport,
      RecordingFileSource.monologue => V3MaterialSource.monologue,
      RecordingFileSource.meeting => V3MaterialSource.meeting,
      RecordingFileSource.internalRecording =>
        V3MaterialSource.internalRecording,
      RecordingFileSource.audioImport ||
      RecordingFileSource.localLibrary => V3MaterialSource.mediaImport,
      RecordingFileSource.recordingCard => V3MaterialSource.recordingCard,
    };
    if (note.source == source &&
        note.recordingId == detail.recording.recordingId &&
        note.minutesStatus == detail.recording.minutesStatus &&
        note.summaryStatus == detail.recording.summaryStatus) {
      return;
    }
    library.updateNote(
      note.copyWith(
        source: source,
        recordingId: detail.recording.recordingId,
        minutesStatus: detail.recording.minutesStatus,
        summaryStatus: detail.recording.summaryStatus,
      ),
    );
  }

  void _openCompletedAsset(BuildContext context, String? route) {
    if (route == null) return;
    context.replace(route);
  }

  void _scheduleAutomaticAssetOpen(
    String? route, {
    required RecordingDetail? detail,
    required String? ownerScope,
  }) {
    if (route == null ||
        detail == null ||
        ownerScope == null ||
        !activityRouteCanRun ||
        ModalRoute.of(context)?.isCurrent != true ||
        !detail.hasFinalTranscriptFact ||
        detail.recording.recordingId != widget.recordingId) {
      return;
    }
    final automaticOpenKey = _recordingScopeKey(
      ownerScope,
      '${detail.recording.recordingId}:$route',
    );
    if (_automaticAssetOpenKey == automaticOpenKey) return;
    if (!mounted ||
        widget.recordingId != detail.recording.recordingId ||
        !_isCurrentRecordingAccountScope(ownerScope)) {
      return;
    }
    _automaticAssetOpenKey = automaticOpenKey;
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      _automaticAssetOpenKey = null;
      return;
    }
    router.replace(route);
  }

  bool _isCurrentRecordingAccountScope(String ownerScope) {
    return ref.read(authenticatedRecordingUserScopeProvider) == ownerScope;
  }
}

String _recordingScopeKey(String accountScope, String recordingId) {
  return '${accountScope.length}:$accountScope:$recordingId';
}

V3FeedItem? _canonicalRecordingNote(
  KnowledgeLibraryController library,
  RecordingDetail? detail,
) {
  final noteId = detail?.noteRef?.noteId.trim();
  if (noteId == null || noteId.isEmpty) return null;
  for (final note in library.notes) {
    if (note.remoteNoteId?.trim() == noteId) return note;
  }
  return null;
}

String _stableTranscriptionPollId(String value) {
  final digest = sha256.convert(utf8.encode(value)).toString();
  return digest.substring(0, 16);
}

class _RecordingStatusCard extends StatelessWidget {
  const _RecordingStatusCard({
    required this.state,
    required this.assetHandoffPhase,
  });

  final RecordingDetailState state;
  final String? assetHandoffPhase;

  @override
  Widget build(BuildContext context) {
    final detail = state.detail;
    final asr = detail?.asrTask;
    final asrMessage = asr?.message;
    final progress = assetHandoffPhase == null && asr != null
        ? _transcriptionProgress(asr)
        : null;
    final showingInitialProgress =
        assetHandoffPhase != null ||
        (detail == null &&
            state.status != RecordingDetailControllerStatus.failed);
    final progressStatus =
        assetHandoffPhase ??
        (asr == null
            ? _controllerStatusLabel(state.status)
            : _remoteStatusLabel(asr.status));
    return Semantics(
      liveRegion: true,
      label: progressStatus,
      child: V3Card(
        radius: 8,
        padding: const EdgeInsets.fromLTRB(18, 17, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  size: 30,
                  color: HuahuoV3Theme.tokensOf(context).ink,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    detail?.recording.title ?? '正在读取录音状态',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: HuahuoV3Theme.tokensOf(context).ink,
                    ),
                  ),
                ),
                _StatusPill(
                  label:
                      assetHandoffPhase ??
                      (detail == null
                          ? _controllerStatusLabel(state.status)
                          : _recordingDetailStatusLabel(detail)),
                ),
              ],
            ),
            if (asr != null || showingInitialProgress) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      assetHandoffPhase != null
                          ? '资产处理'
                          : asr == null
                          ? '正在同步转写状态'
                          : '语音转写',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: HuahuoV3Theme.tokensOf(context).muted,
                      ),
                    ),
                  ),
                  Text(
                    progress == null ? progressStatus : '$progress%',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: HuahuoV3Theme.tokensOf(context).ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  key: const ValueKey('transcription-progress'),
                  minHeight: 7,
                  value: progress == null ? null : progress / 100,
                  backgroundColor: HuahuoV3Theme.tokensOf(context).surfaceMuted,
                  color: HuahuoV3Theme.tokensOf(context).ink,
                ),
              ),
              if (asrMessage != null && assetHandoffPhase == null) ...[
                const SizedBox(height: 10),
                Text(
                  asrMessage,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    color: HuahuoV3Theme.tokensOf(context).muted,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

int? _transcriptionProgress(AsrTaskSnapshot asr) {
  final exact = asr.progress;
  if (exact != null) return exact;
  return switch (asr.status) {
    RecordingRemoteStatus.speakerLabelPending ||
    RecordingRemoteStatus.generatingMinutes ||
    RecordingRemoteStatus.generatingSummary ||
    RecordingRemoteStatus.depositing ||
    RecordingRemoteStatus.deposited ||
    RecordingRemoteStatus.completed => 100,
    _ => null,
  };
}

class _RecordingBody extends StatelessWidget {
  const _RecordingBody({required this.detail, required this.canonicalNote});

  final RecordingDetail detail;
  final V3FeedItem? canonicalNote;

  @override
  Widget build(BuildContext context) {
    final transcript = detail.finalTranscript;
    final outlineMarkdown = _recordingOutlineMarkdown(detail, canonicalNote);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (transcript != null)
          _ContentSection(
            icon: Icons.subject_outlined,
            title: '原始',
            content: transcript,
          )
        else if (detail.isTerminal)
          const _EmptyResultCard(label: '服务端尚未返回可展示的转写内容。'),
        if (outlineMarkdown != null) ...[
          const SizedBox(height: 14),
          _ContentSection(
            icon: Icons.assignment_outlined,
            title: '纲要',
            content: outlineMarkdown,
            renderMarkdown: true,
            markdownKey: 'transcription-outline-markdown',
          ),
        ],
      ],
    );
  }
}

class _OutlineFailureNotice extends StatelessWidget {
  const _OutlineFailureNotice({required this.canRetry});

  final bool canRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      radius: 8,
      color: tokens.danger.withValues(alpha: .08),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.assignment_late_outlined, color: tokens.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              canRetry
                  ? '纲要生成未完成。原始转写已保存，可在对应笔记详情中重新生成。'
                  : '纲要生成未完成。原始转写已保存到资产，稍后可重新进入查看状态。',
              style: TextStyle(color: tokens.text, fontSize: 14, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContentSection extends StatelessWidget {
  const _ContentSection({
    required this.icon,
    required this.title,
    required this.content,
    this.renderMarkdown = false,
    this.markdownKey,
  });

  final IconData icon;
  final String title;
  final String content;
  final bool renderMarkdown;
  final String? markdownKey;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      radius: 8,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: tokens.text),
              const SizedBox(width: 9),
              Text(
                title,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: tokens.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          if (renderMarkdown)
            V3AssistantReplyMarkdown(
              key: markdownKey == null ? null : ValueKey<String>(markdownKey!),
              source: content,
            )
          else
            SelectableText(
              content,
              contextMenuBuilder: V3TextEditing.buildContextMenu,
              style: TextStyle(
                fontSize: 16,
                height: 1.55,
                color: tokens.text,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }
}

String? _recordingOutlineMarkdown(
  RecordingDetail detail,
  V3FeedItem? canonicalNote,
) {
  if (detail.noteOutlineTask?.isSuccessful != true || canonicalNote == null) {
    return null;
  }
  final noteRef = detail.noteRef;
  final expectedRevision = noteRef?.outlinePartRevisionId?.trim();
  final markdown = canonicalNote.summaryBody?.trim();
  if (noteRef == null ||
      expectedRevision == null ||
      expectedRevision.isEmpty ||
      markdown == null ||
      markdown.isEmpty ||
      canonicalNote.remoteNoteId?.trim() != noteRef.noteId.trim() ||
      canonicalNote.recordingId?.trim() !=
          detail.recording.recordingId.trim() ||
      canonicalNote.outlinePartRevisionId?.trim() != expectedRevision ||
      canonicalNote.syncState != NoteSyncState.synced) {
    return null;
  }
  return markdown;
}

class _RetryActions extends ConsumerWidget {
  const _RetryActions({required this.detail, required this.isRetrying});

  final RecordingDetail detail;
  final bool isRetrying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = _allowedRetryActions(detail);
    return V3Card(
      radius: 8,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '服务端允许的重试',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: HuahuoV3Theme.tokensOf(context).ink,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final action in actions)
                OutlinedButton.icon(
                  onPressed: isRetrying
                      ? null
                      : () {
                          final controller = ref.read(
                            recordingDetailControllerProvider,
                          );
                          controller.retryRecording(action.stage);
                        },
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                  label: Text(action.title),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailErrorCard extends StatelessWidget {
  const _DetailErrorCard({required this.errorCode});

  final String errorCode;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      radius: 8,
      color: HuahuoV3Theme.semanticSurface(colors.danger, colors.surface),
      padding: const EdgeInsets.all(15),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _recordingFailureMessage(errorCode),
              style: TextStyle(color: colors.ink, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyResultCard extends StatelessWidget {
  const _EmptyResultCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return V3Card(
      radius: 8,
      padding: const EdgeInsets.all(16),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          height: 1.4,
          color: HuahuoV3Theme.tokensOf(context).muted,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: HuahuoV3Theme.tokensOf(context).surfaceMuted,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          label,
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).ink,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

List<RecordingRetryAction> _allowedRetryActions(RecordingDetail detail) {
  return detail.effectiveRetryActions
      .where(
        (action) => !const <String>{
          'minutes_generation',
          'summary_generation',
          'recording_note_outline',
        }.contains(action.stage.trim()),
      )
      .toList(growable: false);
}

String _recordingFailureMessage(String errorCode) {
  final code = errorCode.trim().toUpperCase();
  if (code == 'RECORDING_UPLOAD_JOB_CONFLICT') {
    return '上传任务与当前文件或工作区不一致，请返回录音列表后重试。';
  }
  if (code.contains('ROUTE') ||
      code.contains('JOB_ID') ||
      code.contains('CHECKPOINT') ||
      code.contains('RECORDING_ID_MISSING') ||
      code.contains('MISMATCH')) {
    return '无法识别这项录音任务，请返回后重新进入。';
  }
  if (code.contains('ACCOUNT') || code.contains('WORKSPACE')) {
    return '当前账号或工作区已变化，请返回后重新进入。';
  }
  if (code.contains('UPLOAD') ||
      code.contains('TOKEN') ||
      code.contains('OBJECT') ||
      code.contains('NETWORK') ||
      code.contains('TIMEOUT')) {
    return '录音上传或同步未完成，请检查网络后重试。';
  }
  if (code.contains('ASR') ||
      code.contains('TRANSCRIPT') ||
      code.contains('SPEAKER') ||
      code.contains('PROCESSING')) {
    return '服务端处理未完成，请稍后重试或从消息通知查看。';
  }
  return '录音处理暂时未完成，请稍后重试。';
}

bool _isSafeRecordingId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
}

String _controllerStatusLabel(RecordingDetailControllerStatus status) {
  return switch (status) {
    RecordingDetailControllerStatus.idle => '等待读取',
    RecordingDetailControllerStatus.loading => '正在读取',
    RecordingDetailControllerStatus.polling => '正在处理',
    RecordingDetailControllerStatus.terminal => '处理完成',
    RecordingDetailControllerStatus.retrying => '正在重试',
    RecordingDetailControllerStatus.failed => '读取失败',
  };
}

String _recordingDetailStatusLabel(RecordingDetail detail) {
  if (detail.hasFinalTranscriptFact && !detail.hasCloudAsset) {
    return '正在创建资产';
  }
  if (detail.hasFinalTranscriptFact &&
      _isFailureRemoteStatus(detail.recording.status)) {
    return '转写已完成';
  }
  return _remoteStatusLabel(detail.recording.status);
}

String? _recordingAssetHandoffPhase(
  RecordingDetail? detail, {
  required bool assetReady,
}) {
  if (detail == null || !detail.hasFinalTranscriptFact || assetReady) {
    return null;
  }
  return detail.canonicalNoteId == null ? '正在创建资产' : '正在存入资产';
}

bool _isFailureRemoteStatus(RecordingRemoteStatus status) {
  return status == RecordingRemoteStatus.failed ||
      status == RecordingRemoteStatus.timeout ||
      status == RecordingRemoteStatus.cancelled;
}

String _remoteStatusLabel(RecordingRemoteStatus status) {
  return switch (status) {
    RecordingRemoteStatus.queued => '已排队',
    RecordingRemoteStatus.uploading => '正在上传',
    RecordingRemoteStatus.uploaded => '已上传',
    RecordingRemoteStatus.processing => '处理中',
    RecordingRemoteStatus.asrRunning => '正在转写',
    RecordingRemoteStatus.speakerLabelPending => '正在整理转写',
    RecordingRemoteStatus.generatingMinutes => '正在生成纲要',
    RecordingRemoteStatus.generatingSummary => '正在生成深度洞察',
    RecordingRemoteStatus.depositing => '正在归档',
    RecordingRemoteStatus.deposited => '已归档',
    RecordingRemoteStatus.completed => '已完成',
    RecordingRemoteStatus.failed => '处理失败',
    RecordingRemoteStatus.timeout => '处理超时',
    RecordingRemoteStatus.cancelled => '已取消',
  };
}
