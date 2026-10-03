import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../recordings/application/monologue_recording_controller.dart';
import '../../recordings/application/recording_waveform_controller.dart';
import '../../transcription/application/live_transcript_controller.dart';
import '../../transcription/presentation/live_transcription_failure_dialog.dart';
import 'widgets/v3_monologue_transcript_window.dart';
import 'widgets/v3_recording_waveform_builder.dart';

Future<void> showV3MonologueQuickCapture(BuildContext context) async {
  final recorder = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(monologueRecordingControllerProvider);
  var handoff = false;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x2e000000),
      builder: (sheetContext) => _QuickMonologueCaptureConnector(
        launcherContext: context,
        onHandoff: () => handoff = true,
      ),
    );
  } finally {
    if (!handoff) await recorder.endCaptureForLeave();
  }
}

class _QuickMonologueCaptureConnector extends ConsumerStatefulWidget {
  const _QuickMonologueCaptureConnector({
    required this.launcherContext,
    required this.onHandoff,
  });

  final BuildContext launcherContext;
  final VoidCallback onHandoff;

  @override
  ConsumerState<_QuickMonologueCaptureConnector> createState() =>
      _QuickMonologueCaptureConnectorState();
}

class _QuickMonologueCaptureConnectorState
    extends ConsumerState<_QuickMonologueCaptureConnector> {
  String? _scheduledNoteId;
  final LiveTranscriptionFailureDialogGate _recordingFailureDialogGate =
      LiveTranscriptionFailureDialogGate();
  final LiveTranscriptionFailureDialogGate _previewFailureDialogGate =
      LiveTranscriptionFailureDialogGate();
  bool _leaving = false;
  bool _allowPop = false;
  late final TextEditingController _transcriptController;

  @override
  void initState() {
    super.initState();
    _transcriptController = TextEditingController(
      text: ref.read(monologueRecordingControllerProvider).state.transcriptText,
    );
    ref.listenManual<MonologueRecordingState>(
      monologueRecordingControllerProvider.select(
        (controller) => controller.state,
      ),
      _onRecordingChanged,
    );
  }

  @override
  void dispose() {
    _transcriptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recorder = ref.read(monologueRecordingControllerProvider);
    final recording = ref.watch(monologueRecordingControllerProvider).state;
    final sharedTranscript = ref.watch(liveTranscriptControllerProvider).state;
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_allowPop) unawaited(_requestClose());
      },
      child: V3MonologueQuickCaptureSheet(
        recording: recording,
        waveform: recorder.waveform,
        transcript: recorder.visibleLiveTranscriptState(sharedTranscript),
        transcriptController: _transcriptController,
        onTranscriptChanged: recorder.updateTranscript,
        onClose: () => unawaited(_requestClose()),
        onExpand: _expand,
        onStart: () => unawaited(_start(recorder)),
        onPause: () => unawaited(recorder.pause()),
        onResume: () => unawaited(recorder.resume()),
        onDone: () => unawaited(recorder.stop()),
        onRetry: () => unawaited(recorder.retry()),
        onOpenAsset: recording.localNoteId == null
            ? null
            : () => _leaveFor(
                AppRoutePaths.feedItem(recording.localNoteId!, stage: 'raw'),
              ),
      ),
    );
  }

  void _onRecordingChanged(
    MonologueRecordingState? previous,
    MonologueRecordingState next,
  ) {
    if (!mounted || _leaving) return;
    if (_transcriptController.text != next.transcriptText) {
      _transcriptController.value = TextEditingValue(
        text: next.transcriptText,
        selection: TextSelection.collapsed(offset: next.transcriptText.length),
      );
    }
    final noteId = next.localNoteId;
    if (next.status == MonologueRecordingStatus.completed &&
        previous?.status != MonologueRecordingStatus.completed &&
        noteId != null &&
        noteId != _scheduledNoteId) {
      _scheduledNoteId = noteId;
      _leaveFor(AppRoutePaths.feedItem(noteId, stage: 'raw'));
      return;
    }
    final liveError = next.liveTranscriptErrorCode;
    if (liveError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            _showFailure(
              liveError,
              previewFailure: true,
              wasTranscribing: monologueFailureWasTranscribing(previous, next),
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
        monologueRecordingFailureMessage(
          next.failureStage,
          next.lastErrorCode!,
        ),
      );
    }
  }

  Future<void> _start(MonologueRecordingController recorder) async {
    _recordingFailureDialogGate.beginAttempt();
    final started = await recorder.start();
    if (!mounted || started) return;
    final failure = recorder.state;
    if (failure.failureStage == MonologueFailureStage.liveTranscription) {
      return;
    }
    final errorCode = failure.lastErrorCode;
    if (errorCode != null) {
      await _showFailure(
        errorCode,
        previewFailure: false,
        wasTranscribing: false,
        attemptId: null,
        correlationId: recorder.state.correlationId,
      );
    }
  }

  Future<void> _showFailure(
    String errorCode, {
    required bool previewFailure,
    required bool wasTranscribing,
    required int? attemptId,
    required String? correlationId,
  }) async {
    final gate = previewFailure
        ? _previewFailureDialogGate
        : _recordingFailureDialogGate;
    if (!mounted ||
        _leaving ||
        !gate.claim(
          owner: previewFailure
              ? 'monologue:${correlationId ?? 'unallocated'}'
              : 'monologue-recording',
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
        failureContext: previewFailure
            ? LiveTranscriptionFailureContext.realtime
            : LiveTranscriptionFailureContext.recording,
      );
    } finally {
      gate.release();
    }
    if (!mounted || _leaving) return;
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
      final recorder = ref.read(monologueRecordingControllerProvider);
      if (previewFailure) _previewFailureDialogGate.beginAttempt();
      unawaited(
        previewFailure
            ? recorder.retryLiveTranscriptPreview()
            : _start(recorder),
      );
    }
  }

  Future<void> _requestClose() async {
    if (_leaving) return;
    final recorder = ref.read(monologueRecordingControllerProvider);
    final recording = recorder.state;
    final needsConfirmation =
        recording.hasNativeCapture ||
        recording.status == MonologueRecordingStatus.checkingPermission ||
        recording.status == MonologueRecordingStatus.starting ||
        recording.status == MonologueRecordingStatus.pausing ||
        recording.status == MonologueRecordingStatus.resuming;
    if (needsConfirmation) {
      final shouldEnd = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => V3GlassDialog(
          title: '正在独白',
          message: '关闭小窗将结束并保存本次独白。',
          cancelLabel: '继续独白',
          primaryLabel: '结束并关闭',
          onCancel: () => Navigator.of(dialogContext).pop(false),
          onPrimary: () => Navigator.of(dialogContext).pop(true),
        ),
      );
      if (!mounted || shouldEnd != true) return;
      final ended = await recorder.endCaptureForLeave();
      if (!mounted) return;
      if (!ended) {
        showV3Snack(context, '独白尚未安全结束，请重试');
        return;
      }
    }
    _popSheet();
  }

  void _expand() => _leaveFor('/v3/feed/monologue?presentation=sheet');

  void _leaveFor(String route) {
    if (_leaving) return;
    _leaving = true;
    widget.onHandoff();
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
      scheduleMicrotask(() {
        if (widget.launcherContext.mounted) {
          widget.launcherContext.push(route);
        }
      });
    });
  }

  void _popSheet() {
    if (_leaving) return;
    _leaving = true;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
    });
  }
}

