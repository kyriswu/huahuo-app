import 'package:flutter/material.dart';

const huahuoV3UiEnabled = bool.fromEnvironment(
  'HUAHUO_V3_UI',
  defaultValue: true,
);

enum HuahuoV3Palette { neutral, mistBlue, pineGreen, warmGold, sakura, aurora }

abstract final class HuahuoSpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  static const page = md;
  static const pageWide = lg;
  static const section = lg;
  static const compact = xs;
}

abstract final class HuahuoRadius {
  static const compact = 8.0;
  static const regular = 12.0;
  static const emphasis = 16.0;

  static const control = compact;
  static const surface = regular;
  static const emphasized = emphasis;
}

abstract final class HuahuoControlSize {
  static const icon = 40.0;
  static const iconComfortable = 44.0;
  static const button = 46.0;
  static const primaryButton = 50.0;
  static const input = 48.0;
}

abstract final class HuahuoElevation {
  static const flat = 0.0;
  static const raised = 1.0;
  static const floating = 4.0;
  static const overlay = 8.0;
}

abstract final class HuahuoTypography {
  static const pageTitle = TextStyle(
    fontFamily: HuahuoV3Theme.fontFamily,
    fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
    fontSize: 20,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
  static const sectionTitle = TextStyle(
    fontFamily: HuahuoV3Theme.fontFamily,
    fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
    fontSize: 18,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const body = TextStyle(
    fontFamily: HuahuoV3Theme.fontFamily,
    fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
  );
  static const supporting = TextStyle(
    fontFamily: HuahuoV3Theme.fontFamily,
    fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
  );
  static const button = TextStyle(
    fontFamily: HuahuoV3Theme.fontFamily,
    fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
    fontSize: 16,
    height: 1,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const compactLabel = TextStyle(
    fontFamily: HuahuoV3Theme.fontFamily,
    fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
    fontSize: 12,
    height: 1.25,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
  );
}

@immutable
final class HuahuoV3GlassTokens {
  const HuahuoV3GlassTokens({
    required this.tint,
    required this.selectedTint,
    required this.rim,
    required this.fallback,
    required this.selectedFallback,
  });

  final Color tint;
  final Color selectedTint;
  final Color rim;
  final Color fallback;
  final Color selectedFallback;

  HuahuoV3GlassTokens lerp(HuahuoV3GlassTokens other, double t) {
    return HuahuoV3GlassTokens(
      tint: Color.lerp(tint, other.tint, t)!,
      selectedTint: Color.lerp(selectedTint, other.selectedTint, t)!,
      rim: Color.lerp(rim, other.rim, t)!,
      fallback: Color.lerp(fallback, other.fallback, t)!,
      selectedFallback: Color.lerp(
        selectedFallback,
        other.selectedFallback,
        t,
      )!,
    );
  }
}

@immutable
final class HuahuoV3ThemeTokens extends ThemeExtension<HuahuoV3ThemeTokens> {
  const HuahuoV3ThemeTokens({
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
    required this.warmGlass,
    required this.coolGlass,
    required this.neutralGlass,
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
  final HuahuoV3GlassTokens warmGlass;
  final HuahuoV3GlassTokens coolGlass;
  final HuahuoV3GlassTokens neutralGlass;

  @override
  HuahuoV3ThemeTokens copyWith({
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
    HuahuoV3GlassTokens? warmGlass,
    HuahuoV3GlassTokens? coolGlass,
    HuahuoV3GlassTokens? neutralGlass,
  }) {
    return HuahuoV3ThemeTokens(
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
      warmGlass: warmGlass ?? this.warmGlass,
      coolGlass: coolGlass ?? this.coolGlass,
      neutralGlass: neutralGlass ?? this.neutralGlass,
    );
  }

  @override
  HuahuoV3ThemeTokens lerp(covariant HuahuoV3ThemeTokens? other, double t) {
    if (other == null) return this;
    return HuahuoV3ThemeTokens(
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
      warmGlass: warmGlass.lerp(other.warmGlass, t),
      coolGlass: coolGlass.lerp(other.coolGlass, t),
      neutralGlass: neutralGlass.lerp(other.neutralGlass, t),
    );
  }
}

final class HuahuoV3Theme {
  const HuahuoV3Theme._();

  static const ink = Color(0xFF090909);
  static const text = Color(0xFF2E2E2E);
  static const muted = Color(0xFF6F6F6F);
  static const faint = Color(0xFFF6F6F6);
  static const line = Color(0xFFE7E7E7);
  static const gold = Color(0xFF93662E);
  static const warmGold = Color(0xFFD0A05A);
  static const card = Color(0xFFFFFFFF);

  // Liquid glass is always rendered on V3's light canvas. These tone tokens
  // keep translucent shader output and opaque accessibility fallbacks aligned.
  static const glassWarmTint = Color(0x08D7B079);
  static const glassWarmSelectedTint = Color(0x14CB8E43);
  static const glassWarmRim = Color(0xFFC99858);
  static const glassWarmFallback = Color(0xFFFFF8EF);
  static const glassWarmSelectedFallback = Color(0xFFFFE9CC);

  static const glassCoolTint = Color(0x05C6E3F1);
  static const glassCoolSelectedTint = Color(0x0AB9D9EA);
  static const glassCoolRim = Color(0xFFD7E4EF);
  static const glassCoolFallback = Color(0xFFF3FAFE);
  static const glassCoolSelectedFallback = Color(0xFFD9EFFB);

  static const glassNeutralTint = Color(0x04F0F4F7);
  static const glassNeutralSelectedTint = Color(0x08DDE7ED);
  static const glassNeutralRim = Color(0xFFD7E1E7);
  static const glassNeutralFallback = Color(0xFFF9FBFC);
  static const glassNeutralSelectedFallback = Color(0xFFE9F0F3);

  static const fontFamily = 'PingFang SC';
  static const fontFamilyFallback = <String>[
    'PingFang SC',
    'Helvetica Neue',
    'Noto Sans SC',
    'Roboto',
  ];

  static const feedTitleSize = 22.0;
  static const pageTitleSize = 20.0;
  static const pageLabelSize = 19.0;
  static const navigationTitleSize = 18.0;
  static const appTextScale = 1.0;

  static const pageLabel = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: pageLabelSize,
    height: 1.2,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
  );
  static const h1 = HuahuoTypography.pageTitle;
  static const navigationTitle = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: navigationTitleSize,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const sectionTitle = HuahuoTypography.sectionTitle;
  static const listTitle = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 17,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  static const body = HuahuoTypography.body;
  static const meta = HuahuoTypography.supporting;
  static const button = HuahuoTypography.button;
  static const compactLabel = HuahuoTypography.compactLabel;

  static const cardRadius = 24.0;
  static const topIconButtonSize = 44.0;
  static const topIconSize = 25.0;
  static const primaryButtonHeight = 52.0;
  static const listIconSize = 46.0;
  static const listIconGlyphSize = 26.0;

  static const lightTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: faint,
    ink: ink,
    text: text,
    muted: muted,
    line: line,
    primary: ink,
    onPrimary: Color(0xFFFFFFFF),
    accent: gold,
    success: Color(0xFF5B7661),
    danger: Color(0xFFB54A22),
    warmGlass: HuahuoV3GlassTokens(
      tint: glassWarmTint,
      selectedTint: glassWarmSelectedTint,
      rim: glassWarmRim,
      fallback: glassWarmFallback,
      selectedFallback: glassWarmSelectedFallback,
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: glassCoolTint,
      selectedTint: glassCoolSelectedTint,
      rim: glassCoolRim,
      fallback: glassCoolFallback,
      selectedFallback: glassCoolSelectedFallback,
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: glassNeutralTint,
      selectedTint: glassNeutralSelectedTint,
      rim: glassNeutralRim,
      fallback: glassNeutralFallback,
      selectedFallback: glassNeutralSelectedFallback,
    ),
  );

  static const darkTokens = HuahuoV3ThemeTokens(
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
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x183A3025),
      selectedTint: Color(0x2A735533),
      rim: Color(0xFF8F714D),
      fallback: Color(0xFF2B251F),
      selectedFallback: Color(0xFF3A2D1F),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x18323E46),
      selectedTint: Color(0x28435E6C),
      rim: Color(0xFF526878),
      fallback: Color(0xFF1B252B),
      selectedFallback: Color(0xFF263943),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x163A4147),
      selectedTint: Color(0x26495259),
      rim: Color(0xFF59636B),
      fallback: Color(0xFF202326),
      selectedFallback: Color(0xFF30363A),
    ),
  );

  static const mistBlueTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFFF7FAFC),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF0F5F8),
    ink: Color(0xFF132A3A),
    text: Color(0xFF2D3B45),
    muted: Color(0xFF637079),
    line: Color(0xFFDCE6EC),
    primary: Color(0xFF315F7D),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFF597281),
    success: Color(0xFF547565),
    danger: Color(0xFFA95645),
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x08CDBA9C),
      selectedTint: Color(0x16B79261),
      rim: Color(0xFFC5AA82),
      fallback: Color(0xFFFFFAF2),
      selectedFallback: Color(0xFFFFEBD2),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x0D8BB8D2),
      selectedTint: Color(0x1C6FA4C1),
      rim: Color(0xFF9CBACB),
      fallback: Color(0xFFF0F8FC),
      selectedFallback: Color(0xFFDCEEF7),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x08D5E2E9),
      selectedTint: Color(0x12C2D4DE),
      rim: Color(0xFFC8D8E1),
      fallback: Color(0xFFF8FBFC),
      selectedFallback: Color(0xFFE8F1F5),
    ),
  );

  static const mistBlueDarkTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFF101820),
    surface: Color(0xFF17232B),
    surfaceMuted: Color(0xFF20323B),
    ink: Color(0xFFEDF8FC),
    text: Color(0xFFDCEBF1),
    muted: Color(0xFFA7BBC4),
    line: Color(0xFF304752),
    primary: Color(0xFF9BC9E2),
    onPrimary: Color(0xFF102A37),
    accent: Color(0xFFB0CAD7),
    success: Color(0xFF93BFA8),
    danger: Color(0xFFF19A85),
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x1F80633E),
      selectedTint: Color(0x31A77A43),
      rim: Color(0xFF816B4F),
      fallback: Color(0xFF2B251E),
      selectedFallback: Color(0xFF3A2D1F),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x25466E86),
      selectedTint: Color(0x3A548EAE),
      rim: Color(0xFF527F98),
      fallback: Color(0xFF192A34),
      selectedFallback: Color(0xFF223C4B),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x1C50636D),
      selectedTint: Color(0x2E637D8A),
      rim: Color(0xFF526A76),
      fallback: Color(0xFF1D282E),
      selectedFallback: Color(0xFF2A3A43),
    ),
  );

  static const pineGreenTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFFF7FAF7),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFEFF5F1),
    ink: Color(0xFF193328),
    text: Color(0xFF304239),
    muted: Color(0xFF63716A),
    line: Color(0xFFDCE7E0),
    primary: Color(0xFF365E4B),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFF607267),
    success: Color(0xFF4E755F),
    danger: Color(0xFFA75847),
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x09D1B990),
      selectedTint: Color(0x18B99158),
      rim: Color(0xFFC3A36E),
      fallback: Color(0xFFFFFAF0),
      selectedFallback: Color(0xFFFFEAC8),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x0A91B7A3),
      selectedTint: Color(0x1A719C85),
      rim: Color(0xFFA5C0B2),
      fallback: Color(0xFFF1F8F4),
      selectedFallback: Color(0xFFDDEDE4),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x08D7E2DA),
      selectedTint: Color(0x14C2D4C8),
      rim: Color(0xFFCAD9D0),
      fallback: Color(0xFFF9FBF9),
      selectedFallback: Color(0xFFE9F1EC),
    ),
  );

  static const pineGreenDarkTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFF111914),
    surface: Color(0xFF18231D),
    surfaceMuted: Color(0xFF223128),
    ink: Color(0xFFEFF8F1),
    text: Color(0xFFDDECE2),
    muted: Color(0xFFA8BBAE),
    line: Color(0xFF33483A),
    primary: Color(0xFF9BC9AA),
    onPrimary: Color(0xFF133020),
    accent: Color(0xFFB6C9BC),
    success: Color(0xFF8BC5A1),
    danger: Color(0xFFF09A86),
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x20836A3D),
      selectedTint: Color(0x32A57C3C),
      rim: Color(0xFF826E48),
      fallback: Color(0xFF2B271C),
      selectedFallback: Color(0xFF39311E),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x20507361),
      selectedTint: Color(0x34689379),
      rim: Color(0xFF557B66),
      fallback: Color(0xFF1B2921),
      selectedFallback: Color(0xFF263B2F),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x1B53675A),
      selectedTint: Color(0x2E688171),
      rim: Color(0xFF586E60),
      fallback: Color(0xFF202A24),
      selectedFallback: Color(0xFF2D3A32),
    ),
  );

  static const warmGoldTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFFFDFBF7),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFFAF3E8),
    ink: Color(0xFF342719),
    text: Color(0xFF463A2D),
    muted: Color(0xFF766C60),
    line: Color(0xFFECE1D3),
    primary: Color(0xFF725226),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFF8B6838),
    success: Color(0xFF5F745B),
    danger: Color(0xFFAB563E),
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x0FCB9A54),
      selectedTint: Color(0x24B9782F),
      rim: Color(0xFFC3904E),
      fallback: Color(0xFFFFF8EC),
      selectedFallback: Color(0xFFFFE5BF),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x08A8C1CB),
      selectedTint: Color(0x168DAFBD),
      rim: Color(0xFFB7C9CF),
      fallback: Color(0xFFF4F9FA),
      selectedFallback: Color(0xFFE1EEF1),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x09E4D8C8),
      selectedTint: Color(0x18D3BFA4),
      rim: Color(0xFFDDCDB9),
      fallback: Color(0xFFFCFAF7),
      selectedFallback: Color(0xFFF2E8DB),
    ),
  );

  static const warmGoldDarkTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFF1B1610),
    surface: Color(0xFF241D15),
    surfaceMuted: Color(0xFF32281C),
    ink: Color(0xFFFFF4E3),
    text: Color(0xFFF0E1CB),
    muted: Color(0xFFC5B093),
    line: Color(0xFF4A3A28),
    primary: Color(0xFFE7BD7D),
    onPrimary: Color(0xFF33230D),
    accent: Color(0xFFE1BB80),
    success: Color(0xFFA7C194),
    danger: Color(0xFFF0A08A),
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x27916C32),
      selectedTint: Color(0x3DB88B40),
      rim: Color(0xFF97743E),
      fallback: Color(0xFF30271A),
      selectedFallback: Color(0xFF45341D),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x1B526875),
      selectedTint: Color(0x2B687F8C),
      rim: Color(0xFF60747D),
      fallback: Color(0xFF20282C),
      selectedFallback: Color(0xFF2A373D),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x1E6A5A46),
      selectedTint: Color(0x307E694F),
      rim: Color(0xFF75634D),
      fallback: Color(0xFF29231B),
      selectedFallback: Color(0xFF393026),
    ),
  );

  static const sakuraTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFFFFF8FB),
    surface: Color(0xFFFFFDFE),
    surfaceMuted: Color(0xFFFAEDF3),
    ink: Color(0xFF3B1F2B),
    text: Color(0xFF523744),
    muted: Color(0xFF7C6671),
    line: Color(0xFFEDD7E0),
    primary: Color(0xFFA64F73),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFF965A71),
    success: Color(0xFF487562),
    danger: Color(0xFFB04B5B),
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x12E58AAD),
      selectedTint: Color(0x28D86B96),
      rim: Color(0xFFD882A4),
      fallback: Color(0xFFFFF4F8),
      selectedFallback: Color(0xFFFFDCE9),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x0B91B9D5),
      selectedTint: Color(0x1A72A3C5),
      rim: Color(0xFFB6CFE0),
      fallback: Color(0xFFF5FAFD),
      selectedFallback: Color(0xFFE1F0F8),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x0AE9D7DF),
      selectedTint: Color(0x18DCC2CE),
      rim: Color(0xFFDFC9D2),
      fallback: Color(0xFFFFFBFC),
      selectedFallback: Color(0xFFF6E8EE),
    ),
  );

  static const sakuraDarkTokens = HuahuoV3ThemeTokens(
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
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x24A64F73),
      selectedTint: Color(0x3AD86B96),
      rim: Color(0xFF9D5E78),
      fallback: Color(0xFF35222B),
      selectedFallback: Color(0xFF4A2937),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x1B527A91),
      selectedTint: Color(0x2D689CB8),
      rim: Color(0xFF587A8E),
      fallback: Color(0xFF202C33),
      selectedFallback: Color(0xFF293E49),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x1B6D5661),
      selectedTint: Color(0x2D8B6677),
      rim: Color(0xFF725361),
      fallback: Color(0xFF2A2025),
      selectedFallback: Color(0xFF3A2931),
    ),
  );

  static const auroraTokens = HuahuoV3ThemeTokens(
    canvas: Color(0xFFF7FBFC),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFECF6F7),
    ink: Color(0xFF102C35),
    text: Color(0xFF29434A),
    muted: Color(0xFF5E7277),
    line: Color(0xFFD3E5E8),
    primary: Color(0xFF006F86),
    onPrimary: Color(0xFFFFFFFF),
    accent: Color(0xFFBB4175),
    success: Color(0xFF1E7C63),
    danger: Color(0xFFB74C4A),
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x10F1BB3E),
      selectedTint: Color(0x24E9A926),
      rim: Color(0xFFD7AA43),
      fallback: Color(0xFFFFFAEB),
      selectedFallback: Color(0xFFFFEDBB),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x1000A8E9),
      selectedTint: Color(0x260068BA),
      rim: Color(0xFF7AC8DE),
      fallback: Color(0xFFF0FAFD),
      selectedFallback: Color(0xFFD5F2FA),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x0CD0E6E8),
      selectedTint: Color(0x1CC2DBDE),
      rim: Color(0xFFBFD8DC),
      fallback: Color(0xFFF8FCFC),
      selectedFallback: Color(0xFFE7F3F4),
    ),
  );

  static const auroraDarkTokens = HuahuoV3ThemeTokens(
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
    warmGlass: HuahuoV3GlassTokens(
      tint: Color(0x24C99728),
      selectedTint: Color(0x36E0AE38),
      rim: Color(0xFF927532),
      fallback: Color(0xFF312B1D),
      selectedFallback: Color(0xFF453A20),
    ),
    coolGlass: HuahuoV3GlassTokens(
      tint: Color(0x240068BA),
      selectedTint: Color(0x3800A8E9),
      rim: Color(0xFF397F94),
      fallback: Color(0xFF152B32),
      selectedFallback: Color(0xFF173B46),
    ),
    neutralGlass: HuahuoV3GlassTokens(
      tint: Color(0x1C3B6970),
      selectedTint: Color(0x2E4D838B),
      rim: Color(0xFF496E75),
      fallback: Color(0xFF1B292D),
      selectedFallback: Color(0xFF263A3F),
    ),
  );

  static HuahuoV3ThemeTokens tokensOf(BuildContext context) {
    return Theme.of(context).extension<HuahuoV3ThemeTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? darkTokens
            : lightTokens);
  }

  /// WCAG contrast ratio for opaque foreground/background pairs.
  static double contrastRatio(Color foreground, Color background) {
    final first = foreground.computeLuminance();
    final second = background.computeLuminance();
    final lighter = first > second ? first : second;
    final darker = first > second ? second : first;
    return (lighter + .05) / (darker + .05);
  }

  /// Uses [fallback] when a supplied foreground would disappear into its
  /// surrounding surface. This keeps user-authored Markdown colours readable.
  static Color readableForeground(
    Color preferred, {
    required Color background,
    required Color fallback,
    double minimumRatio = 4.5,
  }) => contrastRatio(preferred, background) >= minimumRatio
      ? preferred
      : fallback;

  /// Resolves a readable foreground for arbitrary user-authored backgrounds.
  /// Unlike theme surfaces, these colors are not constrained to one palette.
  static Color contrastingForeground(
    Color preferred, {
    required Color background,
    double minimumRatio = 4.5,
  }) {
    if (contrastRatio(preferred, background) >= minimumRatio) return preferred;
    const dark = Color(0xFF111111);
    const light = Color(0xFFF7F7F7);
    return contrastRatio(dark, background) >= contrastRatio(light, background)
        ? dark
        : light;
  }

  /// Builds a theme-aware status surface without leaking a light-only fill
  /// into dark or chromatic palettes.
  static Color semanticSurface(
    Color emphasis,
    Color background, {
    double opacity = .12,
  }) => Color.alphaBlend(emphasis.withValues(alpha: opacity), background);

  static ThemeData light({HuahuoV3Palette palette = HuahuoV3Palette.neutral}) {
    return _buildTheme(_tokensFor(palette, Brightness.light), Brightness.light);
  }

  static ThemeData dark({HuahuoV3Palette palette = HuahuoV3Palette.neutral}) {
    return _buildTheme(_tokensFor(palette, Brightness.dark), Brightness.dark);
  }

  static ThemeData themeFor({
    required HuahuoV3Palette palette,
    required Brightness brightness,
  }) {
    return _buildTheme(_tokensFor(palette, brightness), brightness);
  }

  static ThemeData fromTokens({
    required HuahuoV3ThemeTokens tokens,
    required Brightness brightness,
  }) => _buildTheme(tokens, brightness);

  static HuahuoV3ThemeTokens _tokensFor(
    HuahuoV3Palette palette,
    Brightness brightness,
  ) {
    if (brightness == Brightness.dark) {
      return switch (palette) {
        HuahuoV3Palette.mistBlue => mistBlueDarkTokens,
        HuahuoV3Palette.pineGreen => pineGreenDarkTokens,
        HuahuoV3Palette.warmGold => warmGoldDarkTokens,
        HuahuoV3Palette.sakura => sakuraDarkTokens,
        HuahuoV3Palette.aurora => auroraDarkTokens,
        HuahuoV3Palette.neutral => darkTokens,
      };
    }
    return switch (palette) {
      HuahuoV3Palette.neutral => lightTokens,
      HuahuoV3Palette.mistBlue => mistBlueTokens,
      HuahuoV3Palette.pineGreen => pineGreenTokens,
      HuahuoV3Palette.warmGold => warmGoldTokens,
      HuahuoV3Palette.sakura => sakuraTokens,
      HuahuoV3Palette.aurora => auroraTokens,
    };
  }

  static List<Color> graphPaletteOf(BuildContext context) {
    return graphPaletteFor(tokensOf(context));
  }

  static List<Color> graphPaletteFor(HuahuoV3ThemeTokens tokens) {
    return List<Color>.unmodifiable(<Color>[
      tokens.primary,
      Color.lerp(tokens.primary, tokens.coolGlass.rim, .62)!,
      tokens.success,
      Color.lerp(tokens.warmGlass.rim, tokens.danger, .24)!,
      tokens.accent,
    ]);
  }

  static ThemeData _buildTheme(
    HuahuoV3ThemeTokens tokens,
    Brightness brightness,
  ) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: tokens.primary,
          brightness: brightness,
          primary: tokens.primary,
          secondary: tokens.accent,
          surface: tokens.surface,
          error: tokens.danger,
        ).copyWith(
          onPrimary: tokens.onPrimary,
          onSecondary: readableForeground(
            tokens.onPrimary,
            background: tokens.accent,
            fallback: tokens.ink,
            minimumRatio: 3,
          ),
          onSurface: tokens.text,
          onSurfaceVariant: tokens.muted,
          outline: tokens.line,
          outlineVariant: tokens.line,
          surfaceContainerLowest: tokens.canvas,
          surfaceContainerLow: tokens.surfaceMuted,
          surfaceContainer: tokens.surfaceMuted,
          surfaceContainerHigh: tokens.surfaceMuted,
          surfaceContainerHighest: tokens.surfaceMuted,
          surfaceDim: tokens.canvas,
          surfaceBright: tokens.surface,
          inverseSurface: tokens.ink,
          onInverseSurface: tokens.canvas,
          surfaceTint: Colors.transparent,
        );
    final base = ThemeData(
      useMaterial3: true,
      applyElevationOverlayColor: false,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: tokens.canvas,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      extensions: <ThemeExtension<dynamic>>[tokens],
    );
    return base.copyWith(
      textTheme: base.textTheme
          .copyWith(
            headlineSmall: HuahuoTypography.pageTitle.copyWith(
              color: tokens.ink,
            ),
            titleLarge: HuahuoTypography.sectionTitle.copyWith(
              color: tokens.ink,
            ),
            bodyLarge: HuahuoTypography.body.copyWith(color: tokens.text),
            bodyMedium: HuahuoTypography.body.copyWith(color: tokens.text),
            bodySmall: HuahuoTypography.supporting.copyWith(
              color: tokens.muted,
            ),
            labelLarge: HuahuoTypography.button.copyWith(color: tokens.text),
            labelMedium: HuahuoTypography.compactLabel.copyWith(
              color: tokens.muted,
            ),
          )
          .apply(
            bodyColor: tokens.text,
            displayColor: tokens.ink,
            fontFamily: fontFamily,
          ),
      dividerColor: tokens.line,
      appBarTheme: AppBarTheme(
        elevation: HuahuoElevation.flat,
        scrolledUnderElevation: HuahuoElevation.flat,
        backgroundColor: tokens.canvas,
        foregroundColor: tokens.ink,
        centerTitle: true,
        titleTextStyle: HuahuoTypography.sectionTitle.copyWith(
          color: tokens.ink,
        ),
        iconTheme: IconThemeData(color: tokens.ink, size: 20),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.surfaceMuted,
        hintStyle: HuahuoTypography.body.copyWith(color: tokens.muted),
        labelStyle: HuahuoTypography.supporting.copyWith(color: tokens.muted),
        floatingLabelStyle: HuahuoTypography.supporting.copyWith(
          color: tokens.primary,
        ),
        helperStyle: HuahuoTypography.supporting.copyWith(color: tokens.muted),
        prefixStyle: HuahuoTypography.body.copyWith(color: tokens.text),
        suffixStyle: HuahuoTypography.body.copyWith(color: tokens.text),
        errorStyle: HuahuoTypography.supporting.copyWith(color: tokens.danger),
        constraints: const BoxConstraints(minHeight: HuahuoControlSize.input),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: HuahuoSpacing.md,
          vertical: HuahuoSpacing.sm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.compact),
          borderSide: BorderSide(color: tokens.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.compact),
          borderSide: BorderSide(color: tokens.line),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.compact),
          borderSide: BorderSide(color: tokens.line.withValues(alpha: .55)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.compact),
          borderSide: BorderSide(color: tokens.primary, width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.compact),
          borderSide: BorderSide(color: tokens.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.compact),
          borderSide: BorderSide(color: tokens.danger, width: 1.2),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size.square(HuahuoControlSize.icon),
          ),
          iconSize: const WidgetStatePropertyAll(20),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.disabled)
                ? tokens.muted.withValues(alpha: .45)
                : tokens.ink;
          }),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadius.compact),
            ),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size(0, HuahuoControlSize.primaryButton),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: HuahuoSpacing.lg),
          ),
          textStyle: const WidgetStatePropertyAll(HuahuoTypography.button),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadius.regular),
            ),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          minimumSize: const WidgetStatePropertyAll(
            Size(0, HuahuoControlSize.primaryButton),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: HuahuoSpacing.lg),
          ),
          textStyle: const WidgetStatePropertyAll(HuahuoTypography.button),
          elevation: const WidgetStatePropertyAll(HuahuoElevation.raised),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadius.regular),
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size(0, HuahuoControlSize.button),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: HuahuoSpacing.md),
          ),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.disabled)
                ? tokens.muted.withValues(alpha: .45)
                : tokens.text;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            return BorderSide(
              color: states.contains(WidgetState.disabled)
                  ? tokens.line.withValues(alpha: .55)
                  : tokens.line,
            );
          }),
          textStyle: const WidgetStatePropertyAll(HuahuoTypography.button),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadius.regular),
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size(0, HuahuoControlSize.button),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: HuahuoSpacing.md),
          ),
          textStyle: const WidgetStatePropertyAll(HuahuoTypography.button),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.disabled)
                ? tokens.muted.withValues(alpha: .45)
                : tokens.primary;
          }),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadius.compact),
            ),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: tokens.surface,
        surfaceTintColor: Colors.transparent,
        elevation: HuahuoElevation.flat,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.regular),
          side: BorderSide(color: tokens.line),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: HuahuoElevation.flat,
        insetPadding: EdgeInsets.symmetric(
          horizontal: HuahuoSpacing.lg,
          vertical: HuahuoSpacing.xl,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: HuahuoElevation.flat,
        modalElevation: HuahuoElevation.flat,
        constraints: BoxConstraints(maxWidth: double.infinity),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          textStyle: const WidgetStatePropertyAll(meta),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? tokens.primary
                : tokens.text;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? tokens.neutralGlass.selectedFallback
                : tokens.surface;
          }),
          side: WidgetStatePropertyAll(BorderSide(color: tokens.line)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HuahuoRadius.compact),
            ),
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: tokens.surface,
        selectedColor: tokens.coolGlass.selectedFallback,
        side: BorderSide(color: tokens.line),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.compact),
        ),
        labelStyle: meta.copyWith(
          color: tokens.text,
          fontWeight: FontWeight.w600,
        ),
      ),
      listTileTheme: ListTileThemeData(
        textColor: tokens.text,
        iconColor: tokens.ink,
        titleTextStyle: HuahuoTypography.body.copyWith(color: tokens.ink),
        subtitleTextStyle: HuahuoTypography.supporting.copyWith(
          color: tokens.muted,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: tokens.surface,
        surfaceTintColor: Colors.transparent,
        textStyle: HuahuoTypography.body.copyWith(color: tokens.text),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: tokens.primary),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: tokens.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.emphasis),
        ),
        headerBackgroundColor: tokens.surfaceMuted,
        headerForegroundColor: tokens.ink,
        dayShape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HuahuoRadius.compact),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: tokens.ink,
        elevation: HuahuoElevation.floating,
        contentTextStyle: TextStyle(
          color: tokens.canvas,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HuahuoRadius.regular),
        ),
      ),
    );
  }
}
