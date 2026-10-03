import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/upload_client.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/ui_v3/application/v3_material_upload_controller.dart';

void main() {
  test(
    'durable: audio queue failure keeps selection and publishes no upload job',
    () async {
      final jobs = <String>[];
      final controller = _controller(
        nativeFilePort: _PickerPort(
          NativeFileResult<List<PickedAudioFile>>.success([
            PickedAudioFile(
              pickerRef: 'picker:audio',
              displayName: 'Audio.m4a',
              mimeType: 'audio/mp4',
              sizeBytes: 2048,
            ),
          ]),
        ),
        onDistillationJobReady: (jobId, _) async {
          jobs.add(jobId);
          return false;
        },
      );
      addTearDown(controller.dispose);
      await controller.selectFromPicker();
      final selected = controller.state.selectedItem;
      await controller.uploadSelected(distillToDigitalTwin: true);
      expect(jobs.single, recordingFileJobId(selected!));
      expect(controller.state.lastErrorCode, 'DIGITAL_TWIN_QUEUE_SAVE_FAILED');
      expect(controller.state.selectedItem, selected);
      expect(controller.state.transcriptionJobId, isNull);
    },
  );

  test(
    'durable: audio opt-in is submitted before navigation and survives page disposal',
    () async {
      final gate = Completer<bool>();
      final jobs = <String>[];
      final controller = _controller(
        nativeFilePort: _PickerPort(
          NativeFileResult<List<PickedAudioFile>>.success([
            PickedAudioFile(
              pickerRef: 'picker:audio',
              displayName: 'Audio.m4a',
              mimeType: 'audio/mp4',
              sizeBytes: 2048,
            ),
          ]),
        ),
        onDistillationJobReady: (jobId, _) {
          jobs.add(jobId);
          return gate.future;
        },
      );
      await controller.selectFromPicker();
      final uploading = controller.uploadSelected(distillToDigitalTwin: true);
      expect(jobs, hasLength(1));
      expect(controller.state.transcriptionJobId, isNull);
      controller.dispose();
      gate.complete(true);
      await uploading;
      expect(controller.state.transcriptionJobId, isNull);
    },
  );
  group('V3MaterialUploadController', () {
    test(
      'imports picker audio into the local library and selects it',
      () async {
        final controller = _controller(
          nativeFilePort: _PickerPort(
            NativeFileResult<List<PickedAudioFile>>.success(
              const <PickedAudioFile>[
                PickedAudioFile(
                  pickerRef: 'picker:meeting',
                  displayName: 'Meeting.m4a',
                  mimeType: 'audio/mp4',
                  sizeBytes: 2048,
                ),
              ],
            ),
          ),
        );

        await controller.selectFromPicker();

        expect(controller.state.status, V3MaterialUploadStatus.ready);
        expect(controller.state.selectedItem?.displayName, 'Meeting.m4a');
        expect(controller.state.recentItems, hasLength(1));
        expect(controller.state.lastErrorCode, isNull);

        expect(controller.beginFreshSession(), isTrue);
        expect(controller.state.status, V3MaterialUploadStatus.idle);
        expect(controller.state.selectedItem, isNull);
        expect(controller.state.createdRecording, isNull);
        expect(controller.state.recentItems.single.displayName, 'Meeting.m4a');
      },
    );

    test('does not create a selected item when picker fails', () async {
      final controller = _controller(
        nativeFilePort: _PickerPort(
          NativeFileResult<List<PickedAudioFile>>.failure(
            const AppFailure(
              code: 'RECORDING_PICKER_EMPTY',
              category: AppFailureCategory.storage,
              message: 'No audio selected',
              userMessageKey: 'recording.import.empty',
            ),
          ),
        ),
      );

      await controller.selectFromPicker();

      expect(controller.state.status, V3MaterialUploadStatus.failed);
      expect(controller.state.lastErrorCode, 'RECORDING_PICKER_EMPTY');
      expect(controller.state.selectedItem, isNull);
    });

    test('rejects multiple recordings before importing either file', () async {
      final controller = _controller(
        nativeFilePort: _PickerPort(
          NativeFileResult<List<PickedAudioFile>>.success(
            const <PickedAudioFile>[
              PickedAudioFile(
                pickerRef: 'picker:first',
                displayName: 'First.m4a',
                mimeType: 'audio/mp4',
                sizeBytes: 1024,
              ),
              PickedAudioFile(
                pickerRef: 'picker:second',
                displayName: 'Second.wav',
                mimeType: 'audio/wav',
                sizeBytes: 2048,
              ),
            ],
          ),
        ),
      );

      await controller.selectFromPicker();

      expect(controller.state.status, V3MaterialUploadStatus.failed);
      expect(
        controller.state.lastErrorCode,
        'RECORDING_IMPORT_SINGLE_REQUIRED',
      );
      expect(controller.state.selectedItem, isNull);
      expect(controller.state.recentItems, isEmpty);
    });

    test('multiple selection clears a previously selected recording', () async {
      final controller = _controller(
        nativeFilePort: _SequencePickerPort(
          <NativeFileResult<List<PickedAudioFile>>>[
            NativeFileResult<List<PickedAudioFile>>.success(
              const <PickedAudioFile>[
                PickedAudioFile(
                  pickerRef: 'picker:existing',
                  displayName: 'Existing.m4a',
                  mimeType: 'audio/mp4',
                  sizeBytes: 1024,
                ),
              ],
            ),
            NativeFileResult<List<PickedAudioFile>>.success(
              const <PickedAudioFile>[
                PickedAudioFile(
                  pickerRef: 'picker:first',
                  displayName: 'First.m4a',
                  mimeType: 'audio/mp4',
                  sizeBytes: 1024,
                ),
                PickedAudioFile(
                  pickerRef: 'picker:second',
                  displayName: 'Second.wav',
                  mimeType: 'audio/wav',
                  sizeBytes: 2048,
                ),
              ],
            ),
          ],
        ),
      );

      await controller.selectFromPicker();
      expect(controller.state.selectedItem?.displayName, 'Existing.m4a');

      await controller.selectFromPicker();

      expect(controller.state.status, V3MaterialUploadStatus.failed);
      expect(
        controller.state.lastErrorCode,
        'RECORDING_IMPORT_SINGLE_REQUIRED',
      );
      expect(controller.state.selectedItem, isNull);
    });

    test('dismissed picker remains idle without an import error', () async {
      final controller = _controller(
        nativeFilePort: _PickerPort(
          NativeFileResult<List<PickedAudioFile>>.cancelled(),
        ),
      );

      await controller.selectFromPicker();

      expect(controller.state.status, V3MaterialUploadStatus.idle);
      expect(controller.state.lastErrorCode, isNull);
      expect(controller.state.selectedItem, isNull);
    });

    test('an unresolved picker stays idle and opens only once', () async {
      final picker = _DeferredAudioPicker();
      final controller = _controller(nativeFilePort: picker);

      final first = controller.selectFromPicker();
      await Future<void>.delayed(Duration.zero);
      final second = controller.selectFromPicker();

      expect(controller.state.status, V3MaterialUploadStatus.idle);
      expect(picker.calls, 1);

      picker.complete(NativeFileResult<List<PickedAudioFile>>.cancelled());
      await Future.wait(<Future<void>>[first, second]);
      expect(controller.state.status, V3MaterialUploadStatus.idle);
    });
  });
}

