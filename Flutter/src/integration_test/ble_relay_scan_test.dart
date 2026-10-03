import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real simulator relay scans recording-card advertisements',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card');
      final response = await channel.invokeMapMethod<String, Object?>(
        'scanDevices',
      );
      final rows = response?['devices'] as List<Object?>?;
      expect(rows, isNotNull);
      expect(
        rows,
        isNotEmpty,
        reason: 'Keep a recording card powered on near the Mac for this test.',
      );
      debugPrint(
        '[BLE relay hardware test] qualified candidates=${rows!.length}',
      );
      await channel.invokeMethod<Object?>('cancelDiscovery');
    },
    skip: !const bool.fromEnvironment('BLE_RELAY_HARDWARE_TEST'),
  );
}
