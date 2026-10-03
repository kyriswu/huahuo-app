import 'dart:math' as math;
import 'dart:ui';

final class DigitalTwinParticleProjection {
  ({
    Size viewport,
    double yaw,
    double pitch,
    double zoom,
    bool pending,
    double mergeProgress,
    double mergeFraction,
  })?
  _key;
  List<DigitalTwinProjectedParticle> _projected = const [];

  List<DigitalTwinProjectedParticle> project({
    required Size viewport,
    required double yaw,
    required double pitch,
    required double zoom,
    required bool pending,
    double mergeProgress = 1,
    double mergeFraction = 0,
  }) {
    final key = (
      viewport: viewport,
      yaw: yaw,
      pitch: pitch,
      zoom: zoom,
      pending: pending,
      mergeProgress: mergeProgress,
      mergeFraction: mergeFraction,
    );
    if (_key == key) return _projected;

    final center = Offset(viewport.width / 2, viewport.height * .43);
    final modelScale =
        math.min(viewport.width * .65, viewport.height * .38) * zoom;
    final cosineYaw = math.cos(yaw);
    final sineYaw = math.sin(yaw);
    final cosinePitch = math.cos(pitch);
    final sinePitch = math.sin(pitch);
    final projected = <DigitalTwinProjectedParticle>[];
    for (final particle in _pointCloud) {
      final merging =
          particle.warning &&
          particle.tone < mergeFraction &&
          mergeProgress < 1;
      if (particle.warning && !pending && !merging) continue;
      final horizontal =
          particle.horizontal * (merging ? 1 - mergeProgress * .72 : 1);
      final rotatedHorizontal =
          horizontal * cosineYaw + particle.depth * sineYaw;
      final yawDepth = -horizontal * sineYaw + particle.depth * cosineYaw;
      final rotatedVertical =
          particle.vertical * cosinePitch - yawDepth * sinePitch;
      final depth = particle.vertical * sinePitch + yawDepth * cosinePitch;
      final perspective = (2.8 / (2.8 - depth)).clamp(.62, 1.62);
      final depthLight = ((depth + .7) / 1.4).clamp(0, 1);
      final color = particle.warning
          ? Color.lerp(
              const Color(0xFFFF5E55),
              const Color(0xFFFFB08C),
              particle.tone,
            )!
          : Color.lerp(
              const Color(0xFF685F8A),
              const Color(0xFFF0E9FF),
              (particle.tone * .72 + depthLight * .28).clamp(0, 1),
            )!;
      projected.add(
        DigitalTwinProjectedParticle(
          position: Offset(
            center.dx + rotatedHorizontal * modelScale * perspective,
            center.dy + rotatedVertical * modelScale * perspective,
          ),
          depth: depth,
          radius: particle.radius * perspective,
          color: color,
          baseOpacity: particle.warning
              ? .5
              : .24 + particle.tone * .52 + depthLight * .16,
          warning: particle.warning,
          merging: merging,
        ),
      );
    }
    projected.sort((left, right) => left.depth.compareTo(right.depth));
    _key = key;
    _projected = List<DigitalTwinProjectedParticle>.unmodifiable(projected);
    return _projected;
  }
}

final class DigitalTwinProjectedParticle {
  const DigitalTwinProjectedParticle({
    required this.position,
    required this.depth,
    required this.radius,
    required this.color,
    required this.baseOpacity,
    required this.warning,
    required this.merging,
  });

  final Offset position;
  final double depth;
  final double radius;
  final Color color;
  final double baseOpacity;
  final bool warning;
  final bool merging;
}

final List<_ParticleModelPoint> _pointCloud = _buildPointCloud();

List<_ParticleModelPoint> _buildPointCloud() {
  final random = math.Random(31276649);
  final particles = <_ParticleModelPoint>[];

  for (var index = 0; index < 300; index++) {
    final vertical = random.nextDouble() * 2 - 1;
    final angle = random.nextDouble() * math.pi * 2;
    final radial = math.pow(random.nextDouble(), 1 / 3).toDouble();
    final ring = math.sqrt(1 - vertical * vertical) * radial;
    particles.add(
      _ParticleModelPoint(
        horizontal: math.cos(angle) * ring * .29,
        vertical: -.59 + vertical * radial * .29,
        depth: math.sin(angle) * ring * .23,
        tone: random.nextDouble(),
        radius: .65 + random.nextDouble() * 1.05,
      ),
    );
  }

  for (var index = 0; index < 520; index++) {
    final fraction = random.nextDouble();
    final vertical = -.25 + fraction * 1.12;
    final shoulder = math.exp(-math.pow((fraction - .16) / .22, 2));
    final width = .31 + shoulder * .25 + fraction * .05;
    final depth = .15 + shoulder * .08 + fraction * .02;
    final angle = random.nextDouble() * math.pi * 2;
    final radial = math.sqrt(random.nextDouble());
    particles.add(
      _ParticleModelPoint(
        horizontal: math.cos(angle) * width * radial,
        vertical: vertical,
        depth: math.sin(angle) * depth * radial,
        tone: random.nextDouble(),
        radius: .65 + random.nextDouble() * 1.15,
      ),
    );
  }

  for (var index = 0; index < 144; index++) {
    final side = index.isEven ? -1.0 : 1.0;
    final fraction = random.nextDouble();
    particles.add(
      _ParticleModelPoint(
        horizontal: side * (.57 + random.nextDouble() * .07),
        vertical: -.16 + fraction * .92,
        depth: (random.nextDouble() - .5) * .34,
        tone: random.nextDouble(),
        radius: .8 + random.nextDouble() * 1.3,
        warning: true,
      ),
    );
  }
  return List<_ParticleModelPoint>.unmodifiable(particles);
}

final class _ParticleModelPoint {
  const _ParticleModelPoint({
    required this.horizontal,
    required this.vertical,
    required this.depth,
    required this.tone,
    required this.radius,
    this.warning = false,
  });

  final double horizontal;
  final double vertical;
  final double depth;
  final double tone;
  final double radius;
  final bool warning;
}
