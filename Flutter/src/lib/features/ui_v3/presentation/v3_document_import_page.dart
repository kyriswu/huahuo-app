import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/incoming_material_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../recordings/application/recording_batch_transcription_controller.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/domain/recording_batch_transcription.dart';
import '../../recordings/domain/recording_library.dart';
import '../application/v3_document_import_controller.dart';
import '../application/v3_material_upload_controller.dart';
import '../data/v3_document_import_store.dart';
import '../domain/document_import_progress.dart';
import 'v3_deposit_picker.dart';
import 'v3_material_import_surfaces.dart';

enum V3DocumentImportMode { document, media }

class V3DocumentImportPage extends ConsumerStatefulWidget {
  const V3DocumentImportPage({
    this.mode = V3DocumentImportMode.document,
    this.freshEntry = false,
    this.initialTaskId,
    this.digitalTwinEntry = false,
    super.key,
  });

  final V3DocumentImportMode mode;
  final bool freshEntry;
  final String? initialTaskId;
  final bool digitalTwinEntry;

  @override
  ConsumerState<V3DocumentImportPage> createState() =>
      _V3DocumentImportPageState();
}

class _V3DocumentImportPageState extends ConsumerState<V3DocumentImportPage>
    with AppActivityRouteAware<V3DocumentImportPage> {
  late final IncomingMaterialPort _incomingPort;
  StreamSubscription<void>? _incomingSubscription;
  Future<bool>? _incomingConsumeInFlight;
  List<IncomingMaterialDraft> _incoming = const <IncomingMaterialDraft>[];
  var _incomingLoading = false;
  var _incomingConfirming = false;
  var _audioImportedCount = 0;
  String? _incomingError;
  bool _distillToDigitalTwin = false;
  bool _entryReady = false;
  String? _entryUnavailableMessage;
  V3DocumentRecoveryOutcome? _recoveryOutcome;
  String? _scheduledResultKey;
  String? _openedResultKey;

  @override
  void initState() {
    super.initState();
    _distillToDigitalTwin = widget.digitalTwinEntry;
    _incomingPort = ref.read(incomingMaterialPortProvider);
    if (!widget.freshEntry && widget.initialTaskId == null) {
      _incomingSubscription = _incomingPort.pendingMaterials.listen(
        (_) => unawaited(_consumeIncoming()),
        onError: (_) {
          if (!mounted) return;
          setState(() => _incomingError = 'INCOMING_MATERIAL_UNAVAILABLE');
        },
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeEntry());
    });
  }

  @override
  void dispose() {
    _incomingSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(v3DocumentImportControllerProvider).state;
    final audioState = ref.watch(v3MaterialUploadControllerProvider).state;
    if (!_entryReady) {
      return V3MaterialImportRouteSheet(
        title: widget.mode == V3DocumentImportMode.media ? '导入录音音频' : '从文件导入',
        confirmLabel: '确定',
        confirmEnabled: false,
        onClose: _returnToPrevious,
        onConfirm: () {},
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_entryUnavailableMessage != null ||
        (widget.initialTaskId != null &&
            _recoveryOutcome != V3DocumentRecoveryOutcome.restored)) {
      return V3MaterialImportRouteSheet(
        title: '导入任务',
        confirmLabel: '关闭',
        onClose: _returnToPrevious,
        onConfirm: _returnToPrevious,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.task_alt_rounded, size: 42),
              const SizedBox(height: 14),
              Text(
                _entryUnavailableMessage ?? '该导入任务已结束或当前不可恢复',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '可以关闭此窗口，并在资产或消息中心查看最新结果。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final hasIncoming = _incoming.isNotEmpty;
    final mediaMode = widget.mode == V3DocumentImportMode.media;
    if (mediaMode && !hasIncoming && !_incomingLoading) {
      final recordingUploadState = ref
          .watch(recordingUploadControllerProvider)
          .state;
      _scheduleAudioResultHandoff(audioState);
      return _buildAudioImport(audioState, recordingUploadState);
    }
    if (!hasIncoming && !_incomingLoading) {
      _scheduleDocumentResultHandoff(state);
    }
    final isBusy =
        state.status == V3DocumentImportStatus.preparing ||
        state.status == V3DocumentImportStatus.importing ||
        _incomingLoading ||
        _incomingConfirming;
    final selectedName = state.selectedDocuments.isEmpty
        ? null
        : state.selectedDocuments.first.displayName;
    final distillationLocked =
        state.durableTasks.isNotEmpty &&
        state.durableTasks.every((task) => task.acceptedForImport);
    if (!mediaMode &&
        !hasIncoming &&
        !_incomingLoading &&
        (state.hasWaitingTasks ||
            state.durableTasks.any(
              (task) =>
                  task.acceptedForImport &&
                  task.status == V3DocumentImportTaskStatus.failed,
            ) ||
            (state.durableTasks.length > 1 &&
                state.durableTasks.any((task) => task.acceptedForImport)))) {
      return V3MaterialImportRouteSheet(
        title: '材料导入结果',
        confirmLabel: isBusy
            ? '处理中'
            : state.hasRetryableTasks
            ? state.hasWaitingTasks
                  ? '继续查询未完成项'
                  : '重试未完成项'
            : state.durableTasks.any((task) => !task.isCompleted)
            ? '重新选择文件'
            : '完成',
        confirmEnabled: !isBusy,
        onClose: _returnToPrevious,
        onConfirm: state.hasRetryableTasks
            ? _retryImport
            : state.durableTasks.any((task) => !task.isCompleted)
            ? _pickDocuments
            : _returnToPrevious,
        child: V3DocumentImportResults(
          tasks: state.durableTasks,
          onReturnInBackground: _returnToPrevious,
          onReview: (task) => context.push(
            Uri(
              path: AppRoutePaths.digitalTwin,
              queryParameters: {'importTaskId': task.id},
            ).toString(),
          ),
          onOpenNote: (task) => context.push(
            AppRoutePaths.feedItem(task.noteId ?? task.remoteNoteId!),
          ),
        ),
      );
    }
    if (isBusy || state.status == V3DocumentImportStatus.completed) {
      final activeTasks = state.durableTasks.where(
        (task) => task.status == V3DocumentImportTaskStatus.processing,
      );
      final phase = activeTasks.isEmpty
          ? V3DocumentImportPhase.preparingFile
          : activeTasks.first.phase;
      return V3MaterialImportProgressSurface(
        sourceLabel:
            selectedName ??
            (_incoming.isEmpty
                ? (mediaMode ? '录音音频' : '本地文件')
                : _incoming.first.displayName),
        sourceIcon: mediaMode
            ? Icons.audio_file_outlined
            : Icons.description_outlined,
        sourceAccent: HuahuoV3Theme.tokensOf(context).text,
        title: state.status == V3DocumentImportStatus.completed
            ? '导入完成'
            : mediaMode
            ? '录音转写中...'
            : '${phase.label}中…',
        message: state.status == V3DocumentImportStatus.completed
            ? '已生成 ${state.importedCount + _audioImportedCount} 条笔记。'
            : mediaMode
            ? '正在转写并整理内容，处理时间取决于录音时长。'
            : phase.message,
        onBack: _returnToPrevious,
        canReturnViaNotifications:
            state.status == V3DocumentImportStatus.importing &&
            state.durableTasks.any((task) => task.acceptedForImport),
      );
    }
    final terminalFailure = state.isTerminalFailure;
    final String confirmLabel;
    final VoidCallback onConfirm;
    if (terminalFailure) {
      if (hasIncoming) {
        confirmLabel = '关闭';
        onConfirm = _cancelIncoming;
      } else if (widget.initialTaskId != null) {
        confirmLabel = '关闭';
        onConfirm = _returnToPrevious;
      } else {
        confirmLabel = '重新选择';
        onConfirm = _pickDocuments;
      }
    } else if (hasIncoming) {
      confirmLabel = '确定';
      onConfirm = _confirmIncoming;
    } else if (state.status == V3DocumentImportStatus.failed &&
        state.hasRetryableTasks) {
      confirmLabel = state.hasWaitingTasks ? '继续查询' : '重试';
      onConfirm = _retryImport;
    } else if (state.status == V3DocumentImportStatus.failed &&
        state.hasUnacceptedTasks) {
      confirmLabel = '重试提交';
      onConfirm = _startAnalysis;
    } else if (state.selectedDocuments.isEmpty) {
      confirmLabel = '确定';
      onConfirm = _pickDocuments;
    } else {
      confirmLabel = '确定';
      onConfirm = _startAnalysis;
    }
    return V3MaterialImportRouteSheet(
      title: hasIncoming
          ? '确认导入'
          : mediaMode
          ? '导入录音音频'
          : '从文件导入',
      confirmLabel: confirmLabel,
      confirmEnabled: !isBusy,
      onClose: hasIncoming ? _cancelIncoming : _returnToPrevious,
      onConfirm: onConfirm,
      child: hasIncoming
          ? SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _IncomingConfirmationCard(materials: _incoming),
                  const SizedBox(height: 16),
                  V3DigitalTwinDistillationOption(
                    optionKey: const ValueKey(
                      'incoming-import-distillation-option',
                    ),
                    checked: _distillToDigitalTwin,
                    onChanged: (value) =>
                        setState(() => _distillToDigitalTwin = value),
                  ),
                  const SizedBox(height: 6),
                  V3DigitalTwinDistillationHelpLink(
                    helpKey: const ValueKey(
                      'incoming-import-distillation-help',
                    ),
                    onTap: () => showV3DistillationHelpSheet(context),
                  ),
                ],
              ),
            )
          : V3FileImportSheetContent(
              kind: mediaMode
                  ? V3FileImportKind.media
                  : V3FileImportKind.document,
              selectedFileName: selectedName,
              distillToDigitalTwin: _distillToDigitalTwin,
              onDistillationChanged: distillationLocked
                  ? null
                  : (value) => setState(() => _distillToDigitalTwin = value),
              onDistillationHelp: () => showV3DistillationHelpSheet(context),
              errorText: _incomingError != null
                  ? '外部文件未导入：$_incomingError'
                  : state.hasWaitingTasks
                  ? documentImportErrorMessage('DOCUMENT_INGESTION_TIMEOUT')
                  : state.status == V3DocumentImportStatus.failed
                  ? _errorMessage(state.lastErrorCode)
                  : null,
              onPick: _pickDocuments,
            ),
    );
  }

  Widget _buildAudioImport(
    V3MaterialUploadState state,
    RecordingUploadState recordingUploadState,
  ) {
    final isBusy =
        state.status == V3MaterialUploadStatus.loadingRecent ||
        state.status == V3MaterialUploadStatus.uploading;
    final selectedName = state.selectedItem?.displayName;
    final uploadProgress = state.transcriptionJobId == null
        ? null
        : recordingUploadState.progressForDraft(state.transcriptionJobId!);
    final uploadDetail =
        uploadProgress == null || uploadProgress.totalBytes <= 0
        ? null
        : <String>[
            '${_formatBytes(uploadProgress.bytesSent)} / '
                '${_formatBytes(uploadProgress.totalBytes)}',
            if (uploadProgress.bytesPerSecond > 0)
              '${_formatBytes(uploadProgress.bytesPerSecond.round())}/s',
            if (uploadProgress.estimatedRemainingSeconds != null)
              '剩余 ${_formatUploadEta(uploadProgress.estimatedRemainingSeconds!)}',
          ].join(' · ');
    if (isBusy || state.status == V3MaterialUploadStatus.completed) {
      return V3MaterialImportProgressSurface(
        sourceLabel: selectedName ?? '录音音频',
        sourceIcon: Icons.audio_file_outlined,
        sourceAccent: HuahuoV3Theme.tokensOf(context).text,
        title: state.status == V3MaterialUploadStatus.completed
            ? '录音已上传'
            : '录音上传中...',
        message: state.status == V3MaterialUploadStatus.completed
            ? '录音已提交转写，正在打开识别结果。'
            : uploadDetail ?? '正在准备录音上传，完成后会自动创建转写任务。',
        onBack: _returnToPrevious,
        canReturnViaNotifications:
            state.status == V3MaterialUploadStatus.uploading &&
            state.transcriptionJobId != null,
      );
    }
    final hasSelection = state.selectedItem != null;
    return V3MaterialImportRouteSheet(
      title: '导入录音音频',
      confirmLabel:
          hasSelection && state.status == V3MaterialUploadStatus.failed
          ? '重试'
          : '确定',
      confirmEnabled: !isBusy,
      onClose: _returnToPrevious,
      onConfirm: hasSelection ? _startAudioImport : _pickAudio,
      child: V3FileImportSheetContent(
        kind: V3FileImportKind.media,
        selectedFileName: selectedName,
        distillToDigitalTwin: _distillToDigitalTwin,
        onDistillationChanged: (value) =>
            setState(() => _distillToDigitalTwin = value),
        onDistillationHelp: () => showV3DistillationHelpSheet(context),
        errorText: state.status == V3MaterialUploadStatus.failed
            ? _audioErrorMessage(state.lastErrorCode)
            : _incomingError == null
            ? null
            : '外部文件未导入：$_incomingError',
        onPick: _pickAudio,
      ),
    );
  }

  void _returnToPrevious() {
    unawaited(
      returnToPreviousRoute(
        context,
        fallbackRoute: AppRoutePaths.home,
        result: true,
      ),
    );
  }

  Future<void> _pickDocuments() async {
    final controller = ref.read(v3DocumentImportControllerProvider);
    final picked = await controller.pickDocuments();
    if (!mounted ||
        !picked.ok ||
        picked.value == null ||
        picked.value!.isEmpty) {
      return;
    }
    _syncAcceptedDistillation(controller.state);
  }

  Future<void> _pickAudio() async {
    await ref.read(v3MaterialUploadControllerProvider).selectFromPicker();
  }

  Future<void> _startAudioImport() async {
    final controller = ref.read(v3MaterialUploadControllerProvider);
    final uploading = controller.uploadSelected(
      distillToDigitalTwin: _distillToDigitalTwin,
    );
    if (!mounted || !_isCurrentRoute) return;
    final jobId = controller.state.transcriptionJobId;
    if (jobId == null) {
      await uploading;
      return;
    }
    unawaited(uploading);
    _replaceWithResult(
      AppRoutePaths.transcriptionJob(
        jobId,
        source: RecordingFileSource.audioImport.routeValue,
      ),
      resultKey: 'recording-job:$jobId',
    );
  }

  Future<void> _initializeEntry() async {
    if (!mounted) return;
    if (widget.freshEntry) {
      if (widget.mode == V3DocumentImportMode.document) {
        final activated = await ref
            .read(v3DocumentImportControllerProvider)
            .beginFreshSession();
        if (!mounted) return;
        if (!activated) {
          setState(() {
            _entryUnavailableMessage = '导入入口已被更新，请关闭后重试';
            _entryReady = true;
          });
          return;
        }
      } else {
        final activated = ref
            .read(v3MaterialUploadControllerProvider)
            .beginFreshSession();
        if (!activated) {
          setState(() {
            _entryUnavailableMessage = '已有录音正在上传，请完成后再导入新的录音';
            _entryReady = true;
          });
          return;
        }
      }
      if (mounted) setState(() => _entryReady = true);
      return;
    }
    final controller = ref.read(v3DocumentImportControllerProvider);
    V3DocumentRecoveryOutcome? recoveryOutcome;
    if (widget.mode == V3DocumentImportMode.document) {
      recoveryOutcome = await controller.recoverPending(
        force: true,
        taskId: widget.initialTaskId,
      );
      if (mounted) _syncAcceptedDistillation(controller.state);
    }
    if (!mounted) return;
    if (widget.initialTaskId != null) {
      setState(() {
        _recoveryOutcome = recoveryOutcome;
        _entryReady = true;
      });
      return;
    }
    await _consumeIncoming();
    if (!mounted) return;
    setState(() => _entryReady = true);
  }

  Future<bool> _consumeIncoming() {
    final active = _incomingConsumeInFlight;
    if (active != null) return active;
    late final Future<bool> operation;
    operation = _consumeIncomingOnce().whenComplete(() {
      if (identical(_incomingConsumeInFlight, operation)) {
        _incomingConsumeInFlight = null;
      }
    });
    _incomingConsumeInFlight = operation;
    return operation;
  }

  Future<bool> _consumeIncomingOnce() async {
    if (!mounted) return false;
    setState(() {
      _incomingLoading = true;
      _incomingError = null;
    });
    final result = await _incomingPort.consumePendingMaterials();
    final errorResult = await _incomingPort.consumePendingMaterialErrors();
    if (!mounted) return false;
    setState(() {
      _incomingLoading = false;
      if (!result.ok) {
        _incomingError = result.error?.code ?? 'INCOMING_MATERIAL_FAILED';
      } else if (!errorResult.ok) {
        _incomingError =
            errorResult.error?.code ?? 'INCOMING_MATERIAL_ERROR_READ_FAILED';
      } else if (result.value!.isNotEmpty) {
        _incoming = result.value!;
      }
      if (errorResult.ok && errorResult.value!.isNotEmpty) {
        _incomingError = errorResult.value!.first;
      }
    });
    return _incoming.isNotEmpty;
  }

  Future<void> _confirmIncoming() async {
    if (_incomingConfirming || _incoming.isEmpty) return;
    setState(() {
      _incomingConfirming = true;
      _incomingError = null;
    });
    final materials = List<IncomingMaterialDraft>.from(_incoming);
    final audio = materials
        .where((draft) => draft.kind == IncomingMaterialKind.audio)
        .map((draft) => draft.toPickedAudio())
        .toList(growable: false);
    final documents = materials
        .where((draft) => draft.kind == IncomingMaterialKind.document)
        .map((draft) => draft.toPickedDocument())
        .toList(growable: false);
    final library = ref.read(recordingLibraryControllerProvider);
    final recordingUpload = ref.read(recordingUploadControllerProvider);
    final documentImport = ref.read(v3DocumentImportControllerProvider);
    final acceptedRefs = <String>{};
    String? firstAudioJobId;
    String? audioBatchId;
    String? singleImportedDocumentId;
    final importedAudio = await library.importPickedFilesDetailed(audio);
    _audioImportedCount = importedAudio.imported.length;
    if (importedAudio.imported.isNotEmpty) {
      acceptedRefs.addAll(
        materials
            .where((draft) => draft.kind == IncomingMaterialKind.audio)
            .take(importedAudio.imported.length)
            .map((draft) => draft.opaqueRef),
      );
      final dispatch = await _startExternalAudioTranscription(
        recordingUpload,
        importedAudio.imported,
      );
      firstAudioJobId = dispatch.singleJobId;
      audioBatchId = dispatch.batchId;
      if (firstAudioJobId == null && audioBatchId == null) {
        _incomingError ??= 'RECORDING_UPLOAD_FAILED';
      }
    }
    if (audio.isNotEmpty &&
        (!importedAudio.ok || _audioImportedCount != audio.length)) {
      _incomingError ??=
          importedAudio.error?.code ??
          library.state.lastErrorCode ??
          'RECORDING_IMPORT_FAILED';
    }
    if (documents.isNotEmpty) {
      final staged = await documentImport.prepareDocuments(documents);
      if (!staged) {
        _incomingError ??=
            documentImport.state.lastErrorCode ??
            'DOCUMENT_IMPORT_STAGE_FAILED';
      } else {
        final importedDocuments = await documentImport.importSelected(
          distillToDigitalTwin: _distillToDigitalTwin,
          deferDigitalTwinDistillation: true,
        );
        final requestedDocumentRefs = documents
            .map((document) => document.pickerRef)
            .toSet();
        final acceptedDocumentRefs = documentImport.completedPickerRefs(
          requestedDocumentRefs,
        );
        acceptedRefs.addAll(
          documents
              .where(
                (document) => acceptedDocumentRefs.contains(document.pickerRef),
              )
              .map((document) => document.pickerRef),
        );
        if (acceptedDocumentRefs.length != documents.length) {
          _incomingError ??=
              documentImport.state.lastErrorCode ?? 'DOCUMENT_IMPORT_FAILED';
        } else if (documents.length == 1 && importedDocuments.length == 1) {
          singleImportedDocumentId = importedDocuments.single.id;
        }
      }
    }
    if (acceptedRefs.isNotEmpty) {
      final acknowledged = await _incomingPort.acknowledgePendingMaterials(
        acceptedRefs,
      );
      if (!acknowledged.ok) {
        _incomingError =
            acknowledged.error?.code ?? 'INCOMING_MATERIAL_ACK_FAILED';
      } else {
        _incoming = materials
            .where((material) => !acceptedRefs.contains(material.opaqueRef))
            .toList(growable: false);
      }
    }
    if (!mounted) return;
    setState(() => _incomingConfirming = false);
    if (!_isCurrentRoute) return;
    if (audioBatchId != null && documents.isEmpty) {
      context.replace(AppRoutePaths.transcriptionBatch(audioBatchId));
    } else if (firstAudioJobId != null && documents.isEmpty) {
      context.replace(
        AppRoutePaths.transcriptionJob(
          firstAudioJobId,
          source: RecordingFileSource.audioImport.routeValue,
        ),
      );
    } else if (singleImportedDocumentId != null && _incomingError == null) {
      context.replace(AppRoutePaths.feedItem(singleImportedDocumentId));
    }
  }

  Future<({String? batchId, String? singleJobId})>
  _startExternalAudioTranscription(
    RecordingUploadController upload,
    Iterable<RecordingLibraryItem> importedItems,
  ) async {
    final items = List<RecordingLibraryItem>.unmodifiable(importedItems);
    if (items.isEmpty) {
      return (batchId: null, singleJobId: null);
    }
    if (_distillToDigitalTwin) {
      final queued = await ref
          .read(digitalTwinMaterialControllerProvider)
          .enqueueRecordingJobs({
            for (final item in items)
              recordingFileJobId(item): item.displayName,
          });
      if (!queued) {
        if (mounted) setState(() => _incomingError = '音频材料排队未保存，请重试');
        return (batchId: null, singleJobId: null);
      }
    }
    if (items.length == 1) {
      final item = items.single;
      final jobId = recordingFileJobId(item);
      unawaited(
        upload.uploadLocalRecording(
          item: item,
          sourceScene: 'raw_material',
          fileSource: RecordingFileSource.audioImport,
          title: item.displayName,
        ),
      );
      return (batchId: null, singleJobId: jobId);
    }

    final batchController = ref.read(
      recordingBatchTranscriptionControllerProvider,
    );
    final candidateFactory = ref.read(
      recordingTranscriptionCandidateFactoryProvider,
    );
    try {
      final preview = await batchController.previewSelection(
        items.map(candidateFactory.fromLibraryItem),
      );
      final dispatch = await batchController.startPreview(preview);
      switch (dispatch.kind) {
        case RecordingTranscriptionDispatchKind.disabled:
          return (batchId: null, singleJobId: null);
        case RecordingTranscriptionDispatchKind.batch:
          return (batchId: dispatch.batch?.batchId, singleJobId: null);
        case RecordingTranscriptionDispatchKind.single:
          final preflight = dispatch.single;
          if (preflight == null) {
            return (batchId: null, singleJobId: null);
          }
          RecordingLibraryItem? item;
          for (final candidate in items) {
            if (candidate.recordingId == preflight.candidate.localRecordingId) {
              item = candidate;
              break;
            }
          }
          if (item == null) {
            return (batchId: null, singleJobId: null);
          }
          if (preflight.classification ==
              RecordingTranscriptionClassification.eligible) {
            unawaited(
              upload.uploadLocalRecording(
                item: item,
                sourceScene: 'raw_material',
                fileSource: RecordingFileSource.audioImport,
                title: item.displayName,
              ),
            );
          }
          return (batchId: null, singleJobId: preflight.candidate.jobId);
      }
    } on RecordingBatchTranscriptionException {
      return (batchId: null, singleJobId: null);
    }
  }

  Future<void> _cancelIncoming() async {
    final materials = List<IncomingMaterialDraft>.from(_incoming);
    final result = await _incomingPort.acknowledgePendingMaterials(
      materials.map((material) => material.opaqueRef),
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _incomingError = result.error?.code ?? 'INCOMING_MATERIAL_ACK_FAILED';
      });
      return;
    }
    setState(() {
      _incoming = const <IncomingMaterialDraft>[];
      _incomingError = null;
    });
    if (!_isCurrentRoute) return;
    _returnToPrevious();
  }

  Future<void> _retryImport() async {
    final controller = ref.read(v3DocumentImportControllerProvider);
    final imported = await controller.retryFailed();
    if (!mounted) return;
    if (!_isCurrentRoute) return;
    if (controller.state.status == V3DocumentImportStatus.completed &&
        controller.state.durableTasks.length == 1 &&
        imported.length == 1) {
      _replaceWithResult(
        _documentResultLocation(controller.state, imported.single.id),
        resultKey: 'note:${imported.single.id}',
      );
      return;
    }
    setState(() {});
  }

  void _syncAcceptedDistillation(V3DocumentImportState state) {
    final tasks = state.durableTasks;
    if (tasks.isEmpty || !tasks.every((task) => task.acceptedForImport)) return;
    final persistedValue = tasks.any((task) => task.distillToDigitalTwin);
    if (_distillToDigitalTwin == persistedValue) return;
    setState(() => _distillToDigitalTwin = persistedValue);
  }

  Future<void> _startAnalysis() async {
    final controller = ref.read(v3DocumentImportControllerProvider);
    final imported = await controller.importSelected(
      distillToDigitalTwin: _distillToDigitalTwin,
      deferDigitalTwinDistillation: true,
    );
    if (!mounted) return;
    if (!_isCurrentRoute) return;
    if (controller.state.status == V3DocumentImportStatus.completed &&
        controller.state.durableTasks.length == 1 &&
        imported.length == 1) {
      _replaceWithResult(
        _documentResultLocation(controller.state, imported.single.id),
        resultKey: 'note:${imported.single.id}',
      );
      return;
    }
    setState(() {});
  }

  void _scheduleDocumentResultHandoff(V3DocumentImportState state) {
    final expectedTaskId = widget.initialTaskId;
    if (expectedTaskId != null &&
        !state.durableTasks.any((task) => task.id == expectedTaskId)) {
      return;
    }
    if (state.status != V3DocumentImportStatus.completed ||
        state.durableTasks.length != 1 ||
        state.importedNotes.length != 1) {
      return;
    }
    final noteId = state.importedNotes.single.id;
    final resultKey = 'note:$noteId';
    if (_openedResultKey == resultKey || _scheduledResultKey == resultKey) {
      return;
    }
    _scheduledResultKey = resultKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isCurrentRoute) {
        if (_scheduledResultKey == resultKey) _scheduledResultKey = null;
        return;
      }
      final current = ref.read(v3DocumentImportControllerProvider).state;
      if (current.status != V3DocumentImportStatus.completed ||
          current.durableTasks.length != 1 ||
          current.importedNotes.length != 1 ||
          current.importedNotes.single.id != noteId) {
        if (_scheduledResultKey == resultKey) _scheduledResultKey = null;
        return;
      }
      _replaceWithResult(
        _documentResultLocation(current, noteId),
        resultKey: resultKey,
      );
    });
  }

  String _documentResultLocation(V3DocumentImportState state, String noteId) {
    final task = state.durableTasks
        .where(
          (task) =>
              task.noteId == noteId &&
              task.distillToDigitalTwin &&
              (task.deferDigitalTwinDistillation ||
                  (task.distillationTaskId != null &&
                      task.distillationResourceId != null)) &&
              task.remoteNoteId != null,
        )
        .firstOrNull;
    if (task == null) return AppRoutePaths.feedItem(noteId);
    return Uri(
      path: AppRoutePaths.digitalTwin,
      queryParameters: {'importTaskId': task.id},
    ).toString();
  }

  void _scheduleAudioResultHandoff(V3MaterialUploadState state) {
    final jobId = state.transcriptionJobId?.trim() ?? '';
    if (jobId.isEmpty) return;
    final resultKey = 'recording-job:$jobId';
    if (_openedResultKey == resultKey || _scheduledResultKey == resultKey) {
      return;
    }
    _scheduledResultKey = resultKey;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_isCurrentRoute) {
        if (_scheduledResultKey == resultKey) _scheduledResultKey = null;
        return;
      }
      final current = ref.read(v3MaterialUploadControllerProvider).state;
      if (current.transcriptionJobId != jobId) {
        if (_scheduledResultKey == resultKey) _scheduledResultKey = null;
        return;
      }
      _replaceWithResult(
        AppRoutePaths.transcriptionJob(
          jobId,
          source: RecordingFileSource.audioImport.routeValue,
        ),
        resultKey: resultKey,
      );
    });
  }

  void _replaceWithResult(String route, {required String resultKey}) {
    if (!mounted || !_isCurrentRoute || _openedResultKey == resultKey) return;
    _scheduledResultKey = null;
    _openedResultKey = resultKey;
    context.replace(route);
  }

  bool get _isCurrentRoute => ModalRoute.of(context)?.isCurrent == true;

  @override
  void onActivityRouteBecameActive() {
    if (!_entryReady ||
        (widget.initialTaskId != null &&
            _recoveryOutcome != V3DocumentRecoveryOutcome.restored)) {
      return;
    }
    if (widget.mode == V3DocumentImportMode.media) {
      _scheduleAudioResultHandoff(
        ref.read(v3MaterialUploadControllerProvider).state,
      );
      return;
    }
    _scheduleDocumentResultHandoff(
      ref.read(v3DocumentImportControllerProvider).state,
    );
  }
}

