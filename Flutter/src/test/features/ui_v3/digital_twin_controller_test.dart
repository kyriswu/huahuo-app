import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/features/ui_v3/data/digital_twin_material_store.dart';
import 'package:huahuoai_app/features/ui_v3/domain/digital_twin_operation.dart';
import 'package:huahuoai_app/features/ui_v3/domain/digital_twin_material.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/ui_v3/application/digital_twin_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/digital_twin_material_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/digital_twin_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/document_change_proposal_api.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_digital_twin_page.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';

DigitalTwinController createDigitalTwinVisualFixture({
  Completer<void>? revisionGate,
  Completer<void>? confirmationGate,
}) {
  final api = _FakeDigitalTwinApi()
    ..revisionGate = revisionGate
    ..confirmationGate = confirmationGate
    ..comparisonAvailable = true
    ..previewFiles = _current(const []).files;
  return DigitalTwinController(api, pollInterval: Duration.zero);
}

DigitalTwinMaterialController createDigitalTwinMaterialVisualFixture() =>
    DigitalTwinMaterialController(
      store: DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'isolated-m12-visual',
      ),
      api: _FakeDigitalTwinApi(),
      resolveSource: (_) async => null,
    );

void main() {
  test(
    'independent positioning owner is excluded from twin review and confirmation',
    () async {
      final api = _FakeDigitalTwinApi()
        ..current = _current([
          'dcp-1',
          'positioning',
        ], positioningOwnsProposals: false)
        ..snapshots['positioning'] = _proposal(
          1,
          id: 'positioning',
          ownerId: 'workspace.user.profile.user_positioning',
        );
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      expect(await controller.load(), isTrue);
      expect(controller.state.current!.files.map((file) => file.id), [
        'experience',
      ]);
      expect(
        controller.state.reviews.map(
          (review) => review.snapshot.proposal.proposalId,
        ),
        ['dcp-1'],
      );
      expect(
        controller.captureConfirmationSelection()!.proposals.map(
          (snapshot) => snapshot.proposal.proposalId,
        ),
        ['dcp-1'],
      );
    },
  );

  testWidgets(
    'independent positioning link does not read positioning state in twin',
    (tester) async {
      final controller = DigitalTwinController(
        _FakeDigitalTwinApi(),
        pollInterval: Duration.zero,
      );
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const V3DigitalTwinPage()),
          GoRoute(
            path: AppRoutePaths.positioningReport,
            builder: (_, _) => const Scaffold(body: Text('独立定位页面')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            digitalTwinControllerProvider.overrideWith((ref) => controller),
            deepPositioningRepositoryProvider.overrideWith(
              (ref) => throw StateError('twin must not load positioning'),
            ),
            initialPositioningTaskStateProvider.overrideWith(
              (ref) => throw StateError('twin must not load positioning tasks'),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('查看定位报告').first);
      await tester.pumpAndSettle();
      expect(find.text('独立定位页面'), findsOneWidget);
    },
  );
  _followUpAuditCases();
  _durableOperationCases();
  _recoveryCases();
  for (final failure in [
    (
      code: 'DOCUMENT_GENERATION_FAILED',
      message: '蒸馏候选生成失败，原材料已保留，可查看候选后重新生成。',
    ),
    (
      code: 'DOCUMENT_CANDIDATE_TARGET_MISSED',
      message: '蒸馏候选未通过校验，原材料已保留，可查看候选后重新生成。',
    ),
    (
      code: 'DIGITAL_TWIN_QUEUE_SAVE_FAILED',
      message: '本地材料状态保存失败，原任务已保留，请重新核验。',
    ),
    (
      code: 'UNRECOGNIZED_MATERIAL_FAILURE',
      message: '蒸馏处理暂未完成，原材料和已受理任务已保留，请重新核验。',
    ),
  ]) {
    testWidgets(
      'material errors use Chinese copy without losing ${failure.code}',
      (tester) async {
        tester.view
          ..physicalSize = const Size(390, 844)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = DigitalTwinMaterialStore(
          database: AppDatabase(),
          scope: 'material-error-presentation',
        );
        await store.save(
          DigitalTwinMaterial(
            id: 'failed-material',
            referenceKind: 'note',
            referenceId: 'note-1',
            title: '蒸馏测试材料',
            createdAt: DateTime.utc(2026, 9, 7),
            status: DigitalTwinMaterialStatus.partialFailure,
            proposalIds: const {'user_profile': 'dcp-1'},
            errorCode: failure.code,
          ),
        );
        final materialApi = _FakeDigitalTwinApi()
          ..proposalReadFailureCode = failure.code;
        final materials = DigitalTwinMaterialController(
          store: store,
          api: materialApi,
          resolveSource: (_) async => null,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              digitalTwinControllerProvider.overrideWith(
                (ref) => DigitalTwinController(_FakeDigitalTwinApi()),
              ),
              digitalTwinMaterialControllerProvider.overrideWith(
                (ref) => materials,
              ),
            ],
            child: const MaterialApp(home: V3DigitalTwinPage()),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('digital-twin-material-queue')),
        );
        await tester.pumpAndSettle();
        expect(find.text(failure.message), findsOneWidget);
        expect(find.text(failure.code), findsNothing);

        await tester.tap(find.text('蒸馏测试材料'));
        await tester.pumpAndSettle();
        expect(find.text(failure.message), findsNWidgets(2));
        expect(find.text(failure.code), findsNothing);

        final readsBeforeRefresh = materialApi.proposalReads;
        await tester.tap(find.text('重新核验'));
        await tester.pumpAndSettle();
        expect(materialApi.proposalReads, greaterThan(readsBeforeRefresh));
        expect(store.read().single.errorCode, failure.code);
        expect(store.read().single.proposalIds, {'user_profile': 'dcp-1'});
        expect(materialApi.revisedProposalIds, isEmpty);
        expect(materialApi.confirmationCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  test(
    'accepted queue confirmation locks scope and restores without duplicate submission',
    () async {
      final api = _FakeDigitalTwinApi()..confirmationState = 'applying';
      api.omitConfirmationVersion = true;
      final settled = <String>[];
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
        onConfirmationSettled: (id) async {
          settled.add(id);
        },
      );
      addTearDown(controller.dispose);
      expect(
        await controller.load(
          reviewProposalIds: ['dcp-1'],
          confirmationTaskId: 'task-1',
        ),
        isTrue,
      );
      expect(controller.hasPendingConfirmation, isTrue);
      expect(
        await controller.load(
          importSource: null,
          reviewProposalIds: ['another'],
        ),
        isFalse,
      );
      expect(
        controller.state.errorCode,
        'DIGITAL_TWIN_CONFIRMATION_IN_PROGRESS',
      );
      api.confirmationState = 'report_ready';
      api.omitConfirmationVersion = false;
      expect(await controller.confirmReady(), isTrue);
      expect(api.confirmationCalls, 0);
      expect(settled, ['task-1']);
      expect(controller.hasPendingConfirmation, isFalse);
    },
  );
  test(
    'generating root proposals cannot be included in a formal confirmation',
    () async {
      final api = _FakeDigitalTwinApi();
      api.generatingProposalReadsBeforeReady = 100;
      api.snapshots['dcp-1'] = _proposal(
        1,
        state: DocumentProposalState.generating,
      );
      final controller = DigitalTwinController(api);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.state.readyProposalCount, 0);
      expect(controller.captureConfirmationSelection(), isNull);
    },
  );
  const material = DigitalTwinImportSource(
    importTaskId: 'import-1',
    taskId: 'distill-1',
    resourceId: 'resource-1',
    noteId: 'note-1',
    title: 'Meeting',
  );

  test(
    'material review excludes unrelated and unchanged candidates from confirmation',
    () async {
      final api = _FakeDigitalTwinApi()
        ..snapshots['dcp-1'] = _proposal(
          1,
          sourceNoteIds: {'note-1'},
          hasChanges: true,
        )
        ..snapshots['unchanged'] = _proposal(
          1,
          id: 'unchanged',
          sourceNoteIds: {'note-1'},
          hasChanges: false,
        )
        ..snapshots['unrelated'] = _proposal(
          1,
          id: 'unrelated',
          sourceNoteIds: {'other-note'},
          hasChanges: true,
        );
      String? savedConfirmation;
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
        onConfirmationCreated: (source, id) async {
          expect(source.taskId, 'distill-1');
          savedConfirmation = id;
        },
      );
      addTearDown(controller.dispose);
      expect(await controller.load(importSource: material), isTrue);
      expect(controller.state.reviews, hasLength(2));
      expect(controller.state.readyProposalCount, 1);
      expect(controller.importWaiting, isFalse);
      expect(await controller.rejectUnchanged(), isTrue);
      expect(api.rejectedIds, ['unchanged']);
      expect(await controller.confirmReady(), isTrue);
      expect(api.confirmedIds, ['dcp-1']);
      expect(api.confirmedSource?.resourceId, 'resource-1');
      expect(savedConfirmation, 'task-1');
      expect(controller.state.confirmation?.version?.versionId, 'dtv-1');
    },
  );

  test(
    'restores an accepted confirmation without creating another task',
    () async {
      final api = _FakeDigitalTwinApi();
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      expect(
        await controller.load(
          importSource: const DigitalTwinImportSource(
            importTaskId: 'import-1',
            taskId: 'distill-1',
            resourceId: 'resource-1',
            noteId: 'note-1',
            title: 'Meeting',
            confirmationTaskId: 'task-1',
          ),
        ),
        isTrue,
      );
      expect(controller.state.confirmation?.state, 'report_ready');
      expect(api.confirmationCalls, 0);
    },
  );

  test('a terminal report without a formal version is not success', () async {
    final api = _FakeDigitalTwinApi()..omitConfirmationVersion = true;
    final controller = DigitalTwinController(api, pollInterval: Duration.zero);
    addTearDown(controller.dispose);
    await controller.load();
    expect(await controller.confirmReady(), isFalse);
    expect(controller.hasPendingConfirmation, isTrue);
    api.omitConfirmationVersion = false;
    expect(await controller.confirmReady(), isTrue);
    expect(api.confirmationCalls, 1);
  });

  test(
    'material observation pauses off-route and settles when candidates are ready',
    () async {
      final api = _FakeDigitalTwinApi()..distillationStatus = 'running';
      final orchestrator = TaskOrchestrator();
      final metrics = RuntimeActivityMetrics();
      final controller = DigitalTwinController(
        api,
        taskOrchestrator: orchestrator,
        activityMetrics: metrics,
      );
      addTearDown(() {
        controller.dispose();
        orchestrator.dispose();
      });
      controller.setPollingRouteActive(false);
      await controller.load(importSource: material);
      expect(controller.importWaiting, isTrue);
      final reads = api.distillationReads;
      await Future<void>.delayed(Duration.zero);
      expect(api.distillationReads, reads);
      api.distillationStatus = 'succeeded';
      api.snapshots['dcp-1'] = _proposal(
        1,
        sourceNoteIds: {'note-1'},
        hasChanges: true,
      );
      controller.setPollingRouteActive(true);
      for (
        var attempt = 0;
        attempt < 30 && controller.importWaiting;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.importWaiting, isFalse);
      expect(controller.state.readyProposalCount, 1);
      expect(
        orchestrator.snapshot.projections.every(
          (projection) => !projection.spec.key.contains(material.taskId),
        ),
        isTrue,
      );
    },
  );

  test(
    'continues an in-flight confirmation rather than resubmitting it',
    () async {
      final api = _FakeDigitalTwinApi()..confirmationState = 'applying';
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load(
        importSource: const DigitalTwinImportSource(
          importTaskId: 'import-1',
          taskId: 'distill-1',
          resourceId: 'resource-1',
          noteId: 'note-1',
          title: 'Meeting',
          confirmationTaskId: 'task-1',
        ),
      );
      expect(controller.state.confirmation?.isTerminal, isFalse);
      api.confirmationState = 'report_ready';
      expect(await controller.confirmReady(), isTrue);
      expect(api.confirmationCalls, 0);
    },
  );

  testWidgets('Digital Twin import entry opts into material distillation', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/twin',
      routes: [
        GoRoute(
          path: '/twin',
          builder: (context, state) => const V3DigitalTwinPage(),
        ),
        GoRoute(
          path: '/v3/feed/import/documents',
          builder: (context, state) => Scaffold(
            body: Text(
              'import:${state.uri.queryParameters['digitalTwin']}:${state.uri.queryParameters['entry']}',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          digitalTwinControllerProvider.overrideWith(
            (ref) => DigitalTwinController(_FakeDigitalTwinApi()),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();
    if (find
        .byKey(const ValueKey('digital-twin-import-material'))
        .evaluate()
        .isEmpty) {
      await tester.tap(find.byKey(const ValueKey('digital-twin-info')));
      await tester.pumpAndSettle();
    }
    await tester.tap(
      find.byKey(const ValueKey('digital-twin-import-material')),
    );
    await tester.pumpAndSettle();
    expect(find.text('import:1:fresh'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'loads, revises a selected hunk, and confirms a formal version',
    () async {
      final api = _FakeDigitalTwinApi();
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
        maxPollAttempts: 1,
      );
      addTearDown(controller.dispose);

      expect(await controller.load(), isTrue);
      expect(controller.state.phase, DigitalTwinControllerPhase.ready);
      expect(controller.state.selectedProposalId, 'dcp-1');
      expect(controller.state.selectedReview?.candidateMarkdown, '# Candidate');
      expect(controller.state.selectedReview?.diff.single.hunkId, 'hunk-1');

      controller.toggleHunk('hunk-1');
      expect(await controller.reviseSelected('Keep this hunk.'), isTrue);
      expect(api.revisedHunks.single.hunkId, 'hunk-1');
      expect(api.revisedHunks.single.quotedText, 'Candidate\n');
      expect(
        controller.state.selectedReview?.snapshot.proposal.proposalVersion,
        2,
      );

      expect(await controller.confirmReady(), isTrue);
      expect(controller.state.phase, DigitalTwinControllerPhase.ready);
      expect(controller.state.reviews, isEmpty);
      expect(controller.state.versions.last.label, 'v1');
      expect(controller.state.confirmation?.appliedCount, 1);
    },
  );

  test('retries formal confirmation for an apply-failed candidate', () async {
    final api = _FakeDigitalTwinApi()
      ..snapshots['dcp-1'] = _proposal(
        1,
        state: DocumentProposalState.applyFailed,
        failureCode: 'DIGITAL_TWIN_APPLY_RETRYABLE',
      );
    final controller = DigitalTwinController(
      api,
      pollInterval: Duration.zero,
      maxPollAttempts: 1,
    );
    addTearDown(controller.dispose);

    expect(await controller.load(), isTrue);
    expect(controller.state.readyProposalCount, 1);
    expect(await controller.confirmReady(), isTrue);
    expect(controller.state.confirmation?.appliedCount, 1);
  });

  test('fans selected hunks out through their owning proposals', () async {
    final api = _FakeDigitalTwinApi()
      ..snapshots['dcp-2'] = _proposal(1, id: 'dcp-2')
      ..current = _current(const <String>['dcp-1', 'dcp-2']);
    final controller = DigitalTwinController(
      api,
      pollInterval: Duration.zero,
      maxPollAttempts: 1,
    );
    addTearDown(controller.dispose);

    expect(await controller.load(), isTrue);
    controller.toggleHunk('hunk-1');
    await controller.selectProposal('dcp-2');
    controller.toggleHunk('hunk-2');

    expect(controller.state.selectedHunkCount, 2);
    expect(await controller.reviseSelected('Keep both references.'), isTrue);
    expect(api.revisedProposalIds, containsAll(<String>['dcp-1', 'dcp-2']));
    expect(api.revisedHunksByProposal['dcp-1']?.single.hunkId, 'hunk-1');
    expect(api.revisedHunksByProposal['dcp-2']?.single.hunkId, 'hunk-2');
  });

  test('failed revision keeps the prior ready candidate', () async {
    final api = _FakeDigitalTwinApi()
      ..revisionFailureCode = 'DOCUMENT_GENERATION_FAILED';
    final controller = DigitalTwinController(
      api,
      pollInterval: Duration.zero,
      maxPollAttempts: 1,
    );
    addTearDown(controller.dispose);

    expect(await controller.load(), isTrue);
    controller.toggleHunk('hunk-1');

    expect(await controller.reviseSelected('Try this change.'), isFalse);
    expect(controller.state.errorCode, 'DOCUMENT_GENERATION_FAILED');
    expect(
      controller.state.selectedReview?.snapshot.proposal.proposalVersion,
      1,
    );
    expect(controller.state.selectedReview?.candidateMarkdown, '# Candidate');
    expect(controller.state.canRevise, isTrue);
  });

  test('older proposal versions are inspectable but read only', () async {
    final api = _FakeDigitalTwinApi()..snapshots['dcp-1'] = _proposal(2);
    final controller = DigitalTwinController(api, pollInterval: Duration.zero);
    addTearDown(controller.dispose);

    expect(await controller.load(), isTrue);
    await controller.inspectProposalVersion('dcp-1', 1);

    expect(controller.state.selectedReview?.visibleVersion, 1);
    expect(controller.state.selectedReview?.isViewingCurrent, isFalse);
    expect(controller.state.canRevise, isFalse);
  });

  test('formal restore returns ordinary proposals to pending review', () async {
    final api = _FakeDigitalTwinApi();
    final controller = DigitalTwinController(
      api,
      pollInterval: Duration.zero,
      maxPollAttempts: 1,
    );
    addTearDown(controller.dispose);

    expect(await controller.load(), isTrue);
    expect(await controller.restoreVersion('dtv-0'), isTrue);
    expect(controller.state.selectedProposalId, 'dcp-restore');
    expect(controller.state.readyProposalCount, 1);
  });

  test(
    'pulls a formal version through the supplied archive exporter',
    () async {
      final controller = DigitalTwinController(_FakeDigitalTwinApi());
      addTearDown(controller.dispose);
      Uint8List? exported;

      final ok = await controller.pullVersion(
        'dtv-0',
        export: (bytes) async {
          exported = bytes;
          return true;
        },
      );

      expect(ok, isTrue);
      expect(exported, Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04]));
      expect(controller.state.archiveVersionId, 'dtv-0');
      expect(controller.state.archiveSizeBytes, 4);
    },
  );

  test(
    'proposal polling pauses by route and redacts its scheduler key',
    () async {
      final api = _FakeDigitalTwinApi()..revisionReturnsGenerating = true;
      final orchestrator = TaskOrchestrator();
      final metrics = RuntimeActivityMetrics();
      final controller = DigitalTwinController(
        api,
        pollInterval: const Duration(milliseconds: 1),
        maxPollAttempts: 2,
        taskOrchestrator: orchestrator,
        activityMetrics: metrics,
      );
      addTearDown(() {
        controller.dispose();
        orchestrator.dispose();
        metrics.dispose();
      });

      expect(await controller.load(), isTrue);
      controller.toggleHunk('hunk-1');
      controller.setPollingRouteActive(false);
      final revision = controller.reviseSelected('Wait until visible.');
      await Future<void>.delayed(Duration.zero);
      final readsWhileHidden = api.proposalReads;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(api.proposalReads, readsWhileHidden);

      controller.setPollingRouteActive(true);
      expect(await revision.timeout(const Duration(seconds: 1)), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(metrics.snapshot().peakPollers, 1);
      expect(metrics.current.activePollers, 0);
      expect(
        orchestrator.snapshot.projections.every(
          (projection) => !projection.spec.key.contains('dcp-1'),
        ),
        isTrue,
      );
    },
  );

  testWidgets('particle pulse reports only visible active ticker work', (
    tester,
  ) async {
    final metrics = RuntimeActivityMetrics();
    addTearDown(metrics.dispose);
    final api = _FakeDigitalTwinApi()..current = _current(const <String>[]);
    final controller = DigitalTwinController(api);
    expect(await controller.load(), isTrue);
    final activity = AppActivityCoordinator(binding: tester.binding);
    final activityInput = ValueNotifier((visible: true, reduceMotion: false));
    addTearDown(activityInput.dispose);

    await tester.pumpWidget(
      RuntimeActivityMetricsScope(
        metrics: metrics,
        child: ProviderScope(
          overrides: [
            digitalTwinControllerProvider.overrideWith((ref) => controller),
            appActivityCoordinatorProvider.overrideWith((ref) => activity),
          ],
          child: ValueListenableBuilder(
            valueListenable: activityInput,
            builder: (context, input, _) => MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: input.reduceMotion),
                child: child!,
              ),
              home: TickerMode(
                enabled: input.visible,
                child: const V3DigitalTwinPage(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('digital-twin-particle-person')),
      findsOneWidget,
    );
    expect(metrics.current.activeTickers, 1);

    activityInput.value = (visible: false, reduceMotion: false);
    await tester.pump();
    expect(metrics.current.activeTickers, 0);

    activityInput.value = (visible: true, reduceMotion: false);
    await tester.pump();
    expect(metrics.current.activeTickers, 1);

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(metrics.current.activeTickers, 0);

    activity.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    expect(metrics.current.activeTickers, 1);

    activityInput.value = (visible: true, reduceMotion: true);
    await tester.pump();
    expect(metrics.current.activeTickers, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(metrics.current.activeTickers, 0);
  });

  testWidgets('compact M01 opens files, detail and revision sheet', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeDigitalTwinApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          digitalTwinControllerProvider.overrideWith(
            (ref) => DigitalTwinController(api),
          ),
        ],
        child: const MaterialApp(home: V3DigitalTwinPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('数字孪生'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('digital-twin-open-revision')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('digital-twin-mode-files')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('digital-twin-compact-files')),
      findsOneWidget,
    );
    expect(find.text('构成文件'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('digital-twin-file-experience')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('digital-twin-compact-file-detail')),
      findsOneWidget,
    );
    expect(find.text('在修订中讨论'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('digital-twin-discuss-revision')),
    );
    await tester.pumpAndSettle();
    expect(find.text('数字孪生修订'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('digital-twin-revision-input')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact revision input stays above the keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final api = _FakeDigitalTwinApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          digitalTwinControllerProvider.overrideWith(
            (ref) => DigitalTwinController(api),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const V3DigitalTwinPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('digital-twin-open-revision')));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('digital-twin-revision-input'));
    await tester.tap(input);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    const keyboardTop = 568 - 300.0;
    final submit = find.byKey(const ValueKey('digital-twin-revise-submit'));
    expect(input.hitTestable(), findsOneWidget);
    expect(submit.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(input).dy, lessThanOrEqualTo(keyboardTop));
    expect(tester.getBottomRight(submit).dy, lessThanOrEqualTo(keyboardTop));
    expect(tester.takeException(), isNull);
  });

  testWidgets('M12 preserves quoted input across compact and fullscreen', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeDigitalTwinApi();
    final controller = DigitalTwinController(api);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          digitalTwinControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: V3DigitalTwinPage()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('digital-twin-open-revision')));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('digital-twin-revision-surface')))
          .height,
      414,
    );
    final composer = find.byKey(
      const ValueKey('digital-twin-revision-composer'),
    );
    final composerSurface = find
        .descendant(of: composer, matching: find.byType(DecoratedBox))
        .first;
    expect(tester.getSize(composerSurface).height, 54);
    await tester.tap(
      find.byKey(const ValueKey('digital-twin-revision-file-experience')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ 选中'));
    await tester.pumpAndSettle();
    expect(tester.getSize(composerSurface).height, 96);
    expect(controller.state.selectedHunkCount, 1);
    final input = find.byKey(const ValueKey('digital-twin-revision-input'));
    await tester.enterText(input, '保留来源，只修改第二句话');
    final original = tester.widget<TextField>(input).controller;
    await tester.tap(find.byTooltip('展开'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller, same(original));
    expect(tester.widget<TextField>(input).controller!.text, '保留来源，只修改第二句话');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('digital-twin-confirm')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    expect(controller.state.selectedHunkCount, 1);
    await tester.tap(find.byKey(const ValueKey('digital-twin-revise-submit')));
    await tester.pumpAndSettle();
    expect(api.revisedHunks.single.hunkId, 'hunk-1');
    expect(
      controller.revisionEvents.any(
        (event) => event.isUser && event.text == '保留来源，只修改第二句话',
      ),
      isTrue,
    );
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(find.text('已更新'), findsOneWidget);
    await tester.tap(find.byTooltip('添加上下文'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用文件修改'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('digital-twin-revision-file-experience')),
      findsOneWidget,
    );
    expect(find.text('+ 选中').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'M12 history read failure preserves version identity and retries',
    (tester) async {
      tester.view
        ..physicalSize = const Size(402, 874)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _FakeDigitalTwinApi()
        ..current = _current(const [])
        ..versions = [_version(), _version(number: 1, id: 'dtv-1')]
        ..versionReadFails = true
        ..comparisonAvailable = true
        ..previewFiles = _current(const []).files;
      final controller = DigitalTwinController(api);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            digitalTwinControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3DigitalTwinPage()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('修订记录'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('digital-twin-version-history')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('digital-twin-history-dtv-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('部分内容暂时无法读取'), findsOneWidget);
      expect(find.text('查看本次修订报告'), findsNothing);
      api.versionReadFails = false;
      await tester.tap(find.text('重新核验'));
      await tester.pumpAndSettle();
      expect(controller.state.versionDetail!.version.versionId, 'dtv-1');
      await tester.tap(find.text('查看本次修订报告'));
      await tester.pumpAndSettle();
      expect(find.text('修订报告 · v1'), findsOneWidget);
      expect(find.textContaining('版本内保存的真实差分测试内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in <Size>[const Size(320, 568), const Size(568, 320)]) {
    testWidgets('compact info sheet stays usable at $size and 1.3 scale', (
      tester,
    ) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _FakeDigitalTwinApi();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            digitalTwinControllerProvider.overrideWith(
              (ref) => DigitalTwinController(api),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: const V3DigitalTwinPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('digital-twin-info')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final acknowledge = find.widgetWithText(FilledButton, '知道了');
      expect(acknowledge.hitTestable(), findsOneWidget);
      expect(
        tester.getBottomRight(acknowledge).dy,
        lessThanOrEqualTo(size.height),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(acknowledge);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('什么是数字孪生'), findsNothing);
    });
  }

  for (final size in <Size>[const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('renders the particle view without overflow at $size', (
      tester,
    ) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _FakeDigitalTwinApi()..current = _current(const <String>[]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            digitalTwinControllerProvider.overrideWith(
              (ref) => DigitalTwinController(api),
            ),
          ],
          child: const MaterialApp(home: V3DigitalTwinPage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('digital-twin-interactive-viewer')),
        findsOneWidget,
      );
      if (size.width < 500) {
        expect(
          find.byKey(const ValueKey('digital-twin-view-switch')),
          findsOneWidget,
        );
      } else {
        expect(find.byIcon(Icons.folder_copy_outlined), findsOneWidget);
        expect(find.text('查看定位报告'), findsWidgets);
      }
      expect(tester.takeException(), isNull);

      if (size.width < 500) {
        final scene = find.byKey(const ValueKey('digital-twin-orbit-surface'));
        final semanticsFinder = find.byKey(
          const ValueKey('digital-twin-interactive-viewer'),
        );
        String viewValue() =>
            tester.widget<Semantics>(semanticsFinder).properties.value!;

        final initial = viewValue();
        await tester.drag(scene, const Offset(54, 22));
        await tester.pump();
        expect(viewValue(), isNot(initial));

        final detector = tester.widget<GestureDetector>(scene);
        detector.onScaleStart!(ScaleStartDetails(pointerCount: 2));
        detector.onScaleUpdate!(
          ScaleUpdateDetails(scale: 1.5, pointerCount: 2),
        );
        await tester.pump();
        expect(viewValue(), isNot(contains('缩放 100%')));

        await tester.tap(scene);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(scene);
        await tester.pump(const Duration(milliseconds: 400));
        expect(viewValue(), contains('缩放 100%'));
      }
    });
  }
}

class _LostReceiptApi extends _FakeDigitalTwinApi {
  final List<DigitalTwinConfirmationCommand> attempts = [];
  final List<DigitalTwinProposalCommand> revisions = [];
  bool loseConfirmation = true;
  bool loseRevision = true;
  bool holdRevisionReceipt = false;

  @override
  Future<DigitalTwinConfirmation> createConfirmation({
    required List<DocumentChangeProposalSnapshot> proposals,
    required String idempotencyKey,
    DigitalTwinImportSource? source,
  }) async {
    attempts.add(
      DigitalTwinConfirmationCommand(
        proposals: proposals,
        idempotencyKey: idempotencyKey,
        source: source,
      ),
    );
    final result = await super.createConfirmation(
      proposals: proposals,
      idempotencyKey: idempotencyKey,
      source: source,
    );
    await confirmationGate?.future;
    if (loseConfirmation) {
      loseConfirmation = false;
      throw const DigitalTwinApiException('RESPONSE_LOST');
    }
    return result;
  }

  @override
  Future<DocumentChangeProposalSnapshot> reviseProposal({
    required DocumentChangeProposalSnapshot proposal,
    required String instruction,
    required List<DigitalTwinSelectedHunk> selectedHunks,
    required String idempotencyKey,
  }) async {
    revisions.add(
      DigitalTwinProposalCommand(
        operation: DigitalTwinProposalOperation.revise,
        proposal: proposal,
        instruction: instruction,
        selectedHunks: selectedHunks,
        idempotencyKey: idempotencyKey,
      ),
    );
    if (loseRevision) {
      loseRevision = false;
      await super.reviseProposal(
        proposal: proposal,
        instruction: instruction,
        selectedHunks: selectedHunks,
        idempotencyKey: idempotencyKey,
      );
      throw const DigitalTwinApiException('RESPONSE_LOST');
    }
    if (holdRevisionReceipt)
      throw const DigitalTwinApiException('RESPONSE_LOST');
    return snapshots[proposal.proposal.proposalId]!;
  }
}

void _durableOperationCases() {
  test(
    'durable: historical reports retain citations beyond the live event window and respect version and account scope',
    () async {
      final database = AppDatabase();
      final store = DigitalTwinMaterialStore(
        database: database,
        scope: 'archive-owner',
      );
      for (var version = 1; version <= 101; version++) {
        final command = DigitalTwinProposalCommand(
          idempotencyKey: 'archive-$version',
          operation: DigitalTwinProposalOperation.revise,
          proposal: _proposal(version),
          instruction: '原始修改要求 $version',
          selectedHunks: [
            DigitalTwinSelectedHunk(
              proposalVersion: version,
              diffBundleId: 'bundle-$version',
              hunkId: 'hunk-$version',
              quotedText: '不可丢失的原文 $version',
            ),
          ],
        );
        await store.prepareProposalCommands([command]);
        await store.recordProposalReceipt(command, _proposal(version + 1));
        await store.finishProposalCommand(command, '已生成候选 ${version + 1}');
      }
      final detail = DigitalTwinVersionDetail(
        version: _version(number: 1, id: 'archived-version'),
        operationKey: 'archive',
        rendererVersion: 'v1',
        profileCount: 1,
        hasPositioning: true,
        proposalResults: const [
          DigitalTwinConfirmationOutcome(
            proposalId: 'dcp-1',
            proposalVersion: 101,
            state: DocumentProposalState.applied,
          ),
        ],
      );
      final controller = DigitalTwinController(
        _FakeDigitalTwinApi(),
        recoveryStore: store,
      );
      final other = DigitalTwinController(
        _FakeDigitalTwinApi(),
        recoveryStore: DigitalTwinMaterialStore(
          database: database,
          scope: 'another-account',
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(other.dispose);
      expect(store.revisionEvents.length, 100);
      expect(store.revisionArchive.length, 101);
      final records = controller.revisionRecordsForVersion(detail);
      expect(records.length, 100);
      expect(records.first.command.instruction, '原始修改要求 1');
      expect(
        records.first.command.selectedHunks.single.quotedText,
        '不可丢失的原文 1',
      );
      expect(records.last.command.receipt!.proposal.proposalVersion, 101);
      expect(other.revisionRecordsForVersion(detail), isEmpty);
    },
  );
  test(
    'durable: failed local persistence prevents confirmation mutation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'twin-write-failure-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final persistence = _FailingCommandSnapshotStore(
        File('${directory.path}/commands.json'),
      );
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(snapshotStore: persistence),
        scope: 'account-a',
      );
      final api = _FakeDigitalTwinApi();
      final controller = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load();
      persistence.failWrites = true;
      expect(await controller.confirmReady(), isFalse);
      expect(api.confirmationCalls, 0);
      persistence.failWrites = false;
      expect(await controller.confirmReady(), isTrue);
      expect(api.confirmationCalls, 1);
    },
  );
  test(
    'durable: lost confirmation receipt replays the frozen request after recreation',
    () async {
      final directory = await Directory.systemTemp.createTemp('twin-command-');
      addTearDown(() => directory.delete(recursive: true));
      final persistence = LocalDatabaseSnapshotStore(
        file: File('${directory.path}/journal.sqlite'),
        backend: LocalDatabaseSnapshotBackend.sqlite,
      );
      final database = AppDatabase(snapshotStore: persistence);
      final store = DigitalTwinMaterialStore(
        database: database,
        scope: 'account-a',
      );
      final api = _LostReceiptApi();
      final first = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      await first.load();
      expect(await first.confirmReady(), isFalse);
      expect(store.pendingConfirmationCommand, isNotNull);
      expect(store.pendingConfirmationId, isNull);
      first.dispose();
      final resumedStore = DigitalTwinMaterialStore(
        database: AppDatabase(snapshotStore: persistence),
        scope: 'account-a',
      );
      final resumed = DigitalTwinController(
        api,
        recoveryStore: resumedStore,
        pollInterval: Duration.zero,
      );
      addTearDown(resumed.dispose);
      expect(await resumed.load(), isTrue);
      expect(api.attempts[1].toJson(), api.attempts[0].toJson());
      expect(resumedStore.pendingConfirmationCommand, isNull);
      expect(resumedStore.lastReport?.version?.versionId, 'dtv-1');
      expect(
        DigitalTwinMaterialStore(
          database: database,
          scope: 'account-b',
        ).lastReport,
        isNull,
      );
    },
  );

  test(
    'durable: late confirmation receipt persists after page disposal',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'account-a',
      );
      final gate = Completer<void>();
      final api = _LostReceiptApi()
        ..loseConfirmation = false
        ..confirmationGate = gate;
      final first = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      await first.load();
      final confirming = first.confirmReady();
      while (api.attempts.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      first.dispose();
      gate.complete();
      await confirming;
      expect(store.pendingConfirmationId, 'task-1');
      final resumed = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      addTearDown(resumed.dispose);
      expect(await resumed.load(), isTrue);
      expect(api.attempts, hasLength(1));
    },
  );

  test(
    'durable: revision replay preserves instruction hunks etag and original version',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'account-a',
      );
      final api = _LostReceiptApi()..holdRevisionReceipt = true;
      final first = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      await first.load();
      first.toggleHunk('hunk-1');
      await first.reviseSelected('删除没有依据的结论');
      expect(store.pendingProposalCommands, hasLength(1));
      first.dispose();
      api.holdRevisionReceipt = false;
      final resumed = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      addTearDown(resumed.dispose);
      await resumed.load();
      expect(api.revisions, hasLength(3));
      expect(api.revisions.last.toJson(), api.revisions.first.toJson());
      expect(api.revisedProposalIds, hasLength(1));
      expect(store.pendingProposalCommands, isEmpty);
      expect(
        store.revisionEvents.where((event) => event.isUser).single.text,
        '删除没有依据的结论',
      );
      expect(store.revisionEvents.last.text, contains('v2'));
      expect(api.confirmationCalls, 0);
    },
  );
}

final class _FailingCommandSnapshotStore extends LocalDatabaseSnapshotStore {
  _FailingCommandSnapshotStore(File file) : super(file: file);
  bool failWrites = false;

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    if (failWrites) throw const FileSystemException('disk write failed');
    super.save(schemaVersion: schemaVersion, tables: tables);
  }
}

class _FakeDigitalTwinApi implements DigitalTwinApiPort {
  final List<String> rejectedIds = [];
  final List<String> confirmedIds = [];
  DigitalTwinImportSource? confirmedSource;
  bool omitConfirmationVersion = false;
  String confirmationState = 'report_ready';
  bool publishConfirmationProjection = true;
  String distillationStatus = 'succeeded';
  int distillationReads = 0;

  @override
  Future<DigitalTwinDistillationTask> getDistillationTask(String taskId) async {
    distillationReads += 1;
    return DigitalTwinDistillationTask(
      taskId: taskId,
      status: distillationStatus,
    );
  }

  @override
  Future<List<DocumentChangeProposalSnapshot>> getImportProposals(
    String noteId,
  ) async => snapshots.values
      .where((snapshot) => snapshot.proposal.sourceNoteIds.contains(noteId))
      .toList();

  @override
  Future<DocumentChangeProposalSnapshot> rejectProposal({
    required DocumentChangeProposalSnapshot proposal,
    required String idempotencyKey,
  }) async {
    rejectedIds.add(proposal.proposal.proposalId);
    snapshots.remove(proposal.proposal.proposalId);
    current = _current(snapshots.keys.toList());
    return proposal;
  }

  final Map<String, DocumentChangeProposalSnapshot> snapshots =
      <String, DocumentChangeProposalSnapshot>{'dcp-1': _proposal(1)};
  var current = _current(const <String>['dcp-1']);
  DigitalTwinCurrent? delayedCurrent;
  int? exposeDelayedCurrentAfterRead;
  int currentReads = 0;
  var versions = <DigitalTwinVersion>[_version()];
  Completer<void>? revisionGate;
  Completer<void>? confirmationGate;
  Completer<void>? firstConfirmationReceiptGate;
  bool comparisonAvailable = false;
  bool versionReadFails = false;
  int? failedDiffVersion;
  int? blockedDiffVersion;
  Completer<void>? diffGate;
  final diffVersionsRead = <int>[];
  bool loseRestoreResponse = false;
  bool partialRestoreFailure = false;
  Completer<void>? restoreGate;
  final restoreKeys = <String>[];
  List<DigitalTwinLogicalFile> previewFiles = const [];
  String? revisionFailureCode;
  bool revisionReturnsGenerating = false;
  int generatingProposalReadsBeforeReady = 0;
  bool confirmationThrowsAfterApply = false;
  int confirmationCalls = 0;
  int proposalReads = 0;
  String? proposalReadFailureCode;
  final List<String> revisedProposalIds = <String>[];
  List<DigitalTwinSelectedHunk> revisedHunks =
      const <DigitalTwinSelectedHunk>[];
  final Map<String, List<DigitalTwinSelectedHunk>> revisedHunksByProposal =
      <String, List<DigitalTwinSelectedHunk>>{};

  DocumentChangeProposalSnapshot get snapshot => snapshots['dcp-1']!;

  set snapshot(DocumentChangeProposalSnapshot value) {
    snapshots['dcp-1'] = value;
  }

  @override
  Future<DigitalTwinCurrent> getCurrent() async {
    currentReads += 1;
    final delayed = delayedCurrent;
    final exposeAfter = exposeDelayedCurrentAfterRead;
    if (delayed != null && exposeAfter != null && currentReads >= exposeAfter) {
      current = delayed;
    }
    return current;
  }

  @override
  Future<DigitalTwinSchedule> getSchedule() async => _schedule();

  @override
  Future<List<DigitalTwinVersion>> getVersions() async => versions;

  @override
  Future<DocumentChangeProposalSnapshot> getProposal(String proposalId) async {
    proposalReads += 1;
    final failureCode = proposalReadFailureCode;
    if (failureCode != null) throw DigitalTwinApiException(failureCode);
    final snapshot = snapshots[proposalId]!;
    if (snapshot.proposal.state == DocumentProposalState.generating) {
      if (generatingProposalReadsBeforeReady > 0) {
        generatingProposalReadsBeforeReady -= 1;
        return snapshot;
      }
      final ready = _proposal(
        snapshot.proposal.proposalVersion,
        id: proposalId,
      );
      snapshots[proposalId] = ready;
      return ready;
    }
    return snapshot;
  }

  @override
  Future<List<DigitalTwinProposalVersion>> getProposalVersions(
    String proposalId,
  ) async {
    final current = snapshots[proposalId]!;
    return <DigitalTwinProposalVersion>[
      for (
        var version = 1;
        version <= current.proposal.proposalVersion;
        version += 1
      )
        DigitalTwinProposalVersion(
          proposalId: proposalId,
          proposalVersion: version,
          baseHash: 'sha256:base',
          candidateHash: 'sha256:candidate',
          diffBundleId: 'diff-$version',
          createdAt: DateTime.utc(2026, 8, 29),
        ),
    ];
  }

  @override
  Future<DocumentProposalDiffPage> getProposalDiff({
    required String proposalId,
    required int proposalVersion,
    String? cursor,
  }) async {
    diffVersionsRead.add(proposalVersion);
    if (blockedDiffVersion == proposalVersion) await diffGate?.future;
    if (failedDiffVersion == proposalVersion) {
      throw const DigitalTwinApiException('DIFF_READ_FAILED');
    }
    final hunkId = proposalId == 'dcp-1' ? 'hunk-1' : 'hunk-2';
    return DocumentProposalDiffPage(
      proposalId: proposalId,
      proposalVersion: proposalVersion,
      summary: const DocumentProposalDiffSummary(
        hunks: 1,
        insertedLines: 1,
        deletedLines: 0,
        changedLines: 1,
        hasChanges: true,
      ),
      items: <DocumentProposalDiffHunk>[
        DocumentProposalDiffHunk(
          hunkId: hunkId,
          oldStart: 1,
          oldLines: 0,
          newStart: 1,
          newLines: 1,
          changes: <DocumentProposalDiffChange>[
            const DocumentProposalDiffChange(op: 'insert', text: 'Candidate\n'),
          ],
        ),
      ],
    );
  }

  @override
  Future<DocumentProposalCandidateChunk> getProposalCandidate({
    required String proposalId,
    required int proposalVersion,
    String? cursor,
  }) async => DocumentProposalCandidateChunk(
    proposalId: proposalId,
    proposalVersion: proposalVersion,
    candidateHash: 'sha256:candidate',
    offsetBytes: 0,
    text: '# Candidate',
  );

  @override
  Future<DocumentChangeProposalSnapshot> reviseProposal({
    required DocumentChangeProposalSnapshot proposal,
    required String instruction,
    required List<DigitalTwinSelectedHunk> selectedHunks,
    required String idempotencyKey,
  }) async {
    final proposalId = proposal.proposal.proposalId;
    await revisionGate?.future;
    revisedProposalIds.add(proposalId);
    revisedHunks = selectedHunks;
    revisedHunksByProposal[proposalId] = selectedHunks;
    final current = proposal.proposal.proposalVersion;
    final revised = revisionFailureCode == null
        ? _proposal(
            current + 1,
            id: proposalId,
            state: revisionReturnsGenerating
                ? DocumentProposalState.generating
                : DocumentProposalState.ready,
          )
        : _proposal(current, id: proposalId, failureCode: revisionFailureCode);
    snapshots[proposalId] = revised;
    return revised;
  }

  @override
  Future<DigitalTwinConfirmation> createConfirmation({
    required List<DocumentChangeProposalSnapshot> proposals,
    required String idempotencyKey,
    DigitalTwinImportSource? source,
  }) async {
    confirmationCalls += 1;
    final receiptGate = confirmationCalls == 1
        ? firstConfirmationReceiptGate
        : null;
    await confirmationGate?.future;
    confirmedSource = source;
    confirmedIds.addAll(
      proposals.map((snapshot) => snapshot.proposal.proposalId),
    );
    for (final snapshot in proposals) {
      snapshots[snapshot.proposal.proposalId] = _proposal(
        snapshot.proposal.proposalVersion,
        id: snapshot.proposal.proposalId,
        state: DocumentProposalState.applied,
        sourceNoteIds: snapshot.proposal.sourceNoteIds,
      );
    }
    final formal = _version(number: 1, id: 'dtv-1');
    current = _current(const <String>[], currentVersion: formal);
    versions = <DigitalTwinVersion>[_version(), formal];
    if (confirmationThrowsAfterApply) {
      throw StateError('confirmation response was lost after apply');
    }
    final report = DigitalTwinConfirmation(
      confirmationTaskId: 'task-1',
      state: 'report_ready',
      outcomes: const <DigitalTwinConfirmationOutcome>[
        DigitalTwinConfirmationOutcome(
          proposalId: 'dcp-1',
          proposalVersion: 2,
          state: DocumentProposalState.applied,
        ),
      ],
      appliedCount: 1,
      failedCount: 0,
      version: omitConfirmationVersion ? null : formal,
    );
    await receiptGate?.future;
    return report;
  }

  @override
  Future<DigitalTwinConfirmation> getConfirmation(
    String confirmationTaskId,
  ) async {
    if (publishConfirmationProjection &&
        confirmationState == 'report_ready' &&
        !omitConfirmationVersion) {
      final formal = _version(number: 1, id: 'dtv-1');
      current = _current(const [], currentVersion: formal);
      versions = [_version(), formal];
    }
    return DigitalTwinConfirmation(
      confirmationTaskId: confirmationTaskId,
      state: confirmationState,
      outcomes: const [],
      appliedCount: 1,
      failedCount: 0,
      version: omitConfirmationVersion
          ? null
          : _version(number: 1, id: 'dtv-1'),
    );
  }

  @override
  Future<DocumentChangeProposalSnapshot> regenerateProposal({
    required DocumentChangeProposalSnapshot proposal,
    required String instruction,
    required String idempotencyKey,
  }) async {
    final replacement = _proposal(
      1,
      id: 'dcp-replacement',
      sourceNoteIds: proposal.proposal.sourceNoteIds,
      hasChanges: true,
    );
    snapshots['dcp-replacement'] = replacement;
    return replacement;
  }

  @override
  Future<DigitalTwinSchedule> updateSchedule(
    DigitalTwinScheduleDraft draft, {
    required String idempotencyKey,
  }) async => _schedule();

  @override
  Future<DigitalTwinVersionDetail> getVersion(String versionId) async {
    if (versionReadFails) {
      throw const DigitalTwinApiException('SERVICE_BUSY');
    }
    return DigitalTwinVersionDetail(
      version:
          versions
              .where((version) => version.versionId == versionId)
              .firstOrNull ??
          _version(id: versionId),
      operationKey: 'history',
      rendererVersion: 'v1',
      profileCount: 0,
      hasPositioning: true,
      proposalResults: versionId == 'dtv-1'
          ? const [
              DigitalTwinConfirmationOutcome(
                proposalId: 'dcp-1',
                proposalVersion: 2,
                state: DocumentProposalState.applied,
              ),
            ]
          : const [],
    );
  }

  @override
  Future<List<DigitalTwinLogicalFile>> getPreview(String versionId) async =>
      previewFiles;

  @override
  Future<DigitalTwinVersionComparison> compareVersions({
    required String baseVersionId,
    required String versionId,
  }) async {
    if (!comparisonAvailable)
      throw const DigitalTwinApiException('SERVICE_BUSY');
    return DigitalTwinVersionComparison(
      baseVersion: versions.firstWhere(
        (version) => version.versionId == baseVersionId,
      ),
      version: versions.firstWhere((version) => version.versionId == versionId),
      files: [
        for (final file in previewFiles)
          DigitalTwinFileComparison(
            id: file.id,
            name: file.name,
            summary: const DocumentProposalDiffSummary(
              hunks: 1,
              insertedLines: 1,
              deletedLines: 0,
              changedLines: 1,
              hasChanges: true,
            ),
            hunks: const [
              DocumentProposalDiffHunk(
                hunkId: 'history-hunk',
                oldStart: 1,
                oldLines: 0,
                newStart: 1,
                newLines: 1,
                changes: [
                  DocumentProposalDiffChange(
                    op: 'insert',
                    text: '版本内保存的真实差分测试内容',
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }

  @override
  Future<Uint8List> downloadVersion(String versionId) async =>
      Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04]);

  @override
  Future<DigitalTwinRestore> restoreVersion(
    String versionId, {
    required String idempotencyKey,
  }) async {
    restoreKeys.add(idempotencyKey);
    await restoreGate?.future;
    snapshots['dcp-restore'] = _proposal(1, id: 'dcp-restore');
    current = _current(const <String>['dcp-restore']);
    if (loseRestoreResponse) {
      loseRestoreResponse = false;
      throw const DigitalTwinApiException('RESPONSE_LOST');
    }
    return DigitalTwinRestore(
      taskId: 'restore-task',
      versionId: versionId,
      state: partialRestoreFailure ? 'failed' : 'proposals_created',
      proposalIds: const <String>['dcp-restore'],
    );
  }
}

void _followUpAuditCases() {
  test(
    'second audit: external confirmation owns the journal without a local command',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'external-task',
      );
      final api = _FakeDigitalTwinApi();
      final controller = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await store.recordConfirmation('external-task', ['dcp-1']);
      expect(controller.hasPendingConfirmation, isTrue);
      expect(
        controller.captureConfirmationSelection()!.identity,
        'confirmation:external-task',
      );
      await expectLater(
        store.prepareConfirmation(
          DigitalTwinConfirmationCommand(
            idempotencyKey: 'unrelated-request',
            proposals: [_proposal(1)],
          ),
        ),
        throwsA(isA<DigitalTwinApiException>()),
      );
      expect(store.pendingConfirmationCommand, isNull);
      expect(await controller.load(), isTrue);
      expect(
        controller.state.confirmation!.confirmationTaskId,
        'external-task',
      );
      expect(api.confirmationCalls, 0);
    },
  );
  test(
    'second audit: delayed controller receipt cannot reactivate a completed confirmation',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'delayed-controller',
      );
      final gate = Completer<void>();
      final api = _FakeDigitalTwinApi()..firstConfirmationReceiptGate = gate;
      final accepted = <String>[];
      final controller = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
        onConfirmationAccepted: (id, proposals) async {
          accepted.add(id);
        },
      );
      addTearDown(controller.dispose);
      await controller.load();
      final first = controller.confirmReady();
      for (
        var attempt = 0;
        attempt < 20 && api.confirmationCalls == 0;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.confirmationCalls, 1);
      expect(await controller.load(), isTrue);
      expect(store.pendingConfirmationCommand, isNull);
      final next = DigitalTwinConfirmationCommand(
        idempotencyKey: 'next-request',
        proposals: [_proposal(3)],
      );
      await store.prepareConfirmation(next);
      await store.recordConfirmation(
        'next-task',
        next.proposalIds,
        idempotencyKey: next.idempotencyKey,
      );
      gate.complete();
      expect(await first, isFalse);
      expect(store.pendingConfirmationId, 'next-task');
      expect(store.pendingConfirmationCommand!.idempotencyKey, 'next-request');
      expect(accepted, ['task-1']);
    },
  );
  test(
    'second audit: late confirmation cannot overwrite or settle a newer command',
    () async {
      final database = AppDatabase();
      final store = DigitalTwinMaterialStore(
        database: database,
        scope: 'confirmation-race',
      );
      await store.save(
        DigitalTwinMaterial(
          id: 'material',
          referenceKind: 'note',
          referenceId: 'note',
          title: '版本证据',
          createdAt: DateTime.utc(2026),
          proposalIds: const {'user_profile': 'dcp-1'},
        ),
      );
      DigitalTwinConfirmation report(String task, int version) =>
          DigitalTwinConfirmation(
            confirmationTaskId: task,
            state: 'report_ready',
            appliedCount: 1,
            failedCount: 0,
            version: _version(number: version, id: 'dtv-$version'),
            outcomes: [
              DigitalTwinConfirmationOutcome(
                proposalId: 'dcp-1',
                proposalVersion: version,
                state: DocumentProposalState.applied,
              ),
            ],
          );
      final previous = DigitalTwinConfirmationCommand(
        idempotencyKey: 'previous',
        proposals: [_proposal(1)],
      );
      final next = DigitalTwinConfirmationCommand(
        idempotencyKey: 'next',
        proposals: [_proposal(2)],
      );
      await store.prepareConfirmation(previous);
      await store.recordConfirmation(
        'previous-task',
        previous.proposalIds,
        idempotencyKey: previous.idempotencyKey,
      );
      await store.recordConfirmationReport(report('previous-task', 1));
      await store.settleConfirmation('previous-task');
      await store.prepareConfirmation(next);
      expect(
        await store.recordConfirmation(
          'previous-task',
          previous.proposalIds,
          idempotencyKey: previous.idempotencyKey,
        ),
        isFalse,
      );
      expect(store.pendingConfirmationId, isNull);
      await store.recordConfirmation(
        'next-task',
        next.proposalIds,
        idempotencyKey: next.idempotencyKey,
      );
      await store.recordConfirmationReport(report('next-task', 2));
      expect(
        await store.recordConfirmation(
          'previous-task',
          previous.proposalIds,
          idempotencyKey: previous.idempotencyKey,
        ),
        isFalse,
      );
      expect(store.pendingConfirmationId, 'next-task');
      await store.recordConfirmationReport(
        report('previous-task', 1),
        updateCurrent: false,
      );
      await store.recordConfirmationReport(
        const DigitalTwinConfirmation(
          confirmationTaskId: 'previous-task',
          state: 'confirming',
          outcomes: [],
          appliedCount: 0,
          failedCount: 0,
        ),
        updateCurrent: false,
      );
      expect(store.lastReport!.confirmationTaskId, 'next-task');
      expect(store.read().single.versionId, 'dtv-2');
      expect(
        store.read().single.confirmedVersions.values,
        containsAll(['dtv-1', 'dtv-2']),
      );
      final archived = database.getRecord<LocalDatabaseRecord>(
        LocalTableName.materialIngestionDrafts,
        'digital-twin-operation:confirmation-race:report:previous-task',
      );
      expect(
        ((archived!['operation'] as Map)['report'] as Map)['state'],
        'report_ready',
      );
      await store.settleConfirmation('previous-task');
      expect(store.pendingConfirmationCommand!.idempotencyKey, 'next');
    },
  );
  for (final operation in ['select', 'inspect', 'retry']) {
    test(
      'second audit: superseded $operation details complete without UI exceptions',
      () async {
        final api = _FakeDigitalTwinApi()..snapshot = _proposal(2);
        final controller = DigitalTwinController(
          api,
          pollInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        await controller.load();
        if (operation == 'select') {
          api.snapshots['dcp-2'] = _proposal(1, id: 'dcp-2');
          api.current = _current(['dcp-1', 'dcp-2']);
          await controller.load();
        } else if (operation == 'retry') {
          api.failedDiffVersion = 1;
          await controller.inspectProposalVersion('dcp-1', 1);
          api.failedDiffVersion = null;
        }
        final gate = Completer<void>();
        api.blockedDiffVersion = 1;
        api.diffGate = gate;
        final priorReads = api.diffVersionsRead.length;
        final Future<void> reading = switch (operation) {
          'select' => controller.selectProposal('dcp-2'),
          'inspect' => controller.inspectProposalVersion('dcp-1', 1),
          _ => controller.retryProposalDetails('dcp-1'),
        };
        final completion = expectLater(reading, completes);
        for (
          var attempt = 0;
          attempt < 10 && api.diffVersionsRead.length == priorReads;
          attempt++
        ) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(api.diffVersionsRead.length, greaterThan(priorReads));
        api.blockedDiffVersion = null;
        api.snapshot = _proposal(3);
        expect(await controller.load(preferredProposalId: 'dcp-1'), isTrue);
        gate.complete();
        await completion;
        expect(controller.state.selectedReview!.visibleVersion, 3);
        expect(controller.state.errorCode, isNull);
      },
    );
  }
  testWidgets(
    'audit: unrelated old conversation cannot hide new candidate files',
    (tester) async {
      tester.view
        ..physicalSize = const Size(402, 874)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = DigitalTwinController(
        _FakeDigitalTwinApi(),
        initialRevisionEvents: const [
          DigitalTwinRevisionEvent(
            proposalId: 'old-candidate',
            text: '旧文件的对话',
            isUser: true,
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            digitalTwinControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3DigitalTwinPage()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('digital-twin-open-revision')),
      );
      await tester.pumpAndSettle();
      expect(
        find
            .byKey(const ValueKey('digital-twin-revision-file-experience'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(find.text('旧文件的对话'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'audit: history restore opens scoped review instead of only showing a toast',
    (tester) async {
      tester.view
        ..physicalSize = const Size(402, 874)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _FakeDigitalTwinApi()
        ..comparisonAvailable = true
        ..previewFiles = _current(const []).files;
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            digitalTwinControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3DigitalTwinPage()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('修订记录'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('digital-twin-history-dtv-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('版本操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('基于此版本生成恢复候选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成提案'));
      await tester.pumpAndSettle();
      expect(api.restoreKeys, hasLength(1));
      expect(
        find.byKey(const ValueKey('digital-twin-revision-surface')),
        findsOneWidget,
      );
      expect(controller.state.selectedProposalId, 'dcp-restore');
      expect(controller.hasIndependentReview, isTrue);
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      expect(controller.hasIndependentReview, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'audit: restore replays durable identity across restart and current changes',
    () async {
      final directory = await Directory.systemTemp.createTemp('twin-restore-');
      addTearDown(() => directory.delete(recursive: true));
      final persistence = LocalDatabaseSnapshotStore(
        file: File('${directory.path}/restore.sqlite'),
        backend: LocalDatabaseSnapshotBackend.sqlite,
      );
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(snapshotStore: persistence),
        scope: 'restore-owner',
      );
      final api = _FakeDigitalTwinApi()..loseRestoreResponse = true;
      final first = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      await first.load();
      expect(await first.restoreVersion('dtv-0'), isFalse);
      expect(first.hasPendingRestore, isTrue);
      expect(first.captureConfirmationSelection(), isNull);
      expect(await first.reviseSelected('不得覆盖恢复请求'), isFalse);
      expect(await first.rejectSelectedProposal(), isFalse);
      final frozen = store.pendingRestoreCommand!.idempotencyKey;
      first.dispose();
      api.current = _current([
        'dcp-1',
        'dcp-restore',
      ], currentVersion: _version(number: 4, id: 'dtv-4'));
      final recoveredStore = DigitalTwinMaterialStore(
        database: AppDatabase(snapshotStore: persistence),
        scope: 'restore-owner',
      );
      final recovered = DigitalTwinController(
        api,
        recoveryStore: recoveredStore,
        pollInterval: Duration.zero,
      );
      addTearDown(recovered.dispose);
      expect(await recovered.load(), isTrue);
      expect(api.restoreKeys, [frozen, frozen]);
      expect(recovered.hasPendingRestore, isFalse);
      expect(recovered.lastRestore!.proposalIds, ['dcp-restore']);
      expect(recovered.state.selectedProposalId, 'dcp-restore');
      expect(
        DigitalTwinMaterialStore(
          database: AppDatabase(snapshotStore: persistence),
          scope: 'another-owner',
        ).lastRestore,
        isNull,
      );
    },
  );

  test(
    'audit: restore preserves late receipt after disposal and partial failure is not success',
    () async {
      final store = DigitalTwinMaterialStore(
        database: AppDatabase(),
        scope: 'late-restore',
      );
      final gate = Completer<void>();
      final api = _FakeDigitalTwinApi()
        ..restoreGate = gate
        ..partialRestoreFailure = true;
      final first = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      await first.load();
      final request = first.restoreVersion('dtv-0');
      while (api.restoreKeys.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      first.dispose();
      gate.complete();
      expect(await request, isFalse);
      expect(store.pendingRestoreCommand!.receipt!.proposalIds, [
        'dcp-restore',
      ]);
      final recovered = DigitalTwinController(
        api,
        recoveryStore: store,
        pollInterval: Duration.zero,
      );
      addTearDown(recovered.dispose);
      expect(await recovered.restoreVersion('dtv-0'), isFalse);
      expect(api.restoreKeys, hasLength(1));
      expect(recovered.state.errorCode, 'DIGITAL_TWIN_RESTORE_PARTIAL');
      expect(recovered.hasPendingRestore, isFalse);
      expect(recovered.state.selectedProposalId, 'dcp-restore');
    },
  );

  test(
    'audit: restore cannot replace a frozen confirmation or revision',
    () async {
      for (final confirming in [true, false]) {
        final store = DigitalTwinMaterialStore(
          database: AppDatabase(),
          scope: 'exclusive-$confirming',
        );
        final api = _FakeDigitalTwinApi();
        final controller = DigitalTwinController(
          api,
          recoveryStore: store,
          pollInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        await controller.load();
        if (confirming) {
          await store.prepareConfirmation(
            DigitalTwinConfirmationCommand(
              idempotencyKey: 'confirm-frozen',
              proposals: [_proposal(1)],
            ),
          );
        } else {
          await store.prepareProposalCommands([
            DigitalTwinProposalCommand(
              idempotencyKey: 'revise-frozen',
              operation: DigitalTwinProposalOperation.revise,
              proposal: _proposal(1),
              instruction: '保留这句话',
            ),
          ]);
        }
        expect(controller.canRestoreVersion, isFalse);
        expect(await controller.restoreVersion('dtv-0'), isFalse);
        expect(api.restoreKeys, isEmpty);
        expect(
          controller.state.errorCode,
          'DIGITAL_TWIN_OPERATION_IN_PROGRESS',
        );
      }
    },
  );

  test(
    'audit: refresh and historical retry preserve current citations and exact version',
    () async {
      final api = _FakeDigitalTwinApi()..snapshot = _proposal(2);
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.toggleHunk('hunk-1');
      await controller.load();
      expect(controller.state.selectedReview!.selectedHunkIds, {'hunk-1'});
      api.failedDiffVersion = 1;
      await controller.inspectProposalVersion('dcp-1', 1);
      expect(controller.state.selectedReview!.requestedVersion, 1);
      expect(controller.state.canRevise, isFalse);
      expect(controller.state.canRejectSelected, isFalse);
      expect(controller.captureConfirmationSelection(), isNull);
      controller.toggleHunk('hunk-1');
      expect(controller.state.selectedReview!.selectedHunkIds, {'hunk-1'});
      api.failedDiffVersion = null;
      await controller.retryProposalDetails('dcp-1');
      expect(api.diffVersionsRead.last, 1);
      expect(controller.state.selectedReview!.visibleVersion, 1);
      expect(controller.state.selectedReview!.detailsUsable, isTrue);
      expect(controller.captureConfirmationSelection(), isNull);
      await controller.inspectProposalVersion('dcp-1', 2);
      expect(controller.state.canRevise, isTrue);
      expect(controller.state.selectedReview!.selectedHunkIds, {'hunk-1'});
    },
  );

  test(
    'audit: overview releases material scope and batches exactly twenty reviewed candidates',
    () async {
      final api = _FakeDigitalTwinApi();
      for (var index = 2; index <= 21; index++) {
        api.snapshots['dcp-$index'] = _proposal(1, id: 'dcp-$index');
      }
      api.current = _current(api.snapshots.keys.toList());
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load(reviewProposalIds: ['dcp-1']);
      expect(controller.state.reviews, hasLength(1));
      expect(await controller.openOverview(), isTrue);
      expect(controller.hasIndependentReview, isFalse);
      expect(controller.state.reviews, hasLength(21));
      await controller.prepareReviewDetails();
      expect(controller.state.readyProposalCount, 21);
      expect(
        controller.captureConfirmationSelection()!.proposals,
        hasLength(digitalTwinConfirmationBatchLimit),
      );
    },
  );

  test(
    'audit: visible sheet owns polling after parent deactivation and releases it',
    () async {
      final api = _FakeDigitalTwinApi()..revisionReturnsGenerating = true;
      final orchestrator = TaskOrchestrator();
      final metrics = RuntimeActivityMetrics();
      final controller = DigitalTwinController(
        api,
        pollInterval: const Duration(milliseconds: 1),
        maxPollAttempts: 2,
        taskOrchestrator: orchestrator,
        activityMetrics: metrics,
      );
      addTearDown(() {
        controller.dispose();
        orchestrator.dispose();
        metrics.dispose();
      });
      await controller.load();
      final sheet = Object();
      controller.setPollingRouteActive(true, owner: sheet);
      controller.setPollingRouteActive(false);
      controller.toggleHunk('hunk-1');
      expect(
        await controller
            .reviseSelected('弹窗内继续生成')
            .timeout(const Duration(seconds: 1)),
        isTrue,
      );
      controller.setPollingRouteActive(false, owner: sheet);
      final waiting = controller.reviseSelected('后台暂停');
      await Future<void>.delayed(Duration.zero);
      final reads = api.proposalReads;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(api.proposalReads, reads);
      controller.setPollingRouteActive(true, owner: sheet);
      expect(await waiting.timeout(const Duration(seconds: 1)), isTrue);
      controller.setPollingRouteActive(false, owner: sheet);
      expect(metrics.current.activePollers, 0);
    },
  );

  test(
    'audit: updated badge requires a settled receipt for the exact candidate version',
    () async {
      final api = _FakeDigitalTwinApi()
        ..revisionFailureCode = 'AGENT_UNAVAILABLE';
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(
        controller.hasRevisionEvidence(controller.state.selectedReview!),
        isFalse,
      );
      await controller.reviseSelected('修改失败不能显示已更新');
      expect(
        controller.hasRevisionEvidence(controller.state.selectedReview!),
        isFalse,
      );
      api.revisionFailureCode = null;
      await controller.reviseSelected('本次成功修改');
      expect(
        controller.hasRevisionEvidence(controller.state.selectedReview!),
        isTrue,
      );
      await controller.inspectProposalVersion('dcp-1', 1);
      expect(
        controller.hasRevisionEvidence(controller.state.selectedReview!),
        isFalse,
      );
    },
  );
}

DigitalTwinCurrent _current(
  List<String> pendingProposalIds, {
  DigitalTwinVersion? currentVersion,
  bool positioningExists = true,
  bool positioningOwnsProposals = false,
  String positioningMarkdown = '''---
lastUpdated: 2026-08-29T00:00:00Z
---
# 基础定位报告

正式数字孪生定位正文。''',
  String? workspaceState,
}) => DigitalTwinCurrent(
  workspaceId: 'workspace-1',
  agentProfileId: digitalTwinAgentProfileId,
  state:
      workspaceState ??
      (pendingProposalIds.isEmpty ? 'ready' : 'pending_review'),
  level: const DigitalTwinLevel(
    value: 1,
    name: 'Initial grounding',
    completionPercent: 20,
    scoringModel: 'positioning.v1',
  ),
  pendingReviewCount: pendingProposalIds.length,
  pendingProposalCount: pendingProposalIds.length,
  files: <DigitalTwinLogicalFile>[
    DigitalTwinLogicalFile(
      id: 'social_positioning',
      name: '社媒定位',
      exists: positioningExists,
      markdown: positioningMarkdown,
      conclusions: const <DigitalTwinConclusion>[],
      pendingCount: positioningOwnsProposals ? pendingProposalIds.length : 0,
      pendingProposalIds: positioningOwnsProposals
          ? pendingProposalIds
          : const <String>[],
    ),
    if (!positioningOwnsProposals)
      DigitalTwinLogicalFile(
        id: 'experience',
        name: '经历',
        exists: true,
        markdown: '# 经历',
        conclusions: const <DigitalTwinConclusion>[],
        pendingCount: pendingProposalIds.length,
        pendingProposalIds: pendingProposalIds,
      ),
  ],
  currentVersion: currentVersion ?? _version(),
  updatedAt: DateTime.utc(2026, 8, 29),
);

DocumentChangeProposalSnapshot _proposal(
  int version, {
  String id = 'dcp-1',
  String? failureCode,
  DocumentProposalState state = DocumentProposalState.ready,
  Set<String> sourceNoteIds = const {},
  bool? hasChanges,
  String ownerId = 'positioning.md',
}) => DocumentChangeProposalSnapshot(
  proposal: DocumentChangeProposal(
    proposalId: id,
    proposalVersion: version,
    rowVersion: version,
    state: state,
    ownerKind: 'workspace_standard_file',
    noteId: ownerId,
    rawPartRevisionId: 'part-1',
    candidateAvailable: true,
    sourceNoteIds: sourceNoteIds,
    hasChanges: hasChanges,
    failureCode: failureCode,
  ),
  etag: '"dcp:$id:$version"',
);

DigitalTwinVersion _version({int number = 0, String id = 'dtv-0'}) =>
    DigitalTwinVersion(
      versionId: id,
      versionNumber: number,
      label: 'v$number',
      workspaceVersion: 1,
      completionPercent: 20,
      scoringModel: 'positioning.v1',
      createdAt: DateTime.utc(2026, 8, 29),
    );

DigitalTwinSchedule _schedule() => const DigitalTwinSchedule(
  enabled: false,
  intervalDays: 7,
  preferredLocalTime: '09:00',
  timezone: 'Asia/Shanghai',
  instruction: 'Review recent material.',
  sourceScope: 'digital_twin_and_recent_workspace_refs',
  version: 0,
);

void _recoveryCases() {
  const material = DigitalTwinImportSource(
    importTaskId: 'import-1',
    taskId: 'distill-1',
    resourceId: 'resource-1',
    noteId: 'note-1',
    title: 'Meeting',
  );

  test(
    'recovery: historical inspection cannot confirm current candidate',
    () async {
      final api = _FakeDigitalTwinApi()..snapshots['dcp-1'] = _proposal(2);
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.inspectProposalVersion('dcp-1', 1);
      expect(controller.state.readyProposalCount, 0);
      expect(await controller.confirmReady(), isFalse);
      expect(api.confirmationCalls, 0);
    },
  );

  test('recovery: frozen confirmation refuses an added candidate', () async {
    final api = _FakeDigitalTwinApi()
      ..snapshots['dcp-1'] = _proposal(
        1,
        sourceNoteIds: {'note-1'},
        hasChanges: true,
      );
    final controller = DigitalTwinController(api, pollInterval: Duration.zero);
    addTearDown(controller.dispose);
    await controller.load(importSource: material);
    final selection = controller.captureConfirmationSelection()!;
    api.snapshots['new'] = _proposal(
      1,
      id: 'new',
      sourceNoteIds: {'note-1'},
      hasChanges: true,
    );
    await controller.load();
    expect(await controller.confirmReady(selection: selection), isFalse);
    expect(api.confirmationCalls, 0);
  });

  test('recovery: server version drift is rejected before mutation', () async {
    final api = _FakeDigitalTwinApi();
    final controller = DigitalTwinController(api, pollInterval: Duration.zero);
    addTearDown(controller.dispose);
    await controller.load();
    final selection = controller.captureConfirmationSelection()!;
    api.snapshots['dcp-1'] = _proposal(2);
    expect(await controller.confirmReady(selection: selection), isFalse);
    expect(api.confirmationCalls, 0);
    expect(
      controller.state.errorCode,
      'DIGITAL_TWIN_CONFIRMATION_SELECTION_CHANGED',
    );
  });

  test(
    'recovery: schedule and history preserve material observation',
    () async {
      final api = _FakeDigitalTwinApi()..distillationStatus = 'running';
      final orchestrator = TaskOrchestrator();
      final metrics = RuntimeActivityMetrics();
      final controller = DigitalTwinController(
        api,
        taskOrchestrator: orchestrator,
        activityMetrics: metrics,
      );
      addTearDown(() {
        controller.dispose();
        orchestrator.dispose();
      });
      await controller.load(importSource: material);
      expect(metrics.current.activePollers, greaterThan(0));
      expect(
        await controller.saveSchedule(
          const DigitalTwinScheduleDraft(
            enabled: true,
            intervalDays: 7,
            preferredLocalTime: '09:00',
            timezone: 'Asia/Shanghai',
            instruction: 'Weekly update',
          ),
        ),
        isTrue,
      );
      expect(controller.importWaiting, isTrue);
      expect(metrics.current.activePollers, greaterThan(0));
      expect(await controller.inspectVersion('dtv-0'), isTrue);
      expect(metrics.current.activePollers, greaterThan(0));
    },
  );

  test(
    'recovery: material history restore has an independent review scope',
    () async {
      final api = _FakeDigitalTwinApi()
        ..snapshots['dcp-1'] = _proposal(
          1,
          sourceNoteIds: {'note-1'},
          hasChanges: true,
        );
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load(importSource: material);
      expect(await controller.restoreVersion('dtv-0'), isTrue);
      expect(controller.importSource, isNull);
      expect(controller.hasIndependentReview, isTrue);
      expect(
        controller.state.reviews.map(
          (review) => review.snapshot.proposal.proposalId,
        ),
        ['dcp-restore'],
      );
      await controller.load();
      expect(controller.state.selectedProposalId, 'dcp-restore');
    },
  );

  test(
    'recovery: confirmation read reconciles formal version and history',
    () async {
      final api = _FakeDigitalTwinApi();
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      expect(
        await controller.load(
          importSource: const DigitalTwinImportSource(
            importTaskId: 'import-1',
            taskId: 'distill-1',
            resourceId: 'resource-1',
            noteId: 'note-1',
            title: 'Meeting',
            confirmationTaskId: 'task-1',
          ),
        ),
        isTrue,
      );
      expect(controller.state.current?.currentVersion?.versionId, 'dtv-1');
      expect(controller.state.versions.last.versionId, 'dtv-1');
      expect(api.confirmationCalls, 0);
    },
  );

  test(
    'recovery: lagging projection preserves report and continuation identity',
    () async {
      final api = _FakeDigitalTwinApi()..publishConfirmationProjection = false;
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      expect(
        await controller.load(
          importSource: const DigitalTwinImportSource(
            importTaskId: 'import-1',
            taskId: 'distill-1',
            resourceId: 'resource-1',
            noteId: 'note-1',
            title: 'Meeting',
            confirmationTaskId: 'task-1',
          ),
        ),
        isFalse,
      );
      expect(controller.state.errorCode, 'DIGITAL_TWIN_PROJECTION_PENDING');
      expect(controller.state.confirmation?.version?.versionId, 'dtv-1');
      api.publishConfirmationProjection = true;
      expect(await controller.confirmReady(), isTrue);
      expect(api.confirmationCalls, 0);
    },
  );

  test(
    'recovery: changed candidate can be declined without confirmation',
    () async {
      final api = _FakeDigitalTwinApi()
        ..snapshots['dcp-1'] = _proposal(1, hasChanges: true);
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(await controller.rejectSelectedProposal(), isTrue);
      expect(api.rejectedIds, ['dcp-1']);
      expect(api.confirmationCalls, 0);
    },
  );

  test(
    'recovery: failed candidate rebuild remains in material lineage',
    () async {
      final api = _FakeDigitalTwinApi()
        ..snapshots['dcp-1'] = _proposal(
          1,
          state: DocumentProposalState.generationFailed,
          sourceNoteIds: {'note-1'},
        );
      final controller = DigitalTwinController(
        api,
        pollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.load(importSource: material);
      expect(controller.state.canRegenerateSelected, isTrue);
      expect(
        await controller.regenerateSelected('Use only the source facts'),
        isTrue,
      );
      expect(controller.state.selectedProposalId, 'dcp-replacement');
      expect(controller.state.selectedReview?.snapshot.proposal.sourceNoteIds, {
        'note-1',
      });
      expect(api.confirmationCalls, 0);
    },
  );
}
