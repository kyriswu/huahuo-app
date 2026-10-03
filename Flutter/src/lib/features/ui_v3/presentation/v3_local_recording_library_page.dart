// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/native_playback_port.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import 'v3_recording_library_surfaces.dart';
import '../../recordings/application/recording_library_controller.dart';
import '../../recordings/application/recording_library_ui_controller.dart';
import '../../recordings/application/recording_batch_transcription_controller.dart';
import '../../recordings/application/recording_playback_controller.dart';
import '../../recordings/application/recording_processing_tracker.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/data/local_recording_repository.dart';
import '../../recordings/domain/recording_library.dart';
import '../../recordings/domain/recording_batch_transcription.dart';
import '../../recordings/domain/recording_transcription_receipt.dart';
import '../../recording_card/application/recording_card_controller.dart';
import '../../recording_card/application/recording_card_file_presentation.dart';
import '../../recording_card/application/recording_card_quick_wifi_coordinator.dart';
import '../../recording_card/data/recording_card_auto_sync_store.dart';
import '../../recording_card/domain/recording_card_auto_sync.dart';

typedef V3PlaybackPortFactory = NativePlaybackPort Function();

enum V3RecordingLibraryProjection {
  personalLibrary,
  recordingCardInventory,
  recordingCardFiles,
}

bool recordingCardTerminalWifiProjectionIsReady({
  required RecordingCardWifiBatchSnapshot batch,
  required Map<String, RecordingCardFilePresentation> projectionByFileKey,
}) {
  final requiresSyncedProjection =
      batch.state == RecordingCardWifiBatchState.completed ||
      recordingCardWifiBatchIsBluetoothHandoff(batch);
  return batch.items.every((item) {
    final presentation = projectionByFileKey[item.file.localFileKey];
    return requiresSyncedProjection
        ? presentation?.status == RecordingCardFileDisplayStatus.synced
        : presentation != null;
  });
}

class V3PersonalRecordingLibraryPage extends StatefulWidget {
  const V3PersonalRecordingLibraryPage({super.key});

  @override
  State<V3PersonalRecordingLibraryPage> createState() =>
      _V3PersonalRecordingLibraryPageState();
}

class _V3PersonalRecordingLibraryPageState
    extends State<V3PersonalRecordingLibraryPage> {
  final _scrollController = ScrollController();
  late final V3RecordingLibrarySectionController _sectionController;
  late final RecordingLibraryUiController _uiController;

  @override
  void initState() {
    super.initState();
    _uiController = RecordingLibraryUiController()
      ..reset(tab: V3RecordingLibraryTab.local)
      ..addListener(_onControllerChanged);
    _sectionController = V3RecordingLibrarySectionController()
      ..addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _uiController
      ..removeListener(_onControllerChanged)
      ..dispose();
    _sectionController
      ..removeListener(_onControllerChanged)
      ..dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final batchMode = _uiController.batchMode;
    final selection = _sectionController.selection;
    final page = V3PageScaffold(
      title: '录音文件',
      fallbackRoute: '/v3/profile',
      onBack: batchMode ? _exitBatchMode : null,
      scrollController: _scrollController,
      showScrollbar: true,
      bottomBar: batchMode
          ? _PersonalRecordingBatchBottomBar(
              selection: selection,
              onDelete: () => unawaited(_deleteSelected()),
              onTranscribe: () =>
                  unawaited(_sectionController.transcribeSelected()),
            )
          : null,
      children: <Widget>[
        V3RecordingLibrarySection(
          initialTab: V3RecordingLibraryTab.local,
          automaticDeviceRefresh: false,
          projection: V3RecordingLibraryProjection.personalLibrary,
          uiController: _uiController,
          managementController: _sectionController,
          onEnterBatchMode: _enterBatchMode,
          onExitBatchMode: _exitBatchMode,
        ),
      ],
    );
    return PopScope<Object?>(
      canPop: !batchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && batchMode) _exitBatchMode();
      },
      child: page,
    );
  }

  void _enterBatchMode() {
    _sectionController.clearSelection();
    _uiController.setBatchMode(true);
  }

  void _exitBatchMode() {
    _sectionController.clearSelection();
    _uiController.setBatchMode(false);
  }

  Future<void> _deleteSelected() async {
    final selectionEmpty = await _sectionController.deleteSelected();
    if (mounted && selectionEmpty) _exitBatchMode();
  }
}

class _PersonalRecordingBatchBottomBar extends StatelessWidget {
  const _PersonalRecordingBatchBottomBar({
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
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('personal-recording-batch-delete'),
              onPressed: selection.canDelete ? onDelete : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('删除本地'),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.danger,
                side: BorderSide(color: colors.danger),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              key: const ValueKey('personal-recording-batch-transcribe'),
              onPressed: selection.canTranscribe ? onTranscribe : null,
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: const Text('转写'),
            ),
          ),
        ],
      ),
    );
  }
}

@immutable
final class V3RecordingLibraryBatchSelection {
  const V3RecordingLibraryBatchSelection({
    required this.tab,
    required this.selectedCount,
    required this.selectedBytes,
    required this.deviceSelectedCount,
    required this.wifiEligibleCount,
    required this.canDelete,
    required this.canWifiDownload,
    required this.canBluetoothDownload,
    required this.canTranscribe,
  });

  const V3RecordingLibraryBatchSelection.empty(this.tab)
    : selectedCount = 0,
      selectedBytes = 0,
      deviceSelectedCount = 0,
      wifiEligibleCount = 0,
      canDelete = false,
      canWifiDownload = false,
      canBluetoothDownload = false,
      canTranscribe = false;

  final V3RecordingLibraryTab tab;
  final int selectedCount;
  final int selectedBytes;
  final int deviceSelectedCount;
  final int wifiEligibleCount;
  final bool canDelete;
  final bool canWifiDownload;
  final bool canBluetoothDownload;
  final bool canTranscribe;

  @override
  bool operator ==(Object other) =>
      other is V3RecordingLibraryBatchSelection &&
      other.tab == tab &&
      other.selectedCount == selectedCount &&
      other.selectedBytes == selectedBytes &&
      other.deviceSelectedCount == deviceSelectedCount &&
      other.wifiEligibleCount == wifiEligibleCount &&
      other.canDelete == canDelete &&
      other.canWifiDownload == canWifiDownload &&
      other.canBluetoothDownload == canBluetoothDownload &&
      other.canTranscribe == canTranscribe;

  @override
  int get hashCode => Object.hash(
    tab,
    selectedCount,
    selectedBytes,
    deviceSelectedCount,
    wifiEligibleCount,
    canDelete,
    canWifiDownload,
    canBluetoothDownload,
    canTranscribe,
  );
}

final class V3RecordingLibrarySectionController extends ChangeNotifier {
  V3RecordingLibraryBatchSelection _selection =
      const V3RecordingLibraryBatchSelection.empty(V3RecordingLibraryTab.local);
  Object? _owner;
  Future<bool> Function()? _deleteSelected;
  Future<void> Function()? _downloadSelectedOverWifi;
  Future<bool> Function()? _downloadSelectedOverBluetooth;
  Future<void> Function()? _downloadAllUnsyncedOverWifi;
  Future<void> Function()? _transcribeSelected;
  VoidCallback? _selectAll;
  VoidCallback? _clearSelection;

  V3RecordingLibraryBatchSelection get selection => _selection;

  Future<bool> deleteSelected() async {
    return await _deleteSelected?.call() ?? false;
  }

  Future<void> downloadSelectedOverWifi() async {
    await _downloadSelectedOverWifi?.call();
  }

  Future<bool> downloadSelectedOverBluetooth() async {
    return await _downloadSelectedOverBluetooth?.call() ?? false;
  }

  Future<void> downloadAllUnsyncedOverWifi() async {
    await _downloadAllUnsyncedOverWifi?.call();
  }

  Future<void> transcribeSelected() async {
    await _transcribeSelected?.call();
  }

  void selectAll() => _selectAll?.call();

  void clearSelection() => _clearSelection?.call();

  void _attach({
    required Object owner,
    required Future<bool> Function() deleteSelected,
    required Future<void> Function() downloadSelectedOverWifi,
    required Future<bool> Function() downloadSelectedOverBluetooth,
    required Future<void> Function() downloadAllUnsyncedOverWifi,
    required Future<void> Function() transcribeSelected,
    required VoidCallback selectAll,
    required VoidCallback clearSelection,
  }) {
    _owner = owner;
    _deleteSelected = deleteSelected;
    _downloadSelectedOverWifi = downloadSelectedOverWifi;
    _downloadSelectedOverBluetooth = downloadSelectedOverBluetooth;
    _downloadAllUnsyncedOverWifi = downloadAllUnsyncedOverWifi;
    _transcribeSelected = transcribeSelected;
    _selectAll = selectAll;
    _clearSelection = clearSelection;
  }

  void _detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _deleteSelected = null;
    _downloadSelectedOverWifi = null;
    _downloadSelectedOverBluetooth = null;
    _downloadAllUnsyncedOverWifi = null;
    _transcribeSelected = null;
    _selectAll = null;
    _clearSelection = null;
  }

  void _publish(V3RecordingLibraryBatchSelection value) {
    if (_selection == value) return;
    _selection = value;
    notifyListeners();
  }
}

class V3RecordingCardSyncSettlement {
  const V3RecordingCardSyncSettlement({
    required this.cardSnDigest,
    required this.completedFiles,
    required this.completedCount,
    required this.remainingCount,
  });

  final String cardSnDigest;
  final List<RecordingCardScannedFile> completedFiles;
  final int completedCount;
  final int remainingCount;
}

class V3RecordingLibrarySection extends ConsumerStatefulWidget {
  const V3RecordingLibrarySection({
    required this.initialTab,
    required this.projection,
    this.playbackPortFactory,
    this.automaticDeviceRefresh = true,
    this.wifiTransferSelection = false,
    this.uiController,
    this.managementController,
    this.deviceFilePresentations,
    this.recordingCardSnDigest,
    this.onSyncBatchCompleted,
    this.onSyncBatchSettled,
    this.onEnterBatchMode,
    this.onExitBatchMode,
    super.key,
  });

  final V3RecordingLibraryTab initialTab;
  final V3PlaybackPortFactory? playbackPortFactory;
  final bool automaticDeviceRefresh;
  final bool wifiTransferSelection;
  final V3RecordingLibraryProjection projection;
  final RecordingLibraryUiController? uiController;
  final V3RecordingLibrarySectionController? managementController;
  final List<RecordingCardFilePresentation>? deviceFilePresentations;
  final String? recordingCardSnDigest;
  final ValueChanged<List<RecordingCardScannedFile>>? onSyncBatchCompleted;
  final ValueChanged<V3RecordingCardSyncSettlement>? onSyncBatchSettled;
  final VoidCallback? onEnterBatchMode;
  final VoidCallback? onExitBatchMode;

  @override
  ConsumerState<V3RecordingLibrarySection> createState() =>
      _V3RecordingLibrarySectionState();
}

