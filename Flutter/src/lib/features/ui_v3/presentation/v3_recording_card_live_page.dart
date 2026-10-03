import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../recording_card/application/recording_card_auto_sync_coordinator.dart';
import '../../recording_card/application/recording_card_controller.dart';
import '../../recording_card/domain/recording_card_auto_sync.dart';
import '../../recording_card/domain/recording_card_sync_ledger.dart';
import '../../recordings/application/recording_library_ui_controller.dart';
import 'v3_local_recording_library_page.dart';
import 'v3_recording_card_battery_badge.dart';
import 'v3_recording_card_connection_dialog.dart';
import 'v3_recording_library_surfaces.dart';

const _bluetoothPoweredOffGuidance = '请先在控制中心或系统设置中打开手机蓝牙，然后返回应用点击连接录音卡。';

bool _recordingCardBluetoothIsPoweredOff(RecordingCardControllerState state) {
  return state.lastErrorCode == 'RECORDING_CARD_BLUETOOTH_POWERED_OFF' ||
      state.snapshot.deviceState.permissionProblem == 'bluetooth_powered_off';
}

String _recordingCardActionFeedback(
  String? errorCode, {
  required String successMessage,
}) {
  if (errorCode == 'RECORDING_CARD_BLUETOOTH_POWERED_OFF') {
    return _bluetoothPoweredOffGuidance;
  }
  if (errorCode != null &&
      recordingCardFailureStage(errorCode) ==
          RecordingCardFailureStage.coordination) {
    return '录音卡正在处理其他任务，请等待当前任务完成';
  }
  return errorCode ?? successMessage;
}

class V3RecordingCardLivePage extends ConsumerStatefulWidget {
  const V3RecordingCardLivePage({
    this.initialTab = V3RecordingLibraryTab.local,
    this.focusLibrary = false,
    super.key,
  });

  final V3RecordingLibraryTab initialTab;
  final bool focusLibrary;

  @override
  ConsumerState<V3RecordingCardLivePage> createState() =>
      _V3RecordingCardLivePageState();
}

