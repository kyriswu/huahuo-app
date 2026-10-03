import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/figma_golden_test_support.dart';
import 'note_detail_figma_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('matches the canonical M02 Figma surface', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 874);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(noteDetailFigmaFixture());
    await tester.pumpAndSettle();
    await precacheFigmaFixtureImages(tester);

    await expectLater(
      find.byKey(const ValueKey('note-detail-surface')),
      matchesGoldenFile('goldens/note_detail_surface.png'),
    );
  });
}
