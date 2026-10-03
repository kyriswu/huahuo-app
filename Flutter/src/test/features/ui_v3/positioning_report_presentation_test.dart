import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/onboarding/application/initial_positioning_task_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/positioning_report_presentation.dart';

void main() {
  group('reducePositioningReportPresentation', () {
    test('readable Markdown wins over every local and server phase', () {
      for (final taskStatus in InitialPositioningTaskStatus.values) {
        for (final serverPhase in InitialPositioningServerPhase.values) {
          final state = reducePositioningReportPresentation(
            markdown: '  # 正式定位报告  ',
            taskStatus: taskStatus,
            serverPhase: serverPhase,
            checking: true,
          );

          expect(
            state,
            PositioningReportPresentationState.ready,
            reason: '$taskStatus / $serverPhase',
          );
          expect(state.showReport, isTrue);
          expect(state.showGenerationProgress, isFalse);
        }
      }
    });

    test('only active local tasks generate while the report is absent', () {
      const active = <InitialPositioningTaskStatus>{
        InitialPositioningTaskStatus.registering,
        InitialPositioningTaskStatus.running,
        InitialPositioningTaskStatus.finalizing,
      };

      for (final taskStatus in InitialPositioningTaskStatus.values) {
        final state = reducePositioningReportPresentation(
          markdown: ' \n ',
          taskStatus: taskStatus,
        );

        expect(
          state.showGenerationProgress,
          active.contains(taskStatus),
          reason: '$taskStatus resolved to $state',
        );
      }
    });

    test(
      'active server attempts generate only when the local task is idle',
      () {
        const expected =
            <InitialPositioningServerPhase, PositioningReportPresentationState>{
              InitialPositioningServerPhase.notStarted:
                  PositioningReportPresentationState.notStarted,
              InitialPositioningServerPhase.queued:
                  PositioningReportPresentationState.generating,
              InitialPositioningServerPhase.running:
                  PositioningReportPresentationState.generating,
              InitialPositioningServerPhase.finalizing:
                  PositioningReportPresentationState.generating,
              InitialPositioningServerPhase.completed:
                  PositioningReportPresentationState.reportUnavailable,
              InitialPositioningServerPhase.failed:
                  PositioningReportPresentationState.failed,
              InitialPositioningServerPhase.unavailable:
                  PositioningReportPresentationState.unavailable,
            };

        for (final entry in expected.entries) {
          expect(
            reducePositioningReportPresentation(
              markdown: '',
              taskStatus: InitialPositioningTaskStatus.idle,
              serverPhase: entry.key,
            ),
            entry.value,
            reason: '${entry.key}',
          );
        }
      },
    );

    test('completed without a report is retryable and never generating', () {
      for (final state in <PositioningReportPresentationState>[
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.succeeded,
        ),
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.idle,
          serverPhase: InitialPositioningServerPhase.completed,
        ),
      ]) {
        expect(state, PositioningReportPresentationState.reportUnavailable);
        expect(state.showGenerationProgress, isFalse);
        expect(state.canRetryReportRead, isTrue);
      }
    });

    test('server terminal state overrides stale local activity', () {
      expect(
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.running,
          serverPhase: InitialPositioningServerPhase.completed,
        ),
        PositioningReportPresentationState.reportUnavailable,
      );
      expect(
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.finalizing,
          serverPhase: InitialPositioningServerPhase.failed,
        ),
        PositioningReportPresentationState.failed,
      );
      expect(
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.running,
          serverPhase: InitialPositioningServerPhase.unavailable,
        ),
        PositioningReportPresentationState.unavailable,
      );
      expect(
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.succeeded,
          serverPhase: InitialPositioningServerPhase.unavailable,
        ),
        PositioningReportPresentationState.reportUnavailable,
      );
    });

    test('checking is distinct and cannot mask known local task states', () {
      expect(
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.idle,
          checking: true,
        ),
        PositioningReportPresentationState.checking,
      );
      expect(
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.running,
          checking: true,
        ),
        PositioningReportPresentationState.generating,
      );
      expect(
        reducePositioningReportPresentation(
          markdown: '',
          taskStatus: InitialPositioningTaskStatus.failed,
          checking: true,
        ),
        PositioningReportPresentationState.failed,
      );
    });

    test('idle, failed, and unavailable remain separate non-active states', () {
      final notStarted = reducePositioningReportPresentation(
        markdown: '',
        taskStatus: InitialPositioningTaskStatus.idle,
      );
      final failed = reducePositioningReportPresentation(
        markdown: '',
        taskStatus: InitialPositioningTaskStatus.failed,
      );
      final unavailable = reducePositioningReportPresentation(
        markdown: '',
        taskStatus: InitialPositioningTaskStatus.idle,
        serverPhase: InitialPositioningServerPhase.unavailable,
      );

      expect(notStarted, PositioningReportPresentationState.notStarted);
      expect(failed, PositioningReportPresentationState.failed);
      expect(unavailable, PositioningReportPresentationState.unavailable);
      expect(
        [
          notStarted,
          failed,
          unavailable,
        ].every((state) => !state.showGenerationProgress),
        isTrue,
      );
      expect(unavailable.canRetryReportRead, isTrue);
    });
  });
}
