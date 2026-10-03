import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../theme/huahuo_v3_theme.dart';

/// V3 liquid-glass colour families. The token values live in [HuahuoV3Theme].
enum V3GlassTone { warm, cool, neutral }

/// Optical treatments for rounded liquid-glass surfaces.
enum V3GlassSurfaceStyle { panel, dock, dockSelection, subtle }

enum V3VisualQuality { high, balanced, constrained }

/// Projects the central runtime quality into glass without coupling shared UI
/// primitives to Riverpod or application lifecycle implementations.
class V3GlassPerformanceScope extends InheritedWidget {
  const V3GlassPerformanceScope({
    required super.child,
    required this.quality,
    required this.adaptiveQuality,
    super.key,
  });

  final V3VisualQuality quality;
  final bool adaptiveQuality;

  static V3GlassPerformanceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<V3GlassPerformanceScope>();

  static bool constrainedOf(BuildContext context) {
    final scope = maybeOf(context);
    return scope != null &&
        scope.adaptiveQuality &&
        scope.quality == V3VisualQuality.constrained;
  }

  static double resolveBlurSigma(
    BuildContext context, {
    required double requested,
    required double balancedMaximum,
  }) {
    final normalizedRequested = requested.clamp(0, double.infinity).toDouble();
    final scope = maybeOf(context);
    if (scope == null || !scope.adaptiveQuality) return normalizedRequested;
    return switch (scope.quality) {
      V3VisualQuality.high => normalizedRequested,
      V3VisualQuality.balanced =>
        normalizedRequested.clamp(0, balancedMaximum).toDouble(),
      V3VisualQuality.constrained => 0,
    };
  }

  @override
  bool updateShouldNotify(V3GlassPerformanceScope oldWidget) =>
      oldWidget.quality != quality ||
      oldWidget.adaptiveQuality != adaptiveQuality;
}

final class V3MotionTokens {
  const V3MotionTokens._();

  static const micro = Duration(milliseconds: 70);
  static const responsive = Duration(milliseconds: 120);
  static const compact = Duration(milliseconds: 140);
  static const quick = Duration(milliseconds: 160);
  static const panelRoute = Duration(milliseconds: 170);
  static const standard = Duration(milliseconds: 180);
  static const emphasized = Duration(milliseconds: 220);
  static const routeEnter = Duration(milliseconds: 240);
  static const deliberate = routeEnter;
  static const routeExit = Duration(milliseconds: 200);
  static const pageTravel = Duration(milliseconds: 260);
  static const settled = Duration(milliseconds: 280);
  static const reveal = Duration(milliseconds: 300);
  static const slow = Duration(milliseconds: 360);
  static const graphEntrance = Duration(milliseconds: 800);
  static const graphPulse = Duration(seconds: 2);
  static const aggregation = Duration(milliseconds: 2400);
  static const brandReveal = Duration(seconds: 3);
  static const activityPulse = Duration(milliseconds: 1200);
  static const waveformLoop = Duration(milliseconds: 1400);
  static const ambientLoop = Duration(milliseconds: 2400);

  static Duration resolve(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
}

final class V3FeedbackTimingTokens {
  const V3FeedbackTimingTokens._();

  static const standardSnack = Duration(seconds: 4);
  static const importantSnack = Duration(seconds: 6);
  static const brief = Duration(seconds: 2);
  static const destructiveConfirmation = Duration(milliseconds: 280);
  static const connectionSuccess = Duration(milliseconds: 520);
  static const graphCompletion = Duration(seconds: 2);
}

final class V3InteractionTimingTokens {
  const V3InteractionTimingTokens._();

  static const graphLongPress = Duration(milliseconds: 220);
  static const sheetDismissal = Duration(milliseconds: 220);
  static const keyboardDismissal = Duration(milliseconds: 180);
  static const carouselAdvance = Duration(seconds: 5);
}

final class V3GlassEffectTokens {
  const V3GlassEffectTokens._();

