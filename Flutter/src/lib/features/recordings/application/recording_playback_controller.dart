import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/native/native_playback_port.dart';
import '../domain/recording_library.dart';
import 'recording_playback_position_store.dart';

enum RecordingPlaybackControllerStatus {
  idle,
  loading,
  ready,
  playing,
  paused,
  completed,
  failed,
  released,
}

final class RecordingPlaybackState {
  const RecordingPlaybackState({
    required this.status,
    required this.position,
    required this.duration,
    required this.rate,
    this.item,
    this.lastErrorCode,
  });

  const RecordingPlaybackState.initial()
    : status = RecordingPlaybackControllerStatus.idle,
      position = Duration.zero,
      duration = Duration.zero,
      rate = 1,
      item = null,
      lastErrorCode = null;

  final RecordingPlaybackControllerStatus status;
  final RecordingLibraryItem? item;
  final Duration position;
  final Duration duration;
  final double rate;
  final String? lastErrorCode;

  String? get recordingId => item?.recordingId;
  bool get isPlaying => status == RecordingPlaybackControllerStatus.playing;
  bool get canSeek =>
      item != null &&
      duration > Duration.zero &&
      status != RecordingPlaybackControllerStatus.loading &&
      status != RecordingPlaybackControllerStatus.failed;

  RecordingPlaybackState copyWith({
    RecordingPlaybackControllerStatus? status,
    RecordingLibraryItem? item,
    Duration? position,
    Duration? duration,
    double? rate,
    String? lastErrorCode,
    bool clearItem = false,
    bool clearError = false,
  }) {
    return RecordingPlaybackState(
      status: status ?? this.status,
      item: clearItem ? null : item ?? this.item,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      rate: rate ?? this.rate,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    );
  }
}

final class RecordingPlaybackController extends ChangeNotifier {
  RecordingPlaybackController({
    required NativePlaybackPort playbackPort,
    required RecordingPlaybackPositionStore positionStore,
  }) : _playbackPort = playbackPort,
       _positionStore = positionStore {
    _subscription = _playbackPort.snapshots.listen(_applyNativeSnapshot);
  }

  final NativePlaybackPort _playbackPort;
  final RecordingPlaybackPositionStore _positionStore;
  late final StreamSubscription<NativePlaybackSnapshot> _subscription;
  RecordingPlaybackState _state = const RecordingPlaybackState.initial();
  String? _lastPersistedRecordingId;
  int _lastPersistedSeconds = -1;
  bool _disposed = false;

  RecordingPlaybackState get state => _state;

  Future<void> toggle(RecordingLibraryItem item) async {
    if (_state.recordingId == item.recordingId) {
      if (_state.isPlaying) {
        await pause();
      } else if (_state.status == RecordingPlaybackControllerStatus.ready ||
          _state.status == RecordingPlaybackControllerStatus.paused ||
          _state.status == RecordingPlaybackControllerStatus.completed) {
        await _play();
      } else if (_state.status == RecordingPlaybackControllerStatus.failed ||
          _state.status == RecordingPlaybackControllerStatus.released) {
        await open(item, autoPlay: true);
      }
      return;
    }
    await open(item, autoPlay: true);
  }

  Future<void> open(RecordingLibraryItem item, {bool autoPlay = false}) async {
    final failure = _validate(item);
    if (failure != null) {
      _fail(failure, item: item);
      return;
    }

    if (_state.item != null) {
      await _playbackPort.release();
    }
    _setState(
      RecordingPlaybackState(
        status: RecordingPlaybackControllerStatus.loading,
        item: item,
        position: Duration.zero,
        duration: Duration(
          seconds: item.durationSeconds < 0 ? 0 : item.durationSeconds,
        ),
        rate: _state.rate,
      ),
    );
    final loaded = await _playbackPort.load(
      recordingId: item.recordingId,
      appPrivateUri: item.appPrivateUri!,
      knownDuration: Duration(
        seconds: item.durationSeconds < 0 ? 0 : item.durationSeconds,
      ),
    );
    if (!loaded.ok || loaded.value == null) {
      _fail(
        loaded.error ?? playbackFailure('RECORDING_PLAYBACK_FAILED'),
        item: item,
      );
      return;
    }
    final savedPosition = _positionStore.read(item.recordingId);
    _applyNativeSnapshot(loaded.value!);
    final duration = _state.duration;
    if (savedPosition != null &&
        savedPosition > Duration.zero &&
        (duration == Duration.zero || savedPosition < duration)) {
      final seeked = await _playbackPort.seekTo(savedPosition);
      if (!seeked.ok || seeked.value == null) {
        _fail(
          seeked.error ?? playbackFailure('RECORDING_PLAYBACK_FAILED'),
          item: item,
        );
        return;
      }
      _applyNativeSnapshot(seeked.value!);
    }
    if (autoPlay) await _play();
  }

  Future<void> pause() async {
    final result = await _playbackPort.pause();
    if (!result.ok || result.value == null) {
      _fail(result.error ?? playbackFailure('RECORDING_PLAYBACK_FAILED'));
      return;
    }
    _applyNativeSnapshot(result.value!);
  }

  Future<void> seekTo(Duration position) async {
    final result = await _playbackPort.seekTo(position);
    if (!result.ok || result.value == null) {
      _fail(result.error ?? playbackFailure('RECORDING_PLAYBACK_FAILED'));
      return;
    }
    _applyNativeSnapshot(result.value!);
  }

