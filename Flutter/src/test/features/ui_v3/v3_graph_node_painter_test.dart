import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_node_painter.dart';

void main() {
  test('every faint but painted real note remains tappable', () {
    final node = _node('faint-note');
    expect(
      hitTestV3GraphCanvasNode(
        scenePosition: const Offset(50, 50),
        nodes: [node],
        positions: const {'faint-note': Offset(50, 50)},
        radii: const {'faint-note': 7},
        opacities: const {'faint-note': .03},
        depths: const {'faint-note': .05},
        zoom: 1,
      ),
      same(node),
    );
  });

  test('dense mode thresholds begin after 120 nodes or 300 edges', () {
    expect(v3GraphUsesDenseCanvas(nodeCount: 120, edgeCount: 300), isFalse);
    expect(v3GraphUsesDenseCanvas(nodeCount: 121, edgeCount: 1), isTrue);
    expect(v3GraphUsesDenseCanvas(nodeCount: 1, edgeCount: 301), isTrue);
  });

  test('dense title font stays nine screen points through zoom', () {
    expect(v3GraphDenseLabelSceneFontSize(2) * 2, closeTo(9, .001));
    expect(v3GraphDenseLabelSceneFontSize(3) * 3, closeTo(9, .001));
    expect(v3GraphDenseLabelSceneFontSize(double.nan), 9);
  });

  test('dense labels reveal more content across middle and near zoom', () {
    expect(v3GraphDenseLabelScreenWidth(1.11), 76);
    expect(v3GraphDenseLabelMaxLines(1.11), 1);
    expect(v3GraphDenseLabelScreenWidth(1.12), 144);
    expect(v3GraphDenseLabelMaxLines(1.12), 3);
    expect(v3GraphDenseLabelScreenWidth(1.77), 144);
    expect(v3GraphDenseLabelMaxLines(1.77), 3);
    expect(v3GraphDenseLabelScreenWidth(1.78), 180);
    expect(v3GraphDenseLabelMaxLines(1.78), 4);
    expect(v3GraphDenseLabelScreenWidth(3), 180);
    expect(v3GraphDenseLabelMaxLines(3), 4);
  });

  test('dense overlay remains stable when selection changes', () {
    final nodes = List<V3GraphNode>.generate(
      40,
      (index) => _node(
        'node-$index',
        weight: index == 39 ? -1 : index / 20,
        center: index == 0,
        hotspot: index == 3,
      ),
    );
    final overlays = v3GraphDenseOverlayNodeIds(
      nodes: nodes,
      roles: {
        for (final node in nodes)
          node.id: node.id == 'node-2'
              ? V3GraphNodeRole.core
              : node.center
              ? V3GraphNodeRole.center
              : V3GraphNodeRole.satellite,
      },
      searchMatchNodeIds: const ['node-7', 'node-8'],
      selectedNodeId: 'node-39',
    );
    expect(overlays, containsAll(['node-7', 'node-8', 'node-0']));
    expect(overlays, isNot(contains('node-39')));
    expect(overlays.length, lessThanOrEqualTo(8));
  });

  test('canvas node hit chooses frontmost eligible overlapping node', () {
    final front = _node('front');
    final rear = _node('rear');
    final hit = hitTestV3GraphCanvasNode(
      scenePosition: const Offset(52, 50),
      nodes: [rear, front],
      positions: const {'rear': Offset(50, 50), 'front': Offset(63, 50)},
      radii: const {'rear': 7, 'front': 7},
      opacities: const {'rear': 1, 'front': 1},
      depths: const {'rear': .15, 'front': .9},
      zoom: 2,
    );
    expect(hit?.id, 'front');
    expect(
      hitTestV3GraphCanvasNode(
        scenePosition: const Offset(52, 50),
        nodes: [front],
        positions: const {'front': Offset(50, 50)},
        radii: const {'front': 7},
        opacities: const {'front': .01},
        depths: const {'front': .9},
        zoom: 2,
      ),
      isNull,
    );
  });

  test('dense semantics are bounded actionable and omit overlay nodes', () {
    final repaint = ChangeNotifier();
    String? selectedId;
    final painter = V3GraphNodePainter(
      repaint: repaint,
      resolvePositions: () => const <String, Offset>{
        'a': Offset(40, 60),
        'b': Offset(120, 110),
        'hidden': Offset(160, 160),
      },
      resolveZoom: () => 2,
      sceneOrigin: const Offset(10, 20),
      nodes: <V3GraphNode>[_node('a', weight: 2), _node('b'), _node('hidden')],
      nodeRadii: const <String, double>{'a': 7, 'b': 7, 'hidden': 7},
      nodeColors: const <String, Color>{},
      nodeOpacities: const <String, double>{'a': 1, 'b': 1, 'hidden': .01},
      nodeDepths: const <String, double>{'a': .8, 'b': .9, 'hidden': .1},
      overlayNodeIds: const <String>{'b'},
      showAllLabels: true,
      maximumSemanticNodes: 1,
      onSemanticNodeTap: (id) => selectedId = id,
    );

    final semantics = painter.semanticsBuilder(const Size(200, 200));
    expect(semantics, hasLength(1));
    expect(semantics.single.properties.label, '知识实体：a');
    expect(semantics.single.rect.width, closeTo(22, .001));
    semantics.single.properties.onTap!();
    expect(selectedId, 'a');
    repaint.dispose();
  });

  test('semantic label palette invalidates the dense painter', () {
    final repaint = ChangeNotifier();
    V3GraphNodePainter painter({
      required Color labelColor,
      required Color labelHaloColor,
    }) => V3GraphNodePainter(
      repaint: repaint,
      resolvePositions: () => const <String, Offset>{},
      resolveZoom: () => 1,
      sceneOrigin: Offset.zero,
      nodes: const <V3GraphNode>[],
      nodeRadii: const <String, double>{},
      nodeColors: const <String, Color>{},
      nodeOpacities: const <String, double>{},
      overlayNodeIds: const <String>{},
      showAllLabels: true,
      labelColor: labelColor,
      labelHaloColor: labelHaloColor,
    );

    final light = painter(
      labelColor: const Color(0xFF30312F),
      labelHaloColor: Colors.white,
    );
    expect(
      light.shouldRepaint(
        painter(labelColor: Colors.white, labelHaloColor: Colors.black),
      ),
      isTrue,
    );
    repaint.dispose();
  });

  testWidgets('dense painter draws live ordinary nodes without exceptions', (
    tester,
  ) async {
    final repaint = ChangeNotifier();
    final nodes = [_node('a'), _node('b', hotspot: true)];
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(200, 200),
          painter: V3GraphNodePainter(
            repaint: repaint,
            resolvePositions: () => const {
              'a': Offset(40, 60),
              'b': Offset(120, 110),
            },
            resolveZoom: () => 2,
            sceneOrigin: Offset.zero,
            nodes: nodes,
            nodeRadii: const {'a': 7, 'b': 9},
            nodeColors: const {'a': Color(0xFF0068BA), 'b': Color(0xFFF1BB3E)},
            nodeOpacities: const {'a': 1, 'b': .8},
            nodeDepths: const {'a': .1, 'b': .9},
            overlayNodeIds: const {},
            showAllLabels: true,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final canvas = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is V3GraphNodePainter,
    );
    final painter =
        tester.widget<CustomPaint>(canvas).painter! as V3GraphNodePainter;
    expect(painter.paintedLabelCount, 1);
    repaint.notifyListeners();
    await tester.pump();
    expect(tester.takeException(), isNull);
    repaint.dispose();
  });

  test('dense node paints a bright core and a bounded outer halo', () async {
    final repaint = ChangeNotifier();
    final painter = V3GraphNodePainter(
      repaint: repaint,
      resolvePositions: () => const <String, Offset>{
        'luminous': Offset(30, 30),
      },
      resolveZoom: () => 1,
      sceneOrigin: Offset.zero,
      nodes: <V3GraphNode>[_node('luminous')],
      nodeRadii: const <String, double>{'luminous': 8},
      nodeColors: const <String, Color>{'luminous': Color(0xFF43DFF5)},
      nodeOpacities: const <String, double>{'luminous': 1},
      overlayNodeIds: const <String>{},
      showAllLabels: false,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawColor(Colors.black, BlendMode.src);
    painter.paint(canvas, const Size(60, 60));
    final image = await recorder.endRecording().toImage(60, 60);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = bytes!.buffer.asUint8List();

    final core = _pixelBrightness(pixels, width: 60, x: 30, y: 30);
    final halo = _pixelBrightness(pixels, width: 60, x: 37, y: 30);
    final exterior = _pixelBrightness(pixels, width: 60, x: 2, y: 2);
    expect(core, greaterThan(halo + 120));
    expect(halo, greaterThan(exterior + 8));

    image.dispose();
    repaint.dispose();
  });
}

int _pixelBrightness(
  List<int> pixels, {
  required int width,
  required int x,
  required int y,
}) {
  final offset = (y * width + x) * 4;
  return pixels[offset] + pixels[offset + 1] + pixels[offset + 2];
}

V3GraphNode _node(
  String id, {
  double weight = 1,
  bool center = false,
  bool hotspot = false,
}) => V3GraphNode(
  id: id,
  label: id,
  cluster: V3GraphCluster.viewpoint,
  position: Offset.zero,
  summary: id,
  weight: weight,
  center: center,
  isHotspot: hotspot,
);
