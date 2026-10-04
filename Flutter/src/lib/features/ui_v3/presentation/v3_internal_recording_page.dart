import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../shared/navigation/capture_leave_guard.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../ingestion/application/internal_recording_controller.dart';
import '../../recordings/domain/recording_library.dart';

class V3InternalRecordingPage extends ConsumerStatefulWidget {
  const V3InternalRecordingPage({
    this.freshEntry = false,
    this.distillToDigitalTwin = false,
    this.initialDraftId,
    super.key,
  });

  final bool freshEntry;
  final bool distillToDigitalTwin;
  final String? initialDraftId;

  @override
  ConsumerState<V3InternalRecordingPage> createState() =>
      _V3InternalRecordingPageState();
}

class _V3InternalRecordingPageState
    extends ConsumerState<V3InternalRecordingPage>
    with AppActivityRouteAware<V3InternalRecordingPage> {
  bool _entryReady = false;
  bool _exactEntryUnavailable = false;
  String? _openedJob;
  String? _scheduledJob;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_initialize);
  }

  Future<void> _initialize() async {
    if (!mounted) {
      return;
    }
    final controller = ref.read(internalRecordingControllerProvider);
    final outcome = await controller.initialize(
      recoveryDraftId: widget.initialDraftId,
    );
    if (!mounted) {
      return;
    }
    if (widget.freshEntry &&
        widget.initialDraftId == null &&
        controller.state.status == InternalRecordingStatus.completed) {
      controller.beginFreshJourney();
    }
    setState(() {
      _entryReady = true;
      _exactEntryUnavailable =
          widget.initialDraftId != null &&
          outcome == InternalRecordingEntryOutcome.unavailable;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(internalRecordingControllerProvider);
    final state = controller.state;
    if (_entryReady && !_exactEntryUnavailable) _openTranscription(controller);
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3PageScaffold(
      title: '内录',
      subtitle: '系统录屏获取设备声音，结束后分离音频并转写',
      fallbackRoute: AppRoutePaths.home,
      centerTitle: true,
      onBack: _back,
      bottomBar: !_entryReady || _exactEntryUnavailable
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                child: _controls(controller),
              ),
            ),
      children: <Widget>[
        const SizedBox(height: 26),
        Center(
          child: Icon(
            state.isRecording
                ? Icons.screen_share_rounded
                : Icons.important_devices_rounded,
            size: 64,
            color: state.isRecording ? colors.danger : colors.ink,
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            _duration(state.elapsedSeconds),
            key: const ValueKey('internal-recording-duration'),
            style: TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.w600,
              color: colors.ink,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            _exactEntryUnavailable ? '该内录任务当前不可恢复' : _statusLabel(state.status),
            key: const ValueKey('internal-recording-status'),
            style: HuahuoV3Theme.body.copyWith(color: colors.ink),
          ),
        ),
        if (!_entryReady || state.isBusy) ...<Widget>[
          const SizedBox(height: 16),
          const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ],
        const SizedBox(height: 24),
        _infoCard(
          icon: state.lastErrorCode == null
              ? Icons.info_outline
              : Icons.error_outline,
          text: state.lastErrorCode == null
              ? _statusMessage(state.status)
              : _errorMessage(state.lastErrorCode!),
          isError: state.lastErrorCode != null,
        ),
        const SizedBox(height: 16),
        _infoCard(
          icon: Icons.format_list_numbered_rounded,
          text:
              '1. 点击开始，在系统界面同意录屏。\n'
              '2. 切换到需要录制的 App，播放直播、课程等内容。\n'
              '3. 返回这里或通过系统录屏入口停止。\n'
              '4. 自动分离音频、保存到录音文件，再上传转写。',
        ),
        const SizedBox(height: 12),
        _infoCard(
          icon: Icons.privacy_tip_outlined,
          text:
              '仅采集系统允许录制的应用声音，不使用麦克风替代内录。'
              '受版权保护的内容、通话或禁止声音采集的 App 可能无法录到声音。'
              '\n单次最长 30 分钟、录屏文件最大 500MB；到达上限会自动结束。'
              '\n离开此页面不会停止录屏；系统锁屏、撤销授权或终止录屏时会结束本次采集。',
        ),
      ],
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String text,
    bool isError = false,
  }) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: (isError ? colors.danger : colors.ink).withValues(alpha: .05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 21, color: isError ? colors.danger : colors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: HuahuoV3Theme.body.copyWith(
                color: isError ? colors.danger : colors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(InternalRecordingController controller) {
    final state = controller.state;
    if (state.status == InternalRecordingStatus.unsupported) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _importVideoButton(controller),
          TextButton(
            onPressed: () => context.push('/v3/profile/recordings'),
            child: const Text('导入已有录音'),
          ),
        ],
      );
    }
    if (state.status == InternalRecordingStatus.awaitingConsent) {
      return OutlinedButton.icon(
        key: const ValueKey('internal-recording-cancel-consent'),
        onPressed: () => unawaited(controller.cancel()),
        icon: const Icon(Icons.close),
        label: const Text('取消本次录屏'),
      );
    }
    if (state.isRecording) {
      return V3PrimaryButton(
        key: const ValueKey('internal-recording-finish'),
        label: '结束录屏并转写',
        icon: Icons.stop_rounded,
        onPressed: () => unawaited(controller.stop()),
      );
    }
    if (state.status == InternalRecordingStatus.failed) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          V3PrimaryButton(
            key: const ValueKey('internal-recording-retry'),
            label: state.hasRetainedMedia ? '重试音频处理' : '重新尝试',
            icon: Icons.refresh_rounded,
            onPressed: () => unawaited(controller.retry()),
          ),
          if (state.failureStage == InternalRecordingFailureStage.permission)
            TextButton(
              onPressed: () => unawaited(
                ref
                    .read(platformPermissionsPortProvider)
                    .openAppSettings(
                      PlatformPermissionKind.microphone,
                      impactAcknowledged: true,
                    ),
              ),
              child: const Text('打开系统权限设置'),
            ),
          if (state.hasRetainedMedia)
            TextButton(
              onPressed: () => unawaited(_discard(controller)),
              child: const Text('放弃本次处理，重新录制'),
            ),
          if (controller.canResetCheckpoint)
            TextButton(
              onPressed: () => unawaited(_discard(controller)),
              child: const Text('隔离异常记录并重新开始'),
            ),
          if (!state.hasRetainedMedia && !controller.canResetCheckpoint)
            _importVideoButton(controller),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        V3PrimaryButton(
          key: const ValueKey('internal-recording-start'),
          label: state.isBusy ? _statusLabel(state.status) : '开始内录',
          icon: Icons.screen_share_outlined,
          enabled: !state.isBusy,
          onPressed: () => unawaited(
            controller.start(distillToDigitalTwin: widget.distillToDigitalTwin),
          ),
        ),
        if (!state.isBusy) _importVideoButton(controller),
      ],
    );
  }

  Widget _importVideoButton(InternalRecordingController controller) =>
      TextButton.icon(
        key: const ValueKey('internal-recording-import-video'),
        onPressed: () => unawaited(
          controller.importVideo(
            distillToDigitalTwin: widget.distillToDigitalTwin,
          ),
        ),
        icon: const Icon(Icons.video_file_outlined),
        label: const Text('导入已有录屏视频'),
      );

  Future<void> _discard(InternalRecordingController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新录制？'),
        content: Text(
          controller.canResetCheckpoint
              ? '异常恢复记录会先隔离保存，再重新开始。不会删除已有录屏文件或已保存的音频；如系统仍在录屏，请先从系统入口停止。'
              : '本次尚未完成的录屏处理将不再继续，原始录屏和中间音频会清理。已经保存到录音文件中的音频不会删除。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留并返回'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认重新录制'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await controller.discardAndReset();
  }

  void _openTranscription(InternalRecordingController controller) {
    final jobId = controller.state.transcriptionJobId;
    if (!controller.hasDurableJob ||
        controller.state.status == InternalRecordingStatus.failed ||
        jobId == null ||
        jobId == _openedJob ||
        jobId == _scheduledJob ||
        !isCurrentCaptureRoute(context)) {
      return;
    }
    _scheduledJob = jobId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !isCurrentCaptureRoute(context)) {
        _scheduledJob = null;
        return;
      }
      if (controller.state.transcriptionJobId != jobId ||
          controller.state.status == InternalRecordingStatus.failed ||
          !controller.hasDurableJob) {
        _scheduledJob = null;
        return;
      }
      _openedJob = jobId;
      context.replace(
        AppRoutePaths.transcriptionJob(
          jobId,
          source: RecordingFileSource.internalRecording.routeValue,
        ),
      );
    });
  }

  void _back() {
    unawaited(
      returnToPreviousRoute(context, fallbackRoute: AppRoutePaths.home),
    );
  }

  @override
  void onActivityRouteBecameActive() {
    if (!_entryReady) {
      return;
    }
    final controller = ref.read(internalRecordingControllerProvider);
    unawaited(controller.refreshSession());
    if (!_exactEntryUnavailable) _openTranscription(controller);
  }
}

