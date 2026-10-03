import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_layout.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_projection_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/sphere_graph_render_topology.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_sphere_mesh_painter.dart';

void main() {
  test('mixed mesh paints nonblank in stable far-to-near order', () async {
    final painter = _painter(
      points: const <SphereGraphLayoutPoint>[
        SphereGraphLayoutPoint(
          id: 'real-back',
          x: -.5,
          y: 0,
          z: -.7,
          isSynthetic: false,
        ),
        SphereGraphLayoutPoint(
          id: 'synthetic-far',
          x: 0,
          y: -.5,
          z: -.8,
          isSynthetic: true,
        ),
        SphereGraphLayoutPoint(
          id: 'real-front',
          x: .5,
          y: 0,
          z: .65,
          isSynthetic: false,
        ),
        SphereGraphLayoutPoint(
          id: 'synthetic-near',
          x: 0,
          y: .5,
          z: .8,
          isSynthetic: true,
        ),
      ],
      links: const <SphereGraphVisualLink>[
        SphereGraphVisualLink(
          sourceId: 'real-front',
          targetId: 'synthetic-near',
          touchesSyntheticPoint: true,
        ),
        SphereGraphVisualLink(
          sourceId: 'real-back',
          targetId: 'synthetic-far',
          touchesSyntheticPoint: true,
        ),
        SphereGraphVisualLink(
          sourceId: 'real-back',
          targetId: 'real-front',
          touchesSyntheticPoint: false,
        ),
      ],
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
    painter.paint(canvas, const Size(200, 180));
    final image = await recorder.endRecording().toImage(200, 180);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

    expect(painter.lastLinkPaintOrder, <String>[
      'real-back->synthetic-far',
      'real-back->real-front',
      'real-front->synthetic-near',
    ]);
    expect(painter.lastSyntheticPointPaintOrder, <String>[
      'synthetic-far',
      'synthetic-near',
    ]);
    expect(_containsNonWhitePixel(bytes!.buffer.asUint8List()), isTrue);
    expect(painter.semanticsBuilder, isNull);
    image.dispose();
  });

  test('unknown endpoints and non-finite points fail closed', () {
    final painter = _painter(
      points: const <SphereGraphLayoutPoint>[
        SphereGraphLayoutPoint(
          id: 'valid',
          x: 0,
          y: 0,
          z: 0,
          isSynthetic: false,
        ),
        SphereGraphLayoutPoint(
          id: 'invalid',
          x: double.nan,
          y: 0,
          z: 0,
          isSynthetic: true,
        ),
      ],
      links: const <SphereGraphVisualLink>[
        SphereGraphVisualLink(
          sourceId: 'valid',
          targetId: 'missing',
          touchesSyntheticPoint: false,
        ),
      ],
    );
    final recorder = ui.PictureRecorder();

    expect(
      () => painter.paint(Canvas(recorder), const Size(100, 100)),
      returnsNormally,
    );
    expect(painter.lastLinkPaintOrder, isEmpty);
    recorder.endRecording();
  });

  test('delegate invalidates static inputs but shares live projection', () {
    final projection = _projection();
    final baseline = _painter(projection: projection);
    expect(baseline.shouldRepaint(_painter(projection: projection)), isFalse);
    expect(baseline.shouldRepaint(_painter()), isTrue);
    expect(
      baseline.shouldRepaint(
        _painter(
          projection: projection,
          nodeColors: const <String, Color>{'a': Colors.orange},
        ),
      ),
      isTrue,
    );
    expect(
      baseline.shouldRepaint(
        _painter(projection: projection, canvasColor: const Color(0xFF111111)),
      ),
      isTrue,
    );
  });

  test('synthetic palette is deterministic and uses multiple hues', () {
    expect(
      v3SphereSyntheticColorForId('stable-id', palette: _syntheticPalette),
      v3SphereSyntheticColorForId('stable-id', palette: _syntheticPalette),
    );
    final colors = <Color>{
      for (var index = 0; index < 40; index++)
        v3SphereSyntheticColorForId(
          'synthetic-$index',
          palette: _syntheticPalette,
        ),
    };
    expect(colors.length, greaterThanOrEqualTo(4));
  });

  test('3D link preserves both endpoint colors after depth fading', () async {
    final projection = _projection(
      points: const <SphereGraphLayoutPoint>[
        SphereGraphLayoutPoint(
          id: 'source',
          x: -.72,
          y: 0,
          z: .82,
          isSynthetic: false,
        ),
        SphereGraphLayoutPoint(
          id: 'target',
          x: .72,
          y: 0,
          z: .82,
          isSynthetic: false,
        ),
      ],
      links: const <SphereGraphVisualLink>[
        SphereGraphVisualLink(
          sourceId: 'source',
          targetId: 'target',
          touchesSyntheticPoint: false,
        ),
      ],
    );
    final painter = _painter(
      projection: projection,
      nodeColors: const <String, Color>{
        'source': Color(0xFFE43B32),
        'target': Color(0xFF276BE8),
      },
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
    painter.paint(canvas, const Size(200, 180));
    final image = await recorder.endRecording().toImage(200, 180);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = bytes!.buffer.asUint8List();
    final source = projection.positionAt(
      projection.topology.nodeIndexById['source']!,
    );
    final target = projection.positionAt(
      projection.topology.nodeIndexById['target']!,
    );

    expect(
      _maximumChannelDelta(pixels, 200, Offset.lerp(source, target, .2)!, 0, 2),
      greaterThan(4),
    );
    expect(
      _maximumChannelDelta(pixels, 200, Offset.lerp(source, target, .8)!, 2, 0),
      greaterThan(4),
    );

    image.dispose();
  });

  test(
    'links stay visible but subordinate to points on light and dark',
    () async {
      for (final background in [Colors.white, const Color(0xFF111111)]) {
        final projection = _projection(
          points: const [
            SphereGraphLayoutPoint(
              id: 'left',
              x: -.72,
              y: 0,
              z: .82,
              isSynthetic: true,
            ),
            SphereGraphLayoutPoint(
              id: 'right',
              x: .72,
              y: 0,
              z: .82,
              isSynthetic: true,
            ),
          ],
          links: const [
            SphereGraphVisualLink(
              sourceId: 'left',
              targetId: 'right',
              touchesSyntheticPoint: true,
            ),
          ],
        );
        final painter = _painter(
          projection: projection,
          nodeColors: const {'left': Colors.blue, 'right': Colors.blue},
          canvasColor: background,
        );
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..drawColor(background, BlendMode.src);
        painter.paint(canvas, const Size(200, 180));
        final picture = recorder.endRecording();
        final image = await picture.toImage(200, 180);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final pixels = bytes!.buffer.asUint8List();
        final left = projection.positionAt(
          projection.topology.nodeIndexById['left']!,
        );
        final right = projection.positionAt(
          projection.topology.nodeIndexById['right']!,
        );
        final lineContrast = _contrast(
          pixels,
          Offset.lerp(left, right, .5)!,
          background,
        );
        final pointContrast = _contrast(pixels, left, background);
        expect(lineContrast, greaterThan(0));
        expect(lineContrast, lessThan(20));
        expect(lineContrast, lessThan(pointContrast * .45));
        expect(painter.lastLinkPaintOrder, hasLength(1));
        image.dispose();
        picture.dispose();
        projection.dispose();
      }
    },
  );
}

int _contrast(List<int> pixels, Offset center, Color background) {
  var maximum = 0;
  for (var vertical = -4; vertical <= 4; vertical++) {
    for (var horizontal = -4; horizontal <= 4; horizontal++) {
      final offset =
          ((center.dy.round() + vertical) * 200 +
              center.dx.round() +
              horizontal) *
          4;
      final backgroundChannels = [background.r, background.g, background.b];
      for (var channel = 0; channel < 3; channel++) {
        final contrast =
            (pixels[offset + channel] -
                    (backgroundChannels[channel] * 255).round())
                .abs();
        if (contrast > maximum) maximum = contrast;
      }
    }
  }
  return maximum;
}

int _maximumChannelDelta(
  List<int> pixels,
  int width,
  Offset center,
  int positiveChannel,
  int negativeChannel,
) {
  var maximum = -255;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      final x = center.dx.round() + dx;
      final y = center.dy.round() + dy;
      final offset = (y * width + x) * 4;
      final delta =
          pixels[offset + positiveChannel] - pixels[offset + negativeChannel];
      if (delta > maximum) maximum = delta;
    }
  }
  return maximum;
}

