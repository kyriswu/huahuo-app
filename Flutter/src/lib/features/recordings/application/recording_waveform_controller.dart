import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/native/voice_recorder_port.dart';

final class RecordingWaveformController extends ChangeNotifier
    implements ValueListenable<List<double>> {
  RecordingWaveformController({required this._recorder});

  static const sampleCount = 68;
  final VoiceRecorderPort _recorder;
  final List<double> _samples = List<double>.filled(sampleCount, 0);
  List<double>? _snapshot;
  int _nextIndex = 0;
  double _lastLevel = 0;
  bool _recording = false;
  bool _disposed = false;
  int _generation = 0;
  StreamSubscription<VoiceLevelSample>? _subscription;
  Future<void>? _cancellation;

  @override
  List<double> get value => _snapshot ??= List<double>.unmodifiable(
    List<double>.generate(
      sampleCount,
      (index) => _samples[(_nextIndex + index) % sampleCount],
      growable: false,
    ),
  );

  void start() {
    if (_disposed) return;
    _recording = true;
    _syncSubscription();
  }

  Future<void> stop() {
    if (_disposed) return _cancellation ?? Future<void>.value();
    _recording = false;
    final cancellation = _cancelSubscription();
    reset();
    return cancellation;
  }

  void reset() {
    if (_disposed) return;
    _clear();
    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _syncSubscription();
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_disposed) return;
    super.removeListener(listener);
    _syncSubscription();
  }

  void _syncSubscription() {
    if (_disposed) return;
    if (!_recording || !hasListeners) {
      unawaited(_cancelSubscription());
      if (!hasListeners) _clear();
      return;
    }
    if (_subscription != null || _cancellation != null) return;
    final generation = ++_generation;
    _subscription = _recorder.levelSamples.listen(
      (sample) {
        if (!_disposed && _recording && generation == _generation) {
          _accept(sample);
        }
      },
      onError: (Object _, StackTrace __) {
        if (!_disposed && generation == _generation) reset();
      },
    );
  }

  Future<void> _cancelSubscription() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription == null) return _cancellation ?? Future<void>.value();
    _generation++;
    return _cancellation = Future<void>.sync(subscription.cancel).then<void>(
      (_) => _finishCancellation(),
      onError: (Object _, StackTrace __) => _finishCancellation(),
    );
  }

  void _finishCancellation() {
    _cancellation = null;
    _syncSubscription();
  }

  void _accept(VoiceLevelSample sample) {
    final average = sample.average.isFinite
        ? sample.average.clamp(0.0, 1.0).toDouble()
        : 0.0;
    final peak = sample.peak.isFinite
        ? sample.peak.clamp(0.0, 1.0).toDouble()
        : 0.0;
    var target = average * .72 + peak * .28;
    if (target < .012) target = 0;
    _lastLevel =
        (target == 0
                ? _lastLevel * .62
                : target >= _lastLevel
                ? _lastLevel * .28 + target * .72
                : _lastLevel * .74 + target * .26)
            .clamp(0.0, 1.0);
    _samples[_nextIndex] = _lastLevel;
    _nextIndex = (_nextIndex + 1) % sampleCount;
    _snapshot = null;
    notifyListeners();
  }

  void _clear() {
    _samples.fillRange(0, sampleCount, 0);
    _nextIndex = 0;
    _lastLevel = 0;
    _snapshot = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _recording = false;
    unawaited(_cancelSubscription());
    super.dispose();
  }
}
