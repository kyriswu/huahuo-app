import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_app_shell.dart';

import '../../support/figma_golden_test_support.dart';
import 'graph_test_fixture.dart';

void main() {
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M01 real graph covers the 3D and More Ways V5 states', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previousComparator = goldenFileComparator;
    final localComparator = previousComparator as LocalFileComparator;
    goldenFileComparator = _GraphGoldenComparator(
      localComparator.basedir.resolve('v3_feed_graph_modes_test.dart'),
    );
    addTearDown(() => goldenFileComparator = previousComparator);

    final library = KnowledgeLibraryController(
      initialNotes: buildGraphTestNotes(count: 34),
      includeDemoFixtures: false,
    );
    for (final note in library.notes.where((note) => !note.isHotspot)) {
      library.depositContent(note.id);
    }
    final graph = FeedGraphController(library);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          resolvedDeviceIdProvider.overrideWithValue('test-device'),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: RepaintBoundary(
          key: const ValueKey('feed-graph-golden-root'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: figmaGoldenTheme(),
            home: const V3AppShell(initialMode: V3HomeMode.feed),
          ),
        ),
      ),
    );
    await tester.pump();
    await _pumpGraphFrames(tester);

    await tester.tap(find.byKey(const ValueKey('feed-home-mode-3d')));
    await _pumpGraphFrames(tester);
    expect(find.text('2D'), findsNothing);
    expect(
      find.byKey(const ValueKey('feed-graph-interactive-viewer')),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(const ValueKey('feed-graph-golden-root')),
      matchesGoldenFile('goldens/feed_graph_3d.png'),
    );

    await tester.tap(find.bySemanticsLabel('新建').hitTestable());
    await _pumpOverlayFrames(tester);
    expect(find.text('更多方式'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });
}

final class _GraphGoldenComparator extends LocalFileComparator {
  _GraphGoldenComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= .00002) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

Future<void> _pumpGraphFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 24; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _pumpOverlayFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
