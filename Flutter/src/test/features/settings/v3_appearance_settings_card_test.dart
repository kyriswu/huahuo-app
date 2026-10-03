import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/settings/application/app_appearance_controller.dart';
import 'package:huahuoai_app/features/settings/data/app_appearance_repository.dart';
import 'package:huahuoai_app/features/settings/domain/app_appearance_preset.dart';
import 'package:huahuoai_app/features/settings/widgets/v3_appearance_settings_card.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  testWidgets('shows all themes and persists a visible selection', (
    tester,
  ) async {
    final dao = AppPreferencesDao(AppDatabase());
    final controller = AppAppearanceController(
      repository: AppAppearanceRepository(dao: dao),
    )..restore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appAppearanceControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 375, child: V3AppearanceSettingsCard()),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('settings-appearance-card')),
      findsOneWidget,
    );
    for (final preset in AppAppearancePreset.supportedValues) {
      expect(find.text(preset.label), findsOneWidget);
      expect(
        find.byKey(ValueKey('appearance-preset-${preset.wireName}')),
        findsOneWidget,
      );
    }
    expect(
      tester
          .getSemantics(find.text(AppAppearancePreset.light.label))
          .flagsCollection
          .isSelected,
      ui.Tristate.isTrue,
    );

    await tester.tap(
      find.byKey(
        ValueKey('appearance-preset-${AppAppearancePreset.warmGold.wireName}'),
      ),
    );
    await tester.pump();

    expect(controller.preset, AppAppearancePreset.warmGold);
    expect(
      dao.readValue(AppAppearanceRepository.preferenceKey),
      AppAppearancePreset.warmGold.wireName,
    );
    expect(
      tester
          .getSemantics(find.text(AppAppearancePreset.warmGold.label))
          .flagsCollection
          .isSelected,
      ui.Tristate.isTrue,
    );
    expect(find.text(AppAppearancePreset.system.label), findsOneWidget);
    expect(find.text(AppAppearancePreset.warmGold.label), findsOneWidget);
    for (final preset in AppTextSizePreset.values) {
      expect(find.text(preset.label), findsWidgets);
    }
    expect(find.text('玻璃透明度'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-glass-opacity-value')),
      findsNothing,
    );

    await tester.drag(
      find.byKey(const ValueKey('settings-text-size-slider')),
      const Offset(180, 0),
    );
    await tester.pump();
    expect(controller.textSizePreset, AppTextSizePreset.percent130);
    expect(
      dao.readValue(AppAppearanceRepository.textSizePreferenceKey),
      AppTextSizePreset.percent130.wireName,
    );

    expect(
      find.byKey(const ValueKey('settings-glass-opacity-slider')),
      findsNothing,
    );
  });
}
