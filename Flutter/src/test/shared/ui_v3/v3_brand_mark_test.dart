import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_brand_mark.dart';

void main() {
  testWidgets('brand mark renders the bundled untinted firework asset', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: V3BrandMark(dimension: 48, color: Colors.red)),
      ),
    );

    final mark = tester.widget<V3BrandMark>(find.byType(V3BrandMark));
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(V3BrandMark),
        matching: find.byType(Image),
      ),
    );
    final box = tester.widget<SizedBox>(
      find.descendant(
        of: find.byType(V3BrandMark),
        matching: find.byType(SizedBox),
      ),
    );

    expect(mark.color, Colors.red);
    expect((image.image as AssetImage).assetName, V3BrandMark.assetPath);
    expect(image.fit, BoxFit.contain);
    expect(image.color, isNull);
    expect(image.excludeFromSemantics, isTrue);
    expect(find.bySemanticsLabel('无限花火'), findsOneWidget);
    expect(box.width, 48);
    expect(box.height, 48);
  });

  testWidgets('invalid dimension falls back to the established square size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: V3BrandMark(dimension: -1))),
    );

    final box = tester.widget<SizedBox>(
      find.descendant(
        of: find.byType(V3BrandMark),
        matching: find.byType(SizedBox),
      ),
    );
    expect(box.width, 74);
    expect(box.height, 74);
  });
}
