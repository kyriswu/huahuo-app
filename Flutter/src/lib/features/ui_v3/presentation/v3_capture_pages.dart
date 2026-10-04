// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../shared/navigation/capture_leave_guard.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_chat_mark.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../recordings/application/monologue_recording_controller.dart';
import '../../recordings/application/recording_waveform_controller.dart';
import '../../recordings/domain/recording_library.dart';
import '../../transcription/application/live_transcript_controller.dart';
import '../../transcription/presentation/live_transcription_failure_dialog.dart';
import '../application/knowledge_library_controller.dart';
import 'v3_deposit_picker.dart';
import 'v3_material_import_surfaces.dart';
import 'v3_note_chat.dart';
import 'widgets/v3_monologue_transcript_window.dart' as monologue_ui;
import 'widgets/v3_recording_waveform_builder.dart';

export 'widgets/v3_monologue_transcript_window.dart';

class V3RecordSourcePage extends StatefulWidget {
  const V3RecordSourcePage({super.key});

  @override
  State<V3RecordSourcePage> createState() => _V3RecordSourcePageState();
}

class _V3RecordSourcePageState extends State<V3RecordSourcePage> {
  V3RecordingImportMode _selected = V3RecordingImportMode.external;
  bool _distillToDigitalTwin = false;

  @override
  Widget build(BuildContext context) {
    return V3MaterialImportRouteSheet(
      title: '录音导入',
      confirmLabel: '确定',
      onClose: _close,
      onConfirm: () {
        context.replace(
          AppRoutePaths.recordingCapture(
            external: _selected == V3RecordingImportMode.external,
            freshEntry: true,
            distillToDigitalTwin: _distillToDigitalTwin,
          ),
        );
      },
      child: V3RecordingImportSheetContent(
        selected: _selected,
        onSelected: (value) => setState(() => _selected = value),
        distillToDigitalTwin: _distillToDigitalTwin,
        onDistillationChanged: (value) =>
            setState(() => _distillToDigitalTwin = value),
        onDistillationHelp: () => showV3DistillationHelpSheet(context),
      ),
    );
  }

  void _close() {
    unawaited(
      returnToPreviousRoute(context, fallbackRoute: AppRoutePaths.home),
    );
  }
}

class V3MonologuePage extends ConsumerStatefulWidget {
  const V3MonologuePage({super.key});

  @override
  ConsumerState<V3MonologuePage> createState() => _V3MonologuePageState();
}

class _V3MonologuePageState extends ConsumerState<V3MonologuePage> {
  late final TextEditingController _transcriptController;
  String? _scheduledNoteId;
  final LiveTranscriptionFailureDialogGate _recordingFailureDialogGate =
      LiveTranscriptionFailureDialogGate();
  final LiveTranscriptionFailureDialogGate _previewFailureDialogGate =
      LiveTranscriptionFailureDialogGate();

