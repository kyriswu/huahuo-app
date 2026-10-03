import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/huahuo_v3_theme.dart';

class V3BrandMark extends StatelessWidget {
  const V3BrandMark({this.dimension = 74, this.color, super.key});

  static const assetPath = 'assets/images/huahuo_brand_mark.png';

  final double dimension;

  /// Kept for source compatibility. The product-supplied bitmap is never
  /// tinted so its black-and-gold identity remains stable across themes.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final safeDimension = dimension.isFinite && dimension > 0
        ? dimension
        : 74.0;
    return Semantics(
      image: true,
      label: '无限花火',
      child: Center(
        child: SizedBox.square(
          dimension: safeDimension,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(safeDimension * .22),
            child: Image.asset(
              assetPath,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              gaplessPlayback: true,
              excludeFromSemantics: true,
            ),
          ),
        ),
      ),
    );
  }
}

class V3LaunchBrandLockup extends StatelessWidget {
  const V3LaunchBrandLockup({this.markKey, this.wordmarkKey, super.key});

  static const androidAssetPath =
      'android/app/src/main/res/drawable-xxxhdpi/launch_logo.png';
  static const markDimension = 220.0;
  static const lockupHeight = 300.0;

  final Key? markKey;
  final Key? wordmarkKey;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return Center(
        child: Semantics(
          image: true,
          label: '无限花火',
          textDirection: TextDirection.ltr,
          child: Image.asset(
            androidAssetPath,
            key: markKey,
            width: markDimension,
            height: lockupHeight,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            gaplessPlayback: true,
            excludeFromSemantics: true,
          ),
        ),
      );
    }
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: V3BrandMark(key: markKey, dimension: markDimension),
          ),
          Center(
            child: Transform.translate(
              offset: const Offset(0, 138),
              child: Text(
                '无限花火',
                key: wordmarkKey,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(
                  color: Color(0xFF111827),
                  fontFamily: HuahuoV3Theme.fontFamily,
                  fontFamilyFallback: HuahuoV3Theme.fontFamilyFallback,
                  fontSize: 20,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