String _statusLabel(InternalRecordingStatus status) => switch (status) {
  InternalRecordingStatus.loading => '正在检查录屏状态',
  InternalRecordingStatus.idle => '准备开始录屏',
  InternalRecordingStatus.unsupported => '当前设备不支持应用内录屏声音采集',
  InternalRecordingStatus.starting => '正在准备录屏',
  InternalRecordingStatus.awaitingConsent => '等待系统录屏授权',
  InternalRecordingStatus.recording => '正在内录',
  InternalRecordingStatus.stopping => '正在结束并保存录屏',
  InternalRecordingStatus.importingMedia => '正在导入录屏视频',
  InternalRecordingStatus.extractingAudio => '正在分离录屏音频',
  InternalRecordingStatus.registeringLocal => '正在保存本地音频',
  InternalRecordingStatus.handingOff => '正在上传并创建转写任务',
  InternalRecordingStatus.completed => '已交给后台转写',
  InternalRecordingStatus.cancelled => '已取消录屏',
  InternalRecordingStatus.failed => '内录需要处理',
};

String _statusMessage(InternalRecordingStatus status) => switch (status) {
  InternalRecordingStatus.importingMedia =>
    '请选择已有录屏视频，最多 30 分钟、500MB。复制完成后自动分离音频；不会上传视频。',
  InternalRecordingStatus.awaitingConsent =>
    'iOS 请在系统弹窗中选择「无限花火内录」并确认开始；Android 请同意系统录屏与音频权限。授权前不会录制。',
  InternalRecordingStatus.recording => '现在可以切换到目标 App 播放内容。可从消息中心返回这里结束录屏。',
  InternalRecordingStatus.stopping => '正在等待系统完成视频文件，请勿强制退出应用。',
  InternalRecordingStatus.extractingAudio =>
    '录屏文件已保留，正在提取音轨。只会上传分离后的音频，不上传录屏视频。',
  InternalRecordingStatus.registeringLocal => '正在将音频保存到当前账户的录音文件中。',
  InternalRecordingStatus.handingOff => '后台会继续上传、转写并生成纲要，可以离开当前页面。',
  InternalRecordingStatus.completed => '音频已保存，后续进度请在转写任务中查看。',
  InternalRecordingStatus.cancelled => '本次没有创建转写任务。再次开始需要重新同意系统录屏。',
  _ => '使用系统录屏获取应用播放声音。录屏结束后自动分离音频并进入上传转写流程。',
};

