import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/digital_twin_particle_projection.dart';

void main() {
  test('pulse-only frames reuse the same immutable bounded projection', () {
    final projection = DigitalTwinParticleProjection();
    final first = _project(projection);
    expect(first, hasLength(820));
    for (var frame = 0; frame < 120; frame++) {
      expect(_project(projection), same(first));
    }
    expect(() => first.clear(), throwsUnsupportedError);
    expect(
      first.map((point) => point.depth),
      orderedEquals(first.map((point) => point.depth).toList()..sort()),
    );
    expect(first.every((point) => point.position.dx.isFinite), isTrue);
    expect(first.every((point) => point.position.dy.isFinite), isTrue);
    expect(first.every((point) => point.radius > 0), isTrue);
  });

  test('viewport, orbit and zoom invalidate only the latest projection', () {
    final projection = DigitalTwinParticleProjection();
    var previous = _project(projection);
    for (final next in [
      () => _project(projection, viewport: const Size(300, 520)),
      () => _project(projection, yaw: .3),
      () => _project(projection, pitch: .2),
      () => _project(projection, zoom: 1.4),
    ]) {
      final current = next();
      expect(current, isNot(same(previous)));
      expect(next(), same(current));
      previous = current;
    }
    expect(_project(DigitalTwinParticleProjection()), isNot(same(previous)));
  });

  test('warning and merge particles retain their original lifecycle', () {
    final projection = DigitalTwinParticleProjection();
    final normal = _project(projection);
    final pending = _project(projection, pending: true);
    expect(pending, hasLength(964));
    expect(pending.where((point) => point.warning), hasLength(144));
    expect(pending, isNot(same(normal)));
    final merging = _project(projection, mergeFraction: 1, mergeProgress: .5);
    expect(merging, hasLength(964));
    expect(merging.where((point) => point.merging), hasLength(144));
    expect(
      _project(projection, mergeFraction: 1, mergeProgress: .5),
      same(merging),
    );
    expect(
      _project(projection, mergeFraction: .5, mergeProgress: .5),
      isNot(same(merging)),
    );
    final complete = _project(projection, mergeFraction: 1);
    expect(complete, hasLength(820));
    expect(complete.any((point) => point.warning || point.merging), isFalse);
  });

  test('seeded model preserves perspective, depth color and radius', () {
    final random = math.Random(31276649);
    final vertical = random.nextDouble() * 2 - 1;
    final angle = random.nextDouble() * math.pi * 2;
    final radial = math.pow(random.nextDouble(), 1 / 3).toDouble();
    final ring = math.sqrt(1 - vertical * vertical) * radial;
    final horizontal = math.cos(angle) * ring * .29;
    final height = -.59 + vertical * radial * .29;
    final depth = math.sin(angle) * ring * .23;
    final tone = random.nextDouble();
    final radius = .65 + random.nextDouble() * 1.05;
    final perspective = (2.8 / (2.8 - depth)).clamp(.62, 1.62);
    final projected = _project(
      DigitalTwinParticleProjection(),
      yaw: 0,
      pitch: 0,
    );
    final point = projected.singleWhere(
      (point) => (point.depth - depth).abs() < 1e-12,
    );
    final modelScale = math.min(360 * .65, 620 * .38);
    expect(
      point.position.dx,
      closeTo(180 + horizontal * modelScale * perspective, 1e-10),
    );
    expect(
      point.position.dy,
      closeTo(620 * .43 + height * modelScale * perspective, 1e-10),
    );
    expect(point.radius, closeTo(radius * perspective, 1e-12));
    final depthLight = ((depth + .7) / 1.4).clamp(0, 1);
    expect(
      point.baseOpacity,
      closeTo(.24 + tone * .52 + depthLight * .16, 1e-12),
    );
    expect(
      point.color,
      Color.lerp(
        const Color(0xFF685F8A),
        const Color(0xFFF0E9FF),
        (tone * .72 + depthLight * .28).clamp(0, 1),
      ),
    );
  });
}

List<DigitalTwinProjectedParticle> _project(
  DigitalTwinParticleProjection projection, {
  Size viewport = const Size(360, 620),
  double yaw = -.18,
  double pitch = -.04,
  double zoom = 1,
  bool pending = false,
  double mergeProgress = 1,
  double mergeFraction = 0,
}) => projection.project(
  viewport: viewport,
  yaw: yaw,
  pitch: pitch,
  zoom: zoom,
  pending: pending,
  mergeProgress: mergeProgress,
  mergeFraction: mergeFraction,
);
