import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/core/performance/platform_thermal_state_port.dart';
import 'package:huahuoai_app/core/performance/thermal_state_port.dart';

void main() {
  final observedAt = DateTime.utc(2026, 8, 31, 10);

  test('maps native thermal and low-power tokens', () {
    final observation = thermalObservationFromPlatform(<String, Object?>{
      'thermal': 'serious',
      'lowPower': true,
    }, now: () => observedAt);

    expect(observation?.thermalLevel, ThermalLevel.serious);
    expect(observation?.powerClass, PowerClass.lowPower);
    expect(observation?.observedAt, observedAt);
  });

  test('rejects malformed or unknown native payloads', () {
    expect(thermalObservationFromPlatform(null), isNull);
    expect(
      thermalObservationFromPlatform(<String, Object?>{
        'thermal': 'hot',
        'lowPower': false,
      }),
      isNull,
    );
    expect(
      thermalObservationFromPlatform(<String, Object?>{
        'thermal': 'nominal',
        'lowPower': 'yes',
      }),
      isNull,
    );
  });

  test('thermal limitation takes precedence over low-power mode', () {
    ThermalStateObservation observation(
      ThermalLevel thermal,
      PowerClass power,
    ) => ThermalStateObservation(
      thermalLevel: thermal,
      powerClass: power,
      observedAt: observedAt,
    );

    expect(
      appPowerClassForThermalObservation(
        observation(ThermalLevel.critical, PowerClass.lowPower),
      ),
      AppPowerClass.thermalLimited,
    );
    expect(
      appPowerClassForThermalObservation(
        observation(ThermalLevel.nominal, PowerClass.lowPower),
      ),
      AppPowerClass.lowPower,
    );
    expect(
      appPowerClassForThermalObservation(
        observation(ThermalLevel.fair, PowerClass.normal),
      ),
      AppPowerClass.normal,
    );
  });
}
