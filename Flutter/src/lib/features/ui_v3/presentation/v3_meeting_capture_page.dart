import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/navigation/capture_leave_guard.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../ingestion/application/meeting_capture_controller.dart';
import '../../recordings/application/recording_waveform_controller.dart';
import '../../recordings/domain/recording_library.dart';
import 'v3_transcription_detail_page.dart';
import 'widgets/v3_recording_waveform_builder.dart';

class V3MeetingCapturePage extends ConsumerStatefulWidget {
  const V3MeetingCapturePage({
    this.freshEntry = false,
    this.distillToDigitalTwin = false,
    this.initialDraftId,
    super.key,
  });

  final bool freshEntry;
  final bool distillToDigitalTwin;
  final String? initialDraftId;

  @override
  ConsumerState<V3MeetingCapturePage> createState() =>
      _V3MeetingCapturePageState();
}

class _V3MeetingCapturePageState extends ConsumerState<V3MeetingCapturePage>
    with AppActivityRouteAware<V3MeetingCapturePage> {
  String? _openedTranscriptionJobId;
  String? _scheduledTranscriptionJobId;
  bool _transcriptionHandoffStarted = false;
  bool _entryReady = false;
  String? _entryUnavailableMessage;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(meetingCaptureControllerProvider);
    ref.listenManual<MeetingCaptureState>(
      meetingCaptureControllerProvider.select((value) => value.state),
      (previous, next) {
        if (!mounted || !_entryReady || _entryUnavailableMessage != null) {
          return;
        }
        _openTranscription(next);
        final hasNewError =
            next.lastErrorCode != null &&
            (previous?.lastErrorCode != next.lastErrorCode ||
                previous?.failureStage != next.failureStage);
        if (next.isCaptureActive && _transcriptionHandoffStarted) {
          setState(() => _transcriptionHandoffStarted = false);
        }
        if (hasNewError) {
          showV3Snack(context, _meetingFailureMessage(next));
        }
      },
      fireImmediately: true,
    );
    scheduleMicrotask(() => _initializeEntry(controller));
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(meetingCaptureControllerProvider);
    final state = controller.state;
    if (!_entryReady) {
      return const V3PageScaffold(
        title: '外录',
        subtitle: '麦克风录音，可离开页面并在后台继续',
        fallbackRoute: '/v3/feed',
        backBehavior: V3BackBehavior.fallbackOnly,
        children: <Widget>[
          SizedBox(
            height: 240,
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }
    if (_entryUnavailableMessage != null) {
      return V3TranscriptionPendingSurface(
        title: '外录',
        failureTitle: '当前无法进入外录',
        phase: '录音入口不可用',
        errorCode: _entryUnavailableMessage,
        onBack: _returnToPrevious,
      );
    }
    _openTranscription(state);
    final isRecording = state.status == MeetingCaptureStatus.recording;
    final isPaused = state.status == MeetingCaptureStatus.paused;

    if (_transcriptionHandoffStarted) {
      return V3TranscriptionPendingSurface(
        phase: _meetingTranscriptionPhase(state.status),
        errorCode: state.status == MeetingCaptureStatus.failed
            ? _meetingFailureMessage(state)
            : null,
        onBack: () {
          if (state.status == MeetingCaptureStatus.failed && mounted) {
            setState(() => _transcriptionHandoffStarted = false);
            return;
          }
          _returnToPrevious();
        },
        onRetry: state.canRetry ? () => unawaited(controller.retry()) : null,
      );
    }

    return V3PageScaffold(
      title: '外录',
      subtitle: '麦克风录音，可离开页面并在后台继续',
      fallbackRoute: '/v3/feed',
      backBehavior: V3BackBehavior.fallbackOnly,
      onBack: _returnToPrevious,
      children: [
        _LiveMeetingPanel(
          state: state,
          waveform: controller.waveform,
          isRecording: isRecording,
          isPaused: isPaused,
          onStart: () => unawaited(
            controller.startLiveRecording(
              distillToDigitalTwin: widget.distillToDigitalTwin,
            ),
          ),
          onPauseResume: () =>
              unawaited(isPaused ? controller.resume() : controller.pause()),
          onStop: () => _stopAndOpenTranscription(controller),
          onCancel: () => unawaited(controller.cancel()),
        ),
        if (_showProcessPanel(state)) ...[
          const SizedBox(height: 18),
          _MeetingProcessPanel(
            state: state,
            onRetry: state.canRetry
                ? () => unawaited(controller.retry())
                : null,
          ),
        ],
      ],
    );
  }

  void _stopAndOpenTranscription(MeetingCaptureController controller) {
    if (_transcriptionHandoffStarted) return;
    setState(() => _transcriptionHandoffStarted = true);
    unawaited(controller.stop());
  }

  Future<void> _initializeEntry(MeetingCaptureController controller) async {
    final attachCurrent =
        controller.state.isCaptureActive || controller.state.isBusy;
    final recoverSaved =
        controller.hasPendingRecovery &&
        !controller.state.isCaptureActive &&
        !controller.state.isBusy;
    if (widget.freshEntry &&
        !attachCurrent &&
        !recoverSaved &&
        !controller.beginFreshJourney()) {
      if (mounted) {
        setState(() {
          _entryUnavailableMessage = '已有录音处于不可中断阶段，请完成后再开始新的外录';
          _entryReady = true;
        });
      }
      return;
    }
    final outcome = await controller.initialize(
      restorePending: !widget.freshEntry || recoverSaved || attachCurrent,
      recoveryDraftId: widget.initialDraftId,
    );
    if (!mounted) return;
    setState(() {
      if (outcome == MeetingCaptureEntryOutcome.superseded) {
        _entryUnavailableMessage = '录音入口已被更新，请关闭后重试';
      } else if (widget.initialDraftId != null &&
          outcome != MeetingCaptureEntryOutcome.restored) {
        _entryUnavailableMessage = '该外录任务已结束或当前不可恢复';
      }
      _entryReady = true;
    });
  }

  void _returnToPrevious() {
    unawaited(
      returnToPreviousRoute(context, fallbackRoute: AppRoutePaths.home),
    );
  }

  void _openTranscription(MeetingCaptureState state) {
    if (!_entryReady ||
        _entryUnavailableMessage != null ||
        state.awaitingMaterialQueue ||
        state.status == MeetingCaptureStatus.failed)
      return;
    final jobId = state.transcriptionJobId;
    if (jobId == null ||
        jobId == _openedTranscriptionJobId ||
        jobId == _scheduledTranscriptionJobId ||
        !_isCurrentCaptureRoute()) {
      return;
    }
    _scheduledTranscriptionJobId = jobId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_isCurrentCaptureRoute()) {
        if (_scheduledTranscriptionJobId == jobId) {
          _scheduledTranscriptionJobId = null;
        }
        return;
      }
      if (_openedTranscriptionJobId == jobId) return;
      final current = ref.read(meetingCaptureControllerProvider).state;
      if (current.transcriptionJobId != jobId ||
          current.awaitingMaterialQueue ||
          current.status == MeetingCaptureStatus.failed) {
        _scheduledTranscriptionJobId = null;
        return;
      }
      _scheduledTranscriptionJobId = null;
      _openedTranscriptionJobId = jobId;
      final source = switch (state.source) {
        MeetingCaptureSource.liveMicrophone => RecordingFileSource.meeting,
        MeetingCaptureSource.localLibrary => RecordingFileSource.localLibrary,
        MeetingCaptureSource.recordingCard => RecordingFileSource.recordingCard,
        null => RecordingFileSource.recording,
      };
      final route = AppRoutePaths.transcriptionJob(
        jobId,
        source: source.routeValue,
      );
      context.replace(route);
    });
  }

  bool _isCurrentCaptureRoute() => isCurrentCaptureRoute(context);

  @override
  void onActivityRouteBecameActive() {
    if (!_entryReady || _entryUnavailableMessage != null) return;
    _openTranscription(ref.read(meetingCaptureControllerProvider).state);
  }
}

