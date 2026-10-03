import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/editor/application/desktop_sphere_graph_layout.dart';
import 'package:huahuo_desktop/features/editor/presentation/desktop_knowledge_graph.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

void main() {
  const layout = DesktopSphereGraphLayout();

  test('projection keeps pronounced near and rear depth cues', () {
    const points = <DesktopSphereGraphLayoutPoint>[
      DesktopSphereGraphLayoutPoint(
        id: 'rear',
        x: .6,
        y: 0,
        z: -.6,
        isSynthetic: false,
      ),
      DesktopSphereGraphLayoutPoint(
        id: 'middle',
        x: .6,
        y: 0,
        z: 0,
        isSynthetic: false,
      ),
      DesktopSphereGraphLayoutPoint(
        id: 'near',
        x: .6,
        y: 0,
        z: .6,
        isSynthetic: false,
      ),
    ];
    final projected = layout.project(
      points: points,
      viewport: const Size(900, 700),
    );
    final byId = {for (final point in projected) point.id: point};
    const center = Offset(450, 350);

    expect(projected.map((point) => point.id), <String>[
      'rear',
      'middle',
      'near',
    ]);
    expect(byId['near']!.sizeFactor, greaterThan(byId['middle']!.sizeFactor));
    expect(byId['middle']!.sizeFactor, greaterThan(byId['rear']!.sizeFactor));
    expect(byId['rear']!.opacity, greaterThan(.1));
    expect(byId['near']!.opacity / byId['rear']!.opacity, greaterThan(3));
    expect(byId['near']!.sizeFactor / byId['rear']!.sizeFactor, greaterThan(2));
    expect(
      (byId['near']!.position - center).distance /
          (byId['rear']!.position - center).distance,
      greaterThan(1.5),
    );
  });

  test(
    'surface links follow finite great-circle samples instead of chords',
    () {
      const source = DesktopSphereGraphLayoutPoint(
        id: 'surface-source',
        x: .78,
        y: 0,
        z: 0,
        isSynthetic: false,
      );
      const target = DesktopSphereGraphLayoutPoint(
        id: 'surface-target',
        x: 0,
        y: .78,
        z: 0,
        isSynthetic: false,
      );
      final samples = layout.sampleGreatCircle(
        source: source,
        target: target,
        segments: 8,
      );

      expect(samples, hasLength(9));
      expect(samples.first.x, closeTo(1, 1e-10));
      expect(samples.first.y, closeTo(0, 1e-10));
      expect(samples.last.x, closeTo(0, 1e-10));
      expect(samples.last.y, closeTo(1, 1e-10));
      expect(
        samples.every(
          (sample) =>
              sample.x.isFinite &&
              sample.y.isFinite &&
              sample.z.isFinite &&
              (sample.radius - 1).abs() < 1e-10,
        ),
        isTrue,
      );

      final arcs = layout.projectSurfaceArcs(
        points: const <DesktopSphereGraphLayoutPoint>[source, target],
        links: const <DesktopSphereGraphVisualLink>[
          DesktopSphereGraphVisualLink(
            sourceId: 'surface-source',
            targetId: 'surface-target',
            touchesSyntheticPoint: false,
          ),
        ],
        viewport: const Size(800, 800),
        minimumSegments: 8,
        maximumSegments: 8,
      );
      final projected = arcs.single.samples;
      final chordMidpoint = Offset.lerp(
        projected.first.position,
        projected.last.position,
        .5,
      )!;

      expect(arcs.single.samples, hasLength(9));
      expect((projected[4].position - chordMidpoint).distance, greaterThan(40));
    },
  );

  test('surface node projection meets sampled arc endpoints', () {
    const source = DesktopSphereGraphLayoutPoint(
      id: 'joined-source',
      x: .48,
      y: .16,
      z: .12,
      isSynthetic: false,
    );
    const target = DesktopSphereGraphLayoutPoint(
      id: 'joined-target',
      x: -.18,
      y: .34,
      z: .62,
      isSynthetic: false,
    );
    const viewport = Size(920, 680);
    const rotationX = -.21;
    const rotationY = .37;
    final nodes = layout.project(
      points: const <DesktopSphereGraphLayoutPoint>[source, target],
      viewport: viewport,
      rotationX: rotationX,
      rotationY: rotationY,
    );
    final arcs = layout.projectSurfaceArcs(
      points: const <DesktopSphereGraphLayoutPoint>[source, target],
      links: const <DesktopSphereGraphVisualLink>[
        DesktopSphereGraphVisualLink(
          sourceId: 'joined-source',
          targetId: 'joined-target',
          touchesSyntheticPoint: false,
        ),
      ],
      viewport: viewport,
      rotationX: rotationX,
      rotationY: rotationY,
      minimumSegments: 6,
      maximumSegments: 6,
    );
    final nodesById = {for (final node in nodes) node.id: node};
    final arc = arcs.single;

    expect(
      (nodesById['joined-source']!.position - arc.samples.first.position)
          .distance,
      lessThan(1e-9),
    );
    expect(
      (nodesById['joined-target']!.position - arc.samples.last.position)
          .distance,
      lessThan(1e-9),
    );
    expect(
      nodesById['joined-source']!.cameraDepth,
      closeTo(arc.samples.first.cameraDepth, 1e-12),
    );
    expect(
      nodesById['joined-target']!.cameraDepth,
      closeTo(arc.samples.last.cameraDepth, 1e-12),
    );
  });

  test('viewport pan moves sphere nodes and arcs as one projection', () {
    const source = DesktopSphereGraphLayoutPoint(
      id: 'panned-source',
      x: .44,
      y: -.18,
      z: .28,
      isSynthetic: false,
    );
    const target = DesktopSphereGraphLayoutPoint(
      id: 'panned-target',
      x: -.16,
      y: .38,
      z: .54,
      isSynthetic: false,
    );
    const viewport = Size(920, 680);
    const pan = Offset(83, -47);
    final baseNodes = layout.project(
      points: const <DesktopSphereGraphLayoutPoint>[source, target],
      viewport: viewport,
      rotationX: -.21,
      rotationY: .37,
    );
    final pannedNodes = layout.project(
      points: const <DesktopSphereGraphLayoutPoint>[source, target],
      viewport: viewport,
      rotationX: -.21,
      rotationY: .37,
      pan: pan,
    );
    final pannedArcs = layout.projectSurfaceArcs(
      points: const <DesktopSphereGraphLayoutPoint>[source, target],
      links: const <DesktopSphereGraphVisualLink>[
        DesktopSphereGraphVisualLink(
          sourceId: 'panned-source',
          targetId: 'panned-target',
          touchesSyntheticPoint: false,
        ),
      ],
      viewport: viewport,
      rotationX: -.21,
      rotationY: .37,
      pan: pan,
      minimumSegments: 6,
      maximumSegments: 6,
    );
    final baseById = {for (final node in baseNodes) node.id: node};
    final pannedById = {for (final node in pannedNodes) node.id: node};
    final arc = pannedArcs.single;

    expect(
      ((pannedById['panned-source']!.position -
                  baseById['panned-source']!.position) -
              pan)
          .distance,
      lessThan(1e-9),
    );
    expect(
      ((pannedById['panned-target']!.position -
                  baseById['panned-target']!.position) -
              pan)
          .distance,
      lessThan(1e-9),
    );
    expect(
      (pannedById['panned-source']!.position - arc.samples.first.position)
          .distance,
      lessThan(1e-9),
    );
    expect(
      (pannedById['panned-target']!.position - arc.samples.last.position)
          .distance,
      lessThan(1e-9),
    );
  });

  test('surface arc projection remains finite near antipodal endpoints', () {
    const source = DesktopSphereGraphLayoutPoint(
      id: 'antipodal-source',
      x: 1,
      y: 0,
      z: 0,
      isSynthetic: false,
    );
    const target = DesktopSphereGraphLayoutPoint(
      id: 'antipodal-target',
      x: -1,
      y: .000001,
      z: 0,
      isSynthetic: false,
    );
    final arcs = layout.projectSurfaceArcs(
      points: const <DesktopSphereGraphLayoutPoint>[source, target],
      links: const <DesktopSphereGraphVisualLink>[
        DesktopSphereGraphVisualLink(
          sourceId: 'antipodal-source',
          targetId: 'antipodal-target',
          touchesSyntheticPoint: false,
        ),
      ],
      viewport: const Size(960, 720),
      rotationX: .24,
      rotationY: -.38,
      minimumSegments: 6,
      maximumSegments: 6,
    );

    expect(arcs, hasLength(1));
    expect(
      arcs.single.samples.every(
        (sample) =>
            sample.position.dx.isFinite &&
            sample.position.dy.isFinite &&
            sample.cameraDepth.isFinite &&
            sample.depth.isFinite,
      ),
      isTrue,
    );
  });

  test('surface arc sampling honors a bounded total segment budget', () {
    const points = <DesktopSphereGraphLayoutPoint>[
      DesktopSphereGraphLayoutPoint(
        id: 'a',
        x: 1,
        y: 0,
        z: 0,
        isSynthetic: false,
      ),
      DesktopSphereGraphLayoutPoint(
        id: 'b',
        x: 0,
        y: 1,
        z: 0,
        isSynthetic: false,
      ),
      DesktopSphereGraphLayoutPoint(
        id: 'c',
        x: 0,
        y: 0,
        z: 1,
        isSynthetic: false,
      ),
    ];
    const links = <DesktopSphereGraphVisualLink>[
      DesktopSphereGraphVisualLink(
        sourceId: 'a',
        targetId: 'b',
        touchesSyntheticPoint: false,
      ),
      DesktopSphereGraphVisualLink(
        sourceId: 'b',
        targetId: 'c',
        touchesSyntheticPoint: false,
      ),
      DesktopSphereGraphVisualLink(
        sourceId: 'c',
        targetId: 'a',
        touchesSyntheticPoint: false,
      ),
    ];

    final arcs = layout.projectSurfaceArcs(
      points: points,
      links: links,
      viewport: const Size(800, 600),
      minimumSegments: 3,
      maximumSegments: 18,
      maximumTotalSegments: 4,
    );

    expect(arcs, hasLength(3));
    expect(arcs.every((arc) => arc.samples.length <= 2), isTrue);
  });

  test('points occupy deterministic discrete concentric content shells', () {
    final ids = List<String>.generate(240, (index) => 'shell-$index');
    final first = layout.build(realNodeIds: ids, minimumVisualNodeCount: 0);
    final second = layout.build(
      realNodeIds: ids.reversed,
      minimumVisualNodeCount: 0,
    );

    expect(first, second);
    expect(
      first.every(
        (point) =>
            point.shellIndex >= 0 &&
            point.shellIndex <
                DesktopSphereGraphLayout.contentShellRadii.length &&
            (point.radius -
                        DesktopSphereGraphLayout.contentShellRadii[point
                            .shellIndex])
                    .abs() <
                1e-10,
      ),
      isTrue,
    );
    expect(
      first.map((point) => point.shellIndex).toSet(),
      hasLength(DesktopSphereGraphLayout.contentShellRadii.length),
    );
  });

  test(
    'content shells keep a loose-inner dense-middle loose-outer profile',
    () {
      const legacyCoreRadius = .34;
      const radii = DesktopSphereGraphLayout.contentShellRadii;

      expect(radii, hasLength(10));
      expect(radii.first, greaterThan(legacyCoreRadius + .06));
      for (var index = 1; index < radii.length; index++) {
        expect(radii[index], greaterThan(radii[index - 1]));
      }

      final firstInnerGap = radii[1] - radii[0];
      expect(firstInnerGap, greaterThan(.14));
      for (var index = 2; index <= 6; index++) {
        final middleGap = radii[index] - radii[index - 1];
        expect(middleGap, lessThanOrEqualTo(.07 + 1e-9));
      }
      for (var index = 7; index < radii.length; index++) {
        final outerGap = radii[index] - radii[index - 1];
        expect(outerGap, greaterThan(.07));
      }

      final ids = List<String>.generate(
        10000,
        (index) => 'radial-profile-${index.toString().padLeft(5, '0')}',
      );
      final first = layout.build(realNodeIds: ids, minimumVisualNodeCount: 0);
      final second = layout.build(
        realNodeIds: ids.reversed,
        minimumVisualNodeCount: 0,
      );
      final counts = List<int>.filled(radii.length, 0);
      for (final point in first) {
        counts[point.shellIndex]++;
      }
      final innerCount = counts[0] + counts[1];
      final middleCount = counts[3] + counts[4] + counts[5] + counts[6];
      final outerCount = counts[7] + counts[8] + counts[9];

      expect(first, second);
      expect(middleCount, greaterThan(innerCount * 4));
      expect(middleCount, greaterThan(outerCount * 2));
    },
  );

  test(
    'cross-shell routes retain endpoints and distinguish radial bridges',
    () {
      const source = DesktopSphereGraphLayoutPoint(
        id: 'inner',
        x: .41,
        y: 0,
        z: 0,
        isSynthetic: false,
        shellIndex: 1,
      );
      const target = DesktopSphereGraphLayoutPoint(
        id: 'outer',
        x: 0,
        y: .94,
        z: 0,
        isSynthetic: false,
        shellIndex: 8,
      );
      const viewport = Size(920, 680);
      final nodes = layout.project(
        points: const <DesktopSphereGraphLayoutPoint>[source, target],
        viewport: viewport,
        rotationX: -.21,
        rotationY: .37,
      );
      final route = layout
          .projectSurfaceArcs(
            points: const <DesktopSphereGraphLayoutPoint>[source, target],
            links: const <DesktopSphereGraphVisualLink>[
              DesktopSphereGraphVisualLink(
                sourceId: 'inner',
                targetId: 'outer',
                touchesSyntheticPoint: false,
              ),
            ],
            viewport: viewport,
            rotationX: -.21,
            rotationY: .37,
            minimumSegments: 6,
            maximumSegments: 6,
          )
          .single;
      final byId = {for (final node in nodes) node.id: node};

      expect(
        (route.samples.first.position - byId['inner']!.position).distance,
        lessThan(1e-9),
      );
      expect(
        (route.samples.last.position - byId['outer']!.position).distance,
        lessThan(1e-9),
      );
      expect(route.samples.first.radialDistance, closeTo(.41, 1e-10));
      expect(route.samples.last.radialDistance, closeTo(.94, 1e-10));
      expect(
        route.samples
            .where(
              (sample) =>
                  sample.routeSection ==
                  DesktopSphereGraphRouteSection.shellArc,
            )
            .every((sample) => sample.radialDistance == .94),
        isTrue,
      );
      expect(
        route.samples.any(
          (sample) =>
              sample.routeSection ==
              DesktopSphereGraphRouteSection.radialBridge,
        ),
        isTrue,
      );
    },
  );

  test('external particles are deterministic and follow rotation and pan', () {
    const viewport = Size(920, 680);
    const pan = Offset(83, -47);
    final first = layout.projectAtmosphereDust(
      viewport: viewport,
      rotationX: -.21,
      rotationY: .37,
      zoom: 1.35,
    );
    final second = layout.projectAtmosphereDust(
      viewport: viewport,
      rotationX: -.21,
      rotationY: .37,
      zoom: 1.35,
    );
    final rotated = layout.projectAtmosphereDust(
      viewport: viewport,
      rotationX: .34,
      rotationY: -.18,
      zoom: 1.35,
    );
    final panned = layout.projectAtmosphereDust(
      viewport: viewport,
      rotationX: -.21,
      rotationY: .37,
      zoom: 1.35,
      pan: pan,
    );

    expect(first, second);
    expect(
      first,
      hasLength(DesktopSphereGraphLayout.defaultAtmosphereDustCount),
    );
    expect(
      first.map((particle) => particle.id).toSet(),
      hasLength(first.length),
    );
    expect(
      first.asMap().entries.any(
        (entry) =>
            (entry.value.position - rotated[entry.key].position).distance > .1,
      ),
      isTrue,
    );
    for (var index = 0; index < first.length; index++) {
      expect(
        ((panned[index].position - first[index].position) - pan).distance,
        lessThan(1e-9),
      );
      expect(
        panned[index].cameraDepth,
        closeTo(first[index].cameraDepth, 1e-12),
      );
      expect(panned[index].depth, closeTo(first[index].depth, 1e-12));
    }
  });

  test(
    'shell guides cover every hollow sphere deterministically and finitely',
    () {
      const viewport = Size(920, 680);
      final first = layout.projectShellGuides(
        viewport: viewport,
        rotationX: -.21,
        rotationY: .37,
        zoom: 1.35,
      );
      final second = layout.projectShellGuides(
        viewport: viewport,
        rotationX: -.21,
        rotationY: .37,
        zoom: 1.35,
      );
      final expectedRadii = <double>[
        ...DesktopSphereGraphLayout.contentShellRadii,
        ...DesktopSphereGraphLayout.atmosphereShellRadii,
      ];

      expect(first, second);
      expect(first, hasLength(expectedRadii.length));
      for (var guideIndex = 0; guideIndex < first.length; guideIndex++) {
        final guide = first[guideIndex];
        expect(guide.radius, closeTo(expectedRadii[guideIndex], 1e-12));
        expect(
          guide.isAtmosphere,
          guideIndex >= DesktopSphereGraphLayout.contentShellRadii.length,
        );
        expect(
          guide.contours,
          hasLength(DesktopSphereGraphLayout.defaultShellGuideContourCount),
        );
        for (final contour in guide.contours) {
          expect(
            contour,
            hasLength(DesktopSphereGraphLayout.defaultShellGuideSegments + 1),
          );
          expect(
            (contour.first.position - contour.last.position).distance,
            lessThan(1e-9),
          );
          expect(
            contour.every(
              (sample) =>
                  sample.position.dx.isFinite &&
                  sample.position.dy.isFinite &&
                  sample.cameraDepth.isFinite &&
                  sample.depth.isFinite &&
                  sample.radialDistance.isFinite &&
                  (sample.radialDistance - guide.radius).abs() < 1e-12,
            ),
            isTrue,
          );
        }
      }
    },
  );

  test(
    'shell guides rotate with the camera and translate with viewport pan',
    () {
      const viewport = Size(920, 680);
      const pan = Offset(83, -47);
      final baseline = layout.projectShellGuides(
        viewport: viewport,
        rotationX: -.21,
        rotationY: .37,
        zoom: 1.35,
      );
      final rotated = layout.projectShellGuides(
        viewport: viewport,
        rotationX: .34,
        rotationY: -.18,
        zoom: 1.35,
      );
      final panned = layout.projectShellGuides(
        viewport: viewport,
        rotationX: -.21,
        rotationY: .37,
        zoom: 1.35,
        pan: pan,
      );

      expect(
        baseline.asMap().entries.any(
          (guideEntry) => guideEntry.value.contours.asMap().entries.any(
            (contourEntry) => contourEntry.value.asMap().entries.any(
              (sampleEntry) =>
                  (sampleEntry.value.position -
                          rotated[guideEntry.key]
                              .contours[contourEntry.key][sampleEntry.key]
                              .position)
                      .distance >
                  .1,
            ),
          ),
        ),
        isTrue,
      );
      for (var guideIndex = 0; guideIndex < baseline.length; guideIndex++) {
        final baseGuide = baseline[guideIndex];
        final pannedGuide = panned[guideIndex];
        expect(pannedGuide.radius, closeTo(baseGuide.radius, 1e-12));
        expect(pannedGuide.isAtmosphere, baseGuide.isAtmosphere);
        for (
          var contourIndex = 0;
          contourIndex < baseGuide.contours.length;
          contourIndex++
        ) {
          final baseContour = baseGuide.contours[contourIndex];
          final pannedContour = pannedGuide.contours[contourIndex];
          expect(pannedContour, hasLength(baseContour.length));
          for (
            var sampleIndex = 0;
            sampleIndex < baseContour.length;
            sampleIndex++
          ) {
            final baseSample = baseContour[sampleIndex];
            final pannedSample = pannedContour[sampleIndex];
            expect(
              ((pannedSample.position - baseSample.position) - pan).distance,
              lessThan(1e-9),
            );
            expect(
              pannedSample.cameraDepth,
              closeTo(baseSample.cameraDepth, 1e-12),
            );
            expect(pannedSample.depth, closeTo(baseSample.depth, 1e-12));
            expect(
              pannedSample.radialDistance,
              closeTo(baseSample.radialDistance, 1e-12),
            );
          }
        }
      }
    },
  );

  test('large collections keep every point with a bounded connected mesh', () {
    final points = layout.build(
      realNodeIds: List<String>.generate(
        2004,
        (index) => 'stress-20260728-${index.toString().padLeft(4, '0')}',
      ),
      minimumVisualNodeCount: 0,
    );

    final first = layout.buildVisualLinks(points: points, neighborsPerPoint: 3);
    final second = layout.buildVisualLinks(
      points: points.reversed,
      neighborsPerPoint: 3,
    );

    expect(points, hasLength(2004));
    expect(points.every((point) => !point.isSynthetic), isTrue);
    final projected = layout.project(
      points: points,
      viewport: const Size(760, 640),
      padding: 14,
    );
    expect(projected, hasLength(points.length));
    expect(
      projected.every(
        (point) =>
            point.position.dx >= 0 &&
            point.position.dx <= 760 &&
            point.position.dy >= 0 &&
            point.position.dy <= 640,
      ),
      isTrue,
    );
    expect(first, second);
    expect(first, hasLength(lessThanOrEqualTo((points.length - 1) * 4)));

    final adjacency = <String, Set<String>>{
      for (final point in points) point.id: <String>{},
    };
    for (final link in first) {
      adjacency[link.sourceId]!.add(link.targetId);
      adjacency[link.targetId]!.add(link.sourceId);
    }
    final reached = <String>{points.first.id};
    final queue = <String>[points.first.id];
    for (var index = 0; index < queue.length; index++) {
      final current = queue[index];
      for (final next in adjacency[current]!) {
        if (reached.add(next)) queue.add(next);
      }
    }
    expect(reached, hasLength(points.length));
  });

  testWidgets('graph zoom supports bounded high-detail inspection', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 960,
          height: 720,
          child: DesktopKnowledgeGraph(
            documents: <HuahuoDocumentSnapshot>[
              HuahuoDocumentSnapshot(
                id: 'zoom-contract',
                title: 'Zoom contract',
                deltaJson: '[{"insert":"Keeps the sphere composed.\\n"}]',
                revision: 1,
                createdAt: DateTime.utc(2026, 7, 29),
                modifiedAt: DateTime.utc(2026, 7, 29),
              ),
            ],
            onOpenDocument: (_) {},
            onOpenReference: (_) {},
            onSelectionChanged: (_) {},
            onAddToContext: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('100%'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    for (var index = 0; index < 12; index++) {
      await tester.tap(find.byKey(const ValueKey<String>('graph-zoom-out')));
      await tester.pump();
    }
    expect(find.text('50%'), findsOneWidget);

    for (var index = 0; index < 12; index++) {
      await tester.tap(find.byKey(const ValueKey<String>('graph-zoom-in')));
      await tester.pump();
    }
    expect(find.text('500%'), findsOneWidget);
  });
}
