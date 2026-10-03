import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_entry_figma_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M05 chat entry matches the curated first viewport', (
    tester,
  ) async {
    await loadChatEntryFigmaFonts();
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(chatEntryFigmaFixture());
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/chat_entry_surface.png'),
    );
  });
}
