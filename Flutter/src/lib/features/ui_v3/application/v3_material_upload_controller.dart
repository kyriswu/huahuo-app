import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/native/native_file_port.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/data/local_recording_repository.dart';
import '../../recordings/data/recording_api.dart';
import '../../recordings/domain/recording_library.dart';

enum V3MaterialUploadStatus {
  idle,
  loadingRecent,
  ready,
  uploading,
  completed,
  failed,
}

final class V3MaterialUploadState {
  const V3MaterialUploadState({
    required this.status,
    this.recentItems = const <RecordingLibraryItem>[],
    this.selectedItem,
    this.createdRecording,
    this.transcriptionJobId,
    this.lastErrorCode,
  });

  factory V3MaterialUploadState.initial() {
    return const V3MaterialUploadState(status: V3MaterialUploadStatus.idle);
  }

  final V3MaterialUploadStatus status;
  final List<RecordingLibraryItem> recentItems;
  final RecordingLibraryItem? selectedItem;
  final CreateRecordingResponse? createdRecording;
  final String? transcriptionJobId;
  final String? lastErrorCode;

  V3MaterialUploadState copyWith({
    V3MaterialUploadStatus? status,
    List<RecordingLibraryItem>? recentItems,
    RecordingLibraryItem? selectedItem,
    CreateRecordingResponse? createdRecording,
    String? transcriptionJobId,
    String? lastErrorCode,
    bool clearSelectedItem = false,
    bool clearCreatedRecording = false,
    bool clearTranscriptionJobId = false,
    bool clearError = false,
  }) {
    return V3MaterialUploadState(
      status: status ?? this.status,
      recentItems: recentItems ?? this.recentItems,
      selectedItem: clearSelectedItem
          ? null
          : selectedItem ?? this.selectedItem,
      createdRecording: clearCreatedRecording
          ? null
          : createdRecording ?? this.createdRecording,
      transcriptionJobId: clearTranscriptionJobId
          ? null
          : transcriptionJobId ?? this.transcriptionJobId,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    );
  }
}

final class V3MaterialUploadController extends ChangeNotifier {
  V3MaterialUploadController({
    required NativeFilePort nativeFilePort,
    required LocalRecordingRepository repository,
    required RecordingUploadController recordingUploadController,
    this.onDistillationJobReady,
  }) : _nativeFilePort = nativeFilePort,
       _repository = repository,
       _recordingUploadController = recordingUploadController;

  final NativeFilePort _nativeFilePort;
  final Future<bool> Function(String jobId, String title)?
  onDistillationJobReady;
  bool _disposed = false;
  final LocalRecordingRepository _repository;
  final RecordingUploadController _recordingUploadController;
  V3MaterialUploadState _state = V3MaterialUploadState.initial();
  bool _pickerInFlight = false;

  V3MaterialUploadState get state => _state;

  bool beginFreshSession() {
    if (_pickerInFlight ||
        _state.status == V3MaterialUploadStatus.loadingRecent ||
        _state.status == V3MaterialUploadStatus.uploading) {
      return false;
    }
    _state = V3MaterialUploadState(
      status: V3MaterialUploadStatus.idle,
      recentItems: _state.recentItems,
    );
    notifyListeners();
    return true;
  }

  Future<void> loadRecent() async {
    _set(V3MaterialUploadStatus.loadingRecent, clearError: true);
    final page = await _repository.verifiedList();
    _state = _state.copyWith(
      status: _state.selectedItem == null
          ? V3MaterialUploadStatus.idle
          : V3MaterialUploadStatus.ready,
      recentItems: page.rows,
      clearError: true,
    );
    notifyListeners();
  }