V3GraphSphereMeshPainter _painter({
  SphereGraphProjectionController? projection,
  List<SphereGraphLayoutPoint>? points,
  List<SphereGraphVisualLink> links = const <SphereGraphVisualLink>[],
  Map<String, Color> nodeColors = const <String, Color>{},
  Color canvasColor = Colors.white,
}) {
  return V3GraphSphereMeshPainter(
    projection: projection ?? _projection(points: points, links: links),
    nodeColors: nodeColors,
    syntheticPalette: _syntheticPalette,
    sceneOrigin: Offset.zero,
    canvasColor: canvasColor,
  );
}

SphereGraphProjectionController _projection({
  List<SphereGraphLayoutPoint>? points,
  List<SphereGraphVisualLink> links = const <SphereGraphVisualLink>[],
}) {
  final resolvedPoints =
      points ??
      const <SphereGraphLayoutPoint>[
        SphereGraphLayoutPoint(id: 'a', x: 0, y: 0, z: .5, isSynthetic: true),
      ];
  final topology = SphereGraphRenderTopology.build(
    points: resolvedPoints,
    visualLinks: links,
    semanticEdges: const <V3GraphEdge>[],
  );
  return SphereGraphProjectionController()
    ..updateTopology(topology, notify: false)
    ..project(
      viewport: const Size(200, 180),
      rotationX: 0,
      rotationY: 0,
      notify: false,
    );
}

const _syntheticPalette = <Color>[
  Color(0xFF315F7D),
  Color(0xFF7D9FB5),
  Color(0xFF587B6A),
  Color(0xFFC3904E),
  Color(0xFFA64F73),
];

bool _containsNonWhitePixel(List<int> pixels) {
  for (var index = 0; index + 3 < pixels.length; index += 4) {
    if (pixels[index] < 250 ||
        pixels[index + 1] < 250 ||
        pixels[index + 2] < 250) {
      return true;
    }
  }
  return false;
}
