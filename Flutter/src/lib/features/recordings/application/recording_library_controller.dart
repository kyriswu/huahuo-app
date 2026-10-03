import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/native/native_file_port.dart';
import '../../../core/storage/file_storage_port.dart';
import '../data/local_recording_repository.dart';
import '../domain/recording_library.dart';

enum RecordingLibraryControllerStatus {
  idle,
  loading,
  importing,
  editing,
  exporting,
  error,
}

final class RecordingLibraryState {
  const RecordingLibraryState({
    required this.status,
    required this.items,
    required this.summary,
    required this.query,
    this.hasVerifiedInventory = false,
    this.emptyState,
    this.lastErrorCode,
    this.preparedExport,
  });

  factory RecordingLibraryState.initial() {
    return const RecordingLibraryState(
      status: RecordingLibraryControllerStatus.idle,
      items: <RecordingLibraryItem>[],
      summary: RecordingLibrarySummary(
        totalCount: 0,
        favoriteCount: 0,
        playableCount: 0,
        recycledCount: 0,
      ),
      query: RecordingLibraryQuery(),
      emptyState: 'noLocalRecordings',
    );
  }

  final RecordingLibraryControllerStatus status;
  final List<RecordingLibraryItem> items;
  final RecordingLibrarySummary summary;
  final RecordingLibraryQuery query;
  final bool hasVerifiedInventory;
  final String? emptyState;
  final String? lastErrorCode;
  final PreparedAudioExport? preparedExport;

  RecordingLibraryState copyWith({
    RecordingLibraryControllerStatus? status,
    List<RecordingLibraryItem>? items,
    RecordingLibrarySummary? summary,
    RecordingLibraryQuery? query,
    bool? hasVerifiedInventory,
    String? emptyState,
    String? lastErrorCode,
    PreparedAudioExport? preparedExport,
    bool clearPreparedExport = false,
    bool clearLastErrorCode = false,
  }) {
    return RecordingLibraryState(
      status: status ?? this.status,
      items: items ?? this.items,
      summary: summary ?? this.summary,
      query: query ?? this.query,
      hasVerifiedInventory: hasVerifiedInventory ?? this.hasVerifiedInventory,
      emptyState: emptyState,
      lastErrorCode: clearLastErrorCode
          ? null
          : lastErrorCode ?? this.lastErrorCode,
      preparedExport: clearPreparedExport
          ? null
          : preparedExport ?? this.preparedExport,
    );
  }
}

final class RecordingLibraryController extends ChangeNotifier {
  RecordingLibraryController({
    required LocalRecordingRepository repository,
    required NativeFilePort nativeFilePort,
  }) : _repository = repository,
       _nativeFilePort = nativeFilePort;

  final LocalRecordingRepository _repository;
  final NativeFilePort _nativeFilePort;
  RecordingLibraryState _state = RecordingLibraryState.initial();
  bool _pickerInFlight = false;

  RecordingLibraryState get state => _state;

  RecordingLibraryItem? findById(String recordingId) =>
      _repository.findById(recordingId);

  Future<void> load() async {
    _state = _state.copyWith(status: RecordingLibraryControllerStatus.loading);
    notifyListeners();
    final restored = _repository.restoreHistoricalRecycledRecordings();
    if (!restored.ok) {
      _fail(
        restored.error ??
            recordingLibraryError('RECORDING_RECYCLED_MIGRATION_FAILED'),
      );
      return;
    }
    final page = await _repository.verifiedList(query: _state.query);
    _state = _state.copyWith(hasVerifiedInventory: true);
    _applyPage(page);
  }

  Future<void> importFromPicker({DateTime? now}) async {
    if (_pickerInFlight ||
        _state.status == RecordingLibraryControllerStatus.importing) {
      return;
    }
    _pickerInFlight = true;
    try {
      final picked = await _nativeFilePort.pickAudioFiles();
      if (picked.cancelled) {
        _reload();
        return;
      }
      if (!picked.ok || picked.value == null || picked.value!.isEmpty) {
        _fail(picked.error ?? recordingLibraryError('RECORDING_PICKER_EMPTY'));
        return;
      }
      _state = _state.copyWith(
        status: RecordingLibraryControllerStatus.importing,
        clearLastErrorCode: true,
      );
      notifyListeners();
      final imported = await _repository.importPickedRecordings(
        picked.value!,
        now: now,
      );
      if (!imported.ok) {
        _reload();
        _fail(
          imported.error ?? recordingLibraryError('RECORDING_IMPORT_FAILED'),
        );
        return;
      }
      _reload();
    } finally {
      _pickerInFlight = false;
    }
  }

  Future<int> importPickedFiles(
    List<PickedAudioFile> picked, {
    DateTime? now,
  }) async =>
      (await importPickedFilesDetailed(picked, now: now)).imported.length;

  /// Admits an already-confirmed system handoff through the same account
  /// scoped private-library path as a picker import. The caller can then use
  /// the returned durable items to begin a separate user-visible workflow.
  Future<LocalRecordingImportBatch> importPickedFilesDetailed(
    List<PickedAudioFile> picked, {
    DateTime? now,
  }) async {
    if (picked.isEmpty) {
      return LocalRecordingImportBatch(
        imported: const <RecordingLibraryItem>[],
        error: recordingLibraryError('RECORDING_PICKER_EMPTY'),
      );
    }
    _state = _state.copyWith(
      status: RecordingLibraryControllerStatus.importing,
      clearLastErrorCode: true,
    );
    notifyListeners();
    final imported = await _repository.importPickedRecordings(picked, now: now);
    if (!imported.ok) {
      _reload();
      _fail(imported.error ?? recordingLibraryError('RECORDING_IMPORT_FAILED'));
      return imported;
    }
    _reload();
    return imported;
  }