  static const iconActionSigma = 18.0;
  static const floatingHubSigma = 22.0;
  static const floatingDockSigma = 16.0;
  static const floatingSelectionSigma = 9.0;
  static const sidePanelSigma = 26.0;
  static const balancedFloatingDockSigma = 10.0;
  static const balancedFloatingSelectionSigma = 7.0;
  static const chatMarkSigmaScale = .28;
  static const chatMarkMinimumSigma = 5.0;
  static const chatMarkMaximumSigma = 15.0;

  static double chatMarkSigma(double size) => (size * chatMarkSigmaScale)
      .clamp(chatMarkMinimumSigma, chatMarkMaximumSigma)
      .toDouble();

  static double surfaceSigma(V3GlassSurfaceStyle style) => switch (style) {
    V3GlassSurfaceStyle.panel => 18,
    V3GlassSurfaceStyle.dock => 22,
    V3GlassSurfaceStyle.dockSelection => 18,
    V3GlassSurfaceStyle.subtle => 14,
  };

  static double balancedSurfaceSigma(V3GlassSurfaceStyle style) =>
      switch (style) {
        V3GlassSurfaceStyle.panel => 12,
        V3GlassSurfaceStyle.dock => 14,
        V3GlassSurfaceStyle.dockSelection => 12,
        V3GlassSurfaceStyle.subtle => 9,
      };
}

final class V3GraphEffectTokens {
  const V3GraphEffectTokens._();

  static const selectedEdgeGlowSigma = 2.8;
  static const edgeGlowSigma = 1.7;
  static const outerNodeHaloMinimumSigma = 2.2;
  static const outerNodeHaloRadiusFactor = .52;
  static const innerNodeHaloMinimumSigma = .8;
  static const innerNodeHaloRadiusFactor = .16;
}

/// Keeps the first app frame on static surfaces until shaders are ready.
class V3GlassRuntimeScope extends InheritedWidget {
  const V3GlassRuntimeScope({
    required super.child,
    required this.enabled,
    super.key,
  });

  final bool enabled;

  static bool enabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<V3GlassRuntimeScope>()
          ?.enabled ??
      true;

  @override
  bool updateShouldNotify(V3GlassRuntimeScope oldWidget) =>
      oldWidget.enabled != enabled;
}

/// Enables liquid glass only for the app's top-level home canvases.
class V3GlassHomeScope extends InheritedWidget {
  const V3GlassHomeScope({
    required super.child,
    this.enabled = true,
    super.key,
  });

  final bool enabled;

  static bool enabledOf(BuildContext context) {
    final homeEnabled =
        context
            .dependOnInheritedWidgetOfExactType<V3GlassHomeScope>()
            ?.enabled ??
        false;
    return homeEnabled && V3GlassRuntimeScope.enabledOf(context);
  }

  @override
  bool updateShouldNotify(V3GlassHomeScope oldWidget) =>
      oldWidget.enabled != enabled;
}

/// Supplies the user-selected glass opacity to every V3 glass primitive.
class V3GlassOpacityScope extends InheritedWidget {
  const V3GlassOpacityScope({
    required super.child,
    required this.percent,
    super.key,
  });

  final int percent;

  static int percentOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<V3GlassOpacityScope>()
            ?.percent ??
        50;
  }

  /// Fifty percent preserves the calibrated baseline appearance.
  static double alphaScaleOf(BuildContext context) =>
      (percentOf(context).clamp(0, 100) / 50).clamp(0.0, 2.0).toDouble();

  @override
  bool updateShouldNotify(V3GlassOpacityScope oldWidget) =>
      oldWidget.percent != percent;
}

/// Shared V3 liquid-glass material, interaction, and accessibility settings.
final class V3GlassSpec {
  const V3GlassSpec._();

