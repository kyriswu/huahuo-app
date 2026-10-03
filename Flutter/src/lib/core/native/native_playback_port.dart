import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../api/api_envelope.dart';
import '../storage/private_recording_path_resolver.dart';

enum NativePlaybackStatus {
  idle,
  loading,
  ready,
  playing,
  paused,
  completed,
  failed,
  released,
}

final class NativePlaybackSnapshot {
  const NativePlaybackSnapshot({
    required this.status,
    this.recordingId,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.rate = 1,
    this.errorCode,
  });

  const NativePlaybackSnapshot.idle()
    : status = NativePlaybackStatus.idle,
      recordingId = null,
      position = Duration.zero,
      duration = Duration.zero,
      rate = 1,
      errorCode = null;

  final NativePlaybackStatus status;
  final String? recordingId;
  final Duration position;
  final Duration duration;
  final double rate;
  final String? errorCode;

  NativePlaybackSnapshot copyWith({
    NativePlaybackStatus? status,
    String? recordingId,
    Duration? position,
    Duration? duration,
    double? rate,
    String? errorCode,
    bool clearRecordingId = false,
    bool clearErrorCode = false,
  }) {
    return NativePlaybackSnapshot(
      status: status ?? this.status,
      recordingId: clearRecordingId ? null : recordingId ?? this.recordingId,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      rate: rate ?? this.rate,
      errorCode: clearErrorCode ? null : errorCode ?? this.errorCode,
    );
  }
}

final class NativePlaybackResult<T> {
  const NativePlaybackResult._({required this.ok, this.value, this.error});

  factory NativePlaybackResult.success(T value) {
    return NativePlaybackResult<T>._(ok: true, value: value);
  }

