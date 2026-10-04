import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recordings/application/recording_library_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecordingLibraryController', () {
    test(
      'initial and filtered inventory cannot impersonate deletion',
      () async {
        final controller = _controller(
          nativeFilePort: _FakeNativeFilePort(
            files: <PickedAudioFile>[_picked(displayName: 'Lookup.m4a')],
          ),
        );
        addTearDown(controller.dispose);
        expect(controller.state.hasVerifiedInventory, isFalse);
        await controller.importFromPicker(now: _time());
        final recording = controller.state.items.single;
        controller.setSearchText('not-present');
        expect(controller.state.items, isEmpty);
        expect(
          controller.findById(recording.recordingId)?.displayName,
          'Lookup.m4a',
        );
        expect(controller.state.hasVerifiedInventory, isFalse);
        await controller.load();
        expect(controller.state.hasVerifiedInventory, isTrue);
      },
    );

    test(
      'picker import updates list and search filters visible rows',
      () async {
        final controller = _controller(
          nativeFilePort: _FakeNativeFilePort(
            files: <PickedAudioFile>[
              _picked(displayName: 'Client Meeting.m4a'),
              _picked(displayName: 'Field Note.wav'),
            ],
          ),
        );

        await controller.importFromPicker(now: _time());

        expect(controller.state.status, RecordingLibraryControllerStatus.idle);
        expect(
          controller.state.items.map((item) => item.displayName),
          unorderedEquals(<String>['Client Meeting.m4a', 'Field Note.wav']),
        );

        controller.setSearchText('client');
        expect(controller.state.items, hasLength(1));
        expect(controller.state.items.single.displayName, 'Client Meeting.m4a');

        controller.setSearchText('missing');
        expect(controller.state.items, isEmpty);
        expect(controller.state.emptyState, 'noSearchResults');
      },
    );

    test('picker failure does not create rows or fake success', () async {
      final controller = _controller(
        nativeFilePort: const _FakeNativeFilePort(
          error: AppFailure(
            code: 'NATIVE_FILE_DRIVER_UNAVAILABLE',
            category: AppFailureCategory.storage,
            message: 'unavailable',
            userMessageKey: 'recording.import.nativeUnavailable',
          ),
        ),
      );

      await controller.importFromPicker(now: _time());

      expect(controller.state.status, RecordingLibraryControllerStatus.error);
      expect(controller.state.lastErrorCode, 'NATIVE_FILE_DRIVER_UNAVAILABLE');
      expect(controller.state.items, isEmpty);
    });

    test('an unresolved picker stays idle and opens only once', () async {
      final picker = _DeferredAudioPicker();
      final controller = _controller(nativeFilePort: picker);

      final first = controller.importFromPicker(now: _time());
      await Future<void>.delayed(Duration.zero);
      final second = controller.importFromPicker(now: _time());

      expect(controller.state.status, RecordingLibraryControllerStatus.idle);
      expect(picker.calls, 1);

      picker.complete(NativeFileResult<List<PickedAudioFile>>.cancelled());
      await Future.wait(<Future<void>>[first, second]);
      expect(controller.state.status, RecordingLibraryControllerStatus.idle);
    });

    test('confirmed external audio batch reuses normal import path', () async {
      final native = const _FakeNativeFilePort(
        error: AppFailure(
          code: 'PICKER_MUST_NOT_OPEN',
          category: AppFailureCategory.storage,
          message: 'unused',
          userMessageKey: 'unused',
        ),
      );
      final controller = _controller(nativeFilePort: native);

      final imported = await controller
          .importPickedFilesDetailed(<PickedAudioFile>[
            _picked(
              displayName: 'External.wav',
              pickerRef: 'incoming-material://external-1',
            ),
          ], now: _time());

      expect(imported.ok, isTrue);
      expect(imported.imported, hasLength(1));
      expect(
        imported.imported.single.appPrivateUri,
        startsWith('app-private://'),
      );
      expect(controller.state.status, RecordingLibraryControllerStatus.idle);
      expect(controller.state.items.single.displayName, 'External.wav');
    });

    test('prepare export exposes opaque ref and keeps paths hidden', () async {
      final controller = _controller(
        nativeFilePort: _FakeNativeFilePort(
          files: <PickedAudioFile>[_picked()],
        ),
      );
      await controller.importFromPicker(now: _time());

      await controller.prepareExport(controller.state.items.single.recordingId);

      expect(controller.state.status, RecordingLibraryControllerStatus.idle);
      expect(
        controller.state.preparedExport?.opaqueExportRef,
        startsWith('app-private-export://'),
      );
      expect(
        controller.state.preparedExport?.opaqueExportRef,
        isNot(contains('/Users/')),
      );
      expect(controller.state.preparedExport?.displayName, 'Meeting.m4a');
    });

    test('prepare export failure does not fake success', () async {
      final controller = _controller(
        nativeFilePort: _FakeNativeFilePort(
          files: <PickedAudioFile>[_picked()],
        ),
        fileStorage: _FakeFileStorage(statExists: false),
      );
      await controller.importFromPicker(now: _time());

      await controller.prepareExport(controller.state.items.single.recordingId);

      expect(controller.state.status, RecordingLibraryControllerStatus.error);
      expect(controller.state.lastErrorCode, 'RECORDING_PRIVATE_FILE_MISSING');
      expect(controller.state.preparedExport, isNull);
    });

    test('save and open dispatch only the opaque prepared export', () async {
      final nativeFilePort = _ExportingNativeFilePort(
        files: <PickedAudioFile>[_picked()],
      );
      final controller = _controller(nativeFilePort: nativeFilePort);
      await controller.importFromPicker(now: _time());
      final recordingId = controller.state.items.single.recordingId;

      expect(await controller.saveToDevice(recordingId), isTrue);
      expect(await controller.openWithOtherApp(recordingId), isTrue);

      expect(nativeFilePort.saveCalls, hasLength(1));
      expect(nativeFilePort.openCalls, hasLength(1));
      expect(
        nativeFilePort.saveCalls.single.opaqueExportRef,
        startsWith(
          'app-private-export://recordings/users/'
          'u-0123456789abcdef0123456789abcdef/cache/',
        ),
      );
      expect(
        nativeFilePort.saveCalls.single.opaqueExportRef,
        isNot(contains('/Users/')),
      );
      expect(nativeFilePort.saveCalls.single.mimeType, 'audio/mp4');
      expect(controller.state.lastErrorCode, isNull);
    });

    test('renamed exports keep the real extension and MIME', () async {
      final nativeFilePort = _ExportingNativeFilePort(
        files: <PickedAudioFile>[_picked()],
      );
      final controller = _controller(nativeFilePort: nativeFilePort);
      await controller.importFromPicker(now: _time());
      final recordingId = controller.state.items.single.recordingId;

      await controller.rename(
        recordingId: recordingId,
        displayName: '用户标题.wav',
      );
      expect(await controller.openWithOtherApp(recordingId), isTrue);

      expect(nativeFilePort.openCalls.single.displayName, '用户标题.m4a');
      expect(nativeFilePort.openCalls.single.mimeType, 'audio/mp4');
      expect(
        nativeFilePort.openCalls.single.opaqueExportRef,
        endsWith('/用户标题.m4a'),
      );

      await controller.rename(recordingId: recordingId, displayName: '没有后缀');
      expect(await controller.saveToDevice(recordingId), isTrue);
      expect(nativeFilePort.saveCalls.single.displayName, '没有后缀.m4a');
      expect(nativeFilePort.saveCalls.single.mimeType, 'audio/mp4');
    });

    test(
      'cancelled system save does not report an error or fake success',
      () async {
        final nativeFilePort = _ExportingNativeFilePort(
          files: <PickedAudioFile>[_picked()],
          saveCompleted: false,
        );
        final controller = _controller(nativeFilePort: nativeFilePort);
        await controller.importFromPicker(now: _time());

        expect(
          await controller.saveToDevice(
            controller.state.items.single.recordingId,
          ),
          isFalse,
        );
        expect(controller.state.status, RecordingLibraryControllerStatus.idle);
        expect(controller.state.lastErrorCode, isNull);
        expect(nativeFilePort.saveCalls, hasLength(1));
      },
    );

    test('Android system-save cancellation remains a neutral result', () async {
      const channel = MethodChannel('huahuoai/native_file');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'savePreparedAudioExport');
        throw PlatformException(
          code: 'NATIVE_AUDIO_EXPORT_SAVE_CANCELLED',
          message: 'cancelled',
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final controller = _controller(
        nativeFilePort: MethodChannelNativeFilePort(),
      );
      await controller.importPickedFiles(<PickedAudioFile>[_picked()]);

      expect(
        await controller.saveToDevice(
          controller.state.items.single.recordingId,
        ),
        isFalse,
      );
      expect(controller.state.status, RecordingLibraryControllerStatus.idle);
      expect(controller.state.lastErrorCode, isNull);
    });

    test(
      'exposes favorite tags recycle-bin restore and permanent delete',
      () async {
        final controller = _controller(
          nativeFilePort: _FakeNativeFilePort(
            files: <PickedAudioFile>[_picked()],
          ),
        );
        await controller.importFromPicker(now: _time());
        final recordingId = controller.state.items.single.recordingId;

        controller.setFavorite(recordingId: recordingId, isFavorite: true);
        controller.updateTags(
          recordingId: recordingId,
          tagIds: <String>['customer', 'todo'],
        );
        expect(controller.state.items.single.isFavorite, isTrue);
        expect(controller.state.items.single.tagIds, <String>[
          'customer',
          'todo',
        ]);

        controller.moveToTrash(recordingId: recordingId);
        expect(controller.state.items, isEmpty);
        controller.setView(RecordingLibraryView.recycleBin);
        expect(
          controller.state.items.single.status,
          RecordingLibraryStatus.recycled,
        );

        controller.restoreFromTrash(recordingId: recordingId);
        expect(controller.state.items, isEmpty);
        controller.setView(RecordingLibraryView.library);
        expect(
          controller.state.items.single.status,
          RecordingLibraryStatus.localOnly,
        );

        await controller.deletePermanently(recordingId);
        expect(controller.state.items, isEmpty);
        expect(controller.state.lastErrorCode, isNull);
      },
    );
  });
}

