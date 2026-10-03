import 'dart:io';

import 'package:flutter/material.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:window_manager/window_manager.dart';

import 'app/desktop_app.dart';
import 'app/desktop_services.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureNativeWindow();
  runApp(
    HuahuoDesktopApp(
      services: DesktopServices.fromEnvironment(),
      incomingDocumentPaths: _existingFileArguments(arguments),
    ),
  );
}

List<String> _existingFileArguments(List<String> arguments) =>
    List<String>.unmodifiable(
      arguments
          .map((argument) => argument.trim())
          .where((argument) => argument.isNotEmpty && File(argument).isAbsolute)
          .where((argument) => FileSystemEntity.isFileSync(argument))
          .toSet(),
    );

Future<void> _configureNativeWindow() async {
  if (!Platform.isWindows && !Platform.isMacOS) return;
  if (Platform.isMacOS) {
    await WindowManipulator.initialize();
  }
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 760),
      minimumSize: Size(1040, 680),
      center: true,
      // A transparent Windows surface combined with Mica/Acrylic is unstable
      // on the current Windows compositor. Use a stable startup surface; the
      // Flutter shell supplies the app's quieter internal translucency.
      backgroundColor: Color(0xFFF7F8F7),
      skipTaskbar: false,
      title: '花火 AI',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    ),
  );
  if (Platform.isMacOS) {
    await _applyMacNativeMaterial();
  }
  await windowManager.show();
  await windowManager.focus();
}

Future<void> _applyMacNativeMaterial() async {
  await WindowManipulator.enableFullSizeContentView();
  await WindowManipulator.makeTitlebarTransparent();
  await WindowManipulator.hideCloseButton();
  await WindowManipulator.hideMiniaturizeButton();
  await WindowManipulator.hideZoomButton();
  await WindowManipulator.setMaterial(NSVisualEffectViewMaterial.sidebar);
}
