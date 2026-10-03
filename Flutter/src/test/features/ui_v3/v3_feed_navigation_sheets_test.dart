import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_navigation_sheets.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('M01 More Ways matches Mobile V5', (tester) async {
    _setPhoneViewport(tester);
    V3FeedImportAction? selected;
    await tester.pumpWidget(
      _sheetApp(
        V3FeedMoreWaysSheet(
          onClose: () {},
          onSelected: (value) => selected = value,
        ),
      ),
    );

    await expectLater(
      find.byType(V3FeedMoreWaysSheet),
      matchesGoldenFile('goldens/feed_more_ways.png'),
    );
    await tester.tap(find.text('导入录音音频'));
    expect(selected, V3FeedImportAction.media);
  });
}

Widget _sheetApp(Widget sheet) => MaterialApp(
  theme: figmaGoldenTheme(),
  home: Scaffold(
    backgroundColor: const Color(0xffe2e2e2),
    body: Align(alignment: Alignment.bottomCenter, child: sheet),
  ),
);

void _setPhoneViewport(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