RecordingLibraryController _controller({
  required NativeFilePort nativeFilePort,
  FileStoragePort? fileStorage,
}) {
  return RecordingLibraryController(
    repository: LocalRecordingRepository(
      database: AppDatabase(),
      fileStorage: fileStorage ?? _FakeFileStorage(),
    ),
    nativeFilePort: nativeFilePort,
  );
}

PickedAudioFile _picked({
  String displayName = 'Meeting.m4a',
  String? pickerRef,
}) {
  return PickedAudioFile(
    pickerRef: pickerRef ?? 'picker:$displayName',
    displayName: displayName,
    mimeType: 'audio/mp4',
    sizeBytes: 2048,
    durationSeconds: 90,
    contentHash:
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    recordedAt: _time(),
  );
}

DateTime _time() => DateTime.utc(2026, 7, 1, 9);

final class _FakeNativeFilePort implements NativeFilePort {
  const _FakeNativeFilePort({
    this.files = const <PickedAudioFile>[],
    this.error,
  });

  final List<PickedAudioFile> files;
  final AppFailure? error;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    final failure = error;
    if (failure != null) {
      return NativeFileResult<List<PickedAudioFile>>.failure(failure);
    }
    return NativeFileResult<List<PickedAudioFile>>.success(files);
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

final class _PreparedExportCall {
  const _PreparedExportCall({
    required this.opaqueExportRef,
    required this.displayName,
    required this.mimeType,
  });

