import 'dart:async';

import 'package:characters/characters.dart';

/// Locally reveals an already-safe Agent draft without changing its text.
///
/// The server remains responsible for the final message. This buffer only
/// controls how quickly a public draft reaches the visible Assistant message.
final class ChatStreamRevealBuffer {
  ChatStreamRevealBuffer({
    required this.onReveal,
    String initialText = '',
    this.normalDelay = const Duration(milliseconds: 33),
    this.moderateDelay = const Duration(milliseconds: 33),
    this.catchUpDelay = const Duration(milliseconds: 33),
    this.coalesceUpdates = true,
  }) : _targetText = initialText,
       _target = initialText.characters.toList(growable: false),
       _visibleCount = initialText.characters.length,
       _visibleText = initialText;

  static const _normalBacklogLimit = 24;
  static const _moderateBacklogLimit = 96;
  static const _targetCatchUpBacklog = 24;

  final void Function(String text) onReveal;
  final Duration normalDelay;
  final Duration moderateDelay;
  final Duration catchUpDelay;
  final bool coalesceUpdates;
  String _targetText;
  List<String> _target;
  int _visibleCount;
  String _visibleText;
  Timer? _timer;
  bool _disposed = false;

  String get visibleText => _visibleText;

  String get targetText => _targetText;

  int get pendingGraphemeCount => _target.length - _visibleCount;

  void ingest(String text, {bool replace = false}) {
    if (_disposed) return;
    if (!replace && text.isEmpty) return;
    final previousVisibleText = _visibleText;

    if (replace) {
      final commonVisiblePrefix = _commonPrefixLength(
        previousVisibleText.characters,
        text.characters,
      );
      _targetText = text;
      _target = _targetText.characters.toList(growable: false);
      _visibleCount =
          commonVisiblePrefix == 0 &&
              previousVisibleText.isNotEmpty &&
              _target.isNotEmpty
          ? _stepFor(_target.length).clamp(1, _target.length).toInt()
          : commonVisiblePrefix;
      _visibleText = _target.take(_visibleCount).join();
    } else {
      _targetText = '$_targetText$text';
      // A combining mark or ZWJ sequence can cross a transport boundary.
      // Re-segmenting the full raw target keeps the visible draft valid.
      _target = _targetText.characters.toList(growable: false);
      _visibleCount = _visibleCount.clamp(0, _target.length).toInt();
      _visibleText = _target.take(_visibleCount).join();
    }

    if (!coalesceUpdates) {
      _timer?.cancel();
      _timer = null;
      _visibleCount = _target.length;
      _visibleText = _targetText;
      if (_visibleText != previousVisibleText) onReveal(_visibleText);
      return;
    }

    if (_visibleText != previousVisibleText) {
      onReveal(_visibleText);
    }

    _scheduleNextReveal();
  }

  /// Immediately exposes the current target before its owner stops tracking.
  void flush() {
    if (_disposed || _visibleCount >= _target.length) return;
    _timer?.cancel();
    _timer = null;
    _visibleCount = _target.length;
    _visibleText = _targetText;
    onReveal(_visibleText);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNextReveal() {
    if (_disposed || _timer != null || _visibleCount >= _target.length) {
      return;
    }
    _timer = Timer(_delayFor(pendingGraphemeCount), _revealTick);
  }

  void _revealTick() {
    _timer = null;
    if (_disposed || _visibleCount >= _target.length) return;
    final nextVisibleCount = (_visibleCount + _stepFor(pendingGraphemeCount))
        .clamp(0, _target.length)
        .toInt();
    if (nextVisibleCount == _visibleCount) return;
    final newlyVisible = _target
        .sublist(_visibleCount, nextVisibleCount)
        .join();
    _visibleCount = nextVisibleCount;
    _visibleText = '$_visibleText$newlyVisible';
    onReveal(_visibleText);
    _scheduleNextReveal();
  }

  Duration _delayFor(int pending) {
    if (pending <= _normalBacklogLimit) return normalDelay;
    if (pending <= _moderateBacklogLimit) return moderateDelay;
    return catchUpDelay;
  }

  int _stepFor(int pending) {
    if (pending <= _normalBacklogLimit) return 1;
    if (pending <= _moderateBacklogLimit) return 2;
    final excess = pending - _targetCatchUpBacklog;
    // Drain a large queue to normal cadence in roughly three quarters second.
    return (excess / 48).ceil().clamp(2, 16).toInt();
  }
}

int _commonPrefixLength(Iterable<String> left, Iterable<String> right) {
  final leftIterator = left.iterator;
  final rightIterator = right.iterator;
  var length = 0;
  while (leftIterator.moveNext() && rightIterator.moveNext()) {
    if (leftIterator.current != rightIterator.current) break;
    length += 1;
  }
  return length;
}
