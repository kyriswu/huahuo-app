import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  test('V3 semantic surfaces do not reintroduce fixed light-only colors', () {
    final sourceRoots = <Directory>[
      Directory('lib/features/ui_v3'),
      Directory('lib/shared/ui_v3'),
    ];
    final forbiddenLightSurface = RegExp(
      r'0x(?:ff)?(?:fdfcf9|fdfbf8|f8f4fa|f4f1ec|f6f1e9|fff6ee|f4f7f4|fff7f7|f6f6f6|f7f7f7|f4f5f5|fbf5ec)',
      caseSensitive: false,
    );
    final opticalBlackWhiteAllowlist = <String, String>{
      'lib/features/ui_v3/presentation/v3_account_profile_page.dart':
          'translucent account-header highlight',
      'lib/features/ui_v3/presentation/v3_chat_page.dart':
          'full-screen media and camera overlays',
      'lib/features/ui_v3/presentation/v3_creation_canvas_page.dart':
          'generated-media overlay foregrounds',
      'lib/features/ui_v3/presentation/v3_creation_history_page.dart':
          'destructive swipe foregrounds',
      'lib/features/ui_v3/presentation/v3_feed_item_detail_page.dart':
          'modal scrims',
      'lib/features/ui_v3/presentation/v3_note_chat.dart': 'modal scrims',
      'lib/features/ui_v3/presentation/v3_graph_node_painter.dart':
          'graph-node optical rim and lighting',
      'lib/features/ui_v3/presentation/v3_graph_sphere_mesh_painter.dart':
          'sphere lighting defaults overridden by production callers',
      'lib/features/ui_v3/presentation/v3_help_center_page.dart':
          'QR-code contrast field',
      'lib/features/ui_v3/presentation/v3_interactive_graph.dart':
          'graph-node optical highlights',
      'lib/features/ui_v3/presentation/v3_knowledge_local_surfaces.dart':
          'photo overlays and image preview controls',
      'lib/features/ui_v3/presentation/v3_knowledge_remote_detail.dart':
          'photo overlays and image preview controls',
      'lib/features/ui_v3/presentation/v3_knowledge_remote_home.dart':
          'photo overlays and image preview controls',
      'lib/features/ui_v3/presentation/v3_masterpiece_page.dart':
          'locked-media scrim',
      'lib/features/ui_v3/presentation/v3_material_import_surfaces.dart':
          'full-screen modal scrim behind the import Sheet',
      'lib/features/ui_v3/presentation/v3_profile_side_panel.dart':
          'branded membership card and metallic highlight',
      'lib/features/ui_v3/presentation/v3_workbench_page.dart': 'modal scrim',
      'lib/shared/ui_v3/v3_components.dart':
          'deliberately dark optical-glass component',
      'lib/shared/ui_v3/v3_glass_foundations.dart':
          'glass optical shadow and highlight implementation',
      'lib/shared/ui_v3/v3_glass_painters.dart':
          'glass refraction highlight implementation',
      'lib/shared/ui_v3/v3_liquid_glass.dart':
          'glass reflection, refraction, and shadow implementation',
    };
    final blackWhite = RegExp(
      r'Colors\.(?:white|black)|Color\(0x(?:FF)?(?:FFFFFF|000000)\)',
    );
    final violations = <String>[];

    for (final root in sourceRoots) {
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relative = entity.path.replaceFirst(
          '${Directory.current.path}${Platform.pathSeparator}',
          '',
        );
        final source = entity.readAsStringSync();
        if (forbiddenLightSurface.hasMatch(source)) {
          violations.add('$relative contains a fixed light-only surface');
        }
        if (blackWhite.hasMatch(source) &&
            !opticalBlackWhiteAllowlist.containsKey(relative)) {
          violations.add('$relative uses unregistered fixed black/white');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('every chromatic dark palette keeps its own theme identity', () {
    final neutral = HuahuoV3Theme.themeFor(
      palette: HuahuoV3Palette.neutral,
      brightness: Brightness.dark,
    ).extension<HuahuoV3ThemeTokens>()!;

    for (final palette in HuahuoV3Palette.values.where(
      (candidate) => candidate != HuahuoV3Palette.neutral,
    )) {
      final tokens = HuahuoV3Theme.themeFor(
        palette: palette,
        brightness: Brightness.dark,
      ).extension<HuahuoV3ThemeTokens>()!;
      expect(
        <Color>{tokens.canvas, tokens.primary, tokens.accent},
        isNot(<Color>{neutral.canvas, neutral.primary, neutral.accent}),
        reason: '$palette must not collapse to neutral dark tokens',
      );
    }
  });

  for (final palette in HuahuoV3Palette.values) {
    for (final brightness in Brightness.values) {
      test('$palette ${brightness.name} foreground tokens remain readable', () {
        final theme = HuahuoV3Theme.themeFor(
          palette: palette,
          brightness: brightness,
        );
        final tokens = theme.extension<HuahuoV3ThemeTokens>()!;
        final surfaces = <String, Color>{
          'canvas': tokens.canvas,
          'surface': tokens.surface,
          'mutedSurface': tokens.surfaceMuted,
        };

        for (final foreground in <String, Color>{
          'ink': tokens.ink,
          'text': tokens.text,
          'muted': tokens.muted,
          'accent': tokens.accent,
          'success': tokens.success,
          'danger': tokens.danger,
        }.entries) {
          for (final surface in surfaces.entries) {
            expect(
              HuahuoV3Theme.contrastRatio(foreground.value, surface.value),
              greaterThanOrEqualTo(4.5),
              reason: '${foreground.key} must be readable on ${surface.key}',
            );
          }
        }

        expect(
          HuahuoV3Theme.contrastRatio(tokens.onPrimary, tokens.primary),
          greaterThanOrEqualTo(4.5),
        );
        _expectReadable(
          tokens.success,
          HuahuoV3Theme.semanticSurface(tokens.success, tokens.surface),
          minimumRatio: 3,
        );
        _expectReadable(
          tokens.danger,
          HuahuoV3Theme.semanticSurface(tokens.danger, tokens.surface),
          minimumRatio: 3,
        );
        _expectReadable(
          tokens.ink,
          HuahuoV3Theme.semanticSurface(tokens.success, tokens.surface),
        );
        _expectReadable(
          tokens.ink,
          HuahuoV3Theme.semanticSurface(tokens.danger, tokens.surface),
        );
      });
    }
  }

  test(
    'unreadable inline markdown colour falls back to the active text token',
    () {
      const background = Color(0xFFFFFFFF);
      const fallback = Color(0xFF2E2E2E);
      expect(
        HuahuoV3Theme.readableForeground(
          const Color(0xFFFFDDE9),
          background: background,
          fallback: fallback,
        ),
        fallback,
      );
      const lightHighlight = Color(0xFFFFF0F0);
      const darkHighlight = Color(0xFF232323);
      _expectReadable(
        HuahuoV3Theme.contrastingForeground(
          const Color(0xFFF5F5F3),
          background: lightHighlight,
        ),
        lightHighlight,
      );
      _expectReadable(
        HuahuoV3Theme.contrastingForeground(
          const Color(0xFF111111),
          background: darkHighlight,
        ),
        darkHighlight,
      );
    },
  );

  for (final palette in HuahuoV3Palette.values) {
    for (final brightness in Brightness.values) {
      test(
        '$palette ${brightness.name} Material controls inherit readable colors',
        () {
          final theme = HuahuoV3Theme.themeFor(
            palette: palette,
            brightness: brightness,
          );
          final tokens = theme.extension<HuahuoV3ThemeTokens>()!;
          final input = theme.inputDecorationTheme;
          final listTile = theme.listTileTheme;
          final snackBar = theme.snackBarTheme;

          for (final style in <TextStyle?>[
            theme.textTheme.headlineSmall,
            theme.textTheme.titleLarge,
            theme.textTheme.bodyLarge,
            theme.textTheme.bodyMedium,
            theme.textTheme.bodySmall,
            theme.textTheme.labelLarge,
            theme.textTheme.labelMedium,
            input.hintStyle,
            input.labelStyle,
            input.floatingLabelStyle,
            input.helperStyle,
            input.prefixStyle,
            input.suffixStyle,
            input.errorStyle,
            listTile.titleTextStyle,
            listTile.subtitleTextStyle,
            snackBar.contentTextStyle,
          ]) {
            expect(style, isNotNull);
          }

          _expectReadable(
            theme.textTheme.headlineSmall!.color!,
            tokens.surface,
          );
          _expectReadable(theme.textTheme.titleLarge!.color!, tokens.surface);
          _expectReadable(theme.textTheme.bodyLarge!.color!, tokens.surface);
          _expectReadable(theme.textTheme.bodyMedium!.color!, tokens.surface);
          _expectReadable(theme.textTheme.bodySmall!.color!, tokens.surface);
          _expectReadable(theme.textTheme.labelLarge!.color!, tokens.surface);
          _expectReadable(theme.textTheme.labelMedium!.color!, tokens.surface);
          _expectReadable(input.hintStyle!.color!, tokens.surfaceMuted);
          _expectReadable(input.labelStyle!.color!, tokens.surfaceMuted);
          _expectReadable(
            input.floatingLabelStyle!.color!,
            tokens.surfaceMuted,
          );
          _expectReadable(input.helperStyle!.color!, tokens.surfaceMuted);
          _expectReadable(input.prefixStyle!.color!, tokens.surfaceMuted);
          _expectReadable(input.suffixStyle!.color!, tokens.surfaceMuted);
          _expectReadable(input.errorStyle!.color!, tokens.surfaceMuted);
          _expectReadable(listTile.titleTextStyle!.color!, tokens.surface);
          _expectReadable(listTile.subtitleTextStyle!.color!, tokens.surface);
          _expectReadable(
            snackBar.contentTextStyle!.color!,
            snackBar.backgroundColor!,
          );

          _expectReadable(
            theme.iconButtonTheme.style!.foregroundColor!.resolve({})!,
            tokens.surface,
          );
          _expectReadable(
            theme.outlinedButtonTheme.style!.foregroundColor!.resolve({})!,
            tokens.surface,
          );
          _expectReadable(
            theme.textButtonTheme.style!.foregroundColor!.resolve({})!,
            tokens.surface,
          );
          _expectReadable(
            theme.colorScheme.onPrimary,
            theme.colorScheme.primary,
          );
          _expectReadable(
            theme.colorScheme.onSecondary,
            theme.colorScheme.secondary,
            minimumRatio: 3,
          );
        },
      );
    }
  }
}

void _expectReadable(
  Color foreground,
  Color background, {
  double minimumRatio = 4.5,
}) {
  expect(
    HuahuoV3Theme.contrastRatio(foreground, background),
    greaterThanOrEqualTo(minimumRatio),
  );
}