  final String opaqueExportRef;
  final String displayName;
  final String mimeType;
}

final class _ExportingNativeFilePort
    implements NativeFilePort, NativePreparedAudioExportPort {
  _ExportingNativeFilePort({required this.files, this.saveCompleted = true});

  final List<PickedAudioFile> files;
  final bool saveCompleted;
  final List<_PreparedExportCall> saveCalls = <_PreparedExportCall>[];
  final List<_PreparedExportCall> openCalls = <_PreparedExportCall>[];

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    return NativeFileResult<List<PickedAudioFile>>.success(files);
  }

  @override
  Future<NativeFileResult<bool>> savePreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    saveCalls.add(
      _PreparedExportCall(
        opaqueExportRef: opaqueExportRef,
        displayName: displayName,
        mimeType: mimeType,
      ),
    );
    return NativeFileResult<bool>.success(saveCompleted);
  }

  @override
  Future<NativeFileResult<bool>> openPreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    openCalls.add(
      _PreparedExportCall(
        opaqueExportRef: opaqueExportRef,
        displayName: displayName,
        mimeType: mimeType,
      ),
    );
    return NativeFileResult<bool>.success(true);
  }
}

final class _FakeFileStorage extends UnavailableFileStoragePort {
  _FakeFileStorage({this.statExists = true});

  final bool statExists;

  @override
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  ) async {
    final safeId = picked.displayName.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9._-]+'),
      '-',
    );
    return FileStorageResult<PrivateAudioFile>.success(
      PrivateAudioFile(
        fileId: 'recordings/$safeId',
        appPrivateUri: 'app-private://recordings/$safeId/source.m4a',
        displayName: picked.displayName,
        mimeType: picked.mimeType,
        sizeBytes: picked.sizeBytes,
        durationSeconds: picked.durationSeconds,
        contentHash: picked.contentHash,
        recordedAt: picked.recordedAt,
      ),
    );
  }

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<PrivateAudioFileStat>.success(
      PrivateAudioFileStat(exists: statExists, sizeBytes: 2048),
    );
  }

  @override
  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  }) async {
    return FileStorageResult<PreparedAudioExport>.success(
      PreparedAudioExport(
        opaqueExportRef:
            'app-private-export://recordings/users/'
            'u-0123456789abcdef0123456789abcdef/cache/export-1/$displayName',
        displayName: displayName,
        sizeBytes: 2048,
      ),
    );
  }

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<bool>.success(true);
  }

  @override
  Future<FileStorageResult<bool>> updatePrivateAudioMetadata({
    required String appPrivateUri,
    required String displayName,
  }) async {
    return FileStorageResult<bool>.success(true);
  }
}