String _errorMessage(String code) {
  if (code.contains('CHECKPOINT') ||
      code == 'SCREEN_CAPTURE_RESET_REQUIRES_STOP') {
    return '恢复记录暂时无法读取。可以重试；若持续失败，请先停止系统录屏，再隔离异常记录并重新开始。已有音频不会删除。';
  }
  if (code.contains('CLEANUP')) {
    return '音频已保留，但录屏中间文件尚未清理完成，请重试。不会重复上传。';
  }
  if (code.contains('IMPORT')) {
    return '录屏视频导入失败，请选择含音轨的 MP4 文件，时长不超过 30 分钟、大小不超过 500MB。';
  }
  if (code == 'RECORDING_LOGIN_REQUIRED') {
    return '请先登录账户，再开始内录。';
  }
  if (code == 'SCREEN_CAPTURE_ANDROID_VERSION_UNSUPPORTED') {
    return '当前版本无法通过应用内接口采集系统声音。可以使用设备自带工具录屏，再通过「导入已有录屏视频」分离音频；不会改用麦克风录音。';
  }
  if (code == 'SCREEN_CAPTURE_IOS_SIMULATOR_UNSUPPORTED') {
    return 'iOS 模拟器不支持此录屏功能，请在支持的真实 iPhone 上使用。';
  }
  if (code.contains('IOS_VERSION')) {
    return '当前系统版本不支持内录，请使用本应用支持的 iOS 15 或更新系统。';
  }
  if (code.contains('APP_GROUP') || code.contains('EXTENSION_UNAVAILABLE')) {
    return '录屏扩展未正确安装或未获得共享容器授权，请更新或重新安装应用。';
  }
  if (code.contains('PERMISSION')) {
    return '未获得系统录音权限。Android 系统声音采集也需要此权限，请在设置中允许后重新开始。';
  }
  if (code.contains('ALREADY_ACTIVE') || code.contains('SESSION_MISMATCH')) {
    return '已有其他录屏任务占用系统，请先结束该任务后再尝试。';
  }
  if (code.contains('AUDIO_TOO_SHORT')) {
    return '有效音频不足 3 秒，请播放目标内容并录制更长时间后重新尝试。';
  }
  if (code.contains('AUDIO_UNAVAILABLE') || code.contains('AUDIO_SILENT')) {
    return '录屏中没有获取到有效声音。请确认目标 App 正在播放声音，且允许录屏采集；受保护内容可能无法采集。';
  }
  if (code.contains('AUDIO_EXPORT')) {
    return '音频分离失败，原录屏文件已保留，可以重试同一文件或重新录制。';
  }
  if (code.contains('CHECKPOINT') ||
      code.contains('STORAGE') ||
      code.contains('REGISTER')) {
    return '保存录屏或音频失败，请检查可用空间后重试。已有文件不会被自动替换。';
  }
  if (code.contains('INTERRUPTED') || code.contains('SYSTEM_STOPPED')) {
    return '系统已中断录屏，未获得可处理的完整文件，请重新录制。';
  }
  if (code.contains('STOP')) {
    return '系统尚未完成录屏停止，请返回系统录屏入口停止，或稍后重试。';
  }
  if (code.contains('UPLOAD') || code.contains('HANDOFF')) {
    return '上传或转写任务交接失败，已保留本地音频，请检查网络后重试。';
  }
  if (code.contains('UNSUPPORTED') || code.contains('DRIVER')) {
    return '当前设备或应用版本暂不支持录屏声音采集，可导入已有录音。';
  }
  return '内录未完成，请重试；若没有录到有效音频，请重新播放内容并录制。';
}

String _duration(int seconds) {
  final safe = seconds.clamp(0, 1800);
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(safe ~/ 60)}:${two(safe % 60)}';
}