  static const interactionScale = 1.018;
  static const interactionStretch = 0.10;
  static const iconActionDiameter = 44.0;
  static const surfaceRadius = 28.0;
  static const edgeStrokeScale = 0.15;
  static const edgeBlurScale = 0.30;
  static const edgeInsetScale = 0.30;

  static double edgeStroke(double width) => width * edgeStrokeScale;
  static double edgeBlur(double radius) => radius * edgeBlurScale;
  static double edgeInset(double distance) => distance * edgeInsetScale;
  static double edgeRadius(double scale) => 1 - ((1 - scale) * edgeInsetScale);

  static const _lightVariant = GlassThemeVariant(
    settings: GlassThemeSettings(
      glassColor: HuahuoV3Theme.glassNeutralTint,
      thickness: 24,
      blur: 7,
      chromaticAberration: 0.018,
      lightAngle: 2.356,
      lightIntensity: 1.06,
      ambientStrength: 0.24,
      refractiveIndex: 1.20,
      saturation: 1.04,
      specularSharpness: GlassSpecularSharpness.sharp,
    ),
    quality: GlassQuality.standard,
    borderRadius: surfaceRadius,
  );

  static const _darkVariant = GlassThemeVariant(
    settings: GlassThemeSettings(
      glassColor: Color(0x143A4147),
      thickness: 22,
      blur: 8,
      chromaticAberration: 0.014,
      lightAngle: 2.356,
      lightIntensity: .74,
      ambientStrength: .34,
      refractiveIndex: 1.18,
      saturation: .92,
      specularSharpness: GlassSpecularSharpness.sharp,
    ),
    quality: GlassQuality.standard,
    borderRadius: surfaceRadius,
  );

  /// The V5 app respects the system brightness while keeping the same glass
  /// geometry and interaction behavior in both neutral palettes.
  static const themeData = GlassThemeData(
    light: _lightVariant,
    dark: _darkVariant,
    interaction: GlassInteractionSettings(
      interactionScale: interactionScale,
      stretch: interactionStretch,
    ),
  );

  /// The root scope adds native iOS Reduce Transparency to Flutter's system
  /// accessibility data. The static fallback stays readable on white V3 UI.
  static bool usesStaticAccessibleSurface(BuildContext context) =>
      MediaQuery.highContrastOf(context) ||
      GlassAccessibilityData.of(context).reduceTransparency;

  static bool allowsRealtimeEffects(BuildContext context) =>
      !usesStaticAccessibleSurface(context) &&
      !MediaQuery.disableAnimationsOf(context) &&
      Scrollable.maybeOf(context) == null &&
      !V3GlassPerformanceScope.constrainedOf(context);

  static LiquidGlassSettings settingsFor(
    V3GlassTone tone, {
    bool selected = false,
    HuahuoV3ThemeTokens tokens = HuahuoV3Theme.lightTokens,
    double alphaScale = 1,
  }) {
    final normalizedScale = alphaScale.clamp(0.0, 2.0).toDouble();
    return LiquidGlassSettings(
      glassColor: _scaledAlpha(
        _shaderTintFor(tone, selected: selected, tokens: tokens),
        normalizedScale,
      ),
      thickness: selected ? 32 : 28,
      blur: selected ? 5.0 : 4.2,
      chromaticAberration: selected ? 0.030 : 0.024,
      lightAngle: 2.356,
      lightIntensity: selected ? 1.48 : 1.30,
      ambientStrength: selected ? 0.26 : 0.21,
      ambientRim: selected ? 0.78 : 0.68,
      refractiveIndex: selected ? 1.242 : 1.224,
      saturation: 1.03,
      glowIntensity: selected ? 0.80 : 0.70,
      specularSharpness: GlassSpecularSharpness.sharp,
      standardOpacityMultiplier: (0.68 * normalizedScale).clamp(0.0, 1.0),
      shadowElevation: selected ? 1.58 : 1.34,
      shadow: _shaderShadowFor(tone, selected: selected, tokens: tokens),
      whitenStrength: selected ? 0.17 : 0.125,
      whitenGated: false,
      backerColor: tokens.surface.withValues(
        alpha: ((selected ? 0.075 : 0.052) * normalizedScale).clamp(0.0, 1.0),
      ),
    );
  }