  Future<void> selectFromPicker() async {
    if (_pickerInFlight || _state.status == V3MaterialUploadStatus.uploading) {
      return;
    }
    _pickerInFlight = true;
    try {
      final picked = await _nativeFilePort.pickAudioFiles();
      if (!picked.ok || picked.value == null || picked.value!.isEmpty) {
        if (picked.cancelled) {
          _state = _state.copyWith(
            status: _state.selectedItem == null
                ? V3MaterialUploadStatus.idle
                : V3MaterialUploadStatus.ready,
            clearError: true,
          );
          notifyListeners();
          return;
        }
        _fail(picked.error ?? recordingLibraryError('RECORDING_PICKER_EMPTY'));
        return;
      }
      if (picked.value!.length != 1) {
        _state = _state.copyWith(clearSelectedItem: true);
        _fail(recordingLibraryError('RECORDING_IMPORT_SINGLE_REQUIRED'));
        return;
      }
      _state = _state.copyWith(
        status: _state.selectedItem == null
            ? V3MaterialUploadStatus.idle
            : V3MaterialUploadStatus.ready,
        clearCreatedRecording: true,
        clearTranscriptionJobId: true,
        clearError: true,
      );
      notifyListeners();
      final imported = await _repository.importPickedRecordings(picked.value!);
      if (!imported.ok || imported.imported.isEmpty) {
        _fail(
          imported.error ?? recordingLibraryError('RECORDING_IMPORT_FAILED'),
        );
        return;
      }
      final page = await _repository.verifiedList();
      _state = _state.copyWith(
        status: V3MaterialUploadStatus.ready,
        recentItems: page.rows,
        selectedItem: imported.imported.first,
        clearCreatedRecording: true,
        clearTranscriptionJobId: true,
        clearError: true,
      );
      notifyListeners();
    } finally {
      _pickerInFlight = false;
    }
  }

  void selectExisting(RecordingLibraryItem item) {
    if (!_isUploadReady(item)) {
      _fail(recordingLibraryError('RECORDING_UPLOAD_NOT_READY'));
      return;
    }
    _state = _state.copyWith(
      status: V3MaterialUploadStatus.ready,
      selectedItem: item,
      clearCreatedRecording: true,
      clearTranscriptionJobId: true,
      clearError: true,
    );
    notifyListeners();
  }

  Future<void> uploadSelected({bool distillToDigitalTwin = false}) async {
    if (_disposed || _state.status == V3MaterialUploadStatus.uploading) return;
    final selected = _state.selectedItem;
    if (selected == null || !_isUploadReady(selected)) {
      _fail(recordingLibraryError('RECORDING_UPLOAD_NOT_READY'));
      return;
    }
    final jobId = recordingFileJobId(selected);
    _state = _state.copyWith(
      status: V3MaterialUploadStatus.uploading,
      clearTranscriptionJobId: true,
      clearError: true,
    );
    notifyListeners();
    if (distillToDigitalTwin) {
      try {
        if (await onDistillationJobReady?.call(jobId, selected.displayName) !=
            true) {
          throw StateError('DIGITAL_TWIN_QUEUE_SAVE_FAILED');
        }
      } catch (_) {
        if (!_disposed)
          _fail(recordingLibraryError('DIGITAL_TWIN_QUEUE_SAVE_FAILED'));
        return;
      }
    }
    if (_disposed) return;
    _state = _state.copyWith(transcriptionJobId: jobId);
    notifyListeners();
    final created = await _recordingUploadController.uploadLocalRecording(
      item: selected,
      sourceScene: 'raw_material',
      fileSource: RecordingFileSource.audioImport,
    );
    if (_disposed) return;
    if (created == null) {
      _fail(
        AppFailure(
          code:
              _recordingUploadController.state.lastErrorCode ??
              'RECORDING_UPLOAD_FAILED',
          category: AppFailureCategory.api,
          message: 'Recording upload failed',
          userMessageKey: 'recording.upload.failed',
        ),
      );
      return;
    }
    _state = _state.copyWith(
      status: V3MaterialUploadStatus.completed,
      createdRecording: created,
      clearError: true,
    );
    notifyListeners();
  }

  void _set(
    V3MaterialUploadStatus status, {
    bool clearCreatedRecording = false,
    bool clearError = false,
  }) {
    _state = _state.copyWith(
      status: status,
      clearCreatedRecording: clearCreatedRecording,
      clearError: clearError,
    );
    notifyListeners();
  }

  void _fail(AppFailure error) {
    _state = _state.copyWith(
      status: V3MaterialUploadStatus.failed,
      lastErrorCode: error.code,
      clearCreatedRecording: true,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

bool _isUploadReady(RecordingLibraryItem item) {
  return item.status != RecordingLibraryStatus.recycled &&
      item.localFileState == RecordingLocalFileState.ready &&
      item.appPrivateUri != null &&
      item.sizeBytes > 0;
}
