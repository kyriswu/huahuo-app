import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/features/onboarding/application/initial_positioning_task_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_digital_twin_page.dart';
import 'package:integration_test/integration_test.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';

import '../test/features/ui_v3/digital_twin_controller_test.dart' as fixtures;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('M12 revision visual lifecycle without production writes', (
    tester,
  ) async {
    final revisionGate = Completer<void>();
    final confirmationGate = Completer<void>();
    final controller = fixtures.createDigitalTwinVisualFixture(
      revisionGate: revisionGate,
      confirmationGate: confirmationGate,
    );
    final materials = fixtures.createDigitalTwinMaterialVisualFixture();
    await materials.enqueue(
      referenceId: 'visual-note-1',
      title: '访谈笔记：把复杂问题讲清楚',
    );
    await materials.enqueue(referenceId: 'visual-note-2', title: '专业知识与表达方法');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          digitalTwinControllerProvider.overrideWith((ref) => controller),
          digitalTwinMaterialControllerProvider.overrideWith(
            (ref) => materials,
          ),
          initialPositioningTaskStateProvider.overrideWith(
            (ref) => const InitialPositioningTaskState(),
          ),
          deepPositioningRepositoryProvider.overrideWithValue(
            const UnavailableDeepPositioningRepository(),
          ),
        ],
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: V3DigitalTwinPage(),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('digital-twin-material-queue')));
    await _settle(tester);
    await _capture(binding, '00-material-approval');
    await tester.tap(find.byTooltip('关闭').last);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('digital-twin-open-revision')));
    await _settle(tester);
    await _capture(binding, '01-compact');
    await tester.tap(
      find.byKey(
        const ValueKey('digital-twin-revision-file-social_positioning'),
      ),
    );
    await _settle(tester);
    await _capture(binding, '02-expanded-file');
    await tester.tap(find.text('+ 选中'));
    await _settle(tester);
    await _capture(binding, '03-citation');
    await tester.tap(find.byTooltip('展开'));
    await _settle(tester);
    await _capture(binding, '04-fullscreen');
    await tester.tap(find.byTooltip('收起'));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('digital-twin-revision-input')),
      '保留原文来源，把这一项改写得更具体。',
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('digital-twin-revise-submit')));
    await _settle(tester);
    await _capture(binding, '05-revising');
    revisionGate.complete();
    await _until(
      tester,
      () =>
          !controller.state.isBusy &&
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('digital-twin-revision-input')),
              )
              .controller!
              .text
              .isEmpty,
    );
    debugPrint(
      'M12 revision phase=${controller.state.phase.name}, error=${controller.state.errorCode}, pending=${controller.hasPendingEdits}, ready=${controller.state.readyProposalCount}, text=${tester.widget<TextField>(find.byKey(const ValueKey('digital-twin-revision-input'))).controller!.text}',
    );
    await _capture(binding, '06-draft-updated');
    await tester.tap(find.byKey(const ValueKey('digital-twin-confirm')));
    await _settle(tester);
    await _capture(binding, '07-confirming');
    confirmationGate.complete();
    await _until(
      tester,
      () =>
          controller.state.confirmation?.state == 'report_ready' &&
          !controller.state.isBusy,
    );
    debugPrint(
      'M12 confirmation phase=${controller.state.phase.name}, error=${controller.state.errorCode}, task=${controller.state.confirmation?.confirmationTaskId}',
    );
    await _capture(binding, '08-confirmed');
    expect(controller.state.confirmation!.state, 'report_ready');
    await tester.tap(find.text('查看本次修订报告'));
    await _settle(tester);
    await _capture(binding, '09-history-detail');
    await tester.tap(find.text('查看本次修订报告').last);
    await _settle(tester);
    await _capture(binding, '10-version-report');
    await tester.tap(find.byTooltip('返回').last);
    await _settle(tester);
    await tester.tap(find.byTooltip('返回').last);
    await _settle(tester);
    await tester.tap(find.byTooltip('关闭').last);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('digital-twin-history')));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await _capture(binding, '11-history-list');
    await tester.tap(find.byTooltip('返回').last);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('digital-twin-mode-files')));
    await _settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('digital-twin-file-social_positioning')),
    );
    await _settle(tester);
    await _capture(binding, '12-positioning-summary');
    await tester.tap(find.text('查看定位报告'));
    await _settle(tester);
    await _capture(binding, '13-positioning-report');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
) async {
  final bytes = await binding.takeScreenshot(name);
  final directory = Directory('${Directory.systemTemp.path}/twin-m12-visual');
  await directory.create(recursive: true);
  await File('${directory.path}/$name.png').writeAsBytes(bytes);
  debugPrint('M12 screenshot: ${directory.path}/$name.png');
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 75));
  }
}

Future<void> _until(WidgetTester tester, bool Function() completed) async {
  for (var frame = 0; frame < 80 && !completed(); frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    completed(),
    isTrue,
    reason: 'Expected lifecycle state did not settle within eight seconds',
  );
  await _settle(tester);
}