  @override
  void initState() {
    super.initState();
    _transcriptController = TextEditingController();
    ref.listenManual<MonologueRecordingState>(
      monologueRecordingControllerProvider.select(
        (controller) => controller.state,
      ),
      (previous, next) {
        if (!mounted) return;
        if (_transcriptController.text != next.transcriptText) {
          _transcriptController.value = TextEditingValue(
            text: next.transcriptText,
            selection: TextSelection.collapsed(
              offset: next.transcriptText.length,
            ),
          );
        }
        final noteId = next.localNoteId;
        if (next.status == MonologueRecordingStatus.completed &&
            noteId != null &&
            noteId != _scheduledNoteId) {
          _scheduledNoteId = noteId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
            context.replace(AppRoutePaths.feedItem(noteId, stage: 'raw'));
          });
        }
        final liveError = next.liveTranscriptErrorCode;
        if (liveError != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              unawaited(
                _showLiveTranscriptFailure(
                  liveError,
                  wasTranscribing: monologue_ui.monologueFailureWasTranscribing(
                    previous,
                    next,
                  ),
                  attemptId: next.liveTranscriptAttemptId,
                  correlationId: next.correlationId,
                ),
              );
            }
          });
        }
        if (next.status == MonologueRecordingStatus.failed &&
            previous?.status != MonologueRecordingStatus.failed &&
            next.lastErrorCode != null &&
            next.failureStage != MonologueFailureStage.permission &&
            next.failureStage != MonologueFailureStage.nativeStart &&
            next.failureStage != MonologueFailureStage.liveTranscription) {
          showV3Snack(
            context,
            monologue_ui.monologueRecordingFailureMessage(
              next.failureStage,
              next.lastErrorCode!,
            ),
          );
        }
        if (next.localItem != previous?.localItem) {
          unawaited(ref.read(recordingLibraryControllerProvider).load());
        }
      },
    );
    scheduleMicrotask(
      () => ref.read(recordingLibraryControllerProvider).load(),
    );
  }

  @override
  void dispose() {
    _transcriptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final recording = ref.watch(monologueRecordingControllerProvider).state;
    final sharedLiveTranscript = ref
        .watch(liveTranscriptControllerProvider)
        .state;
    final recorder = ref.read(monologueRecordingControllerProvider);
    final liveTranscript = recorder.visibleLiveTranscriptState(
      sharedLiveTranscript,
    );
    if (recording.status == MonologueRecordingStatus.stopping ||
        recording.status == MonologueRecordingStatus.registeringLocal ||
        recording.status == MonologueRecordingStatus.savingNote) {
      return V3MaterialImportProgressSurface(
        sourceLabel: recording.localItem?.displayName ?? '独白录音.m4a',
        sourceIcon: Icons.audio_file_outlined,
        sourceAccent: colors.ink,
        title: recording.status == MonologueRecordingStatus.savingNote
            ? '正在保存独白笔记...'
            : '正在保存独白录音...',
        message: '实时转写已经完成，正在保存录音副本和笔记。',
        onBack: () {
          unawaited(returnToPreviousRoute(context, fallbackRoute: '/v3/feed'));
        },
      );
    }

    return CaptureLeaveGuard(
      state: _monologueLeaveState(recording),
      fallbackRoute: '/v3/feed',
      onEndAndLeave: recorder.endCaptureForLeave,
      stateResolver: () {
        final current = ref.read(monologueRecordingControllerProvider);
        return _monologueLeaveState(current.state);
      },
      child: Builder(
        builder: (guardContext) => V3MonologueCaptureSurface(
          recording: recording,
          waveform: recorder.waveform,
          liveTranscript: liveTranscript,
          transcriptController: _transcriptController,
          hasHistory: false,
          onBack: () => unawaited(CaptureLeaveGuard.requestLeave(guardContext)),
          onHistory: () {},
          onDone: recording.isBusy
              ? null
              : recording.canFinish
              ? () => unawaited(recorder.stop())
              : recording.canRetry
              ? () => unawaited(recorder.retry())
              : recording.status == MonologueRecordingStatus.completed &&
                    recording.localNoteId != null
              ? () => context.replace(
                  AppRoutePaths.feedItem(recording.localNoteId!, stage: 'raw'),
                )
              : () => unawaited(CaptureLeaveGuard.requestLeave(guardContext)),
          onStatusTap: recording.canPause
              ? () => unawaited(recorder.pause())
              : recording.canResume
              ? () => unawaited(recorder.resume())
              : null,
          onPrimaryTap: recording.canPause
              ? () => unawaited(recorder.pause())
              : recording.canResume
              ? () => unawaited(recorder.resume())
              : recording.canRetry
              ? () => unawaited(recorder.retry())
              : recording.status == MonologueRecordingStatus.completed
              ? () => unawaited(_startRecording(recorder))
              : recording.canStart
              ? () => unawaited(_startRecording(recorder))
              : null,
          onTranscriptChanged: recorder.updateTranscript,
          onOpenAsset: recording.localNoteId == null
              ? null
              : () => context.replace(
                  AppRoutePaths.feedItem(recording.localNoteId!, stage: 'raw'),
                ),
          supplementary: const SizedBox.shrink(),
        ),
      ),
    );
  }

  Future<void> _startRecording(MonologueRecordingController recorder) async {
    _recordingFailureDialogGate.beginAttempt();
    final started = await recorder.start();
    if (!mounted || started) return;
    final failure = recorder.state;
    final errorCode = failure.lastErrorCode;
    if (errorCode == null ||
        (failure.failureStage != MonologueFailureStage.permission &&
            failure.failureStage != MonologueFailureStage.nativeStart) ||
        !_recordingFailureDialogGate.claim(
          owner: 'monologue-recording',
          attemptId: null,
        )) {
      return;
    }
    late final LiveTranscriptionFailureDialogAction action;
    try {
      action = await showLiveTranscriptionFailureDialog(
        context: context,
        errorCode: errorCode,
        failureContext: LiveTranscriptionFailureContext.recording,
      );
    } finally {
      _recordingFailureDialogGate.release();
    }
    if (!mounted) return;
    if (action == LiveTranscriptionFailureDialogAction.openSettings) {
      unawaited(
        ref
            .read(platformPermissionsPortProvider)
            .openAppSettings(
              PlatformPermissionKind.microphone,
              impactAcknowledged: true,
            ),
      );
    } else if (action == LiveTranscriptionFailureDialogAction.retry) {
      unawaited(_startRecording(recorder));
    }
  }

  Future<void> _showLiveTranscriptFailure(
    String errorCode, {
    required bool wasTranscribing,
    required int? attemptId,
    required String? correlationId,
  }) async {
    if (!mounted ||
        !_previewFailureDialogGate.claim(
          owner: 'monologue:${correlationId ?? 'unallocated'}',
          attemptId: attemptId,
        )) {
      return;
    }
    late final LiveTranscriptionFailureDialogAction action;
    try {
      action = await showLiveTranscriptionFailureDialog(
        context: context,
        errorCode: errorCode,
        wasTranscribing: wasTranscribing,
        failureContext: LiveTranscriptionFailureContext.realtime,
      );
    } finally {
      _previewFailureDialogGate.release();
    }
    if (!mounted) return;
    if (action == LiveTranscriptionFailureDialogAction.openSettings) {
      unawaited(
        ref
            .read(platformPermissionsPortProvider)
            .openAppSettings(
              PlatformPermissionKind.microphone,
              impactAcknowledged: true,
            ),
      );
    } else if (action == LiveTranscriptionFailureDialogAction.retry) {
      _previewFailureDialogGate.beginAttempt();
      unawaited(
        ref
            .read(monologueRecordingControllerProvider)
            .retryLiveTranscriptPreview(),
      );
    }
  }
}