Future<void> showV3TextQuickCapture(BuildContext context) async {
  final draft = await showModalBottomSheet<Map<String, String>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x2e000000),
    builder: (sheetContext) => _QuickTextCaptureConnector(
      onClose: () => Navigator.of(sheetContext).pop(),
      onContinue: (title, body) => Navigator.of(
        sheetContext,
      ).pop(<String, String>{'title': title, 'body': body}),
    ),
  );
  if (draft != null && context.mounted) {
    await context.push('/v3/feed/note?presentation=sheet', extra: draft);
  }
}

class V3MonologueQuickCaptureSheet extends StatelessWidget {
  const V3MonologueQuickCaptureSheet({
    required this.recording,
    this.waveform,
    required this.transcript,
    required this.onClose,
    required this.onExpand,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onDone,
    this.onRetry,
    this.transcriptController,
    this.onTranscriptChanged,
    this.onOpenAsset,
    super.key,
  });

  final MonologueRecordingState recording;
  final RecordingWaveformController? waveform;
  final LiveTranscriptState transcript;
  final TextEditingController? transcriptController;
  final ValueChanged<String>? onTranscriptChanged;
  final VoidCallback onClose;
  final VoidCallback onExpand;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDone;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenAsset;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final mediaTop = MediaQuery.viewPaddingOf(context).top;
    final flutterView = View.of(context);
    final platformTop =
        flutterView.viewPadding.top / flutterView.devicePixelRatio;
    final persistentTop = platformTop > mediaTop ? platformTop : mediaTop;
    final viewportAvailable =
        MediaQuery.sizeOf(context).height - keyboardInset - persistentTop;
    final status = _quickMonologueStatusLabel(recording);
    final statusColor = _quickMonologueStatusColor(recording, colors);
    final processing =
        recording.status == MonologueRecordingStatus.stopping ||
        recording.status == MonologueRecordingStatus.registeringLocal ||
        recording.status == MonologueRecordingStatus.savingNote;

