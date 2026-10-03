import 'dart:async';

import 'package:flutter/services.dart';

import 'thermal_state_port.dart';

const _defaultMethodChannel = MethodChannel('huahuoai/runtime_performance');
const _defaultEventChannel = EventChannel(
  'huahuoai/runtime_performance/events',
);

final class PlatformThermalStatePort implements ThermalStatePort {
  PlatformThermalStatePort({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    DateTime Function()? now,
  }) : _methodChannel = methodChannel ?? _defaultMethodChannel,
       _eventChannel = eventChannel ?? _defaultEventChannel,
       _now = now ?? DateTime.now,
       _current = ThermalStateObservation(
         thermalLevel: ThermalLevel.unknown,
         powerClass: PowerClass.normal,
         observedAt: (now ?? DateTime.now)().toUtc(),
       ) {
    unawaited(_activate());
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final DateTime Function() _now;
  final StreamController<ThermalStateObservation> _controller =
      StreamController<ThermalStateObservation>.broadcast(sync: true);
  StreamSubscription<Object?>? _subscription;
  ThermalStateObservation _current;
  var _disposed = false;

  @override
  ThermalStateObservation get current => _current;

  @override
  Stream<ThermalStateObservation> get changes => _controller.stream;

  Future<void> _activate() async {
    try {
      final value = await _methodChannel.invokeMethod<Object?>('getState');
      if (_disposed) return;
      _accept(value);
      _subscription = _eventChannel.receiveBroadcastStream().listen(
        _accept,
        onError: (_) {},
      );
    } on Object {
      // Unsupported platforms keep the safe unknown observation.
    }
  }

  void _accept(Object? value) {
    if (_disposed) return;
    final next = thermalObservationFromPlatform(value, now: _now);
    if (next == null ||
        (next.thermalLevel == _current.thermalLevel &&
            next.powerClass == _current.powerClass)) {
      return;
    }
    _current = next;
    _controller.add(next);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    unawaited(_controller.close());
  }
}

ThermalStateObservation? thermalObservationFromPlatform(
  Object? value, {
  DateTime Function()? now,
}) {
  if (value is! Map) return null;
  final thermalToken = value['thermal'];
  final lowPower = value['lowPower'];
  if (thermalToken is! String || lowPower is! bool) return null;
  final thermalLevel = switch (thermalToken) {
    'nominal' => ThermalLevel.nominal,
    'fair' => ThermalLevel.fair,
    'serious' => ThermalLevel.serious,
    'critical' => ThermalLevel.critical,
    'unknown' => ThermalLevel.unknown,
    _ => null,
  };
  if (thermalLevel == null) return null;
  return ThermalStateObservation(
    thermalLevel: thermalLevel,
    powerClass: lowPower ? PowerClass.lowPower : PowerClass.normal,
    observedAt: (now ?? DateTime.now)().toUtc(),
  );
}
