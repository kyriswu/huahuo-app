import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:huahuo_desktop/app/desktop_feature_registry.dart';
import 'package:huahuo_desktop/app/desktop_router.dart';
import 'package:huahuo_product/huahuo_product.dart';

void main() {
  testWidgets('Desktop router restores known product destinations', (
    tester,
  ) async {
    final router = createDesktopRouter(
      commands: desktopFeatureCommands(ProductFeatureCatalog.entries),
      initialLocation: '/notifications',
      pageBuilder: (context, location, failed) =>
          Text('$location:$failed', textDirection: TextDirection.ltr),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    expect(find.text('/notifications:false'), findsOneWidget);
  });

  testWidgets('Desktop router does not expose hidden native destinations', (
    tester,
  ) async {
    final router = createDesktopRouter(
      commands: desktopFeatureCommands(ProductFeatureCatalog.entries),
      initialLocation: '/brain',
      pageBuilder: (context, location, failed) =>
          Text('$location:$failed', textDirection: TextDirection.ltr),
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/native/recording-card');
    await tester.pumpAndSettle();

    expect(find.text('/native/recording-card:true'), findsOneWidget);
  });
}
