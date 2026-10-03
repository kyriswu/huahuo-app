import 'dart:async';
import 'dart:math' as math;

import '../performance/runtime_activity_metrics.dart';
import 'task_orchestrator.dart';

typedef OrchestratedPollCallback =
    FutureOr<bool> Function(AppTaskCancellationToken token);

/// Repeatedly schedules one keyed task without retaining a resource permit
/// while waiting between attempts.
final class OrchestratedPoller {
  OrchestratedPoller({
    required TaskOrchestrator orchestrator,
    required TaskSpec spec,
    required Duration interval,
    required OrchestratedPollCallback poll,
    Duration maxBackoff = const Duration(seconds: 30),
    double jitter = .15,
    double Function()? randomDouble,
    RuntimeActivityMetrics? activityMetrics,
    String? metricsOwner,
  }) : _orchestrator = orchestrator,
       _spec = spec,
       _interval = interval,
       _poll = poll,
       _maxBackoff = maxBackoff,
       _jitter = jitter,
       _randomDouble = randomDouble ?? _defaultRandomDouble,
       _activityMetrics = activityMetrics,
       _metricsOwner = metricsOwner ?? spec.owner {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
    if (maxBackoff < interval) {
      throw ArgumentError.value(
        maxBackoff,
        'maxBackoff',
        'must not be shorter than interval',
      );
    }
    if (jitter < 0 || jitter > 1) {
      throw ArgumentError.value(jitter, 'jitter', 'must be between 0 and 1');
    }
    if (spec.deadline == null || spec.deadline! <= Duration.zero) {
      throw ArgumentError.value(
        spec.deadline,
        'spec.deadline',
        'poll attempts require a positive deadline',
      );
    }
    if (!spec.retryable) {
      throw ArgumentError.value(
        spec.retryable,
        'spec.retryable',
        'poll attempts must declare retryable: true',
      );
    }
    if (!spec.replaceExisting) {
      throw ArgumentError.value(
        spec.replaceExisting,
        'spec.replaceExisting',
        'poll attempts must declare replaceExisting: true',
      );
    }
    _orchestrator.addListener(_handleOrchestratorChanged);
  }

  final TaskOrchestrator _orchestrator;
  final TaskSpec _spec;
  final Duration _interval;
  final OrchestratedPollCallback _poll;
  final Duration _maxBackoff;
  final double _jitter;
  final double Function() _randomDouble;
  final RuntimeActivityMetrics? _activityMetrics;
  final String _metricsOwner;

  Timer? _timer;
  var _generation = 0;
  var _consecutiveFailures = 0;
  var _active = false;
  var _suspended = false;
  var _disposed = false;

  bool get isRunning => _active && !_suspended && !_disposed;

  void start({bool immediate = true}) {
    if (_disposed) throw StateError('OrchestratedPoller is disposed');
    if (_active) return;
    _active = true;
    _consecutiveFailures = 0;
    final generation = ++_generation;
    if (_spec.foregroundOnly && !_orchestrator.isForeground) {
      _suspended = true;
      return;
    }
    _suspended = false;
    _activityMetrics?.setPollerActive(_metricsOwner);
    if (immediate) {
      unawaited(_attempt(generation));
    } else {
      _schedule(generation, _jitteredDelay(_interval.inMicroseconds));
    }
  }

  void stop() {
    if (!_active) return;
    _active = false;
    _suspended = false;
    _generation += 1;
    _timer?.cancel();
    _timer = null;
    _orchestrator.cancel(_spec.key, reason: 'poller-stopped');
    _activityMetrics?.removePoller(_metricsOwner);
  }

  void dispose() {
    if (_disposed) return;
    _orchestrator.removeListener(_handleOrchestratorChanged);
    stop();
    _disposed = true;
  }

  Future<void> _attempt(int generation) async {
    if (!_owns(generation)) return;
    try {
      final shouldContinue = await _orchestrator.schedule<bool>(_spec, _poll);
      if (!_owns(generation)) return;
      if (!shouldContinue) {
        stop();
        return;
      }
      _consecutiveFailures = 0;
      _schedule(generation, _jitteredDelay(_interval.inMicroseconds));
    } catch (_) {
      if (!_owns(generation)) return;
      _consecutiveFailures += 1;
      _orchestrator.recordRetry(_spec);
      _schedule(generation, _failureDelay());
    }
  }

  void _schedule(int generation, Duration delay) {
    if (!_owns(generation)) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_attempt(generation));
    });
  }

  Duration _failureDelay() {
    final exponent = math.min(_consecutiveFailures - 1, 20);
    final exponentialMicros = _interval.inMicroseconds * (1 << exponent);
    final boundedMicros = math.min(
      exponentialMicros,
      _maxBackoff.inMicroseconds,
    );
    return _jitteredDelay(boundedMicros);
  }

  Duration _jitteredDelay(int baseMicroseconds) {
    final random = _randomDouble().clamp(0.0, 1.0);
    final factor = 1 + ((random * 2) - 1) * _jitter;
    final jitteredMicros = (baseMicroseconds * factor).round();
    return Duration(
      microseconds: jitteredMicros.clamp(1, _maxBackoff.inMicroseconds).toInt(),
    );
  }

  void _handleOrchestratorChanged() {
    if (_disposed || !_active || !_spec.foregroundOnly) return;
    final shouldSuspend = !_orchestrator.isForeground;
    if (shouldSuspend == _suspended) return;
    if (shouldSuspend) {
      _suspended = true;
      _generation += 1;
      _timer?.cancel();
      _timer = null;
      _orchestrator.cancel(_spec.key, reason: 'poller-backgrounded');
      _activityMetrics?.removePoller(_metricsOwner);
      return;
    }
    _suspended = false;
    final generation = ++_generation;
    _activityMetrics?.setPollerActive(_metricsOwner);
    unawaited(_attempt(generation));
  }

  bool _owns(int generation) =>
      _active && !_suspended && !_disposed && generation == _generation;
}

final _random = math.Random();

double _defaultRandomDouble() => _random.nextDouble();
