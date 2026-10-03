import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/bootstrap/home_widget_snapshot_sync.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../recording_card/application/recording_card_controller.dart';
import 'v3_recording_card_battery_badge.dart';
import 'v3_recording_card_connection_dialog.dart';

export 'v3_recording_card_battery_badge.dart';

const _bluetoothPoweredOffGuidance = '请先在控制中心或系统设置中打开手机蓝牙，然后返回应用点击连接录音卡。';

bool _recordingCardBluetoothIsPoweredOff(RecordingCardControllerState state) {
  return state.lastErrorCode == 'RECORDING_CARD_BLUETOOTH_POWERED_OFF' ||
      state.snapshot.deviceState.permissionProblem == 'bluetooth_powered_off';
}

enum _RecordingCardLiveStatus {
  bluetoothOff,
  disconnected,
  connecting,
  error,
  recording,
  paused,
  transferring,
  connected,
}

_RecordingCardLiveStatus _recordingCardConnectionStatus({
  required RecordingCardDeviceState device,
  required bool bluetoothPoweredOff,
}) {
  if (bluetoothPoweredOff) return _RecordingCardLiveStatus.bluetoothOff;
  return switch (device.connectionState) {
    RecordingCardConnectionState.disconnected =>
      _RecordingCardLiveStatus.disconnected,
    RecordingCardConnectionState.connecting =>
      _RecordingCardLiveStatus.connecting,
    RecordingCardConnectionState.error => _RecordingCardLiveStatus.error,
    RecordingCardConnectionState.connected =>
      _RecordingCardLiveStatus.connected,
  };
}

_RecordingCardLiveStatus _recordingCardLiveStatus({
  required RecordingCardDeviceState device,
  required RecordingCardRecordingInfo recording,
  required bool transferActive,
  required bool bluetoothPoweredOff,
}) {
  final connectionStatus = _recordingCardConnectionStatus(
    device: device,
    bluetoothPoweredOff: bluetoothPoweredOff,
  );
  if (connectionStatus != _RecordingCardLiveStatus.connected) {
    return connectionStatus;
  }
  if (recording.state == RecordingCardRecordingState.recording) {
    return _RecordingCardLiveStatus.recording;
  }
  if (recording.state == RecordingCardRecordingState.paused) {
    return _RecordingCardLiveStatus.paused;
  }
  if (transferActive) return _RecordingCardLiveStatus.transferring;
  return _RecordingCardLiveStatus.connected;
}

String _recordingCardLiveStatusLabel(
  _RecordingCardLiveStatus status, {
  String connectedLabel = '已连接',
}) {
  return switch (status) {
    _RecordingCardLiveStatus.bluetoothOff => '蓝牙已关闭',
    _RecordingCardLiveStatus.disconnected => '未连接',
    _RecordingCardLiveStatus.connecting => '连接中',
    _RecordingCardLiveStatus.error => '连接异常',
    _RecordingCardLiveStatus.recording => '录音中',
    _RecordingCardLiveStatus.paused => '已暂停',
    _RecordingCardLiveStatus.transferring => '文件传输中',
    _RecordingCardLiveStatus.connected => connectedLabel,
  };
}

enum RecordingCardWidgetAction {
  refresh,
  connect,
  start,
  pause,
  resume;

  static RecordingCardWidgetAction? fromRoute(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    for (final action in values) {
      if (action.name == normalized) return action;
    }
    return null;
  }
}

class V3RecordingCardControlPage extends ConsumerStatefulWidget {
  const V3RecordingCardControlPage({
    this.initialWidgetAction,
    this.widgetSnapshotEpochMs,
    this.widgetActionToken,
    super.key,
  });

  final RecordingCardWidgetAction? initialWidgetAction;
  final int? widgetSnapshotEpochMs;
  final String? widgetActionToken;

  @override
  ConsumerState<V3RecordingCardControlPage> createState() =>
      _V3RecordingCardControlPageState();
}