V3MaterialUploadController _controller({
  required NativeFilePort nativeFilePort,
  Future<bool> Function(String jobId, String title)? onDistillationJobReady,
}) {
  final database = AppDatabase();
  final repository = LocalRecordingRepository(
    database: database,
    fileStorage: const _FileStorage(),
  );
  return V3MaterialUploadController(
    onDistillationJobReady: onDistillationJobReady,
    nativeFilePort: nativeFilePort,
    repository: repository,
    recordingUploadController: RecordingUploadController(
      uploadClient: UploadClient(
        apiClient: ApiClient(
          config: ApiClientConfig(
            baseUrl: Uri.parse('https://api.example.test'),
            clientVersion: 'test',
            deviceId: 'device-1',
            platform: 'test',
            locale: 'zh-CN',
          ),
          transport: const _UnusedApiTransport(),
        ),
        objectTransport: const _UnusedObjectUploadTransport(),
      ),
      draftStore: UploadDraftStore(database: database),
      recordingApi: const _UnusedRecordingApi(),
      localRecordingRepository: repository,
    ),
  );
}

final class _PickerPort implements NativeFilePort {
  const _PickerPort(this.result);

  final NativeFileResult<List<PickedAudioFile>> result;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    return result;
  }
}

final class _SequencePickerPort implements NativeFilePort {
  _SequencePickerPort(this.results);

  final List<NativeFileResult<List<PickedAudioFile>>> results;
  var _index = 0;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    return results[_index++];
  }
}

final class _DeferredAudioPicker implements NativeFilePort {
  final Completer<NativeFileResult<List<PickedAudioFile>>> _result =
      Completer<NativeFileResult<List<PickedAudioFile>>>();
  int calls = 0;

  void complete(NativeFileResult<List<PickedAudioFile>> result) {
    _result.complete(result);
  }

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() {
    calls += 1;
    return _result.future;
  }
}

final class _FileStorage extends UnavailableFileStoragePort {
  const _FileStorage();

  @override
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  ) async {
    return FileStorageResult<PrivateAudioFile>.success(
      PrivateAudioFile(
        fileId: 'local-meeting',
        appPrivateUri: 'app-private://recordings/local-meeting/source.m4a',
        displayName: picked.displayName,
        mimeType: picked.mimeType,
        sizeBytes: picked.sizeBytes,
      ),
    );
  }

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(String appPrivateUri) {
    throw UnimplementedError();
  }

  @override
  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<PrivateAudioFileStat>.success(
      const PrivateAudioFileStat(exists: true, sizeBytes: 2048),
    );
  }

  @override
  Future<FileStorageResult<bool>> updatePrivateAudioMetadata({
    required String appPrivateUri,
    required String displayName,
  }) {
    throw UnimplementedError();
  }
}

final class _UnusedApiTransport implements ApiTransport {
  const _UnusedApiTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    throw UnimplementedError();
  }
}

final class _UnusedObjectUploadTransport implements ObjectUploadTransport {
  const _UnusedObjectUploadTransport();

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) {
    throw UnimplementedError();
  }
}

final class _UnusedRecordingApi implements RecordingApiPort {
  const _UnusedRecordingApi();

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(String recordingId) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }
}
