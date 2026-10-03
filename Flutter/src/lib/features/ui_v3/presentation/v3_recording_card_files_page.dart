import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../recording_card/application/recording_card_controller.dart';
import '../../recording_card/application/recording_card_file_presentation.dart';
import '../../recording_card/domain/recording_card_sync_ledger.dart';
import '../../recordings/application/recording_library_ui_controller.dart';
import 'v3_local_recording_library_page.dart';
import 'v3_recording_card_connection_dialog.dart';

enum _CardFileSelectionPurpose { general, bluetooth, wifi, delete }

enum _CardFileMenuAction { bluetooth, wifi, delete }

enum _CardFileTransferChoice { bluetooth, wifi }

class V3RecordingCardFilesPage extends ConsumerStatefulWidget {
  const V3RecordingCardFilesPage({super.key});

  @override
  ConsumerState<V3RecordingCardFilesPage> createState() =>
      _V3RecordingCardFilesPageState();
}

class _V3RecordingCardFilesPageState
    extends ConsumerState<V3RecordingCardFilesPage> {
  final _scrollController = ScrollController();
  late final V3RecordingLibrarySectionController _sectionController;
  late final RecordingLibraryUiController _uiController;
  _CardFileSelectionPurpose _selectionPurpose =
      _CardFileSelectionPurpose.general;
  bool _refreshInFlight = false;
  bool _bluetoothBatchActionInFlight = false;
  String? _lastObservedCardSnDigest;
  _CardSyncSessionSummary? _lastSyncSummary;

  @override
  void initState() {
    super.initState();
    ref.listenManual<String>(authenticatedUserDataScopeProvider, (
      previous,
      next,
    ) {
      if (previous == next || !mounted) return;
      setState(() {
        _lastObservedCardSnDigest = null;
        _lastSyncSummary = null;
      });
      _exitBatchMode(_uiController);
    });
    _uiController = RecordingLibraryUiController()
      ..reset(tab: V3RecordingLibraryTab.device)
      ..addListener(_onUiControllerChanged);
    _sectionController = V3RecordingLibrarySectionController()
      ..addListener(_onSelectionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(recordingCardControllerProvider)
            .ensureFilesLoadedForCurrentConnection(),
      );
    });
  }

  void _onUiControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _uiController
      ..removeListener(_onUiControllerChanged)
      ..dispose();
    _sectionController
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(recordingCardControllerProvider);
    final autoSync = ref.watch(recordingCardAutoSyncCoordinatorProvider);
    final ledgerStore = ref.watch(recordingCardAutoSyncStoreProvider);
    final library = ref.watch(recordingLibraryControllerProvider);
    final uiController = _uiController;
    final state = controller.state;
    final device = state.snapshot.deviceState;
    final connected = device.isOperationallyConnected;
    final connectedDigest = autoSync.connectedCardSnDigest;
    final unresolvedWifiBatchDigest = controller.hasUnresolvedWifiBatch
        ? state.wifiBatch?.cardSnDigest
        : null;
    if (connected && connectedDigest != null) {
      if (_lastObservedCardSnDigest != null &&
          _lastObservedCardSnDigest != connectedDigest) {
        _lastSyncSummary = null;
      }
      _lastObservedCardSnDigest = connectedDigest;
    }
    final resolvedDigest = connected
        ? connectedDigest
        : unresolvedWifiBatchDigest ??
              _lastObservedCardSnDigest ??
              autoSync.syncSession.cardSnDigest ??
              ledgerStore.latestKnownCardSnDigest();
    final visibleSyncSummary = _lastSyncSummary?.cardSnDigest == resolvedDigest
        ? _lastSyncSummary
        : null;
    final cachedLedger = resolvedDigest == null
        ? const <RecordingCardFileLedgerEntry>[]
        : ledgerStore.loadFileLedger(resolvedDigest);
    final useLiveDirectory =
        connected &&
        (controller.hasLoadedFilesForCurrentConnection ||
            state.snapshot.files.isNotEmpty);
    final presentations = buildRecordingCardFilePresentations(
      directory: useLiveDirectory ? state.snapshot.files : null,
      ledger: cachedLedger,
      cardSnDigest: resolvedDigest,
      card: state,
      localRecordingLookup: library.findById,
      localInventoryLoaded: library.state.hasVerifiedInventory,
      receipts: ref
          .watch(recordingTranscriptionReceiptStoreProvider)
          .listReceipts(),
    );
    final presentationFiles = presentations
        .map((item) => item.file)
        .toList(growable: false);
    final hasCurrentCardWifiBatch = recordingCardWifiBatchMatchesCard(
      batch: state.wifiBatch,
      cardSnDigest: resolvedDigest,
      deviceFingerprint: device.safeDeviceFingerprint,
    );
    final wifiOwnsDevice =
        state.operation.isActive &&
        state.operation.kind == RecordingCardOperationKind.wifiTransfer;
    final batchMode = uiController.batchMode;
    final selection = _sectionController.selection;
    final canRefresh =
        !batchMode &&
        !_refreshInFlight &&
        !_bluetoothBatchActionInFlight &&
        controller.canRefreshFilesNow;
    final canMutate =
        connected &&
        connectedDigest != null &&
        controller.hasLoadedFilesForCurrentConnection &&
        state.snapshot.recordingInfo.state ==
            RecordingCardRecordingState.idle &&
        !controller.hasActiveDeviceOperation &&
        !controller.hasActiveTransfer &&
        !_refreshInFlight &&
        !_bluetoothBatchActionInFlight &&
        state.status == RecordingCardControllerStatus.idle;
    final hasCardFiles = presentationFiles.isNotEmpty;
    final hasTransferCandidates = presentationFiles.any(
      (file) => file.syncState != RecordingCardFileSyncState.synced,
    );

    final page = V3PageScaffold(
      title: '录音卡文件',
      centerTitle: true,
      fallbackRoute: '/v3/recording-card/details',
      onBack: batchMode ? () => _exitBatchMode(uiController) : null,
      topBarLeadingWidth: 96,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('recording-card-files-header-refresh'),
            tooltip: '刷新卡内文件',
            onPressed: canRefresh ? () => unawaited(_refreshFiles()) : null,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            key: const ValueKey('recording-card-files-menu'),
            tooltip: '文件操作',
            onPressed: batchMode
                ? null
                : () => _showFileActions(
                    canMutate: canMutate,
                    hasCardFiles: hasCardFiles,
                    hasTransferCandidates: hasTransferCandidates,
                  ),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
      scrollController: _scrollController,
      onRefresh: canRefresh ? _refreshFiles : null,
      showScrollbar: true,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      bottomBar: batchMode
          ? _CardFileBatchBottomBar(
              selection: selection,
              purpose: _selectionPurpose,
              actionBusy: _bluetoothBatchActionInFlight,
              onSync: () => unawaited(_chooseTransfer()),
              onBluetooth: () => unawaited(_runBluetoothTransfer()),
              onWifi: () => unawaited(_runWifiTransfer()),
              onDelete: () => unawaited(_runDelete()),
            )
          : null,
      children: [
        if (!wifiOwnsDevice)
          _CardDirectoryStatus(
            connected: connected,
            refreshing: _refreshInFlight || controller.isRefreshingFiles,
            catalogReady: controller.hasLoadedFilesForCurrentConnection,
            hasCachedRows: presentationFiles.isNotEmpty,
            errorCode: state.fileCatalog.errorCode ?? state.lastErrorCode,
            onRefresh: canRefresh ? _refreshFiles : null,
            onConnect: connected ? null : _showConnectionChooser,
          ),
        if (!state.operation.isActive &&
            !hasCurrentCardWifiBatch &&
            visibleSyncSummary != null) ...[
          const SizedBox(height: 12),
          _CardFileSyncSessionSummary(summary: visibleSyncSummary),
        ],
        const SizedBox(height: 12),
        V3RecordingLibrarySection(
          initialTab: V3RecordingLibraryTab.device,
          projection: V3RecordingLibraryProjection.recordingCardFiles,
          automaticDeviceRefresh: false,
          wifiTransferSelection:
              _selectionPurpose == _CardFileSelectionPurpose.wifi ||
              _selectionPurpose == _CardFileSelectionPurpose.bluetooth,
          uiController: uiController,
          managementController: _sectionController,
          deviceFilePresentations: presentations,
          recordingCardSnDigest: resolvedDigest,
          onSyncBatchSettled: _recordSyncBatchSettlement,
          onEnterBatchMode: () =>
              _enterBatchMode(uiController, _CardFileSelectionPurpose.general),
          onExitBatchMode: () => _exitBatchMode(uiController),
        ),
      ],
    );
    return PopScope<Object?>(
      canPop: !batchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && batchMode) _exitBatchMode(uiController);
      },
      child: page,
    );
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  void _recordSyncBatchSettlement(V3RecordingCardSyncSettlement settlement) {
    if (!mounted) return;
    setState(() {
      _lastSyncSummary = _CardSyncSessionSummary.fromSettlement(settlement);
    });
  }

  void _enterBatchMode(
    RecordingLibraryUiController controller,
    _CardFileSelectionPurpose purpose,
  ) {
    if (controller.batchMode) return;
    _sectionController.clearSelection();
    setState(() => _selectionPurpose = purpose);
    controller.setBatchMode(true);
  }

  void _exitBatchMode(RecordingLibraryUiController controller) {
    _sectionController.clearSelection();
    controller.setBatchMode(false);
    if (mounted) {
      setState(() => _selectionPurpose = _CardFileSelectionPurpose.general);
    }
  }

  Future<void> _refreshFiles() async {
    if (_refreshInFlight || _bluetoothBatchActionInFlight) return;
    final controller = ref.read(recordingCardControllerProvider);
    if (!controller.state.snapshot.deviceState.isOperationallyConnected) {
      showV3Snack(context, '录音卡未连接，正在显示上次读取结果');
      return;
    }
    if (!controller.canRefreshFilesNow) {
      final recording =
          controller.state.snapshot.recordingInfo.state !=
          RecordingCardRecordingState.idle;
      showV3Snack(context, recording ? '录音进行中，结束后将自动刷新' : '录音卡正在处理其他任务，请稍后刷新');
      return;
    }
    final successfulRevision = controller.successfulFileRefreshRevision;
    setState(() => _refreshInFlight = true);
    try {
      await controller.refreshFiles(
        reason: RecordingCardFileRefreshReason.manual,
      );
    } on Object {
      // The controller owns the typed failure projection; the page only
      // guarantees that an unexpected adapter error cannot strand its latch.
    } finally {
      if (mounted) setState(() => _refreshInFlight = false);
    }
    if (!mounted) return;
    if (controller.successfulFileRefreshRevision > successfulRevision) {
      showV3Snack(context, '卡内文件已刷新');
    } else {
      showV3Snack(
        context,
        _cardFileErrorMessage(
          controller.state.fileCatalog.errorCode ??
              controller.state.lastErrorCode,
        ),
      );
    }
  }

  Future<void> _showConnectionChooser() async {
    await showV3RecordingCardConnectionDialog(
      context,
      controller: ref.read(recordingCardControllerProvider),
    );
  }

  Future<void> _showFileActions({
    required bool canMutate,
    required bool hasCardFiles,
    required bool hasTransferCandidates,
  }) async {
    final controller = ref.read(recordingCardControllerProvider);
    final wifiSupported =
        controller.state.snapshot.deviceState.wifiSupported == true;
    final canTransfer = canMutate && hasTransferCandidates;
    final allFilesSynced = canMutate && hasCardFiles && !hasTransferCandidates;
    final action = await showV3ActionSheet<_CardFileMenuAction>(
      context: context,
      title: '文件操作',
      items: [
        V3ActionSheetItem<_CardFileMenuAction>(
          key: const ValueKey('recording-card-files-bluetooth-entry'),
          value: _CardFileMenuAction.bluetooth,
          icon: Icons.bluetooth_rounded,
          label: '蓝牙传输',
          subtitle: allFilesSynced ? '卡内文件均已同步到本地' : null,
          enabled: canTransfer,
        ),
        V3ActionSheetItem<_CardFileMenuAction>(
          key: const ValueKey('recording-card-files-wifi-entry'),
          value: _CardFileMenuAction.wifi,
          icon: Icons.wifi_rounded,
          label: 'Wi-Fi 传输',
          subtitle: !wifiSupported
              ? '当前录音卡不支持 Wi-Fi'
              : allFilesSynced
              ? '卡内文件均已同步到本地'
              : null,
          enabled: canTransfer && wifiSupported,
        ),
        V3ActionSheetItem<_CardFileMenuAction>(
          key: const ValueKey('recording-card-files-delete-entry'),
          value: _CardFileMenuAction.delete,
          icon: Icons.delete_outline_rounded,
          label: '删除录音卡文件',
          enabled: canMutate && hasCardFiles,
          destructive: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    final uiController = _uiController;
    switch (action) {
      case _CardFileMenuAction.bluetooth:
        _enterBatchMode(uiController, _CardFileSelectionPurpose.bluetooth);
      case _CardFileMenuAction.wifi:
        _enterBatchMode(uiController, _CardFileSelectionPurpose.wifi);
      case _CardFileMenuAction.delete:
        _enterBatchMode(uiController, _CardFileSelectionPurpose.delete);
    }
  }

  Future<void> _chooseTransfer() async {
    final selection = _sectionController.selection;
    if (selection.selectedCount == 0) return;
    final choice = await showV3ActionSheet<_CardFileTransferChoice>(
      context: context,
      title: '同步到本地',
      items: [
        V3ActionSheetItem<_CardFileTransferChoice>(
          key: const ValueKey('recording-card-files-choose-bluetooth'),
          value: _CardFileTransferChoice.bluetooth,
          icon: Icons.bluetooth_rounded,
          label: '蓝牙传输',
          subtitle: '适合少量文件，保持录音卡连接',
          enabled: selection.canBluetoothDownload,
        ),
        V3ActionSheetItem<_CardFileTransferChoice>(
          key: const ValueKey('recording-card-files-choose-wifi'),
          value: _CardFileTransferChoice.wifi,
          icon: Icons.wifi_rounded,
          label: 'Wi-Fi 快速传输',
          subtitle: '适合多个或较大的录音文件',
          enabled: selection.canWifiDownload,
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _CardFileTransferChoice.bluetooth:
        await _runBluetoothTransfer();
      case _CardFileTransferChoice.wifi:
        await _runWifiTransfer();
    }
  }

  Future<void> _runBluetoothTransfer() async {
    if (_bluetoothBatchActionInFlight) return;
    setState(() => _bluetoothBatchActionInFlight = true);
    try {
      final selectionEmpty = await _sectionController
          .downloadSelectedOverBluetooth();
      if (!mounted) return;
      if (selectionEmpty) {
        _exitBatchMode(_uiController);
      }
    } finally {
      if (mounted) setState(() => _bluetoothBatchActionInFlight = false);
    }
  }

  Future<void> _runWifiTransfer() async {
    await _sectionController.downloadSelectedOverWifi();
  }

  Future<void> _runDelete() async {
    final selectionEmpty = await _sectionController.deleteSelected();
    if (!mounted) return;
    if (selectionEmpty) {
      _exitBatchMode(_uiController);
    }
  }
}

class _CardDirectoryStatus extends StatelessWidget {
  const _CardDirectoryStatus({
    required this.connected,
    required this.refreshing,
    required this.catalogReady,
    required this.hasCachedRows,
    required this.errorCode,
    required this.onRefresh,
    required this.onConnect,
  });

  final bool connected;
  final bool refreshing;
  final bool catalogReady;
  final bool hasCachedRows;
  final String? errorCode;
  final VoidCallback? onRefresh;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    if (!connected) {
      return V3Card(
        key: const ValueKey('recording-card-files-offline'),
        variant: V3CardVariant.outlined,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.sd_card_outlined, color: colors.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasCachedRows ? '显示上次读取结果' : '录音卡未连接',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    hasCachedRows ? '连接后可刷新、传输或删除卡内文件' : '连接录音卡后读取卡内文件',
                    style: TextStyle(color: colors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            FilledButton(
              key: const ValueKey('recording-card-files-connect'),
              onPressed: onConnect,
              child: const Text('连接'),
            ),
          ],
        ),
      );
    }
    if (refreshing) {
      return const V3Card(
        key: ValueKey('recording-card-files-loading'),
        variant: V3CardVariant.outlined,
        padding: EdgeInsets.all(14),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Expanded(child: Text('正在读取卡内文件，保留上次结果')),
          ],
        ),
      );
    }
    if (!catalogReady && errorCode != null) {
      return V3Card(
        key: const ValueKey('recording-card-files-error'),
        variant: V3CardVariant.outlined,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: colors.danger),
            const SizedBox(width: 10),
            Expanded(child: Text(_cardFileErrorMessage(errorCode))),
            IconButton(
              tooltip: '重新读取',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _CardSyncSessionSummary {
  const _CardSyncSessionSummary({
    required this.cardSnDigest,
    required this.completedCount,
    required this.remainingCount,
    required this.earliestRecordedAt,
    required this.latestRecordedAt,
    required this.unknownTimeCount,
  });

  factory _CardSyncSessionSummary.fromSettlement(
    V3RecordingCardSyncSettlement settlement,
  ) {
    final frozen = settlement.completedFiles;
    final knownTimes =
        frozen
            .map((file) => file.recordedAt)
            .whereType<DateTime>()
            .toList(growable: false)
          ..sort();
    return _CardSyncSessionSummary(
      cardSnDigest: settlement.cardSnDigest,
      completedCount: settlement.completedCount,
      remainingCount: settlement.remainingCount,
      earliestRecordedAt: knownTimes.firstOrNull,
      latestRecordedAt: knownTimes.lastOrNull,
      unknownTimeCount: frozen.length - knownTimes.length,
    );
  }

  final String cardSnDigest;
  final int completedCount;
  final int remainingCount;
  final DateTime? earliestRecordedAt;
  final DateTime? latestRecordedAt;
  final int unknownTimeCount;
}

class _CardFileSyncSessionSummary extends StatelessWidget {
  const _CardFileSyncSessionSummary({required this.summary});

  final _CardSyncSessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final earliest = summary.earliestRecordedAt;
    final latest = summary.latestRecordedAt;
    return V3Card(
      key: const ValueKey('recording-card-files-session-summary'),
      variant: V3CardVariant.outlined,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '本轮同步：已同步 ${summary.completedCount} 条，未同步 ${summary.remainingCount} 条',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (earliest != null && latest != null) ...[
            const SizedBox(height: 4),
            Text(
              earliest == latest
                  ? '录音时间 ${_cardFileSummaryTime(earliest)}'
                  : '录音时间 ${_cardFileSummaryTime(earliest)} - ${_cardFileSummaryTime(latest)}',
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
          if (summary.unknownTimeCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '时间未知 ${summary.unknownTimeCount} 条',
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _CardFileBatchBottomBar extends StatelessWidget {
  const _CardFileBatchBottomBar({
    required this.selection,
    required this.purpose,
    required this.actionBusy,
    required this.onSync,
    required this.onBluetooth,
    required this.onWifi,
    required this.onDelete,
  });

  final V3RecordingLibraryBatchSelection selection;
  final _CardFileSelectionPurpose purpose;
  final bool actionBusy;
  final VoidCallback onSync;
  final VoidCallback onBluetooth;
  final VoidCallback onWifi;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final selected = selection.selectedCount;
    final buttons = switch (purpose) {
      _CardFileSelectionPurpose.bluetooth => <Widget>[
        _BatchActionButton(
          key: const ValueKey('recording-card-files-batch-bluetooth'),
          icon: Icons.bluetooth_rounded,
          label: selected == 0 ? '蓝牙传输' : '蓝牙传输（$selected）',
          enabled: selection.canBluetoothDownload && !actionBusy,
          onPressed: onBluetooth,
        ),
      ],
      _CardFileSelectionPurpose.wifi => <Widget>[
        _BatchActionButton(
          key: const ValueKey('recording-card-files-batch-wifi'),
          icon: Icons.wifi_rounded,
          label: selected == 0 ? 'Wi-Fi 传输' : 'Wi-Fi 传输（$selected）',
          enabled: selection.canWifiDownload && !actionBusy,
          onPressed: onWifi,
        ),
      ],
      _CardFileSelectionPurpose.delete => <Widget>[
        _BatchActionButton(
          key: const ValueKey('recording-card-files-batch-delete'),
          icon: Icons.delete_outline_rounded,
          label: selected == 0 ? '删除卡内文件' : '删除卡内文件（$selected）',
          enabled: selection.canDelete && !actionBusy,
          onPressed: onDelete,
          destructive: true,
        ),
      ],
      _CardFileSelectionPurpose.general => <Widget>[
        _BatchActionButton(
          key: const ValueKey('recording-card-files-batch-sync'),
          icon: Icons.download_rounded,
          label: '同步到本地',
          enabled:
              (selection.canBluetoothDownload || selection.canWifiDownload) &&
              !actionBusy,
          onPressed: onSync,
        ),
        _BatchActionButton(
          key: const ValueKey('recording-card-files-batch-delete'),
          icon: Icons.delete_outline_rounded,
          label: '删除卡内文件',
          enabled: selection.canDelete && !actionBusy,
          onPressed: onDelete,
          destructive: true,
        ),
      ],
    };
    return SizedBox(
      height: 72,
      child: Column(
        children: [
          Text(
            selected == 0 ? '请选择卡内录音' : '已选 $selected 条',
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
                for (var index = 0; index < buttons.length; index++) ...[
                  if (index > 0) const SizedBox(width: 10),
                  Expanded(child: buttons[index]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BatchActionButton extends StatelessWidget {
  const _BatchActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.destructive = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final bool destructive;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    if (destructive) {
      return OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, size: 18),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.danger,
          side: BorderSide(color: colors.danger),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

String _cardFileErrorMessage(String? code) {
  return switch (code) {
    'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED' ||
    'RECORDING_CARD_BLUETOOTH_UNAUTHORIZED' => '需要蓝牙权限才能读取录音卡文件',
    'RECORDING_CARD_BUSY' ||
    'RECORDING_CARD_TRANSFER_BUSY' ||
    'RECORDING_CARD_OPERATION_BUSY' ||
    'RECORDING_CARD_OPERATION_DEFERRED' => '录音卡正在处理其他任务，请稍后刷新',
    'RECORDING_CARD_BLUETOOTH_POWERED_OFF' => '请打开手机蓝牙后重新读取',
    'RECORDING_CARD_NOT_CONNECTED' || null => '录音卡未连接，无法读取最新文件',
    _ => '卡内文件读取失败，请稍后重试',
  };
}

String _cardFileSummaryTime(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