  factory NativePlaybackResult.failure(AppFailure error) {
    return NativePlaybackResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

abstract interface class NativePlaybackPort {
  Stream<NativePlaybackSnapshot> get snapshots;

  Future<NativePlaybackResult<NativePlaybackSnapshot>> load({
    required String recordingId,
    required String appPrivateUri,
    Duration knownDuration = Duration.zero,
  });

  Future<NativePlaybackResult<NativePlaybackSnapshot>> play();

  Future<NativePlaybackResult<NativePlaybackSnapshot>> pause();

  Future<NativePlaybackResult<NativePlaybackSnapshot>> seekTo(Duration value);

  Future<NativePlaybackResult<NativePlaybackSnapshot>> setRate(double value);

  Future<NativePlaybackResult<NativePlaybackSnapshot>> release();

  Future<void> dispose();
}

typedef PrivateAudioPlaybackFileResolver =
    Future<File?> Function(String appPrivateUri);

abstract interface class PlaybackAudioSession {
  Future<void> configure();

  Future<void> activate();

  Future<void> deactivate();
}

const rnPlaybackAudioSessionConfiguration = AudioSessionConfiguration(
  avAudioSessionCategory: AVAudioSessionCategory.playback,
  avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
  avAudioSessionMode: AVAudioSessionMode.defaultMode,
  avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
  androidAudioAttributes: AndroidAudioAttributes(
    contentType: AndroidAudioContentType.speech,
    usage: AndroidAudioUsage.media,
  ),
  androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
  androidWillPauseWhenDucked: true,
);

final class RnPlaybackAudioSession implements PlaybackAudioSession {
  AudioSession? _session;
  bool _configured = false;

  @override
  Future<void> configure() async {
    if (_configured) return;
    final session = await AudioSession.instance;
    await session.configure(rnPlaybackAudioSessionConfiguration);
    _session = session;
    _configured = true;
  }

  @override
  Future<void> activate() async {
    await configure();
    await _session!.setActive(true);
  }

  @override
  Future<void> deactivate() async {
    if (!_configured || _session == null) return;
    await _session!.setActive(
      false,
      avAudioSessionSetActiveOptions:
          AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
    );
  }
}

/// Bridges opaque app-private recording references to `just_audio`.
const nativePlaybackPositionMinPeriod = Duration(milliseconds: 100);
const nativePlaybackPositionMaxPeriod = Duration(milliseconds: 250);

final class JustAudioPlaybackPort implements NativePlaybackPort {
  JustAudioPlaybackPort({
    AudioPlayer? player,
    PrivateAudioPlaybackFileResolver? resolvePrivateAudioFile,
    PlaybackAudioSession? audioSession,
  }) : _player = player ?? AudioPlayer(),
       _resolvePrivateAudioFile =
           resolvePrivateAudioFile ??
           PrivateRecordingPathResolver().resolveFile,
       _audioSession = audioSession ?? RnPlaybackAudioSession() {
    _subscriptions = <StreamSubscription<dynamic>>[
      _player
          .createPositionStream(
            minPeriod: nativePlaybackPositionMinPeriod,
            maxPeriod: nativePlaybackPositionMaxPeriod,
          )
          .listen(_onPosition),
      _player.durationStream.listen(_onDuration),
      _player.playerStateStream.listen(_onPlayerState),
    ];
  }

  final AudioPlayer _player;
  final PrivateAudioPlaybackFileResolver _resolvePrivateAudioFile;
  final PlaybackAudioSession _audioSession;
  final StreamController<NativePlaybackSnapshot> _snapshots =
      StreamController<NativePlaybackSnapshot>.broadcast();
  late final List<StreamSubscription<dynamic>> _subscriptions;
  NativePlaybackSnapshot _snapshot = const NativePlaybackSnapshot.idle();
  Directory? _temporaryPlaybackDirectory;
  bool _disposed = false;

  @override
  Stream<NativePlaybackSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> load({
    required String recordingId,
    required String appPrivateUri,
    Duration knownDuration = Duration.zero,
  }) async {
    final id = _safeRecordingId(recordingId);
    if (id == null) {
      return _failure('RECORDING_PLAYBACK_FILE_MISSING');
    }
    if (!_isSafeAppPrivateAudioUri(appPrivateUri)) {
      return _failure('RECORDING_PLAYBACK_FILE_NOT_READY');
    }
    if (_disposed) {
      return _failure('NATIVE_PLAYBACK_DRIVER_UNAVAILABLE');
    }

    _emit(
      NativePlaybackSnapshot(
        status: NativePlaybackStatus.loading,
        recordingId: id,
        duration: _safeDuration(knownDuration),
        rate: _snapshot.rate,
      ),
    );
    try {
      await _deleteTemporaryPlaybackDirectory();
      final file = await _resolvePrivateAudioFile(appPrivateUri);
      if (file == null || !await file.exists()) {
        return _failure('RECORDING_PLAYBACK_FILE_MISSING');
      }
      final playableFile = await _preparePlayableFile(file);
      await _audioSession.configure();
      await _player.setVolume(1);
      final duration = await _player.setFilePath(playableFile.path);
      await _player.setSpeed(1);
      final resolvedDuration = _safeDuration(duration ?? knownDuration);
      final snapshot = NativePlaybackSnapshot(
        status: NativePlaybackStatus.ready,
        recordingId: id,
        duration: resolvedDuration,
        rate: 1,
      );
      _emit(snapshot);
      return NativePlaybackResult<NativePlaybackSnapshot>.success(snapshot);
    } catch (error) {
      await _deleteTemporaryPlaybackDirectory();
      return _failure(_mapPlaybackErrorCode(error));
    }
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> pause() async {
    if (!_hasLoadedRecording) return _failure('RECORDING_PLAYBACK_NOT_READY');
    try {
      await _player.pause();
      final snapshot = _snapshot.copyWith(
        status: NativePlaybackStatus.paused,
        position: _clampPosition(_player.position),
      );
      _emit(snapshot);
      return NativePlaybackResult<NativePlaybackSnapshot>.success(snapshot);
    } catch (error) {
      return _failure(_mapPlaybackErrorCode(error));
    }
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> play() async {
    if (!_hasLoadedRecording) return _failure('RECORDING_PLAYBACK_NOT_READY');
    try {
      await _audioSession.activate();
      if (_snapshot.status == NativePlaybackStatus.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
      final snapshot = _snapshot.copyWith(
        status: NativePlaybackStatus.playing,
        position: _clampPosition(_player.position),
        clearErrorCode: true,
      );
      _emit(snapshot);
      return NativePlaybackResult<NativePlaybackSnapshot>.success(snapshot);
    } catch (error) {
      return _failure(_mapPlaybackErrorCode(error));
    }
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> release() async {
    if (_disposed) return _failure('NATIVE_PLAYBACK_DRIVER_UNAVAILABLE');
    try {
      await _player.stop();
      await _audioSession.deactivate();
      await _deleteTemporaryPlaybackDirectory();
      final snapshot = _snapshot.copyWith(
        status: NativePlaybackStatus.released,
        position: Duration.zero,
        clearRecordingId: true,
        clearErrorCode: true,
      );
      _emit(snapshot);
      return NativePlaybackResult<NativePlaybackSnapshot>.success(snapshot);
    } catch (error) {
      await _deleteTemporaryPlaybackDirectory();
      return _failure(_mapPlaybackErrorCode(error));
    }
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> seekTo(
    Duration value,
  ) async {
    if (!_hasLoadedRecording) return _failure('RECORDING_PLAYBACK_NOT_READY');
    try {
      final position = _clampPosition(value);
      await _player.seek(position);
      final snapshot = _snapshot.copyWith(position: position);
      _emit(snapshot);
      return NativePlaybackResult<NativePlaybackSnapshot>.success(snapshot);
    } catch (error) {
      return _failure(_mapPlaybackErrorCode(error));
    }
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> setRate(
    double value,
  ) async {
    if (!_hasLoadedRecording) return _failure('RECORDING_PLAYBACK_NOT_READY');
    if (!_supportedRates.contains(value)) {
      return _failure('RECORDING_PLAYBACK_RATE_UNSUPPORTED');
    }
    try {
      await _player.setSpeed(value);
      final snapshot = _snapshot.copyWith(rate: value);
      _emit(snapshot);
      return NativePlaybackResult<NativePlaybackSnapshot>.success(snapshot);
    } catch (error) {
      return _failure(_mapPlaybackErrorCode(error));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _audioSession.deactivate();
    await _deleteTemporaryPlaybackDirectory();
    await _snapshots.close();
  }

  Future<File> _preparePlayableFile(File source) async {
    final input = await source.open();
    List<int> header;
    try {
      header = await input.read(12);
    } finally {
      await input.close();
    }
    if (!isAdtsAacAudioHeader(header)) return source;

    final directory = await Directory.systemTemp.createTemp(
      'huahuo-aac-playback-',
    );
    final target = File('${directory.path}/recording.aac');
    try {
      await source.openRead().pipe(target.openWrite());
      if (!await target.exists() || await target.length() <= 0) {
        throw const FileSystemException('AAC playback lease is empty');
      }
      _temporaryPlaybackDirectory = directory;
      return target;
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _deleteTemporaryPlaybackDirectory() async {
    final directory = _temporaryPlaybackDirectory;
    _temporaryPlaybackDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  bool get _hasLoadedRecording =>
      !_disposed &&
      _snapshot.recordingId != null &&
      _snapshot.status != NativePlaybackStatus.idle &&
      _snapshot.status != NativePlaybackStatus.failed &&
      _snapshot.status != NativePlaybackStatus.released;

  void _onDuration(Duration? duration) {
    if (_disposed || duration == null || duration.isNegative) return;
    _emit(_snapshot.copyWith(duration: duration));
  }

  void _onPlayerState(PlayerState playerState) {
    if (_disposed || _snapshot.recordingId == null) return;
    final status = switch (playerState.processingState) {
      ProcessingState.loading ||
      ProcessingState.buffering => NativePlaybackStatus.loading,
      ProcessingState.completed => NativePlaybackStatus.completed,
      ProcessingState.idle => _snapshot.status,
      ProcessingState.ready =>
        playerState.playing
            ? NativePlaybackStatus.playing
            : _snapshot.status == NativePlaybackStatus.ready
            ? NativePlaybackStatus.ready
            : NativePlaybackStatus.paused,
    };
    _emit(
      _snapshot.copyWith(
        status: status,
        position: _clampPosition(_player.position),
      ),
    );
  }

  void _onPosition(Duration position) {
    if (_disposed || _snapshot.recordingId == null) return;
    _emit(_snapshot.copyWith(position: _clampPosition(position)));
  }

  Duration _clampPosition(Duration value) {
    if (value.isNegative) return Duration.zero;
    final duration = _snapshot.duration;
    return duration > Duration.zero && value > duration ? duration : value;
  }

  void _emit(NativePlaybackSnapshot value) {
    _snapshot = value;
    if (!_disposed && !_snapshots.isClosed) _snapshots.add(value);
  }

  NativePlaybackResult<NativePlaybackSnapshot> _failure(String code) {
    final snapshot = _snapshot.copyWith(
      status: NativePlaybackStatus.failed,
      errorCode: code,
    );
    _emit(snapshot);
    return NativePlaybackResult<NativePlaybackSnapshot>.failure(
      playbackFailure(code),
    );
  }
}

bool isAdtsAacAudioHeader(List<int> header) {
  return header.length >= 2 && header[0] == 0xff && (header[1] & 0xf6) == 0xf0;
}

final class UnavailableNativePlaybackPort implements NativePlaybackPort {
  const UnavailableNativePlaybackPort();

  @override
  Stream<NativePlaybackSnapshot> get snapshots =>
      const Stream<NativePlaybackSnapshot>.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> load({
    required String recordingId,
    required String appPrivateUri,
    Duration knownDuration = Duration.zero,
  }) async => NativePlaybackResult<NativePlaybackSnapshot>.failure(
    playbackFailure('NATIVE_PLAYBACK_DRIVER_UNAVAILABLE'),
  );

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> pause() async =>
      NativePlaybackResult<NativePlaybackSnapshot>.failure(
        playbackFailure('NATIVE_PLAYBACK_DRIVER_UNAVAILABLE'),
      );

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> play() async =>
      NativePlaybackResult<NativePlaybackSnapshot>.failure(
        playbackFailure('NATIVE_PLAYBACK_DRIVER_UNAVAILABLE'),
      );

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> release() async =>
      NativePlaybackResult<NativePlaybackSnapshot>.failure(
        playbackFailure('NATIVE_PLAYBACK_DRIVER_UNAVAILABLE'),
      );

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> seekTo(
    Duration value,
  ) async => NativePlaybackResult<NativePlaybackSnapshot>.failure(
    playbackFailure('NATIVE_PLAYBACK_DRIVER_UNAVAILABLE'),
  );

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> setRate(
    double value,
  ) async => NativePlaybackResult<NativePlaybackSnapshot>.failure(
    playbackFailure('NATIVE_PLAYBACK_DRIVER_UNAVAILABLE'),
  );
}

AppFailure playbackFailure(String code) {
  final retryable =
      code != 'RECORDING_PLAYBACK_UNSUPPORTED_FORMAT' &&
      code != 'RECORDING_PLAYBACK_RATE_UNSUPPORTED';
  return AppFailure(
    code: code,
    category: AppFailureCategory.storage,
    message: 'Recording playback failed',
    userMessageKey: 'recording.playback.error.$code',
    isRetryable: retryable,
    recoveryActions: retryable
        ? const <String>['retry']
        : const <String>['none'],
  );
}

bool _isSafeAppPrivateAudioUri(String value) {
  return isSafeAppPrivateRecordingUri(value);
}

String? _safeRecordingId(String value) {
  final text = value.trim();
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(text)
      ? text
      : null;
}

Duration _safeDuration(Duration value) {
  return value.isNegative ? Duration.zero : value;
}

String _mapPlaybackErrorCode(Object error) {
  final text = error.toString();
  if (RegExp(
    r'missing|not found|enoent|file_missing',
    caseSensitive: false,
  ).hasMatch(text)) {
    return 'RECORDING_PLAYBACK_FILE_MISSING';
  }
  if (RegExp(r'part|not_ready', caseSensitive: false).hasMatch(text)) {
    return 'RECORDING_PLAYBACK_FILE_NOT_READY';
  }
  if (RegExp(
    r'unsupported|codec|format',
    caseSensitive: false,
  ).hasMatch(text)) {
    return 'RECORDING_PLAYBACK_UNSUPPORTED_FORMAT';
  }
  if (RegExp(
    r'permission|denied|unreadable',
    caseSensitive: false,
  ).hasMatch(text)) {
    return 'RECORDING_PLAYBACK_STORAGE_UNREADABLE';
  }
  if (RegExp(r'interrupt|audio focus', caseSensitive: false).hasMatch(text)) {
    return 'RECORDING_PLAYBACK_INTERRUPTED';
  }
  return 'RECORDING_PLAYBACK_FAILED';
}

final Set<double> _supportedRates = <double>{1, 1.25, 1.5, 2};