String _meetingTranscriptionPhase(MeetingCaptureStatus status) =>
    switch (status) {
      MeetingCaptureStatus.stopping => '正在结束录音',
      MeetingCaptureStatus.registeringLocal => '正在保存录音',
      MeetingCaptureStatus.uploading => '正在上传录音',
      MeetingCaptureStatus.completed => '正在打开转写结果',
      MeetingCaptureStatus.failed => '转写准备失败',
      _ => '正在准备转写',
    };

class _LiveMeetingPanel extends StatelessWidget {
  const _LiveMeetingPanel({
    required this.state,
    required this.waveform,
    required this.isRecording,
    required this.isPaused,
    required this.onStart,
    required this.onPauseResume,
    required this.onStop,
    required this.onCancel,
  });

  final MeetingCaptureState state;
  final RecordingWaveformController waveform;
  final bool isRecording;
  final bool isPaused;
  final VoidCallback onStart;
  final VoidCallback onPauseResume;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final active = state.isCaptureActive;
    return V3Card(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.groups_2_outlined, size: 22),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  '麦克风录音',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              _StateBadge(label: _captureStateLabel(state.status)),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            _durationText(state.elapsedSeconds),
            key: const ValueKey('meeting-live-elapsed'),
            style: const TextStyle(
              fontSize: 46,
              height: 1,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 18),
          V3RecordingWaveformBuilder(
            source: waveform,
            builder: (context, samples) => V3Waveform(
              key: const ValueKey('meeting-live-waveform'),
              active: isRecording,
              samples: samples,
              height: 82,
            ),
          ),
          if (active && state.lastErrorCode != null) ...[
            const SizedBox(height: 16),
            _ActiveCaptureError(state: state),
          ],
          const SizedBox(height: 18),
          if (!active)
            V3PrimaryButton(
              label: state.isBusy ? '正在处理' : '开始外录',
              icon: state.isBusy
                  ? Icons.hourglass_top_rounded
                  : Icons.mic_none_rounded,
              enabled:
                  !state.isBusy &&
                  state.status != MeetingCaptureStatus.completed,
              onPressed: onStart,
            )
          else
            Row(
              children: [
                _MeetingIconAction(
                  tooltip: isPaused ? '继续录音' : '暂停录音',
                  icon: isPaused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                  onPressed: onPauseResume,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: V3PrimaryButton(
                    key: const ValueKey('meeting-stop-and-transcribe'),
                    label: '结束并转写',
                    icon: Icons.stop_rounded,
                    onPressed: onStop,
                  ),
                ),
                const SizedBox(width: 12),
                _MeetingIconAction(
                  tooltip: '取消本次录音',
                  icon: Icons.close_rounded,
                  onPressed: onCancel,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ActiveCaptureError extends StatelessWidget {
  const _ActiveCaptureError({required this.state});

  final MeetingCaptureState state;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: const ValueKey('meeting-active-control-error'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: .08),
        border: Border.all(color: colors.danger.withValues(alpha: .28)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: colors.danger, size: 20),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              _meetingFailureMessage(state),
              style: TextStyle(color: colors.danger, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeetingIconAction extends StatelessWidget {
  const _MeetingIconAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox.square(
      dimension: 52,
      child: IconButton.filledTonal(
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceMuted),
          foregroundColor: WidgetStatePropertyAll(colors.ink),
        ),
      ),
    );
  }
}

class _MeetingProcessPanel extends StatelessWidget {
  const _MeetingProcessPanel({required this.state, this.onRetry});

  final MeetingCaptureState state;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final failed = state.status == MeetingCaptureStatus.failed;
    return V3Card(
      padding: const EdgeInsets.all(17),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 42,
            child: failed
                ? Icon(Icons.error_outline_rounded, color: colors.danger)
                : state.status == MeetingCaptureStatus.completed
                ? const Icon(Icons.check_circle_outline_rounded)
                : const CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _processTitle(state),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  failed
                      ? _meetingFailureMessage(state)
                      : _processSubtitle(state),
                  style: TextStyle(color: colors.muted, height: 1.35),
                ),
              ],
            ),
          ),
          if (onRetry != null)
            IconButton(
              key: const ValueKey('meeting-retry'),
              tooltip: '重试',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: onRetry,
            ),
        ],
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: const ValueKey('meeting-live-state-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

bool _showProcessPanel(MeetingCaptureState state) => switch (state.status) {
  MeetingCaptureStatus.downloadingDevice ||
  MeetingCaptureStatus.uploading ||
  MeetingCaptureStatus.completed ||
  MeetingCaptureStatus.failed => true,
  _ => false,
};

String _captureStateLabel(MeetingCaptureStatus status) => switch (status) {
  MeetingCaptureStatus.recording => '录音中',
  MeetingCaptureStatus.paused => '已暂停',
  MeetingCaptureStatus.checkingPermission ||
  MeetingCaptureStatus.starting => '准备中',
  MeetingCaptureStatus.stopping ||
  MeetingCaptureStatus.registeringLocal => '保存中',
  _ => '待机',
};

String _processTitle(MeetingCaptureState state) => switch (state.status) {
  MeetingCaptureStatus.downloadingDevice => '正在通过蓝牙下载',
  MeetingCaptureStatus.uploading => '正在上传会议录音',
  MeetingCaptureStatus.completed => '会议笔记已生成',
  MeetingCaptureStatus.failed => '会议处理未完成',
  _ => '准备会议材料',
};

String _processSubtitle(MeetingCaptureState state) => switch (state.status) {
  MeetingCaptureStatus.downloadingDevice => '文件校验并登记到本地录音库后才会上传',
  MeetingCaptureStatus.uploading => '正在发送真实录音文件，请保持网络连接',
  MeetingCaptureStatus.completed => '正在打开外部世界中的会议笔记',
  _ => state.localItem?.displayName ?? '会议材料',
};

String _failureStageLabel(MeetingFailureStage? stage) => switch (stage) {
  MeetingFailureStage.permission => '麦克风权限',
  MeetingFailureStage.nativeStart => '启动录音',
  MeetingFailureStage.nativeCapture => '录音控制',
  MeetingFailureStage.nativeStop => '结束录音',
  MeetingFailureStage.draftValidation => '文件校验',
  MeetingFailureStage.localRegistration => '本地保存',
  MeetingFailureStage.localSelection => '本地文件',
  MeetingFailureStage.deviceDownload => '蓝牙下载',
  MeetingFailureStage.upload => '录音上传',
  null => '会议处理',
};

String _meetingFailureMessage(MeetingCaptureState state) {
  final code = state.lastErrorCode?.toUpperCase() ?? '';
  if (state.failureStage == MeetingFailureStage.permission ||
      code.contains('PERMISSION')) {
    return '未获得麦克风权限，请在系统设置中允许后重试';
  }
  if (state.failureStage == MeetingFailureStage.localSelection ||
      code.contains('NOT_FOUND') ||
      code.contains('MISSING')) {
    return '录音文件不可用，请重新选择';
  }
  if (state.failureStage == MeetingFailureStage.localRegistration ||
      code.contains('STORAGE') ||
      code.contains('DISK')) {
    return '录音保存失败，请检查存储空间后重试';
  }
  if (state.failureStage == MeetingFailureStage.deviceDownload ||
      code.contains('BLUETOOTH') ||
      code.contains('DISCONNECTED')) {
    return '录音卡连接已中断，请重新连接后重试';
  }
  if (state.failureStage == MeetingFailureStage.upload ||
      code.contains('UPLOAD') ||
      code.contains('NETWORK')) {
    return '会议录音上传失败，请检查网络后重试';
  }
  return '${_failureStageLabel(state.failureStage)}失败，请稍后重试';
}

String _durationText(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  final remaining = safe % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '${two(hours)}:${two(minutes)}:${two(remaining)}'
      : '${two(minutes)}:${two(remaining)}';
}
