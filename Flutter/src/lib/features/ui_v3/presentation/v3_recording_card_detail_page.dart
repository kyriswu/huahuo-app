import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../recording_card/application/recording_card_account_binding_controller.dart';
import '../../recording_card/application/recording_card_controller.dart';
import '../../recording_card/application/recording_card_file_presentation.dart';
import '../../recordings/domain/recording_library.dart';
import 'v3_recording_card_connection_dialog.dart';

class V3RecordingCardDetailPage extends ConsumerStatefulWidget {
  const V3RecordingCardDetailPage({this.focusLocalStorage = false, super.key});

  final bool focusLocalStorage;

  @override
  ConsumerState<V3RecordingCardDetailPage> createState() =>
      _V3RecordingCardDetailPageState();
}

class _V3RecordingCardDetailPageState
    extends ConsumerState<V3RecordingCardDetailPage> {
  final _scrollController = ScrollController();
  final _localStorageKey = GlobalKey();
  var _focusAttempts = 0;
  var _unbindInFlight = false;
  var _refreshInFlight = false;
  String? _guidedConnectionErrorCode;
  String? _refreshErrorCode;
  int? _refreshErrorSuccessfulRevision;
  int? _refreshErrorConnectionRevision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDetails());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDetails() async {
    final library = ref.read(recordingLibraryControllerProvider);
    library.setSearchText('');
    library.setView(RecordingLibraryView.library);
    await library.load();
    await ref.read(recordingCardCloudBindingControllerProvider).load();
    if (!mounted) return;
    _focusLocalStorage();
  }

  Future<void> _refreshDetails() async {
    if (_refreshInFlight) return;
    final card = ref.read(recordingCardControllerProvider);
    if (!card.canRefreshFilesNow) return;
    final successfulRevision = card.successfulFileRefreshRevision;
    setState(() {
      _refreshInFlight = true;
      _refreshErrorCode = null;
      _refreshErrorSuccessfulRevision = null;
      _refreshErrorConnectionRevision = null;
    });
    try {
      await card.refreshDeviceInfo();
      if (card.canRefreshFilesNow) await card.scanFiles();
    } on Object {
      // Controller state remains the typed source for presentation failures.
    } finally {
      if (mounted) setState(() => _refreshInFlight = false);
    }
    if (!mounted) return;
    final refreshSucceeded =
        card.successfulFileRefreshRevision > successfulRevision;
    setState(() {
      _refreshErrorCode = refreshSucceeded
          ? null
          : card.state.fileCatalog.errorCode ??
                card.state.lastErrorCode ??
                'RECORDING_CARD_BUSY';
      _refreshErrorSuccessfulRevision = refreshSucceeded
          ? null
          : card.successfulFileRefreshRevision;
      _refreshErrorConnectionRevision = refreshSucceeded
          ? null
          : card.state.fileCatalog.connectionRevision;
    });
  }

  Future<void> _showConnectionChooser() async {
    if (_guidedConnectionErrorCode != null) {
      setState(() => _guidedConnectionErrorCode = null);
    }
    final controller = ref.read(recordingCardControllerProvider);
    await showV3RecordingCardConnectionDialog(context, controller: controller);
    if (!mounted) return;
    final errorCode = controller.state.lastErrorCode;
    if (errorCode != null) {
      setState(() => _guidedConnectionErrorCode = errorCode);
      return;
    }
    if (_guidedConnectionErrorCode != null) {
      setState(() => _guidedConnectionErrorCode = null);
    }
  }

  Future<void> _openBluetoothPermissionSettings() async {
    final result = await ref
        .read(platformPermissionsPortProvider)
        .openAppSettings(
          PlatformPermissionKind.bluetooth,
          impactAcknowledged: true,
        );
    if (!mounted) return;
    if (!result.ok) {
      showV3Snack(context, '无法打开蓝牙权限设置，请在系统设置中允许应用使用蓝牙。');
    }
  }

  Future<void> _editBluetoothName(RecordingCardDeviceState device) async {
    final updated = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _BluetoothNameEditorDialog(
        initialName: device.displayName ?? '',
        onSubmit: (bluetoothName) {
          return ref
              .read(recordingCardControllerProvider)
              .setBluetoothName(bluetoothName);
        },
      ),
    );
    if (!mounted || updated != true) return;
    showV3Snack(context, '蓝牙名称已设置，请重启录音卡后重新连接。');
  }

  void _focusLocalStorage() {
    if (!widget.focusLocalStorage || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final storageContext = _localStorageKey.currentContext;
      if (storageContext != null) {
        Scrollable.ensureVisible(
          storageContext,
          alignment: .08,
          duration: V3MotionTokens.settled,
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (_scrollController.hasClients && _focusAttempts < 3) {
        _focusAttempts += 1;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        _focusLocalStorage();
      }
    });
  }

  Future<void> _confirmUnbind(RecordingCardDeviceState device) async {
    if (_unbindInFlight) return;
    final cardController = ref.read(recordingCardControllerProvider);
    final cloudController = ref.read(
      recordingCardCloudBindingControllerProvider,
    );
    final disconnectDevice = device.isOperationallyConnected;
    final cloudBinding = cloudController.state.binding;
    final unbindAccount = cloudBinding != null;
    if (!disconnectDevice && !unbindAccount) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _RecordingCardGlassConfirmDialog(
        title: '解除录音卡绑定？',
        message: _combinedUnbindConfirmationMessage(
          device: device,
          serialNumberMasked: cloudBinding?.serialNumberMasked,
          disconnectDevice: disconnectDevice,
          unbindAccount: unbindAccount,
        ),
        cancelLabel: '保留绑定',
        primaryLabel: '确认解除绑定',
        primaryKey: const ValueKey('recording-card-unbind-confirm'),
        destructive: true,
        onCancel: () => Navigator.pop(dialogContext, false),
        onPrimary: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _unbindInFlight = true);
    var deviceStageCompleted = !disconnectDevice;
    Future<String?> disconnectDeviceBeforeCloud() async {
      if (!cardController.state.snapshot.deviceState.isOperationallyConnected) {
        deviceStageCompleted = true;
        return null;
      }
      await cardController.unbindDevice(deleteDeviceFiles: false);
      final errorCode = cardController.state.lastErrorCode;
      deviceStageCompleted = errorCode == null;
      return errorCode;
    }

    if (unbindAccount) {
      final success = await cloudController.unbindCurrentCard(
        beforeCloudUnbind: disconnectDevice
            ? disconnectDeviceBeforeCloud
            : null,
      );
      if (!mounted) return;
      if (!success) {
        final errorCode = cloudController.state.errorCode;
        setState(() => _unbindInFlight = false);
        showV3Snack(
          context,
          !disconnectDevice
              ? '解除账号绑定失败：${errorCode ?? 'RECORDING_CARD_UNBIND_FAILED'}'
              : deviceStageCompleted
              ? '设备连接已断开，但账号解绑失败：${errorCode ?? 'RECORDING_CARD_UNBIND_FAILED'}'
              : '断开录音卡失败：${errorCode ?? 'RECORDING_CARD_DEVICE_DISCONNECT_FAILED'}，账号绑定已保留',
        );
        return;
      }
    } else {
      final errorCode = await disconnectDeviceBeforeCloud();
      if (!mounted) return;
      if (errorCode != null) {
        setState(() => _unbindInFlight = false);
        showV3Snack(context, '断开录音卡失败：$errorCode');
        return;
      }
    }
    setState(() => _unbindInFlight = false);
    showV3Snack(context, '已解除录音卡绑定');
    await returnToPreviousRoute(context, fallbackRoute: '/v3/recording-card');
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final cardController = ref.watch(recordingCardControllerProvider);
    final autoSync = ref.watch(recordingCardAutoSyncCoordinatorProvider);
    final card = cardController.state;
    final showRefreshError =
        _refreshErrorCode != null &&
        _refreshErrorSuccessfulRevision ==
            cardController.successfulFileRefreshRevision &&
        _refreshErrorConnectionRevision == card.fileCatalog.connectionRevision;
    final cloudBinding = ref
        .watch(recordingCardCloudBindingControllerProvider)
        .state;
    final libraryController = ref.watch(recordingLibraryControllerProvider);
    final library = libraryController.state;
    final snapshot = card.snapshot;
    final device = snapshot.deviceState;
    final fileUploadActive = cardController.hasActiveTransfer;
    final bluetoothName = _currentBluetoothName(device);
    final totalLocalBytes = library.items.fold<int>(
      0,
      (sum, item) => sum + item.sizeBytes,
    );
    final totalLocalSeconds = library.items.fold<int>(
      0,
      (sum, item) => sum + item.durationSeconds,
    );
    final deviceFiles = snapshot.files;
    final currentCardLedger = autoSync.connectedCardLedger;
    final currentCheckpoint = autoSync.connectedCardCheckpoint;
    final ledgerResolved = autoSync.connectedCardSnDigest != null;
    final filePresentations = buildRecordingCardFilePresentations(
      directory:
          cardController.hasLoadedFilesForCurrentConnection ||
              deviceFiles.isNotEmpty
          ? deviceFiles
          : null,
      ledger: currentCardLedger,
      cardSnDigest: autoSync.connectedCardSnDigest,
      card: card,
      localRecordingLookup: libraryController.findById,
      localInventoryLoaded: library.hasVerifiedInventory,
    );
    final visibleDeviceFiles = filePresentations
        .map((item) => item.file)
        .toList(growable: false);
    final syncedDeviceFiles = filePresentations
        .where((item) => item.status == RecordingCardFileDisplayStatus.synced)
        .length;
    final locallyDeletedOnCard = filePresentations
        .where(
          (item) =>
              item.status == RecordingCardFileDisplayStatus.locallyDeleted,
        )
        .length;
    final pendingSyncFiles = filePresentations
        .where(
          (item) =>
              item.status.isAutomaticCandidate || item.status.hasActiveTransfer,
        )
        .length;
    final lastSuccessfulSyncAt = _latestTimestamp(
      currentCheckpoint?.lastSuccessfulAutoSyncAt,
      currentCheckpoint?.lastTransferCompletedAt,
    );
    final latestDeviceRecordingAt = _latestDeviceRecordingAt(
      visibleDeviceFiles,
    );
    final hasLoadedDeviceFiles =
        cardController.hasLoadedFilesForCurrentConnection;
    final deviceFilesLoading =
        device.isOperationallyConnected &&
        !hasLoadedDeviceFiles &&
        cardController.isRefreshingFiles;
    String deviceStorageValue(String loadedValue) {
      if (!device.isOperationallyConnected) return '未连接';
      if (deviceFilesLoading) return '正在读取';
      if (!hasLoadedDeviceFiles) return '未读取';
      return loadedValue;
    }

    String ledgerValue(String resolvedValue) {
      if (!device.isOperationallyConnected) return '未连接';
      return ledgerResolved ? resolvedValue : '未读取';
    }

    final unbindStatusAvailable =
        card.status == RecordingCardControllerStatus.idle ||
        card.status == RecordingCardControllerStatus.error;
    final accountBindingResolved =
        cloudBinding.status == RecordingCardCloudBindingStatus.bound ||
        cloudBinding.status == RecordingCardCloudBindingStatus.unbound;
    final localUnbindAvailable =
        device.isOperationallyConnected &&
        snapshot.recordingInfo.state == RecordingCardRecordingState.idle &&
        !cardController.hasActiveTransfer &&
        unbindStatusAvailable;
    final accountOnlyUnbindAvailable =
        !device.isOperationallyConnected && cloudBinding.binding != null;
    final canUnbind =
        accountBindingResolved &&
        !_unbindInFlight &&
        (localUnbindAvailable || accountOnlyUnbindAvailable);
    final unbindButtonLabel = !_unbindInFlight
        ? '解除录音卡绑定'
        : switch (cloudBinding.unbindPhase) {
            RecordingCardUnbindPhase.unbindingCloud => '正在解除账号绑定',
            _ => '正在断开录音卡',
          };
    final canEditBluetoothName =
        device.isOperationallyConnected &&
        snapshot.recordingInfo.state == RecordingCardRecordingState.idle &&
        !cardController.hasActiveTransfer &&
        (card.status == RecordingCardControllerStatus.idle ||
            card.status == RecordingCardControllerStatus.error);
    final connectionBusy =
        card.status == RecordingCardControllerStatus.connecting ||
        card.status == RecordingCardControllerStatus.scanning ||
        device.connectionState == RecordingCardConnectionState.connecting;
    final connectionLocked =
        cardController.hasActiveTransfer ||
        (card.status != RecordingCardControllerStatus.idle &&
            card.status != RecordingCardControllerStatus.error);
    final canRefresh = !_refreshInFlight && cardController.canRefreshFilesNow;

    return V3PageScaffold(
      title: '录音卡设备详情',
      centerTitle: true,
      trailing: IconButton(
        key: const ValueKey('recording-card-detail-refresh'),
        tooltip: '刷新设备详情',
        onPressed: canRefresh ? _refreshDetails : null,
        icon: _refreshInFlight
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh_rounded),
      ),
      fallbackRoute: '/v3/recording-card',
      scrollController: _scrollController,
      showScrollbar: true,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
      children: [
        _DeviceIdentityCard(
          device: device,
          bluetoothName: bluetoothName,
          fileUploadActive: fileUploadActive,
        ),
        const SizedBox(height: 18),
        _GuidedConnectionCard(
          connected: device.isOperationallyConnected,
          fileUploadActive: fileUploadActive,
          busy: connectionBusy,
          locked: connectionLocked,
          errorCode: device.isOperationallyConnected
              ? null
              : _guidedConnectionErrorCode,
          onConnect: _showConnectionChooser,
          onOpenBluetoothPermissionSettings: _openBluetoothPermissionSettings,
        ),
        const SizedBox(height: 22),
        const V3SectionTitle('蓝牙设置'),
        V3Card(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DetailRow(
                label: '蓝牙名称',
                value:
                    bluetoothName ??
                    (device.isOperationallyConnected ? '未读取' : '未连接'),
                action: IconButton(
                  key: const ValueKey('recording-card-bluetooth-name-edit'),
                  tooltip: '修改蓝牙名称',
                  onPressed: canEditBluetoothName
                      ? () => _editBluetoothName(device)
                      : null,
                  icon: const Icon(Icons.edit_outlined),
                ),
                last: true,
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _bluetoothNameAvailabilityMessage(card),
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const V3SectionTitle('设备信息'),
        V3Card(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          child: Column(
            children: [
              _DetailRow(
                label: '设备名称',
                value:
                    bluetoothName ??
                    (device.isOperationallyConnected ? '未读取' : '未连接'),
              ),
              _DetailRow(
                label: '连接状态',
                value: fileUploadActive
                    ? '文件上传中'
                    : _connectionStageLabel(device),
              ),
              _DetailRow(
                label: '当前状态',
                value: device.isOperationallyConnected
                    ? _recordingStateLabel(snapshot.recordingInfo.state)
                    : _connectionStageLabel(device),
              ),
              _DetailRow(
                label: '电量',
                value: device.batteryPercent == null
                    ? '未读取'
                    : '${device.batteryPercent}%',
              ),
              _DetailRow(label: '设备型号', value: device.deviceModel ?? '未读取'),
              _DetailRow(
                label: '固件版本',
                value: device.firmwareVersion ?? '未读取',
                last: snapshot.recordingInfo.currentFileName == null,
              ),
              if (snapshot.recordingInfo.currentFileName != null)
                _DetailRow(
                  label: '当前录音文件',
                  value: snapshot.recordingInfo.currentFileName!,
                  last: true,
                ),
            ],
          ),
        ),
        if (showRefreshError) ...[
          const SizedBox(height: 12),
          const _InlineError('设备详情刷新失败，请点击右上角刷新重试。'),
        ],
        const SizedBox(height: 22),
        const V3SectionTitle('录音卡存储'),
        V3Card(
          key: const ValueKey('recording-card-open-files'),
          onTap: () => context.push(AppRoutePaths.recordingCardFiles),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          child: Column(
            children: [
              _DetailRow(
                label: '卡内录音',
                value: deviceStorageValue('${visibleDeviceFiles.length} 条'),
                action: const Icon(Icons.chevron_right_rounded),
              ),
              _DetailRow(
                label: '文件大小合计',
                value: deviceStorageValue(
                  _formatDeviceFileBytes(visibleDeviceFiles),
                ),
              ),
              _DetailRow(
                label: '录音总时长',
                value: deviceStorageValue(
                  _formatDeviceFileDuration(visibleDeviceFiles),
                ),
              ),
              _DetailRow(
                label: '已同步到本地',
                value: ledgerResolved
                    ? ledgerValue('$syncedDeviceFiles 条')
                    : deviceStorageValue('$syncedDeviceFiles 条'),
              ),
              _DetailRow(
                label: '本地已删除，卡内仍保留',
                value: ledgerValue('$locallyDeletedOnCard 条'),
              ),
              _DetailRow(
                label: '待同步',
                value: ledgerValue('$pendingSyncFiles 条'),
              ),
              _DetailRow(
                label: '最新录音',
                value: deviceStorageValue(
                  _formatTimestamp(latestDeviceRecordingAt),
                ),
              ),
              _DetailRow(
                label: '最近成功同步',
                value: ledgerValue(_formatTimestamp(lastSuccessfulSyncAt)),
              ),
              _DetailRow(
                label: '最近读取卡内目录',
                value: ledgerValue(
                  _formatTimestamp(currentCheckpoint?.lastDirectoryReadAt),
                ),
                last: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        KeyedSubtree(
          key: _localStorageKey,
          child: const V3SectionTitle('本地存储'),
        ),
        V3Card(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          child: Column(
            children: [
              _DetailRow(
                label: '本地录音',
                value: '${library.summary.totalCount} 条',
              ),
              _DetailRow(label: '录音文件大小', value: _formatBytes(totalLocalBytes)),
              _DetailRow(
                label: '录音总时长',
                value: _formatDuration(totalLocalSeconds),
                last: true,
              ),
            ],
          ),
        ),
        if (library.lastErrorCode != null) ...[
          const SizedBox(height: 12),
          _InlineError('本地录音读取失败：${library.lastErrorCode}'),
        ],
        const SizedBox(height: 22),
        const V3SectionTitle('设备操作'),
        V3Card(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DetailRow(
                label: '绑定录音卡 SN',
                value:
                    device.serialNumber ??
                    cloudBinding.binding?.serialNumberMasked ??
                    '未绑定',
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const ValueKey('recording-card-unbind'),
                onPressed: canUnbind ? () => _confirmUnbind(device) : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.danger,
                  side: BorderSide(color: colors.danger),
                  minimumSize: const Size.fromHeight(46),
                ),
                icon: _unbindInFlight
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link_off_rounded),
                label: Text(unbindButtonLabel),
              ),
              const SizedBox(height: 10),
              Text(
                _unbindAvailabilityMessage(cloudBinding, card),
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _guidedConnectionMessage(String errorCode) => switch (errorCode) {
  'RECORDING_CARD_GUIDED_DEVICE_NOT_FOUND' =>
    '没有找到可连接的录音卡。请检查设备已开机且手机蓝牙已打开，然后重试。',
  'RECORDING_CARD_GUIDED_MULTIPLE_DEVICES' => '检测到多台录音卡。请只保留身边一台录音卡开机后再连接。',
  'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED' => '请允许应用使用蓝牙后再连接录音卡。',
  'RECORDING_CARD_BLUETOOTH_UNAUTHORIZED' => '请在系统设置中允许应用使用蓝牙后，再返回这里连接录音卡。',
  'RECORDING_CARD_BLUETOOTH_POWERED_OFF' =>
    '系统蓝牙已关闭。请在控制中心或系统设置中打开蓝牙后，回到这里重新检测。',
  'RECORDING_CARD_BLUETOOTH_UNSUPPORTED' => '当前手机不支持低功耗蓝牙，无法连接录音卡。',
  'RECORDING_CARD_BLUETOOTH_UNAVAILABLE' => '蓝牙正在准备，请确认已打开并稍候几秒后重试。',
  'RECORDING_CARD_SCAN_IN_PROGRESS' => '正在搜索附近录音卡，请等待当前搜索完成后再试。',
  _ => '连接录音卡失败，请检查设备和蓝牙后重试。',
};

String _unbindAvailabilityMessage(
  RecordingCardCloudBindingState binding,
  RecordingCardControllerState card,
) {
  if (binding.isLoading) return '正在读取当前账号的录音卡绑定状态。';
  if (binding.status == RecordingCardCloudBindingStatus.failure ||
      binding.status == RecordingCardCloudBindingStatus.unavailable) {
    return '暂时无法确认账号绑定状态，请重新打开页面后重试。';
  }
  final connected = card.snapshot.deviceState.isOperationallyConnected;
  final accountBound = binding.binding != null;
  if (!connected && !accountBound) return '当前没有可解除的录音卡绑定。';
  if (!connected) return '录音卡未连接，可通过已绑定 SN 的账号记录直接解除云端绑定。';
  if (connected &&
      card.snapshot.recordingInfo.state != RecordingCardRecordingState.idle) {
    return '录音进行中，请结束录音后再解除绑定。';
  }
  if (card.hasActiveTransfer) {
    return '文件传输进行中，请等待传输结束后再解除绑定。';
  }
  if (accountBound) return '将先断开本机与录音卡，再解除当前账号的云端绑定。';
  return '将断开本机与录音卡；当前账号没有需要解除的云端绑定。';
}

String _combinedUnbindConfirmationMessage({
  required RecordingCardDeviceState device,
  required String? serialNumberMasked,
  required bool disconnectDevice,
  required bool unbindAccount,
}) {
  final target = device.displayName ?? '当前录音卡';
  final action = switch ((disconnectDevice, unbindAccount)) {
    (true, true) =>
      '将先断开 $target 的本机连接，再解除 ${serialNumberMasked ?? '该录音卡'} 与当前账号的云端绑定。',
    (true, false) => '将断开 $target 的本机连接；当前账号没有需要解除的云端绑定。',
    (false, true) =>
      '录音卡当前未连接，将通过 ${serialNumberMasked ?? '已绑定 SN'} 对应的账号记录解除云端绑定。',
    (false, false) => '',
  };
  return '$action\n\n此操作不会删除录音卡内文件，本地录音、同步记录和云端资产也会保留。';
}

String _bluetoothNameAvailabilityMessage(RecordingCardControllerState card) {
  if (!card.snapshot.deviceState.isOperationallyConnected) {
    return '连接录音卡后可修改蓝牙名称。';
  }
  if (card.snapshot.recordingInfo.state != RecordingCardRecordingState.idle) {
    return '录音进行中，请结束录音后再修改蓝牙名称。';
  }
  if (card.hasActiveTransfer) {
    return '文件传输进行中，请等待传输结束后再修改蓝牙名称。';
  }
  if (card.status != RecordingCardControllerStatus.idle &&
      card.status != RecordingCardControllerStatus.error) {
    return '设备操作进行中，请稍后再试。';
  }
  return '保存后需重新启动，录音卡名称才会有效';
}

class _DeviceIdentityCard extends StatelessWidget {
  const _DeviceIdentityCard({
    required this.device,
    required this.bluetoothName,
    required this.fileUploadActive,
  });

  final RecordingCardDeviceState device;
  final String? bluetoothName;
  final bool fileUploadActive;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final connected = device.isOperationallyConnected;
    return V3Card(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset(
              'assets/images/recording_card_device.png',
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
              semanticLabel: '无限花火录音卡',
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bluetoothName ?? device.deviceModel ?? '录音卡',
                  key: const ValueKey(
                    'recording-card-detail-identity-bluetooth-name',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  connected
                      ? bluetoothName == null
                            ? '蓝牙已连接，正在读取名称'
                            : '蓝牙名称'
                      : '连接录音卡后显示蓝牙名称',
                  key: const ValueKey(
                    'recording-card-detail-identity-bluetooth-name-label',
                  ),
                  style: TextStyle(color: colors.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color:
                  (fileUploadActive
                          ? colors.primary
                          : connected
                          ? colors.success
                          : colors.muted)
                      .withValues(alpha: .12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              fileUploadActive
                  ? '文件上传中'
                  : connected
                  ? '已连接'
                  : '未连接',
              style: TextStyle(
                color: fileUploadActive
                    ? colors.primary
                    : connected
                    ? colors.success
                    : colors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String? _currentBluetoothName(RecordingCardDeviceState device) {
  if (!device.isOperationallyConnected) return null;
  final name = device.displayName?.trim();
  return name == null || name.isEmpty ? null : name;
}

class _GuidedConnectionCard extends StatelessWidget {
  const _GuidedConnectionCard({
    required this.connected,
    required this.fileUploadActive,
    required this.busy,
    required this.locked,
    required this.errorCode,
    required this.onConnect,
    required this.onOpenBluetoothPermissionSettings,
  });

  final bool connected;
  final bool fileUploadActive;
  final bool busy;
  final bool locked;
  final String? errorCode;
  final VoidCallback onConnect;
  final VoidCallback onOpenBluetoothPermissionSettings;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final guidedErrorCode = errorCode;
    final bluetoothAuthorizationBlocked =
        guidedErrorCode == 'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED' ||
        guidedErrorCode == 'RECORDING_CARD_BLUETOOTH_UNAUTHORIZED';
    final bluetoothPoweredOff =
        guidedErrorCode == 'RECORDING_CARD_BLUETOOTH_POWERED_OFF';
    return V3Card(
      variant: V3CardVariant.outlined,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                fileUploadActive
                    ? Icons.upload_file_rounded
                    : connected
                    ? Icons.check_circle_outline_rounded
                    : Icons.bluetooth_searching_rounded,
                color: fileUploadActive
                    ? colors.primary
                    : connected
                    ? colors.success
                    : colors.primary,
              ),
              const SizedBox(width: 9),
              Text(
                fileUploadActive
                    ? '文件上传中'
                    : connected
                    ? '录音卡已连接'
                    : '连接录音卡',
                style: HuahuoV3Theme.listTitle,
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            fileUploadActive
                ? '录音文件上传中，暂时不能开始、暂停或结束录音。'
                : connected
                ? '设备已准备就绪。录音和文件同步可在本页及设备管理页继续操作。'
                : '请先打开录音卡并确认手机蓝牙已开启，然后点击连接，从搜索结果中选择要连接的设备。',
            style: TextStyle(color: colors.muted, height: 1.5),
          ),
          if (!connected) ...[
            const SizedBox(height: 14),
            V3PrimaryButton(
              key: const ValueKey('recording-card-detail-connect'),
              label: busy
                  ? '正在连接录音卡'
                  : bluetoothPoweredOff
                  ? '重新检测蓝牙'
                  : '连接录音卡',
              icon: busy ? null : Icons.bluetooth_connected_rounded,
              leading: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              enabled: !locked,
              busy: busy,
              onPressed: onConnect,
            ),
          ],
          if (guidedErrorCode != null) ...[
            const SizedBox(height: 10),
            Text(
              _guidedConnectionMessage(guidedErrorCode),
              style: TextStyle(color: colors.danger, height: 1.4),
            ),
            if (bluetoothAuthorizationBlocked) ...[
              const SizedBox(height: 10),
              V3OutlineButton(
                key: const ValueKey(
                  'recording-card-detail-open-bluetooth-settings',
                ),
                label: '打开蓝牙权限设置',
                icon: Icons.settings_rounded,
                onPressed: onOpenBluetoothPermissionSettings,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.action,
    this.last = false,
  });

  final String label;
  final String value;
  final Widget? action;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: colors.muted, fontSize: 14),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: colors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 4), action!],
        ],
      ),
    );
  }
}

class _BluetoothNameEditorDialog extends StatefulWidget {
  const _BluetoothNameEditorDialog({
    required this.initialName,
    required this.onSubmit,
  });

  final String initialName;
  final Future<RecordingCardResult<RecordingCardDeviceState>> Function(
    String bluetoothName,
  )
  onSubmit;

  @override
  State<_BluetoothNameEditorDialog> createState() =>
      _BluetoothNameEditorDialogState();
}

class _BluetoothNameEditorDialogState
    extends State<_BluetoothNameEditorDialog> {
  late final TextEditingController _controller;
  var _submitting = false;
  String? _remoteErrorCode;
  var _showLocalValidationError = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final bluetoothName = normalizeRecordingCardBluetoothName(_controller.text);
    if (bluetoothName == null) {
      setState(() => _showLocalValidationError = true);
      return;
    }
    setState(() {
      _submitting = true;
      _remoteErrorCode = null;
      _showLocalValidationError = false;
    });
    final result = await widget.onSubmit(bluetoothName);
    if (!mounted) return;
    if (!result.ok || result.value == null) {
      setState(() {
        _submitting = false;
        _remoteErrorCode =
            result.error?.code ?? 'RECORDING_CARD_BLUETOOTH_NAME_FAILED';
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final draft = _controller.text;
    final normalizedName = normalizeRecordingCardBluetoothName(draft);
    final valid = normalizedName != null;
    final errorMessage = _remoteErrorCode == null
        ? _showLocalValidationError && !valid
              ? '请输入有效的蓝牙名称。'
              : null
        : _bluetoothNameFailureMessage(_remoteErrorCode!);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: V3Card(
        key: const ValueKey('recording-card-bluetooth-name-dialog-card'),
        radius: 24,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                key: const ValueKey('recording-card-bluetooth-name-scroll'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '修改蓝牙名称',
                      style: HuahuoV3Theme.h1.copyWith(color: colors.ink),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey(
                        'recording-card-bluetooth-name-input',
                      ),
                      controller: _controller,
                      contextMenuBuilder: V3TextEditing.buildContextMenu,
                      enabled: !_submitting,
                      autofocus: true,
                      maxLines: 1,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) {
                        if (_remoteErrorCode != null ||
                            _showLocalValidationError) {
                          setState(() {
                            _remoteErrorCode = null;
                            _showLocalValidationError = false;
                          });
                        } else {
                          setState(() {});
                        }
                      },
                      onSubmitted: (_) {
                        if (valid && !_submitting) {
                          _submit();
                        }
                      },
                      decoration: InputDecoration(
                        labelText: '蓝牙名称',
                        errorText: errorMessage,
                        counterText: '',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '保存后需重新启动，录音卡名称才会有效',
                      key: const ValueKey(
                        'recording-card-bluetooth-name-restart-note',
                      ),
                      style: TextStyle(
                        color: colors.muted,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              key: const ValueKey('recording-card-bluetooth-name-actions'),
              children: [
                Expanded(
                  child: V3OutlineButton(
                    key: const ValueKey('recording-card-bluetooth-name-cancel'),
                    label: '取消',
                    icon: Icons.close_rounded,
                    enabled: !_submitting,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: V3PrimaryButton(
                    key: const ValueKey('recording-card-bluetooth-name-save'),
                    label: _submitting ? '正在保存' : '保存',
                    icon: _submitting ? null : Icons.save_outlined,
                    leading: _submitting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    enabled: valid && !_submitting,
                    busy: _submitting,
                    onPressed: _submit,
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

String _bluetoothNameFailureMessage(String errorCode) => switch (errorCode) {
  'RECORDING_CARD_BLUETOOTH_NAME_REJECTED' => '设备拒绝修改蓝牙名称，请稍后重试。',
  'RECORDING_CARD_BLUETOOTH_NAME_RESPONSE_INVALID' => '设备返回异常，请保持连接后重试。',
  'RECORDING_CARD_BLUETOOTH_NAME_NOT_CONNECTED' => '录音卡已断开连接，请重新连接后再试。',
  'RECORDING_CARD_BLUETOOTH_NAME_RECORDING_ACTIVE' => '请结束录音后再修改蓝牙名称。',
  'RECORDING_CARD_BLUETOOTH_NAME_BUSY' => '设备正在处理其他操作，请稍后再试。',
  'RECORDING_CARD_BLUETOOTH_NAME_UNAVAILABLE' => '当前设备暂不支持修改蓝牙名称。',
  _ => '修改蓝牙名称失败，请保持连接后重试。',
};

class _InlineError extends StatelessWidget {
  const _InlineError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: colors.danger, size: 20),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.danger, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordingCardGlassConfirmDialog extends StatelessWidget {
  const _RecordingCardGlassConfirmDialog({
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.primaryLabel,
    required this.primaryKey,
    required this.destructive,
    required this.onCancel,
    required this.onPrimary,
  });

  final String title;
  final String message;
  final String cancelLabel;
  final String primaryLabel;
  final Key primaryKey;
  final bool destructive;
  final VoidCallback onCancel;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height - mediaQuery.padding.vertical - 32;
    return SafeArea(
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight.clamp(0.0, 640.0)),
          child: V3Card(
            radius: 28,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(
                    key: const ValueKey(
                      'recording-card-confirm-dialog-content-scroll',
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: HuahuoV3Theme.h1.copyWith(color: colors.ink),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          message,
                          style: HuahuoV3Theme.body.copyWith(
                            color: colors.text,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: V3OutlineButton(
                        label: cancelLabel,
                        onPressed: onCancel,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        key: primaryKey,
                        onPressed: onPrimary,
                        style: FilledButton.styleFrom(
                          backgroundColor: destructive
                              ? colors.danger
                              : colors.ink,
                          foregroundColor: colors.canvas,
                        ),
                        child: Text(primaryLabel),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _recordingStateLabel(RecordingCardRecordingState state) {
  return switch (state) {
    RecordingCardRecordingState.idle => '待机',
    RecordingCardRecordingState.recording => '录音中',
    RecordingCardRecordingState.paused => '已暂停',
  };
}

String _formatDeviceFileBytes(List<RecordingCardScannedFile> files) {
  if (files.isEmpty) return '0 B';
  final known = files.where((file) => file.sizeBytes != null).toList();
  if (known.isEmpty) return '未读取';
  final total = known.fold<int>(0, (sum, file) => sum + file.sizeBytes!);
  final notes = <String>[];
  final unknownCount = files.length - known.length;
  if (unknownCount > 0) notes.add('$unknownCount 条大小未读取');
  final suspectCount = known
      .where(
        (file) =>
            file.sizeConfidence == RecordingCardFileSizeConfidence.suspect,
      )
      .length;
  if (suspectCount > 0) notes.add('$suspectCount 条待校验');
  final formatted = _formatBytes(total);
  return notes.isEmpty ? formatted : '$formatted（${notes.join('，')}）';
}

String _formatDeviceFileDuration(List<RecordingCardScannedFile> files) {
  if (files.isEmpty) return '0 分钟';
  final known = files.where((file) => file.durationSeconds != null).toList();
  if (known.isEmpty) return '未读取';
  final total = known.fold<int>(0, (sum, file) => sum + file.durationSeconds!);
  final unknownCount = files.length - known.length;
  final formatted = _formatDuration(total);
  return unknownCount == 0 ? formatted : '$formatted（$unknownCount 条未读取）';
}

DateTime? _latestDeviceRecordingAt(List<RecordingCardScannedFile> files) {
  DateTime? latest;
  for (final file in files) {
    final recordedAt = file.recordedAt;
    if (recordedAt != null && (latest == null || recordedAt.isAfter(latest))) {
      latest = recordedAt;
    }
  }
  return latest;
}

DateTime? _latestTimestamp(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return left.isAfter(right) ? left : right;
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

String _formatDuration(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return hours > 0 ? '$hours 小时 $minutes 分钟' : '$minutes 分钟';
}

String _connectionStageLabel(RecordingCardDeviceState device) {
  return switch (device.connectionStage) {
    RecordingCardConnectionStage.searching => '搜索中',
    RecordingCardConnectionStage.connecting => '连接中',
    RecordingCardConnectionStage.connected => '已连接',
    RecordingCardConnectionStage.failed => '连接异常',
    RecordingCardConnectionStage.idle =>
      device.connectionState == RecordingCardConnectionState.error
          ? '连接异常'
          : '未连接',
  };
}

String _formatTimestamp(DateTime? value) {
  if (value == null) return '未读取';
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
