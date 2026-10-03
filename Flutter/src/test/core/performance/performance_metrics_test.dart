import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/runtime/runtime_provider_module.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/performance/database_metrics.dart';
import 'package:huahuoai_app/core/performance/frame_metrics_collector.dart';
import 'package:huahuoai_app/core/performance/memory_pressure_port.dart';
import 'package:huahuoai_app/core/performance/network_metrics.dart';
import 'package:huahuoai_app/core/performance/performance_snapshot.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/performance/task_metrics.dart';
import 'package:huahuoai_app/core/performance/thermal_state_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'frame metrics retain a bounded window and report percentiles and jank',
    () {
      final metrics = FrameMetricsCollector(capacity: 3);
      for (final milliseconds in <int>[10, 20, 40, 50]) {
        metrics.recordFrame(
          build: Duration(milliseconds: milliseconds ~/ 2),
          raster: Duration(milliseconds: milliseconds ~/ 4),
          total: Duration(milliseconds: milliseconds),
        );
      }

      final snapshot = metrics.snapshot();
      expect(snapshot.sampleCount, 4);
      expect(snapshot.retainedSampleCount, 3);
      expect(snapshot.total.p50Ms, 40);
      expect(snapshot.total.p95Ms, 50);
      expect(snapshot.total.p99Ms, 50);
      expect(snapshot.jankCount, 2);
      expect(snapshot.jankRate, closeTo(2 / 3, 0.0001));
      expect(snapshot.recentFrames, hasLength(3));

      metrics
        ..start()
        ..start();
      expect(metrics.isRunning, isTrue);
      metrics
        ..stop()
        ..stop()
        ..dispose();
      expect(metrics.isRunning, isFalse);
    },
  );

  test('frame metric notifications are emitted by aggregate window', () {
    final metrics = FrameMetricsCollector(notificationBatchSize: 3);
    addTearDown(metrics.dispose);
    var notifications = 0;
    metrics.addListener(() => notifications++);

    for (var index = 0; index < 7; index++) {
      metrics.recordFrame(
        build: const Duration(milliseconds: 1),
        raster: const Duration(milliseconds: 1),
        total: const Duration(milliseconds: 2),
      );
    }

    expect(notifications, 2);
    metrics.reset();
    expect(notifications, 3);
  });

  test('total percentiles are shared until samples change or reset', () {
    final metrics = FrameMetricsCollector(
      capacity: 1,
      notificationBatchSize: 1,
    );
    addTearDown(metrics.dispose);
    final empty = metrics.totalPercentiles;
    expect(empty.p95Ms, isNull);
    expect(metrics.totalPercentiles, same(empty));
    final notifiedTotals = <double?>[];
    metrics.addListener(() {
      notifiedTotals.add(metrics.totalPercentiles.p95Ms);
    });

    for (final milliseconds in <int>[40, 10]) {
      final previous = metrics.totalPercentiles;
      metrics.recordFrame(
        build: const Duration(milliseconds: 2),
        raster: const Duration(milliseconds: 3),
        total: Duration(milliseconds: milliseconds),
      );
      final current = metrics.totalPercentiles;
      expect(current, isNot(same(previous)));
      expect(current.p95Ms, milliseconds);
      expect(metrics.totalPercentiles, same(current));
      expect(metrics.snapshot().total, same(current));
      expect(metrics.retainedSampleCount, 1);
    }

    final retained = metrics.totalPercentiles;
    metrics.reset();
    expect(metrics.totalPercentiles, isNot(same(retained)));
    expect(metrics.totalPercentiles.p95Ms, isNull);
    expect(metrics.snapshot().total, same(metrics.totalPercentiles));
    expect(notifiedTotals, <double?>[40, 10, null]);
  });

  test(
    'recent frame export is capped independently from aggregate capacity',
    () {
      final metrics = FrameMetricsCollector();
      addTearDown(metrics.dispose);
      for (var index = 0; index < 650; index++) {
        metrics.recordFrame(
          build: Duration(milliseconds: index),
          raster: Duration(milliseconds: index + 1),
          total: Duration(milliseconds: index + 2),
        );
      }

      final snapshot = metrics.snapshot();
      expect(snapshot.sampleCount, 650);
      expect(snapshot.retainedSampleCount, 600);
      expect(snapshot.recentFrames, hasLength(60));
      expect(
        snapshot.recentFrames.first.total,
        const Duration(milliseconds: 592),
      );
      expect(snapshot.toJson()['recentFrames'], isA<List<Object?>>());
    },
  );

  test('runtime metrics sanitize navigation context and retain peak gauges', () {
    final metrics = RuntimeActivityMetrics(
      capacity: 2,
      now: () => DateTime.utc(2026, 8, 31, 8),
    );
    metrics.update(
      route:
          'https://example.test/v3/chat/550e8400-e29b-41d4-a716-446655440000?token=secret',
      tab: 'feed main',
      lifecycle: AppLifecycleState.resumed,
      activeTasks: 4,
      visualQuality: RuntimeVisualQuality.balanced,
    );
    metrics
      ..setTickerActive('knowledge graph')
      ..setTickerActive('recording waveform')
      ..setPollerActive('chat fallback')
      ..setPollerActive('recording status')
      ..setSseState('chat stream', RuntimeSseState.healthy)
      ..removeTicker('knowledge graph')
      ..removePoller('chat fallback')
      ..update(activeTasks: 2);

    final snapshot = metrics.snapshot();
    expect(snapshot.current.route, '/v3/chat/:id');
    expect(snapshot.current.tab, 'feed_main');
    expect(snapshot.current.activeTickers, 1);
    expect(snapshot.current.activePollers, 1);
    expect(snapshot.current.sseState, RuntimeSseState.healthy);
    expect(snapshot.peakTickers, 2);
    expect(snapshot.peakPollers, 2);
    expect(snapshot.peakTasks, 4);
    expect(snapshot.retainedSampleCount, 2);
  });

  test('runtime owner gauges are idempotent and aggregate SSE health', () {
    final metrics = RuntimeActivityMetrics()
      ..update(lifecycle: AppLifecycleState.resumed)
      ..setTickerActive('knowledge graph')
      ..setTickerActive('knowledge graph')
      ..setTickerActive('recording waveform')
      ..setPollerActive('chat fallback')
      ..setPollerActive('chat fallback')
      ..setSseState('chat stream', RuntimeSseState.healthy)
      ..setSseState('sync stream', RuntimeSseState.connecting)
      ..setSseState('recording stream', RuntimeSseState.failed);

    expect(metrics.current.activeTickers, 2);
    expect(metrics.current.activePollers, 1);
    expect(metrics.current.sseState, RuntimeSseState.failed);

    metrics
      ..removeTicker('missing owner')
      ..removeTicker('knowledge graph')
      ..removeTicker('knowledge graph')
      ..removeSseState('recording stream');
    expect(metrics.current.activeTickers, 1);
    expect(metrics.current.sseState, RuntimeSseState.connecting);

    metrics
      ..setSseState('sync stream', RuntimeSseState.healthy)
      ..removeSseState('chat stream');
    expect(metrics.current.sseState, RuntimeSseState.healthy);
  });

  test('runtime owner gauges clear on lifecycle pause and disposal', () {
    final metrics = RuntimeActivityMetrics()
      ..update(lifecycle: AppLifecycleState.resumed)
      ..setTickerActive('knowledge graph')
      ..setPollerActive('chat fallback')
      ..setSseState('chat stream', RuntimeSseState.healthy)
      ..update(lifecycle: AppLifecycleState.paused);

    expect(metrics.current.activeTickers, 0);
    expect(metrics.current.activePollers, 0);
    expect(metrics.current.sseState, RuntimeSseState.disconnected);

    metrics
      ..update(lifecycle: AppLifecycleState.resumed)
      ..setTickerActive('knowledge graph')
      ..setPollerActive('chat fallback')
      ..setSseState('chat stream', RuntimeSseState.healthy)
      ..dispose()
      ..setTickerActive('late ticker')
      ..setPollerActive('late poller')
      ..setSseState('late stream', RuntimeSseState.failed);

    expect(metrics.current.activeTickers, 0);
    expect(metrics.current.activePollers, 0);
    expect(metrics.current.sseState, RuntimeSseState.disconnected);
  });

  test('runtime rebuild metrics keep bounded safe owner categories', () {
    final metrics = RuntimeActivityMetrics(maxRebuildOwners: 1)
      ..recordRebuild('chat streaming item')
      ..recordRebuild('chat streaming item')
      ..recordRebuild('private/thread/123456789012345678901234')
      ..recordRebuild('another category');

    final snapshot = metrics.snapshot();
    expect(snapshot.totalRebuilds, 4);
    expect(snapshot.rebuildsByOwner, <String, int>{
      'chat_streaming_item': 2,
      'other': 2,
    });
  });

  test(
    'task metrics aggregate outcomes without accepting task identifiers',
    () {
      final metrics = TaskMetrics(capacity: 2, maxKinds: 1);
      metrics
        ..recordStarted('chat run')
        ..recordRetry('chat run')
        ..recordFinished(
          'chat run',
          outcome: TaskMetricOutcome.succeeded,
          elapsed: const Duration(milliseconds: 20),
        )
        ..recordStarted('recording:private-id')
        ..recordFinished(
          'recording:private-id',
          outcome: TaskMetricOutcome.failed,
          elapsed: const Duration(milliseconds: 40),
        );

      final snapshot = metrics.snapshot();
      expect(snapshot.started, 2);
      expect(snapshot.succeeded, 1);
      expect(snapshot.failed, 1);
      expect(snapshot.retries, 1);
      expect(snapshot.active, 0);
      expect(snapshot.byKind.keys, containsAll(<String>['chat_run', 'other']));
      expect(snapshot.duration.p95Ms, 40);
    },
  );

  test('database metrics expose bounded aggregate timing and volume only', () {
    final metrics = DatabaseMetrics(capacity: 2, maxLabels: 1);
    metrics
      ..setQueueDepth(3)
      ..record(
        operation: 'upsert',
        table: 'chat_run_checkpoint',
        queueWait: const Duration(milliseconds: 4),
        execute: const Duration(milliseconds: 12),
        rows: 1,
        bytes: 80,
        reason: 'stream checkpoint',
        callerFeature: 'chat',
      )
      ..record(
        operation: 'delete',
        table: 'diagnostic_logs',
        queueWait: const Duration(milliseconds: 8),
        execute: const Duration(milliseconds: 30),
        rows: 2,
        bytes: 10,
        callerFeature: 'diagnostics',
        success: false,
      )
      ..setQueueDepth(0);

    final snapshot = metrics.snapshot();
    expect(snapshot.operations, 2);
    expect(snapshot.writes, 2);
    expect(snapshot.failures, 1);
    expect(snapshot.rows, 3);
    expect(snapshot.bytes, 90);
    expect(snapshot.peakQueueDepth, 3);
    expect(snapshot.longestExecuteMs, 30);
    expect(snapshot.byOperation.keys, containsAll(<String>['upsert', 'other']));
    expect(
      snapshot.byTable.keys,
      containsAll(<String>['chat_run_checkpoint', 'other']),
    );
  });

  test('network metrics discard host query and identifier path segments', () {
    final metrics = NetworkMetrics(capacity: 2);
    metrics
      ..recordStarted()
      ..recordStarted()
      ..recordRetry()
      ..recordCompleted(
        method: 'get',
        endpoint:
            'https://api.example.test/api/v1/runs/550e8400-e29b-41d4-a716-446655440000?access_token=secret',
        duration: const Duration(milliseconds: 15),
        statusCode: 200,
        bytesReceived: 128,
      )
      ..recordCompleted(
        method: 'post',
        endpoint: '/api/v1/runs/12345#private',
        duration: const Duration(milliseconds: 25),
        statusCode: 503,
        bytesSent: 64,
        success: false,
      );

    final snapshot = metrics.snapshot();
    expect(snapshot.peakActive, 2);
    expect(snapshot.active, 0);
    expect(snapshot.failures, 1);
    expect(snapshot.retries, 1);
    expect(snapshot.byEndpoint.keys, <String>['/api/v1/runs/:id']);
    expect(snapshot.byStatusClass, <String, int>{'2xx': 1, '5xx': 1});
    expect(snapshot.duration.p95Ms, 25);
  });

  test('instrumented transport records unary and SSE handshakes', () async {
    final metrics = NetworkMetrics();
    final transport = InstrumentedApiTransport(
      delegate: _PerformanceTestTransport(),
      metrics: metrics,
    );
    final request = ApiTransportRequest(
      url: Uri.parse(
        'https://api.example.test/runs/'
        '550e8400-e29b-41d4-a716-446655440000?token=private',
      ),
      method: 'GET',
      headers: const <String, String>{},
      body: '{"private":"content"}',
    );

    await transport.send(request);
    await transport.open(request);

    final snapshot = metrics.snapshot();
    expect(snapshot.started, 2);
    expect(snapshot.completed, 2);
    expect(snapshot.active, 0);
    expect(snapshot.bytesReceived, 24);
    expect(snapshot.byEndpoint, <String, int>{'/runs/:id': 2});
    expect(snapshot.toJson().toString(), isNot(contains('private')));
  });

  test('instrumented transport forwards unary cancellation', () async {
    final metrics = NetworkMetrics();
    final delegate = _CancellablePerformanceTestTransport();
    final transport = InstrumentedApiTransport(
      delegate: delegate,
      metrics: metrics,
    );
    final operation = transport.sendCancellable(
      ApiTransportRequest(
        url: Uri.parse('https://api.example.test/assets/markdown'),
        method: 'GET',
        headers: const <String, String>{},
      ),
    );
    final completion = expectLater(operation.response, throwsStateError);

    expect(metrics.snapshot().active, 1);
    operation.cancel();
    await completion;

    final snapshot = metrics.snapshot();
    expect(delegate.cancelCalls, 1);
    expect(snapshot.started, 1);
    expect(snapshot.completed, 1);
    expect(snapshot.failures, 1);
    expect(snapshot.active, 0);
  });

  test('memory and thermal ports emit bounded typed state', () async {
    final now = DateTime.utc(2026, 8, 31, 9);
    final memory = InMemoryMemoryPressurePort(capacity: 2, now: () => now);
    final thermal = InMemoryThermalStatePort(capacity: 2, now: () => now);
    final memoryEvent = expectLater(
      memory.changes,
      emits(
        predicate<MemoryPressureObservation>((value) {
          return value.level == MemoryPressureLevel.critical;
        }),
      ),
    );
    final thermalEvent = expectLater(
      thermal.changes,
      emits(
        predicate<ThermalStateObservation>((value) {
          return value.thermalLevel == ThermalLevel.serious &&
              value.powerClass == PowerClass.lowPower;
        }),
      ),
    );

    memory.update(MemoryPressureLevel.critical);
    thermal.update(
      thermalLevel: ThermalLevel.serious,
      powerClass: PowerClass.lowPower,
    );
    await Future.wait(<Future<void>>[memoryEvent, thermalEvent]);
    expect(memory.current.toJson()['level'], 'critical');
    expect(thermal.current.toJson()['powerClass'], 'lowPower');
    expect(memory.retainedObservationCount, 2);
    expect(thermal.retainedObservationCount, 2);
    memory.dispose();
    thermal.dispose();
  });

  test('performance snapshot recursively redacts unsafe diagnostic fields', () {
    final snapshot = PerformanceSnapshot(
      capturedAt: DateTime.utc(2026, 8, 31, 10),
      frame: const <String, Object?>{'sampleCount': 12},
      runtime: const <String, Object?>{
        'route': '/v3/chat/:id',
        'token': 'must-not-appear',
      },
      tasks: const <String, Object?>{},
      database: const <String, Object?>{
        'queueDepth': 2,
        'sqlText': 'select private',
      },
      network: const <String, Object?>{
        'endpoint': '/api/v1/runs/:id?secret=yes',
        'requestBody': 'private prose',
      },
      imageCaches: const <String, Object?>{
        'decoded': <String, Object?>{
          'currentBytes': 1024,
          'maximumBytes': 2048,
        },
        'url': 'https://private.example/image?token=secret',
        'path': '/Users/run/private/image.png',
      },
    );

    final encoded = snapshot.toJsonString();
    expect(jsonDecode(encoded), isA<Map<String, Object?>>());
    expect(encoded, contains('/v3/chat/:id'));
    expect(encoded, isNot(contains('must-not-appear')));
    expect(encoded, isNot(contains('select private')));
    expect(encoded, isNot(contains('private prose')));
    expect(encoded, isNot(contains('secret=yes')));
    expect(encoded, isNot(contains('private.example')));
    expect(encoded, isNot(contains('/Users/run/private')));
    expect(encoded, contains('currentBytes'));
    expect(encoded, contains('[REDACTED]'));
  });

  test('app runtime captures real cache gauges only on demand', () {
    final frames = FrameMetricsCollector();
    final activity = RuntimeActivityMetrics()
      ..update(
        route: '/v3/feed/chat/private-thread-123456789012345678901234',
        lifecycle: AppLifecycleState.resumed,
      );
    final memory = InMemoryMemoryPressurePort();
    final thermal = InMemoryThermalStatePort();
    addTearDown(() {
      frames.dispose();
      activity.dispose();
      memory.dispose();
      thermal.dispose();
    });
    final runtime = AppPerformanceRuntime(
      frames: frames,
      activity: activity,
      tasks: TaskMetrics(),
      database: DatabaseMetrics(),
      network: NetworkMetrics(),
      memoryPressure: memory,
      thermal: thermal,
    );

    final snapshot = runtime.capture(
      compressedImageCache: const <String, Object?>{
        'available': true,
        'currentBytes': 4096,
        'maximumBytes': 8192,
      },
    );
    final caches = snapshot.imageCaches;
    expect(caches['decoded'], containsPair('available', true));
    expect(caches['compressed'], containsPair('currentBytes', 4096));
    expect(
      (snapshot.frame['windowContext']! as Map<String, Object?>)['route'],
      '/v3/feed/chat/:id',
    );
  });
}

final class _PerformanceTestTransport
    implements ApiTransport, ApiStreamingTransport {
  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    return const ApiTransportResponse(
      status: 200,
      headers: <String, String>{'Content-Length': '12'},
      body: <String, Object?>{'success': true},
    );
  }

  @override
  Future<ApiTransportStreamResponse> open(ApiTransportRequest request) async {
    return const ApiTransportStreamResponse(
      status: 200,
      headers: <String, String>{'content-length': '12'},
      events: Stream<ApiTransportStreamEvent>.empty(),
    );
  }
}

final class _CancellablePerformanceTestTransport
    implements ApiTransport, CancellableApiTransport {
  int cancelCalls = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) =>
      sendCancellable(request).response;

  @override
  ApiTransportOperation sendCancellable(ApiTransportRequest request) {
    final response = Completer<ApiTransportResponse>();
    return ApiTransportOperation(
      response: response.future,
      cancel: () {
        cancelCalls += 1;
        if (!response.isCompleted) {
          response.completeError(StateError('transport-cancelled'));
        }
      },
    );
  }
}
