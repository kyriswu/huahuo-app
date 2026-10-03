import 'package:flutter/material.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

final class DesktopMotionTokens {
  const DesktopMotionTokens._();

  static const responsive = Duration(milliseconds: 120);
  static const standard = Duration(milliseconds: 160);
  static const ambientLoop = Duration(seconds: 12);

  static Duration resolve(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
}

final class DesktopDisclosureChevron extends StatelessWidget {
  const DesktopDisclosureChevron({
    required this.expanded,
    this.size = 16,
    this.color,
    super.key,
  });

  final bool expanded;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: AnimatedRotation(
      turns: expanded ? .25 : 0,
      duration: DesktopMotionTokens.resolve(
        context,
        DesktopMotionTokens.standard,
      ),
      curve: Curves.easeOutCubic,
      child: Icon(
        LucideIcons.chevronRight,
        size: size,
        color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

final class DesktopDisclosureTile extends StatefulWidget {
  const DesktopDisclosureTile({
    required this.title,
    required this.children,
    this.subtitle,
    this.status,
    this.tilePadding,
    this.childrenPadding,
    this.initiallyExpanded = false,
    super.key,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? status;
  final List<Widget> children;
  final EdgeInsetsGeometry? tilePadding;
  final EdgeInsetsGeometry? childrenPadding;
  final bool initiallyExpanded;

  @override
  State<DesktopDisclosureTile> createState() => _DesktopDisclosureTileState();
}

final class _DesktopDisclosureTileState extends State<DesktopDisclosureTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final duration = DesktopMotionTokens.resolve(
      context,
      DesktopMotionTokens.standard,
    );
    return ExpansionTile(
      initiallyExpanded: widget.initiallyExpanded,
      tilePadding: widget.tilePadding,
      childrenPadding: widget.childrenPadding,
      title: widget.title,
      subtitle: widget.subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.status case final status?) ...[
            status,
            const SizedBox(width: 8),
          ],
          DesktopDisclosureChevron(expanded: _expanded),
        ],
      ),
      expansionAnimationStyle: AnimationStyle(
        duration: duration,
        reverseDuration: duration,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeOutCubic,
      ),
      onExpansionChanged: (expanded) {
        setState(() => _expanded = expanded);
      },
      children: widget.children,
    );
  }
}

final class DesktopEffectTokens {
  const DesktopEffectTokens._();

  static const graphOverlaySigma = 14.0;
  static const graphPreviewShadowSigma = 3.0;
}

final class DesktopInteractionTimingTokens {
  const DesktopInteractionTimingTokens._();

  static const tooltipWait = Duration(milliseconds: 450);
}

/// The mobile V3 palettes available to desktop surfaces.
///
/// The wire names deliberately match [AppAppearancePreset] on mobile so a
/// future shared preference can travel between devices without translation.
enum DesktopThemePalette {
  neutral(wireName: 'neutral', label: '默认'),
  mistBlue(wireName: 'mist-blue', label: '雾蓝'),
  pineGreen(wireName: 'pine-green', label: '松绿'),
  warmGold(wireName: 'warm-gold', label: '暖金'),
  sakura(wireName: 'sakura', label: '绯樱'),
  aurora(wireName: 'aurora', label: '极光');

  const DesktopThemePalette({required this.wireName, required this.label});

  final String wireName;
  final String label;

  static const selectable = <DesktopThemePalette>[
    mistBlue,
    pineGreen,
    warmGold,
    sakura,
    aurora,
  ];

  static DesktopThemePalette? tryParse(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    for (final palette in DesktopThemePalette.values) {
      if (palette.wireName == normalized) return palette;
    }
    return null;
  }
}

/// Compatibility bridge for the original desktop palette preference.
///
/// Keep this enum until persisted desktop preferences have migrated. New UI
/// should use [DesktopThemePalette.selectable], which exposes the same five
/// named presets as mobile V3.
enum DesktopAccentPalette {
  graphite(DesktopThemePalette.neutral),
  ocean(DesktopThemePalette.mistBlue),
  forest(DesktopThemePalette.pineGreen),
  warmGold(DesktopThemePalette.warmGold),
  rose(DesktopThemePalette.sakura),
  aurora(DesktopThemePalette.aurora);

  const DesktopAccentPalette(this.v3Palette);

  final DesktopThemePalette v3Palette;

