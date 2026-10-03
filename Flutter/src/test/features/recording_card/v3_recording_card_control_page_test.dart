import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/bootstrap/home_widget_snapshot_sync.dart';
import 'package:huahuoai_app/core/native/home_widget_port.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_control_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'physical recording events update elapsed before and after background',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card_event_timer_ui');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'scanFiles' ? <Object?>[] : null;
      });
      final events = StreamController<Object?>(sync: true);
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await port.dispose();
        await events.close();
      });
      events.add(<String, Object?>{
        'type': 'connection_state',
        'deviceState': <String, Object?>{
          'connectionState': 'connected',
          'connectionStage': 'connected',
          'safeDeviceFingerprint': 'event-clock-card',
        },
      });
      final controller = _controller(port);
      var revision = 0;
      void publish(String state, {int duration = 0}) {
        final now = DateTime.now().toUtc().toIso8601String();
        events.add(<String, Object?>{
          'type': 'recording_state',
          'recordingInfo': <String, Object?>{
            'state': state,
            'currentFileName': '20990101000000.m4a',
            'durationSeconds': duration,
            if (state == 'recording') 'startedAt': now,
            'revision': ++revision,
            'observedAt': now,
          },
        });
      }

      publish('recording');
      expect(
        controller.state.snapshot.recordingInfo.state,
        RecordingCardRecordingState.recording,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: V3RecordingCardCompactControl(onOpenManagement: () {}),
            ),
          ),
        ),
      );
      expect(find.text('00:00:00'), findsOneWidget);
      expect(find.text('录音中'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      publish('paused', duration: 8);
      expect(controller.state.snapshot.recordingInfo.durationSeconds, 8);
      publish('recording', duration: 8);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('00:00:08'), findsOneWidget);
      expect(calls, isNot(contains('startRecording')));
      expect(calls, isNot(contains('readRecordingState')));
      publish('idle');
      expect(controller.state.snapshot.recordingInfo.startedAt, isNull);
      await tester.pump();
      expect(find.text('00:00:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'elapsed display stops ticking when hidden without stopping recording',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card_visibility_ui');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'scanFiles' ? <Object?>[] : null;
      });
      final events = StreamController<Object?>(sync: true);
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final enabled = ValueNotifier(true);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        enabled.dispose();
        await port.dispose();
        await events.close();
      });
      events.add(<String, Object?>{
        'type': 'connection_state',
        'deviceState': <String, Object?>{
          'connectionState': 'connected',
          'connectionStage': 'connected',
          'safeDeviceFingerprint': 'visibility-clock-card',
        },
      });
      final controller = _controller(port);
      final startedAt = DateTime.now().toUtc().toIso8601String();
      events.add(<String, Object?>{
        'type': 'recording_state',
        'recordingInfo': <String, Object?>{
          'state': 'recording',
          'currentFileName': '20990101000000.m4a',
          'durationSeconds': 0,
          'startedAt': startedAt,
          'revision': 1,
          'observedAt': startedAt,
        },
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: enabled,
                builder: (context, value, child) =>
                    TickerMode(enabled: value, child: child!),
                child: V3RecordingCardCompactControl(onOpenManagement: () {}),
              ),
            ),
          ),
        ),
      );
      final elapsed = find.byKey(
        const ValueKey('profile-recording-card-elapsed'),
        skipOffstage: false,
      );
      final visibleText = tester.widget<Text>(elapsed);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(elapsed), isNot(same(visibleText)));

      enabled.value = false;
      await tester.pump();
      final disabledText = tester.widget<Text>(elapsed);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.widget<Text>(elapsed), same(disabledText));
      enabled.value = true;
      await tester.pump();
      final enabledText = tester.widget<Text>(elapsed);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(elapsed), isNot(same(enabledText)));

      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Text('Covered recording card')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final coveredText = tester.widget<Text>(elapsed);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.widget<Text>(elapsed), same(coveredText));
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final resumedText = tester.widget<Text>(elapsed);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(elapsed), isNot(same(resumedText)));
      expect(
        controller.state.snapshot.recordingInfo.state,
        RecordingCardRecordingState.recording,
      );
      expect(
        calls.where(
          (method) => const {
            'startRecording',
            'pauseRecording',
            'stopRecording',
            'readRecordingState',
          }.contains(method),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('compact battery badge covers boundary and unknown values', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              V3RecordingCardBatteryBadge(
                percent: 0,
                valueKey: ValueKey('battery-zero'),
              ),
              V3RecordingCardBatteryBadge(
                percent: 100,
                valueKey: ValueKey('battery-full'),
              ),
              V3RecordingCardBatteryBadge(
                percent: null,
                valueKey: ValueKey('battery-unknown'),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('0%'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
    expect(find.textContaining('电量'), findsNothing);
    expect(find.bySemanticsLabel('录音卡电量 0%'), findsOneWidget);
    expect(find.bySemanticsLabel('录音卡电量 100%'), findsOneWidget);
    expect(find.bySemanticsLabel('录音卡电量未知'), findsOneWidget);
    for (final key in const [
      'battery-zero',
      'battery-full',
      'battery-unknown',
    ]) {
      expect(tester.getSize(find.byKey(ValueKey(key))), const Size(48, 24));
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'control page connects, disconnects and keeps management routes',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card_control_connect');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'scanDevices' => <String, Object?>{
            'devices': <Object?>[
              <String, Object?>{
                'displayName': 'Huahuo FW920',
                'safeDeviceFingerprint': 'control-card',
                'isConnectable': true,
              },
            ],
          },
          'connect' => <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'safeDeviceFingerprint': 'control-card',
            'displayName': 'Huahuo FW920',
            'batteryPercent': 72,
          },
          'readRecordingState' => <String, Object?>{
            'state': 'idle',
            'durationSeconds': 0,
          },
          'scanFiles' => <String, Object?>{'files': <Object?>[]},
          'disconnect' => <String, Object?>{
            'connectionState': 'disconnected',
            'connectionStage': 'idle',
          },
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>(sync: true);
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final controller = _controller(port);
      final router = GoRouter(
        initialLocation: '/control',
        routes: [
          GoRoute(
            path: '/control',
            builder: (context, state) => const V3RecordingCardControlPage(),
          ),
          GoRoute(
            path: '/v3/recording-card',
            builder: (context, state) => const Scaffold(body: Text('设备文件管理页')),
          ),
          GoRoute(
            path: '/v3/recording-card/details',
            builder: (context, state) => const Scaffold(body: Text('录音卡设备详情页')),
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      expect(find.text('卡内文件'), findsNothing);
      expect(find.textContaining('已同步'), findsNothing);
      expect(
        find.byKey(const ValueKey('recording-card-control-connect')),
        findsOneWidget,
      );
      expect(
        tester.getSize(
          find.byKey(
            const ValueKey('recording-card-control-connection-target'),
          ),
        ),
        const Size(62, 48),
      );

      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-connection-target')),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('recording-card-nearby-device-control-card')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 560));
      await tester.pump();

      expect(calls, contains('connect'));
      expect(calls, contains('readRecordingState'));
      expect(
        find.byKey(const ValueKey('recording-card-control-disconnect')),
        findsOneWidget,
      );

      expect(
        find.byKey(const ValueKey('recording-card-open-voiceprint')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-connection-target')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('断开').last);
      await tester.pumpAndSettle();
      expect(calls, contains('disconnect'));

      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-device-icon')),
      );
      await tester.pumpAndSettle();
      expect(find.text('设备文件管理页'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('recording-card-open-management')),
      );
      await tester.pumpAndSettle();
      expect(find.text('设备文件管理页'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-details')),
      );
      await tester.pumpAndSettle();
      expect(find.text('录音卡设备详情页'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'active file upload labels the connected card and locks recording controls',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card_upload_status');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final pendingDownload = Completer<Object?>();
      const connectedDevice = <String, Object?>{
        'connectionState': 'ble_ready',
        'connectionStage': 'connected',
        'safeDeviceFingerprint': 'upload-status-card',
        'displayName': 'Huahuo FW920',
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'connect' || 'getConnectionState' => connectedDevice,
          'readRecordingState' => const <String, Object?>{
            'state': 'idle',
            'durationSeconds': 0,
          },
          'scanFiles' => <String, Object?>{
            'files': <Object?>[
              <String, Object?>{
                'deviceFileId': 'upload-status-file',
                'localFileKey': 'upload-status-file',
                'deviceFilename': '20260819090000.m4a',
                'sizeBytes': 2048,
                'format': 'm4a',
              },
            ],
          },
          'downloadFileToLocalCache' => pendingDownload.future,
          _ => null,
        };
      });
      final events = StreamController<Object?>(sync: true);
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final controller = _controller(port);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        if (!pendingDownload.isCompleted) {
          pendingDownload.completeError(
            PlatformException(code: 'RECORDING_CARD_TEST_TRANSFER_CANCELLED'),
          );
        }
        await port.dispose();
        await events.close();
      });

      await controller.connect();
      await controller.scanFiles();
      final transfer = controller.downloadFile(
        controller.state.snapshot.files.single,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3RecordingCardControlPage()),
        ),
      );
      await tester.pump();

      expect(controller.state.hasActiveTransfer, isTrue);
      expect(find.text('文件传输中'), findsWidgets);
      final startControl = find.descendant(
        of: find.byKey(const ValueKey('recording-card-control-start')),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(startControl).onPressed, isNull);

      pendingDownload.completeError(
        PlatformException(code: 'RECORDING_CARD_TEST_TRANSFER_CANCELLED'),
      );
      await transfer;
      await tester.pump();
      expect(controller.state.hasActiveTransfer, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'control page uses shared timer and only explicit status refreshes locally',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card_control_state');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      var recordingState = 'paused';
      var durationSeconds = 90;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'scanFiles':
            return <String, Object?>{'files': <Object?>[]};
          case 'readRecordingState':
            return <String, Object?>{
              'state': recordingState,
              'durationSeconds': durationSeconds,
            };
          case 'resumeRecording':
            recordingState = 'recording';
            return <String, Object?>{
              'state': recordingState,
              'durationSeconds': durationSeconds,
            };
          case 'pauseRecording':
            recordingState = 'paused';
            durationSeconds = 91;
            return <String, Object?>{
              'state': recordingState,
              'durationSeconds': durationSeconds,
            };
          case 'stopRecording':
            recordingState = 'idle';
            durationSeconds = 0;
            return <String, Object?>{
              'state': recordingState,
              'durationSeconds': durationSeconds,
            };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>(sync: true);
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      events.add(<String, Object?>{
        'type': 'runtime_snapshot',
        'snapshot': <String, Object?>{
          'deviceState': <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'safeDeviceFingerprint': 'control-state-card',
            'displayName': 'Huahuo FW920',
          },
          'recordingInfo': <String, Object?>{
            'state': 'paused',
            'durationSeconds': 90,
          },
          'files': <Object?>[
            <String, Object?>{
              'deviceFileId': 'cached-file',
              'localFileKey': 'cached-file',
              'deviceFilename': '20260717090000.m4a',
              'sizeBytes': 4096,
              'format': 'm4a',
            },
          ],
        },
      });
      final controller = _controller(port);
      calls.clear();
      addTearDown(() async {
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: V3RecordingCardControlPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(calls, isEmpty);
      expect(find.text('00:01:30'), findsOneWidget);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('已连接'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('卡内文件'), findsNothing);
      expect(find.textContaining('已同步'), findsNothing);

      calls.clear();
      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-pause-resume')),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, <String>['resumeRecording']);
      expect(find.text('录音中'), findsOneWidget);
      expect(find.text('暂停'), findsOneWidget);

      calls.clear();
      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-status')),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, <String>['readRecordingState']);
      expect(calls, isNot(contains('scanFiles')));

      calls.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, isEmpty);
      expect(calls, isNot(contains('scanFiles')));

      calls.clear();
      await tester.tap(
        find.byKey(const ValueKey('recording-card-control-stop')),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, <String>['stopRecording', 'scanFiles']);
      expect(find.text('00:00:00'), findsOneWidget);
      expect(find.text('待机'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final testCase
      in <
        ({
          RecordingCardWidgetAction action,
          String initialState,
          String expectedMethod,
          String resultState,
        })
      >[
        (
          action: RecordingCardWidgetAction.start,
          initialState: 'idle',
          expectedMethod: 'startRecording',
          resultState: 'recording',
        ),
        (
          action: RecordingCardWidgetAction.pause,
          initialState: 'recording',
          expectedMethod: 'pauseRecording',
          resultState: 'paused',
        ),
        (
          action: RecordingCardWidgetAction.resume,
          initialState: 'paused',
          expectedMethod: 'resumeRecording',
          resultState: 'recording',
        ),
      ]) {
    for (final validTarget in [true, false]) {
      testWidgets(
        'home widget ${testCase.action.name} validates target=$validTarget',
        (tester) async {
          final channel = MethodChannel(
            'huahuoai/recording_card_widget_${testCase.action.name}',
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final calls = <String>[];
          var recordingState = testCase.initialState;
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'readRecordingState') {
              return <String, Object?>{
                'state': recordingState,
                'durationSeconds': 12,
              };
            }
            if (call.method == testCase.expectedMethod) {
              recordingState = testCase.resultState;
              return <String, Object?>{
                'state': recordingState,
                'durationSeconds': 12,
              };
            }
            return null;
          });
          final events = StreamController<Object?>(sync: true);
          final port = MethodChannelRecordingCardPort(
            methodChannel: channel,
            nativeEvents: events.stream,
          );
          events.add(<String, Object?>{
            'type': 'runtime_snapshot',
            'snapshot': <String, Object?>{
              'deviceState': <String, Object?>{
                'connectionState': 'ble_ready',
                'connectionStage': 'connected',
                'safeDeviceFingerprint': 'widget-card',
                'displayName': 'Huahuo FW920',
              },
              'recordingInfo': <String, Object?>{
                'state': recordingState,
                'durationSeconds': 12,
              },
              'files': <Object?>[],
            },
          });
          final controller = _controller(port);
          addTearDown(() async {
            messenger.setMockMethodCallHandler(channel, null);
            await port.dispose();
            await events.close();
          });

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                recordingCardControllerProvider.overrideWith(
                  (ref) => controller,
                ),
                homeWidgetRecordingActionBindingProvider.overrideWith(
                  (ref) => HomeWidgetRecordingActionBinding(
                    token: 'a' * 64,
                    deviceFingerprint: validTarget ? 'widget-card' : 'old-card',
                  ),
                ),
              ],
              child: MaterialApp(
                home: V3RecordingCardControlPage(
                  initialWidgetAction: testCase.action,
                  widgetSnapshotEpochMs: DateTime.now().millisecondsSinceEpoch,
                  widgetActionToken: 'a' * 64,
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          expect(
            calls.where((method) => method == testCase.expectedMethod),
            hasLength(validTarget ? 1 : 0),
          );

          await tester.pump(const Duration(milliseconds: 40));
          expect(
            calls.where((method) => method == testCase.expectedMethod),
            hasLength(validTarget ? 1 : 0),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('disconnected home widget action opens nearby-card search', (
    tester,
  ) async {
    const channel = MethodChannel('huahuoai/recording_card_widget_connect');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'scanDevices' => <String, Object?>{'devices': <Object?>[]},
        _ => null,
      };
    });
    final events = StreamController<Object?>(sync: true);
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = _controller(port);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: V3RecordingCardControlPage(
            initialWidgetAction: RecordingCardWidgetAction.connect,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(calls, contains('scanDevices'));
    expect(find.text('未发现附近的录音卡'), findsOneWidget);
    expect(calls, isNot(contains('startRecording')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'compact control fits drawer width and isolates commands from navigation',
    (tester) async {
      const channel = MethodChannel('huahuoai/recording_card_compact_control');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'readRecordingState' => <String, Object?>{
            'state': 'paused',
            'durationSeconds': 75,
          },
          'resumeRecording' => <String, Object?>{
            'state': 'recording',
            'durationSeconds': 75,
          },
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final events = StreamController<Object?>(sync: true);
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      events.add(<String, Object?>{
        'type': 'runtime_snapshot',
        'snapshot': <String, Object?>{
          'deviceState': <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'safeDeviceFingerprint': 'compact-control-card',
            'displayName': 'Huahuo FW920',
          },
          'recordingInfo': <String, Object?>{
            'state': 'paused',
            'durationSeconds': 75,
          },
        },
      });
      final controller = _controller(port);
      var managementOpenCount = 0;
      addTearDown(() async {
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 212,
                  child: V3RecordingCardCompactControl(
                    onOpenManagement: () => managementOpenCount += 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('00:01:15'), findsOneWidget);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(
        tester
            .widget<Icon>(
              find.byKey(const ValueKey('profile-recording-card-title-icon')),
            )
            .color,
        HuahuoV3Theme.lightTokens.accent,
      );
      expect(
        find.byKey(const ValueKey('profile-recording-card-status')),
        findsNothing,
      );
      final titleRect = tester.getRect(find.text('录音卡'));
      final batteryRect = tester.getRect(
        find.byKey(const ValueKey('profile-recording-card-battery')),
      );
      final elapsedRect = tester.getRect(
        find.byKey(const ValueKey('profile-recording-card-elapsed')),
      );
      expect(batteryRect.left, greaterThan(titleRect.right));
      expect(batteryRect.top, lessThan(elapsedRect.top));
      expect(tester.takeException(), isNull);

      calls.clear();
      await tester.tap(
        find.byKey(const ValueKey('profile-recording-card-pause-resume')),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, <String>['resumeRecording']);
      expect(managementOpenCount, 0);

      await tester.tap(
        find.byKey(const ValueKey('profile-recording-card-start')),
      );
      await tester.pump();
      expect(managementOpenCount, 0);

      expect(
        find.byKey(const ValueKey('profile-recording-card-voiceprint')),
        findsNothing,
      );
      expect(managementOpenCount, 0);

      await tester.tap(
        find.byKey(const ValueKey('profile-recording-card-open-management')),
      );
      await tester.pump();
      expect(managementOpenCount, 1);

      await tester.tap(
        find.byKey(const ValueKey('profile-recording-card-battery')),
      );
      await tester.pump();
      expect(managementOpenCount, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'compact control adapts at 168dp with scaled connection error text',
    (tester) async {
      final controller = _controller(const UnavailableRecordingCardPort());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 568),
                textScaler: TextScaler.linear(1.3),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 168,
                    child: V3RecordingCardCompactControl(
                      onOpenManagement: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('录音卡'), findsOneWidget);
      expect(find.text('连接异常'), findsOneWidget);
      expect(find.text('00:00:00'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-recording-card-connect')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-recording-card-start')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-recording-card-pause-resume')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-recording-card-stop')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'profile compact connection keeps one panel height while search settles',
    (tester) async {
      const channel = MethodChannel(
        'recording_card_profile_connection_dialog_geometry',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final scan = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'scanDevices' => scan.future,
          _ => null,
        };
      });
      final events = StreamController<Object?>();
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final controller = _controller(port);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(402, 874);
      addTearDown(() async {
        if (!scan.isCompleted) {
          scan.complete(<String, Object?>{'devices': <Object?>[]});
        }
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        messenger.setMockMethodCallHandler(channel, null);
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: V3RecordingCardCompactControl(onOpenManagement: () {}),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('profile-recording-card-connect')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      final fixedPanel = find.byKey(
        const ValueKey<String>('recording-card-connection-panel'),
      );
      expect(tester.getSize(fixedPanel), const Size(362, 532));

      scan.complete(<String, Object?>{'devices': <Object?>[]});
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(fixedPanel), const Size(362, 532));
    },
  );

  testWidgets('control surfaces guide a powered-off phone Bluetooth state', (
    tester,
  ) async {
    const channel = MethodChannel('recording_card_control_bluetooth_off');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'scanDevices' || 'connect' => throw PlatformException(
          code: 'RECORDING_CARD_BLUETOOTH_POWERED_OFF',
        ),
        'readRecordingState' => <String, Object?>{'state': 'idle'},
        _ => null,
      };
    });
    final events = StreamController<Object?>(sync: true);
    final dedicatedPort = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final dedicatedController = _controller(dedicatedPort);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dedicatedPort.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingCardControllerProvider.overrideWith(
            (ref) => dedicatedController,
          ),
        ],
        child: const MaterialApp(home: V3RecordingCardControlPage()),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('recording-card-control-connection-target')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      find.byKey(
        const ValueKey('recording-card-control-bluetooth-off-guidance'),
      ),
      findsOneWidget,
    );
    expect(find.text('蓝牙已关闭'), findsWidgets);
    expect(find.textContaining('请先在控制中心或系统设置中打开手机蓝牙'), findsWidgets);
    expect(find.text('连接异常'), findsNothing);
    expect(find.text('RECORDING_CARD_BLUETOOTH_POWERED_OFF'), findsNothing);

    final compactEvents = StreamController<Object?>(sync: true);
    final compactPort = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: compactEvents.stream,
    );
    final compactController = _controller(compactPort);
    addTearDown(() async {
      await compactPort.dispose();
      await compactEvents.close();
    });
    await compactController.connect();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingCardControllerProvider.overrideWith(
            (ref) => compactController,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 168,
              child: V3RecordingCardCompactControl(onOpenManagement: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('蓝牙已关闭'), findsOneWidget);
    expect(find.text('连接异常'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('control page exposes the exact native connection failure', (
    tester,
  ) async {
    final controller = _controller(const UnavailableRecordingCardPort());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: V3RecordingCardControlPage()),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('recording-card-control-connection-target')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('NATIVE_RECORDING_CARD_DRIVER_UNAVAILABLE'), findsWidgets);
    expect(find.text('已连接'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

RecordingCardController _controller(RecordingCardPort port) {
  return RecordingCardController(
    port: port,
    localRecordingRepository: LocalRecordingRepository(
      database: AppDatabase(),
      fileStorage: const UnavailableFileStoragePort(),
    ),
    platformPermissionsPort: const _GrantedPermissionsPort(),
    bindingTokenProvider: _bindingToken,
    requiresBluetoothPermissionRequest: () => false,
  );
}

Future<String> _bindingToken() async => '0123456789abcdef0123456789abcdef';

final class _GrantedPermissionsPort implements PlatformPermissionsPort {
  const _GrantedPermissionsPort();

  @override
  Future<PlatformPermissionResult<BluetoothActivationResult>>
  requestBluetoothActivation() async =>
      PlatformPermissionResult<BluetoothActivationResult>.success(
        BluetoothActivationResult.unavailable,
      );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  loadPermissionSummary() async {
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      const <PlatformPermissionSummary>[],
    );
  }

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async {
    return PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
      PermissionSettingsOpenReceipt(
        kind: kind,
        opened: impactAcknowledged,
        impactText: buildPermissionImpactText(kind),
      ),
    );
  }

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async {
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      const <PlatformPermissionSummary>[
        PlatformPermissionSummary(
          kind: PlatformPermissionKind.bluetooth,
          status: PlatformPermissionStatus.granted,
          impactText: '',
          recoveryAction: PermissionRecoveryAction.none,
        ),
      ],
    );
  }
}