  static Color _scaledAlpha(Color color, double scale) =>
      color.withValues(alpha: (color.a * scale).clamp(0.0, 1.0));

  static Color _shaderTintFor(
    V3GlassTone tone, {
    required bool selected,
    required HuahuoV3ThemeTokens tokens,
  }) {
    final glass = glassTokensFor(tone, tokens: tokens);
    return selected ? glass.selectedTint : glass.tint;
  }

  static List<BoxShadow> _shaderShadowFor(
    V3GlassTone tone, {
    bool selected = false,
    HuahuoV3ThemeTokens tokens = HuahuoV3Theme.lightTokens,
  }) {
    return <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: selected ? 0.062 : 0.048),
        blurRadius: selected ? 22 : 18,
        spreadRadius: -4,
        offset: const Offset(0, 9),
      ),
      BoxShadow(
        color: rimFor(
          tone,
          tokens: tokens,
        ).withValues(alpha: selected ? 0.28 : 0.20),
        blurRadius: selected ? 18 : 15,
        spreadRadius: -5,
        offset: const Offset(0, 5),
      ),
      BoxShadow(
        color: Colors.white.withValues(alpha: 0.78),
        blurRadius: 7,
        spreadRadius: -5,
        offset: const Offset(-3, -4),
      ),
    ];
  }

  static HuahuoV3GlassTokens glassTokensFor(
    V3GlassTone tone, {
    HuahuoV3ThemeTokens tokens = HuahuoV3Theme.lightTokens,
  }) {
    return switch (tone) {
      V3GlassTone.warm => tokens.warmGlass,
      V3GlassTone.cool => tokens.coolGlass,
      V3GlassTone.neutral => tokens.neutralGlass,
    };
  }

  static Color tintFor(
    V3GlassTone tone, {
    bool selected = false,
    HuahuoV3ThemeTokens tokens = HuahuoV3Theme.lightTokens,
  }) {
    final glass = glassTokensFor(tone, tokens: tokens);
    return selected ? glass.selectedTint : glass.tint;
  }

  static Color rimFor(
    V3GlassTone tone, {
    HuahuoV3ThemeTokens tokens = HuahuoV3Theme.lightTokens,
  }) {
    return glassTokensFor(tone, tokens: tokens).rim;
  }

  static Color iconColorFor(
    V3GlassTone tone, {
    HuahuoV3ThemeTokens tokens = HuahuoV3Theme.lightTokens,
  }) {
    return switch (tone) {
      V3GlassTone.warm => Color.lerp(tokens.ink, tokens.accent, .72)!,
      V3GlassTone.cool => Color.lerp(tokens.ink, tokens.coolGlass.rim, .46)!,
      V3GlassTone.neutral => tokens.ink,
    };
  }

  static Color fallbackSurfaceFor(
    V3GlassTone tone, {
    bool selected = false,
    HuahuoV3ThemeTokens tokens = HuahuoV3Theme.lightTokens,
  }) {
    final glass = glassTokensFor(tone, tokens: tokens);
    return selected ? glass.selectedFallback : glass.fallback;
  }

  static List<BoxShadow> shadowsFor(
    V3GlassTone tone, {
    HuahuoV3ThemeTokens tokens = HuahuoV3Theme.lightTokens,
  }) {
    return <BoxShadow>[
      BoxShadow(
        color: tokens.ink.withValues(alpha: 0.08),
        blurRadius: 18,
        offset: const Offset(0, 8),
      ),
      BoxShadow(
        color: rimFor(tone, tokens: tokens).withValues(alpha: 0.16),
        blurRadius: 13,
        spreadRadius: -2,
      ),
    ];
  }
}
