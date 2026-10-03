import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/settings/application/app_appearance_controller.dart';
import 'package:huahuoai_app/features/settings/data/app_appearance_repository.dart';
import 'package:huahuoai_app/features/settings/domain/app_appearance_preset.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  group('AppAppearancePreset', () {
    test('uses eight stable wire values and rejects unknown values', () {
      expect(
        AppAppearancePreset.values.map((preset) => preset.wireName),
        <String>[
          'system',
          'light',
          'dark',
          'mist-blue',
          'pine-green',
          'warm-gold',
          'sakura',
          'aurora',
        ],
      );
      for (final preset in AppAppearancePreset.values) {
        expect(AppAppearancePreset.tryParse(preset.wireName), preset);
      }
      expect(AppAppearancePreset.tryParse('unknown'), isNull);
      expect(AppAppearancePreset.tryParse(' MIST-BLUE '), isNull);
      expect(AppAppearancePreset.supportedValues, AppAppearancePreset.values);
    });
  });

  test('text-size presets expose six stable factors and wire values', () {
    expect(AppTextSizePreset.values.map((preset) => preset.label), <String>[
      '80%',
      '90%',
      '100%',
      '110%',
      '120%',
      '130%',
    ]);
    for (final preset in AppTextSizePreset.values) {
      expect(AppTextSizePreset.tryParse(preset.wireName), preset);
    }
  });

  group('AppAppearanceController', () {
    test('chromatic palettes expose readable light and dark variants', () {
      for (final palette in <HuahuoV3Palette>[
        HuahuoV3Palette.mistBlue,
        HuahuoV3Palette.pineGreen,
        HuahuoV3Palette.warmGold,
        HuahuoV3Palette.sakura,
        HuahuoV3Palette.aurora,
      ]) {
        final light = HuahuoV3Theme.themeFor(
          palette: palette,
          brightness: Brightness.light,
        );
        final dark = HuahuoV3Theme.themeFor(
          palette: palette,
          brightness: Brightness.dark,
        );
        expect(light.brightness, Brightness.light);
        expect(dark.brightness, Brightness.dark);
        expect(
          HuahuoV3Theme.graphPaletteFor(
            light.extension<HuahuoV3ThemeTokens>()!,
          ).toSet().length,
          greaterThanOrEqualTo(4),
        );
        expect(
          light.colorScheme.primary.computeLuminance(),
          isNot(dark.colorScheme.primary.computeLuminance()),
        );
      }
    });

    test('defaults to light and preserves every supported preset', () {
      final controller = AppAppearanceController()..restore();
      addTearDown(controller.dispose);

      expect(controller.preset, AppAppearancePreset.light);
      expect(controller.glassOpacityPercent, 50);
      expect(controller.restored, isTrue);
      expect(controller.themeMode, ThemeMode.light);

      final expectedModes = <AppAppearancePreset, ThemeMode>{
        AppAppearancePreset.system: ThemeMode.system,
        AppAppearancePreset.light: ThemeMode.light,
        AppAppearancePreset.dark: ThemeMode.dark,
        AppAppearancePreset.mistBlue: ThemeMode.system,
        AppAppearancePreset.pineGreen: ThemeMode.system,
        AppAppearancePreset.warmGold: ThemeMode.system,
        AppAppearancePreset.sakura: ThemeMode.system,
        AppAppearancePreset.aurora: ThemeMode.system,
      };
      for (final entry in expectedModes.entries) {
        expect(controller.selectPreset(entry.key), isTrue);
        expect(controller.preset, entry.key);
        expect(controller.themeMode, entry.value);
      }
    });

    test('persists a selection and restores it in a new controller', () {
      final dao = AppPreferencesDao(AppDatabase());
      final repository = AppAppearanceRepository(
        dao: dao,
        now: () => DateTime.utc(2026, 7, 24, 1, 2, 3),
      );
      final first = AppAppearanceController(repository: repository)..restore();
      addTearDown(first.dispose);

      expect(first.selectPreset(AppAppearancePreset.warmGold), isTrue);
      expect(first.selectTextSizePreset(AppTextSizePreset.percent120), isTrue);
      expect(
        dao.readValue(AppAppearanceRepository.preferenceKey),
        AppAppearancePreset.warmGold.wireName,
      );

      final recovered = AppAppearanceController(repository: repository)
        ..restore();
      addTearDown(recovered.dispose);
      expect(recovered.preset, AppAppearancePreset.warmGold);
      expect(recovered.textSizePreset, AppTextSizePreset.percent120);
      expect(recovered.glassOpacityPercent, 50);
      expect(
        dao.readValue(AppAppearanceRepository.textSizePreferenceKey),
        AppTextSizePreset.percent120.wireName,
      );
      expect(recovered.errorCode, isNull);
    });

    test('repairs an invalid persisted value to canonical light', () {
      final dao = AppPreferencesDao(AppDatabase());
      dao.upsertValue(
        preferenceKey: AppAppearanceRepository.preferenceKey,
        value: 'corrupt-preset',
        updatedAt: '2026-07-24T00:00:00.000Z',
      );
      final controller = AppAppearanceController(
        repository: AppAppearanceRepository(dao: dao),
      )..restore();
      addTearDown(controller.dispose);

      expect(controller.preset, AppAppearancePreset.light);
      expect(controller.errorCode, isNull);
      expect(
        dao.readValue(AppAppearanceRepository.preferenceKey),
        AppAppearancePreset.light.wireName,
      );
    });

    test('restores a persisted chromatic preset without migration', () {
      final dao = AppPreferencesDao(AppDatabase());
      dao.upsertValue(
        preferenceKey: AppAppearanceRepository.preferenceKey,
        value: AppAppearancePreset.warmGold.wireName,
        updatedAt: '2026-08-31T00:00:00.000Z',
      );
      final controller = AppAppearanceController(
        repository: AppAppearanceRepository(dao: dao),
      )..restore();
      addTearDown(controller.dispose);

      expect(controller.preset, AppAppearancePreset.warmGold);
      expect(
        dao.readValue(AppAppearanceRepository.preferenceKey),
        AppAppearancePreset.warmGold.wireName,
      );
    });

    test('keeps the visible preset unchanged when persistence fails', () async {
      final root = await Directory.systemTemp.createTemp('appearance-failure-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final database = AppDatabase(
        snapshotStore: _ThrowingSnapshotStore(
          file: File('${root.path}/local-db.json'),
        ),
      );
      final controller = AppAppearanceController(
        repository: AppAppearanceRepository(dao: AppPreferencesDao(database)),
      )..restore();
      addTearDown(controller.dispose);

      expect(controller.selectPreset(AppAppearancePreset.dark), isFalse);
      expect(controller.preset, AppAppearancePreset.light);
      expect(controller.errorCode, 'APP_APPEARANCE_SAVE_FAILED');
    });
  });
}

final class _ThrowingSnapshotStore extends LocalDatabaseSnapshotStore {
  const _ThrowingSnapshotStore({required super.file});

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    throw FileSystemException('test persistence failure', file.path);
  }
}