class _V3RecordingCardLivePageState
    extends ConsumerState<V3RecordingCardLivePage> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _libraryKey = GlobalKey();
  late final V3RecordingLibrarySectionController _librarySectionController;
  late final RecordingLibraryUiController _uiController;
  String? _dismissedLowBatteryDevice;

  @override
  void initState() {
    super.initState();
    _uiController = ref.read(recordingLibraryUiControllerProvider)
      ..addListener(_onUiControllerChanged);
    _librarySectionController = V3RecordingLibrarySectionController()
      ..addListener(_onLibrarySelectionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _uiController.reset(tab: widget.initialTab);
      unawaited(
        ref
            .read(recordingCardControllerProvider)
            .ensureFilesLoadedForCurrentConnection(),
      );
      if (widget.focusLibrary) _scrollToLibrary();
    });
  }

  void _onUiControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _uiController.removeListener(_onUiControllerChanged);
    if (_uiController.batchMode) _uiController.setBatchMode(false);
    _librarySectionController
      ..removeListener(_onLibrarySelectionChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = ref.watch(recordingCardControllerProvider);
    final uiController = _uiController;
    final snapshot = card.state.snapshot;
    final device = snapshot.deviceState;
    final connected = device.isOperationallyConnected;
    final controllerOperationBusy =
        card.state.status != RecordingCardControllerStatus.idle &&
        card.state.status != RecordingCardControllerStatus.error;
    final connectionBusy =
        card.state.status == RecordingCardControllerStatus.connecting ||
        card.state.status == RecordingCardControllerStatus.authorizing ||
        device.connectionState == RecordingCardConnectionState.connecting;
    final wifiTransferPaused =
        card.state.wifiBatch?.state == RecordingCardWifiBatchState.paused;
    final connectionLocked =
        connectionBusy ||
        controllerOperationBusy ||
        (!wifiTransferPaused &&
            (card.hasActiveDeviceOperation ||
                card.hasActiveTransfer ||
                card.state.wifiBatch?.isActive == true));
    final errorCode = card.state.lastErrorCode;
    final bluetoothPoweredOff = _recordingCardBluetoothIsPoweredOff(card.state);
    final batchSelection = _librarySectionController.selection;
    final batchMode = uiController.batchMode;
    final batteryPercent = device.batteryPercent;
    final deviceIdentity =
        device.safeDeviceFingerprint ??
        device.serialNumber ??
        device.displayName ??
        'recording-card';
    final lowBattery =
        connected &&
        batteryPercent != null &&
        batteryPercent <= 20 &&
        _dismissedLowBatteryDevice != deviceIdentity;
    final page = V3PageScaffold(
      title: '录音卡设备管理',
      centerTitle: true,
      onBack: batchMode ? () => _exitSelectionMode(uiController) : null,
      onTitleTap: batchMode ? null : _scrollToTop,
      fallbackRoute: '/v3/feed',
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
      trailing: batchMode
          ? null
          : IconButton(
              key: const ValueKey<String>(
                'recording-card-management-sync-settings',
              ),
              tooltip: '同步设置',
              onPressed: () => unawaited(_showSyncSettings()),
              icon: const Icon(Icons.more_horiz, size: 30),
            ),
      scrollController: _scrollController,
      showScrollbar: true,
      bottomBar: uiController.batchMode
          ? _LocalRecordingBatchBottomBar(
              selection: batchSelection,
              onDelete: () =>
                  unawaited(_librarySectionController.deleteSelected()),
              onTranscribe: () =>
                  unawaited(_librarySectionController.transcribeSelected()),
            )
          : null,
      children: [
        _DeviceHero(
          device: device,
          connected: connected,
          recording: snapshot.recordingInfo,
          fileTransferActive:
              card.hasActiveTransfer &&
              card.state.wifiBatch?.state != RecordingCardWifiBatchState.paused,
          fileTransferPaused:
              card.state.wifiBatch?.state == RecordingCardWifiBatchState.paused,
          connectionBusy: connectionBusy,
          connectionLocked: connectionLocked,
          bluetoothPoweredOff: bluetoothPoweredOff,
          onConnectionPressed: () {
            if (connected) {
              _confirmDisconnect(context, ref);
              return;
            }
            unawaited(_connectRecordingCard(context, ref));
          },
          onDetails: () => context.push('/v3/recording-card/details'),
        ),
        if (bluetoothPoweredOff) ...[
          const SizedBox(height: 10),
          const _BluetoothPoweredOffGuidance(),
        ],
        if (card.isRefreshingFiles) ...[
          const SizedBox(height: 10),
          V3RecordingDeviceStateBanner(
            key: const ValueKey('recording-card-files-refreshing'),
            title: '正在刷新录音文件',
            subtitle: '列表会自动更新',
            actionLabel: '取消',
            refreshing: true,
            onAction: card.cancelFileRefresh,
          ),
        ] else if (lowBattery) ...[
          const SizedBox(height: 10),
          V3RecordingDeviceStateBanner(
            key: const ValueKey('recording-card-low-battery'),
            title: '录音卡电量较低',
            subtitle: '剩余 $batteryPercent%，建议充电后继续传输',
            actionLabel: '知道了',
            danger: true,
            onAction: () =>
                setState(() => _dismissedLowBatteryDevice = deviceIdentity),
          ),
        ],
        const SizedBox(height: 12),
        KeyedSubtree(
          key: _libraryKey,
          child: V3RecordingLibrarySection(
            initialTab: widget.initialTab,
            automaticDeviceRefresh: false,
            projection: V3RecordingLibraryProjection.recordingCardInventory,
            managementController: _librarySectionController,
            onEnterBatchMode: () => _enterSelectionMode(uiController),
            onExitBatchMode: () => _exitSelectionMode(uiController),
          ),
        ),
        if (errorCode != null && !bluetoothPoweredOff) ...[
          const SizedBox(height: 6),
          _ErrorPanel(errorCode: errorCode),
        ],
      ],
    );
    return PopScope<Object?>(
      canPop: !batchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && batchMode) _exitSelectionMode(uiController);
      },
      child: page,
    );
  }

  void _onLibrarySelectionChanged() {
    if (mounted) setState(() {});
  }

  void _enterSelectionMode(RecordingLibraryUiController controller) {
    _librarySectionController.clearSelection();
    controller.setBatchMode(true);
  }

  void _exitSelectionMode(RecordingLibraryUiController controller) {
    _librarySectionController.clearSelection();
    controller.setBatchMode(false);
    if (mounted) setState(() {});
  }

  void _scrollToLibrary() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = _libraryKey.currentContext;
      if (!mounted || targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: V3MotionTokens.pageTravel,
        curve: Curves.easeOutCubic,
        alignment: .05,
      );
    });
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    unawaited(
      _scrollController.animateTo(
        0,
        duration: V3MotionTokens.pageTravel,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  Future<void> _showSyncSettings() => showV3GlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _RecordingCardSyncSettingsSheet(),
  );
}