class _V3RecordingCardControlPageState
    extends ConsumerState<V3RecordingCardControlPage>
    with _RecordingCardControlActions<V3RecordingCardControlPage> {
  bool _handledWidgetAction = false;
  int _widgetActionGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialWidgetAction != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_handleInitialWidgetAction());
      });
    }
  }

  @override
  void didUpdateWidget(covariant V3RecordingCardControlPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialWidgetAction == widget.initialWidgetAction &&
        oldWidget.widgetSnapshotEpochMs == widget.widgetSnapshotEpochMs &&
        oldWidget.widgetActionToken == widget.widgetActionToken) {
      return;
    }
    _widgetActionGeneration += 1;
    _handledWidgetAction = false;
    if (widget.initialWidgetAction != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_handleInitialWidgetAction());
      });
    }
  }

  Future<void> _handleInitialWidgetAction() async {
    final action = widget.initialWidgetAction;
    if (_handledWidgetAction || action == null || !mounted) return;
    _handledWidgetAction = true;
    final generation = _widgetActionGeneration;
    final revision = widget.widgetSnapshotEpochMs;
    final mutating =
        action == RecordingCardWidgetAction.start ||
        action == RecordingCardWidgetAction.pause ||
        action == RecordingCardWidgetAction.resume;
    bool authorized() =>
        mounted &&
        generation == _widgetActionGeneration &&
        ref
            .read(homeWidgetRecordingActionBindingProvider)
            .authorizes(widget.widgetActionToken, revision, DateTime.now());
    if (mutating && !authorized()) {
      showV3Snack(context, '小组件状态或设备已变化，请确认当前状态后操作');
      return;
    }
    final fingerprint = mutating
        ? ref.read(homeWidgetRecordingActionBindingProvider).deviceFingerprint
        : null;
    bool claimAuthorization() =>
        authorized() &&
        ref
            .read(homeWidgetRecordingActionBindingProvider)
            .claim(widget.widgetActionToken, revision, DateTime.now());
    final before = ref.read(recordingCardControllerProvider).state;
    if (before.hasActiveTransfer ||
        (before.status != RecordingCardControllerStatus.idle &&
            before.status != RecordingCardControllerStatus.error)) {
      showV3Snack(context, '录音卡正在忙，请稍后再试');
      return;
    }
    if (!before.snapshot.deviceState.isOperationallyConnected) {
      await _connect();
      return;
    }
    await _readRecordingState();
    if (!mounted || generation != _widgetActionGeneration) return;
    if (mutating && !authorized()) {
      showV3Snack(context, '小组件状态或设备已变化，请确认当前状态后操作');
      return;
    }
    final controller = ref.read(recordingCardControllerProvider);
    final state = controller.state;
    if (!state.snapshot.deviceState.isOperationallyConnected) {
      await _connect();
      return;
    }
    if (state.lastErrorCode != null) {
      showV3Snack(context, '录音卡状态刷新失败，请重试');
      return;
    }
    if (state.hasActiveTransfer ||
        (state.status != RecordingCardControllerStatus.idle &&
            state.status != RecordingCardControllerStatus.error)) {
      showV3Snack(context, '录音卡正在忙，请稍后再试');
      return;
    }
    final recordingState = state.snapshot.recordingInfo.state;
    if (action == RecordingCardWidgetAction.refresh) return;
    final command = switch ((action, recordingState)) {
      (RecordingCardWidgetAction.start, RecordingCardRecordingState.idle) => (
        '录音已开始',
        (RecordingCardController card) => card.startRecording(
          expectedDeviceFingerprint: fingerprint,
          canExecute: claimAuthorization,
        ),
      ),
      (
        RecordingCardWidgetAction.pause,
        RecordingCardRecordingState.recording,
      ) =>
        (
          '录音已暂停',
          (RecordingCardController card) => card.pauseRecording(
            expectedDeviceFingerprint: fingerprint,
            canExecute: claimAuthorization,
          ),
        ),
      (RecordingCardWidgetAction.resume, RecordingCardRecordingState.paused) =>
        (
          '录音已继续',
          (RecordingCardController card) => card.resumeRecording(
            expectedDeviceFingerprint: fingerprint,
            canExecute: claimAuthorization,
          ),
        ),
      _ => null,
    };
    if (command == null) {
      if (action != RecordingCardWidgetAction.connect) {
        showV3Snack(context, '录音卡状态已更新，请重新操作');
      }
      return;
    }
    await _runCommand(successMessage: command.$1, command: command.$2);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(recordingCardControllerProvider);
    final state = controller.state;
    final snapshot = state.snapshot;
    final device = snapshot.deviceState;
    final recording = snapshot.recordingInfo;
    final connected = device.isOperationallyConnected;
    final operationBusy =
        state.status != RecordingCardControllerStatus.idle &&
        state.status != RecordingCardControllerStatus.error;
    final busy = operationBusy || state.hasActiveTransfer;
    final connectionBusy =
        state.status == RecordingCardControllerStatus.connecting ||
        device.connectionState == RecordingCardConnectionState.connecting;
    final connectionLocked = busy || connectionBusy;
    final bluetoothPoweredOff = _recordingCardBluetoothIsPoweredOff(state);
    final errorCode = state.lastErrorCode;

    return V3PageScaffold(
      title: '录音卡',
      centerTitle: true,
      fallbackRoute: '/v3/feed',
      backBehavior: V3BackBehavior.fallbackOnly,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        _DeviceCard(
          device: device,
          connectionBusy: connectionBusy,
          connectionLocked: connectionLocked,
          bluetoothPoweredOff: bluetoothPoweredOff,
          onConnectionPressed: () {
            if (connected) {
              unawaited(_confirmDisconnect());
            } else {
              unawaited(_connect());
            }
          },
          onOpenManagement: () => context.push('/v3/recording-card'),
          onDetails: () => context.push('/v3/recording-card/details'),
        ),
        if (bluetoothPoweredOff) ...[
          const SizedBox(height: 10),
          const _BluetoothPoweredOffGuidance(),
        ],
        const SizedBox(height: 14),
        _RecordingControlCard(
          device: device,
          recording: recording,
          busy: busy,
          fileUploadActive: state.hasActiveTransfer,
          bluetoothPoweredOff: bluetoothPoweredOff,
          onRefresh: () => unawaited(_readRecordingState(showResult: true)),
          onStart:
              connected &&
                  !busy &&
                  recording.state == RecordingCardRecordingState.idle
              ? () => unawaited(
                  _runCommand(
                    successMessage: '录音已开始',
                    command: (card) => card.startRecording(),
                  ),
                )
              : null,
          onPauseOrResume:
              connected &&
                  !busy &&
                  recording.state != RecordingCardRecordingState.idle
              ? () => unawaited(
                  _runCommand(
                    successMessage:
                        recording.state == RecordingCardRecordingState.recording
                        ? '录音已暂停'
                        : '录音已继续',
                    command:
                        recording.state == RecordingCardRecordingState.recording
                        ? (card) => card.pauseRecording()
                        : (card) => card.resumeRecording(),
                  ),
                )
              : null,
          onStop:
              connected &&
                  !busy &&
                  recording.state != RecordingCardRecordingState.idle
              ? () => unawaited(
                  _runCommand(
                    successMessage: '录音已结束',
                    command: (card) => card.stopRecording(),
                  ),
                )
              : null,
        ),
        const SizedBox(height: 14),
        V3OutlineButton(
          key: const ValueKey('recording-card-open-management'),
          label: '设备与文件管理',
          icon: Icons.folder_open_outlined,
          onPressed: () => context.push('/v3/recording-card'),
        ),
        if (errorCode != null && !bluetoothPoweredOff) ...[
          const SizedBox(height: 14),
          _ErrorPanel(errorCode: errorCode),
        ],
      ],
    );
  }
}

