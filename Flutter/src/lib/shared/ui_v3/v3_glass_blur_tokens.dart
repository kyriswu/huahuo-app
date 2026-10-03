/// Painter-only blur calibration. Backdrop quality policy remains in
/// `v3_glass_foundations.dart`.
abstract final class V3Blur {
  static const _edgeScale = .30;

  static const upperReflect = 5.0;
  static const lowerReflect = 6.0;
  static const edgeMeniscus = .8 * _edgeScale;
  static const edgeCompression = .6 * _edgeScale;
  static const upperHighlight = .25 * _edgeScale;
  static const lowerRefract = .3 * _edgeScale;
  static const edgeWarmGlint = .35 * _edgeScale;

  static const surfaceMeniscus = .9;
  static const surfaceCompress = .45;
  static const surfaceDepth = 1.8;
  static const surfaceTopShade = 1.5;
  static const surfaceInnerWall = .7;
  static const surfaceSpark = .8;
  static const lightReflect = .35;
  static const lightPatch = 4.0;

  static const faceOpticalCompression = .45 * _edgeScale;
  static const dockUpperGlint = .45;
  static const dockLowerCaustic = .65;
  static const dockCompression = .7;
  static const dockGlow = 5.0;

  static double outerHaloContact(double radius) =>
      (radius * .10).clamp(4.0, 9.0).toDouble();
  static double outerHaloLift(double radius) =>
      (radius * .055).clamp(2.0, 5.5).toDouble();
  static double outerHaloUpperAir(double radius) =>
      (radius * .028).clamp(1.0, 3.0).toDouble() * _edgeScale;

  static double faceInnerMist(double radius) => radius * .135;
  static double faceCenterAperture(double radius) => radius * .130;
  static double faceOpticalBand(double radius) =>
      (radius * .014).clamp(.7, 1.6).toDouble() * _edgeScale;
  static double faceEdgeMeniscus(double radius) => radius * .030 * _edgeScale;
  static double faceUpperMeniscusLight(double radius) =>
      radius * .034 * _edgeScale;
  static double faceUpperGlassWash(double radius) => radius * .052 * _edgeScale;
  static double faceLowerMeniscusPress(double radius) =>
      radius * .058 * _edgeScale;
  static double faceLowerGlassCatch(double radius) =>
      radius * .045 * _edgeScale;
  static double faceUpperBloom(double radius) => radius * .062;
  static double faceTopSurfaceSheen(double radius) =>
      radius * .026 * _edgeScale;
  static double faceUpperLensLip(double radius) => radius * .040 * _edgeScale;
  static double faceUpperLensShade(double radius) => radius * .046 * _edgeScale;
  static double faceUpperFoldShade(double radius) => radius * .040 * _edgeScale;
  static double faceRightBloom(double radius) => radius * .048;
  static double faceRightSpark(double radius) => radius * .025;
  static double faceTopDepth(double radius) => radius * .032 * _edgeScale;
  static double faceLowerInternalDepth(double radius) =>
      radius * .054 * _edgeScale;
  static double faceLowerInternalSheen(double radius) =>
      radius * .028 * _edgeScale;
  static double faceLeftWall(double radius) => radius * .034 * _edgeScale;
  static double faceLowerShade(double radius) => radius * .068 * _edgeScale;

  static double rimSelectedSoftEdge(double radius) =>
      radius * .016 * _edgeScale;
  static double rimSelectedArc(double radius) => radius * .003 * _edgeScale;
  static double rimSelectedTopWash(double radius) => radius * .008 * _edgeScale;
  static double rimTopSpecular(double radius) => radius * .013 * _edgeScale;
  static double rimGlint(double radius) => radius * .012 * _edgeScale;
  static double rimLowerCatch(double radius) => radius * .024 * _edgeScale;
  static double rimLowerBrightLip(double radius) => radius * .010 * _edgeScale;
}
