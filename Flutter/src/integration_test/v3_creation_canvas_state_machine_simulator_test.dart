import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/features/ui_v3/v3_creation_canvas_page_test.dart' as scenarios;
import '../test/features/ui_v3/v3_note_page_test.dart' as ingress;
import '../test/features/ui_v3/v3_knowledge_world_visual_states_test.dart'
    as world;
import '../test/core/app_root_pending_navigation_test.dart' as runtime;
import '../test/features/chat/chat_controller_test.dart' as chat;
import '../test/features/ui_v3/feed_item_detail_controller_test.dart' as derived;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var scenarioNumber = 0;
  setUp(() {
    expect(defaultTargetPlatform, TargetPlatform.iOS);
    binding.testTextInput.register();
    scenarioNumber += 1;
    debugPrint('CANVAS_SIMULATOR_SCENARIO_START $scenarioNumber');
  });
  tearDown(() async {
    if (scenarioNumber <= 12) {
      final bytes = await binding.takeScreenshot(
        'canvas_state_$scenarioNumber',
      );
      final support = await getApplicationSupportDirectory();
      final directory = Directory('${support.path}/CanvasSimulatorAudit');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/state_$scenarioNumber.png',
      ).writeAsBytes(bytes);
    }
    debugPrint('CANVAS_SIMULATOR_SCENARIO_END $scenarioNumber');
    binding.testTextInput.unregister();
  });
  group('state', scenarios.main);
  group('detail', ingress.main);
  group('world', world.main);
  group('runtime', runtime.main);
  group('chat', chat.main);
  group('derived', derived.main);
}