class _V3RecordingLibrarySectionState
    extends ConsumerState<V3RecordingLibrarySection> {
  final Set<String> _selectedIds = <String>{};
  late RecordingPlaybackController _playbackController;
  bool _ownsPlaybackController = false;
  String? _renderedPlaybackRecordingId;
  bool _wifiBatchActionInFlight = false;
  bool _wifiFlowOpen = false;
  bool _deviceDeleteInFlight = false;
  bool _transcriptionActionInFlight = false;
  String? _uploadingRecordingId;
  String? _uploadingRecordingTitle;
  int _uploadPresentationGeneration = 0;
  RecordingProcessingState? _processingState;
  final Set<String> _reportedWifiCompletionKeys = <String>{};
  final Set<String> _announcedWifiCompletionBatchIds = <String>{};
  final Set<String> _reportedWifiSettlementKeys = <String>{};
  int _selectionPruneGeneration = 0;
  String? _quickWifiProjectionAckRequestId;
  String? _wifiTerminalProjectionAckKey;
  ProviderSubscription<bool>? _globalBatchModeSubscription;

  @override
  void initState() {
    super.initState();
    final factory = widget.playbackPortFactory;
    if (factory == null) {
      _playbackController = ref.read(recordingPlaybackControllerProvider);
    } else {
      _ownsPlaybackController = true;
      _playbackController = _createInjectedPlaybackController(factory);
    }
    _renderedPlaybackRecordingId = _playbackController.state.recordingId;
    _playbackController.addListener(_onPlaybackChanged);
    _attachUiControllerListener();
    _attachManagementController();
    _listenToRuntimeChanges();
    scheduleMicrotask(() {
      if (!mounted) return;
      if (widget.uiController == null) {
        ref
            .read(recordingLibraryUiControllerProvider)
            .reset(tab: widget.initialTab);
      }
      final library = ref.read(recordingLibraryControllerProvider);
      library.setSearchText('');
      if (library.state.query.view != RecordingLibraryView.library) {
        library.setView(RecordingLibraryView.library);
      }
      unawaited(library.load());
      if (widget.automaticDeviceRefresh &&
          widget.projection != V3RecordingLibraryProjection.personalLibrary) {
        unawaited(
          ref
              .read(recordingCardControllerProvider)
              .ensureFilesLoadedForCurrentConnection(),
        );
      }
    });
  }

  void _listenToRuntimeChanges() {
    ref.listenManual<RecordingPlaybackController>(
      recordingPlaybackControllerProvider,
      (previous, next) {
        if (widget.playbackPortFactory != null || identical(previous, next)) {
          return;
        }
        _replacePlaybackControllerForCurrentConfiguration();
      },
    );
    ref.listenManual<String?>(authenticatedRecordingUserScopeProvider, (
      previous,
      next,
    ) {
      if (widget.playbackPortFactory == null || previous == next) return;
      _replacePlaybackControllerForCurrentConfiguration();
    });
    ref.listenManual<RecordingCardWifiBatchSnapshot?>(
      recordingCardControllerProvider.select(
        (controller) => controller.state.wifiBatch,
      ),
      (previous, next) {
        if (_wifiFlowOpen || _wifiBatchActionInFlight || !_ownsCardFeedback) {
          return;
        }
        if (next == null ||
            !_wifiBatchMatchesCurrentCard(next) ||
            (previous?.batchId == next.batchId &&
                previous?.state == next.state)) {
          return;
        }
        _presentWifiBatchSettlement(next);
      },
    );
    ref.listenManual<int>(
      recordingCardControllerProvider.select(
        (controller) => controller.localRecordingRegistrationRevision,
      ),
      (previous, next) {
        if (next == previous) return;
        unawaited(ref.read(recordingLibraryControllerProvider).load());
      },
    );
    ref.listenManual<String?>(
      recordingCardControllerProvider.select(
        (controller) =>
            _recordingCardSelectionOwner(controller.state.snapshot.deviceState),
      ),
      (previous, owner) {
        if (previous == owner || _selectedIds.isEmpty || !mounted) {
          return;
        }
        setState(() {
          _selectedIds.removeWhere((id) => id.startsWith('device:'));
        });
      },
    );
  }

  @override
  void didUpdateWidget(covariant V3RecordingLibrarySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.uiController, widget.uiController)) {
      oldWidget.uiController?.removeListener(_onInjectedUiControllerChanged);
      _globalBatchModeSubscription?.close();
      _globalBatchModeSubscription = null;
      _attachUiControllerListener();
    }
    if (oldWidget.wifiTransferSelection != widget.wifiTransferSelection &&
        _selectedIds.isNotEmpty) {
      _selectedIds.clear();
    }
    if (!identical(oldWidget.playbackPortFactory, widget.playbackPortFactory)) {
      _replacePlaybackControllerForCurrentConfiguration();
    }
    if (identical(
      oldWidget.managementController,
      widget.managementController,
    )) {
      return;
    }
    oldWidget.managementController?._detach(this);
    _attachManagementController();
  }

  void _attachManagementController() {
    widget.managementController?._attach(
      owner: this,
      deleteSelected: _deleteCurrentSelection,
      downloadSelectedOverWifi: _downloadCurrentDeviceSelection,
      downloadSelectedOverBluetooth:
          _downloadCurrentDeviceSelectionOverBluetooth,
      downloadAllUnsyncedOverWifi: _downloadAllUnsyncedDeviceFiles,
      transcribeSelected: _transcribeCurrentSelection,
      selectAll: _selectAllCurrentRecordings,
      clearSelection: _clearSelection,
    );
  }

  RecordingLibraryUiController get _recordingUiController =>
      widget.uiController ?? ref.read(recordingLibraryUiControllerProvider);

  void _attachUiControllerListener() {
    final injectedController = widget.uiController;
    if (injectedController != null) {
      injectedController.addListener(_onInjectedUiControllerChanged);
      return;
    }
    _globalBatchModeSubscription = ref.listenManual<bool>(
      recordingLibraryUiControllerProvider.select(
        (controller) => controller.batchMode,
      ),
      (previous, next) {
        if (next || _selectedIds.isEmpty || !mounted) return;
        setState(_selectedIds.clear);
      },
    );
  }

  void _onInjectedUiControllerChanged() {
    if (!mounted) return;
    setState(() {
      if (widget.uiController?.batchMode != true) _selectedIds.clear();
    });
  }

  RecordingPlaybackController _createInjectedPlaybackController(
    V3PlaybackPortFactory factory,
  ) {
    return RecordingPlaybackController(
      playbackPort: factory(),
      positionStore: ref.read(recordingPlaybackPositionStoreProvider),
    );
  }

  void _replacePlaybackControllerForCurrentConfiguration() {
    final factory = widget.playbackPortFactory;
    final ownsController = factory != null;
    final next = factory == null
        ? ref.read(recordingPlaybackControllerProvider)
        : _createInjectedPlaybackController(factory);
    if (identical(_playbackController, next)) return;

    final previous = _playbackController;
    previous.removeListener(_onPlaybackChanged);
    if (_ownsPlaybackController) {
      previous.dispose();
    } else {
      unawaited(previous.release());
    }
    _playbackController = next;
    _ownsPlaybackController = ownsController;
    _renderedPlaybackRecordingId = next.state.recordingId;
    _playbackController.addListener(_onPlaybackChanged);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.uiController?.removeListener(_onInjectedUiControllerChanged);
    _globalBatchModeSubscription?.close();
    widget.managementController?._detach(this);
    _playbackController.removeListener(_onPlaybackChanged);
    if (_ownsPlaybackController) {
      _playbackController.dispose();
    } else {
      unawaited(_playbackController.release());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final RecordingLibraryUiController uiController =
        widget.uiController ?? ref.watch(recordingLibraryUiControllerProvider);
    final libraryState = ref.watch(recordingLibraryControllerProvider).state;
    final cardController = ref.watch(recordingCardControllerProvider);
    ref.watch(recordingTranscriptionReceiptStoreProvider);
    _processingState = null;
    if (libraryState.items.any(
      (item) => item.remoteRecordingId?.trim().isNotEmpty == true,
    )) {
      try {
        _processingState = ref.watch(recordingProcessingTrackerProvider).state;
      } on StateError {
        _processingState = null;
      }
    }
    final autoSync = ref.watch(recordingCardAutoSyncCoordinatorProvider);
    final quickWifi = ref.watch(recordingCardQuickWifiCoordinatorProvider);
    final quickWifiState = quickWifi.state;
    final isCardProjection =
        widget.projection != V3RecordingLibraryProjection.personalLibrary;
    final digest =
        widget.recordingCardSnDigest ??
        autoSync.connectedCardSnDigest ??
        autoSync.syncSession.cardSnDigest;
    final scopedTasks = autoSync.state.tasks
        .where((task) {
          if (!isCardProjection || task.isTerminal) return false;
          if (task.cardSnDigest != null) return task.cardSnDigest == digest;
          return task.deviceFingerprint ==
              cardController.state.snapshot.deviceState.safeDeviceFingerprint;
        })
        .toList(growable: false);
    final scopedAutoState = autoSync.state.copyWith(
      tasks: scopedTasks,
      clearActiveTask: !scopedTasks.any(
        (task) => task.taskId == autoSync.state.activeTaskId,
      ),
    );
    final automaticTranscriptionActive = scopedTasks.any(
      (task) => task.state == RecordingCardAutoSyncTaskState.transcribing,
    );
    final automaticSyncSessionVisible =
        digest != null &&
        autoSync.syncSession.cardSnDigest == digest &&
        (scopedAutoState.status == RecordingCardAutoSyncStatus.verifying ||
            scopedAutoState.status == RecordingCardAutoSyncStatus.committing ||
            scopedAutoState.status == RecordingCardAutoSyncStatus.pausing ||
            autoSync.hasObjectivePrerequisiteWait);
    final visibleTransferProgress = _visibleTransferProgress(
      cardController.state,
    );

    final observesUploadState =
        _uploadingRecordingId != null || automaticTranscriptionActive;
    final observedUploadState = observesUploadState
        ? ref.watch(recordingUploadControllerProvider).state
        : const RecordingUploadState();
    final uploadState = _uploadingRecordingId == null
        ? null
        : observedUploadState;
    final activeUploadState =
        uploadState?.activeDraft?.localRecordingId == _uploadingRecordingId
        ? uploadState
        : null;
    final activeUploadProgress = _uploadingRecordingId == null
        ? null
        : uploadState?.progressForDraft('draft-$_uploadingRecordingId');
    var autoUploadBytesSent = 0;
    var autoUploadTotalBytes = 0;
    var autoUploadBytesPerSecond = 0.0;
    for (final task in scopedTasks) {
      final localRecordingId = task.localRecordingId?.trim();
      if (task.state != RecordingCardAutoSyncTaskState.transcribing ||
          localRecordingId == null ||
          localRecordingId.isEmpty) {
        continue;
      }
      final uploadProgress = observedUploadState.progressForDraft(
        'draft-$localRecordingId',
      );
      if (uploadProgress == null) continue;
      autoUploadBytesSent += uploadProgress.bytesSent;
      autoUploadTotalBytes += uploadProgress.totalBytes;
      autoUploadBytesPerSecond += uploadProgress.bytesPerSecond;
    }
    final autoUploadRemainingBytes =
        (autoUploadTotalBytes - autoUploadBytesSent).clamp(
          0,
          autoUploadTotalBytes,
        );
    final autoUploadEstimatedRemainingSeconds =
        autoUploadTotalBytes > 0 && autoUploadBytesPerSecond > 0
        ? (autoUploadRemainingBytes / autoUploadBytesPerSecond).ceil()
        : null;
    final operationallyConnected =
        cardController.state.snapshot.deviceState.isOperationallyConnected;
    final projection = _recordingProjectionSnapshot(
      localItems: libraryState.items,
      cardState: cardController.state,
    );
    final selectionProjection = projection;
    if (uiController.batchMode) {
      final eligibleSelectionIds = selectionProjection.rows
          .where(
            (row) =>
                !widget.wifiTransferSelection ||
                (row.localItem == null &&
                    row.deviceFile != null &&
                    row.deviceFile!.syncState !=
                        RecordingCardFileSyncState.synced),
          )
          .map((row) => row.selectionId)
          .toSet();
      _pruneSelectionSoon(eligibleSelectionIds);
    }
    final filePresentations = isCardProjection
        ? _currentCardFilePresentations(cardController.state)
        : const <RecordingCardFilePresentation>[];
    final unsyncedCount = filePresentations
        .where(
          (item) =>
              item.status.isAutomaticCandidate || item.status.hasActiveTransfer,
        )
        .length;
    final recordings = projection.rows;
    final selectedRows = selectionProjection.rows;
    final selectableDeviceFiles = selectedRows
        .where((row) => row.deviceFile != null)
        .map((row) => row.deviceFile!)
        .toList(growable: false);
    final playback = _playbackController.state;
    final retainedWifiBatch = cardController.state.wifiBatch;
    final wifiBatch = _wifiBatchMatchesCurrentCard(retainedWifiBatch)
        ? retainedWifiBatch
        : null;
    final quickWifiMatchesCurrentCard =
        quickWifiState.keepsSyncCardVisible &&
        quickWifiState.expectedCardSnDigest == digest &&
        (quickWifiState.expectedDeviceFingerprint == null ||
            quickWifiState.expectedDeviceFingerprint ==
                cardController
                    .state
                    .snapshot
                    .deviceState
                    .safeDeviceFingerprint ||
            quickWifiState.batchId == wifiBatch?.batchId);
    final quickWifiBusy =
        quickWifiMatchesCurrentCard && !quickWifiState.isTerminal;
    final projectionByFileKey = <String, RecordingCardFilePresentation>{
      for (final item in filePresentations) item.file.localFileKey: item,
    };
    if (wifiBatch != null &&
        (wifiBatch.state == RecordingCardWifiBatchState.completed ||
            wifiBatch.state == RecordingCardWifiBatchState.cancelled) &&
        (!quickWifiBusy || quickWifiState.batchId == wifiBatch.batchId) &&
        digest != null &&
        libraryState.hasVerifiedInventory &&
        cardController.state.fileCatalog.isReady) {
      final projectionReady = recordingCardTerminalWifiProjectionIsReady(
        batch: wifiBatch,
        projectionByFileKey: projectionByFileKey,
      );
      if (projectionReady) {
        _acknowledgeTerminalWifiProjectionSoon(
          quickWifi,
          batch: wifiBatch,
          cardSnDigest: digest,
        );
      }
    } else if (quickWifiMatchesCurrentCard &&
        quickWifiState.batchId == null &&
        quickWifiState.phase == RecordingCardQuickWifiPhase.completed &&
        digest != null &&
        libraryState.hasVerifiedInventory &&
        cardController.state.fileCatalog.isReady) {
      final unverifiedTargetCount = quickWifiState.targetFileKeys
          .where(
            (key) =>
                projectionByFileKey[key]?.status !=
                RecordingCardFileDisplayStatus.synced,
          )
          .length;
      if (unverifiedTargetCount == 0) {
        _acknowledgeQuickWifiProjectionSoon(
          quickWifi,
          quickWifiState,
          cardSnDigest: digest,
        );
      }
    }
    final hasActiveTransfer = cardController.hasActiveTransfer;
    final deviceControllerIdle =
        cardController.state.status == RecordingCardControllerStatus.idle;
    final cardRecordingIdle =
        cardController.state.snapshot.recordingInfo.state ==
        RecordingCardRecordingState.idle;
    final canMutateDevice =
        operationallyConnected &&
        autoSync.connectedCardSnDigest != null &&
        cardController.hasLoadedFilesForCurrentConnection &&
        !hasActiveTransfer &&
        !cardController.hasActiveDeviceOperation &&
        deviceControllerIdle &&
        cardRecordingIdle &&
        !_wifiBatchActionInFlight &&
        !quickWifiBusy &&
        !_deviceDeleteInFlight;
    final operation = cardController.state.operation;
    final canHandoffAutomaticBluetooth =
        operationallyConnected &&
        autoSync.connectedCardSnDigest != null &&
        cardController.hasLoadedFilesForCurrentConnection &&
        cardRecordingIdle &&
        operation.phase == RecordingCardOperationPhase.running &&
        operation.kind == RecordingCardOperationKind.bluetoothTransfer &&
        operation.origin == RecordingCardOperationOrigin.automatic &&
        !_wifiBatchActionInFlight &&
        !quickWifiBusy &&
        !_deviceDeleteInFlight;
    final selectedDeviceFiles = selectableDeviceFiles
        .where((file) => _selectedIds.contains(_deviceSelectionId(file)))
        .toList(growable: false);
    final wifiEligibleDeviceFiles = selectedDeviceFiles
        .where((file) => file.syncState != RecordingCardFileSyncState.synced)
        .toList(growable: false);
    final selectedDeviceBytes = selectedDeviceFiles.fold<int>(
      0,
      (total, file) => total + (file.sizeBytes ?? 0),
    );
    final selectedLocalItems = selectedRows
        .where((row) => row.deviceFile == null)
        .map((row) => row.localItem)
        .whereType<RecordingLibraryItem>()
        .where((item) => _selectedIds.contains(_localSelectionId(item)))
        .toList(growable: false);
    final selectedLocalBytes = selectedLocalItems.fold<int>(
      0,
      (total, item) => total + item.sizeBytes,
    );
    _publishManagementSelectionSoon(
      V3RecordingLibraryBatchSelection(
        // Preserve the legacy field for consumers that still render this value.
        tab: selectedDeviceFiles.isNotEmpty && selectedLocalItems.isEmpty
            ? V3RecordingLibraryTab.device
            : V3RecordingLibraryTab.local,
        selectedCount: selectedDeviceFiles.length + selectedLocalItems.length,
        selectedBytes: selectedDeviceBytes + selectedLocalBytes,
        deviceSelectedCount: selectedDeviceFiles.length,
        wifiEligibleCount: wifiEligibleDeviceFiles.length,
        canDelete:
            widget.projection == V3RecordingLibraryProjection.recordingCardFiles
            ? selectedDeviceFiles.isNotEmpty && canMutateDevice
            : selectedLocalItems.isNotEmpty,
        canWifiDownload:
            wifiEligibleDeviceFiles.isNotEmpty &&
            canMutateDevice &&
            cardController.state.snapshot.deviceState.wifiSupported == true,
        canBluetoothDownload:
            wifiEligibleDeviceFiles.isNotEmpty && canMutateDevice,
        canTranscribe:
            selectedLocalItems.any(
              (item) => !isMonologueRecordingHistoryItem(item),
            ) &&
            !_transcriptionActionInFlight &&
            widget.projection !=
                V3RecordingLibraryProjection.recordingCardFiles,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (uiController.batchMode && widget.managementController == null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('library-batch-actions'),
              onPressed: selectedLocalItems.isEmpty ? null : _openBatchActions,
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('批量操作'),
            ),
          ),
        if (isCardProjection && wifiBatch != null) ...[
          const SizedBox(height: 8),
          V3WifiBatchProgressPanel(
            batch: wifiBatch,
            bytesPerSecond: wifiBatch.bytesPerSecond ?? 0,
            actionBusy: _wifiBatchActionInFlight,
            onStart: () => unawaited(_startQueuedWifiBatch()),
            onPause: () => unawaited(_pauseWifiBatch()),
            onResume: () => unawaited(_resumeWifiBatch()),
            onRetryFailed: () => unawaited(_retryFailedWifiBatch()),
            onCancel: () => unawaited(_cancelWifiBatch()),
            onDismiss: () => unawaited(_dismissWifiBatch()),
          ),
        ] else if (isCardProjection && quickWifiMatchesCurrentCard) ...[
          const SizedBox(height: 8),
          V3QuickWifiPreparationPanel(
            state: quickWifiState,
            onRetry: () {
              final requestId = quickWifiState.requestId;
              if (requestId != null) unawaited(quickWifi.retry(requestId));
            },
          ),
        ],
        if (isCardProjection &&
            wifiBatch == null &&
            !quickWifiMatchesCurrentCard &&
            (unsyncedCount > 0 ||
                scopedTasks.isNotEmpty ||
                automaticTranscriptionActive ||
                automaticSyncSessionVisible)) ...[
          const SizedBox(height: 8),
          V3RecordingAutoSyncPanel(
            state: scopedAutoState,
            unsyncedCount: unsyncedCount,
            progress:
                cardController.state.operation.origin ==
                        RecordingCardOperationOrigin.automatic &&
                    scopedTasks.any(
                      (task) =>
                          task.taskId == scopedAutoState.activeTaskId &&
                          task.localFileKey ==
                              visibleTransferProgress?.localFileKey,
                    )
                ? visibleTransferProgress
                : null,
            uploadBytesSent: autoUploadBytesSent,
            uploadTotalBytes: autoUploadTotalBytes,
            uploadBytesPerSecond: autoUploadBytesPerSecond,
            uploadEstimatedRemainingSeconds:
                autoUploadEstimatedRemainingSeconds,
            onStart: () => unawaited(autoSync.setAutoSyncEnabled(true)),
            onPause: () => unawaited(autoSync.pause()),
            onContinue: autoSync.continueSync,
            onRetry: autoSync.retry,
            quickWifiEnabled:
                unsyncedCount > 0 &&
                !quickWifiBusy &&
                (canMutateDevice || canHandoffAutomaticBluetooth) &&
                cardController.state.snapshot.deviceState.wifiSupported == true,
            onQuickWifiTransfer: () =>
                unawaited(_downloadAllUnsyncedDeviceFiles()),
          ),
        ],
        if (_uploadingRecordingId != null) ...[
          const SizedBox(height: 8),
          V3RecordingUploadProgressPanel(
            title: _uploadingRecordingTitle ?? '录音',
            status: activeUploadState?.status,
            bytesSent: activeUploadProgress?.bytesSent ?? 0,
            totalBytes: activeUploadProgress?.totalBytes ?? 0,
            bytesPerSecond: activeUploadProgress?.bytesPerSecond ?? 0,
            estimatedRemainingSeconds:
                activeUploadProgress?.estimatedRemainingSeconds,
          ),
        ],
        const SizedBox(height: 7),
        V3Card(
          padding: EdgeInsets.zero,
          radius: 0,
          variant: V3CardVariant.flat,
          color: colors.canvas,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
                child: _RecordingBatchHeader(
                  deviceFiles:
                      widget.projection ==
                      V3RecordingLibraryProjection.recordingCardFiles,
                  batchMode: uiController.batchMode,
                  selectedCount:
                      selectedDeviceFiles.length + selectedLocalItems.length,
                  totalCount: recordings.length,
                  onManage: () {
                    _clearSelection();
                    final callback = widget.onEnterBatchMode;
                    if (callback != null) {
                      callback();
                    } else {
                      _recordingUiController.setBatchMode(true);
                    }
                  },
                  onSelectAll: _selectAllCurrentRecordings,
                  onClear: _clearSelection,
                  onExit: _exitBatchMode,
                ),
              ),
              if (libraryState.status ==
                      RecordingLibraryControllerStatus.loading &&
                  recordings.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 38),
                  child: CircularProgressIndicator(),
                )
              else if (recordings.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 42),
                  child: Text(
                    _emptyText(
                      importAbove: isCardProjection,
                      recordingCardManagement: isCardProjection,
                      recordingCardFiles:
                          widget.projection ==
                          V3RecordingLibraryProjection.recordingCardFiles,
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.muted,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else ...[
                for (var index = 0; index < recordings.length; index++) ...[
                  if (widget.projection ==
                          V3RecordingLibraryProjection.recordingCardFiles &&
                      _startsRecordingDateGroup(recordings, index))
                    _RecordingDateGroupHeader(
                      label: _recordingDateGroupLabel(
                        recordings[index].recordedAt,
                      ),
                    ),
                  _buildRecordingRow(
                    row: recordings[index],
                    isLast: index == recordings.length - 1,
                    uiController: uiController,
                    playback: playback,
                    cardController: cardController,
                    directTransferProgress: wifiBatch == null
                        ? visibleTransferProgress
                        : null,
                    canMutateDevice: canMutateDevice,
                  ),
                ],
              ],
            ],
          ),
        ),
        if (libraryState.lastErrorCode != null) ...[
          const SizedBox(height: 10),
          Text(
            recordingLibraryFailureMessage(
              libraryState.lastErrorCode,
              action: '录音库操作',
            ),
            style: TextStyle(
              color: colors.danger,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildRecordingRow({
    required _MergedRecordingRow row,
    required bool isLast,
    required RecordingLibraryUiController uiController,
    required RecordingPlaybackState playback,
    required RecordingCardController cardController,
    required RecordingCardTransferProgress? directTransferProgress,
    required bool canMutateDevice,
  }) {
    final item = row.localItem;
    if (item != null &&
        !uiController.batchMode &&
        playback.item != null &&
        playback.recordingId == item.recordingId) {
      return V3RecordingPlaybackPanel(
        key: ValueKey('recording-inline-player-${item.recordingId}'),
        controller: _playbackController,
        availabilityLabel: row.availabilityLabel,
        transcriptionLabel: _transcriptionStateFor(item).label,
        onToggle: () => unawaited(_togglePlayback(playback.item!)),
        onSeek: _playbackController.seekTo,
        onRate: (rate) => unawaited(_playbackController.setRate(rate)),
        onClose: () => unawaited(_playbackController.release()),
        onMore: (anchorContext) => _openItemMenu(item, anchorContext),
      );
    }
    final file = row.deviceFile;
    final fileKey = file?.localFileKey;
    final progress =
        fileKey != null && directTransferProgress?.localFileKey == fileKey
        ? directTransferProgress
        : null;
    final busy =
        (row.cardPresentation?.status.hasActiveTransfer ?? false) ||
        (fileKey != null &&
            cardController.state.status ==
                RecordingCardControllerStatus.deleting &&
            cardController.state.activeFileKey == fileKey);
    final synced = row.isSynced;
    final transcription = _transcriptionStateFor(item);
    final hasDeviceTranscriptionReceipt =
        file != null && (_presentationFor(file)?.transcribed ?? false);
    final selectionId = row.selectionId;
    final wifiSelectionEligible =
        item == null &&
        file != null &&
        file.syncState != RecordingCardFileSyncState.synced;
    final selectionEnabled =
        !widget.wifiTransferSelection || wifiSelectionEligible;
    final managementKey = item?.recordingId ?? file!.localFileKey;
    final statusLabel = synced ? '已同步' : row.availabilityLabel;
    final durationSeconds = item != null && item.durationSeconds > 0
        ? item.durationSeconds
        : null;
    return _RecordingLibraryRow(
      key: ValueKey('recording-card-management-row-$managementKey'),
      title: _recordingLibraryTitle(row),
      recordedAt: row.recordedAt,
      durationSeconds: durationSeconds,
      deviceMetadata:
          widget.projection == V3RecordingLibraryProjection.recordingCardFiles,
      sizeBytes: file?.sizeBytes,
      deviceDurationSeconds: file?.durationSeconds,
      lastSyncedAt: file == null ? null : _lastSyncedAtFor(file),
      lastSyncedKey: file == null
          ? null
          : ValueKey('recording-card-last-synced-${file.localFileKey}'),
      statusLabel: statusLabel,
      transcriptionLabel: hasDeviceTranscriptionReceipt
          ? '已转写'
          : transcription.badgeLabel,
      transcribedKey: item == null
          ? ValueKey('recording-card-transcribed-${file!.localFileKey}')
          : ValueKey('recording-transcribed-${item.recordingId}'),
      rowKey: item == null
          ? ValueKey('recording-card-device-row-${file!.localFileKey}')
          : null,
      statusKey: item == null
          ? ValueKey(
              synced
                  ? 'recording-card-device-synced-label-${file!.localFileKey}'
                  : 'recording-card-device-unsynced-label-${file!.localFileKey}',
            )
          : ValueKey('recording-availability-${item.recordingId}'),
      cancelKey: file == null
          ? null
          : ValueKey('recording-card-cancel-transfer-${file.localFileKey}'),
      progressLabelKey: file == null
          ? null
          : ValueKey('recording-card-transfer-progress-${file.localFileKey}'),
      batchMode: uiController.batchMode,
      selected: _selectedIds.contains(selectionId),
      isPlaying:
          item != null &&
          playback.isPlaying &&
          playback.recordingId == item.recordingId,
      busy: busy,
      progress: progress,
      cancelling:
          cardController.state.status ==
          RecordingCardControllerStatus.cancellingTransfer,
      showDivider: !isLast,
      leadingKey: ValueKey(
        item == null
            ? 'recording-card-management-play-${file!.localFileKey}'
            : 'recording-leading-${item.recordingId}',
      ),
      moreKey: ValueKey(
        item == null
            ? 'recording-card-management-more-${file!.localFileKey}'
            : 'recording-row-more-${item.recordingId}',
      ),
      onTap: !selectionEnabled
          ? null
          : uiController.batchMode && file != null
          ? () => _toggleDeviceFileSelection(file)
          : widget.projection == V3RecordingLibraryProjection.recordingCardFiles
          ? () => unawaited(_showRecordingFileDetails(item, file))
          : item != null
          ? () => _handleRowTap(uiController, item)
          : null,
      onCancelTransfer: file == null ? null : _cancelDeviceTransfer,
      onMore: (anchorContext) {
        if (widget.projection !=
                V3RecordingLibraryProjection.recordingCardFiles &&
            item != null) {
          unawaited(_openItemMenu(item, anchorContext));
          return;
        }
        unawaited(
          _openDeviceFileMenu(
            file!,
            anchorContext,
            showDetails: true,
            wifiEnabled:
                !busy &&
                !synced &&
                canMutateDevice &&
                cardController.state.snapshot.deviceState.wifiSupported == true,
            bluetoothEnabled: !busy && !synced && canMutateDevice,
            deleteEnabled: !busy && canMutateDevice,
          ),
        );
      },
    );
  }

  List<RecordingCardFilePresentation> _currentCardFilePresentations(
    RecordingCardControllerState card, {
    List<RecordingCardScannedFile>? directory,
    String? cardSnDigest,
  }) {
    final provided = widget.deviceFilePresentations;
    if (provided != null && directory == null) return provided;
    final autoSync = ref.read(recordingCardAutoSyncCoordinatorProvider);
    final library = ref.read(recordingLibraryControllerProvider);
    return buildRecordingCardFilePresentations(
      directory: directory ?? card.snapshot.files,
      ledger: autoSync.connectedCardLedger,
      cardSnDigest:
          cardSnDigest ??
          widget.recordingCardSnDigest ??
          autoSync.connectedCardSnDigest,
      card: card,
      localRecordingLookup: library.findById,
      localInventoryLoaded: library.state.hasVerifiedInventory,
      receipts: ref
          .read(recordingTranscriptionReceiptStoreProvider)
          .listReceipts(),
    );
  }

  RecordingCardFilePresentation? _presentationFor(
    RecordingCardScannedFile file,
  ) =>
      _currentCardFilePresentations(
            ref.read(recordingCardControllerProvider).state,
          )
          .where(
            (item) =>
                item.file.localFileKey == file.localFileKey &&
                item.file.deviceFileId == file.deviceFileId,
          )
          .firstOrNull;

  DateTime? _lastSyncedAtFor(RecordingCardScannedFile file) =>
      _presentationFor(file)?.lastSyncedAt;

  _RecordingTranscriptionState _transcriptionStateFor(
    RecordingLibraryItem? item,
  ) {
    if (item == null) return _RecordingTranscriptionState.notTranscribed;
    if (_durableTranscriptionReceiptFor(item) != null) {
      return _RecordingTranscriptionState.transcribed;
    }
    final remoteId = item.remoteRecordingId?.trim();
    if (remoteId == null || remoteId.isEmpty) {
      return _RecordingTranscriptionState.notTranscribed;
    }
    final trackedStatus = _processingState?.taskFor(remoteId)?.status;
    if (trackedStatus != null) {
      return switch (trackedStatus) {
        RecordingFileJobStatus.ready => _RecordingTranscriptionState.unknown,
        RecordingFileJobStatus.failed => _RecordingTranscriptionState.failed,
        RecordingFileJobStatus.uploading || RecordingFileJobStatus.processing =>
          _RecordingTranscriptionState.processing,
      };
    }
    return _RecordingTranscriptionState.unknown;
  }

  RecordingTranscriptionReceipt? _durableTranscriptionReceiptFor(
    RecordingLibraryItem item,
  ) {
    final receiptStore = ref.read(recordingTranscriptionReceiptStoreProvider);
    final rowHash = _normalizedRecordingHash(item.contentHash);
    final localReceipt = receiptStore.findByLocalRecordingId(item.recordingId);
    if (localReceipt != null) {
      final receiptHash = _normalizedRecordingHash(localReceipt.contentHash);
      if (rowHash == null || receiptHash == null || receiptHash == rowHash) {
        return localReceipt;
      }
    }
    if (rowHash != null) {
      final contentReceipt = receiptStore.findByFileIdentity(rowHash);
      final receiptHash = _normalizedRecordingHash(contentReceipt?.contentHash);
      if (contentReceipt != null &&
          (receiptHash == null || receiptHash == rowHash)) {
        return contentReceipt;
      }
    }
    return null;
  }

  List<_MergedRecordingRow> _mergedRecordings({
    required List<RecordingLibraryItem> localItems,
    required List<RecordingCardScannedFile> deviceFiles,
    bool includeUnassignedLocalItems = true,
  }) {
    final eligibleLocalItems = localItems
        .where(
          (item) =>
              item.status != RecordingLibraryStatus.recycled &&
              (item.source != RecordingLibrarySource.device ||
                  item.localFileState == RecordingLocalFileState.ready),
        )
        .toList(growable: false);
    final assignedLocalIds = <String>{};
    final rows = <_MergedRecordingRow>[];
    for (final file in deviceFiles) {
      final localItem = file.syncState == RecordingCardFileSyncState.synced
          ? _matchingLocalItemForDevice(
              file,
              eligibleLocalItems,
              assignedLocalIds,
            )
          : null;
      if (localItem != null) assignedLocalIds.add(localItem.recordingId);
      final row = _MergedRecordingRow(
        localItem: localItem,
        deviceFile: file,
        cardPresentation: _presentationFor(file),
      );
      rows.add(row);
    }
    if (includeUnassignedLocalItems) {
      for (final item in eligibleLocalItems) {
        if (assignedLocalIds.contains(item.recordingId)) continue;
        final row = _MergedRecordingRow(localItem: item);
        rows.add(row);
      }
    }
    rows.sort(_compareMergedRecordings);
    return List<_MergedRecordingRow>.unmodifiable(rows);
  }

  _RecordingProjectionSnapshot _recordingProjectionSnapshot({
    required List<RecordingLibraryItem> localItems,
    required RecordingCardControllerState cardState,
  }) {
    // Device-directory rows belong exclusively to the dedicated card-files page.
    final deviceFiles =
        widget.projection == V3RecordingLibraryProjection.recordingCardFiles
        ? _currentCardFilePresentations(
            cardState,
          ).map((item) => item.file).toList(growable: false)
        : const <RecordingCardScannedFile>[];
    final projectedLocalItems = switch (widget.projection) {
      V3RecordingLibraryProjection.recordingCardInventory =>
        localItems
            .where(
              (item) =>
                  item.source == RecordingLibrarySource.device &&
                  item.status != RecordingLibraryStatus.recycled &&
                  item.localFileState == RecordingLocalFileState.ready,
            )
            .toList(growable: false),
      V3RecordingLibraryProjection.recordingCardFiles =>
        localItems
            .where(
              (item) =>
                  item.source == RecordingLibrarySource.device &&
                  item.status != RecordingLibraryStatus.recycled &&
                  item.localFileState == RecordingLocalFileState.ready,
            )
            .toList(growable: false),
      V3RecordingLibraryProjection.personalLibrary =>
        localItems
            .where(
              (item) =>
                  item.status != RecordingLibraryStatus.recycled &&
                  item.status != RecordingLibraryStatus.deviceOnly &&
                  item.localFileState == RecordingLocalFileState.ready &&
                  (isMonologueRecordingHistoryItem(item) ||
                      isInternalRecordingHistoryItem(item) ||
                      isExternalRecordingHistoryItem(item)),
            )
            .toList(growable: false),
    };
    return _RecordingProjectionSnapshot(
      deviceFiles: deviceFiles,
      rows: _mergedRecordings(
        localItems: projectedLocalItems,
        deviceFiles: deviceFiles,
        includeUnassignedLocalItems:
            widget.projection !=
            V3RecordingLibraryProjection.recordingCardFiles,
      ),
    );
  }

  RecordingLibraryItem? _matchingLocalItemForDevice(
    RecordingCardScannedFile file,
    List<RecordingLibraryItem> localItems,
    Set<String> assignedLocalIds,
  ) {
    Iterable<RecordingLibraryItem> candidates() sync* {
      for (final item in localItems) {
        if (assignedLocalIds.contains(item.recordingId) ||
            item.localFileState != RecordingLocalFileState.ready) {
          continue;
        }
        yield item;
      }
    }

    if (file.syncState != RecordingCardFileSyncState.synced) return null;
    final linkedLocalId = file.localFileId?.trim();
    final privateUri = file.appPrivateUri?.trim();
    if (linkedLocalId == null ||
        linkedLocalId.isEmpty ||
        privateUri == null ||
        privateUri.isEmpty) {
      return null;
    }
    for (final item in candidates()) {
      if (item.recordingId == linkedLocalId &&
          item.appPrivateUri == privateUri) {
        return item;
      }
    }
    return null;
  }

  int _compareMergedRecordings(
    _MergedRecordingRow left,
    _MergedRecordingRow right,
  ) {
    if (widget.projection != V3RecordingLibraryProjection.recordingCardFiles) {
      final byState = left.sortGroup.compareTo(right.sortGroup);
      if (byState != 0) return byState;
    }
    final leftAt = left.recordedAt;
    final rightAt = right.recordedAt;
    if (leftAt != null && rightAt != null) {
      final byTime = rightAt.compareTo(leftAt);
      if (byTime != 0) return byTime;
    } else if (leftAt != null) {
      return -1;
    } else if (rightAt != null) {
      return 1;
    }
    final byName = right.title.compareTo(left.title);
    if (byName != 0) return byName;
    return left.selectionId.compareTo(right.selectionId);
  }

  bool _wifiBatchMatchesCurrentCard(RecordingCardWifiBatchSnapshot? batch) {
    if (widget.projection == V3RecordingLibraryProjection.personalLibrary) {
      return false;
    }
    final autoSync = ref.read(recordingCardAutoSyncCoordinatorProvider);
    return recordingCardWifiBatchMatchesCard(
      batch: batch,
      cardSnDigest:
          widget.recordingCardSnDigest ??
          autoSync.connectedCardSnDigest ??
          autoSync.syncSession.cardSnDigest,
      deviceFingerprint: ref
          .read(recordingCardControllerProvider)
          .state
          .snapshot
          .deviceState
          .safeDeviceFingerprint,
    );
  }

  void _reportCompletedWifiBatch(RecordingCardWifiBatchSnapshot batch) {
    if (!_wifiBatchMatchesCurrentCard(batch)) return;
    var newlyCompleted = false;
    for (final item in batch.items.where(
      (item) => item.state == RecordingCardWifiBatchItemState.completed,
    )) {
      newlyCompleted =
          _reportedWifiCompletionKeys.add(
            '${batch.batchId}:${item.ledgerSourceSignature ?? item.file.deviceFileId}',
          ) ||
          newlyCompleted;
    }
    final completed = batch.items
        .where(
          (item) => item.state == RecordingCardWifiBatchItemState.completed,
        )
        .map((item) => item.file)
        .toList(growable: false);
    if (newlyCompleted && completed.isNotEmpty) {
      widget.onSyncBatchCompleted?.call(completed);
    }
    final settlementKey = <Object?>[
      batch.batchId,
      batch.state.name,
      batch.completedCount,
      batch.remainingCount,
      batch.failureCode,
    ].join(':');
    final cardSnDigest = batch.cardSnDigest?.trim();
    if (cardSnDigest != null &&
        cardSnDigest.isNotEmpty &&
        _reportedWifiSettlementKeys.add(settlementKey)) {
      widget.onSyncBatchSettled?.call(
        V3RecordingCardSyncSettlement(
          cardSnDigest: cardSnDigest,
          completedFiles: completed,
          completedCount: batch.completedCount,
          remainingCount: batch.remainingCount,
        ),
      );
    }
  }

  bool get _ownsCardFeedback =>
      mounted &&
      widget.projection != V3RecordingLibraryProjection.personalLibrary &&
      (ModalRoute.of(context)?.isCurrent ?? false);

  void _announceCompletedWifiBatch(RecordingCardWifiBatchSnapshot batch) {
    if (!_ownsCardFeedback || !_wifiBatchMatchesCurrentCard(batch)) return;
    if (!_announcedWifiCompletionBatchIds.add(batch.batchId)) return;
    showV3Snack(
      context,
      recordingCardWifiBatchSettlementMessage(batch, prefix: 'Wi-Fi 传输完成'),
    );
  }

  void _presentWifiBatchSettlement(RecordingCardWifiBatchSnapshot batch) {
    if (!_ownsCardFeedback || !_wifiBatchMatchesCurrentCard(batch)) return;
    _reportCompletedWifiBatch(batch);
    _removeCompletedWifiSelection(batch);
    switch (batch.state) {
      case RecordingCardWifiBatchState.completed:
        unawaited(ref.read(recordingLibraryControllerProvider).load());
        _announceCompletedWifiBatch(batch);
        break;
      case RecordingCardWifiBatchState.paused:
        unawaited(ref.read(recordingLibraryControllerProvider).load());
        showV3Snack(
          context,
          recordingCardWifiBatchSettlementMessage(
            batch,
            prefix: recordingCardWifiPausedBatchMessage(
              itemErrorCodes: batch.items.map((item) => item.errorCode),
              fallbackErrorCode:
                  batch.failureCode ??
                  ref.read(recordingCardControllerProvider).state.lastErrorCode,
            ),
          ),
        );
        break;
      case RecordingCardWifiBatchState.failed:
        unawaited(ref.read(recordingLibraryControllerProvider).load());
        showV3Snack(
          context,
          recordingCardWifiBatchSettlementMessage(batch, prefix: 'Wi-Fi 传输已中断'),
        );
        break;
      case RecordingCardWifiBatchState.cancelled:
        unawaited(ref.read(recordingLibraryControllerProvider).load());
        showV3Snack(
          context,
          recordingCardWifiBatchSettlementMessage(batch, prefix: 'Wi-Fi 传输已结束'),
        );
        break;
      case RecordingCardWifiBatchState.queued:
      case RecordingCardWifiBatchState.awaitingHotspot:
      case RecordingCardWifiBatchState.openingSession:
      case RecordingCardWifiBatchState.transferring:
      case RecordingCardWifiBatchState.verifying:
      case RecordingCardWifiBatchState.registering:
      case RecordingCardWifiBatchState.reconciling:
        break;
    }
  }

  Future<int> _persistSuccessfulCardDeletionReceipts(
    List<RecordingCardScannedFile> files,
    Set<String> failedDeviceFileIds, {
    required RecordingCardAutoSyncStore store,
    required LocalRecordingRepository repository,
    required String cardSnDigest,
  }) async {
    final deletedFiles = files
        .where((file) => !failedDeviceFileIds.contains(file.deviceFileId))
        .toList(growable: false);
    if (deletedFiles.isEmpty) return 0;
    var writeFailures = 0;
    var wroteReceipt = false;
    for (final file in deletedFiles) {
      try {
        store.markCardDeletedForFile(
          cardSnDigest: cardSnDigest,
          file: file,
          at: DateTime.now(),
        );
        wroteReceipt = true;
      } on Object {
        writeFailures += 1;
      }
    }
    if (!wroteReceipt) return writeFailures;
    final flushed = await repository.flushRecordingCardPersistence();
    if (!flushed.ok) return deletedFiles.length;
    return writeFailures;
  }

  Future<void> _downloadDeviceFile(RecordingCardScannedFile file) async {
    final controller = ref.read(recordingCardControllerProvider);
    final operationCardSnDigest = _currentCardSnDigest();
    if (controller.hasActiveDeviceOperation || controller.hasActiveTransfer) {
      showV3Snack(context, '录音卡正在处理其他任务，请等待完成后再传输');
      return;
    }
    final result = await controller.downloadFileResult(file);
    if (!mounted) return;
    final downloaded = result.value;
    final completed =
        result.ok &&
        downloaded != null &&
        downloaded.localFileKey == file.localFileKey;
    if (!completed) {
      final code =
          result.error?.code ??
          controller.state.lastErrorCode ??
          controller.operationBlockCode;
      showV3Snack(
        context,
        code != null &&
                recordingCardFailureStage(code) ==
                    RecordingCardFailureStage.coordination
            ? recordingLibraryFailureMessage(code, action: '传输')
            : code == null || code == 'RECORDING_CARD_TRANSFER_CANCELLED'
            ? '蓝牙传输已取消'
            : '蓝牙传输失败（${_recordingCardTransferStageLabel(code)}），请重试',
      );
      return;
    }
    _emitManualSyncSettlement(
      cardSnDigest: operationCardSnDigest,
      completedFiles: <RecordingCardScannedFile>[file],
      remainingCount: 0,
    );
    await ref.read(recordingLibraryControllerProvider).load();
    if (mounted) showV3Snack(context, '已下载到本地录音库');
  }

  Future<void> _cancelDeviceTransfer() async {
    final controller = ref.read(recordingCardControllerProvider);
    await controller.cancelFileTransfer();
    if (!mounted) return;
    final code = controller.state.lastErrorCode;
    showV3Snack(
      context,
      code == null
          ? '已取消蓝牙传输'
          : recordingLibraryFailureMessage(code, action: '取消传输'),
    );
  }

  Future<void> _confirmDeleteDeviceFiles(
    List<RecordingCardScannedFile> files, {
    int retainedLocalCopyCount = 0,
  }) async {
    if (files.isEmpty || _deviceDeleteInFlight) return;
    final countLabel = '${files.length} 条录音卡文件';
    final retainedCount = retainedLocalCopyCount < 0
        ? 0
        : retainedLocalCopyCount > files.length
        ? files.length
        : retainedLocalCopyCount;
    final confirmationMessage = retainedCount == 0
        ? '将从录音卡永久删除$countLabel，此操作无法恢复。'
        : retainedCount == files.length
        ? '将从录音卡永久删除$countLabel，本地录音副本会保留。此操作无法恢复。'
        : '将从录音卡永久删除$countLabel，其中 $retainedCount 条已同步录音的本地副本会保留。此操作无法恢复。';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = HuahuoV3Theme.tokensOf(dialogContext);
        return V3GlassDialogFrame(
          title: '永久删除录音卡文件？',
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 32,
          ),
          borderRadius: 28,
          content: Text(confirmationMessage),
          actions: <Widget>[
            SizedBox(
              width: 146,
              height: 50,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
            ),
            SizedBox(
              width: 146,
              height: 50,
              child: FilledButton(
                key: const ValueKey('recording-card-confirm-device-delete'),
                onPressed: () => Navigator.pop(dialogContext, true),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.ink,
                  foregroundColor: HuahuoV3Theme.readableForeground(
                    colors.canvas,
                    background: colors.ink,
                    fallback: colors.canvas,
                    minimumRatio: 3,
                  ),
                ),
                child: const Text('永久删除'),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed == true && mounted) await _deleteDeviceFiles(files);
  }

  Future<bool> _deleteDeviceFiles(List<RecordingCardScannedFile> files) async {
    if (files.isEmpty || _deviceDeleteInFlight) return false;
    final cardSnDigest = ref
        .read(recordingCardAutoSyncCoordinatorProvider)
        .connectedCardSnDigest;
    if (cardSnDigest == null) {
      showV3Snack(context, '未能确认录音卡身份，请重新连接后重试');
      return false;
    }
    final deletionStore = ref.read(recordingCardAutoSyncStoreProvider);
    final deletionRepository = ref.read(localRecordingRepositoryProvider);
    setState(() => _deviceDeleteInFlight = true);
    final controller = ref.read(recordingCardControllerProvider);
    final result = await controller.deleteFiles(files);
    final receiptFailures = await _persistSuccessfulCardDeletionReceipts(
      files,
      result.failureCodes.keys.toSet(),
      store: deletionStore,
      repository: deletionRepository,
      cardSnDigest: cardSnDigest,
    );
    if (!mounted) return result.failedCount == 0;
    final deletedSelectionIds = files
        .where((file) => !result.failureCodes.containsKey(file.deviceFileId))
        .map(_deviceSelectionId);
    setState(() {
      _deviceDeleteInFlight = false;
      _selectedIds.removeAll(deletedSelectionIds);
    });
    if (receiptFailures == 0) {
      _showBatchResult('已从录音卡永久删除', result.requestedCount, result.failedCount);
    } else {
      final deviceFailureMessage = result.failedCount == 0
          ? ''
          : '，${result.failedCount} 条设备删除失败';
      showV3Snack(
        context,
        '录音卡已删除 ${result.deletedCount} 条$deviceFailureMessage，'
        '$receiptFailures 条本地删除记录保存失败',
      );
    }
    return result.failedCount == 0 && receiptFailures == 0;
  }

  void _toggleDeviceFileSelection(RecordingCardScannedFile file) {
    if (widget.wifiTransferSelection &&
        file.syncState == RecordingCardFileSyncState.synced) {
      return;
    }
    final selectionId = _deviceSelectionId(file);
    setState(() {
      if (!_selectedIds.add(selectionId)) {
        _selectedIds.remove(selectionId);
      }
    });
  }

  void _selectAllMergedRecordings(List<_MergedRecordingRow> rows) {
    setState(() {
      _selectedIds.addAll(rows.map((row) => row.selectionId));
    });
  }

  void _selectAllCurrentRecordings() {
    final rows = _recordingProjectionSnapshot(
      localItems: ref.read(recordingLibraryControllerProvider).state.items,
      cardState: ref.read(recordingCardControllerProvider).state,
    ).rows;
    _selectAllMergedRecordings(
      widget.wifiTransferSelection
          ? rows
                .where(
                  (row) =>
                      row.localItem == null &&
                      row.deviceFile != null &&
                      row.deviceFile!.syncState !=
                          RecordingCardFileSyncState.synced,
                )
                .toList(growable: false)
          : rows,
    );
  }

  Future<bool> _deleteCurrentSelection() async {
    final rows = _recordingProjectionSnapshot(
      localItems: ref.read(recordingLibraryControllerProvider).state.items,
      cardState: ref.read(recordingCardControllerProvider).state,
    ).rows;
    final selectedLocalItems = rows
        .where((row) => row.deviceFile == null)
        .map((row) => row.localItem)
        .whereType<RecordingLibraryItem>()
        .where((item) => _selectedIds.contains(_localSelectionId(item)))
        .toList(growable: false);
    final selectedDeviceFiles = rows
        .where((row) => row.deviceFile != null)
        .map((row) => row.deviceFile!)
        .where((file) => _selectedIds.contains(_deviceSelectionId(file)))
        .toList(growable: false);
    if (widget.projection != V3RecordingLibraryProjection.recordingCardFiles &&
        selectedLocalItems.isNotEmpty) {
      await _confirmDeleteSelected(selectedLocalItems);
    }
    if (widget.projection != V3RecordingLibraryProjection.recordingCardFiles ||
        !mounted ||
        selectedDeviceFiles.isEmpty) {
      return _selectedIds.isEmpty;
    }
    final card = ref.read(recordingCardControllerProvider);
    final currentCardSnDigest = ref
        .read(recordingCardAutoSyncCoordinatorProvider)
        .connectedCardSnDigest;
    final canDeleteDevice =
        card.state.snapshot.deviceState.isOperationallyConnected &&
        currentCardSnDigest != null &&
        card.hasLoadedFilesForCurrentConnection &&
        !card.hasActiveTransfer &&
        card.state.snapshot.recordingInfo.state ==
            RecordingCardRecordingState.idle &&
        card.state.status == RecordingCardControllerStatus.idle;
    if (!canDeleteDevice) {
      showV3Snack(context, '请先连接空闲的录音卡后删除设备文件');
      return false;
    }
    await _confirmDeleteDeviceFiles(
      selectedDeviceFiles,
      retainedLocalCopyCount: selectedDeviceFiles
          .where((file) => file.syncState == RecordingCardFileSyncState.synced)
          .length,
    );
    return _selectedIds.isEmpty;
  }

  Future<void> _downloadCurrentDeviceSelection() async {
    final rows = _recordingProjectionSnapshot(
      localItems: ref.read(recordingLibraryControllerProvider).state.items,
      cardState: ref.read(recordingCardControllerProvider).state,
    ).rows;
    final selected = rows
        .where((row) => row.deviceFile != null && row.localItem == null)
        .map((row) => row.deviceFile!)
        .where(
          (file) =>
              _selectedIds.contains(_deviceSelectionId(file)) &&
              file.syncState != RecordingCardFileSyncState.synced,
        )
        .toList(growable: false);
    if (selected.isEmpty) return;
    await _openQuickWifiTransfer(selectedFiles: selected);
  }

  Future<bool> _downloadCurrentDeviceSelectionOverBluetooth() async {
    final rows = _recordingProjectionSnapshot(
      localItems: ref.read(recordingLibraryControllerProvider).state.items,
      cardState: ref.read(recordingCardControllerProvider).state,
    ).rows;
    final selected = List<RecordingCardScannedFile>.unmodifiable(
      rows
          .map((row) => row.deviceFile)
          .whereType<RecordingCardScannedFile>()
          .where(
            (file) =>
                _selectedIds.contains(_deviceSelectionId(file)) &&
                file.syncState != RecordingCardFileSyncState.synced,
          ),
    );
    if (selected.isEmpty) return _selectedIds.isEmpty;
    final controller = ref.read(recordingCardControllerProvider);
    final operationCardSnDigest = _currentCardSnDigest();
    if (controller.hasActiveDeviceOperation || controller.hasActiveTransfer) {
      showV3Snack(context, '录音卡正在处理其他任务，请等待完成后再传输');
      return false;
    }
    final libraryController = ref.read(recordingLibraryControllerProvider);
    final result = await controller.downloadFilesOverBluetooth(selected);
    await libraryController.load();
    if (!mounted) return false;
    final batch = result.value;
    if (!result.ok || batch == null) {
      showV3Snack(
        context,
        recordingLibraryFailureMessage(result.error?.code, action: '蓝牙同步'),
      );
      return false;
    }
    final completedFiles = batch.completedFiles;
    _emitManualSyncSettlement(
      cardSnDigest: operationCardSnDigest,
      completedFiles: completedFiles,
      remainingCount: batch.remainingCount,
    );
    setState(
      () => _selectedIds.removeAll(completedFiles.map(_deviceSelectionId)),
    );
    showV3Snack(
      context,
      '蓝牙同步结束：已同步 ${batch.completedCount} 条，未同步 ${batch.remainingCount} 条',
    );
    return _selectedIds.isEmpty;
  }

  String? _currentCardSnDigest() {
    final explicit = widget.recordingCardSnDigest?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final autoSync = ref.read(recordingCardAutoSyncCoordinatorProvider);
    final resolved =
        autoSync.connectedCardSnDigest ?? autoSync.syncSession.cardSnDigest;
    final normalized = resolved?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  void _emitManualSyncSettlement({
    required String? cardSnDigest,
    required List<RecordingCardScannedFile> completedFiles,
    required int remainingCount,
  }) {
    final frozen = List<RecordingCardScannedFile>.unmodifiable(completedFiles);
    if (frozen.isNotEmpty) widget.onSyncBatchCompleted?.call(frozen);
    final normalizedDigest = cardSnDigest?.trim();
    if (normalizedDigest == null || normalizedDigest.isEmpty) return;
    widget.onSyncBatchSettled?.call(
      V3RecordingCardSyncSettlement(
        cardSnDigest: normalizedDigest,
        completedFiles: frozen,
        completedCount: frozen.length,
        remainingCount: remainingCount,
      ),
    );
  }

  Future<void> _downloadAllUnsyncedDeviceFiles() async {
    await _openQuickWifiTransfer(allUnsynced: true);
  }

  void _publishManagementSelectionSoon(
    V3RecordingLibraryBatchSelection selection,
  ) {
    final controller = widget.managementController;
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(widget.managementController, controller)) {
        controller._publish(selection);
      }
    });
  }

  void _pruneSelectionSoon(Set<String> eligibleSelectionIds) {
    final generation = ++_selectionPruneGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _selectionPruneGeneration) return;
      final staleIds = _selectedIds
          .where((id) => !eligibleSelectionIds.contains(id))
          .toList(growable: false);
      if (staleIds.isEmpty) return;
      setState(() => _selectedIds.removeAll(staleIds));
    });
  }

  void _acknowledgeQuickWifiProjectionSoon(
    RecordingCardQuickWifiCoordinator coordinator,
    RecordingCardQuickWifiState state, {
    required String cardSnDigest,
  }) {
    final requestId = state.requestId;
    if (requestId == null || _quickWifiProjectionAckRequestId == requestId) {
      return;
    }
    _quickWifiProjectionAckRequestId = requestId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await coordinator.acknowledgeCompletedProjection(
          requestId: requestId,
          cardSnDigest: cardSnDigest,
          remainingTargetCount: 0,
        );
      } finally {
        if (_quickWifiProjectionAckRequestId == requestId) {
          _quickWifiProjectionAckRequestId = null;
        }
      }
    });
  }

  void _acknowledgeTerminalWifiProjectionSoon(
    RecordingCardQuickWifiCoordinator coordinator, {
    required RecordingCardWifiBatchSnapshot batch,
    required String cardSnDigest,
  }) {
    final acknowledgementKey = '${batch.batchId}:${batch.state.name}';
    if (_wifiTerminalProjectionAckKey == acknowledgementKey) return;
    _wifiTerminalProjectionAckKey = acknowledgementKey;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;
        final controller = ref.read(recordingCardControllerProvider);
        final currentBatch = controller.state.wifiBatch;
        if (currentBatch == null ||
            currentBatch.batchId != batch.batchId ||
            currentBatch.state != batch.state ||
            !_wifiBatchMatchesCurrentCard(currentBatch)) {
          return;
        }
        final currentDigest = _currentCardSnDigest();
        final library = ref.read(recordingLibraryControllerProvider);
        if (currentDigest != cardSnDigest ||
            !library.state.hasVerifiedInventory ||
            !controller.state.fileCatalog.isReady) {
          return;
        }
        final projectionByFileKey = <String, RecordingCardFilePresentation>{
          for (final item in _currentCardFilePresentations(controller.state))
            item.file.localFileKey: item,
        };
        final projectionReady = recordingCardTerminalWifiProjectionIsReady(
          batch: currentBatch,
          projectionByFileKey: projectionByFileKey,
        );
        if (!projectionReady) return;

        final quickState = coordinator.state;
        final quickOwnsBatch =
            quickState.requestId != null &&
            quickState.batchId == currentBatch.batchId &&
            quickState.expectedCardSnDigest == currentDigest;
        if (quickOwnsBatch) {
          if (currentBatch.state == RecordingCardWifiBatchState.completed &&
              quickState.phase == RecordingCardQuickWifiPhase.completed) {
            await coordinator.acknowledgeCompletedProjection(
              requestId: quickState.requestId!,
              cardSnDigest: currentDigest!,
              remainingTargetCount: 0,
            );
          } else if (currentBatch.state ==
                  RecordingCardWifiBatchState.cancelled &&
              quickState.phase == RecordingCardQuickWifiPhase.cancelled) {
            await coordinator.acknowledgeCancelledProjection(
              requestId: quickState.requestId!,
              cardSnDigest: currentDigest!,
              projectionReady: true,
            );
          }
          return;
        }
        await controller.dismissWifiBatch();
      } finally {
        if (_wifiTerminalProjectionAckKey == acknowledgementKey) {
          _wifiTerminalProjectionAckKey = null;
        }
      }
    });
  }

  Future<V3WifiTransferFlowResult?> _openQuickWifiTransfer({
    bool allUnsynced = false,
    List<RecordingCardScannedFile>? selectedFiles,
    RecordingCardWifiBatchSnapshot? existingBatch,
    RecordingCardQuickWifiExistingAction? existingAction,
  }) async {
    if (!mounted || _wifiFlowOpen) return null;
    final controller = ref.read(recordingCardControllerProvider);
    if (existingBatch == null) {
      final state = controller.state;
      if (!state.snapshot.deviceState.isOperationallyConnected ||
          !state.fileCatalog.isReady) {
        showV3Snack(context, '请等待录音卡文件校验完成');
        return null;
      }
      if (state.snapshot.deviceState.wifiSupported != true) {
        showV3Snack(context, '当前录音卡不支持 Wi-Fi 传输');
        return null;
      }
    }
    final coordinator = ref.read(recordingCardQuickWifiCoordinatorProvider);
    final requestId = existingBatch != null && existingAction != null
        ? coordinator.beginExistingBatch(existingBatch, existingAction)
        : allUnsynced
        ? coordinator.beginAllUnsynced()
        : coordinator.beginSelected(
            selectedFiles ?? const <RecordingCardScannedFile>[],
          );
    setState(() => _wifiFlowOpen = true);
    V3WifiTransferFlowResult? outcome;
    try {
      final colors = HuahuoV3Theme.tokensOf(context);
      final sheet = showModalBottomSheet<V3WifiTransferFlowResult>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        barrierColor: colors.ink.withValues(alpha: .42),
        builder: (sheetContext) => PopScope(
          canPop: false,
          child: V3GlassBottomSheet(
            borderRadius: 24,
            child: V3WifiTransferFlowSheet(
              controller: controller,
              quickWifiCoordinator: coordinator,
              quickWifiRequestId: requestId,
              onReady: () => unawaited(coordinator.execute(requestId)),
              onCompleted: () {
                if (!mounted) return;
                final completedBatch = controller.state.wifiBatch;
                if (completedBatch?.state ==
                    RecordingCardWifiBatchState.completed) {
                  _reportCompletedWifiBatch(completedBatch!);
                  _removeCompletedWifiSelection(completedBatch);
                  unawaited(
                    ref.read(recordingLibraryControllerProvider).load(),
                  );
                }
              },
            ),
          ),
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(coordinator.execute(requestId));
      });
      WidgetsBinding.instance.scheduleFrame();
      outcome = await sheet;
    } finally {
      if (mounted) {
        setState(() => _wifiFlowOpen = false);
      }
    }
    if (!mounted) return outcome;
    final settledBatch = controller.state.wifiBatch;
    if (outcome == null &&
        settledBatch?.state == RecordingCardWifiBatchState.completed) {
      outcome = V3WifiTransferFlowResult.completed;
    }
    if (settledBatch != null) _reportCompletedWifiBatch(settledBatch);
    if (settledBatch != null) _removeCompletedWifiSelection(settledBatch);
    if (outcome == V3WifiTransferFlowResult.completed) {
      await ref.read(recordingLibraryControllerProvider).load();
      if (!mounted) return outcome;
      final summary = settledBatch == null
          ? 'Wi-Fi 传输完成'
          : recordingCardWifiBatchSettlementMessage(
              settledBatch,
              prefix: 'Wi-Fi 传输完成',
            );
      showV3Snack(context, summary);
    } else if (outcome == V3WifiTransferFlowResult.cancelled) {
      final cancelledBatch = controller.state.wifiBatch;
      if (cancelledBatch?.state != RecordingCardWifiBatchState.cancelled) {
        await ref.read(recordingLibraryControllerProvider).load();
        if (!mounted) return outcome;
        showV3Snack(
          context,
          cancelledBatch?.state == RecordingCardWifiBatchState.completed
              ? recordingCardWifiBatchSettlementMessage(
                  cancelledBatch!,
                  prefix: 'Wi-Fi 传输完成',
                )
              : cancelledBatch == null
              ? 'Wi-Fi 传输暂未结束，请检查连接后重试'
              : recordingCardWifiBatchSettlementMessage(
                  cancelledBatch,
                  prefix: recordingCardWifiPausedBatchMessage(
                    itemErrorCodes: cancelledBatch.items.map(
                      (item) => item.errorCode,
                    ),
                    fallbackErrorCode:
                        cancelledBatch.failureCode ??
                        controller.state.lastErrorCode,
                  ),
                ),
        );
        return outcome;
      }
      await ref.read(recordingLibraryControllerProvider).load();
      if (!mounted) return outcome;
      final summary = recordingCardWifiBatchSettlementMessage(
        cancelledBatch!,
        prefix: 'Wi-Fi 传输已结束',
      );
      showV3Snack(context, summary);
    } else if (outcome == V3WifiTransferFlowResult.failed) {
      await ref.read(recordingLibraryControllerProvider).load();
      if (!mounted) return outcome;
      if (settledBatch != null) {
        showV3Snack(
          context,
          recordingCardWifiBatchSettlementMessage(
            settledBatch,
            prefix: 'Wi-Fi 传输已中断',
          ),
        );
      }
    }
    return outcome;
  }

  void _removeCompletedWifiSelection(RecordingCardWifiBatchSnapshot batch) {
    final settledPrefixes = batch.items
        .where((item) => item.isCompleted)
        .map((item) => _deviceSelectionStablePrefix(item.file))
        .toSet();
    if (settledPrefixes.isEmpty ||
        !_selectedIds.any(
          (id) => settledPrefixes.any((prefix) => id.startsWith(prefix)),
        )) {
      return;
    }
    setState(
      () => _selectedIds.removeWhere(
        (id) => settledPrefixes.any((prefix) => id.startsWith(prefix)),
      ),
    );
    if (_selectedIds.isEmpty) _exitBatchMode();
  }

  Future<void> _pauseWifiBatch() async {
    if (_wifiBatchActionInFlight) return;
    final controller = ref.read(recordingCardControllerProvider);
    setState(() => _wifiBatchActionInFlight = true);
    try {
      await controller.pauseWifiBatch();
    } finally {
      if (mounted) setState(() => _wifiBatchActionInFlight = false);
    }
    if (!mounted) return;
    final batch = controller.state.wifiBatch;
    if (batch?.state == RecordingCardWifiBatchState.paused ||
        batch?.state == RecordingCardWifiBatchState.failed ||
        batch?.state == RecordingCardWifiBatchState.cancelled ||
        batch?.state == RecordingCardWifiBatchState.completed) {
      _presentWifiBatchSettlement(batch!);
      return;
    }
    showV3Snack(context, '同步任务暂未暂停，请检查连接后重试');
  }

  Future<void> _resumeWifiBatch() async {
    final controller = ref.read(recordingCardControllerProvider);
    final batch = controller.state.wifiBatch;
    if (batch == null) return;
    if (recordingCardWifiBatchIsBluetoothResumeFailure(batch)) {
      if (_wifiBatchActionInFlight) return;
      setState(() => _wifiBatchActionInFlight = true);
      RecordingCardResult<RecordingCardWifiBatchSnapshot> result;
      try {
        result = await controller.resumeWifiBatch();
      } finally {
        if (mounted) setState(() => _wifiBatchActionInFlight = false);
      }
      if (mounted && !result.ok) {
        showV3Snack(context, '蓝牙续传暂未恢复，请检查录音卡连接后重试');
      }
      return;
    }
    await _openQuickWifiTransfer(
      existingBatch: batch,
      existingAction: RecordingCardQuickWifiExistingAction.resume,
    );
  }

  Future<void> _cancelWifiBatch() async {
    if (_wifiBatchActionInFlight) return;
    final controller = ref.read(recordingCardControllerProvider);
    setState(() => _wifiBatchActionInFlight = true);
    try {
      await controller.cancelWifiBatch();
    } finally {
      if (mounted) setState(() => _wifiBatchActionInFlight = false);
    }
    if (!mounted) return;
    final batch = controller.state.wifiBatch;
    if (batch?.state == RecordingCardWifiBatchState.cancelled ||
        batch?.state == RecordingCardWifiBatchState.completed) {
      _presentWifiBatchSettlement(batch!);
      return;
    }
    showV3Snack(context, '同步任务暂未结束，请检查连接后重试');
  }

  Future<V3WifiTransferFlowResult?> _startQueuedWifiBatch() async {
    final controller = ref.read(recordingCardControllerProvider);
    final batch = controller.state.wifiBatch;
    if (batch == null) return null;
    return _openQuickWifiTransfer(
      existingBatch: batch,
      existingAction: RecordingCardQuickWifiExistingAction.start,
    );
  }

  Future<void> _retryFailedWifiBatch() async {
    final controller = ref.read(recordingCardControllerProvider);
    final batch = controller.state.wifiBatch;
    if (batch == null) return;
    await _openQuickWifiTransfer(
      existingBatch: batch,
      existingAction: RecordingCardQuickWifiExistingAction.retryFailed,
    );
  }

  Future<void> _dismissWifiBatch() async {
    if (_wifiBatchActionInFlight) return;
    final controller = ref.read(recordingCardControllerProvider);
    final batch = controller.state.wifiBatch;
    if (batch == null) return;
    _removeCompletedWifiSelection(batch);
    final dismissed = await _requestWifiBatchDismiss(controller);
    if (!mounted || dismissed) return;
    showV3Snack(context, '同步状态暂未清理，请稍后重试');
  }

  Future<bool> _requestWifiBatchDismiss(
    RecordingCardController controller,
  ) async {
    if (_wifiBatchActionInFlight) return false;
    setState(() => _wifiBatchActionInFlight = true);
    try {
      return await controller.dismissWifiBatch();
    } finally {
      if (mounted) setState(() => _wifiBatchActionInFlight = false);
    }
  }

  Future<void> _togglePlayback(RecordingLibraryItem item) async {
    await _playbackController.toggle(item);
    final error = _playbackController.state.lastErrorCode;
    if (mounted && error != null) {
      showV3Snack(context, recordingLibraryFailureMessage(error, action: '播放'));
    }
  }

  void _handleRowTap(
    RecordingLibraryUiController controller,
    RecordingLibraryItem item,
  ) {
    if (controller.batchMode) {
      if (widget.wifiTransferSelection) return;
      final selectionId = _localSelectionId(item);
      setState(() {
        if (!_selectedIds.add(selectionId)) {
          _selectedIds.remove(selectionId);
        }
      });
      return;
    }
    unawaited(_togglePlayback(item));
  }

  Future<void> _openItemMenu(
    RecordingLibraryItem item,
    BuildContext anchorContext,
  ) async {
    final receipt = _durableTranscriptionReceiptFor(item);
    final resolvedRemoteRecordingId =
        receipt?.remoteRecordingId ?? item.remoteRecordingId;
    final action = await _showAnchoredMenu<_RecordingItemAction>(
      anchorContext,
      items: [
        _recordingMenuItem(
          _RecordingItemAction.details,
          '文件详情',
          Icons.info_outline_rounded,
          key: ValueKey('recording-file-details-${item.recordingId}'),
        ),
        if (!isMonologueRecordingHistoryItem(item))
          _recordingMenuItem(
            _RecordingItemAction.transcription,
            resolvedRemoteRecordingId == null ? '上传并转写' : '查看转写',
            resolvedRemoteRecordingId == null
                ? Icons.cloud_upload_outlined
                : Icons.subject_outlined,
          ),
        _recordingMenuItem(
          _RecordingItemAction.rename,
          '重命名',
          Icons.drive_file_rename_outline,
        ),
        _recordingMenuItem(
          _RecordingItemAction.openExternal,
          '用其他应用打开',
          Icons.open_in_new_outlined,
          enabled: item.localFileState == RecordingLocalFileState.ready,
        ),
        _recordingMenuItem(
          _RecordingItemAction.delete,
          '删除本地录音文件',
          Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _RecordingItemAction.details:
        unawaited(_showRecordingFileDetails(item, null));
      case _RecordingItemAction.transcription:
        if (resolvedRemoteRecordingId == null) {
          unawaited(_uploadForTranscription(item));
        } else {
          _openTranscription(
            resolvedRemoteRecordingId,
            source: _fileSourceForLibraryItem(item),
          );
        }
      case _RecordingItemAction.rename:
        unawaited(_showRenameDialog(item));
      case _RecordingItemAction.openExternal:
        unawaited(_openWithOtherApp(item));
      case _RecordingItemAction.delete:
        unawaited(_confirmDeleteLocalRecording(item));
    }
  }

  Future<T?> _showAnchoredMenu<T>(
    BuildContext anchorContext, {
    required List<PopupMenuEntry<T>> items,
  }) {
    final button = anchorContext.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final colors = HuahuoV3Theme.tokensOf(context);
    return showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      color: colors.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: colors.ink.withValues(alpha: .16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.line),
      ),
      items: items,
    );
  }

  Future<void> _openDeviceFileMenu(
    RecordingCardScannedFile file,
    BuildContext anchorContext, {
    required bool showDetails,
    required bool wifiEnabled,
    required bool bluetoothEnabled,
    required bool deleteEnabled,
  }) async {
    final action = await _showAnchoredMenu<_DeviceFileAction>(
      anchorContext,
      items: <PopupMenuEntry<_DeviceFileAction>>[
        if (showDetails)
          _recordingMenuItem(
            _DeviceFileAction.details,
            '文件详情',
            Icons.info_outline_rounded,
            key: ValueKey('recording-file-details-${file.localFileKey}'),
          ),
        _recordingMenuItem(
          _DeviceFileAction.wifi,
          'Wi-Fi 传输',
          Icons.wifi_rounded,
          key: ValueKey('recording-card-wifi-${file.localFileKey}'),
          enabled: wifiEnabled,
        ),
        _recordingMenuItem(
          _DeviceFileAction.bluetooth,
          '蓝牙传输',
          Icons.bluetooth_rounded,
          key: ValueKey('recording-card-bluetooth-${file.localFileKey}'),
          enabled: bluetoothEnabled,
        ),
        _recordingMenuItem(
          _DeviceFileAction.delete,
          '删除录音卡原文件',
          Icons.delete_outline_rounded,
          key: ValueKey('recording-card-delete-${file.localFileKey}'),
          enabled: deleteEnabled,
          destructive: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _DeviceFileAction.details:
        await _showRecordingFileDetails(null, file);
      case _DeviceFileAction.wifi:
        await _queueSingleWifiFile(file);
      case _DeviceFileAction.bluetooth:
        await _downloadDeviceFile(file);
      case _DeviceFileAction.delete:
        await _confirmDeleteDeviceFiles(
          <RecordingCardScannedFile>[file],
          retainedLocalCopyCount:
              file.syncState == RecordingCardFileSyncState.synced ? 1 : 0,
        );
    }
  }

  Future<void> _queueSingleWifiFile(RecordingCardScannedFile file) async {
    await _openQuickWifiTransfer(
      selectedFiles: <RecordingCardScannedFile>[file],
    );
  }

  Future<void> _showRecordingFileDetails(
    RecordingLibraryItem? item,
    RecordingCardScannedFile? deviceFile,
  ) {
    final recordedAt = deviceFile?.recordedAt ?? item?.createdAt;
    final sizeBytes = item?.sizeBytes ?? deviceFile?.sizeBytes;
    final durationSeconds = item != null && item.durationSeconds > 0
        ? item.durationSeconds
        : deviceFile?.durationSeconds;
    final format = item == null
        ? _recordingCardFormatLabel(deviceFile?.format)
        : _recordingLibraryFormatLabel(
            resolveRecordingLibraryExportFormat(item),
          );
    final hasDeviceTranscriptionReceipt =
        deviceFile != null &&
        (_presentationFor(deviceFile)?.transcribed ?? false);
    final transcription = hasDeviceTranscriptionReceipt
        ? _RecordingTranscriptionState.transcribed
        : _transcriptionStateFor(item);
    final lastSyncedAt = deviceFile == null
        ? null
        : _lastSyncedAtFor(deviceFile);
    return showV3GlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => V3SheetScaffold(
        key: const ValueKey('recording-file-details-sheet'),
        title: '文件详情',
        showClose: true,
        maxHeightFactor: .62,
        child: Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: <Widget>[
              _RecordingFileDetailRow(
                label: '录制时间',
                value: _displayFullDateTime(recordedAt),
              ),
              _RecordingFileDetailRow(
                label: '来源',
                value: _recordingSourceLabel(item),
              ),
              _RecordingFileDetailRow(
                label: '文件大小',
                value: sizeBytes == null || sizeBytes <= 0
                    ? '--'
                    : _formatBytes(sizeBytes),
              ),
              _RecordingFileDetailRow(
                label: '录音时长',
                value: durationSeconds == null || durationSeconds <= 0
                    ? '--'
                    : _displayDurationSeconds(durationSeconds),
              ),
              if (lastSyncedAt != null)
                _RecordingFileDetailRow(
                  label: '最近同步',
                  value: _displayFullDateTime(lastSyncedAt),
                ),
              _RecordingFileDetailRow(label: '文件类型', value: format),
              _RecordingFileDetailRow(
                label: '转写状态',
                value: transcription.label,
                showDivider: false,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRenameDialog(RecordingLibraryItem item) async {
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _LibraryTextDialog(
        title: '重命名录音',
        hintText: '录音名称',
        initialValue: item.displayName,
        maxLength: 80,
      ),
    );
    if (name == null) return;
    await ref
        .read(recordingLibraryControllerProvider)
        .rename(recordingId: item.recordingId, displayName: name);
    if (!mounted) return;
    final error = ref
        .read(recordingLibraryControllerProvider)
        .state
        .lastErrorCode;
    showV3Snack(
      context,
      error == null
          ? '已重命名'
          : recordingLibraryFailureMessage(error, action: '重命名'),
    );
  }

  Future<void> _openWithOtherApp(RecordingLibraryItem item) async {
    final opened = await ref
        .read(recordingLibraryControllerProvider)
        .openWithOtherApp(item.recordingId);
    if (!mounted) return;
    final error = ref
        .read(recordingLibraryControllerProvider)
        .state
        .lastErrorCode;
    if (error != null || opened == null) {
      showV3Snack(context, recordingLibraryFailureMessage(error, action: '打开'));
    }
  }

  Future<void> _uploadForTranscription(RecordingLibraryItem item) async {
    final presentationGeneration = ++_uploadPresentationGeneration;
    setState(() {
      _uploadingRecordingId = item.recordingId;
      _uploadingRecordingTitle = item.displayName;
    });
    final upload = ref.read(recordingUploadControllerProvider);
    final source = _fileSourceForLibraryItem(item);
    final jobId = recordingFileJobId(item);
    final uploading = upload.uploadLocalRecording(
      item: item,
      sourceScene: 'raw_material',
      fileSource: source,
      title: item.displayName,
    );
    if (mounted) {
      context.push(
        AppRoutePaths.transcriptionJob(jobId, source: source.routeValue),
      );
    }
    unawaited(() async {
      await uploading;
      if (!mounted || presentationGeneration != _uploadPresentationGeneration) {
        return;
      }
      setState(() {
        _uploadingRecordingId = null;
        _uploadingRecordingTitle = null;
      });
      unawaited(ref.read(recordingLibraryControllerProvider).load());
    }());
  }

  void _openTranscription(
    String recordingId, {
    RecordingFileSource source = RecordingFileSource.recording,
  }) {
    context.push(
      AppRoutePaths.transcriptionDetail(recordingId, source: source.routeValue),
    );
  }

  Future<void> _confirmDeleteLocalRecording(RecordingLibraryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '删除本地录音？',
        message: '将永久删除手机本地录音文件。录音卡中的原文件不会被删除。',
        primaryLabel: '删除本地',
        onPrimary: () => Navigator.pop(dialogContext, true),
        onCancel: () => Navigator.pop(dialogContext, false),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _deletePermanently(<RecordingLibraryItem>[item]);
  }

  Future<void> _deletePermanently(List<RecordingLibraryItem> items) async {
    final activeId = _playbackController.state.recordingId;
    if (activeId != null && items.any((item) => item.recordingId == activeId)) {
      await _playbackController.release();
    }
    var failures = 0;
    var deletedDeviceCopy = false;
    final deletedSelectionIds = <String>[];
    final controller = ref.read(recordingLibraryControllerProvider);
    for (final item in items) {
      await controller.deletePermanently(item.recordingId);
      if (controller.state.lastErrorCode != null) {
        failures += 1;
      } else {
        deletedSelectionIds.add(_localSelectionId(item));
        if (item.source == RecordingLibrarySource.device) {
          deletedDeviceCopy = true;
        }
      }
    }
    if (deletedDeviceCopy) {
      await ref.read(recordingCardControllerProvider).refreshLocalSyncState();
    }
    if (!mounted) return;
    final batchMode = _recordingUiController.batchMode;
    if (batchMode && failures == 0) {
      _exitBatchMode();
    } else if (deletedSelectionIds.isNotEmpty) {
      setState(() => _selectedIds.removeAll(deletedSelectionIds));
    }
    _showBatchResult('已永久删除', items.length, failures);
  }

  void _openBatchActions() {
    final selectedItems = _selectedItems();
    if (selectedItems.isEmpty) {
      showV3Snack(context, '请先选择录音');
      return;
    }
    showV3GlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * .78,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    '已选择 ${selectedItems.length} 条录音',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                const Divider(height: 1),
                _SheetAction(
                  icon: Icons.star_outline,
                  label: '全部收藏',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setSelectedFavorite(selectedItems, true);
                  },
                ),
                _SheetAction(
                  icon: Icons.star_border,
                  label: '取消收藏',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setSelectedFavorite(selectedItems, false);
                  },
                ),
                _SheetAction(
                  icon: Icons.sell_outlined,
                  label: '设置标签',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_showBatchTagDialog(selectedItems));
                  },
                ),
                _SheetAction(
                  icon: Icons.delete_forever_outlined,
                  label: '永久删除',
                  destructive: true,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_confirmDeleteSelected(selectedItems));
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<RecordingLibraryItem> _selectedItems() {
    final selectedIds = Set<String>.from(_selectedIds);
    return ref
        .read(recordingLibraryControllerProvider)
        .state
        .items
        .where((item) => selectedIds.contains(_localSelectionId(item)))
        .toList(growable: false);
  }

  Future<void> _transcribeCurrentSelection() async {
    if (_transcriptionActionInFlight) return;
    final currentSelection = _selectedItems();
    if (currentSelection.isEmpty) return;
    if (currentSelection.every(isMonologueRecordingHistoryItem)) {
      showV3Snack(context, '独白录音仅用于回听，不需要再次转写');
      return;
    }
    final batchController = ref.read(
      recordingBatchTranscriptionControllerProvider,
    );
    final candidateFactory = ref.read(
      recordingTranscriptionCandidateFactoryProvider,
    );
    setState(() => _transcriptionActionInFlight = true);
    try {
      final candidates = List<RecordingTranscriptionCandidate>.unmodifiable(
        currentSelection.map(candidateFactory.fromLibraryItem),
      );
      final preview = await batchController.previewSelection(candidates);
      if (!mounted) return;
      if (preview.counts.total >= 2) {
        final confirmed = await _confirmBatchTranscription(preview);
        if (!mounted || confirmed != true) return;
      }
      final dispatch = await batchController.startPreview(preview);
      if (!mounted) return;
      switch (dispatch.kind) {
        case RecordingTranscriptionDispatchKind.disabled:
          return;
        case RecordingTranscriptionDispatchKind.single:
          final item = currentSelection.single;
          final preflight = dispatch.single!;
          if (preflight.classification ==
              RecordingTranscriptionClassification.unavailable) {
            showV3Snack(context, '所选录音文件不可用，请检查本地文件后重试');
            return;
          }
          _exitBatchMode();
          if (preflight.classification ==
              RecordingTranscriptionClassification.eligible) {
            await _uploadForTranscription(item);
            return;
          }
          final candidate = preflight.candidate;
          final candidateRemoteId = candidate.remoteRecordingId?.trim();
          final receiptRemoteId = preflight.receipt?.remoteRecordingId.trim();
          final remoteId = candidateRemoteId?.isNotEmpty == true
              ? candidateRemoteId
              : receiptRemoteId;
          if (remoteId != null && remoteId.isNotEmpty) {
            _openTranscription(
              remoteId,
              source: _fileSourceForLibraryItem(item),
            );
          } else {
            context.push(
              AppRoutePaths.transcriptionJob(
                candidate.jobId,
                source: _fileSourceForLibraryItem(item).routeValue,
              ),
            );
          }
          return;
        case RecordingTranscriptionDispatchKind.batch:
          final batch = dispatch.batch;
          if (batch == null) return;
          _exitBatchMode();
          context.push(AppRoutePaths.transcriptionBatch(batch.batchId));
          return;
      }
    } on RecordingBatchTranscriptionException catch (_) {
      if (mounted) showV3Snack(context, '转写任务启动失败，请重试');
    } finally {
      if (mounted) setState(() => _transcriptionActionInFlight = false);
    }
  }

  Future<bool?> _confirmBatchTranscription(
    RecordingTranscriptionSelectionPreview preview,
  ) {
    final counts = preview.counts;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialogFrame(
        title: '确认批量转写？',
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 430),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('将按当前选择创建一组后台任务，返回后仍会继续处理。'),
                const SizedBox(height: 14),
                _TranscriptionPreviewSummaryRow(
                  label: '共选择',
                  value: counts.total,
                ),
                _TranscriptionPreviewSummaryRow(
                  label: '将开始',
                  value: counts.willSubmit,
                ),
                _TranscriptionPreviewSummaryRow(
                  label: '正在处理 / 继续观察',
                  value: counts.willObserve,
                ),
                _TranscriptionPreviewSummaryRow(
                  label: '已转写，跳过',
                  value: counts.willSkip,
                ),
                _TranscriptionPreviewSummaryRow(
                  label: '不可用 / 需要处理',
                  value: counts.needsAttention,
                ),
                const SizedBox(height: 14),
                for (final item in preview.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            item.candidate.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _transcriptionPreviewClassificationLabel(
                            item.classification,
                          ),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey('recording-batch-transcribe-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('recording-batch-transcribe-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('开始转写'),
          ),
        ],
      ),
    );
  }

  void _setSelectedFavorite(List<RecordingLibraryItem> items, bool isFavorite) {
    var failures = 0;
    final controller = ref.read(recordingLibraryControllerProvider);
    for (final item in items) {
      controller.setFavorite(
        recordingId: item.recordingId,
        isFavorite: isFavorite,
      );
      if (controller.state.lastErrorCode != null) failures += 1;
    }
    _clearSelection();
    _showBatchResult(isFavorite ? '已收藏' : '已取消收藏', items.length, failures);
  }

  Future<void> _showBatchTagDialog(List<RecordingLibraryItem> items) async {
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _LibraryTextDialog(
        title: '设置批量标签',
        hintText: '用逗号分隔标签',
        maxLength: 120,
      ),
    );
    if (value == null) return;
    var failures = 0;
    final tagIds = _parseTags(value);
    final controller = ref.read(recordingLibraryControllerProvider);
    for (final item in items) {
      controller.updateTags(recordingId: item.recordingId, tagIds: tagIds);
      if (controller.state.lastErrorCode != null) failures += 1;
    }
    _clearSelection();
    _showBatchResult('已更新标签', items.length, failures);
  }

  Future<void> _confirmDeleteSelected(List<RecordingLibraryItem> items) async {
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialogFrame(
        title: '永久删除录音？',
        content: Text('将永久删除 ${items.length} 条录音及本地音频，无法恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _deletePermanently(items);
  }

  void _clearSelection() {
    if (!mounted || _selectedIds.isEmpty) return;
    setState(_selectedIds.clear);
  }

  void _exitBatchMode() {
    _clearSelection();
    final callback = widget.onExitBatchMode;
    if (callback != null) {
      callback();
      return;
    }
    _recordingUiController.setBatchMode(false);
  }

  void _showBatchResult(String action, int total, int failures) {
    if (!mounted) return;
    final succeeded = total - failures;
    final message = failures == 0
        ? '$action $total 条录音'
        : '$action $succeeded 条，$failures 条失败';
    showV3Snack(context, message);
  }

  void _onPlaybackChanged() {
    final nextRecordingId = _playbackController.state.recordingId;
    if (_renderedPlaybackRecordingId == nextRecordingId) return;
    _renderedPlaybackRecordingId = nextRecordingId;
    if (mounted) setState(() {});
  }
}

@immutable
final class _RecordingProjectionSnapshot {
  const _RecordingProjectionSnapshot({
    required this.deviceFiles,
    required this.rows,
  });

  final List<RecordingCardScannedFile> deviceFiles;
  final List<_MergedRecordingRow> rows;
}

@immutable
final class _MergedRecordingRow {
  const _MergedRecordingRow({
    this.localItem,
    this.deviceFile,
    this.cardPresentation,
  }) : assert(localItem != null || deviceFile != null);

  final RecordingLibraryItem? localItem;
  final RecordingCardScannedFile? deviceFile;
  final RecordingCardFilePresentation? cardPresentation;

  bool get hasVerifiedLocalProjection {
    final file = deviceFile;
    if (file == null || file.syncState != RecordingCardFileSyncState.synced) {
      return false;
    }
    final localFileId = file.localFileId?.trim();
    final appPrivateUri = file.appPrivateUri?.trim();
    return localFileId != null &&
        localFileId.isNotEmpty &&
        appPrivateUri != null &&
        appPrivateUri.isNotEmpty;
  }

  bool get isDeviceOnly =>
      localItem == null && deviceFile != null && !hasVerifiedLocalProjection;
  bool get isSynced =>
      hasVerifiedLocalProjection ||
      (deviceFile == null &&
          localItem?.source == RecordingLibrarySource.device &&
          localItem?.localFileState == RecordingLocalFileState.ready &&
          isSafeAppPrivateUri(localItem?.appPrivateUri ?? ''));

  String get availabilityLabel {
    if (cardPresentation != null) return cardPresentation!.status.label;
    if (isSynced) return '已同步';
    final file = deviceFile;
    if (localItem == null && file != null) {
      return switch (file.syncState) {
        RecordingCardFileSyncState.downloading => '同步中',
        RecordingCardFileSyncState.localMissing => '本地文件缺失',
        RecordingCardFileSyncState.failed => '同步失败',
        _ => '未同步',
      };
    }
    return '本地文件';
  }

  int get sortGroup => isDeviceOnly ? 0 : (isSynced ? 2 : 1);

  DateTime? get recordedAt => deviceFile?.recordedAt ?? localItem?.createdAt;

  String get title => deviceFile?.deviceFilename ?? localItem!.displayName;

  String get selectionId => deviceFile != null
      ? _deviceSelectionId(deviceFile!)
      : _localSelectionId(localItem!);
}

String _deviceSelectionId(RecordingCardScannedFile file) =>
    'device:${file.localFileKey}:${file.deviceFileId}:${file.deviceFilename}:'
    '${file.sizeBytes ?? -1}:'
    '${file.recordedAt?.toUtc().toIso8601String() ?? ''}:'
    '${file.contentHash ?? ''}';

String _deviceSelectionStablePrefix(RecordingCardScannedFile file) =>
    'device:${file.localFileKey}:${file.deviceFileId}:';

String? _recordingCardSelectionOwner(RecordingCardDeviceState device) {
  if (!device.isOperationallyConnected) return null;
  final serial = device.serialNumber?.trim();
  if (serial != null && serial.isNotEmpty) return 'serial:$serial';
  final fingerprint = device.safeDeviceFingerprint?.trim();
  return fingerprint == null || fingerprint.isEmpty
      ? null
      : 'fingerprint:$fingerprint';
}

String _localSelectionId(RecordingLibraryItem item) =>
    'local:${item.recordingId}';

String? _normalizedRecordingHash(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

class _LibraryTextDialog extends StatefulWidget {
  const _LibraryTextDialog({
    required this.title,
    required this.hintText,
    required this.maxLength,
    this.initialValue = '',
  });

  final String title;
  final String hintText;
  final String initialValue;
  final int maxLength;

  @override
  State<_LibraryTextDialog> createState() => _LibraryTextDialogState();
}

class _LibraryTextDialogState extends State<_LibraryTextDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return V3GlassDialogFrame(
      title: widget.title,
      content: TextField(
        controller: _controller,
        contextMenuBuilder: V3TextEditing.buildContextMenu,
        autofocus: true,
        maxLength: widget.maxLength,
        decoration: InputDecoration(hintText: widget.hintText),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<bool> importV3LocalRecordingFiles(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = ref.read(recordingLibraryControllerProvider);
  final before = controller.state.items.length;
  await controller.importFromPicker();
  if (!context.mounted) return false;
  final state = controller.state;
  if (state.lastErrorCode != null) {
    showV3Snack(
      context,
      recordingLibraryFailureMessage(state.lastErrorCode, action: '导入'),
    );
    return false;
  }
  final added = state.items.length - before;
  showV3Snack(context, added > 0 ? '已导入 $added 条录音' : '未选择可导入的音频');
  return added > 0;
}

void toggleV3RecordingLibraryBatchMode(BuildContext context, WidgetRef ref) {
  final controller = ref.read(recordingLibraryUiControllerProvider);
  final next = !controller.batchMode;
  controller.setBatchMode(next);
  showV3Snack(context, next ? '已进入批量管理' : '已退出批量管理');
}

class _RecordingBatchHeader extends StatelessWidget {
  const _RecordingBatchHeader({
    required this.deviceFiles,
    required this.batchMode,
    required this.selectedCount,
    required this.totalCount,
    required this.onManage,
    required this.onSelectAll,
    required this.onClear,
    required this.onExit,
  });

  final bool deviceFiles;
  final bool batchMode;
  final int selectedCount;
  final int totalCount;
  final VoidCallback onManage;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final compactButtonStyle = TextButton.styleFrom(
      minimumSize: const Size(42, 40),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Row(
      children: [
        Expanded(
          child: Text(
            batchMode
                ? '已选择 $selectedCount 条'
                : deviceFiles
                ? '卡内录音（$totalCount）'
                : '录音文件',
            key: const ValueKey('recording-library-section-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
        ),
        if (!batchMode)
          TextButton(
            key: ValueKey(
              deviceFiles
                  ? 'recording-card-files-enter-batch'
                  : 'recording-card-toggle-batch',
            ),
            onPressed: onManage,
            style: compactButtonStyle,
            child: const Text('批量管理'),
          )
        else ...[
          TextButton(
            key: const ValueKey('recording-library-batch-select-all'),
            onPressed: totalCount == 0 ? null : onSelectAll,
            style: compactButtonStyle,
            child: const Text('全选'),
          ),
          TextButton(
            key: const ValueKey('recording-library-batch-clear'),
            onPressed: selectedCount == 0 ? null : onClear,
            style: compactButtonStyle,
            child: const Text('清除'),
          ),
          TextButton(
            key: const ValueKey('recording-library-batch-exit'),
            onPressed: onExit,
            style: compactButtonStyle,
            child: Text('退出', style: TextStyle(color: colors.muted)),
          ),
        ],
      ],
    );
  }
}

class _TranscriptionPreviewSummaryRow extends StatelessWidget {
  const _TranscriptionPreviewSummaryRow({
    required this.label,
    required this.value,
  });

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: colors.muted)),
          ),
          Text('$value 条', style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

bool _startsRecordingDateGroup(List<_MergedRecordingRow> rows, int index) {
  if (index == 0) return true;
  return _recordingDateGroupKey(rows[index - 1].recordedAt) !=
      _recordingDateGroupKey(rows[index].recordedAt);
}

String _recordingDateGroupKey(DateTime? value) {
  if (value == null) return 'unknown';
  final local = value.toLocal();
  return '${local.year}-${local.month}-${local.day}';
}

String _recordingDateGroupLabel(DateTime? value) {
  if (value == null) return '时间未知';
  final local = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  if (day == today) return '今天';
  if (day == today.subtract(const Duration(days: 1))) return '昨天';
  return '${local.year}年${local.month}月${local.day}日';
}

class _RecordingDateGroupHeader extends StatelessWidget {
  const _RecordingDateGroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 7),
      child: Text(
        label,
        style: TextStyle(
          color: colors.muted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _RecordingLibraryRow extends StatelessWidget {
  const _RecordingLibraryRow({
    required this.title,
    required this.recordedAt,
    required this.durationSeconds,
    required this.deviceMetadata,
    required this.sizeBytes,
    required this.deviceDurationSeconds,
    required this.lastSyncedAt,
    required this.lastSyncedKey,
    required this.statusLabel,
    required this.transcriptionLabel,
    required this.transcribedKey,
    required this.rowKey,
    required this.statusKey,
    required this.cancelKey,
    required this.progressLabelKey,
    required this.busy,
    required this.progress,
    required this.cancelling,
    required this.batchMode,
    required this.selected,
    required this.isPlaying,
    required this.showDivider,
    required this.leadingKey,
    required this.moreKey,
    required this.onTap,
    required this.onCancelTransfer,
    required this.onMore,
    super.key,
  });

  final String title;
  final DateTime? recordedAt;
  final int? durationSeconds;
  final bool deviceMetadata;
  final int? sizeBytes;
  final int? deviceDurationSeconds;
  final DateTime? lastSyncedAt;
  final Key? lastSyncedKey;
  final String statusLabel;
  final String? transcriptionLabel;
  final Key? transcribedKey;
  final Key? rowKey;
  final Key statusKey;
  final Key? cancelKey;
  final Key? progressLabelKey;
  final bool busy;
  final RecordingCardTransferProgress? progress;
  final bool cancelling;
  final bool batchMode;
  final bool selected;
  final bool isPlaying;
  final bool showDivider;
  final Key leadingKey;
  final Key moreKey;
  final VoidCallback? onTap;
  final VoidCallback? onCancelTransfer;
  final ValueChanged<BuildContext> onMore;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final stateColor = switch (statusLabel) {
      '同步失败' => colors.danger,
      '同步中' => colors.primary,
      '已同步' => colors.success,
      _ => colors.muted,
    };
    final leadingActionLabel = batchMode
        ? selected
              ? '取消选择'
              : '选择录音'
        : isPlaying
        ? '暂停播放'
        : onTap == null
        ? '录音文件'
        : '播放录音';
    return InkWell(
      key: rowKey,
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: deviceMetadata ? 88 : 64),
        decoration: showDivider
            ? BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.line)),
              )
            : null,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Tooltip(
              message: leadingActionLabel,
              child: Semantics(
                label: leadingActionLabel,
                button: true,
                enabled: onTap != null,
                child: V3RecordingLeadingControl(
                  key: leadingKey,
                  batchMode: batchMode,
                  selected: selected,
                  icon: busy || progress != null
                      ? Icons.downloading_rounded
                      : isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  enabled: onTap != null,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 6,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        <String>[
                          _displayManagementDateTime(recordedAt),
                          if (deviceMetadata && sizeBytes != null)
                            _formatBytes(sizeBytes!),
                          if (deviceMetadata &&
                              deviceDurationSeconds != null &&
                              deviceDurationSeconds! > 0)
                            _displayDurationSeconds(deviceDurationSeconds!),
                        ].join(' · '),
                        style: TextStyle(color: colors.muted, fontSize: 11.5),
                      ),
                      if (transcriptionLabel != null)
                        Text(
                          transcriptionLabel!,
                          key: transcribedKey,
                          style: TextStyle(
                            color: colors.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      Text(
                        statusLabel,
                        key: statusKey,
                        style: TextStyle(
                          color: stateColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  if (deviceMetadata && lastSyncedAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '最近同步 ${_displayManagementDateTime(lastSyncedAt)}',
                        key: lastSyncedKey,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.muted, fontSize: 11),
                      ),
                    ),
                  if (progress case final transferProgress?)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(
                            value: transferProgress.fraction,
                            minHeight: 2,
                            borderRadius: BorderRadius.circular(1),
                            color: colors.primary,
                            backgroundColor: colors.line,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _transferProgressLabel(transferProgress),
                            key: progressLabelKey,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (!deviceMetadata && durationSeconds != null) ...[
              const SizedBox(width: 6),
              Text(
                _displayDurationSeconds(durationSeconds!),
                style: const TextStyle(fontSize: 12),
              ),
            ],
            if (!batchMode && progress != null)
              IconButton(
                key: cancelKey,
                tooltip: cancelling ? '正在取消传输' : '取消传输',
                onPressed: cancelling ? null : onCancelTransfer,
                icon: cancelling
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.close_rounded, size: 21),
              )
            else if (!batchMode)
              Builder(
                builder: (anchorContext) => IconButton(
                  key: moreKey,
                  onPressed: () => onMore(anchorContext),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_horiz, size: 22),
                ),
              ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

String _displayManagementDateTime(DateTime? value) {
  if (value == null) return '--';
  final local = value.toLocal();
  return '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _displayFullDateTime(DateTime? value) {
  if (value == null) return '--';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _recordingLibraryTitle(_MergedRecordingRow row) {
  final item = row.localItem;
  final raw = item?.source == RecordingLibrarySource.device
      ? row.deviceFile?.deviceFilename ??
            item?.deviceFilename ??
            item!.displayName
      : item?.displayName ?? row.deviceFile!.deviceFilename;
  return raw.replaceFirst(
    RegExp(r'\.(?:mp3|m4a|mp4|wav|opus)$', caseSensitive: false),
    '',
  );
}

String _recordingSourceLabel(RecordingLibraryItem? item) {
  if (item == null || item.source == RecordingLibrarySource.device) {
    return '录音卡';
  }
  if (isMonologueRecordingHistoryItem(item)) return '独白';
  if (isInternalRecordingHistoryItem(item)) return '内录';
  if (isExternalRecordingHistoryItem(item)) return '外录';
  return switch (item.source) {
    RecordingLibrarySource.localImport => '本地导入',
    RecordingLibrarySource.microphone => '麦克风录音',
    RecordingLibrarySource.device => '录音卡',
  };
}

String _recordingLibraryFormatLabel(RecordingLibraryFormat format) {
  return switch (format) {
    RecordingLibraryFormat.mp3 => 'MP3',
    RecordingLibraryFormat.opus => 'Opus',
    RecordingLibraryFormat.m4a => 'M4A',
    RecordingLibraryFormat.wav => 'WAV',
    RecordingLibraryFormat.unknown => '未知',
  };
}

String _recordingCardFormatLabel(RecordingCardFileFormat? format) {
  return switch (format) {
    RecordingCardFileFormat.mp3 => 'MP3',
    RecordingCardFileFormat.opus => 'Opus',
    RecordingCardFileFormat.m4a => 'M4A',
    RecordingCardFileFormat.wav => 'WAV',
    RecordingCardFileFormat.unknown || null => '未知',
  };
}

enum _RecordingTranscriptionState {
  transcribed('已转写'),
  processing('转写中'),
  failed('转写失败'),
  notTranscribed('未转写'),
  unknown('暂无法确认');

  const _RecordingTranscriptionState(this.label);

  final String label;
  String? get badgeLabel => switch (this) {
    transcribed || processing || failed => label,
    _ => null,
  };
}

RecordingCardTransferProgress? _visibleTransferProgress(
  RecordingCardControllerState state,
) {
  final progress = state.snapshot.transferProgress;
  if (!state.operation.isActive ||
      state.operation.kind != RecordingCardOperationKind.bluetoothTransfer ||
      state.activeFileKey != progress?.localFileKey ||
      progress?.transport == RecordingCardTransferTransport.wifi ||
      progress?.phase == RecordingCardTransferPhase.cancelled ||
      progress?.phase == RecordingCardTransferPhase.failed)
    return null;
  return progress;
}

String _transferProgressLabel(RecordingCardTransferProgress progress) {
  final received = _formatBytes(progress.receivedBytes);
  final total = progress.totalBytes;
  final bytesPerSecond = progress.bytesPerSecond;
  final estimatedRemainingSeconds =
      progress.estimatedRemainingSeconds ??
      (total != null && bytesPerSecond != null && bytesPerSecond > 0
          ? ((total - progress.receivedBytes).clamp(0, total) / bytesPerSecond)
                .ceil()
          : null);
  final parts = <String>[
    total == null ? '已接收 $received' : '已接收 $received / ${_formatBytes(total)}',
    if (bytesPerSecond != null && bytesPerSecond > 0)
      '${_formatBytes(bytesPerSecond.round())}/s',
    if (estimatedRemainingSeconds != null)
      '预计剩余 ${_displayTransferEta(estimatedRemainingSeconds)}',
    if (progress.directorySizeMismatch) '设备长度已校准',
  ];
  return parts.join(' · ');
}

String _displayTransferEta(int seconds) {
  if (seconds <= 0) return '即将完成';
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (minutes < 60) {
    return remainingSeconds == 0
        ? '$minutes 分钟'
        : '$minutes 分 $remainingSeconds 秒';
  }
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return remainingMinutes == 0 ? '$hours 小时' : '$hours 小时 $remainingMinutes 分';
}

enum _RecordingItemAction {
  details,
  transcription,
  rename,
  openExternal,
  delete,
}

enum _DeviceFileAction { details, wifi, bluetooth, delete }

PopupMenuItem<T> _recordingMenuItem<T>(
  T value,
  String label,
  IconData icon, {
  Key? key,
  bool enabled = true,
  bool destructive = false,
}) => PopupMenuItem<T>(
  key: key,
  value: value,
  enabled: enabled,
  height: 44,
  padding: const EdgeInsets.symmetric(horizontal: 12),
  child: Builder(
    builder: (context) {
      final colors = HuahuoV3Theme.tokensOf(context);
      final foreground = !enabled
          ? colors.muted
          : destructive
          ? colors.danger
          : colors.text;
      return Row(
        children: [
          Icon(icon, size: 19, color: foreground),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    },
  ),
);

class _RecordingFileDetailRow extends StatelessWidget {
  const _RecordingFileDetailRow({
    required this.label,
    required this.value,
    this.showDivider = true,
  });

  final String label;
  final String value;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: showDivider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.line)),
            )
          : null,
      child: Row(
        children: [
          Text(label, style: TextStyle(color: colors.muted, fontSize: 14)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return ListTile(
      leading: Icon(icon, color: destructive ? colors.danger : null),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: destructive ? colors.danger : colors.ink,
        ),
      ),
      onTap: onTap,
    );
  }
}

String _recordingCardTransferStageLabel(String code) {
  return switch (recordingCardFailureStage(code)) {
    RecordingCardFailureStage.coordination => '任务协调阶段',
    RecordingCardFailureStage.connection => '连接阶段',
    RecordingCardFailureStage.request => '请求阶段',
    RecordingCardFailureStage.transfer => '传输阶段',
    RecordingCardFailureStage.verification => '校验阶段',
    RecordingCardFailureStage.storage => '落盘阶段',
  };
}

const Set<String> _recordingCardWifiDisconnectErrorCodes = <String>{
  'RECORDING_CARD_DISCONNECTED',
  'RECORDING_CARD_WIFI_CONNECTION_TIMEOUT',
  'RECORDING_CARD_WIFI_DISCONNECTED',
  'RECORDING_CARD_WIFI_NETWORK_TIMEOUT',
  'RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE',
  'RECORDING_CARD_WIFI_READ_FAILED',
};

@visibleForTesting
String recordingCardWifiPausedBatchMessage({
  required Iterable<String?> itemErrorCodes,
  String? fallbackErrorCode,
}) {
  final recoveryMessage = recordingCardWifiRecoveryMessage(fallbackErrorCode);
  if (recoveryMessage != null) return recoveryMessage;
  String? errorCode;
  for (final candidate in itemErrorCodes) {
    final normalized = candidate?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      errorCode = normalized;
      break;
    }
  }
  final fallback = fallbackErrorCode?.trim();
  if (errorCode == null && fallback != null && fallback.isNotEmpty) {
    errorCode = fallback;
  }
  if (errorCode == null) {
    return 'Wi-Fi 传输已暂停，可重新连接后继续';
  }
  if (_recordingCardWifiDisconnectErrorCodes.contains(
    errorCode.toUpperCase(),
  )) {
    return 'Wi-Fi 连接已中断，可重新连接后继续';
  }
  return 'Wi-Fi 传输遇到问题，可重新连接后重试';
}

@visibleForTesting
String recordingCardWifiBatchSettlementMessage(
  RecordingCardWifiBatchSnapshot batch, {
  required String prefix,
}) {
  return '$prefix：已同步 ${batch.completedCount} 条，'
      '未同步 ${batch.remainingCount} 条';
}

@visibleForTesting
String recordingLibraryFailureMessage(
  String? errorCode, {
  required String action,
}) {
  final code = errorCode?.trim().toUpperCase() ?? '';
  if (recordingCardFailureStage(code) ==
      RecordingCardFailureStage.coordination) {
    return '录音卡正在处理其他任务，请等待完成后再$action';
  }
  if (code.contains('PERMISSION') || code.contains('DENIED')) {
    return '$action失败，请检查系统权限后重试';
  }
  if (code.contains('NOT_FOUND') ||
      code.contains('MISSING') ||
      code.contains('UNAVAILABLE')) {
    return '$action失败，录音文件不可用';
  }
  if (code.contains('STORAGE') ||
      code.contains('DISK') ||
      code.contains('WRITE')) {
    return '$action失败，请检查存储空间后重试';
  }
  if (code.contains('MIME') ||
      code.contains('FORMAT') ||
      code.contains('UNSUPPORTED')) {
    return '$action失败，暂不支持该音频格式';
  }
  if (code.contains('NETWORK') ||
      code.contains('WIFI') ||
      code.contains('DISCONNECTED') ||
      code.contains('TIMEOUT')) {
    return '$action失败，请检查连接后重试';
  }
  if (code.contains('CANCEL')) return '$action未完成';
  return '$action失败，请稍后重试';
}

RecordingFileSource _fileSourceForLibraryItem(RecordingLibraryItem item) {
  if (item.source == RecordingLibrarySource.device) {
    return RecordingFileSource.recordingCard;
  }
  if (isMonologueRecordingHistoryItem(item)) {
    return RecordingFileSource.monologue;
  }
  if (isInternalRecordingHistoryItem(item)) {
    return RecordingFileSource.internalRecording;
  }
  if (isExternalRecordingHistoryItem(item)) {
    return RecordingFileSource.meeting;
  }
  return RecordingFileSource.localLibrary;
}

String _transcriptionPreviewClassificationLabel(
  RecordingTranscriptionClassification classification,
) {
  return switch (classification) {
    RecordingTranscriptionClassification.eligible => '将开始',
    RecordingTranscriptionClassification.alreadyCompleted ||
    RecordingTranscriptionClassification.existingRemoteCompleted => '已转写',
    RecordingTranscriptionClassification.alreadyProcessing => '正在处理',
    RecordingTranscriptionClassification.awaitingVerification => '等待核验',
    RecordingTranscriptionClassification.retryExisting => '将重试',
    RecordingTranscriptionClassification.unavailable => '不可用',
  };
}

String _formatDuration(Duration duration) {
  final seconds = duration.isNegative ? 0 : duration.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '${two(hours)}:${two(minutes)}:${two(rest)}'
      : '${two(minutes)}:${two(rest)}';
}

String _displayDurationSeconds(int seconds) {
  return seconds > 0 ? _formatDuration(Duration(seconds: seconds)) : '--';
}

String _formatBytes(int bytes) {
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

String _emptyText({
  bool importAbove = false,
  bool recordingCardManagement = false,
  bool recordingCardFiles = false,
}) {
  if (recordingCardManagement) {
    return recordingCardFiles ? '当前录音卡中没有录音文件' : '还没有同步到本地的录音';
  }
  return importAbove ? '还没有录音文件\n可通过上方按钮导入音频文件' : '还没有录音文件';
}

List<String> _parseTags(String value) {
  return value
      .split(',')
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);
}