  Color primaryFor(Brightness brightness) => v3Palette.primaryFor(brightness);
}

@immutable
final class DesktopThemeTokens extends ThemeExtension<DesktopThemeTokens> {
  const DesktopThemeTokens({
    required this.canvas,
    required this.surface,
    required this.surfaceMuted,
    required this.ink,
    required this.text,
    required this.muted,
    required this.line,
    required this.primary,
    required this.onPrimary,
    required this.accent,
    required this.success,
    required this.danger,
    required this.warmRim,
    required this.coolRim,
  });

  final Color canvas;
  final Color surface;
  final Color surfaceMuted;
  final Color ink;
  final Color text;
  final Color muted;
  final Color line;
  final Color primary;
  final Color onPrimary;
  final Color accent;
  final Color success;
  final Color danger;
  final Color warmRim;
  final Color coolRim;

  /// Uses the same five-color graph sequence as mobile V3.
  List<Color> get graphPalette => List<Color>.unmodifiable(<Color>[
    primary,
    Color.lerp(primary, coolRim, .62)!,
    success,
    Color.lerp(warmRim, danger, .24)!,
    accent,
  ]);

  static DesktopThemeTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<DesktopThemeTokens>() ??
        DesktopThemePalette.neutral.tokensFor(theme.brightness);
  }

  @override
  DesktopThemeTokens copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceMuted,
    Color? ink,
    Color? text,
    Color? muted,
    Color? line,
    Color? primary,
    Color? onPrimary,
    Color? accent,
    Color? success,
    Color? danger,
    Color? warmRim,
    Color? coolRim,
  }) {
    return DesktopThemeTokens(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      ink: ink ?? this.ink,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      line: line ?? this.line,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      danger: danger ?? this.danger,
      warmRim: warmRim ?? this.warmRim,
      coolRim: coolRim ?? this.coolRim,
    );
  }

  @override
  DesktopThemeTokens lerp(
    covariant ThemeExtension<DesktopThemeTokens>? other,
    double t,
  ) {
    if (other is! DesktopThemeTokens) return this;
    return DesktopThemeTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      line: Color.lerp(line, other.line, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warmRim: Color.lerp(warmRim, other.warmRim, t)!,
      coolRim: Color.lerp(coolRim, other.coolRim, t)!,
    );
  }
}

extension DesktopThemePaletteTokens on DesktopThemePalette {
  DesktopThemeTokens tokensFor(Brightness brightness) =>
      _DesktopThemeTokenCatalog.forPalette(this, brightness);

  Color primaryFor(Brightness brightness) => tokensFor(brightness).primary;
}

