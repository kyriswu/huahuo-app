import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

Future<void> loadFigmaGoldenFonts() async {
  await Future.wait([
    (FontLoader(
      'Noto Sans SC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))).load(),
    (FontLoader(
      'PingFang SC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))).load(),
    (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load(),
    (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(
          rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
        ))
        .load(),
  ]);
}

ThemeData figmaGoldenTheme() {
  final theme = HuahuoV3Theme.light();
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'Noto Sans SC'),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'Noto Sans SC'),
  );
}

Future<void> precacheFigmaFixtureImages(WidgetTester tester) async {
  final images = find.byType(Image).evaluate().map((element) {
    return (element.widget as Image).image;
  }).toSet();
  for (final image in images) {
    await tester.runAsync(
      () => precacheImage(image, tester.element(find.byType(Image).first)),
    );
  }
  await tester.pumpAndSettle();
}
