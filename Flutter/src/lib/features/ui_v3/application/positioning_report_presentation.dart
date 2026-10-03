import '../../onboarding/application/initial_positioning_task_coordinator.dart';

enum PositioningReportPresentationState {
  ready,
  checking,
  generating,
  reportUnavailable,
  failed,
  unavailable,
  notStarted;

  bool get showReport => this == PositioningReportPresentationState.ready;

  bool get showGenerationProgress =>
      this == PositioningReportPresentationState.generating;

  bool get canRetryReportRead =>
      this == PositioningReportPresentationState.reportUnavailable ||
      this == PositioningReportPresentationState.unavailable;
}

PositioningReportPresentationState reducePositioningReportPresentation({
  required String markdown,
  required InitialPositioningTaskStatus taskStatus,
  InitialPositioningServerPhase? serverPhase,
  bool checking = false,
}) {
  if (markdown.trim().isNotEmpty) {
    return PositioningReportPresentationState.ready;
  }

  if (serverPhase == InitialPositioningServerPhase.completed) {
    return PositioningReportPresentationState.reportUnavailable;
  }
  if (serverPhase == InitialPositioningServerPhase.failed) {
    return PositioningReportPresentationState.failed;
  }
  if (serverPhase == InitialPositioningServerPhase.unavailable) {
    return switch (taskStatus) {
      InitialPositioningTaskStatus.succeeded =>
        PositioningReportPresentationState.reportUnavailable,
      InitialPositioningTaskStatus.failed =>
        PositioningReportPresentationState.failed,
      InitialPositioningTaskStatus.idle ||
      InitialPositioningTaskStatus.registering ||
      InitialPositioningTaskStatus.running ||
      InitialPositioningTaskStatus.finalizing =>
        PositioningReportPresentationState.unavailable,
    };
  }

  switch (taskStatus) {
    case InitialPositioningTaskStatus.registering:
    case InitialPositioningTaskStatus.running:
    case InitialPositioningTaskStatus.finalizing:
      return PositioningReportPresentationState.generating;
    case InitialPositioningTaskStatus.succeeded:
      return PositioningReportPresentationState.reportUnavailable;
    case InitialPositioningTaskStatus.failed:
      return PositioningReportPresentationState.failed;
    case InitialPositioningTaskStatus.idle:
      break;
  }

  if (checking) return PositioningReportPresentationState.checking;

  return switch (serverPhase) {
    InitialPositioningServerPhase.queued ||
    InitialPositioningServerPhase.running ||
    InitialPositioningServerPhase.finalizing =>
      PositioningReportPresentationState.generating,
    InitialPositioningServerPhase.completed =>
      PositioningReportPresentationState.reportUnavailable,
    InitialPositioningServerPhase.failed =>
      PositioningReportPresentationState.failed,
    InitialPositioningServerPhase.unavailable =>
      PositioningReportPresentationState.unavailable,
    InitialPositioningServerPhase.notStarted ||
    null => PositioningReportPresentationState.notStarted,
  };
}
