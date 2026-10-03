import 'package:flutter/foundation.dart';

enum TaskPriority {
  userBlocking,
  userVisible,
  foregroundDeferred,
  backgroundOpportunistic,
}

enum TaskResource { network, database, cpu, media }

sealed class AppTaskState {
  const AppTaskState();

  bool get isTerminal => switch (this) {
    AppTaskSucceeded() || AppTaskFailed() || AppTaskCancelled() => true,
    _ => false,
  };
}

final class AppTaskQueued extends AppTaskState {
  const AppTaskQueued();
}

final class AppTaskRunning extends AppTaskState {
  const AppTaskRunning({this.progress})
    : assert(progress == null || progress >= 0 && progress <= 1);

  final double? progress;
}

final class AppTaskWaitingRemote extends AppTaskState {
  const AppTaskWaitingRemote();
}

final class AppTaskPaused extends AppTaskState {
  const AppTaskPaused();
}

final class AppTaskSucceeded extends AppTaskState {
  const AppTaskSucceeded();
}

final class AppTaskFailed extends AppTaskState {
  const AppTaskFailed({required this.errorCategory, required this.retryable});

  final String errorCategory;
  final bool retryable;
}

final class AppTaskCancelled extends AppTaskState {
  const AppTaskCancelled();
}

@immutable
final class TaskSpec {
  TaskSpec({
    required String key,
    required String owner,
    required this.priority,
    Set<TaskResource> resources = const <TaskResource>{},
    this.foregroundOnly = false,
    this.replaceExisting = false,
    this.retryable = false,
    this.deadline,
  }) : key = _requiredLabel(key, 'key'),
       owner = _requiredLabel(owner, 'owner'),
       resources = Set<TaskResource>.unmodifiable(resources);

  final String key;
  final String owner;
  final TaskPriority priority;
  final Set<TaskResource> resources;
  final bool foregroundOnly;
  final bool replaceExisting;
  final bool retryable;
  final Duration? deadline;
}

@immutable
final class AppTaskProjection {
  const AppTaskProjection({required this.spec, required this.state});

  final TaskSpec spec;
  final AppTaskState state;
}

final class AppTaskCancelledException implements Exception {
  const AppTaskCancelledException(this.reason);

  final String reason;

  @override
  String toString() => 'AppTaskCancelledException($reason)';
}

@immutable
final class TaskOrchestratorSnapshot {
  TaskOrchestratorSnapshot({
    required this.queued,
    required this.running,
    required this.cancelled,
    required this.completed,
    required Iterable<AppTaskProjection> projections,
  }) : projections = List<AppTaskProjection>.unmodifiable(projections);

  final int queued;
  final int running;
  final int cancelled;
  final int completed;
  final List<AppTaskProjection> projections;
}

String _requiredLabel(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}