  Future<void> setRate(double rate) async {
    final result = await _playbackPort.setRate(rate);
    if (!result.ok || result.value == null) {
      _fail(result.error ?? playbackFailure('RECORDING_PLAYBACK_FAILED'));
      return;
    }
    _applyNativeSnapshot(result.value!);
  }

  Future<void> release() async {
    final current = _state;
    if (current.recordingId != null) _persistCurrentPosition(force: true);
    final result = await _playbackPort.release();
    if (!result.ok || result.value == null) {
      _fail(result.error ?? playbackFailure('RECORDING_PLAYBACK_FAILED'));
      return;
    }
    _setState(
      current.copyWith(
        status: RecordingPlaybackControllerStatus.released,
        position: Duration.zero,
        duration: Duration.zero,
        clearItem: true,
        clearError: true,
      ),
    );
  }

  Future<void> _play() async {
    final result = await _playbackPort.play();
    if (!result.ok || result.value == null) {
      _fail(result.error ?? playbackFailure('RECORDING_PLAYBACK_FAILED'));
      return;
    }
    _applyNativeSnapshot(result.value!);
  }

  AppFailure? _validate(RecordingLibraryItem item) {
    if (!_isSafeRecordingId(item.recordingId) || item.appPrivateUri == null) {
      return playbackFailure('RECORDING_PLAYBACK_FILE_MISSING');
    }
    if (item.status == RecordingLibraryStatus.recycled ||
        item.localFileState == RecordingLocalFileState.part ||
        item.localFileState == RecordingLocalFileState.none) {
      return playbackFailure('RECORDING_PLAYBACK_FILE_NOT_READY');
    }
    if (item.localFileState == RecordingLocalFileState.missing) {
      return playbackFailure('RECORDING_PLAYBACK_FILE_MISSING');
    }
    if (item.format == RecordingLibraryFormat.unknown) {
      return playbackFailure('RECORDING_PLAYBACK_UNSUPPORTED_FORMAT');
    }
    return null;
  }

  void _applyNativeSnapshot(NativePlaybackSnapshot snapshot) {
    if (_disposed) return;
    final item = _state.item;
    if (snapshot.recordingId != null &&
        snapshot.recordingId != item?.recordingId) {
      return;
    }
    final status = _mapNativeStatus(snapshot.status);
    final next = _state.copyWith(
      status: status,
      position: _clampPosition(snapshot.position, snapshot.duration),
      duration: snapshot.duration > Duration.zero
          ? snapshot.duration
          : _state.duration,
      rate: snapshot.rate,
      lastErrorCode: snapshot.errorCode,
      clearError:
          snapshot.errorCode == null &&
          status != RecordingPlaybackControllerStatus.failed,
    );
    _setState(next);
    _persistCurrentPosition();
  }

  void _fail(AppFailure failure, {RecordingLibraryItem? item}) {
    _setState(
      _state.copyWith(
        status: RecordingPlaybackControllerStatus.failed,
        item: item,
        lastErrorCode: failure.code,
      ),
    );
  }

  void _persistCurrentPosition({bool force = false}) {
    final current = _state;
    final id = current.recordingId;
    if (id == null) return;
    if (current.status == RecordingPlaybackControllerStatus.completed) {
      _positionStore.clear(id);
      _lastPersistedRecordingId = id;
      _lastPersistedSeconds = 0;
      return;
    }
    if (current.status != RecordingPlaybackControllerStatus.playing &&
        current.status != RecordingPlaybackControllerStatus.paused &&
        current.status != RecordingPlaybackControllerStatus.ready &&
        current.status != RecordingPlaybackControllerStatus.released) {
      return;
    }
    final seconds = current.position.inSeconds;
    final sameRecording = _lastPersistedRecordingId == id;
    if (!force &&
        sameRecording &&
        (seconds - _lastPersistedSeconds).abs() < 2) {
      return;
    }
    _positionStore.save(recordingId: id, position: current.position);
    _lastPersistedRecordingId = id;
    _lastPersistedSeconds = seconds;
  }

  void _setState(RecordingPlaybackState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _persistCurrentPosition(force: true);
    _disposed = true;
    unawaited(_subscription.cancel());
    unawaited(_playbackPort.dispose());
    super.dispose();
  }
}

RecordingPlaybackControllerStatus _mapNativeStatus(
  NativePlaybackStatus status,
) {
  return switch (status) {
    NativePlaybackStatus.idle => RecordingPlaybackControllerStatus.idle,
    NativePlaybackStatus.loading => RecordingPlaybackControllerStatus.loading,
    NativePlaybackStatus.ready => RecordingPlaybackControllerStatus.ready,
    NativePlaybackStatus.playing => RecordingPlaybackControllerStatus.playing,
    NativePlaybackStatus.paused => RecordingPlaybackControllerStatus.paused,
    NativePlaybackStatus.completed =>
      RecordingPlaybackControllerStatus.completed,
    NativePlaybackStatus.failed => RecordingPlaybackControllerStatus.failed,
    NativePlaybackStatus.released => RecordingPlaybackControllerStatus.released,
  };
}

Duration _clampPosition(Duration position, Duration duration) {
  if (position.isNegative) return Duration.zero;
  return duration > Duration.zero && position > duration ? duration : position;
}

bool _isSafeRecordingId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value.trim());
}