  void setSearchText(String value) {
    _state = _state.copyWith(query: _state.query.copyWith(searchText: value));
    _reload();
  }

  void setView(RecordingLibraryView view) {
    _state = _state.copyWith(query: _state.query.copyWith(view: view));
    _reload();
  }

  Future<void> rename({
    required String recordingId,
    required String displayName,
    DateTime? updatedAt,
  }) async {
    _state = _state.copyWith(status: RecordingLibraryControllerStatus.editing);
    notifyListeners();
    final result = await _repository.rename(
      recordingId: recordingId,
      displayName: displayName,
      updatedAt: updatedAt,
    );
    _handle(result);
  }

  void updateTags({
    required String recordingId,
    required List<String> tagIds,
    DateTime? updatedAt,
  }) {
    _handle(
      _repository.updateTags(
        recordingId: recordingId,
        tagIds: tagIds,
        updatedAt: updatedAt,
      ),
    );
  }

  void setFavorite({
    required String recordingId,
    required bool isFavorite,
    DateTime? updatedAt,
  }) {
    _handle(
      _repository.setFavorite(
        recordingId: recordingId,
        isFavorite: isFavorite,
        updatedAt: updatedAt,
      ),
    );
  }

  void moveToTrash({required String recordingId, DateTime? deletedAt}) {
    _handle(
      _repository.moveToTrash(recordingId: recordingId, deletedAt: deletedAt),
    );
  }

  void restoreFromTrash({required String recordingId, DateTime? restoredAt}) {
    _handle(
      _repository.restoreFromTrash(
        recordingId: recordingId,
        restoredAt: restoredAt,
      ),
    );
  }

  Future<void> deletePermanently(String recordingId) async {
    _state = _state.copyWith(status: RecordingLibraryControllerStatus.editing);
    notifyListeners();
    final result = await _repository.deletePermanently(recordingId);
    _handle(result);
  }

  Future<void> prepareExport(String recordingId) async {
    await _prepareExport(recordingId, settleAfterPreparation: true);
  }

  Future<bool?> saveToDevice(String recordingId) {
    return _performPreparedExport(recordingId, openWithOtherApp: false);
  }

  Future<bool?> openWithOtherApp(String recordingId) {
    return _performPreparedExport(recordingId, openWithOtherApp: true);
  }

  Future<bool?> _performPreparedExport(
    String recordingId, {
    required bool openWithOtherApp,
  }) async {
    final prepared = await _prepareExport(
      recordingId,
      settleAfterPreparation: false,
    );
    if (prepared == null) return null;
    final mimeType = prepared.mimeType;
    if (mimeType == null) {
      _fail(recordingLibraryError('RECORDING_EXPORT_FORMAT_UNKNOWN'));
      return null;
    }
    final result = openWithOtherApp
        ? await _nativeFilePort.openPreparedAudioExport(
            opaqueExportRef: prepared.opaqueExportRef,
            displayName: prepared.displayName,
            mimeType: mimeType,
          )
        : await _nativeFilePort.savePreparedAudioExport(
            opaqueExportRef: prepared.opaqueExportRef,
            displayName: prepared.displayName,
            mimeType: mimeType,
          );
    if (result.cancelled) {
      _state = _state.copyWith(
        status: RecordingLibraryControllerStatus.idle,
        preparedExport: prepared,
        clearLastErrorCode: true,
      );
      notifyListeners();
      return false;
    }
    if (!result.ok || result.value == null) {
      _fail(
        result.error ??
            recordingLibraryError(
              openWithOtherApp
                  ? 'RECORDING_OPEN_WITH_APP_FAILED'
                  : 'RECORDING_SAVE_TO_DEVICE_FAILED',
            ),
      );
      return null;
    }
    _state = _state.copyWith(
      status: RecordingLibraryControllerStatus.idle,
      preparedExport: prepared,
      clearLastErrorCode: true,
    );
    notifyListeners();
    return result.value!;
  }

  Future<PreparedAudioExport?> _prepareExport(
    String recordingId, {
    required bool settleAfterPreparation,
  }) async {
    _state = _state.copyWith(
      status: RecordingLibraryControllerStatus.exporting,
      clearPreparedExport: true,
    );
    notifyListeners();
    final result = await _repository.prepareExport(recordingId);
    if (!result.ok || result.value == null) {
      _reload();
      _fail(result.error ?? recordingLibraryError('RECORDING_EXPORT_FAILED'));
      return null;
    }
    _state = _state.copyWith(
      status: settleAfterPreparation
          ? RecordingLibraryControllerStatus.idle
          : RecordingLibraryControllerStatus.exporting,
      preparedExport: result.value,
      clearLastErrorCode: true,
    );
    notifyListeners();
    return result.value;
  }

  void _handle<T>(LocalRecordingResult<T> result) {
    if (!result.ok) {
      _fail(result.error ?? recordingLibraryError('RECORDING_MUTATION_FAILED'));
      return;
    }
    _reload();
  }

  void _reload() {
    final page = _repository.list(query: _state.query);
    _applyPage(page);
  }

  void _applyPage(LocalRecordingPage page) {
    _state = _state.copyWith(
      status: RecordingLibraryControllerStatus.idle,
      items: page.rows,
      summary: page.summary,
      emptyState: page.emptyState,
      clearLastErrorCode: true,
    );
    notifyListeners();
  }

  void _fail(AppFailure failure) {
    _state = _state.copyWith(
      status: RecordingLibraryControllerStatus.error,
      lastErrorCode: failure.code,
      clearPreparedExport: true,
    );
    notifyListeners();
  }
}
