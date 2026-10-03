import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_connection_history.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_connection_dialog.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const handshakeFailures = <String, String>{
    'RECORDING_CARD_SETUP_TIMEOUT': '录音卡连接初始化超时，请重新连接。',
    'RECORDING_CARD_CONNECT_BUSY': '当前录音卡仍在使用，请先结束录音或传输，再断开后重试。',
    'RECORDING_CARD_BINDING_INFO_MALFORMED': '录音卡返回的配对信息格式异常，无法完成握手，请重新连接。',
    'RECORDING_CARD_BINDING_INFO_TIMEOUT': '录音卡未在配对时限内返回绑定信息，请靠近录音卡后重新连接。',
    'RECORDING_CARD_BINDING_WINDOW_EXPIRED': '未能在录音卡要求的 5 秒内发送配对指令，请重新连接。',
    'RECORDING_CARD_BINDING_REJECTED': '录音卡拒绝了本次配对，设备未提供具体原因；这不代表已绑定其他手机。',
    'RECORDING_CARD_BINDING_ACK_MALFORMED': '录音卡返回的配对结果格式异常，尚不能确认配对成功，请重新连接。',
    'RECORDING_CARD_BINDING_ACK_TIMEOUT': '配对指令已发送，但未收到录音卡确认，请重新连接。',
    'RECORDING_CARD_COMMAND_TIMEOUT': '录音卡未及时响应连接指令，请靠近录音卡后重试。',
    'RECORDING_CARD_WRITE_FAILED': '蓝牙未能发送连接指令，请重新连接。',
    'RECORDING_CARD_COMMAND_IN_PROGRESS': '录音卡仍有连接指令正在处理，请稍后重试。',
    'RECORDING_CARD_DISCONNECTED': '连接过程中蓝牙已断开，请确认录音卡状态后重新搜索。',
    'RECORDING_CARD_BINDING_CONFLICT': '录音卡配对未完成，当前错误信息不足以判断绑定归属，请重新连接。',
  };
  for (final failure in handshakeFailures.entries) {
    testWidgets('chooser preserves ${failure.key} without claiming ownership', (
      tester,
    ) async {
      final channel = MethodChannel('connection_failure_${failure.key}');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'connect') {
          throw PlatformException(code: failure.key);
        }
        if (call.method == 'scanDevices') {
          return <String, Object?>{
            'devices': <Object?>[
              <String, Object?>{
                'displayName': '握手测试录音卡',
                'safeDeviceFingerprint': 'handshake-failure-card',
                'isConnectable': true,
              },
            ],
          };
        }
        return null;
      });
      final events = StreamController<Object?>();
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final controller = _controller(port);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        controller.dispose();
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(_dialogLauncher(controller, '检查连接错误'));
      await tester.tap(find.text('检查连接错误'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('recording-card-nearby-device-handshake-failure-card'),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.state.lastErrorCode, failure.key);
      expect(find.text(failure.value), findsOneWidget);
      expect(find.textContaining('请先在原手机中解除绑定'), findsNothing);
      expect(find.text('录音卡已连接'), findsNothing);
      expect(
        controller.state.snapshot.deviceState.isOperationallyConnected,
        isFalse,
      );
      await tester.tap(find.text('重新搜索'));
      await tester.pumpAndSettle();
      expect(calls.where((method) => method == 'scanDevices'), hasLength(2));
      expect(find.text(failure.value), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recording-card-connection-dialog')),
        findsNothing,
      );
      expect(
        calls.where((method) => method.toLowerCase().contains('unbind')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('chooser lists native discoveries and connects the tapped card', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('recording_card_connection_dialog_select');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'scanDevices' => <String, Object?>{
          'devices': <Object?>[
            <String, Object?>{
              'displayName': '同名录音卡',
              'safeDeviceFingerprint': 'dialog-card-a',
              'serialNumber': 'SP63A03003',
              'rssi': -47,
              'isConnectable': true,
            },
            <String, Object?>{
              'displayName': '同名录音卡',
              'safeDeviceFingerprint': 'dialog-card-b',
              'serialNumber': 'SP63A03004',
              'rssi': -61,
              'isConnectable': true,
            },
          ],
        },
        'connect' => <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': '同名录音卡',
          'safeDeviceFingerprint': 'dialog-card-b',
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
    final controller = _controller(port);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showV3RecordingCardConnectionDialog(
                  context,
                  controller: controller,
                  requireSerialConfirmation: true,
                ),
              ),
              child: const Text('打开连接弹窗'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开连接弹窗'));
    await tester.pump();
    final fade = find.byKey(const ValueKey('recording-card-connection-fade'));
    expect(
      find.byKey(const ValueKey('recording-card-connection-transition')),
      findsOneWidget,
    );
    expect(fade, findsOneWidget);
    expect(tester.widget<FadeTransition>(fade).opacity.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 260));
    expect(tester.widget<FadeTransition>(fade).opacity.value, closeTo(1, .001));
    await tester.pump();
    expect(find.text('同名录音卡'), findsNWidgets(2));
    expect(find.text('SN：SP63A03003'), findsOneWidget);
    expect(find.text('SN：SP63A03004'), findsOneWidget);
    expect(find.text('设备识别码 GCARDA · 信号强'), findsOneWidget);
    expect(find.text('设备识别码 GCARDB · 信号良好'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('recording-card-nearby-device-dialog-card-b')),
    );
    await tester.pump();
    expect(find.text('核对 SN 码'), findsOneWidget);
    expect(
      tester.getSize(
        find.byKey(const ValueKey('recording-card-connection-panel')),
      ),
      const Size(362, 532),
    );
    expect(calls.where((call) => call.method == 'connect'), isEmpty);

    await tester.tap(find.text('SN 一致，连接'));
    await tester.pump();
    await tester.pump();
    expect(find.text('录音卡已连接'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 520));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));

    expect(fade, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(fade).opacity.value,
      lessThanOrEqualTo(.01),
    );
    await tester.pumpAndSettle();

    final connect = calls.firstWhere((call) => call.method == 'connect');
    expect(
      (connect.arguments as Map<Object?, Object?>)['safeDeviceFingerprint'],
      'dialog-card-b',
    );
    expect(
      controller.state.snapshot.deviceState.isOperationallyConnected,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('recording-card-connection-dialog')),
      findsNothing,
    );
  });

  testWidgets('chooser keeps compact landscape actions reachable', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel(
      'recording_card_connection_dialog_compact_landscape',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanDevices') {
        return <String, Object?>{'devices': const <Object?>[]};
      }
      return null;
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = _controller(port);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      _dialogLauncher(
        controller,
        '打开紧凑横屏连接弹窗',
        textScaler: const TextScaler.linear(1.3),
      ),
    );
    await tester.tap(find.text('打开紧凑横屏连接弹窗'));
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('recording-card-connection-panel'));
    final cancel = find.byKey(
      const ValueKey('recording-card-connection-cancel'),
    );
    final rescan = find.byKey(
      const ValueKey('recording-card-connection-rescan'),
    );
    expect(tester.getSize(panel), const Size(362, 296));
    expect(tester.getTopLeft(panel).dy, 12);
    expect(tester.getBottomRight(panel).dy, 308);
    expect(cancel.hitTestable(), findsOneWidget);
    expect(rescan.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(cancel);
    await tester.pumpAndSettle();
  });

  testWidgets('chooser waits for cloud authorization before showing success', (
    tester,
  ) async {
    const channel = MethodChannel(
      'recording_card_connection_dialog_cloud_gate',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'scanDevices' => <String, Object?>{
          'devices': <Object?>[
            <String, Object?>{
              'displayName': '云端校验录音卡',
              'safeDeviceFingerprint': 'cloud-gate-card',
              'isConnectable': true,
            },
          ],
        },
        'connect' => <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': '云端校验录音卡',
          'safeDeviceFingerprint': 'cloud-gate-card',
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
    final authorization = _FakeConnectionAuthorization.pending();
    final controller = _controller(
      port,
      connectionAuthorization: authorization,
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(_dialogLauncher(controller, '打开云端校验弹窗'));
    await tester.tap(find.text('打开云端校验弹窗'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    await tester.tap(
      find.byKey(
        const ValueKey('recording-card-nearby-device-cloud-gate-card'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('正在验证录音卡'), findsOneWidget);
    expect(find.text('正在核验 SN 和账号归属'), findsOneWidget);
    expect(find.text('录音卡已连接'), findsNothing);
    expect(controller.state.status, RecordingCardControllerStatus.authorizing);

    authorization.completeSuccess();
    await tester.pump();
    await tester.pump();

    expect(find.text('录音卡已连接'), findsOneWidget);
    expect(controller.state.status, RecordingCardControllerStatus.idle);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
  });

  testWidgets('chooser keeps cloud ownership rejection visible', (
    tester,
  ) async {
    const channel = MethodChannel(
      'recording_card_connection_dialog_cloud_rejection',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'scanDevices' => <String, Object?>{
          'devices': <Object?>[
            <String, Object?>{
              'displayName': '他人录音卡',
              'safeDeviceFingerprint': 'other-account-card',
              'isConnectable': true,
            },
          ],
        },
        'connect' => <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': '他人录音卡',
          'safeDeviceFingerprint': 'other-account-card',
        },
        'disconnect' => <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
        },
        _ => null,
      };
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = _controller(
      port,
      connectionAuthorization: _FakeConnectionAuthorization.failure(
        'RECORDING_CARD_ALREADY_BOUND',
      ),
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(_dialogLauncher(controller, '打开归属校验弹窗'));
    await tester.tap(find.text('打开归属校验弹窗'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    await tester.tap(
      find.byKey(
        const ValueKey('recording-card-nearby-device-other-account-card'),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('该录音卡已绑定其他账号，不会进行连接。'), findsOneWidget);
    expect(controller.state.lastErrorCode, 'RECORDING_CARD_ALREADY_BOUND');
    expect(
      controller.state.snapshot.deviceState.isOperationallyConnected,
      isFalse,
    );
    await tester.pumpAndSettle();
  });

  testWidgets(
    'chooser accepts an external connection while its scan is still active',
    (tester) async {
      const channel = MethodChannel(
        'recording_card_connection_dialog_external_completion',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final scan = Completer<Object?>();
      final fileScan = Completer<Object?>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'scanDevices' => scan.future,
          'scanFiles' => fileScan.future,
          _ => null,
        };
      });
      final events = StreamController<Object?>();
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final controller = _controller(port);
      addTearDown(() async {
        if (!scan.isCompleted) {
          scan.complete(<String, Object?>{'devices': <Object?>[]});
        }
        if (!fileScan.isCompleted) {
          fileScan.complete(<String, Object?>{'files': <Object?>[]});
        }
        messenger.setMockMethodCallHandler(channel, null);
        controller.dispose();
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(_dialogLauncher(controller, '打开后台连接弹窗'));
      await tester.tap(find.text('打开后台连接弹窗'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump();

      expect(controller.state.status, RecordingCardControllerStatus.scanning);
      events.add(<String, Object?>{
        'type': 'runtime_snapshot',
        'snapshot': <String, Object?>{
          'deviceState': <String, Object?>{
            'connectionState': 'ble_ready',
            'connectionStage': 'connected',
            'displayName': '后台恢复录音卡',
            'safeDeviceFingerprint': 'external-connected-card',
          },
          'recordingInfo': <String, Object?>{'state': 'idle'},
          'files': <Object?>[],
        },
      });
      await tester.pump();
      await tester.pump();

      expect(
        controller.state.snapshot.deviceState.isOperationallyConnected,
        isTrue,
      );
      expect(
        controller.state.status,
        isNot(RecordingCardControllerStatus.idle),
      );
      expect(find.text('录音卡已连接'), findsOneWidget);
      expect(find.text('后台恢复录音卡 已准备就绪'), findsOneWidget);

      scan.complete(<String, Object?>{'devices': <Object?>[]});
      for (var pumpCount = 0; pumpCount < 10; pumpCount += 1) {
        if (calls.any((call) => call.method == 'scanFiles')) break;
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(calls.map((call) => call.method), contains('scanFiles'));
      expect(controller.isRefreshingFiles, isTrue);

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recording-card-connection-dialog')),
        findsNothing,
      );
      expect(calls.where((call) => call.method == 'cancelDiscovery'), isEmpty);

      fileScan.complete(<String, Object?>{'files': <Object?>[]});
      await tester.pump();
      await tester.pump();
      expect(controller.hasLoadedFilesForCurrentConnection, isTrue);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'chooser skips presentation motion when animations are disabled',
    (tester) async {
      const channel = MethodChannel('recording_card_connection_dialog_reduced');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'scanDevices' => <String, Object?>{'devices': <Object?>[]},
          'scanFiles' => <String, Object?>{'files': <Object?>[]},
          _ => null,
        };
      });
      final events = StreamController<Object?>();
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final controller = _controller(port);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        controller.dispose();
        await port.dispose();
        await events.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: HuahuoV3Theme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  showV3RecordingCardConnectionDialog(
                    context,
                    controller: controller,
                  ),
                ),
                child: const Text('打开减少动态连接弹窗'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开减少动态连接弹窗'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('recording-card-connection-transition')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recording-card-connection-fade')),
        findsNothing,
      );
      expect(find.text('选择录音卡'), findsOneWidget);
      expect(calls.map((call) => call.method), contains('scanDevices'));

      await tester.tap(
        find.byKey(const ValueKey('recording-card-connection-cancel')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recording-card-connection-dialog')),
        findsNothing,
      );
    },
  );

  testWidgets('chooser automatically reconnects one unique cached SN card', (
    tester,
  ) async {
    const channel = MethodChannel('recording_card_connection_dialog_auto');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'scanDevices' => <String, Object?>{
          'devices': <Object?>[
            <String, Object?>{
              'displayName': '我的录音卡',
              'safeDeviceFingerprint': 'remembered-card',
              'serialNumber': 'SP63A03003',
              'isConnectable': true,
            },
          ],
        },
        'connect' => <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'displayName': '我的录音卡',
          'safeDeviceFingerprint': 'remembered-card',
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
    final controller = _controller(
      port,
      connectionAuthorization: const _CachedSnAuthorization('SP63A03003'),
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showV3RecordingCardConnectionDialog(
                  context,
                  controller: controller,
                ),
              ),
              child: const Text('连接'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('连接'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 560));

    expect(
      calls.map((call) => call.method),
      containsAll(<String>['scanDevices', 'connect']),
    );
    expect(
      (calls.firstWhere((call) => call.method == 'connect').arguments
          as Map<Object?, Object?>)['safeDeviceFingerprint'],
      'remembered-card',
    );
    expect(
      (calls.firstWhere((call) => call.method == 'connect').arguments
          as Map<Object?, Object?>)['expectedSerialNumber'],
      'SP63A03003',
    );
  });

  testWidgets('chooser does not auto-connect duplicate cached SN rows', (
    tester,
  ) async {
    const channel = MethodChannel(
      'recording_card_connection_dialog_duplicate_sn',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'scanDevices') {
        return <String, Object?>{
          'devices': <Object?>[
            for (final fingerprint in <String>['duplicate-a', 'duplicate-b'])
              <String, Object?>{
                'displayName': '同序列号录音卡',
                'safeDeviceFingerprint': fingerprint,
                'serialNumber': 'SP63A03003',
                'isConnectable': true,
              },
          ],
        };
      }
      return null;
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = _controller(
      port,
      connectionAuthorization: const _CachedSnAuthorization('SP63A03003'),
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(_dialogLauncher(controller, '连接重复 SN'));
    await tester.tap(find.text('连接重复 SN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('SN：SP63A03003'), findsNWidgets(2));
    expect(calls.where((call) => call.method == 'connect'), isEmpty);
  });

  testWidgets('Bluetooth activation retries discovery after system approval', (
    tester,
  ) async {
    const recordingChannel = MethodChannel(
      'recording_card_connection_dialog_bluetooth_activation',
    );
    const permissionChannel = MethodChannel(
      'recording_card_connection_dialog_platform_permissions',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var scanCalls = 0;
    var activationCalls = 0;
    messenger.setMockMethodCallHandler(recordingChannel, (call) async {
      if (call.method != 'scanDevices') return null;
      scanCalls += 1;
      if (scanCalls == 1) {
        throw PlatformException(code: 'RECORDING_CARD_BLUETOOTH_POWERED_OFF');
      }
      return <String, Object?>{'devices': const <Object?>[]};
    });
    messenger.setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'requestBluetoothActivation') {
        activationCalls += 1;
        return 'enabled';
      }
      return null;
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: recordingChannel,
      nativeEvents: events.stream,
    );
    final controller = _controller(port);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(recordingChannel, null);
      messenger.setMockMethodCallHandler(permissionChannel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      _dialogLauncher(
        controller,
        '连接蓝牙关闭的录音卡',
        permissions: const MethodChannelPlatformPermissionsPort(
          channel: permissionChannel,
          isAndroid: true,
        ),
      ),
    );
    await tester.tap(find.text('连接蓝牙关闭的录音卡'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();

    expect(find.text('打开蓝牙'), findsWidgets);
    await tester.tap(find.text('打开蓝牙').last);
    await tester.pump();
    await tester.pump();

    expect(activationCalls, 1);
    expect(scanCalls, 2);
    await tester.pumpAndSettle();
  });

  testWidgets('denied Bluetooth permission opens application settings', (
    tester,
  ) async {
    const recordingChannel = MethodChannel(
      'recording_card_connection_dialog_permission_denied',
    );
    const permissionChannel = MethodChannel(
      'recording_card_connection_dialog_permission_settings',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(recordingChannel, (call) async {
      if (call.method == 'scanDevices') {
        throw PlatformException(
          code: 'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED',
        );
      }
      return null;
    });
    var settingsCalls = 0;
    messenger.setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'openAppSettings') {
        settingsCalls += 1;
        return true;
      }
      return null;
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: recordingChannel,
      nativeEvents: events.stream,
    );
    final controller = _controller(port);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(recordingChannel, null);
      messenger.setMockMethodCallHandler(permissionChannel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      _dialogLauncher(
        controller,
        '连接未授权的录音卡',
        permissions: const MethodChannelPlatformPermissionsPort(
          channel: permissionChannel,
          isAndroid: true,
        ),
      ),
    );
    await tester.tap(find.text('连接未授权的录音卡'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();

    expect(find.text('授权蓝牙'), findsOneWidget);
    await tester.tap(find.text('授权蓝牙'));
    await tester.pump();

    expect(settingsCalls, 1);
  });

  testWidgets('legacy Android location failure shows recovery guidance', (
    tester,
  ) async {
    const channel = MethodChannel(
      'recording_card_connection_dialog_legacy_location',
    );
    const permissionChannel = MethodChannel(
      'recording_card_connection_dialog_legacy_location_permissions',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanDevices') {
        throw PlatformException(
          code: 'RECORDING_CARD_LOCATION_SERVICES_DISABLED',
        );
      }
      return null;
    });
    var settingsCalls = 0;
    messenger.setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'openBluetoothSettings') {
        settingsCalls += 1;
        expect(call.arguments, <String, Object?>{
          'target': 'location_services',
        });
        return true;
      }
      return null;
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = _controller(port);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(permissionChannel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(
      _dialogLauncher(
        controller,
        '连接旧版安卓录音卡',
        permissions: const MethodChannelPlatformPermissionsPort(
          channel: permissionChannel,
          isAndroid: true,
        ),
      ),
    );
    await tester.tap(find.text('连接旧版安卓录音卡'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();

    expect(
      find.text('Android 7～11 需要开启系统定位服务才能搜索录音卡，请开启后重新搜索。'),
      findsOneWidget,
    );
    expect(find.text('开启定位服务'), findsOneWidget);
    await tester.tap(find.text('开启定位服务'));
    await tester.pump();
    expect(settingsCalls, 1);
    expect(find.text('重新搜索'), findsOneWidget);
  });

  testWidgets('unsupported Bluetooth is terminal and closes without retry', (
    tester,
  ) async {
    const channel = MethodChannel(
      'recording_card_connection_dialog_bluetooth_unsupported',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanDevices') {
        throw PlatformException(code: 'RECORDING_CARD_BLUETOOTH_UNSUPPORTED');
      }
      return null;
    });
    final events = StreamController<Object?>();
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final controller = _controller(port);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      controller.dispose();
      await port.dispose();
      await events.close();
    });

    await tester.pumpWidget(_dialogLauncher(controller, '连接不支持蓝牙的设备'));
    await tester.tap(find.text('连接不支持蓝牙的设备'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();

    expect(find.text('当前设备不支持蓝牙连接'), findsOneWidget);
    expect(find.text('当前设备不支持低功耗蓝牙（BLE），无法搜索或连接录音卡。'), findsOneWidget);
    expect(find.text('重新搜索'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recording-card-connection-dialog')),
      findsNothing,
    );
  });
}

RecordingCardController _controller(
  RecordingCardPort port, {
  RecordingCardConnectionHistoryPort? history,
  RecordingCardConnectionAuthorizationPort? connectionAuthorization,
}) {
  return RecordingCardController(
    port: port,
    localRecordingRepository: LocalRecordingRepository(
      database: AppDatabase(),
      fileStorage: const UnavailableFileStoragePort(),
    ),
    platformPermissionsPort: const _GrantedPermissionsPort(),
    bindingTokenProvider: _bindingToken,
    connectionAuthorization: connectionAuthorization,
    connectionHistory: history,
    requiresBluetoothPermissionRequest: () => false,
  );
}

Widget _dialogLauncher(
  RecordingCardController controller,
  String label, {
  PlatformPermissionsPort permissions = const _GrantedPermissionsPort(),
  TextScaler? textScaler,
}) {
  return MaterialApp(
    theme: HuahuoV3Theme.light(),
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => unawaited(
            showV3RecordingCardConnectionDialog(
              context,
              controller: controller,
              permissions: permissions,
            ),
          ),
          child: Text(label),
        ),
      ),
    ),
  );
}

final class _FakeConnectionAuthorization
    implements RecordingCardConnectionAuthorizationPort {
  _FakeConnectionAuthorization._(this._result, this._pending);

  factory _FakeConnectionAuthorization.pending() =>
      _FakeConnectionAuthorization._(
        RecordingCardResult<bool>.success(true),
        Completer<RecordingCardResult<bool>>(),
      );

  factory _FakeConnectionAuthorization.failure(String code) =>
      _FakeConnectionAuthorization._(
        RecordingCardResult<bool>.failure(
          recordingCardFailure(code, 'Cloud authorization rejected the card'),
        ),
        null,
      );

  final RecordingCardResult<bool> _result;
  final Completer<RecordingCardResult<bool>>? _pending;

  @override
  Future<RecordingCardResult<bool>> authorizeConnection(
    RecordingCardDeviceState device,
  ) => _pending?.future ?? Future.value(_result);

  void completeSuccess() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.complete(RecordingCardResult<bool>.success(true));
    }
  }
}

final class _CachedSnAuthorization
    implements
        RecordingCardConnectionAuthorizationPort,
        RecordingCardDiscoveryAuthorizationPort {
  const _CachedSnAuthorization(this.serialNumber);

  final String serialNumber;

  @override
  Future<RecordingCardResult<bool>> authorizeConnection(
    RecordingCardDeviceState device,
  ) async => RecordingCardResult<bool>.success(true);

  @override
  Future<RecordingCardResult<bool>> authorizeDiscoveredDevice({
    required String serialNumber,
    required String displayName,
  }) async =>
      RecordingCardResult<bool>.success(this.serialNumber == serialNumber);

  @override
  Future<RecordingCardResult<bool>> matchesCachedSerial(
    String serialNumber,
  ) async =>
      RecordingCardResult<bool>.success(this.serialNumber == serialNumber);
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
