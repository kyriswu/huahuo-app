import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/workbench_generation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/workbench_generation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_workbench_generated_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_workbench_generating_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_chat_execution_process.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_glass_accessibility.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_liquid_glass.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

void main() {
  testWidgets('V3 liquid glass respects transparency and motion settings', (
    tester,
  ) async {
    final port = _FakeGlassAccessibilityPort(initialValue: true);
    GlassAccessibilityData? capturedAccessibility;

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: V3GlassAccessibilityScope(port: port, child: child!),
          );
        },
        home: Builder(
          builder: (context) {
            capturedAccessibility = GlassAccessibilityData.of(context);
            return V3GlassHomeScope(
              child: Column(
                children: [
                  V3LiquidGlassCircle(
                    diameter: 120,
                    semanticLabel: '可访问性玻璃圆',
                    tone: V3GlassTone.neutral,
                    onTap: () {},
                    child: const SizedBox.shrink(),
                  ),
                  const SizedBox(
                    width: 205,
                    height: 56,
                    child: V3LiquidGlassSurface(child: SizedBox.expand()),
                  ),
                  const SizedBox(
                    width: 205,
                    height: 56,
                    child: V3FloatingGlassDockSurface(child: SizedBox.expand()),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();

    expect(capturedAccessibility?.reduceMotion, isTrue);
    expect(capturedAccessibility?.reduceTransparency, isTrue);
    expect(find.byType(GlassButton), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.bySemanticsLabel('可访问性玻璃圆'), findsOneWidget);
  });

  testWidgets('V3 liquid glass uses an interactive fallback before readiness', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: V3GlassRuntimeScope(
          enabled: false,
          child: V3GlassHomeScope(
            child: Center(
              child: V3LiquidGlassCircle(
                diameter: 44,
                semanticLabel: '启动静态按钮',
                tone: V3GlassTone.neutral,
                onTap: () => taps += 1,
                child: const Icon(Icons.add),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(GlassButton), findsNothing);
    await tester.tap(find.bySemanticsLabel('启动静态按钮'));
    expect(taps, 1);
  });

  testWidgets('fixed glass has no backdrop-dependent renderer', (tester) async {
    await tester.pumpWidget(
      _glassHarness(
        child: const Column(
          children: [
            SizedBox(
              width: 205,
              height: 56,
              child: V3LiquidGlassSurface(child: SizedBox.expand()),
            ),
            SizedBox(
              width: 205,
              height: 56,
              child: V3FloatingGlassDockSurface(child: SizedBox.expand()),
            ),
          ],
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('adaptive constrained glass is static and stays interactive', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _glassHarness(
        quality: V3VisualQuality.constrained,
        child: V3LiquidGlassSurface(
          child: TextButton(
            key: const ValueKey('constrained-glass-action'),
            onPressed: () => taps += 1,
            child: const Text('继续'),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.byKey(const ValueKey('constrained-glass-action')));
    expect(taps, 1);

    await tester.pumpWidget(
      _glassHarness(
        quality: V3VisualQuality.constrained,
        adaptiveQuality: false,
        child: const SizedBox(
          width: 205,
          height: 56,
          child: V3LiquidGlassSurface(child: SizedBox.expand()),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('scrolling and Reduce Motion suppress real-time glass', (
    tester,
  ) async {
    await tester.pumpWidget(
      _glassHarness(
        child: ListView(
          children: const [
            SizedBox(
              width: 205,
              height: 56,
              child: V3LiquidGlassSurface(child: Text('滚动项')),
            ),
          ],
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.pumpWidget(
      _glassHarness(
        disableAnimations: true,
        child: const SizedBox(
          width: 205,
          height: 56,
          child: V3LiquidGlassSurface(child: Text('减少动态效果')),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('surface stays interactive without backdrop sampling', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _glassHarness(
        child: V3LiquidGlassSurface(
          child: TextButton(
            key: const ValueKey('static-glass-action'),
            onPressed: () => taps += 1,
            child: const Text('静态玻璃'),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.byKey(const ValueKey('static-glass-action')));
    expect(taps, 1);
  });

  testWidgets('balanced glass caps caller blur through the shared token', (
    tester,
  ) async {
    double? resolvedSigma;
    await tester.pumpWidget(
      _glassHarness(
        quality: V3VisualQuality.balanced,
        child: Builder(
          builder: (context) {
            resolvedSigma = V3GlassPerformanceScope.resolveBlurSigma(
              context,
              requested: 22,
              balancedMaximum: 14,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(resolvedSigma, 14);
  });

  testWidgets('permanent loops stop when hidden or Reduce Motion is enabled', (
    tester,
  ) async {
    final metrics = RuntimeActivityMetrics();
    addTearDown(metrics.dispose);
    Widget loops({required bool tickerEnabled, bool reduceMotion = false}) {
      return RuntimeActivityMetricsScope(
        metrics: metrics,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          home: TickerMode(
            enabled: tickerEnabled,
            child: const Column(
              children: [
                V3Waveform(),
                V3AgentRunGlyph(color: Colors.black),
              ],
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(loops(tickerEnabled: true));
    await tester.pump();
    expect(metrics.current.activeTickers, 2);

    await tester.pumpWidget(loops(tickerEnabled: false));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(metrics.current.activeTickers, 0);

    await tester.pumpWidget(loops(tickerEnabled: true, reduceMotion: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(metrics.current.activeTickers, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(metrics.current.activeTickers, 0);
  });

  testWidgets(
    'invalid generating route preserves navigation until explicit return',
    (tester) async {
      final library = KnowledgeLibraryController();
      final generation = WorkbenchGenerationController(
        library: library,
        repository: const WorkbenchGenerationMockRepository(
          delay: Duration.zero,
        ),
      );
      final router = _workbenchGenerationRouter();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            workbenchGenerationControllerProvider.overrideWith(
              (ref) => generation,
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open-generating-route')));
      await tester.pumpAndSettle();

      expect(find.text('生成记录不可用'), findsOneWidget);
      expect(generation.tasks, isEmpty);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-picker-route')),
        findsOneWidget,
      );
      expect(find.byType(V3WorkbenchGeneratingPage), findsNothing);
      expect(router.canPop(), isFalse);
    },
  );

  testWidgets(
    'generation and regeneration preserve material selection below the result',
    (tester) async {
      final note = V3FeedItem(
        id: 'generation-route-note',
        title: '素材选择来源',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 17),
        rawBody: '用于生成的原始内容',
      );
      final library = KnowledgeLibraryController(initialNotes: [note]);
      final generation =
          WorkbenchGenerationController(
              library: library,
              repository: const WorkbenchGenerationMockRepository(
                delay: Duration.zero,
              ),
            )
            ..startSelection(WorkbenchPurpose.persona)
            ..toggleNote(note.id);
      final router = _workbenchGenerationRouter();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
            workbenchGenerationControllerProvider.overrideWith(
              (ref) => generation,
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('open-generating-route')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(V3WorkbenchGeneratedPage), findsOneWidget);
      expect(generation.purpose, WorkbenchPurpose.persona);
      expect(generation.resultMarkdown, isNotNull);
      expect(generation.status, WorkbenchGenerationStatus.succeeded);

      final regenerate = find.byWidgetPredicate(
        (widget) => widget is V3PrimaryButton && widget.label == '重新生成',
      );
      await tester.scrollUntilVisible(regenerate, 300);
      expect(regenerate, findsOneWidget);
      await tester.tap(regenerate);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(V3WorkbenchGeneratedPage), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-picker-route')),
        findsOneWidget,
      );
      expect(router.canPop(), isFalse);
    },
  );
}

Widget _glassHarness({
  required Widget child,
  V3VisualQuality quality = V3VisualQuality.high,
  bool adaptiveQuality = true,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: app!,
    ),
    home: V3GlassPerformanceScope(
      quality: quality,
      adaptiveQuality: adaptiveQuality,
      child: V3GlassHomeScope(child: child),
    ),
  );
}

GoRouter _workbenchGenerationRouter() => GoRouter(
  initialLocation: AppRoutePaths.workbenchMaterials('persona'),
  routes: [
    GoRoute(
      path: AppRoutePaths.workbenchMaterialsRoute,
      builder: (context, state) => Scaffold(
        key: const ValueKey('material-picker-route'),
        body: Center(
          child: TextButton(
            key: const ValueKey('open-generating-route'),
            onPressed: () => context.push(
              AppRoutePaths.workbenchGenerating(
                state.pathParameters['purpose'] ?? 'persona',
              ),
            ),
            child: const Text('打开生成页'),
          ),
        ),
      ),
    ),
    GoRoute(
      path: AppRoutePaths.workbenchGeneratingRoute,
      builder: (context, state) => V3WorkbenchGeneratingPage(
        purpose: WorkbenchPurpose.persona,
        resumeOperationId: state.uri.queryParameters['operationId'],
      ),
    ),
    GoRoute(
      path: AppRoutePaths.workbenchGeneratedRoute,
      builder: (context, state) => V3WorkbenchGeneratedPage(
        purpose: WorkbenchPurpose.persona,
        operationId: state.uri.queryParameters['operationId'],
      ),
    ),
  ],
);

final class _FakeGlassAccessibilityPort implements GlassAccessibilityPort {
  _FakeGlassAccessibilityPort({required this.initialValue});

  final bool initialValue;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  Stream<bool> get reduceTransparencyChanges => _changes.stream;

  @override
  Future<bool> getReduceTransparencyEnabled() async => initialValue;

  @override
  void dispose() => _changes.close();
}
