import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/workbench_generation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/workbench_generation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_workbench_material_picker_page.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

import '../../support/mobile_agent_test_support.dart';

void main() {
  testWidgets('only deposited personal assets support multi-select', (
    tester,
  ) async {
    final hotspot = V3FeedItem(
      id: 'hotspot',
      title: '热点材料',
      source: V3MaterialSource.hotspot,
      ownership: V3NoteOwnership.hotspot,
      createdAt: DateTime(2026, 7, 13),
      rawBody: '',
      summaryBody: '热点纲要',
    );
    final normal = V3FeedItem(
      id: 'normal',
      title: '普通材料',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 12),
      rawBody: '原始内容',
      summaryBody: '普通纲要',
      remoteNoteId: 'remote-normal',
      rawPartRevisionId: 'remote-normal-raw-1',
    );
    final library = KnowledgeLibraryController(initialNotes: [normal, hotspot]);
    expect(library.depositContent(normal.id), isNotNull);
    final generation = WorkbenchGenerationController(
      library: library,
      repository: const WorkbenchGenerationMockRepository(delay: Duration.zero),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...mobileAgentReadyTestOverrides(),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          workbenchGenerationControllerProvider.overrideWith(
            (ref) => generation,
          ),
        ],
        child: const MaterialApp(
          home: V3WorkbenchMaterialPickerPage(
            purpose: WorkbenchPurpose.persona,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('热点材料'), findsNothing);
    expect(find.text('普通材料'), findsOneWidget);
    await tester.tap(find.text('普通材料'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 条笔记'), findsOneWidget);
    expect(
      tester
          .widget<V3PrimaryButton>(find.widgetWithText(V3PrimaryButton, '上传'))
          .enabled,
      isTrue,
    );
  });

  testWidgets('random selection replaces the selected ready assets', (
    tester,
  ) async {
    final notes = List<V3FeedItem>.generate(
      4,
      (index) => V3FeedItem(
        id: 'ready-$index',
        title: '资产 ${index + 1}',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 7, 14, index),
        rawBody: '可用于分析的内容 $index',
        remoteNoteId: 'remote-ready-$index',
        rawPartRevisionId: 'raw-ready-$index',
      ),
    );
    final library = KnowledgeLibraryController(initialNotes: notes);
    for (final note in notes) {
      expect(library.depositContent(note.id), isNotNull);
    }
    final generation = WorkbenchGenerationController(
      library: library,
      repository: const WorkbenchGenerationMockRepository(delay: Duration.zero),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...mobileAgentReadyTestOverrides(),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          workbenchGenerationControllerProvider.overrideWith(
            (ref) => generation,
          ),
        ],
        child: const MaterialApp(
          home: V3WorkbenchMaterialPickerPage(purpose: WorkbenchPurpose.lead),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('workbench-asset-random-select')),
    );
    await tester.pump();

    expect(generation.selectedCount, inInclusiveRange(1, 2));
    expect(
      generation.selectedNoteIds.every(
        (id) => notes.any((note) => note.id == id),
      ),
      isTrue,
    );
  });

  testWidgets('upload opens the one-shot specialist analysis route', (
    tester,
  ) async {
    final asset = V3FeedItem(
      id: 'upload-ready',
      title: '可上传资产',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 7, 14),
      rawBody: '已有正式版本的资产。',
      remoteNoteId: 'remote-upload-ready',
      rawPartRevisionId: 'raw-upload-ready',
    );
    final library = KnowledgeLibraryController(initialNotes: [asset]);
    expect(library.depositContent(asset.id), isNotNull);
    final generation = WorkbenchGenerationController(
      library: library,
      repository: const WorkbenchGenerationMockRepository(delay: Duration.zero),
    );
    Uri? analysisUri;
    final router = GoRouter(
      initialLocation: '/picker',
      routes: <RouteBase>[
        GoRoute(
          path: '/picker',
          builder: (context, state) => const V3WorkbenchMaterialPickerPage(
            purpose: WorkbenchPurpose.persona,
          ),
        ),
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) {
            analysisUri = state.uri;
            return const Scaffold(body: Text('分析会话'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...mobileAgentReadyTestOverrides(),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          workbenchGenerationControllerProvider.overrideWith(
            (ref) => generation,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('可上传资产'));
    await tester.pump();
    await tester.tap(find.widgetWithText(V3PrimaryButton, '上传'));
    await tester.pumpAndSettle();

    expect(generation.selectedNoteIds, isEmpty);
    expect(analysisUri?.queryParameters['skill'], 'persona');
    expect(analysisUri?.queryParameters['materialIds'], 'upload-ready');
    expect(analysisUri?.queryParameters['analyzeAssets'], '1');
  });

  testWidgets('empty-library recovery pushes feed and restores the picker', (
    tester,
  ) async {
    final library = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    final generation = WorkbenchGenerationController(
      library: library,
      repository: const WorkbenchGenerationMockRepository(delay: Duration.zero),
    );
    final router = GoRouter(
      initialLocation: '/source',
      routes: <RouteBase>[
        GoRoute(
          path: '/source',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/picker'),
              child: const Text('打开素材选择'),
            ),
          ),
        ),
        GoRoute(
          path: '/picker',
          builder: (context, state) => const V3WorkbenchMaterialPickerPage(
            purpose: WorkbenchPurpose.persona,
          ),
        ),
        GoRoute(
          path: AppRoutePaths.home,
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: context.pop,
              child: const Text('返回素材选择'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...mobileAgentReadyTestOverrides(),
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          workbenchGenerationControllerProvider.overrideWith(
            (ref) => generation,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('打开素材选择'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('前往 思想图谱'));
    await tester.pumpAndSettle();
    expect(find.text('返回素材选择'), findsOneWidget);

    await tester.tap(find.text('返回素材选择'));
    await tester.pumpAndSettle();
    expect(find.text('前往 思想图谱'), findsOneWidget);
  });
}
