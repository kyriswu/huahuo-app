import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

enum SphereGraphMotionState {
  inactive,
  suspended,
  idle,
  automatic,
  interacting,
  cooldown,
}

final class SphereGraphMotionController extends ChangeNotifier {
  SphereGraphMotionController({
    required this.onRotate,
    this.resumeDelay = const Duration(seconds: 2),
    this.automaticDuration = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ValueChanged<double> onRotate;
  final Duration resumeDelay;
  final Duration automaticDuration;
  final DateTime Function() _now;
  final Set<int> _pointers = {};
  Timer? _resumeTimer;
  Timer? _idleTimer;
  DateTime? _automaticDeadline;
  bool _idleExpired = false;
  Timer? _frameTimer;
  int? _frameCallbackId;
  int _frameGeneration = 0;
  SphereGraphMotionState _state = SphereGraphMotionState.inactive;
  bool _active = false;
  bool _suspended = false;
  bool _disposed = false;
  int _nodeCount = 72;
  int _maximumFrameRate = 30;
  Duration? _lastFrame;
  double _rampElapsed = 0;

  SphereGraphMotionState get state => _state;
  bool get isTicking =>
      !_disposed && _state == SphereGraphMotionState.automatic;

  Duration get _frameInterval => Duration(
    microseconds:
        (Duration.microsecondsPerSecond /
                math.min(
                  _maximumFrameRate,
                  _nodeCount > 5000
                      ? 15
                      : _nodeCount > 1500
                      ? 20
                      : 30,
                ))
            .ceil(),
  );

  void configure({
    required bool active,
    required bool suspended,
    int? nodeCount,
    int maximumFrameRate = 30,
  }) {
    if (_disposed) return;
    final previousInterval = _frameInterval;
    _nodeCount = nodeCount ?? _nodeCount;
    _maximumFrameRate = maximumFrameRate.clamp(1, 30);
    suspended = suspended || maximumFrameRate <= 0;
    if (_active == active && _suspended == suspended) {
      if (isTicking && _frameInterval != previousInterval) {
        _cancelFrames();
        _scheduleNextFrame();
      }
      return;
    }
    if (active && !_active) _resetIdleBudget();
    _active = active;
    _suspended = suspended;
    _cancelResume();
    if (!active) {
      _pointers.clear();
      _setState(SphereGraphMotionState.inactive);
    } else if (_pointers.isNotEmpty) {
      _setState(SphereGraphMotionState.interacting);
    } else {
      _setState(
        suspended
            ? SphereGraphMotionState.suspended
            : SphereGraphMotionState.automatic,
      );
    }
  }

  void pointerDown(int pointer) {
    if (_disposed || !_active) return;
    _pointers.add(pointer);
    _cancelResume();
    _setState(SphereGraphMotionState.interacting);
  }

  void pointerUp(int pointer) {
    if (_disposed || !_pointers.remove(pointer) || _pointers.isNotEmpty) return;
    _resetIdleBudget();
    if (!_active || _suspended) {
      _setState(
        _active
            ? SphereGraphMotionState.suspended
            : SphereGraphMotionState.inactive,
      );
      return;
    }
    _setState(SphereGraphMotionState.cooldown);
    _cancelResume();
    _resumeTimer = Timer(resumeDelay, () {
      _resumeTimer = null;
      if (!_disposed && _active && !_suspended && _pointers.isEmpty) {
        _setState(SphereGraphMotionState.automatic);
      }
    });
  }

  void _setState(SphereGraphMotionState next) {
    if (_state == next) return;
    Duration? remaining;
    if (next == SphereGraphMotionState.automatic) {
      _automaticDeadline ??= _now().add(automaticDuration);
      remaining = _automaticDeadline!.difference(_now());
      if (_idleExpired || remaining <= Duration.zero) {
        _idleExpired = true;
        next = SphereGraphMotionState.idle;
      }
    }
    _state = next;
    _lastFrame = null;
    _rampElapsed = 0;
    _cancelFrames();
    _idleTimer?.cancel();
    _idleTimer = null;
    if (next == SphereGraphMotionState.automatic) {
      _idleTimer = Timer(remaining!, () {
        _idleExpired = true;
        _setState(SphereGraphMotionState.idle);
      });
      _requestFrame();
    }
    notifyListeners();
  }

  void _resetIdleBudget() {
    _automaticDeadline = null;
    _idleExpired = false;
  }

  void _requestFrame() {
    _frameTimer = null;
    if (!isTicking || _frameCallbackId != null) return;
    final generation = _frameGeneration;
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback((
      elapsed,
    ) {
      _frameCallbackId = null;
      if (!isTicking || generation != _frameGeneration) return;
      final previous = _lastFrame;
      _lastFrame = elapsed;
      if (previous != null) {
        final seconds =
            ((elapsed - previous).inMicroseconds /
                    Duration.microsecondsPerSecond)
                .clamp(0.0, .1);
        _rampElapsed += seconds;
        onRotate(.09 * seconds * math.min(1.0, _rampElapsed / .4));
      }
      if (isTicking && generation == _frameGeneration) _scheduleNextFrame();
    });
  }

  void _scheduleNextFrame() {
    _frameTimer?.cancel();
    _frameTimer = Timer(_frameInterval, _requestFrame);
  }

  void _cancelFrames() {
    _frameGeneration++;
    _frameTimer?.cancel();
    _frameTimer = null;
    final callbackId = _frameCallbackId;
    _frameCallbackId = null;
    if (callbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
    }
  }

  void _cancelResume() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _cancelResume();
    _pointers.clear();
    _cancelFrames();
    super.dispose();
  }
}