    return LayoutBuilder(
      builder: (context, constraints) {
        final constrainedAvailable = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : viewportAvailable;
        final availableHeight = viewportAvailable < constrainedAvailable
            ? viewportAvailable
            : constrainedAvailable;
        final sheetHeight = availableHeight.clamp(0.0, 694.0).toDouble();
        final compact = keyboardInset > 0 || sheetHeight < 520;
        return AnimatedPadding(
          duration: V3MotionTokens.standard,
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: Material(
            key: const ValueKey('monologue-quick-sheet'),
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: sheetHeight,
              child: Column(
                key: const ValueKey('monologue-sheet-layout'),
                children: [
                  SizedBox(
                    height: compact ? 14 : 20,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xffc9cccd),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: compact ? 48 : 58,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        V3CloseButton(onPressed: onClose),
                        const Expanded(
                          child: Text(
                            '独白',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              height: 1.4,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '展开独白',
                          onPressed: onExpand,
                          icon: const Icon(LucideIcons.arrowUpRight, size: 18),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      compact ? 2 : 8,
                      24,
                      compact ? 6 : 12,
                    ),
                    child: compact
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _QuickStatusDot(color: statusColor),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.muted,
                                    fontSize: 13,
                                    height: 1.4,
                                    letterSpacing: 0,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _quickDuration(recording.elapsedSeconds),
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 18,
                                  height: 1.3,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 0,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _QuickStatusDot(color: statusColor),
                                  const SizedBox(width: 8),
                                  Text(
                                    status,
                                    style: TextStyle(
                                      color: colors.muted,
                                      fontSize: 13,
                                      height: 1.5,
                                      letterSpacing: 0,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                _quickDuration(recording.elapsedSeconds),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.ink,
                                  fontSize: 32,
                                  height: 1.24,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 0,
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 54,
                                width: double.infinity,
                                child: V3RecordingWaveformBuilder(
                                  source: waveform,
                                  builder: (context, samples) => CustomPaint(
                                    painter: _QuickWavePainter(
                                      active: recording.isNativeWriting,
                                      samples: samples,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        compact ? 2 : 4,
                        24,
                        compact ? 6 : 10,
                      ),
                      child: KeyedSubtree(
                        key: const ValueKey('monologue-transcript-scroll'),
                        child: V3MonologueTranscriptWindow(
                          state: transcript,
                          sessionActive: monologueTranscriptSessionActive(
                            recording,
                          ),
                          liveTranscriptErrorCode:
                              recording.liveTranscriptErrorCode,
                          controller: transcriptController,
                          transcriptText: recording.transcriptText,
                          editable: recording.canEditTranscript,
                          onChanged: onTranscriptChanged,
                          height: null,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: compact ? 78 : 112,
                    child: Center(
                      child: _buildActions(
                        compact: compact,
                        processing: processing,
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 4 : 12),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActions({required bool compact, required bool processing}) {
    final canToggle = recording.canPause || recording.canResume;
    if (canToggle) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QuickRoundAction(
            tooltip: recording.canResume ? '继续录音' : '暂停录音',
            icon: recording.canResume ? LucideIcons.play : LucideIcons.pause,
            label: recording.canResume ? '继续' : '暂停',
            onTap: recording.canResume ? onResume : onPause,
            compact: compact,
          ),
          SizedBox(width: compact ? 48 : 72),
          _QuickRoundAction(
            tooltip: '完成录音',
            icon: LucideIcons.square,
            label: '完成',
            filled: true,
            onTap: recording.canFinish ? onDone : null,
            compact: compact,
          ),
        ],
      );
    }
    if (recording.status == MonologueRecordingStatus.completed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QuickRoundAction(
            tooltip: '再次独白',
            icon: LucideIcons.mic,
            label: '再次独白',
            filled: true,
            onTap: recording.canStart ? onStart : null,
            compact: compact,
          ),
          SizedBox(width: compact ? 38 : 56),
          _QuickRoundAction(
            tooltip: '查看已保存笔记',
            icon: LucideIcons.fileText,
            label: '查看笔记',
            onTap: onOpenAsset,
            compact: compact,
          ),
        ],
      );
    }
    if (recording.status == MonologueRecordingStatus.failed &&
        recording.canFinish) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QuickRoundAction(
            tooltip: '重试当前步骤',
            icon: LucideIcons.refreshCw,
            label: '重试',
            onTap: recording.canRetry ? onRetry : null,
            compact: compact,
          ),
          SizedBox(width: compact ? 48 : 72),
          _QuickRoundAction(
            tooltip: '完成并保存录音',
            icon: LucideIcons.square,
            label: '完成',
            filled: true,
            onTap: onDone,
            compact: compact,
          ),
        ],
      );
    }
    final label = processing
        ? '保存中'
        : recording.canRetry
        ? '重试'
        : recording.canStart
        ? '开始独白'
        : recording.status == MonologueRecordingStatus.resuming
        ? '继续中'
        : recording.status == MonologueRecordingStatus.pausing
        ? '暂停中'
        : '处理中';
    final icon = recording.canRetry
        ? LucideIcons.refreshCw
        : recording.canStart
        ? LucideIcons.mic
        : LucideIcons.loaderCircle;
    final callback = recording.canRetry
        ? onRetry
        : recording.canStart
        ? onStart
        : null;
    return _QuickRoundAction(
      tooltip: label,
      icon: icon,
      label: label,
      filled: true,
      onTap: callback,
      compact: compact,
    );
  }
}

class _QuickStatusDot extends StatelessWidget {
  const _QuickStatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

String _quickMonologueStatusLabel(MonologueRecordingState recording) {
  if (recording.hasRecoverableLiveFailure) return '转写已暂停';
  return switch (recording.status) {
    MonologueRecordingStatus.idle => '准备开始',
    MonologueRecordingStatus.checkingPermission => '正在请求麦克风',
    MonologueRecordingStatus.starting => '正在启动',
    MonologueRecordingStatus.recording => '正在实时转写',
    MonologueRecordingStatus.pausing => '正在暂停',
    MonologueRecordingStatus.paused => '已暂停，可编辑',
    MonologueRecordingStatus.resuming => '正在继续',
    MonologueRecordingStatus.stopping => '正在保存录音',
    MonologueRecordingStatus.registeringLocal => '正在存放录音',
    MonologueRecordingStatus.savingNote => '正在保存笔记',
    MonologueRecordingStatus.completed => '已保存',
    MonologueRecordingStatus.failed => '操作未完成',
  };
}

Color _quickMonologueStatusColor(
  MonologueRecordingState recording,
  HuahuoV3ThemeTokens colors,
) {
  if (recording.isNativeWriting) return const Color(0xffc85a52);
  if (recording.canResume) return const Color(0xff9a6426);
  if (recording.status == MonologueRecordingStatus.failed) {
    return colors.danger;
  }
  if (recording.isBusy) return colors.primary;
  if (recording.status == MonologueRecordingStatus.completed) {
    return const Color(0xff2f7d5c);
  }
  return colors.muted;
}

class V3TextQuickCaptureSheet extends StatefulWidget {
  const V3TextQuickCaptureSheet({
    required this.titleController,
    required this.bodyController,
    required this.onClose,
    required this.onExpand,
    required this.onAdd,
    required this.onChecklist,
    required this.onImage,
    required this.onContinue,
    super.key,
  });

  final TextEditingController titleController;
  final TextEditingController bodyController;
  final VoidCallback onClose;
  final VoidCallback onExpand;
  final VoidCallback onAdd;
  final VoidCallback onChecklist;
  final VoidCallback onImage;
  final VoidCallback onContinue;

  @override
  State<V3TextQuickCaptureSheet> createState() =>
      _V3TextQuickCaptureSheetState();
}

class _V3TextQuickCaptureSheetState extends State<V3TextQuickCaptureSheet> {
  final FocusNode _titleFocusNode = FocusNode();
  final FocusNode _bodyFocusNode = FocusNode();

  TextEditingController get titleController => widget.titleController;
  TextEditingController get bodyController => widget.bodyController;
  VoidCallback get onClose => widget.onClose;
  VoidCallback get onExpand => widget.onExpand;
  VoidCallback get onAdd => widget.onAdd;
  VoidCallback get onChecklist => widget.onChecklist;
  VoidCallback get onImage => widget.onImage;
  VoidCallback get onContinue => widget.onContinue;

  @override
  void dispose() {
    _titleFocusNode.dispose();
    _bodyFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final mediaQueryViewPadding = MediaQuery.viewPaddingOf(context).top;
    final flutterView = View.of(context);
    final platformTopViewPadding =
        flutterView.viewPadding.top / flutterView.devicePixelRatio;
    final persistentTopViewPadding =
        platformTopViewPadding > mediaQueryViewPadding
        ? platformTopViewPadding
        : mediaQueryViewPadding;
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        keyboardInset -
        persistentTopViewPadding;
    final compactHeight = availableHeight < 420;
    final sheetHeight = availableHeight.clamp(0.0, 694.0);
    return AnimatedPadding(
      duration: V3MotionTokens.standard,
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Material(
        key: const ValueKey('text-quick-sheet'),
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: sheetHeight,
          child: compactHeight
              ? _buildCompactBody(context, colors)
              : Stack(
                  children: [
                    const _QuickSheetHandle(),
                    Positioned(
                      left: 16,
                      top: 26,
                      child: V3CloseButton(onPressed: onClose),
                    ),
                    const Positioned(
                      left: 100,
                      right: 100,
                      top: 38,
                      child: Text(
                        '文字',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          height: 1.4,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 16,
                      top: 26,
                      child: IconButton(
                        tooltip: '展开文字编辑',
                        onPressed: onExpand,
                        icon: const Icon(LucideIcons.arrowUpRight, size: 18),
                      ),
                    ),
                    const Positioned(
                      left: 40,
                      top: 118,
                      child: Text(
                        '新建文字笔记',
                        style: TextStyle(
                          fontSize: 18,
                          height: 1.4,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 40,
                      right: 40,
                      top: 167,
                      child: TextField(
                        key: const ValueKey('text-quick-title'),
                        controller: titleController,
                        focusNode: _titleFocusNode,
                        contextMenuBuilder: V3TextEditing.buildContextMenu,
                        maxLines: 1,
                        decoration: const InputDecoration(
                          hintText: '标题（可选）',
                          filled: false,
                          border: UnderlineInputBorder(
                            borderSide: BorderSide(color: Color(0xffe0e2e3)),
                          ),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Color(0xffe0e2e3)),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Color(0xffb67630)),
                          ),
                          contentPadding: EdgeInsets.symmetric(vertical: 14),
                        ),
                        style: const TextStyle(fontSize: 15, letterSpacing: 0),
                      ),
                    ),
                    Positioned(
                      left: 40,
                      right: 40,
                      top: 236,
                      bottom: 114,
                      child: TextField(
                        key: const ValueKey('text-quick-body'),
                        controller: bodyController,
                        focusNode: _bodyFocusNode,
                        contextMenuBuilder: V3TextEditing.buildContextMenu,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(
                          hintText: '从这里开始写下你的想法...',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.7,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 40,
                      right: 40,
                      bottom: 114,
                      child: Divider(height: 1, color: colors.line),
                    ),
                    Positioned(
                      left: 40,
                      right: 40,
                      bottom: 47,
                      child: SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            _QuickToolbarAction(
                              tooltip: '添加',
                              icon: LucideIcons.plus,
                              onTap: onAdd,
                            ),
                            _QuickToolbarAction(
                              tooltip: '清单',
                              icon: LucideIcons.listChecks,
                              onTap: onChecklist,
                            ),
                            _QuickToolbarAction(
                              tooltip: '图片',
                              icon: LucideIcons.image,
                              onTap: onImage,
                            ),
                            const Spacer(),
                            IconButton.filled(
                              key: const ValueKey('text-quick-continue'),
                              tooltip: '继续编辑',
                              onPressed: onContinue,
                              style: IconButton.styleFrom(
                                fixedSize: const Size.square(48),
                                backgroundColor: colors.primary,
                                foregroundColor: colors.onPrimary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: const Icon(LucideIcons.arrowUp, size: 21),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildCompactBody(BuildContext context, HuahuoV3ThemeTokens colors) {
    return Column(
      children: [
        SizedBox(
          height: 22,
          child: Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xffc9cccd),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 8),
              V3CloseButton(onPressed: onClose),
              const Expanded(
                child: Text(
                  '文字',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
              ),
              IconButton(
                tooltip: '展开文字编辑',
                onPressed: onExpand,
                icon: const Icon(LucideIcons.arrowUpRight, size: 18),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '新建文字笔记',
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  key: const ValueKey('text-quick-title'),
                  controller: titleController,
                  focusNode: _titleFocusNode,
                  contextMenuBuilder: V3TextEditing.buildContextMenu,
                  maxLines: 1,
                  decoration: const InputDecoration(
                    hintText: '标题（可选）',
                    filled: false,
                    border: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xffe0e2e3)),
                    ),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xffe0e2e3)),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xffb67630)),
                    ),
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  style: const TextStyle(fontSize: 15, letterSpacing: 0),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('text-quick-body'),
                  controller: bodyController,
                  focusNode: _bodyFocusNode,
                  contextMenuBuilder: V3TextEditing.buildContextMenu,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    hintText: '从这里开始写下你的想法...',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.7,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: colors.line),
        SafeArea(
          top: false,
          minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                _QuickToolbarAction(
                  tooltip: '添加',
                  icon: LucideIcons.plus,
                  onTap: onAdd,
                ),
                _QuickToolbarAction(
                  tooltip: '清单',
                  icon: LucideIcons.listChecks,
                  onTap: onChecklist,
                ),
                _QuickToolbarAction(
                  tooltip: '图片',
                  icon: LucideIcons.image,
                  onTap: onImage,
                ),
                const Spacer(),
                IconButton.filled(
                  key: const ValueKey('text-quick-continue'),
                  tooltip: '继续编辑',
                  onPressed: onContinue,
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(48),
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(LucideIcons.arrowUp, size: 21),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _QuickTextCaptureConnector extends StatefulWidget {
  const _QuickTextCaptureConnector({
    required this.onClose,
    required this.onContinue,
  });

  final VoidCallback onClose;
  final void Function(String title, String body) onContinue;

  @override
  State<_QuickTextCaptureConnector> createState() =>
      _QuickTextCaptureConnectorState();
}

class _QuickTextCaptureConnectorState
    extends State<_QuickTextCaptureConnector> {
  late final TextEditingController _title;
  late final TextEditingController _body;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    _body = TextEditingController();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => V3TextQuickCaptureSheet(
    titleController: _title,
    bodyController: _body,
    onClose: widget.onClose,
    onExpand: _continue,
    onAdd: () => _insert('\n'),
    onChecklist: () => _insert('- [ ] '),
    onImage: () => _insert('![图片说明](图片地址)'),
    onContinue: _continue,
  );

  void _continue() => widget.onContinue(_title.text, _body.text);

  void _insert(String value) {
    final selection = _body.selection;
    final start = selection.isValid ? selection.start : _body.text.length;
    final end = selection.isValid ? selection.end : _body.text.length;
    final next = _body.text.replaceRange(start, end, value);
    _body.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
  }
}

class _QuickSheetHandle extends StatelessWidget {
  const _QuickSheetHandle();

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: 12,
    child: Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xffc9cccd),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

class _QuickRoundAction extends StatelessWidget {
  const _QuickRoundAction({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
    this.compact = false,
  });

  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          style: IconButton.styleFrom(
            fixedSize: Size.square(compact ? 48 : 64),
            backgroundColor: filled
                ? colors.primary.withValues(alpha: onTap == null ? .62 : 1)
                : colors.surfaceMuted,
            foregroundColor: filled ? colors.onPrimary : colors.ink,
            side: filled ? BorderSide.none : BorderSide(color: colors.line),
            shape: const CircleBorder(),
          ),
          icon: Icon(icon, size: compact ? 18 : 20),
        ),
        SizedBox(height: compact ? 4 : 8),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.text,
            fontSize: compact ? 11.5 : 12.5,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _QuickToolbarAction extends StatelessWidget {
  const _QuickToolbarAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
    padding: EdgeInsets.zero,
    icon: Icon(icon, size: 19),
  );
}

class _QuickWavePainter extends CustomPainter {
  const _QuickWavePainter({required this.active, required this.samples});

  final bool active;
  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    const count = 27;
    final baseline = size.height / 2;
    final gap = size.width / (count + 1);
    final muted = Paint()
      ..color = active ? const Color(0xffcdd2d4) : const Color(0xffeef0f0)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final accent = Paint()
      ..color = active ? const Color(0xffdf766d) : const Color(0xffffe0dc)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < count; index++) {
      final hasSignal = samples.any((sample) => sample > .01);
      final sample = !hasSignal
          ? ((index * 13) % 19) / 19
          : samples[index % samples.length];
      final height = 7 + sample.clamp(0.0, 1.0) * 42;
      final x = gap * (index + 1);
      canvas.drawLine(
        Offset(x, baseline - height / 2),
        Offset(x, baseline + height / 2),
        index == 14 ? accent : muted,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _QuickWavePainter oldDelegate) =>
      oldDelegate.active != active || oldDelegate.samples != samples;
}

String _quickDuration(int seconds) {
  final normalized = seconds.clamp(0, 359999);
  final minutes = normalized ~/ 60;
  final remainder = normalized % 60;
  return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}.0';
}