abstract final class _DesktopThemeTokenCatalog {
  static const _neutralLight = DesktopThemeTokens(
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF6F6F6),
    ink: Color(0xFF090909),
    text: Color(0xFF2E2E2E),
    muted: Color(0xFF777777),
    line: Color(0xFFE7E7E7),
    primary: Color(0xFF090909),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFFA87535),
    success: Color(0xFF5E7A64),
    danger: Color(0xFFB54A22),
    warmRim: Color(0xFFC99858),
    coolRim: Color(0xFFD7E4EF),
  );

  static const _neutralDark = DesktopThemeTokens(
    canvas: Color(0xFF121212),
    surface: Color(0xFF1A1A1A),
    surfaceMuted: Color(0xFF242424),
    ink: Color(0xFFF5F5F3),
    text: Color(0xFFE7E7E5),
    muted: Color(0xFFA8A8A5),
    line: Color(0xFF343434),
    primary: Color(0xFFF2F2F0),
    onPrimary: Color(0xFF171717),
    accent: Color(0xFFC99858),
    success: Color(0xFF8FB099),
    danger: Color(0xFFE08A78),
    warmRim: Color(0xFF8F714D),
    coolRim: Color(0xFF526878),
  );

  static const _mistBlue = DesktopThemeTokens(
    canvas: Color(0xFFF7FAFC),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF0F5F8),
    ink: Color(0xFF132A3A),
    text: Color(0xFF2D3B45),
    muted: Color(0xFF71808A),
    line: Color(0xFFDCE6EC),
    primary: Color(0xFF315F7D),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFF7D9FB5),
    success: Color(0xFF587B6A),
    danger: Color(0xFFB65D4A),
    warmRim: Color(0xFFC5AA82),
    coolRim: Color(0xFF9CBACB),
  );

  static const _pineGreen = DesktopThemeTokens(
    canvas: Color(0xFFF7FAF7),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFEFF5F1),
    ink: Color(0xFF193328),
    text: Color(0xFF304239),
    muted: Color(0xFF708078),
    line: Color(0xFFDCE7E0),
    primary: Color(0xFF365E4B),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFF829A8B),
    success: Color(0xFF4E755F),
    danger: Color(0xFFB35E4C),
    warmRim: Color(0xFFC3A36E),
    coolRim: Color(0xFFA5C0B2),
  );

  static const _warmGold = DesktopThemeTokens(
    canvas: Color(0xFFFDFBF7),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFFAF3E8),
    ink: Color(0xFF342719),
    text: Color(0xFF463A2D),
    muted: Color(0xFF82776A),
    line: Color(0xFFECE1D3),
    primary: Color(0xFF725226),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFFB7894A),
    success: Color(0xFF647B60),
    danger: Color(0xFFB65B42),
    warmRim: Color(0xFFC3904E),
    coolRim: Color(0xFFB7C9CF),
  );

  static const _sakura = DesktopThemeTokens(
    canvas: Color(0xFFFFF8FB),
    surface: Color(0xFFFFFDFE),
    surfaceMuted: Color(0xFFFAEDF3),
    ink: Color(0xFF3B1F2B),
    text: Color(0xFF523744),
    muted: Color(0xFF8D7480),
    line: Color(0xFFEDD7E0),
    primary: Color(0xFFA64F73),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFFE58AAD),
    success: Color(0xFF4F806B),
    danger: Color(0xFFB94F60),
    warmRim: Color(0xFFD882A4),
    coolRim: Color(0xFFB6CFE0),
  );

  static const _sakuraDark = DesktopThemeTokens(
    canvas: Color(0xFF1C1418),
    surface: Color(0xFF261B20),
    surfaceMuted: Color(0xFF33242B),
    ink: Color(0xFFFFEEF4),
    text: Color(0xFFF3DDE6),
    muted: Color(0xFFC1A3B0),
    line: Color(0xFF4B3440),
    primary: Color(0xFFF0A1BF),
    onPrimary: Color(0xFF341623),
    accent: Color(0xFFE178A2),
    success: Color(0xFF8FC4AA),
    danger: Color(0xFFF08A9A),
    warmRim: Color(0xFF9D5E78),
    coolRim: Color(0xFF587A8E),
  );

  static const _aurora = DesktopThemeTokens(
    canvas: Color(0xFFF7FBFC),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFECF6F7),
    ink: Color(0xFF102C35),
    text: Color(0xFF29434A),
    muted: Color(0xFF6C8288),
    line: Color(0xFFD3E5E8),
    primary: Color(0xFF006F86),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFFD14983),
    success: Color(0xFF20866B),
    danger: Color(0xFFC2504E),
    warmRim: Color(0xFFD7AA43),
    coolRim: Color(0xFF7AC8DE),
  );

  static const _auroraDark = DesktopThemeTokens(
    canvas: Color(0xFF10191C),
    surface: Color(0xFF172328),
    surfaceMuted: Color(0xFF203238),
    ink: Color(0xFFE8FAFC),
    text: Color(0xFFD8ECEF),
    muted: Color(0xFF9DB9BE),
    line: Color(0xFF304A51),
    primary: Color(0xFF67D5E5),
    onPrimary: Color(0xFF08282F),
    accent: Color(0xFFF184B3),
    success: Color(0xFF70C7A8),
    danger: Color(0xFFF18582),
    warmRim: Color(0xFF927532),
    coolRim: Color(0xFF397F94),
  );

  static DesktopThemeTokens forPalette(
    DesktopThemePalette palette,
    Brightness brightness,
  ) {
    if (brightness == Brightness.dark) {
      return switch (palette) {
        DesktopThemePalette.sakura => _sakuraDark,
        DesktopThemePalette.aurora => _auroraDark,
        DesktopThemePalette.neutral ||
        DesktopThemePalette.mistBlue ||
        DesktopThemePalette.pineGreen ||
        DesktopThemePalette.warmGold => _neutralDark,
      };
    }
    return switch (palette) {
      DesktopThemePalette.neutral => _neutralLight,
      DesktopThemePalette.mistBlue => _mistBlue,
      DesktopThemePalette.pineGreen => _pineGreen,
      DesktopThemePalette.warmGold => _warmGold,
      DesktopThemePalette.sakura => _sakura,
      DesktopThemePalette.aurora => _aurora,
    };
  }
}

abstract final class HuahuoDesktopTheme {
  static ThemeData light({
    DesktopAccentPalette palette = DesktopAccentPalette.graphite,
  }) => themeFor(palette: palette.v3Palette, brightness: Brightness.light);

  static ThemeData dark({
    DesktopAccentPalette palette = DesktopAccentPalette.graphite,
  }) => themeFor(palette: palette.v3Palette, brightness: Brightness.dark);

