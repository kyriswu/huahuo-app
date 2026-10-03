import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/lifecycle/app_activity_coordinator.dart';
import 'package:huahuoai_app/app/navigation/app_route_observer.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/recordings/application/recording_waveform_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/widgets/v3_recording_waveform_builder.dart';

void main() {
  test(
    'waveform keeps bounded immutable snapshots only while observed',
    () async {
      final recorder = _LevelRecorder();
      final waveform = RecordingWaveformController(recorder: recorder);
      addTearDown(waveform.dispose);
      addTearDown(recorder.close);
      waveform.start();
      expect(recorder.activeSubscriptions, 0);
      var notifications = 0;
      void listener() => notifications++;
      waveform.addListener(listener);
      expect(recorder.activeSubscriptions, 1);
      final initial = waveform.value;
      for (var index = 0; index < 100; index++) {
        recorder.emit(.5);
      }
      expect(notifications, 100);
      expect(waveform.value, hasLength(68));
      expect(waveform.value, everyElement(greaterThan(0)));
      expect(waveform.value, same(waveform.value));
      expect(initial, everyElement(0));
      expect(() => waveform.value[0] = 1, throwsUnsupportedError);
      recorder.emit(double.nan);
      expect(waveform.value.every((sample) => sample.isFinite), isTrue);
      waveform.removeListener(listener);
      await Future<void>.delayed(Duration.zero);
      expect(recorder.activeSubscriptions, 0);
      expect(waveform.value, everyElement(0));
      waveform.addListener(listener);
      await Future<void>.delayed(Duration.zero);
      recorder.emit(.8);
      expect(waveform.value.last, greaterThan(0));
      await waveform.stop();
      expect(recorder.activeSubscriptions, 0);
      expect(waveform.value, everyElement(0));
    },
  );

  test('resubscription waits for the previous native cancellation', () async {
    final gate = Completer<void>();
    final recorder = _LevelRecorder(cancellation: gate.future);
    final waveform = RecordingWaveformController(recorder: recorder);
    addTearDown(recorder.close);
    addTearDown(waveform.dispose);
    void listener() {}
    waveform.start();
    waveform.addListener(listener);
    waveform.removeListener(listener);
    waveform.addListener(listener);
    expect(recorder.streams, hasLength(1));
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(recorder.streams, hasLength(2));
    expect(recorder.activeSubscriptions, 1);
    waveform.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(recorder.activeSubscriptions, 0);
  });

  testWidgets('only the visible waveform rebuilds and subscribes', (
    tester,
  ) async {
    final recorder = _LevelRecorder();
    final waveform = RecordingWaveformController(recorder: recorder)..start();
    final activity = AppActivityCoordinator();
    activity.updateLifecycle(AppLifecycleState.resumed);
    final tickerEnabled = ValueNotifier(true);
    final navigator = GlobalKey<NavigatorState>();
    var parentBuilds = 0;
    var waveformBuilds = 0;
    addTearDown(waveform.dispose);
    addTearDown(recorder.close);
    addTearDown(tickerEnabled.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appActivityCoordinatorProvider.overrideWith((ref) => activity),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [appRouteObserver],
          home: ValueListenableBuilder<bool>(
            valueListenable: tickerEnabled,
            builder: (context, enabled, child) => TickerMode(
              enabled: enabled,
              child: Builder(
                builder: (context) {
                  parentBuilds++;
                  return V3RecordingWaveformBuilder(
                    source: waveform,
                    builder: (context, samples) {
                      waveformBuilds++;
                      return Text('level=${samples.last}');
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(recorder.activeSubscriptions, 1);
    final beforeParent = parentBuilds;
    final beforeWaveform = waveformBuilds;
    recorder.emit(.8);
    await tester.pump();
    expect(parentBuilds, beforeParent);
    expect(waveformBuilds, beforeWaveform + 1);

    tickerEnabled.value = false;
    await tester.pump();
    expect(recorder.activeSubscriptions, 0);
    tickerEnabled.value = true;
    await tester.pump();
    expect(recorder.activeSubscriptions, 1);

    activity.updateLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(recorder.activeSubscriptions, 0);
    activity.updateLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    expect(recorder.activeSubscriptions, 1);

    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (context) => const Scaffold(body: Text('next')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(recorder.activeSubscriptions, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(recorder.activeSubscriptions, 1);
    await tester.pumpWidget(const SizedBox());
    expect(recorder.activeSubscriptions, 0);
  });
}

class _LevelRecorder implements VoiceRecorderPort, VoiceRecorderLevelSource {
  _LevelRecorder({this.cancellation});

  final Future<void>? cancellation;
  final streams = <StreamController<VoiceLevelSample>>[];
  int activeSubscriptions = 0;

  @override
  Stream<VoiceLevelSample> get levelSamples {
    final controller = StreamController<VoiceLevelSample>(
      sync: true,
      onListen: () => activeSubscriptions++,
      onCancel: () async {
        if (cancellation != null) await cancellation;
        activeSubscriptions--;
      },
    );
    streams.add(controller);
    return controller.stream;
  }

  void emit(double level) => streams.last.add(
    VoiceLevelSample(
      capturedAt: DateTime.utc(2026, 9, 6),
      average: level,
      peak: level,
    ),
  );

  Future<void> close() async {
    for (final controller in streams) {
      await controller.close();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
