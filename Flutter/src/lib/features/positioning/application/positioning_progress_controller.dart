import 'package:flutter/foundation.dart';

import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../domain/positioning_progress_repository.dart';

/// Owns the page's coverage reader, not the durable server generation task.
final class PositioningProgressController extends ChangeNotifier {
  PositioningProgressController({
    required PositioningProgressRepository? repository,
    required TaskOrchestrator orchestrator,
    required String userScope,
    required String? workspaceId,
    required bool Function() isCurrentScope,
    RuntimeActivityMetrics? activityMetrics,
  }) : _repository = repository,
       _isCurrentScope = isCurrentScope {
    if (isCurrentScope()) _coverage = repository?.readCached();
    _poller = OrchestratedPoller(
      orchestrator: orchestrator,
      // performance-rfc: unified-network-pollers
      spec: TaskSpec(
        key: 'positioning:progress:$userScope:$workspaceId',
        owner: 'positioning-report-progress',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 15),
      ),
      interval: const Duration(seconds: 3),
      maxBackoff: const Duration(seconds: 30),
      activityMetrics: activityMetrics,
      poll: _read,
    );
  }

  final PositioningProgressRepository? _repository;
  final bool Function() _isCurrentScope;
  late final OrchestratedPoller _poller;
  PositioningCoverage? _coverage;
  bool _visible = false;
  bool _taskActive = false;
  bool _disposed = false;
  int _generation = 0;

  PositioningCoverage? get coverage => _coverage;

  bool get _canPoll =>
      !_disposed &&
      _visible &&
      _taskActive &&
      _repository != null &&
      _isCurrentScope();

  void setActivity({required bool visible, required bool taskActive}) {
    if (_disposed) return;
    _visible = visible;
    _taskActive = taskActive;
    if (_canPoll) {
      _poller.start();
    } else {
      _generation++;
      _poller.stop();
    }
  }

  void refresh() {
    if (_disposed) return;
    _generation++;
    _poller.stop();
    if (_canPoll) _poller.start();
  }

  Future<bool> _read(AppTaskCancellationToken token) async {
    if (!_canPoll) return false;
    final generation = _generation;
    bool isCurrent() =>
        !token.isCancelled && generation == _generation && _canPoll;
    try {
      final coverage = await _repository!.refresh(isCurrent: isCurrent);
      if (isCurrent() && coverage != null) {
        _coverage = coverage;
        notifyListeners();
      }
    } catch (_) {
      if (isCurrent()) {
        _coverage = _coverage?.asStale();
        notifyListeners();
        rethrow;
      }
    }
    return _canPoll;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _poller.dispose();
    super.dispose();
  }
}