  static ThemeData themeFor({
    required DesktopThemePalette palette,
    required Brightness brightness,
  }) => _build(brightness: brightness, tokens: palette.tokensFor(brightness));

  static ThemeData _build({
    required Brightness brightness,
    required DesktopThemeTokens tokens,
  }) {
    final canvas = tokens.canvas;
    final surface = tokens.surface;
    final surfaceMuted = tokens.surfaceMuted;
    final text = tokens.text;
    final textSecondary = tokens.muted;
    final line = tokens.line;
    final primary = tokens.primary;
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
          primary: primary,
          secondary: tokens.accent,
          surface: surface,
          error: tokens.danger,
        ).copyWith(
          onPrimary: tokens.onPrimary,
          onSurface: text,
          onSurfaceVariant: textSecondary,
          outline: line,
          outlineVariant: line,
          surfaceContainerLowest: canvas,
          surfaceContainerLow: surfaceMuted,
          surfaceContainer: surfaceMuted,
          surfaceContainerHigh: surfaceMuted,
          surfaceContainerHighest: surfaceMuted,
          surfaceDim: canvas,
          surfaceBright: surface,
          inverseSurface: text,
          onInverseSurface: canvas,
          surfaceTint: Colors.transparent,
        );
    final base = ThemeData(
      useMaterial3: true,
      applyElevationOverlayColor: false,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: canvas,
      fontFamily: HuahuoTypography.primaryFamily,
      fontFamilyFallback: HuahuoTypography.fallbacks,
      extensions: <ThemeExtension<dynamic>>[tokens],
      visualDensity: VisualDensity.compact,
      hoverColor: surfaceMuted.withValues(alpha: 0.72),
      focusColor: primary.withValues(alpha: 0.08),
      highlightColor: primary.withValues(alpha: 0.05),
    );
    return base.copyWith(
      textTheme: base.textTheme
          .apply(
            bodyColor: text,
            displayColor: text,
            fontFamily: HuahuoTypography.primaryFamily,
          )
          .copyWith(
            headlineMedium: TextStyle(
              color: text,
              fontFamily: HuahuoTypography.primaryFamily,
              fontFamilyFallback: HuahuoTypography.fallbacks,
              fontSize: 26,
              height: 1.28,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
            titleMedium: TextStyle(
              color: text,
              fontFamily: HuahuoTypography.primaryFamily,
              fontFamilyFallback: HuahuoTypography.fallbacks,
              fontSize: 14,
              height: 1.35,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
            bodyMedium: TextStyle(
              color: text,
              fontFamily: HuahuoTypography.primaryFamily,
              fontFamilyFallback: HuahuoTypography.fallbacks,
              fontSize: 14,
              height: 1.55,
              letterSpacing: 0,
            ),
          ),
      dividerColor: line,
      splashFactory: InkRipple.splashFactory,
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStatePropertyAll(textSecondary),
          minimumSize: const WidgetStatePropertyAll(Size.square(34)),
          maximumSize: const WidgetStatePropertyAll(Size.square(34)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: const WidgetStatePropertyAll(CircleBorder()),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(primary),
          minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontFamily: HuahuoTypography.primaryFamily,
              fontFamilyFallback: HuahuoTypography.fallbacks,
              letterSpacing: 0,
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(text),
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontFamily: HuahuoTypography.primaryFamily,
              fontFamilyFallback: HuahuoTypography.fallbacks,
              letterSpacing: 0,
            ),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: line)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadii.control),
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: textSecondary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadii.control),
          borderSide: BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadii.control),
          borderSide: BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadii.control),
          borderSide: BorderSide(color: primary),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HuahuoRadii.panel),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black.withValues(
          alpha: brightness == Brightness.dark ? 0.28 : 0.1,
        ),
        textStyle: TextStyle(
          color: text,
          fontSize: 13,
          fontWeight: FontWeight.w400,
          fontFamily: HuahuoTypography.primaryFamily,
          fontFamilyFallback: HuahuoTypography.fallbacks,
          letterSpacing: 0,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HuahuoRadii.control),
          side: BorderSide(color: line),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: surfaceMuted,
        circularTrackColor: surfaceMuted,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: text,
        contentTextStyle: TextStyle(color: canvas, letterSpacing: 0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HuahuoRadii.control),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: DesktopInteractionTimingTokens.tooltipWait,
        decoration: BoxDecoration(
          color: text,
          borderRadius: BorderRadius.circular(HuahuoRadii.navigation),
        ),
        textStyle: TextStyle(color: canvas, fontSize: 12, letterSpacing: 0),
      ),
    );
  }
}
