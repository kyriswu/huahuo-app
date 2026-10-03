import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/onboarding/application/first_launch_device_setup_controller.dart';
import 'package:huahuoai_app/features/onboarding/data/first_launch_device_setup_repository.dart';
import 'package:huahuoai_app/features/onboarding/presentation/v3_first_launch_device_setup_page.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/ui_v3/application/voiceprint_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_voiceprint_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/app/di/onboarding_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scenario in [
    'skip',
    'denied',
    'recording',
    'stopFailure',
    'submitFailure',
    'success',
    'pendingPermission',
    'pendingUpload',
  ]) {
    testWidgets('real startup voiceprint exits once: $scenario', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture(includeChatGuide: true);
      final hardware = await _RecordingCardFixture.create();
      final router = _router(realVoiceprint: true);
      addTearDown(router.dispose);
      addTearDown(hardware.dispose);
      final permissionGate = Completer<void>();
      final uploadGate = Completer<void>();
      const channel = MethodChannel('startup_voiceprint_test');
      const levelChannel = MethodChannel('startup_voiceprint_levels_test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      var elapsed = 0;
      messenger.setMockMethodCallHandler(levelChannel, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'getMicrophonePermission') {
          if (scenario == 'pendingPermission') await permissionGate.future;
          return {
            'state': scenario == 'denied' ? 'denied' : 'granted',
            'canAskAgain': false,
          };
        }
        if (call.method == 'startRecording' ||
            call.method == 'getRecordingState') {
          return {
            'recordingId': 'voiceprint-startup',
            'scene': 'voiceprint',
            'state': 'recording',
            'startedAt': DateTime.utc(2026, 9, 1).toIso8601String(),
            'elapsedSeconds': elapsed,
          };
        }
        if (call.method == 'stopRecording') {
          if (scenario == 'stopFailure') {
            throw PlatformException(code: 'VOICE_RECORDER_STOP_FAILED');
          }
          return {
            'recordingId': 'voiceprint-startup',
            'scene': 'voiceprint',
            'appPrivateUri': 'app-private://voiceprint-startup.wav',
            'fileName': 'voiceprint-startup.wav',
            'mimeType': 'audio/wav',
            'sizeBytes': 320044,
            'durationSeconds': 10,
            'sampleRateHz': 16000,
            'bitDepth': 16,
            'channelCount': 1,
            'sha256': 'a' * 64,
            'recordedAt': DateTime.utc(2026, 9, 1).toIso8601String(),
          };
        }
        if (call.method == 'cancelRecording') return {'state': 'idle'};
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(levelChannel, null);
      });
      final voiceprint = VoiceprintController(
        recorder: MethodChannelVoiceRecorderPort(
          channel: channel,
          levelChannel: const EventChannel('startup_voiceprint_levels_test'),
        ),
        port: SessionMockVoiceprintPort(
          deleteLocalSample: (_) async {
            if (scenario == 'pendingUpload') await uploadGate.future;
            return scenario != 'submitFailure';
          },
        ),
        initialUserId: 'first-launch-page-user',
      );
      await tester.pumpWidget(
        _app(
          router,
          fixture,
          recordingController: hardware.controller,
          voiceprintController: voiceprint,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('first-launch-voiceprint-enroll')),
      );
      await tester.pumpAndSettle();
      expect(find.text('录制 10 秒，满 10 秒自动结束'), findsOneWidget);
      if (scenario != 'skip') {
        await tester.ensureVisible(find.text('开始录入'));
        await tester.tap(find.text('开始录入'));
        await tester.pump();
        if (scenario != 'pendingPermission') await tester.pumpAndSettle();
      }
      if (['skip', 'recording', 'pendingPermission'].contains(scenario)) {
        await tester.tap(find.byKey(const ValueKey('voiceprint-startup-next')));
        await tester.pumpAndSettle();
      } else if (scenario != 'denied') {
        elapsed = 10;
        await tester.runAsync(() async {
          await voiceprint.refresh();
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        expect(
          calls.where((method) => method == 'stopRecording'),
          hasLength(1),
          reason:
              '${voiceprint.state.status} ${voiceprint.state.errorCode}: ${calls.join(', ')}',
        );
        if (scenario != 'stopFailure') {
          expect(voiceprint.state.status, VoiceprintStatus.ready);
          await tester.ensureVisible(find.byType(CheckboxListTile));
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pump();
          await tester.ensureVisible(find.text('确认录入'));
          await tester.tap(find.text('确认录入'));
          await tester.pump();
          if (scenario == 'pendingUpload') {
            expect(voiceprint.state.status, VoiceprintStatus.submitting);
            await tester.tap(
              find.byKey(const ValueKey('voiceprint-startup-next')),
            );
          }
        }
      }
      await tester.pumpAndSettle();
      expect(
        fixture.controller.phase,
        FirstLaunchJourneyPhase.recordingCardRequired,
      );
      expect(fixture.controller.snapshot.voiceprint.status, switch (scenario) {
        'denied' ||
        'stopFailure' ||
        'submitFailure' => FirstLaunchStepStatus.failed,
        'success' => FirstLaunchStepStatus.succeeded,
        _ => FirstLaunchStepStatus.deferred,
      });
      expect(
        find.byKey(const ValueKey('first-launch-recording-card-search')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('first-launch-recording-card-skip')),
      );
      await tester.pumpAndSettle();
      if (!permissionGate.isCompleted) permissionGate.complete();
      if (!uploadGate.isCompleted) uploadGate.complete();
      await tester.pumpAndSettle();
      expect(fixture.controller.phase, FirstLaunchJourneyPhase.chatRequired);
      if (scenario == 'pendingPermission') {
        expect(calls, isNot(contains('startRecording')));
      }
      if (scenario == 'recording') expect(calls, contains('cancelRecording'));
      expect(tester.takeException(), isNull);
    });
  }

  for (final outcome in [
    'success',
    'failure',
    'cancel',
    'empty',
    'pendingConnect',
    'external',
  ]) {
    testWidgets('startup card $outcome advances to the fourth step', (
      tester,
    ) async {
      final fixture = _Fixture(
        phase: FirstLaunchJourneyPhase.recordingCardRequired,
        includeChatGuide: true,
      );
      final connectionGate = Completer<void>();
      final hardware = await _RecordingCardFixture.create(
        failConnect: outcome == 'failure',
        emptyScan: outcome == 'empty',
        connectionGate: outcome == 'pendingConnect'
            ? connectionGate.future
            : null,
      );
      final router = _router();
      addTearDown(router.dispose);
      addTearDown(hardware.dispose);
      await tester.pumpWidget(
        _app(router, fixture, recordingController: hardware.controller),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('first-launch-recording-card-search')),
      );
      await tester.pumpAndSettle();
      if (outcome == 'external') {
        await hardware.controller.connectDiscoveredDevice(
          const RecordingCardDiscoveredDevice(
            displayName: '无限花火录音卡',
            safeDeviceFingerprint: 'first-launch-card',
            serialNumber: 'SP63A03003',
            isConnectable: true,
          ),
        );
      } else if (outcome == 'cancel') {
        await tester.tap(
          find.byKey(const ValueKey('recording-card-connection-cancel')),
        );
      } else if (outcome != 'empty') {
        await tester.tap(
          find.byKey(
            const ValueKey('recording-card-nearby-device-first-launch-card'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('recording-card-connection-rescan')),
        );
        if (outcome == 'pendingConnect') {
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('recording-card-connection-cancel')),
          );
        }
      }
      await tester.pumpAndSettle();
      expect(fixture.controller.phase, FirstLaunchJourneyPhase.chatRequired);
      expect(
        fixture.controller.snapshot.recordingCard.status,
        switch (outcome) {
          'success' => FirstLaunchStepStatus.succeeded,
          'failure' => FirstLaunchStepStatus.failed,
          _ => FirstLaunchStepStatus.deferred,
        },
      );
      expect(find.text('v3-home'), findsOneWidget);
      connectionGate.complete();
      await tester.pumpAndSettle();
      expect(fixture.controller.phase, FirstLaunchJourneyPhase.chatRequired);
      if (outcome == 'pendingConnect') {
        expect(
          fixture.controller.snapshot.recordingCard.status,
          FirstLaunchStepStatus.deferred,
        );
      }
    });
  }

  testWidgets('unstarted device journey returns to positioning', (
    tester,
  ) async {
    final fixture = _Fixture(phase: FirstLaunchJourneyPhase.notStarted);
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(router, fixture));
    await tester.pumpAndSettle();
    expect(find.text('onboarding-intake'), findsOneWidget);
  });

  testWidgets('deferring voiceprint then card visits both steps before home', (
    tester,
  ) async {
    final fixture = _Fixture();
    final hardware = await _RecordingCardFixture.create();
    final router = _router();
    addTearDown(router.dispose);
    addTearDown(hardware.dispose);
    await tester.pumpWidget(
      _app(router, fixture, recordingController: hardware.controller),
    );
    await tester.pumpAndSettle();
    expect(find.text('录入你的声纹'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('first-launch-voiceprint-skip')),
    );
    await tester.pumpAndSettle();
    expect(
      fixture.controller.snapshot.voiceprint.status,
      FirstLaunchStepStatus.deferred,
    );
    expect(
      find.byKey(const ValueKey('first-launch-recording-card-search')),
      findsOneWidget,
    );
    expect(find.text('v3-home'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('first-launch-recording-card-skip')),
    );
    await tester.pumpAndSettle();
    expect(find.text('v3-home'), findsOneWidget);
    expect(
      fixture.controller.snapshot.recordingCard.status,
      FirstLaunchStepStatus.deferred,
    );
    expect(
      fixture.controller.snapshot.positioning.status,
      FirstLaunchStepStatus.submitted,
    );
  });

  for (final result in <bool?>[true, false, null]) {
    testWidgets(
      'voiceprint result $result continues to card without success coupling',
      (tester) async {
        final fixture = _Fixture();
        final hardware = await _RecordingCardFixture.create();
        final router = _router(voiceprintResult: result);
        addTearDown(router.dispose);
        addTearDown(hardware.dispose);
        await tester.pumpWidget(
          _app(router, fixture, recordingController: hardware.controller),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('first-launch-voiceprint-enroll')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('voiceprint-return')));
        await tester.pumpAndSettle();
        expect(
          fixture.controller.phase,
          FirstLaunchJourneyPhase.recordingCardRequired,
        );
        expect(fixture.controller.snapshot.voiceprint.status, switch (result) {
          true => FirstLaunchStepStatus.succeeded,
          false => FirstLaunchStepStatus.failed,
          null => FirstLaunchStepStatus.deferred,
        });
      },
    );
  }

  testWidgets(
    'an operational card still requires explicit ownership confirmation',
    (tester) async {
      final fixture = _Fixture(
        phase: FirstLaunchJourneyPhase.recordingCardRequired,
      );
      final hardware = await _RecordingCardFixture.create();
      await hardware.controller.connectDiscoveredDevice(
        const RecordingCardDiscoveredDevice(
          displayName: '无限花火录音卡',
          safeDeviceFingerprint: 'first-launch-card',
          serialNumber: 'SP63A03003',
          isConnectable: true,
        ),
      );
      final router = _router();
      addTearDown(router.dispose);
      addTearDown(hardware.dispose);
      await tester.pumpWidget(
        _app(router, fixture, recordingController: hardware.controller),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认已连接的录音卡'), findsOneWidget);
      expect(fixture.controller.snapshot.isComplete, isFalse);
      await tester.tap(
        find.byKey(
          const ValueKey('first-launch-recording-card-confirm-ownership'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('v3-home'), findsOneWidget);
      expect(
        fixture.controller.snapshot.recordingCard.status,
        FirstLaunchStepStatus.succeeded,
      );
      expect(fixture.controller.snapshot.recordingCardSerial, 'HFRC-82A4-19C7');
      expect(
        fixture.controller.snapshot.voiceprint.status,
        FirstLaunchStepStatus.deferred,
      );
    },
  );
}

Widget _app(
  GoRouter router,
  _Fixture fixture, {
  RecordingCardController? recordingController,
  VoiceprintController? voiceprintController,
}) => ProviderScope(
  overrides: <Override>[
    firstLaunchDeviceSetupControllerProvider.overrideWith(
      (ref) => fixture.controller,
    ),
    if (voiceprintController != null)
      voiceprintControllerProvider.overrideWith((ref) => voiceprintController),
    if (recordingController != null)
      recordingCardControllerProvider.overrideWith(
        (ref) => recordingController,
      ),
  ],
  child: MaterialApp.router(theme: HuahuoV3Theme.dark(), routerConfig: router),
);

GoRouter _router({bool? voiceprintResult, bool realVoiceprint = false}) =>
    GoRouter(
      initialLocation: '/setup',
      routes: <RouteBase>[
        GoRoute(
          path: '/setup',
          builder: (context, state) => const V3FirstLaunchDeviceSetupPage(),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (context, state) =>
              const Scaffold(body: Text('onboarding-intake')),
        ),
        GoRoute(
          path: '/v3',
          builder: (context, state) => const Scaffold(body: Text('v3-home')),
        ),
        GoRoute(
          path: '/v3/profile/voiceprint/enroll',
          builder: (context, state) => realVoiceprint
              ? const V3VoiceprintPage(
                  enrollmentOnly: true,
                  startupJourney: true,
                  initialProfileName: '我的声纹',
                )
              : Scaffold(
                  body: Center(
                    child: TextButton(
                      key: const ValueKey('voiceprint-return'),
                      onPressed: () => context.pop<bool>(voiceprintResult),
                      child: const Text('return'),
                    ),
                  ),
                ),
        ),
      ],
    );

final class _Fixture {
  _Fixture({
    FirstLaunchJourneyPhase phase = FirstLaunchJourneyPhase.voiceprintRequired,
    bool includeChatGuide = false,
  }) {
    controller = FirstLaunchDeviceSetupController(
      repository: FirstLaunchDeviceSetupRepository(
        dao: AppPreferencesDao(AppDatabase()),
        userScope: 'first-launch-page-user',
      ),
    );
    if (phase != FirstLaunchJourneyPhase.notStarted) {
      controller.beginPositioning(includeChatGuide: includeChatGuide);
      controller.finishPositioning(FirstLaunchStepStatus.submitted);
      if (phase == FirstLaunchJourneyPhase.recordingCardRequired) {
        controller.finishVoiceprint(FirstLaunchStepStatus.deferred);
      }
    }
  }
  late final FirstLaunchDeviceSetupController controller;
}

final class _RecordingCardFixture {
  _RecordingCardFixture._({
    required this.controller,
    required this.port,
    required this.events,
    required this.messenger,
    required this.channel,
    required this.calls,
  });

  final RecordingCardController controller;
  final MethodChannelRecordingCardPort port;
  final StreamController<Object?> events;
  final TestDefaultBinaryMessenger messenger;
  final MethodChannel channel;
  final List<MethodCall> calls;

  static Future<_RecordingCardFixture> create({
    bool failConnect = false,
    bool emptyScan = false,
    Future<void>? connectionGate,
  }) async {
    const channel = MethodChannel('first_launch_recording_card_journey');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'connect' && connectionGate != null) {
        await connectionGate;
      }
      if (call.method == 'connect' && failConnect) {
        throw PlatformException(code: 'RECORDING_CARD_CONNECT_FAILED');
      }
      return switch (call.method) {
        'scanDevices' => <String, Object?>{
          'devices': emptyScan
              ? <Object?>[]
              : <Object?>[
                  <String, Object?>{
                    'displayName': '无限花火录音卡',
                    'safeDeviceFingerprint': 'first-launch-card',
                    'serialNumber': 'SP63A03003',
                    'rssi': -42,
                    'isConnectable': true,
                  },
                ],
        },
        'connect' => <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': '无限花火录音卡',
          'safeDeviceFingerprint': 'first-launch-card',
          'serialNumber': 'HFRC-82A4-19C7',
        },
        'disconnect' => <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
        },
        'scanFiles' => <String, Object?>{'files': <Object?>[]},
        _ => null,
      };
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = RecordingCardController(
      port: port,
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: () async => '0123456789abcdef0123456789abcdef',
      requiresBluetoothPermissionRequest: () => false,
    );
    return _RecordingCardFixture._(
      controller: controller,
      port: port,
      events: events,
      messenger: messenger,
      channel: channel,
      calls: calls,
    );
  }

  Future<void> dispose() async {
    messenger.setMockMethodCallHandler(channel, null);
    await port.dispose();
    await events.close();
  }
}

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
  loadPermissionSummary() async =>
      PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
        const <PlatformPermissionSummary>[],
      );

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async => PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
    PermissionSettingsOpenReceipt(
      kind: kind,
      opened: impactAcknowledged,
      impactText: buildPermissionImpactText(kind),
    ),
  );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async =>
      PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
        const <PlatformPermissionSummary>[],
      );
}