class V3MonologueCaptureSurface extends StatelessWidget {
  const V3MonologueCaptureSurface({
    required this.recording,
    this.waveform,
    required this.liveTranscript,
    required this.transcriptController,
    required this.hasHistory,
    required this.onBack,
    required this.onHistory,
    required this.onDone,
    required this.onStatusTap,
    required this.onPrimaryTap,
    this.onTranscriptChanged,
    this.onOpenAsset,
    required this.supplementary,
    super.key,
  });

  final MonologueRecordingState recording;
  final RecordingWaveformController? waveform;
  final LiveTranscriptState liveTranscript;
  final TextEditingController transcriptController;
  final bool hasHistory;
  final VoidCallback onBack;
  final VoidCallback onHistory;
  final VoidCallback? onDone;
  final VoidCallback? onStatusTap;
  final VoidCallback? onPrimaryTap;
  final ValueChanged<String>? onTranscriptChanged;
  final VoidCallback? onOpenAsset;
  final Widget supplementary;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final recoverableLiveFailure = recording.hasRecoverableLiveFailure;
    final captureActive =
        recording.isCaptureActive || recording.hasNativeCapture;
    final paused = recording.canResume;
    final busy = recording.isBusy;
    final failed = recording.status == MonologueRecordingStatus.failed;
    final statusLabel = recoverableLiveFailure
        ? '转写已暂停'
        : paused
        ? '已暂停'
        : recording.status == MonologueRecordingStatus.resuming
        ? '正在继续'
        : recording.status == MonologueRecordingStatus.pausing
        ? '正在暂停'
        : recording.status == MonologueRecordingStatus.recording
        ? '正在实时转写'
        : busy
        ? '正在处理'
        : recording.status == MonologueRecordingStatus.completed
        ? '笔记已保存'
        : failed
        ? '处理失败'
        : '准备开始';
    final statusColor = captureActive && !paused
        ? const Color(0xffc85a52)
        : paused
        ? const Color(0xffb87938)
        : failed
        ? colors.danger
        : colors.muted;
    final processing =
        recording.status == MonologueRecordingStatus.stopping ||
        recording.status == MonologueRecordingStatus.registeringLocal ||
        recording.status == MonologueRecordingStatus.savingNote;
    final headerActionLabel = processing
        ? '保存中'
        : recording.canFinish
        ? '完成'
        : recording.canRetry
        ? '重试'
        : recording.status == MonologueRecordingStatus.completed
        ? '查看'
        : '完成';

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Stack(
                children: [
                  Positioned(
                    left: 14,
                    top: 6,
                    child: V3NavigationBackButton(onPressed: onBack),
                  ),
                  Center(
                    child: Text(
                      '独白',
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 17,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (hasHistory && !captureActive)
                    Positioned(
                      right: 104,
                      top: 6,
                      child: IconButton(
                        key: const ValueKey<String>('monologue-history-button'),
                        tooltip: '独白历史',
                        onPressed: onHistory,
                        icon: const Icon(Icons.history_rounded),
                        iconSize: 22,
                      ),
                    ),
                  if (recording.canFinish ||
                      processing ||
                      recording.status == MonologueRecordingStatus.completed ||
                      (recording.status == MonologueRecordingStatus.failed &&
                          recording.canRetry))
                    Positioned(
                      right: 24,
                      top: 10,
                      child: SizedBox(
                        width: 84,
                        height: 40,
                        child: FilledButton(
                          onPressed: onDone,
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xff121316),
                            disabledBackgroundColor: const Color(
                              0xff121316,
                            ).withValues(alpha: .42),
                            shape: const StadiumBorder(),
                          ),
                          child: Text(
                            headerActionLabel,
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final editorHeight = (constraints.maxHeight * .36)
                      .clamp(190.0, 286.0)
                      .toDouble();
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: (constraints.maxHeight - 36)
                            .clamp(0.0, double.infinity)
                            .toDouble(),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Semantics(
                              button: onStatusTap != null,
                              label: paused ? '继续实时转写' : statusLabel,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: onStatusTap,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 3,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 7,
                                        height: 7,
                                        decoration: BoxDecoration(
                                          color: statusColor,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        statusLabel,
                                        style: TextStyle(
                                          color: colors.muted,
                                          fontSize: 13,
                                          height: 1.5,
                                          fontWeight: FontWeight.w400,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            key: const ValueKey<String>('monologue-duration'),
                            _v5MonologueDurationText(recording.elapsedSeconds),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 34,
                              height: 1.24,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 7),
                            child: V3RecordingWaveformBuilder(
                              source: waveform,
                              builder: (context, samples) =>
                                  _V5MonologueWaveform(
                                    active: recording.isNativeWriting,
                                    samples: samples,
                                  ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Text(
                                '实时转写',
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 14,
                                  height: 1.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                recording.canEditTranscript
                                    ? '可编辑'
                                    : recording.status ==
                                          MonologueRecordingStatus.recording
                                    ? '实时更新'
                                    : '',
                                style: TextStyle(
                                  color: colors.muted,
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          monologue_ui.V3MonologueTranscriptWindow(
                            state: liveTranscript,
                            sessionActive: monologue_ui
                                .monologueTranscriptSessionActive(recording),
                            liveTranscriptErrorCode:
                                recording.liveTranscriptErrorCode,
                            controller: transcriptController,
                            transcriptText: recording.transcriptText,
                            editable: recording.canEditTranscript,
                            onChanged: onTranscriptChanged,
                            flat: true,
                            height: editorHeight,
                          ),
                          if (paused || recording.canEditTranscript) ...[
                            const SizedBox(height: 9),
                            Text(
                              recoverableLiveFailure
                                  ? '实时转写已暂停，可修改文字后重试继续。'
                                  : recording.canResume
                                  ? '录音已暂停，可修改文字后重试继续。'
                                  : failed
                                  ? '录音已结束，可修改文字后重试保存笔记。'
                                  : '录音已暂停，可修改文字；继续后新内容会接在末尾。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: recoverableLiveFailure
                                    ? colors.danger
                                    : colors.muted,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          Center(
                            child:
                                recording.status ==
                                    MonologueRecordingStatus.completed
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 250,
                                        child: V3PrimaryButton(
                                          key: const ValueKey<String>(
                                            'monologue-primary-action',
                                          ),
                                          label: '再次独白',
                                          icon: Icons.mic_none_rounded,
                                          enabled: onPrimaryTap != null,
                                          onPressed: onPrimaryTap ?? () {},
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextButton.icon(
                                        key: const ValueKey<String>(
                                          'monologue-open-saved-note',
                                        ),
                                        onPressed: onOpenAsset,
                                        icon: const Icon(
                                          Icons.description_outlined,
                                          size: 18,
                                        ),
                                        label: const Text('查看已保存笔记'),
                                      ),
                                    ],
                                  )
                                : _V5MonologuePrimaryAction(
                                    active: captureActive,
                                    paused: paused,
                                    busy: busy,
                                    failed: failed,
                                    enabled: onPrimaryTap != null,
                                    onTap: onPrimaryTap,
                                  ),
                          ),
                          if (supplementary is! SizedBox ||
                              (supplementary as SizedBox).child != null) ...[
                            const SizedBox(height: 20),
                            supplementary,
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _v5MonologueDurationText(int totalSeconds) {
  final normalized = totalSeconds < 0 ? 0 : totalSeconds;
  final hours = normalized ~/ 3600;
  final minutes = (normalized % 3600) ~/ 60;
  final seconds = normalized % 60;
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  if (hours > 0) {
    return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}.0';
  }
  return '${twoDigits(minutes)}:${twoDigits(seconds)}.0';
}

class _V5MonologuePrimaryAction extends StatelessWidget {
  const _V5MonologuePrimaryAction({
    required this.active,
    required this.paused,
    required this.busy,
    required this.failed,
    required this.enabled,
    required this.onTap,
  });

  final bool active;
  final bool paused;
  final bool busy;
  final bool failed;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final label = busy
        ? '正在处理'
        : paused
        ? '继续转写'
        : failed
        ? '重试'
        : active
        ? '暂停转写'
        : '开始独白';
    return Semantics(
      button: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkResponse(
            key: const ValueKey<String>('monologue-primary-action'),
            radius: 46,
            onTap: enabled ? onTap : null,
            child: Opacity(
              opacity: enabled ? 1 : .45,
              child: AnimatedContainer(
                duration: V3MotionTokens.quick,
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: paused ? colors.surface : colors.primary,
                  shape: BoxShape.circle,
                  border: paused
                      ? Border.all(color: colors.line, width: 1.2)
                      : null,
                ),
                child: Center(
                  child: busy
                      ? SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(
                            color: colors.onPrimary,
                            strokeWidth: 2,
                          ),
                        )
                      : Icon(
                          paused
                              ? Icons.play_arrow_rounded
                              : failed
                              ? Icons.refresh_rounded
                              : active
                              ? Icons.pause_rounded
                              : Icons.mic_none_rounded,
                          size: paused ? 25 : 24,
                          color: paused ? colors.ink : colors.onPrimary,
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: TextStyle(
              color: colors.text,
              fontSize: 12.5,
              height: 1.4,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _V5MonologueWaveform extends StatelessWidget {
  const _V5MonologueWaveform({required this.active, required this.samples});

  final bool active;
  final List<double> samples;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _V5MonologueWavePainter(active: active, samples: samples),
      child: const SizedBox(height: 92, width: double.infinity),
    ),
  );
}

class _V5MonologueWavePainter extends CustomPainter {
  const _V5MonologueWavePainter({required this.active, required this.samples});

  final bool active;
  final List<double> samples;

  static const _fallback = <double>[
    .12,
    .25,
    .40,
    .28,
    .18,
    .42,
    .62,
    .34,
    .20,
    .50,
    .76,
    .45,
    .30,
    .58,
    .88,
    .48,
    .24,
    .66,
    .38,
    .20,
    .55,
    .35,
    .18,
    .42,
    .28,
    .16,
    .31,
    .22,
    .12,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = const Color(0xffe4e6e7)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      baseline,
    );
    const count = 29;
    for (var index = 0; index < count; index++) {
      final sampleIndex = samples.isEmpty
          ? 0
          : (index * (samples.length - 1) / (count - 1)).round();
      final sampled = samples.isEmpty ? 0.0 : samples[sampleIndex];
      final normalized = sampled.isFinite
          ? sampled.clamp(0.0, 1.0).toDouble()
          : 0.0;
      final level = normalized <= .01 ? _fallback[index] : normalized;
      final height = 10 + level * 70;
      final x = size.width * index / (count - 1);
      final paint = Paint()
        ..color = index == 14
            ? active
                  ? const Color(0xffc85a52)
                  : const Color(0xffffd8d4)
            : active
            ? const Color(0xffc4c9cc)
            : const Color(0xffedf0f0)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _V5MonologueWavePainter oldDelegate) =>
      oldDelegate.active != active || oldDelegate.samples != samples;
}

CaptureLeaveState _monologueLeaveState(MonologueRecordingState state) {
  if (state.status == MonologueRecordingStatus.failed &&
      (state.hasNativeCapture ||
          state.failureStage == MonologueFailureStage.liveTranscription)) {
    return CaptureLeaveState.capturing;
  }
  return switch (state.status) {
    MonologueRecordingStatus.checkingPermission ||
    MonologueRecordingStatus.starting ||
    MonologueRecordingStatus.recording ||
    MonologueRecordingStatus.pausing ||
    MonologueRecordingStatus.paused ||
    MonologueRecordingStatus.resuming => CaptureLeaveState.capturing,
    MonologueRecordingStatus.stopping ||
    MonologueRecordingStatus.registeringLocal ||
    MonologueRecordingStatus.savingNote => CaptureLeaveState.processing,
    MonologueRecordingStatus.idle ||
    MonologueRecordingStatus.completed ||
    MonologueRecordingStatus.failed => CaptureLeaveState.idle,
  };
}

String _monologueDurationText(int totalSeconds) {
  final normalized = totalSeconds < 0 ? 0 : totalSeconds;
  final hours = normalized ~/ 3600;
  final minutes = (normalized % 3600) ~/ 60;
  final seconds = normalized % 60;
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
}

class V3MonologueHistoryPage extends ConsumerStatefulWidget {
  const V3MonologueHistoryPage({super.key});

  @override
  ConsumerState<V3MonologueHistoryPage> createState() =>
      _V3MonologueHistoryPageState();
}

class _V3MonologueHistoryPageState
    extends ConsumerState<V3MonologueHistoryPage> {
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(
      () => ref.read(recordingLibraryControllerProvider).load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingLibraryControllerProvider).state;
    final items = state.items
        .where(isMonologueRecordingHistoryItem)
        .toList(growable: false);
    return V3PageScaffold(
      title: '独白历史',
      subtitle: '仅显示你的独白录音',
      fallbackRoute: '/v3/feed/monologue',
      backBehavior: V3BackBehavior.popThenFallback,
      children: [
        if (items.isEmpty)
          const _MonologueHistoryEmptyState()
        else
          for (final item in items) ...[
            V3Card(
              key: ValueKey<String>('monologue-history-${item.recordingId}'),
              variant: V3CardVariant.outlined,
              onTap: item.remoteRecordingId == null
                  ? null
                  : () => context.push(
                      '/v3/feed/transcription-done/'
                      '${Uri.encodeComponent(item.remoteRecordingId!)}',
                    ),
              child: Row(
                children: [
                  const Icon(Icons.mic_none_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _monologueHistoryMetadata(item),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.3,
                            color: HuahuoV3Theme.tokensOf(context).muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (item.remoteRecordingId != null)
                    const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

class _MonologueHistoryEmptyState extends StatelessWidget {
  const _MonologueHistoryEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: 76),
      child: Center(
        child: Text(
          '暂无独白记录',
          style: TextStyle(fontSize: 15, color: colors.muted),
        ),
      ),
    );
  }
}

String _monologueHistoryMetadata(RecordingLibraryItem item) {
  final createdAt = item.createdAt.toLocal();
  final date =
      '${createdAt.year.toString().padLeft(4, '0')}-'
      '${createdAt.month.toString().padLeft(2, '0')}-'
      '${createdAt.day.toString().padLeft(2, '0')} '
      '${createdAt.hour.toString().padLeft(2, '0')}:'
      '${createdAt.minute.toString().padLeft(2, '0')}';
  return '$date · ${_monologueDurationText(item.durationSeconds)}';
}

class V3TranscriptionDonePage extends ConsumerStatefulWidget {
  const V3TranscriptionDonePage({super.key});

  @override
  ConsumerState<V3TranscriptionDonePage> createState() =>
      _V3TranscriptionDonePageState();
}

class _V3TranscriptionDonePageState
    extends ConsumerState<V3TranscriptionDonePage> {
  late final TextEditingController _transcriptController;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _transcriptController = TextEditingController(
      text:
          '我们首先讨论了 ROI 的衡量方式。客户关注的不只是效率提升，而是业务结果的改善。我们建议从成本节约、收入增长、风险降低三个维度来设定可量化的指标，并在试点阶段就建立基线和验收标准。\n\n接着聊到组织协同问题。AI 落地不是单点工具上线，而是流程与角色的重塑。需要管理层明确方向，业务与 IT 共建场景，设立专人负责推进，并通过培训提升一线团队的使用能力。\n\n最后，我们重点讨论了数据安全与权限管理。客户担心数据外泄和合规风险。我们建议采用最小权限原则，分级分域管理数据，关键数据本地化处理，并建立审计日志与敏感操作告警机制，确保可追溯、可管控。',
    );
  }

  @override
  void dispose() {
    _transcriptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return V3PageScaffold(
      title: '转写完成',
      centerTitle: true,
      fallbackRoute: '/v3/feed',
      backBehavior: V3BackBehavior.fallbackOnly,
      trailing: IconButton(
        tooltip: '\u6c89\u6dc0\u5230...',
        icon: const Icon(Icons.folder_outlined),
        onPressed: _showDepositPicker,
      ),
      bottomBar: V3PrimaryButton(
        label: '保存并沉淀',
        weak: true,
        onPressed: _showDepositPicker,
      ),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      children: [
        const _TranscriptionAudioCard(),
        const SizedBox(height: 9),
        V3Card(
          padding: const EdgeInsets.fromLTRB(15, 11, 15, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '转写内容（可编辑）',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: HuahuoV3Theme.tokensOf(context).ink,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _editing ? Icons.check_rounded : Icons.edit_outlined,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() => _editing = !_editing);
                      showV3Snack(context, _editing ? '已开启编辑' : '已保存编辑内容');
                    },
                  ),
                ],
              ),
              TextField(
                enabled: _editing,
                contextMenuBuilder: V3TextEditing.buildContextMenu,
                minLines: null,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                scrollPhysics: const NeverScrollableScrollPhysics(),
                controller: _transcriptController,
                style: TextStyle(
                  fontSize: 11.7,
                  height: 1.26,
                  fontWeight: FontWeight.w400,
                  color: HuahuoV3Theme.tokensOf(context).ink,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 9),
        const V3SectionTitle('本次沉淀结果'),
        const _DepositResultsRow(),
        const SizedBox(height: 9),
        const V3SectionTitle('接下来，你可以'),
        LayoutBuilder(
          builder: (context, constraints) {
            final textScaler = MediaQuery.textScalerOf(context);
            final actionHeight =
                (112 +
                        2 * (textScaler.scale(13) * 1.12 - 13 * 1.12) +
                        2 * (textScaler.scale(9.6) * 1.2 - 9.6 * 1.2))
                    .clamp(112.0, double.infinity)
                    .toDouble();
            final actions = <Widget>[
              _NextActionCard(
                icon: const Icon(Icons.auto_awesome_outlined),
                title: '加入思想图谱',
                subtitle: '沉淀素材\n喂养大脑',
                onTap: () {
                  _ensurePreviewTranscriptDeposit();
                  _depositTranscriptToGraph();
                  context.go('/v3/feed');
                },
              ),
              _NextActionCard(
                icon: const Icon(Icons.summarize_outlined),
                title: '生成总结',
                subtitle: '提炼要点\n生成报告',
                onTap: () => _showSummaryDialog(context),
              ),
              _NextActionCard(
                icon: const V3ChatMark(size: 21),
                title: '继续追问',
                subtitle: '继续提问\n深入内容',
                onTap: _openPreviewTranscriptChat,
              ),
              _NextActionCard(
                icon: const Icon(Icons.add_box_outlined),
                title: '去创作空间',
                subtitle: '开始创作\n生成内容',
                onTap: () => context.go('/v3/workbench'),
              ),
            ];
            if (constraints.maxWidth >= 480) {
              return SizedBox(
                height: actionHeight,
                child: Row(
                  children: [
                    for (var index = 0; index < actions.length; index++) ...[
                      if (index > 0) const SizedBox(width: 8),
                      Expanded(child: actions[index]),
                    ],
                  ],
                ),
              );
            }
            final itemWidth = (constraints.maxWidth - 8) / 2;
            return Wrap(
              key: const ValueKey('transcription-next-actions-compact-grid'),
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final action in actions)
                  SizedBox(
                    width: itemWidth,
                    height: actionHeight,
                    child: action,
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 104),
      ],
    );
  }

  Future<void> _showDepositPicker() async {
    final contentId = _ensurePreviewTranscriptDeposit();
    await showV3DepositPicker(context, contentId: contentId);
  }

  void _openPreviewTranscriptChat() {
    final contentId = _ensurePreviewTranscriptDeposit();
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .noteForId(contentId);
    if (note == null) {
      showV3Snack(context, '转写内容暂时无法读取，请稍后重试');
      return;
    }
    context.push(v3NoteChatRoute(note));
  }

  String _ensurePreviewTranscriptDeposit() {
    final note = ref
        .read(knowledgeLibraryControllerProvider)
        .upsertProcessedTranscription(
          id: 'transcription-preview',
          title: '\u8f6c\u5199\u5b8c\u6210',
          rawBody: _transcriptController.text,
          outlineBody: '\u8f6c\u5199\u5b8c\u6210\u9884\u89c8',
          sproutBody:
              '\u5f85\u7ee7\u7eed\u6269\u5c55\u7684\u5185\u5bb9\u65b9\u5411',
        );
    return note.id;
  }

  void _depositTranscriptToGraph() {
    ref
        .read(knowledgeLibraryCommandsProvider)
        .upsertProcessedTranscription(
          id: 'transcript-ai-delivery',
          title: 'AI 落地转写',
          rawBody: '客户访谈中沉淀出的 ROI、协同和数据安全观点。',
          outlineBody: '自动纲要\n\n围绕 ROI、组织协同和数据安全整理可复用判断。',
          sproutBody: '内容方向：把 AI 落地拆成可验证的业务结果。',
        );
  }

  void _showSummaryDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: 'AI 总结已生成',
        message: '本次对话可沉淀为：ROI 指标、组织协同、数据安全三条内容主线。',
        cancelLabel: '关闭',
        primaryLabel: '知道了',
        onPrimary: () => Navigator.pop(dialogContext),
      ),
    );
  }
}

class _TranscriptionAudioCard extends StatelessWidget {
  const _TranscriptionAudioCard();

  @override
  Widget build(BuildContext context) {
    return V3Card(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Row(
        children: [
          _SoftIcon(icon: Icons.audio_file_outlined),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '和客户聊 AI 落地的关键问题',
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: _MiniWaveform()),
                    SizedBox(width: 10),
                    Text(
                      '00:12:48',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: HuahuoV3Theme.tokensOf(context).muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DepositResultsRow extends StatelessWidget {
  const _DepositResultsRow();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 480) {
          final itemWidth = (constraints.maxWidth - 8) / 2;
          return Wrap(
            key: const ValueKey('deposit-results-compact-grid'),
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: itemWidth,
                child: const _DepositResultCard(
                  icon: Icons.lightbulb_outline,
                  title: '观点',
                  subtitle: '2条核心观点',
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: const _DepositResultCard(
                  icon: Icons.workspace_premium_outlined,
                  title: '故事',
                  subtitle: '1条真实故事',
                ),
              ),
              SizedBox(
                width: itemWidth,
                child: const _DepositResultCard(
                  icon: Icons.grid_view_rounded,
                  title: '案例',
                  subtitle: '1个落地案例',
                ),
              ),
              SizedBox(width: itemWidth, child: const _DepositKeywordsCard()),
            ],
          );
        }
        return const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: _DepositResultCard(
                icon: Icons.lightbulb_outline,
                title: '观点',
                subtitle: '2条核心观点',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: _DepositResultCard(
                icon: Icons.workspace_premium_outlined,
                title: '故事',
                subtitle: '1条真实故事',
              ),
            ),
            SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: _DepositResultCard(
                icon: Icons.grid_view_rounded,
                title: '案例',
                subtitle: '1个落地案例',
              ),
            ),
            SizedBox(width: 8),
            Expanded(flex: 8, child: _DepositKeywordsCard()),
          ],
        );
      },
    );
  }
}

class _DepositResultCard extends StatelessWidget {
  const _DepositResultCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _scaledDepositCardHeight(context),
      child: V3Card(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
        radius: 16,
        child: Column(
          children: [
            Icon(icon, size: 22, color: HuahuoV3Theme.tokensOf(context).ink),
            const Spacer(),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9.8,
                color: HuahuoV3Theme.tokensOf(context).muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DepositKeywordsCard extends StatelessWidget {
  const _DepositKeywordsCard();

  static const _keywords = ['ROI', '落地', '协同', '数据', '安全', '价值'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _scaledDepositCardHeight(context),
      child: V3Card(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(7, 7, 7, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.local_fire_department,
                  size: 21,
                  color: HuahuoV3Theme.tokensOf(context).ink,
                ),
                SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '高频词',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '6个高频词',
              style: TextStyle(
                fontSize: 9.5,
                color: HuahuoV3Theme.tokensOf(context).muted,
              ),
            ),
            const Spacer(),
            Wrap(
              spacing: 4,
              runSpacing: 3,
              children: [
                for (final word in _keywords)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: HuahuoV3Theme.tokensOf(context).surfaceMuted,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      word,
                      style: const TextStyle(
                        fontSize: 8.8,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

double _scaledDepositCardHeight(BuildContext context) {
  final textScaler = MediaQuery.textScalerOf(context);
  return (94 +
          (textScaler.scale(14) - 14) +
          (textScaler.scale(9.8) - 9.8) +
          2 * (textScaler.scale(8.8) - 8.8))
      .clamp(94.0, double.infinity)
      .toDouble();
}

class _NextActionCard extends StatelessWidget {
  const _NextActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return V3Card(
      onTap: onTap,
      radius: 16,
      padding: const EdgeInsets.fromLTRB(8, 9, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 21,
            child: IconTheme(
              data: IconThemeData(
                size: 21,
                color: HuahuoV3Theme.tokensOf(context).ink,
              ),
              child: icon,
            ),
          ),
          const Spacer(),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              height: 1.12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 9.6,
                    height: 1.2,
                    color: HuahuoV3Theme.tokensOf(context).muted,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 17,
                color: HuahuoV3Theme.tokensOf(context).muted,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SoftIcon extends StatelessWidget {
  const _SoftIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return V3GlassGlyph(
      icon: icon,
      size: 52,
      iconSize: 26,
      iconColor: HuahuoV3Theme.tokensOf(context).muted,
    );
  }
}

class _MiniWaveform extends StatelessWidget {
  const _MiniWaveform();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return CustomPaint(
      painter: _MiniWaveformPainter(color: colors.muted),
      child: const SizedBox(height: 24, width: double.infinity),
    );
  }
}

class _MiniWaveformPainter extends CustomPainter {
  const _MiniWaveformPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    const heights = [
      8,
      16,
      24,
      13,
      9,
      22,
      28,
      15,
      8,
      19,
      25,
      12,
      17,
      30,
      21,
      9,
      16,
      26,
      12,
      20,
      28,
      14,
      8,
      18,
      24,
      10,
    ];
    final step = size.width / (heights.length - 1);
    final centerY = size.height / 2;
    for (var i = 0; i < heights.length; i++) {
      final x = i * step;
      final h = heights[i].toDouble();
      canvas.drawLine(
        Offset(x, centerY - h / 2),
        Offset(x, centerY + h / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniWaveformPainter oldDelegate) =>
      oldDelegate.color != color;
}
