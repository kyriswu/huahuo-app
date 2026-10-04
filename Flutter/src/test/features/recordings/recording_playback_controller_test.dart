import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/native/native_playback_port.dart';
import 'package:huahuoai_app/features/recordings/application/recording_playback_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_playback_position_store.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';

void main() {
  group('RecordingPlaybackController', () {
    test('recognizes raw AAC ADTS without misclassifying M4A ftyp', () {
      expect(isAdtsAacAudioHeader(const <int>[0xff, 0xf1, 0x50, 0x80]), isTrue);
      expect(isAdtsAacAudioHeader(const <int>[0xff, 0xf9, 0x4c, 0x80]), isTrue);
      expect(
        isAdtsAacAudioHeader(const <int>[
          0x00,
          0x00,
          0x00,
          0x18,
          0x66,
          0x74,
          0x79,
          0x70,
        ]),
        isFalse,
      );
    });

    test('uses the RN playback audio-session configuration', () {
      const configuration = rnPlaybackAudioSessionConfiguration;

      expect(
        configuration.avAudioSessionCategory,
        AVAudioSessionCategory.playback,
      );
      expect(configuration.avAudioSessionMode, AVAudioSessionMode.defaultMode);
      expect(
        configuration.avAudioSessionCategoryOptions,
        AVAudioSessionCategoryOptions.none,
      );
      expect(
        configuration.androidAudioAttributes?.usage,
        AndroidAudioUsage.media,
      );
      expect(
        configuration.androidAudioAttributes?.contentType,
        AndroidAudioContentType.speech,
      );
      expect(
        configuration.androidAudioFocusGainType,
        AndroidAudioFocusGainType.gain,
      );
    });

    test('bounds playback position updates to 4-10 Hz', () {
      expect(
        nativePlaybackPositionMinPeriod,
        const Duration(milliseconds: 100),
      );
      expect(
        nativePlaybackPositionMaxPeriod,
        const Duration(milliseconds: 250),
      );
    });

    test(
      'loads, resumes, pauses, seeks, changes rate, and clears completed progress',
      () async {
        final port = _FakePlaybackPort();
        final positions = InMemoryRecordingPlaybackPositionStore()
          ..save(
            recordingId: _item().recordingId,
            position: const Duration(seconds: 12),
          );
        final controller = RecordingPlaybackController(
          playbackPort: port,
          positionStore: positions,
        );
        addTearDown(controller.dispose);

        await controller.open(_item(), autoPlay: true);

        expect(port.loadCalls, 1);
        expect(port.seekCalls, <Duration>[const Duration(seconds: 12)]);
        expect(port.playCalls, 1);
        expect(
          controller.state.status,
          RecordingPlaybackControllerStatus.playing,
        );
        expect(controller.state.position, const Duration(seconds: 12));

        await controller.seekTo(const Duration(seconds: 20));
        await controller.setRate(1.5);
        await controller.pause();

        expect(
          controller.state.status,
          RecordingPlaybackControllerStatus.paused,
        );
        expect(controller.state.position, const Duration(seconds: 20));
        expect(controller.state.rate, 1.5);
        expect(
          positions.read(_item().recordingId),
          const Duration(seconds: 20),
        );

        port.emit(
          NativePlaybackSnapshot(
            status: NativePlaybackStatus.completed,
            recordingId: _item().recordingId,
            position: const Duration(seconds: 60),
            duration: const Duration(seconds: 60),
            rate: 1.5,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          controller.state.status,
          RecordingPlaybackControllerStatus.completed,
        );
        expect(positions.read(_item().recordingId), isNull);
      },
    );

    test(
      'rejects incomplete and missing library files before touching player',
      () async {
        final port = _FakePlaybackPort();
        final controller = RecordingPlaybackController(
          playbackPort: port,
          positionStore: InMemoryRecordingPlaybackPositionStore(),
        );
        addTearDown(controller.dispose);

        await controller.open(
          _item(localFileState: RecordingLocalFileState.part),
          autoPlay: true,
        );
        expect(
          controller.state.status,
          RecordingPlaybackControllerStatus.failed,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_PLAYBACK_FILE_NOT_READY',
        );
        expect(port.loadCalls, 0);

        await controller.open(
          _item(localFileState: RecordingLocalFileState.missing),
          autoPlay: true,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_PLAYBACK_FILE_MISSING',
        );
        expect(port.loadCalls, 0);
      },
    );

    test(
      'surfaces playback-port failures without a fabricated playing state',
      () async {
        final port = _FakePlaybackPort(
          loadFailure: const AppFailure(
            code: 'NATIVE_PLAYBACK_DRIVER_UNAVAILABLE',
            category: AppFailureCategory.storage,
            message: 'unavailable',
            userMessageKey: 'recording.playback.error.unavailable',
          ),
        );
        final controller = RecordingPlaybackController(
          playbackPort: port,
          positionStore: InMemoryRecordingPlaybackPositionStore(),
        );
        addTearDown(controller.dispose);

        await controller.toggle(_item());

        expect(
          controller.state.status,
          RecordingPlaybackControllerStatus.failed,
        );
        expect(
          controller.state.lastErrorCode,
          'NATIVE_PLAYBACK_DRIVER_UNAVAILABLE',
        );
        expect(controller.state.isPlaying, isFalse);
      },
    );

    test(
      'retrying a failed active item starts a fresh validated load',
      () async {
        final port = _FakePlaybackPort(
          loadFailure: const AppFailure(
            code: 'NATIVE_PLAYBACK_DRIVER_UNAVAILABLE',
            category: AppFailureCategory.storage,
            message: 'unavailable',
            userMessageKey: 'recording.playback.error.unavailable',
          ),
        );
        final controller = RecordingPlaybackController(
          playbackPort: port,
          positionStore: InMemoryRecordingPlaybackPositionStore(),
        );
        addTearDown(controller.dispose);

        await controller.toggle(_item());
        port.loadFailure = null;
        await controller.toggle(_item());

        expect(port.loadCalls, 2);
        expect(
          controller.state.status,
          RecordingPlaybackControllerStatus.playing,
        );
      },
    );

    test(
      'release saves a resume point and clears the active player item',
      () async {
        final positions = InMemoryRecordingPlaybackPositionStore();
        final controller = RecordingPlaybackController(
          playbackPort: _FakePlaybackPort(),
          positionStore: positions,
        );
        addTearDown(controller.dispose);

        await controller.open(_item(), autoPlay: true);
        await controller.seekTo(const Duration(seconds: 18));
        await controller.release();

        expect(
          controller.state.status,
          RecordingPlaybackControllerStatus.released,
        );
        expect(controller.state.item, isNull);
        expect(
          positions.read(_item().recordingId),
          const Duration(seconds: 18),
        );
      },
    );

    test('local position store writes resumable whole seconds only', () {
      final store = LocalRecordingPlaybackPositionStore(
        dao: RecordingDao(AppDatabase()),
      );

      store.save(
        recordingId: _item().recordingId,
        position: const Duration(milliseconds: 3900),
      );
      store.save(
        recordingId: '../unsafe',
        position: const Duration(seconds: 11),
      );

      expect(store.read(_item().recordingId), const Duration(seconds: 3));
      expect(store.read('../unsafe'), isNull);
      store.clear(_item().recordingId);
      expect(store.read(_item().recordingId), isNull);
    });
  });
}

RecordingLibraryItem _item({
  RecordingLocalFileState localFileState = RecordingLocalFileState.ready,
}) {
  final at = DateTime.utc(2026, 7, 10, 10);
  return RecordingLibraryItem(
    recordingId: 'local-recording-1',
    source: RecordingLibrarySource.localImport,
    displayName: 'Meeting.m4a',
    format: RecordingLibraryFormat.m4a,
    localFileState: localFileState,
    status: RecordingLibraryStatus.localOnly,
    durationSeconds: 60,
    sizeBytes: 2048,
    isFavorite: false,
    tagIds: const <String>[],
    createdAt: at,
    updatedAt: at,
    appPrivateUri: 'app-private://recordings/recording-1/source.m4a',
  );
}

final class _FakePlaybackPort implements NativePlaybackPort {
  _FakePlaybackPort({this.loadFailure});

  AppFailure? loadFailure;
  final StreamController<NativePlaybackSnapshot> _snapshots =
      StreamController<NativePlaybackSnapshot>.broadcast();
  NativePlaybackSnapshot _snapshot = const NativePlaybackSnapshot.idle();
  int loadCalls = 0;
  int playCalls = 0;
  final List<Duration> seekCalls = <Duration>[];

  @override
  Stream<NativePlaybackSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> dispose() async {
    await _snapshots.close();
  }

  void emit(NativePlaybackSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> load({
    required String recordingId,
    required String appPrivateUri,
    Duration knownDuration = Duration.zero,
  }) async {
    loadCalls += 1;
    final failure = loadFailure;
    if (failure != null) return NativePlaybackResult.failure(failure);
    _snapshot = NativePlaybackSnapshot(
      status: NativePlaybackStatus.ready,
      recordingId: recordingId,
      duration: knownDuration,
    );
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> pause() async {
    _snapshot = _snapshot.copyWith(status: NativePlaybackStatus.paused);
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> play() async {
    playCalls += 1;
    _snapshot = _snapshot.copyWith(status: NativePlaybackStatus.playing);
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> release() async {
    _snapshot = _snapshot.copyWith(
      status: NativePlaybackStatus.released,
      clearRecordingId: true,
    );
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> seekTo(
    Duration value,
  ) async {
    seekCalls.add(value);
    _snapshot = _snapshot.copyWith(position: value);
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> setRate(
    double value,
  ) async {
    _snapshot = _snapshot.copyWith(rate: value);
    return NativePlaybackResult.success(_snapshot);
  }
}
