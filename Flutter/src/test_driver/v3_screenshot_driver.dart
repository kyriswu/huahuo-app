import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver_extended.dart';

const _artifactsEnvironmentVariable = 'HUAHUO_V3_ARTIFACTS';
final _safeScreenshotName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');

Future<void> main() async {
  final driver = await FlutterDriver.connect(logCommunicationToFile: false);
  await integrationDriver(
    driver: driver,
    onScreenshot: _writeScreenshot,
    responseDataCallback: null,
  );
}

Future<bool> _writeScreenshot(
  String screenshotName,
  List<int> screenshotBytes, [
  Map<String, Object?>? args,
]) async {
  if (!_safeScreenshotName.hasMatch(screenshotName)) {
    stderr.writeln('Unsafe screenshot name: $screenshotName');
    return false;
  }

  final directory = Directory(
    Platform.environment[_artifactsEnvironmentVariable] ??
        '${Directory.systemTemp.path}/huahuoai-v3-artifacts',
  );
  await directory.create(recursive: true);
  final output = File('${directory.path}/$screenshotName.png');
  await output.writeAsBytes(screenshotBytes, flush: true);
  stdout.writeln('Wrote screenshot: ${output.path}');
  return true;
}