class _RecordingCardSyncSettingsSheet extends ConsumerWidget {
  const _RecordingCardSyncSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinator = ref.watch(recordingCardAutoSyncCoordinatorProvider);
    final state = coordinator.state;
    final preferences = state.preferences;
    return V3SheetScaffold(
      key: const ValueKey<String>('recording-card-sync-settings-sheet'),
      title: '同步设置',
      showClose: true,
      child: Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: HuahuoSpacing.compact),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              V3Card(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    _RecordingCardSyncSettingSwitch(
                      valueKey: const ValueKey<String>(
                        'recording-card-auto-sync-switch',
                      ),
                      title: '自动同步录音',
                      description: _recordingCardBackgroundDescription(
                        coordinator.backgroundCapability,
                      ),
                      value: preferences.autoSyncEnabled,
                      onChanged: coordinator.setAutoSyncEnabled,
                    ),
                    const Divider(height: 1),
                    _RecordingCardSyncSettingSwitch(
                      valueKey: const ValueKey<String>(
                        'recording-card-auto-transcription-switch',
                      ),
                      title: '同步后自动转写',
                      description: '默认关闭，仅处理开启后新同步的文件',
                      value: preferences.autoTranscriptionEnabled,
                      enabled: preferences.autoSyncEnabled,
                      onChanged: coordinator.setAutoTranscriptionEnabled,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _RecordingCardAutoSyncStatusRow(
                state: state,
                onRetry:
                    state.status == RecordingCardAutoSyncStatus.failed ||
                        _isRecordingCardObjectivePrerequisite(
                          state.waitingReason,
                        )
                    ? coordinator.retry
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordingCardSyncSettingSwitch extends StatelessWidget {
  const _RecordingCardSyncSettingSwitch({
    required this.valueKey,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final Key valueKey;
  final String title;
  final String description;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    key: valueKey,
    contentPadding: EdgeInsets.zero,
    title: Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        description,
        style: const TextStyle(fontSize: 12.5, height: 1.35),
      ),
    ),
    value: value,
    onChanged: enabled ? onChanged : null,
  );
}

class _RecordingCardAutoSyncStatusRow extends StatelessWidget {
  const _RecordingCardAutoSyncStatusRow({required this.state, this.onRetry});

  final RecordingCardAutoSyncState state;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = state.status == RecordingCardAutoSyncStatus.failed;
    final colors = HuahuoV3Theme.tokensOf(context);
    final color = failed ? colors.danger : colors.muted;
    return Row(
      children: [
        Icon(
          failed ? Icons.error_outline_rounded : Icons.sync_rounded,
          size: 17,
          color: color,
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            _recordingCardAutoSyncStatusLabel(state),
            key: const ValueKey<String>('recording-card-auto-sync-status'),
            style: TextStyle(color: color, fontSize: 12.5),
          ),
        ),
        if (onRetry != null)
          TextButton(
            key: const ValueKey<String>('recording-card-auto-sync-retry'),
            onPressed: onRetry,
            child: const Text('重试'),
          ),
      ],
    );
  }
}

String _recordingCardBackgroundDescription(
  RecordingCardBackgroundExecutionCapability capability,
) => switch (capability.mode) {
  RecordingCardBackgroundExecutionMode.processBound =>
    '连接后自动下载；App 进程存活时可在后台继续，系统结束或划掉后下次打开恢复',
  RecordingCardBackgroundExecutionMode.appResumeOnly =>
    '连接后自动下载；后台持续能力不可用时，未完成任务会在下次打开 App 后恢复',
};

String _recordingCardAutoSyncStatusLabel(RecordingCardAutoSyncState state) {
  if (!state.preferences.autoSyncEnabled) return '自动同步已关闭';
  final waitingLabel = switch (state.waitingReason) {
    RecordingCardSyncWaitingReason.persistenceRequired => '同步记录尚未写入，恢复后请重试',
    RecordingCardSyncWaitingReason.networkRequired => '网络不可用，恢复后请重试',
    RecordingCardSyncWaitingReason.permissionRequired => '录音卡权限未开启，开启后请重试',
    RecordingCardSyncWaitingReason.storageInsufficient => '本地空间不足，清理后请重试',
    _ => null,
  };
  if (waitingLabel != null) return waitingLabel;
  return switch (state.status) {
    RecordingCardAutoSyncStatus.idle => '自动同步未运行',
    RecordingCardAutoSyncStatus.waitingForDevice => '等待录音卡连接',
    RecordingCardAutoSyncStatus.waitingForRetry => '暂时未能同步，等待自动重试',
    RecordingCardAutoSyncStatus.waitingForRecording => '录音进行中，结束后继续',
    RecordingCardAutoSyncStatus.waitingForTransfer => '手动传输进行中，完成后继续',
    RecordingCardAutoSyncStatus.scanning => '正在读取录音卡文件',
    RecordingCardAutoSyncStatus.downloading =>
      state.tasks.isEmpty
          ? '正在同步录音'
          : '正在同步 ${state.fileSyncCompletedCount + 1}/${state.tasks.length}',
    RecordingCardAutoSyncStatus.verifying => '正在核验本地录音',
    RecordingCardAutoSyncStatus.committing => '正在保存同步记录',
    RecordingCardAutoSyncStatus.pausing => '正在停止当前传输',
    RecordingCardAutoSyncStatus.paused => '同步已暂停，进度已保留',
    RecordingCardAutoSyncStatus.transcribing => '正在提交转写',
    RecordingCardAutoSyncStatus.completed => '当前没有待同步文件',
    RecordingCardAutoSyncStatus.failed => '自动处理失败，请重试',
  };
}

bool _isRecordingCardObjectivePrerequisite(
  RecordingCardSyncWaitingReason? reason,
) =>
    reason == RecordingCardSyncWaitingReason.networkRequired ||
    reason == RecordingCardSyncWaitingReason.permissionRequired ||
    reason == RecordingCardSyncWaitingReason.storageInsufficient ||
    reason == RecordingCardSyncWaitingReason.persistenceRequired;

Future<void> _confirmDisconnect(BuildContext context, WidgetRef ref) async {
  final shouldDisconnect = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => V3GlassDialog(
      title: '断开录音卡连接？',
      message: '断开后设备录音和文件同步将停止，稍后可以重新连接。',
      primaryLabel: '断开',
      onPrimary: () => Navigator.pop(dialogContext, true),
      onCancel: () => Navigator.pop(dialogContext, false),
    ),
  );
  if (shouldDisconnect != true || !context.mounted) return;
  await _runAction(
    context,
    ref,
    successMessage: '录音卡已断开',
    action: (controller) => controller.disconnect(),
  );
}

