import 'dart:async';

import 'performance_snapshot.dart';

enum ThermalLevel { unknown, nominal, fair, serious, critical }

enum PowerClass { normal, lowPower }

final class ThermalStateObservation {
  const ThermalStateObservation({
    required this.thermalLevel,
    required this.powerClass,
    required this.observedAt,
  });

  final ThermalLevel thermalLevel;
  final PowerClass powerClass;
  final DateTime observedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'thermalLevel': thermalLevel.name,
    'powerClass': powerClass.name,
    'observedAt': observedAt.toUtc().toIso8601String(),
  };
}

abstract interface class ThermalStatePort {
  ThermalStateObservation get current;
  Stream<ThermalStateObservation> get changes;
  void dispose();
}

final class NoopThermalStatePort implements ThermalStatePort {
  NoopThermalStatePort({DateTime? observedAt})
    : _current = ThermalStateObservation(
        thermalLevel: ThermalLevel.unknown,
        powerClass: PowerClass.normal,
        observedAt: (observedAt ?? DateTime.now()).toUtc(),
      );

  final ThermalStateObservation _current;

  @override
  ThermalStateObservation get current => _current;

  @override
  Stream<ThermalStateObservation> get changes =>
      const Stream<ThermalStateObservation>.empty();

  @override
  void dispose() {}
}

final class InMemoryThermalStatePort implements ThermalStatePort {
  InMemoryThermalStatePort({
    ThermalLevel initialThermalLevel = ThermalLevel.unknown,
    PowerClass initialPowerClass = PowerClass.normal,
    DateTime Function()? now,
    int capacity = 16,
  }) : _now = now ?? DateTime.now,
       _history = BoundedMetricBuffer<ThermalStateObservation>(
         capacity: capacity,
       ) {
    _current = ThermalStateObservation(
      thermalLevel: initialThermalLevel,
      powerClass: initialPowerClass,
      observedAt: _now().toUtc(),
    );
    _history.add(_current);
  }

  final DateTime Function() _now;
  final BoundedMetricBuffer<ThermalStateObservation> _history;
  final StreamController<ThermalStateObservation> _controller =
      StreamController<ThermalStateObservation>.broadcast(sync: true);
  late ThermalStateObservation _current;
  bool _disposed = false;

  @override
  ThermalStateObservation get current => _current;

  @override
  Stream<ThermalStateObservation> get changes => _controller.stream;

  int get retainedObservationCount => _history.length;

  void update({required ThermalLevel thermalLevel, PowerClass? powerClass}) {
    if (_disposed) throw StateError('ThermalStatePort is disposed');
    final nextPowerClass = powerClass ?? _current.powerClass;
    if (thermalLevel == _current.thermalLevel &&
        nextPowerClass == _current.powerClass) {
      return;
    }
    _current = ThermalStateObservation(
      thermalLevel: thermalLevel,
      powerClass: nextPowerClass,
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
