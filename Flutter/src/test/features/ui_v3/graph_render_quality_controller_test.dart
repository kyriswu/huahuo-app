import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/performance/performance_policy.dart';
import 'package:huahuoai_app/features/ui_v3/application/graph_render_budget.dart';
import 'package:huahuoai_app/features/ui_v3/application/graph_render_quality_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_edge_geometry.dart';

void main() {
  test('interaction settles once after a 120ms quiet window', () async {
    final controller = GraphRenderQualityController();
    addTearDown(controller.dispose);
    final states = <GraphRenderQuality>[];
    controller.addListener(() => states.add(controller.quality));

    controller.beginInteraction();
    controller.endInteraction();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    controller.endInteraction();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(controller.quality, GraphRenderQuality.settling);
    await Future<void>.delayed(const Duration(milliseconds: 70));

    expect(controller.quality, GraphRenderQuality.idle);
    expect(states, <GraphRenderQuality>[
      GraphRenderQuality.interacting,
      GraphRenderQuality.settling,
      GraphRenderQuality.idle,
    ]);
  });

  test('inactive cancels settling until reactivated', () async {
    final controller = GraphRenderQualityController();
    addTearDown(controller.dispose);

    controller.beginInteraction();
    controller.endInteraction();
    controller.setActive(false);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(controller.quality, GraphRenderQuality.inactive);

    controller.beginInteraction();
    expect(controller.quality, GraphRenderQuality.inactive);
    controller.setActive(true);
    expect(controller.quality, GraphRenderQuality.idle);
  });

  test('performance limits update the budget without changing activity', () {
    final controller = GraphRenderQualityController();
    addTearDown(controller.dispose);

    controller.setPerformanceLimits(
      maximumVisualNodeCount: 32,
      maximumOrdinaryEdgeCount: 48,
    );
    final budget = controller.resolveBudget(GraphGeometryLod.near);

    expect(controller.quality, GraphRenderQuality.idle);
    expect(budget.maximumVisualNodeCount, 32);
    expect(budget.ordinaryEdgeCount, 48);
  });

  test('runtime policy updates its complete graph-facing slice once', () {
    final controller = GraphRenderQualityController();
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.beginInteraction();
    controller.setPerformancePolicy(
      maximumVisualNodeCount: 32,
      maximumOrdinaryEdgeCount: 48,
      visualQuality: AppVisualQuality.constrained,
      allowIdleAnimation: false,
    );
    controller.setPerformancePolicy(
      maximumVisualNodeCount: 32,
      maximumOrdinaryEdgeCount: 48,
      visualQuality: AppVisualQuality.constrained,
      allowIdleAnimation: false,
    );

    final budget = controller.resolveBudget(GraphGeometryLod.near);
    expect(controller.quality, GraphRenderQuality.interacting);
    expect(controller.visualQuality, AppVisualQuality.constrained);
    expect(controller.allowIdleAnimation, isFalse);
    expect(budget.maximumVisualNodeCount, 32);
    expect(budget.ordinaryEdgeCount, 48);
    expect(notifications, 2);
  });
}