mixin _RecordingCardControlActions<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  Future<void>? _stateReadInFlight;

  Future<void> _connect() async {
    final controller = ref.read(recordingCardControllerProvider);
    await showV3RecordingCardConnectionDialog(context, controller: controller);
    if (!mounted) return;
    if (ref
        .read(recordingCardControllerProvider)
        .state
        .snapshot
        .deviceState
        .isOperationallyConnected) {
      await _readRecordingStateAfterConnectionSettles();
    }
  }

  Future<void> _readRecordingStateAfterConnectionSettles() async {
    for (var attempt = 0; attempt < 100; attempt += 1) {
      if (!mounted) return;
      final state = ref.read(recordingCardControllerProvider).state;
      if (!state.snapshot.deviceState.isOperationallyConnected) return;
      if (state.status == RecordingCardControllerStatus.error) return;
      if (!state.hasActiveTransfer &&
          state.status == RecordingCardControllerStatus.idle) {
        await _readRecordingState();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '断开录音卡连接？',
        message: '断开后无法继续控制录音，稍后可以重新连接。',
        primaryLabel: '断开',
        onPrimary: () => Navigator.pop(dialogContext, true),
        onCancel: () => Navigator.pop(dialogContext, false),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runCommand(
      successMessage: '录音卡已断开',
      command: (controller) => controller.disconnect(),
    );
  }

  Future<void> _readRecordingState({bool showResult = false}) {
    final existing = _stateReadInFlight;
    if (existing != null) return existing;
    if (!mounted) return Future<void>.value();
    final controller = ref.read(recordingCardControllerProvider);
    final state = controller.state;
    if (!state.snapshot.deviceState.isOperationallyConnected ||
        state.hasActiveTransfer ||
        (state.status != RecordingCardControllerStatus.idle &&
            state.status != RecordingCardControllerStatus.error)) {
      return Future<void>.value();
    }
    final future = controller.readRecordingState();
    _stateReadInFlight = future;
    return future.whenComplete(() {
      _stateReadInFlight = null;
      if (!mounted || !showResult) return;
      final errorCode = controller.state.lastErrorCode;
      showV3Snack(context, errorCode ?? '录音卡状态已刷新');
    });
  }

  Future<void> _runCommand({
    required String successMessage,
    required Future<void> Function(RecordingCardController controller) command,
  }) async {
    final controller = ref.read(recordingCardControllerProvider);
    await command(controller);
    if (!mounted) return;
    showV3Snack(context, controller.state.lastErrorCode ?? successMessage);
  }
}

class V3RecordingCardCompactControl extends ConsumerStatefulWidget {
  const V3RecordingCardCompactControl({
    required this.onOpenManagement,
    super.key,
  });

  final VoidCallback onOpenManagement;

  @override
  ConsumerState<V3RecordingCardCompactControl> createState() =>
      _V3RecordingCardCompactControlState();
}

class _V3RecordingCardCompactControlState
    extends ConsumerState<V3RecordingCardCompactControl>
    with _RecordingCardControlActions<V3RecordingCardCompactControl> {
  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final controller = ref.watch(recordingCardControllerProvider);
    final state = controller.state;
    final device = state.snapshot.deviceState;
    final recording = state.snapshot.recordingInfo;
    final connected = device.isOperationallyConnected;
    final operationBusy =
        state.status != RecordingCardControllerStatus.idle &&
        state.status != RecordingCardControllerStatus.error;
    final busy = operationBusy || state.hasActiveTransfer;
    final connectionBusy =
        state.status == RecordingCardControllerStatus.connecting ||
        device.connectionState == RecordingCardConnectionState.connecting;
    final connectionLocked = busy || connectionBusy;
    final fileUploadActive = state.hasActiveTransfer;
    final paused = recording.state == RecordingCardRecordingState.paused;
    final bluetoothPoweredOff = _recordingCardBluetoothIsPoweredOff(state);

    Widget managementTitle() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            key: const ValueKey('profile-recording-card-title-icon'),
            Icons.settings_input_component_outlined,
            size: 17,
            color: colors.accent,
          ),
          const SizedBox(width: 6),
          const Text(
            '录音卡',
            maxLines: 1,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );

    Widget batteryBadge() => V3RecordingCardBatteryBadge(
      percent: device.batteryPercent,
      valueKey: const ValueKey('profile-recording-card-battery'),
    );

    Widget managementChevron() => SizedBox(
      key: const ValueKey('profile-recording-card-open-management-chevron'),
      width: 28,
      height: 32,
      child: Center(
        child: Icon(Icons.chevron_right_rounded, size: 17, color: colors.muted),
      ),
    );

    Widget elapsed() => InkWell(
      onTap: widget.onOpenManagement,
      borderRadius: BorderRadius.circular(8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _RecordingElapsed(
          recording: recording,
          compact: true,
          valueKey: const ValueKey('profile-recording-card-elapsed'),
        ),
      ),
    );

    final liveStatus = _recordingCardLiveStatus(
      device: device,
      recording: recording,
      transferActive: fileUploadActive,
      bluetoothPoweredOff: bluetoothPoweredOff,
    );
    final connectionLabel = _recordingCardLiveStatusLabel(liveStatus);
    final connectionActionLabel = fileUploadActive
        ? '正在传输录音文件，暂时不能操作录音卡'
        : bluetoothPoweredOff
        ? '请先打开手机蓝牙后重试'
        : switch (device.connectionState) {
            RecordingCardConnectionState.connected => '断开录音卡',
            RecordingCardConnectionState.connecting => '正在连接录音卡',
            RecordingCardConnectionState.disconnected ||
            RecordingCardConnectionState.error => '连接录音卡',
          };

    Widget connectionButton() => Tooltip(
      message: '$connectionLabel，$connectionActionLabel',
      child: V3CompactActionTarget(
        key: const ValueKey('profile-recording-card-connection-target'),
        semanticLabel: '$connectionLabel，$connectionActionLabel',
        width: 68,
        onTap: connectionLocked
            ? null
            : connected
            ? _confirmDisconnect
            : _connect,
        child: SizedBox(
          width: 68,
          height: 31,
          child: connected
              ? OutlinedButton(
                  key: const ValueKey('profile-recording-card-disconnect'),
                  onPressed: connectionLocked ? null : _confirmDisconnect,
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    foregroundColor: colors.success,
                    textStyle: const TextStyle(fontSize: 10.5),
                  ),
                  child: Text(connectionLabel),
                )
              : FilledButton(
                  key: const ValueKey('profile-recording-card-connect'),
                  onPressed: connectionLocked ? null : _connect,
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    backgroundColor: bluetoothPoweredOff
                        ? colors.danger
                        : device.connectionState ==
                              RecordingCardConnectionState.error
                        ? colors.danger
                        : colors.primary,
                    foregroundColor: colors.onPrimary,
                    textStyle: const TextStyle(fontSize: 10.5),
                  ),
                  child: connectionBusy
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colors.onPrimary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Text('连接中'),
                          ],
                        )
                      : Text(connectionLabel),
                ),
        ),
      ),
    );

    Widget controls() => Row(
      children: [
        Expanded(
          child: _CompactControlButton(
            key: const ValueKey('profile-recording-card-start'),
            icon: Icons.fiber_manual_record_rounded,
            label: '开始',
            enabled:
                connected &&
                !busy &&
                recording.state == RecordingCardRecordingState.idle,
            onPressed: () => unawaited(
              _runCommand(
                successMessage: '录音已开始',
                command: (card) => card.startRecording(),
              ),
            ),
            activeColor: colors.danger,
          ),
        ),
        Expanded(
          child: _CompactControlButton(
            key: const ValueKey('profile-recording-card-pause-resume'),
            icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            label: paused ? '继续' : '暂停',
            enabled:
                connected &&
                !busy &&
                recording.state != RecordingCardRecordingState.idle,
            onPressed: () => unawaited(
              _runCommand(
                successMessage:
                    recording.state == RecordingCardRecordingState.recording
                    ? '录音已暂停'
                    : '录音已继续',
                command:
                    recording.state == RecordingCardRecordingState.recording
                    ? (card) => card.pauseRecording()
                    : (card) => card.resumeRecording(),
              ),
            ),
          ),
        ),
        Expanded(
          child: _CompactControlButton(
            key: const ValueKey('profile-recording-card-stop'),
            icon: Icons.stop_rounded,
            label: '结束',
            enabled:
                connected &&
                !busy &&
                recording.state != RecordingCardRecordingState.idle,
            onPressed: () => unawaited(
              _runCommand(
                successMessage: '录音已结束',
                command: (card) => card.stopRecording(),
              ),
            ),
          ),
        ),
      ],
    );

    return Semantics(
      label: '录音卡控制',
      child: V3Card(
        key: const ValueKey('profile-recording-card-control-card'),
        radius: 18,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 220;
            return Column(
              children: [
                Semantics(
                  button: true,
                  label: '进入设备与文件管理',
                  child: InkWell(
                    key: const ValueKey(
                      'profile-recording-card-open-management',
                    ),
                    onTap: widget.onOpenManagement,
                    child: Row(
                      children: [
                        if (narrow)
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: managementTitle(),
                            ),
                          )
                        else
                          managementTitle(),
                        const SizedBox(width: 4),
                        batteryBadge(),
                        const Spacer(),
                        managementChevron(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: elapsed()),
                    const SizedBox(width: 6),
                    connectionButton(),
                  ],
                ),
                const SizedBox(height: 5),
                controls(),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BluetoothPoweredOffGuidance extends StatelessWidget {
  const _BluetoothPoweredOffGuidance();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      key: const ValueKey('recording-card-control-bluetooth-off-guidance'),
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.bluetooth_disabled_rounded,
              size: 17,
              color: colors.danger,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _bluetoothPoweredOffGuidance,
              style: TextStyle(
                color: colors.muted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.connectionBusy,
    required this.connectionLocked,
    required this.bluetoothPoweredOff,
    required this.onConnectionPressed,
    required this.onOpenManagement,
    required this.onDetails,
  });

  final RecordingCardDeviceState device;
  final bool connectionBusy;
  final bool connectionLocked;
  final bool bluetoothPoweredOff;
  final VoidCallback onConnectionPressed;
  final VoidCallback onOpenManagement;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final connected = device.isOperationallyConnected;
    final liveStatus = _recordingCardConnectionStatus(
      device: device,
      bluetoothPoweredOff: bluetoothPoweredOff,
    );
    final status = _recordingCardLiveStatusLabel(liveStatus);
    final statusIcon = switch (liveStatus) {
      _RecordingCardLiveStatus.bluetoothOff => Icons.bluetooth_disabled_rounded,
      _RecordingCardLiveStatus.disconnected => Icons.info_outline_rounded,
      _RecordingCardLiveStatus.connecting => Icons.sync_rounded,
      _RecordingCardLiveStatus.error => Icons.error_outline_rounded,
      _RecordingCardLiveStatus.recording => Icons.fiber_manual_record_rounded,
      _RecordingCardLiveStatus.paused => Icons.pause_circle_outline_rounded,
      _RecordingCardLiveStatus.transferring => Icons.swap_vert_rounded,
      _RecordingCardLiveStatus.connected => Icons.check_circle_rounded,
    };
    final statusColor = switch (liveStatus) {
      _RecordingCardLiveStatus.bluetoothOff ||
      _RecordingCardLiveStatus.error ||
      _RecordingCardLiveStatus.recording => colors.danger,
      _RecordingCardLiveStatus.disconnected => colors.muted,
      _RecordingCardLiveStatus.connecting ||
      _RecordingCardLiveStatus.paused => colors.accent,
      _RecordingCardLiveStatus.transferring => colors.primary,
      _RecordingCardLiveStatus.connected => colors.success,
    };
    return V3Card(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: '打开录音卡文件管理',
              child: InkWell(
                onTap: onOpenManagement,
                child: Row(
                  children: [
                    Container(
                      key: const ValueKey('recording-card-control-device-icon'),
                      width: 54,
                      height: 54,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: colors.surface.withValues(alpha: .72),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: colors.line),
                      ),
                      child: Image.asset(
                        'assets/images/recording_card_device.png',
                        fit: BoxFit.contain,
                        semanticLabel: '无限花火录音卡',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.displayName ?? '无限花火录音卡',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              height: 1.1,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Row(
                            children: [
                              Icon(statusIcon, size: 15, color: statusColor),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: colors.muted,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 5),
                              V3RecordingCardBatteryBadge(
                                percent: device.batteryPercent,
                                valueKey: const ValueKey(
                                  'recording-card-control-device-battery',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          V3CompactActionTarget(
            key: const ValueKey('recording-card-control-connection-target'),
            semanticLabel: connected ? '断开录音卡' : '连接录音卡',
            width: 62,
            onTap: connectionLocked ? null : onConnectionPressed,
            child: SizedBox(
              width: 62,
              height: 34,
              child: connected
                  ? OutlinedButton(
                      key: const ValueKey('recording-card-control-disconnect'),
                      onPressed: connectionLocked ? null : onConnectionPressed,
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('断开'),
                    )
                  : FilledButton(
                      key: const ValueKey('recording-card-control-connect'),
                      onPressed: connectionLocked ? null : onConnectionPressed,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        backgroundColor: bluetoothPoweredOff
                            ? colors.danger
                            : colors.primary,
                        foregroundColor: colors.onPrimary,
                      ),
                      child: connectionBusy
                          ? SizedBox.square(
                              dimension: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colors.onPrimary,
                              ),
                            )
                          : Text(bluetoothPoweredOff ? '重试' : '连接'),
                    ),
            ),
          ),
          IconButton(
            key: const ValueKey('recording-card-control-details'),
            tooltip: '录音卡设备详情',
            onPressed: onDetails,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.chevron_right, color: colors.muted),
          ),
        ],
      ),
    );
  }
}

class _RecordingControlCard extends StatelessWidget {
  const _RecordingControlCard({
    required this.device,
    required this.recording,
    required this.busy,
    required this.fileUploadActive,
    required this.bluetoothPoweredOff,
    required this.onRefresh,
    this.onStart,
    this.onPauseOrResume,
    this.onStop,
  });

  final RecordingCardDeviceState device;
  final RecordingCardRecordingInfo recording;
  final bool busy;
  final bool fileUploadActive;
  final bool bluetoothPoweredOff;
  final VoidCallback onRefresh;
  final VoidCallback? onStart;
  final VoidCallback? onPauseOrResume;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final paused = recording.state == RecordingCardRecordingState.paused;
    return V3Card(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mic_none_rounded, color: colors.ink),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  '录音控制',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ),
              _StatusBadge(
                device: device,
                recording: recording,
                fileUploadActive: fileUploadActive,
                bluetoothPoweredOff: bluetoothPoweredOff,
                enabled: !busy && device.isOperationallyConnected,
                onPressed: onRefresh,
              ),
            ],
          ),
          const SizedBox(height: 20),
          Center(child: _RecordingElapsed(recording: recording)),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _ControlButton(
                key: const ValueKey('recording-card-control-start'),
                icon: Icons.fiber_manual_record_rounded,
                label: '开始',
                enabled: onStart != null,
                onPressed: onStart,
                activeColor: colors.danger,
              ),
              _ControlButton(
                key: const ValueKey('recording-card-control-pause-resume'),
                icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                label: paused ? '继续' : '暂停',
                enabled: onPauseOrResume != null,
                onPressed: onPauseOrResume,
              ),
              _ControlButton(
                key: const ValueKey('recording-card-control-stop'),
                icon: Icons.stop_rounded,
                label: '结束',
                enabled: onStop != null,
                onPressed: onStop,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecordingElapsed extends StatefulWidget {
  const _RecordingElapsed({
    required this.recording,
    this.compact = false,
    this.valueKey,
  });

  final RecordingCardRecordingInfo recording;
  final bool compact;
  final Key? valueKey;

  @override
  State<_RecordingElapsed> createState() => _RecordingElapsedState();
}

class _RecordingElapsedState extends State<_RecordingElapsed>
    with WidgetsBindingObserver {
  Timer? _ticker;
  bool _foreground = true;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = _showsElapsedTime(WidgetsBinding.instance.lifecycleState);
    _syncTicker();
  }

  bool _showsElapsedTime(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _showsElapsedTime(state);
    _syncTicker();
    if (_foreground && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _RecordingElapsed oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    final shouldTick =
        _foreground &&
        _visible &&
        widget.recording.state == RecordingCardRecordingState.recording;
    if (shouldTick && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!shouldTick) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _formatClock(recordingCardElapsedSeconds(widget.recording)),
      key: widget.valueKey ?? const ValueKey('recording-card-control-elapsed'),
      style: TextStyle(
        fontSize: widget.compact ? 23 : 36,
        height: 1,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
        letterSpacing: 0,
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.device,
    required this.recording,
    required this.fileUploadActive,
    required this.bluetoothPoweredOff,
    required this.enabled,
    required this.onPressed,
  });

  final RecordingCardDeviceState device;
  final RecordingCardRecordingInfo recording;
  final bool fileUploadActive;
  final bool bluetoothPoweredOff;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final liveStatus = _recordingCardLiveStatus(
      device: device,
      recording: recording,
      transferActive: fileUploadActive,
      bluetoothPoweredOff: bluetoothPoweredOff,
    );
    final label = _recordingCardLiveStatusLabel(
      liveStatus,
      connectedLabel: '待机',
    );
    final color = switch (liveStatus) {
      _RecordingCardLiveStatus.bluetoothOff ||
      _RecordingCardLiveStatus.error ||
      _RecordingCardLiveStatus.recording => colors.danger,
      _RecordingCardLiveStatus.disconnected => colors.muted,
      _RecordingCardLiveStatus.connecting ||
      _RecordingCardLiveStatus.paused => colors.accent,
      _RecordingCardLiveStatus.transferring => colors.primary,
      _RecordingCardLiveStatus.connected => colors.success,
    };
    return Tooltip(
      message: enabled ? '刷新录音卡状态' : label,
      child: Material(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          key: const ValueKey('recording-card-control-status'),
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onPressed;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final color = enabled ? activeColor ?? colors.ink : colors.muted;
    return SizedBox(
      width: 72,
      child: Column(
        children: [
          IconButton.filledTonal(
            tooltip: label,
            onPressed: enabled ? onPressed : null,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(48),
              foregroundColor: color,
              backgroundColor: color.withValues(alpha: enabled ? .10 : .05),
              disabledForegroundColor: colors.muted.withValues(alpha: .45),
              disabledBackgroundColor: colors.surfaceMuted,
            ),
            icon: Icon(icon, size: 23),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            style: TextStyle(
              color: enabled ? colors.text : colors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactControlButton extends StatelessWidget {
  const _CompactControlButton({
    required super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final color = enabled ? activeColor ?? colors.ink : colors.muted;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 44,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 19,
                color: color.withValues(alpha: enabled ? 1 : .42),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: enabled
                      ? colors.text
                      : colors.muted.withValues(alpha: .55),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.errorCode});

  final String errorCode;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('recording-card-control-error'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.danger.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.danger.withValues(alpha: .28)),
        ),
        child: Text(
          errorCode,
          style: TextStyle(
            color: colors.danger,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

String _formatClock(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  final remainingSeconds = safe % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${remainingSeconds.toString().padLeft(2, '0')}';
}