class _IncomingConfirmationCard extends StatelessWidget {
  const _IncomingConfirmationCard({required this.materials});

  final List<IncomingMaterialDraft> materials;

  @override
  Widget build(BuildContext context) => V3Card(
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '确认导入外部文件',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Text(
          '文件尚未上传或分析，确认后才会进入无限花火。',
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).muted,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 14),
        for (final material in materials) ...[
          Row(
            children: [
              Icon(
                material.kind == IncomingMaterialKind.audio
                    ? Icons.audio_file_outlined
                    : Icons.description_outlined,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      material.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${material.mimeType} · ${_formatBytes(material.sizeBytes)}',
                      style: TextStyle(
                        color: HuahuoV3Theme.tokensOf(context).muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ],
    ),
  );
}

String _errorMessage(String? code) => documentImportErrorMessage(code);

String _documentTaskMessage(V3DocumentImportTask task) {
  if (task.isCompleted) return '笔记已保存';
  if (task.status == V3DocumentImportTaskStatus.failed ||
      task.status == V3DocumentImportTaskStatus.waiting) {
    return '${task.phase.label}：${documentImportErrorMessage(task.lastErrorCode)}';
  }
  return task.status == V3DocumentImportTaskStatus.staged
      ? '文件已准备，等待确认导入'
      : '${task.phase.label}：${task.phase.message}';
}

String _audioErrorMessage(String? code) => switch (code) {
  'RECORDING_IMPORT_SINGLE_REQUIRED' => '一次请选择一段录音。',
  'RECORDING_PICKER_EMPTY' => '没有选择录音，请重新选择。',
  'RECORDING_IMPORT_FAILED' => '录音未能保存到 App 私有目录，请重试。',
  'RECORDING_UPLOAD_NOT_READY' => '录音文件尚未准备好，请重新选择。',
  'RECORDING_UPLOAD_FAILED' => '录音上传或转写任务创建失败，请重试。',
  _ => '录音导入未完成，请重试。',
};

String _formatBytes(int sizeBytes) {
  if (sizeBytes < 1024) return '$sizeBytes B';
  if (sizeBytes < 1024 * 1024) {
    return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatUploadEta(int seconds) {
  final safeSeconds = seconds < 0 ? 0 : seconds;
  if (safeSeconds < 60) return '${safeSeconds}s';
  final minutes = safeSeconds ~/ 60;
  final remainingSeconds = safeSeconds % 60;
  if (minutes < 60) {
    return remainingSeconds == 0
        ? '${minutes}min'
        : '${minutes}min ${remainingSeconds}s';
  }
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return remainingMinutes == 0
      ? '${hours}h'
      : '${hours}h ${remainingMinutes}min';
}

class V3DocumentImportResults extends StatelessWidget {
  const V3DocumentImportResults({
    required this.tasks,
    this.onReturnInBackground,
    required this.onReview,
    required this.onOpenNote,
    super.key,
  });

  final List<V3DocumentImportTask> tasks;
  final VoidCallback? onReturnInBackground;
  final ValueChanged<V3DocumentImportTask> onReview;
  final ValueChanged<V3DocumentImportTask> onOpenNote;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
    children: [
      if (tasks.any(
        (task) =>
            task.acceptedForImport &&
            (task.status == V3DocumentImportTaskStatus.processing ||
                task.status == V3DocumentImportTaskStatus.waiting),
      )) ...[
        V3LongRunningTaskNotice(onReturn: onReturnInBackground),
        const SizedBox(height: 12),
      ],
      const Text('每份材料独立处理。成功项可立即查看；数字孪生候选经确认后才会成为正式内容。'),
      const SizedBox(height: 12),
      for (final task in tasks)
        Padding(
          key: ValueKey('document-import-result-${task.id}'),
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.displayName,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(_documentTaskMessage(task)),
              if (task.lastErrorCode != null && !task.isCompleted)
                Text(
                  '错误码：${RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(task.lastErrorCode!) ? task.lastErrorCode : 'DOCUMENT_IMPORT_FAILED'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (task.remoteNoteId != null)
                Wrap(
                  spacing: 8,
                  children: [
                    if (task.distillToDigitalTwin &&
                        (task.deferDigitalTwinDistillation ||
                            (task.distillationTaskId != null &&
                                task.distillationResourceId != null)))
                      TextButton(
                        key: ValueKey('document-import-review-${task.id}'),
                        onPressed: () => onReview(task),
                        child: Text(
                          task.deferDigitalTwinDistillation
                              ? '查看待确认材料'
                              : '查看候选与进度',
                        ),
                      ),
                    TextButton(
                      key: ValueKey('document-import-note-${task.id}'),
                      onPressed: () => onOpenNote(task),
                      child: const Text('查看笔记'),
                    ),
                  ],
                ),
            ],
          ),
        ),
    ],
  );
}