Future<void> _connectRecordingCard(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(recordingCardControllerProvider);
  await showV3RecordingCardConnectionDialog(context, controller: controller);
}

Future<void> _runAction(
  BuildContext context,
  WidgetRef ref, {
  required String successMessage,
  required Future<void> Function(RecordingCardController controller) action,
}) async {
  final controller = ref.read(recordingCardControllerProvider);
  await action(controller);
  if (!context.mounted) return;
  final errorCode =
      controller.state.lastErrorCode ?? controller.operationBlockCode;
  showV3Snack(
    context,
    _recordingCardActionFeedback(errorCode, successMessage: successMessage),
  );
}

class _LocalRecordingBatchBottomBar extends StatelessWidget {
  const _LocalRecordingBatchBottomBar({
    required this.selection,
    required this.onDelete,
    required this.onTranscribe,
  });

  final V3RecordingLibraryBatchSelection selection;
  final VoidCallback onDelete;
  final VoidCallback onTranscribe;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final countLabel = selection.selectedCount == 0
        ? '请选择录音文件'
        : '已选 ${selection.selectedCount} 条';
    return SizedBox(
      height: 72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            countLabel,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('recording-card-device-batch-delete'),
                    onPressed: selection.canDelete ? onDelete : null,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: Text(
                      selection.selectedCount > 0
                          ? '删除本地（${selection.selectedCount}）'
                          : '删除本地',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.danger,
                      side: BorderSide(color: colors.danger),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey(
                      'recording-card-local-batch-transcribe',
                    ),
                    onPressed: selection.canTranscribe ? onTranscribe : null,
                    icon: const Icon(Icons.subject_rounded, size: 18),
                    label: Text(
                      selection.selectedCount > 0
                          ? '转写（${selection.selectedCount}）'
                          : '转写',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
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
      key: const ValueKey('recording-card-management-bluetooth-off-guidance'),
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

class _DeviceHero extends StatelessWidget {
  const _DeviceHero({
    required this.device,
    required this.connected,
    required this.recording,
    required this.fileTransferActive,
    required this.fileTransferPaused,
    required this.connectionBusy,
    required this.connectionLocked,
    required this.bluetoothPoweredOff,
    required this.onConnectionPressed,
    required this.onDetails,
  });

  final RecordingCardDeviceState device;
  final bool connected;
  final RecordingCardRecordingInfo recording;
  final bool fileTransferActive;
  final bool fileTransferPaused;
  final bool connectionBusy;
  final bool connectionLocked;
  final bool bluetoothPoweredOff;
  final VoidCallback onConnectionPressed;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    late final String status;
    late final IconData statusIcon;
    late final Color statusColor;
    if (bluetoothPoweredOff) {
      status = '蓝牙已关闭';
      statusIcon = Icons.bluetooth_disabled_rounded;
      statusColor = colors.danger;
    } else if (!connected) {
      status = switch (device.connectionState) {
        RecordingCardConnectionState.connecting => '正在连接',
        RecordingCardConnectionState.error => '连接异常',
        _ => '未连接',
      };
      statusIcon = Icons.info_outline_rounded;
      statusColor = colors.accent;
    } else if (recording.state == RecordingCardRecordingState.recording) {
      status = '录音中';
      statusIcon = Icons.mic_rounded;
      statusColor = colors.danger;
    } else if (recording.state == RecordingCardRecordingState.paused) {
      status = '录音已暂停';
      statusIcon = Icons.pause_circle_rounded;
      statusColor = colors.accent;
    } else if (fileTransferPaused) {
      status = '文件传输已暂停';
      statusIcon = Icons.pause_circle_outline_rounded;
      statusColor = colors.accent;
    } else if (fileTransferActive) {
      status = '文件传输中';
      statusIcon = Icons.sync_rounded;
      statusColor = colors.primary;
    } else {
      status = '已连接';
      statusIcon = Icons.check_circle_rounded;
      statusColor = colors.success;
    }
    return V3Card(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: '打开录音卡设备详情',
              child: InkWell(
                onTap: onDetails,
                child: Row(
                  children: [
                    ClipRRect(
                      key: const ValueKey('recording-card-device-icon'),
                      borderRadius: BorderRadius.circular(18),
                      child: Image.asset(
                        'assets/images/recording_card_device.png',
                        width: 54,
                        height: 54,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
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
                              fontSize: 18,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Row(
                            children: [
                              Icon(statusIcon, size: 15, color: statusColor),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: colors.muted,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 5),
                              V3RecordingCardBatteryBadge(
                                percent: device.batteryPercent,
                                valueKey: const ValueKey(
                                  'recording-card-management-device-battery',
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
            key: const ValueKey('recording-card-connection-target'),
            semanticLabel: connected ? '断开录音卡' : '连接录音卡',
            width: 62,
            onTap: connectionLocked ? null : onConnectionPressed,
            child: SizedBox(
              width: 62,
              height: 34,
              child: connected
                  ? OutlinedButton(
                      key: const ValueKey('recording-card-disconnect'),
                      onPressed: connectionLocked ? null : onConnectionPressed,
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('断开'),
                    )
                  : FilledButton(
                      key: const ValueKey('recording-card-connect'),
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
            key: const ValueKey('recording-card-details'),
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

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.errorCode});

  final String errorCode;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      radius: 16,
      padding: const EdgeInsets.all(13),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: colors.danger),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_recordingCardFailureStageLabel(errorCode)}阶段',
                  style: TextStyle(
                    color: colors.danger,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _recordingCardErrorMessage(errorCode),
                  style: TextStyle(
                    color: colors.danger,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _recordingCardErrorMessage(String code) {
  final cloudMessage = switch (code) {
    'RECORDING_CARD_NOT_REGISTERED' => '云端没有登记此录音卡，已断开连接，请联系售后核对 SN',
    'RECORDING_CARD_ALREADY_BOUND' => '该录音卡已绑定其他账号，已断开连接',
    'RECORDING_CARD_ACCOUNT_LIMIT_REACHED' => '当前账号已绑定其他录音卡，已断开连接，请先解除原绑定',
    'RECORDING_CARD_CLOUD_BINDING_AUTH_REQUIRED' => '登录状态已失效，已断开录音卡，请重新登录',
    'RECORDING_CARD_CLOUD_BINDING_REQUEST_FAILED' ||
    'RECORDING_CARD_BIND_FAILED' => '云端校验暂时失败，已断开录音卡，请稍后重试',
    _ => null,
  };
  if (cloudMessage != null) return cloudMessage;
  if (code == 'NATIVE_RECORDING_CARD_MALFORMED_PAYLOAD') {
    return '设备返回的数据不完整，请刷新或重新连接';
  }
  return switch (recordingCardFailureStage(code)) {
    RecordingCardFailureStage.coordination => '录音卡正在处理其他任务，请等待当前任务完成',
    RecordingCardFailureStage.connection => '设备连接失败，请重新连接',
    RecordingCardFailureStage.request => '设备响应异常，请稍后重试',
    RecordingCardFailureStage.transfer => '文件传输失败，请重新连接后重试',
    RecordingCardFailureStage.verification => '文件校验未通过，请重新扫描',
    RecordingCardFailureStage.storage => '文件保存失败，请检查可用空间',
  };
}

String _recordingCardFailureStageLabel(String code) {
  return switch (recordingCardFailureStage(code)) {
    RecordingCardFailureStage.coordination => '任务协调',
    RecordingCardFailureStage.connection => '连接',
    RecordingCardFailureStage.request => '请求',
    RecordingCardFailureStage.transfer => '传输',
    RecordingCardFailureStage.verification => '校验',
    RecordingCardFailureStage.storage => '落盘',
  };
}
