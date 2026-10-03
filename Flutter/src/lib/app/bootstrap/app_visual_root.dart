import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:go_router/go_router.dart';

import '../../core/performance/runtime_activity_metrics.dart';
import '../../features/settings/domain/app_appearance_preset.dart';
import '../../shared/navigation/foreground_ingress_coordinator.dart';
import '../../shared/theme/huahuo_v3_theme.dart';
import '../../shared/ui_v3/v3_components.dart';
import '../../shared/ui_v3/v3_glass_accessibility.dart';
import '../../shared/ui_v3/v3_liquid_glass.dart';

const _minimumAppTextScale = .8;
const _maximumAppTextScale = 1.3;

double resolveAppTextScale({
  required double platformTextScale,
  required double preferredTextScale,
}) => (platformTextScale * preferredTextScale)
    .clamp(_minimumAppTextScale, _maximumAppTextScale)
    .toDouble();

final class AppVisualRoot extends StatelessWidget {
  const AppVisualRoot({
    required this.router,
    required this.appearancePreset,
    required this.themeMode,
    required this.textSizeFactor,
    required this.glassOpacityPercent,
    required this.scaffoldMessengerKey,
    required this.foregroundIngressCoordinator,
    required this.activityMetrics,
    super.key,
  });

  final GoRouter router;
  final AppAppearancePreset appearancePreset;
  final ThemeMode themeMode;
  final double textSizeFactor;
  final int glassOpacityPercent;
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;
  final ForegroundIngressCoordinator foregroundIngressCoordinator;
  final RuntimeActivityMetrics activityMetrics;

  @override
  Widget build(BuildContext context) {
    final palette = switch (appearancePreset) {
      AppAppearancePreset.mistBlue => HuahuoV3Palette.mistBlue,
      AppAppearancePreset.pineGreen => HuahuoV3Palette.pineGreen,
      AppAppearancePreset.warmGold => HuahuoV3Palette.warmGold,
      AppAppearancePreset.sakura => HuahuoV3Palette.sakura,
      AppAppearancePreset.aurora => HuahuoV3Palette.aurora,
      AppAppearancePreset.system ||
      AppAppearancePreset.light ||
      AppAppearancePreset.dark => HuahuoV3Palette.neutral,
    };

    return MaterialApp.router(
      title: '无限花火',
      restorationScopeId: 'huahuo-app',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: _withV3PlatformPageTransitions(
        HuahuoV3Theme.light(palette: palette),
      ),
      darkTheme: _withV3PlatformPageTransitions(
        HuahuoV3Theme.dark(palette: palette),
      ),
      themeMode: themeMode,
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        ...FlutterQuillLocalizations.localizationsDelegates,
      ],
      supportedLocales: const <Locale>[Locale('zh', 'CN')],
      routerConfig: router,
      builder: (context, child) {
        final app = child ?? const SizedBox.shrink();
        final mediaQuery = MediaQuery.of(context);
        final theme = Theme.of(context);
        final colors = HuahuoV3Theme.tokensOf(context);
        final isDark = theme.brightness == Brightness.dark;
        final platformTextScale = mediaQuery.textScaler.scale(1.0);
        final effectiveTextScale = resolveAppTextScale(
          platformTextScale: platformTextScale,
          preferredTextScale: HuahuoV3Theme.appTextScale * textSizeFactor,
        );
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: colors.canvas,
            systemNavigationBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: MediaQuery(
            data: mediaQuery.copyWith(
              textScaler: TextScaler.linear(effectiveTextScale),
            ),
            child: V3KeyboardDismissOnUpwardScroll(
              child: V3GlassAccessibilityScope(
                child: V3GlassOpacityScope(
                  percent: glassOpacityPercent,
                  child: V3GlassHomeScope(
                    child: ColoredBox(
                      color: colors.canvas,
                      child: ForegroundIngressScope(
                        coordinator: foregroundIngressCoordinator,
                        child: RuntimeActivityMetricsScope(
                          metrics: activityMetrics,
                          child: app,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

ThemeData _withV3PlatformPageTransitions(ThemeData theme) {
  return theme.copyWith(pageTransitionsTheme: _v3PlatformPageTransitions);
}

const _v3PlatformPageTransitions = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
    TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
  },
);
