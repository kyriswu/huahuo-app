import 'dart:async';

import 'performance_snapshot.dart';

enum MemoryPressureLevel { normal, warning, critical }

final class MemoryPressureObservation {
  const MemoryPressureObservation({
    required this.level,
    required this.observedAt,
  });

  final MemoryPressureLevel level;
  final DateTime observedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'level': level.name,
    'observedAt': observedAt.toUtc().toIso8601String(),
  };
}

abstract interface class MemoryPressurePort {
  MemoryPressureObservation get current;
  Stream<MemoryPressureObservation> get changes;
  void dispose();
}

final class NoopMemoryPressurePort implements MemoryPressurePort {
  NoopMemoryPressurePort({DateTime? observedAt})
    : _current = MemoryPressureObservation(
        level: MemoryPressureLevel.normal,
        observedAt: (observedAt ?? DateTime.now()).toUtc(),
      );

  final MemoryPressureObservation _current;

  @override
  MemoryPressureObservation get current => _current;

  @override
  Stream<MemoryPressureObservation> get changes =>
      const Stream<MemoryPressureObservation>.empty();

  @override
  void dispose() {}
}

final class InMemoryMemoryPressurePort implements MemoryPressurePort {
  InMemoryMemoryPressurePort({
    MemoryPressureLevel initialLevel = MemoryPressureLevel.normal,
    DateTime Function()? now,
    int capacity = 16,
  }) : _now = now ?? DateTime.now,
       _history = BoundedMetricBuffer<MemoryPressureObservation>(
         capacity: capacity,
       ) {
    _current = MemoryPressureObservation(
      level: initialLevel,
      observedAt: _now().toUtc(),
    );
    _history.add(_current);
  }

  final DateTime Function() _now;
  final BoundedMetricBuffer<MemoryPressureObservation> _history;
  final StreamController<MemoryPressureObservation> _controller =
      StreamController<MemoryPressureObservation>.broadcast(sync: true);
  late MemoryPressureObservation _current;
  bool _disposed = false;

  @override
  MemoryPressureObservation get current => _current;

  @override
  Stream<MemoryPressureObservation> get changes => _controller.stream;

  int get retainedObservationCount => _history.length;

  void update(MemoryPressureLevel level) {
    if (_disposed) throw StateError('MemoryPressurePort is disposed');
    if (level == _current.level) return;
    _current = MemoryPressureObservation(
      level: level,
      observedAt: _now().toUtc(),
    );
    _history.add(_current);
    _controller.add(_current);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.close();
  }
}
