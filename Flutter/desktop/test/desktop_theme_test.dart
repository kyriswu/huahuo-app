import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/shared/theme/desktop_theme.dart';

void main() {
  test('surface roles do not introduce implicit elevation colors', () {
    for (final palette in DesktopThemePalette.values) {
      for (final brightness in Brightness.values) {
        final theme = HuahuoDesktopTheme.themeFor(
          palette: palette,
          brightness: brightness,
        );
        final tokens = theme.extension<DesktopThemeTokens>()!;
        expect(theme.applyElevationOverlayColor, isFalse);
        expect(theme.colorScheme.surfaceTint, Colors.transparent);
        expect(theme.colorScheme.surfaceContainerHighest, tokens.surfaceMuted);
        expect(theme.colorScheme.surfaceBright, tokens.surface);
        expect(theme.colorScheme.surfaceDim, tokens.canvas);
      }
    }
  });

  group('DesktopThemePalette', () {
    const lightCases = <_ThemeExpectation>[
      _ThemeExpectation(
        palette: DesktopThemePalette.mistBlue,
        canvas: Color(0xFFF7FAFC),
        primary: Color(0xFF315F7D),
      ),
      _ThemeExpectation(
        palette: DesktopThemePalette.pineGreen,
        canvas: Color(0xFFF7FAF7),
        primary: Color(0xFF365E4B),
      ),
      _ThemeExpectation(
        palette: DesktopThemePalette.warmGold,
        canvas: Color(0xFFFDFBF7),
        primary: Color(0xFF725226),
      ),
      _ThemeExpectation(
        palette: DesktopThemePalette.sakura,
        canvas: Color(0xFFFFF8FB),
        primary: Color(0xFFA64F73),
      ),
      _ThemeExpectation(
        palette: DesktopThemePalette.aurora,
        canvas: Color(0xFFF7FBFC),
        primary: Color(0xFF006F86),
      ),
    ];

    for (final expectation in lightCases) {
      test(
        '${expectation.palette.wireName} uses its mobile V3 light tokens',
        () {
          final theme = HuahuoDesktopTheme.themeFor(
            palette: expectation.palette,
            brightness: Brightness.light,
          );
          final tokens = theme.extension<DesktopThemeTokens>();

          expect(tokens, isNotNull);
          expect(tokens!.canvas, expectation.canvas);
          expect(tokens.primary, expectation.primary);
          expect(theme.scaffoldBackgroundColor, expectation.canvas);
          expect(theme.colorScheme.primary, expectation.primary);
          expect(theme.colorScheme.surfaceContainerLow, tokens.surfaceMuted);
        },
      );
    }

    test('dark fallback matches mobile for light-only color presets', () {
      for (final palette in <DesktopThemePalette>[
        DesktopThemePalette.mistBlue,
        DesktopThemePalette.pineGreen,
        DesktopThemePalette.warmGold,
      ]) {
        final tokens = palette.tokensFor(Brightness.dark);
        expect(tokens.canvas, const Color(0xFF121212));
        expect(tokens.primary, const Color(0xFFF2F2F0));
      }
    });

    test('sakura and aurora keep their mobile dark tokens', () {
      final sakura = DesktopThemePalette.sakura.tokensFor(Brightness.dark);
      final aurora = DesktopThemePalette.aurora.tokensFor(Brightness.dark);

      expect(sakura.canvas, const Color(0xFF1C1418));
      expect(sakura.primary, const Color(0xFFF0A1BF));
      expect(aurora.canvas, const Color(0xFF10191C));
      expect(aurora.primary, const Color(0xFF67D5E5));
    });

    test('exposes exactly the five mobile color presets', () {
      expect(DesktopThemePalette.selectable, <DesktopThemePalette>[
        DesktopThemePalette.mistBlue,
        DesktopThemePalette.pineGreen,
        DesktopThemePalette.warmGold,
        DesktopThemePalette.sakura,
        DesktopThemePalette.aurora,
      ]);
      expect(
        DesktopThemePalette.tryParse('aurora'),
        DesktopThemePalette.aurora,
      );
      expect(DesktopThemePalette.tryParse('unknown'), isNull);
    });

    test('legacy desktop palettes resolve to the matching V3 palette', () {
      expect(
        DesktopAccentPalette.ocean.v3Palette,
        DesktopThemePalette.mistBlue,
      );
      expect(
        DesktopAccentPalette.forest.v3Palette,
        DesktopThemePalette.pineGreen,
      );
      expect(DesktopAccentPalette.rose.v3Palette, DesktopThemePalette.sakura);
      expect(
        HuahuoDesktopTheme.light(
          palette: DesktopAccentPalette.ocean,
        ).colorScheme.primary,
        const Color(0xFF315F7D),
      );
    });

    test('graph colors are derived from the selected V3 tokens', () {
      final tokens = DesktopThemePalette.aurora.tokensFor(Brightness.light);

      expect(tokens.graphPalette, hasLength(5));
      expect(tokens.graphPalette.first, const Color(0xFF006F86));
      expect(tokens.graphPalette[2], const Color(0xFF20866B));
      expect(tokens.graphPalette.last, const Color(0xFFD14983));
    });
  });
}

final class _ThemeExpectation {
  const _ThemeExpectation({
    required this.palette,
    required this.canvas,
    required this.primary,
  });

  final DesktopThemePalette palette;
  final Color canvas;
  final Color primary;
}
