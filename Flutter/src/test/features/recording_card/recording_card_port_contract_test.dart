import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecordingCardPort contract', () {
    for (final scenario in [
      (
        name: 'finds a committed file without BLE format',
        filename: '20260902123249',
        format: RecordingCardFileFormat.unknown,
        committedFormat: 'm4a',
        expectedFormats: ['mp3', 'opus', 'm4a'],
      ),
      (
        name: 'confirms an absent target without BLE format',
        filename: '20260902123249',
        format: RecordingCardFileFormat.unknown,
        committedFormat: null,
        expectedFormats: ['mp3', 'opus', 'm4a', 'wav'],
      ),
      (
        name: 'uses the persisted source format',
        filename: '20260902123249',
        format: RecordingCardFileFormat.wav,
        committedFormat: null,
        expectedFormats: ['wav'],
      ),
      (
        name: 'uses a known filename extension',
        filename: '20260902123249.mp3',
        format: RecordingCardFileFormat.unknown,
        committedFormat: null,
        expectedFormats: ['mp3'],
      ),
    ]) {
      test('offline Wi-Fi recovery ${scenario.name}', () async {
        const channel = MethodChannel('huahuoai/offline_wifi_recovery');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>();
        final requestedFormats = <String>[];
        const target = 'card-22222222222222222222222222222222';
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'recoverWifiDownload');
          final arguments = call.arguments as Map;
          expect(arguments['plannedNativeFileId'], target);
          final format = arguments['format'] as String;
          requestedFormats.add(format);
          if (format != scenario.committedFormat) return {'exists': false};
          return {
            ..._downloadedMap(),
            'localFileId': target,
            'appPrivateUri': 'app-private://recording-card/$target.$format',
            'format': format,
          };
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        addTearDown(() async {
          await port.dispose();
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });

        final recovered = await port.recoverWifiDownload(
          RecordingCardScannedFile(
            deviceFileId: 'card-file-1',
            localFileKey: 'card-20260701090000',
            deviceFilename: scenario.filename,
            sizeBytes: 4096,
            format: scenario.format,
          ),
          nativeFileId: target,
        );

        expect(recovered.ok, isTrue, reason: recovered.error?.code);
        expect(requestedFormats, scenario.expectedFormats);
        expect(
          recovered.value?.file?.localFileId,
          scenario.committedFormat == null ? isNull : target,
        );
      });
    }

    for (final malformed in [false, true]) {
      test(
        'offline Wi-Fi recovery preserves ${malformed ? 'malformed receipts' : 'native errors'}',
        () async {
          const channel = MethodChannel('huahuoai/offline_wifi_recovery_error');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final events = StreamController<Object?>();
          var lookups = 0;
          messenger.setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'recoverWifiDownload');
            lookups += 1;
            if (malformed) return <String, Object?>{};
            throw PlatformException(
              code: 'RECORDING_CARD_WIFI_UNLOCK_REQUIRED',
            );
          });
          final port = MethodChannelRecordingCardPort(
            methodChannel: channel,
            nativeEvents: events.stream,
          );
          addTearDown(() async {
            await port.dispose();
            messenger.setMockMethodCallHandler(channel, null);
            await events.close();
          });

          final recovered = await port.recoverWifiDownload(
            _file(),
            nativeFileId: 'card-22222222222222222222222222222222',
          );

          expect(recovered.ok, isFalse);
          expect(lookups, 1);
          expect(recovered.value, isNull);
          if (!malformed) {
            expect(
              recovered.error?.code,
              'RECORDING_CARD_WIFI_UNLOCK_REQUIRED',
            );
          }
        },
      );
    }

    test(
      'Wi-Fi recovery channel carries attempt and stable target through teardown',
      () async {
        const channel = MethodChannel('huahuoai/wifi_recovery_contract');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>();
        final calls = <MethodCall>[];
        const target = 'card-11111111111111111111111111111111';
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'beginWifiAttempt':
            case 'closeWifiSession':
            case 'cancelWifiSession':
            case 'settleWifiRecovery':
              return true;
            case 'verifyWifiHandoff':
              return <String, Object?>{'status': 'ready'};
            case 'queryWifiSession':
              return {
                'batchId': 'batch-one',
                'attemptId': 'attempt-one',
                'active': true,
              };
            case 'recoverWifiDownload':
              return {'exists': false};
            case 'downloadFileInWifiSession':
              return _downloadedMap();
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        addTearDown(() async {
          await port.dispose();
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });
        expect(
          (await port.beginWifiAttempt(
            batchId: 'batch-one',
            attemptId: 'attempt-one',
          )).ok,
          isTrue,
        );
        expect(
          (await port.verifyWifiHandoff()).value?.status,
          RecordingCardWifiHandoffStatus.ready,
        );
        expect((await port.queryWifiSession()).value!.active, isTrue);
        expect(
          (await port.recoverWifiDownload(
            _file(),
            nativeFileId: target,
          )).value!.file,
          isNull,
        );
        await port.downloadRecoverableWifiFile(_file(), nativeFileId: target);
        await port.closeWifiSession();
        expect(
          (await port.settleWifiRecovery(
            batchId: 'batch-one',
            attemptId: 'attempt-one',
            safeDeviceFingerprint: 'card-fingerprint-one',
          )).ok,
          isTrue,
        );
        await port.cancelWifiSession();
        for (final call in calls.where(
          (call) =>
              call.method != 'recoverWifiDownload' &&
              call.method != 'cancelWifiSession',
        )) {
          final arguments = call.arguments as Map;
          expect(arguments['recoveryBatchId'], 'batch-one');
          expect(arguments['attemptId'], 'attempt-one');
        }
        expect(
          calls
              .singleWhere((call) => call.method == 'cancelWifiSession')
              .arguments,
          isEmpty,
        );
        final download = calls.singleWhere(
          (call) => call.method == 'downloadFileInWifiSession',
        );
        expect((download.arguments as Map)['plannedNativeFileId'], target);
        expect(
          calls
              .singleWhere((call) => call.method == 'settleWifiRecovery')
              .arguments,
          <String, Object?>{
            'recoveryBatchId': 'batch-one',
            'attemptId': 'attempt-one',
            'safeDeviceFingerprint': 'card-fingerprint-one',
          },
        );
        final observed = <RecordingCardWifiSessionObservation>[];
        final subscription = port.subscribeWifiSession(observed.add);
        events.add({
          'type': 'wifi_session',
          'batchId': 'batch-one',
          'attemptId': 'attempt-one',
          'active': false,
          'failureCode': 'RECORDING_CARD_WIFI_BACKGROUND_EXPIRED',
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          observed.single.failureCode,
          'RECORDING_CARD_WIFI_BACKGROUND_EXPIRED',
        );
        subscription.unsubscribe();
      },
    );

    test(
      'rejected Wi-Fi begin restores prior owner and failed close retains it for cancel',
      () async {
        const channel = MethodChannel(
          'huahuoai/wifi_attempt_transaction_contract',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>();
        final terminalArguments = <Map<Object?, Object?>>[];
        Map<Object?, Object?>? verificationArguments;
        var beginCalls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'beginWifiAttempt':
              beginCalls += 1;
              if (beginCalls == 2) {
                throw PlatformException(
                  code: 'RECORDING_CARD_WIFI_SESSION_BUSY',
                );
              }
              return true;
            case 'closeWifiSession':
              terminalArguments.add(
                Map<Object?, Object?>.from(call.arguments! as Map),
              );
              throw PlatformException(
                code: 'RECORDING_CARD_WIFI_SESSION_CLOSE_FAILED',
              );
            case 'cancelWifiSession':
              terminalArguments.add(
                Map<Object?, Object?>.from(call.arguments! as Map),
              );
              return true;
            case 'verifyWifiHandoff':
              verificationArguments = Map<Object?, Object?>.from(
                call.arguments! as Map,
              );
              return <String, Object?>{'status': 'ready'};
            case 'disconnect':
              return <String, Object?>{
                'connectionState': 'disconnected',
                'connectionStage': 'idle',
              };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        addTearDown(() async {
          await port.dispose();
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });

        expect(
          (await port.beginWifiAttempt(
            batchId: 'batch-old',
            attemptId: 'attempt-old',
          )).ok,
          isTrue,
        );
        final rejected = await port.beginWifiAttempt(
          batchId: 'batch-new',
          attemptId: 'attempt-new',
        );
        expect(rejected.ok, isFalse);
        expect(rejected.error?.code, 'RECORDING_CARD_WIFI_SESSION_BUSY');

        expect((await port.closeWifiSession()).ok, isFalse);
        expect((await port.cancelWifiSession()).value, isTrue);
        expect(terminalArguments, <Map<Object?, Object?>>[
          <Object?, Object?>{
            'recoveryBatchId': 'batch-old',
            'attemptId': 'attempt-old',
          },
          <Object?, Object?>{
            'recoveryBatchId': 'batch-old',
            'attemptId': 'attempt-old',
          },
        ]);

        expect((await port.verifyWifiHandoff()).ok, isTrue);
        expect(verificationArguments, isEmpty);
      },
    );

    for (final terminalMethod in <String>[
      'closeWifiSession',
      'cancelWifiSession',
    ]) {
      test(
        'late $terminalMethod success does not clear a newer Wi-Fi owner',
        () async {
          final channel = MethodChannel(
            'huahuoai/wifi_attempt_late_${terminalMethod.toLowerCase()}',
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final events = StreamController<Object?>();
          final terminalStarted = Completer<void>();
          final terminalResult = Completer<Object?>();
          Map<Object?, Object?>? verificationArguments;
          messenger.setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'beginWifiAttempt':
                return true;
              case 'closeWifiSession':
              case 'cancelWifiSession':
                if (call.method == terminalMethod) {
                  terminalStarted.complete();
                  return terminalResult.future;
                }
                return true;
              case 'verifyWifiHandoff':
                verificationArguments = Map<Object?, Object?>.from(
                  call.arguments! as Map,
                );
                return <String, Object?>{'status': 'ready'};
              case 'disconnect':
                return <String, Object?>{
                  'connectionState': 'disconnected',
                  'connectionStage': 'idle',
                };
            }
            return null;
          });
          final port = MethodChannelRecordingCardPort(
            methodChannel: channel,
            nativeEvents: events.stream,
          );
          addTearDown(() async {
            await port.dispose();
            messenger.setMockMethodCallHandler(channel, null);
            await events.close();
          });

          expect(
            (await port.beginWifiAttempt(
              batchId: 'batch-old',
              attemptId: 'attempt-old',
            )).ok,
            isTrue,
          );
          final terminal = terminalMethod == 'closeWifiSession'
              ? port.closeWifiSession()
              : port.cancelWifiSession();
          await terminalStarted.future;
          expect(
            (await port.beginWifiAttempt(
              batchId: 'batch-new',
              attemptId: 'attempt-new',
            )).ok,
            isTrue,
          );
          terminalResult.complete(true);
          expect((await terminal).value, isTrue);

          expect((await port.verifyWifiHandoff()).ok, isTrue);
          expect(verificationArguments, <Object?, Object?>{
            'recoveryBatchId': 'batch-new',
            'attemptId': 'attempt-new',
          });
        },
      );
    }

    test(
      'recoverable Bluetooth channel preserves the planned native id',
      () async {
        const channel = MethodChannel('huahuoai/bluetooth_recovery_contract');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>();
        final calls = <MethodCall>[];
        const target = 'card-22222222222222222222222222222222';
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'recoverBluetoothDownload' => <String, Object?>{'exists': false},
            'downloadRecoverableBluetoothFile' => _downloadedMap(),
            _ => null,
          };
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        addTearDown(() async {
          await port.dispose();
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });

        final recovered = await port.recoverBluetoothDownload(
          _file(),
          plannedNativeFileId: target,
        );
        final downloaded = await port.downloadRecoverableBluetoothFile(
          _file(),
          plannedNativeFileId: target,
        );

        expect(recovered.ok, isTrue);
        expect(recovered.value?.file, isNull);
        expect(downloaded.ok, isTrue);
        expect(calls.map((call) => call.method), <String>[
          'recoverBluetoothDownload',
          'downloadRecoverableBluetoothFile',
        ]);
        for (final call in calls) {
          expect((call.arguments as Map)['plannedNativeFileId'], target);
        }
      },
    );

    test(
      'recording timeline rebases duration samples and remains idempotent',
      () {
        final start = DateTime.utc(2026, 9, 7, 9);
        var revision = 0;
        RecordingCardRecordingObservation observation(
          RecordingCardRecordingInfo info,
          int seconds,
        ) => RecordingCardRecordingObservation(
          info: info,
          source: RecordingCardObservationSource.statusNotification,
          revision: ++revision,
          observedAt: start.add(Duration(seconds: seconds)),
        );
        var current = mergeRecordingCardRecordingObservation(
          RecordingCardRecordingInfo.idle(),
          observation(
            const RecordingCardRecordingInfo(
              state: RecordingCardRecordingState.recording,
              currentFileName: '20990101000000.m4a',
            ),
            0,
          ),
        );
        expect(current.startedAt, start);
        current = mergeRecordingCardRecordingObservation(
          current,
          observation(
            const RecordingCardRecordingInfo(
              state: RecordingCardRecordingState.recording,
              durationSeconds: 12,
            ),
            10,
          ),
        );
        expect(
          recordingCardElapsedSeconds(
            current,
            now: start.add(const Duration(seconds: 15)),
          ),
          17,
        );
        final normalized = observation(current, 10);
        current = mergeRecordingCardRecordingObservation(current, normalized);
        expect(
          recordingCardElapsedSeconds(
            current,
            now: start.add(const Duration(seconds: 15)),
          ),
          17,
        );
        current = mergeRecordingCardRecordingObservation(
          current,
          observation(
            const RecordingCardRecordingInfo(
              state: RecordingCardRecordingState.paused,
            ),
            15,
          ),
        );
        expect(current.durationSeconds, 17);
        expect(current.startedAt, isNull);
        current = mergeRecordingCardRecordingObservation(
          current,
          observation(
            const RecordingCardRecordingInfo(
              state: RecordingCardRecordingState.recording,
            ),
            40,
          ),
        );
        expect(
          recordingCardElapsedSeconds(
            current,
            now: start.add(const Duration(seconds: 45)),
          ),
          22,
        );
        current = mergeRecordingCardRecordingObservation(
          current,
          observation(
            const RecordingCardRecordingInfo(
              state: RecordingCardRecordingState.recording,
              currentFileName: 'new-session.m4a',
            ),
            50,
          ),
        );
        expect(current.startedAt, start.add(const Duration(seconds: 50)));
        expect(current.durationSeconds, 0);
      },
    );

    test(
      'physical start notification publishes immediately without filename time guessing',
      () async {
        final now = DateTime.utc(2026, 9, 7, 9);
        final events = StreamController<Object?>(sync: true);
        final port = MethodChannelRecordingCardPort(
          nativeEvents: events.stream,
          clock: () => now,
        );
        addTearDown(() async {
          await port.dispose();
          await events.close();
        });
        events.add(<String, Object?>{
          'type': 'connection_state',
          'deviceState': _connectedDeviceMap(),
        });
        var observedRecording = false;
        final subscription = port.subscribeRuntimeSnapshot((snapshot) {
          observedRecording =
              snapshot.recordingInfo.state ==
              RecordingCardRecordingState.recording;
        });
        addTearDown(subscription.unsubscribe);
        events.add(<String, Object?>{
          'type': 'recording_state',
          'recordingInfo': <String, Object?>{
            'state': 'recording',
            'currentFileName': '20990101000000.m4a',
            'revision': 50,
            'observedAt': now.toIso8601String(),
          },
        });
        expect(observedRecording, isTrue);
        expect(port.runtimeSnapshot.recordingInfo.startedAt, now);
        expect(
          recordingCardElapsedSeconds(
            port.runtimeSnapshot.recordingInfo,
            now: now.add(const Duration(seconds: 8)),
          ),
          8,
        );
      },
    );

    test(
      'new card runtime recording revision cannot inherit the previous timer',
      () async {
        var now = DateTime.utc(2026, 9, 7, 9);
        final events = StreamController<Object?>(sync: true);
        final port = MethodChannelRecordingCardPort(
          nativeEvents: events.stream,
          clock: () => now,
        );
        addTearDown(() async {
          await port.dispose();
          await events.close();
        });
        events.add(
          _runtimeEvent(
            recordingInfo: <String, Object?>{
              'state': 'recording',
              'revision': 50,
              'observedAt': now.toIso8601String(),
            },
          ),
        );
        now = now.add(const Duration(seconds: 90));
        events.add(<String, Object?>{
          'type': 'runtime_snapshot',
          'snapshot': <String, Object?>{
            'deviceState': <String, Object?>{
              ..._connectedDeviceMap(),
              'safeDeviceFingerprint': 'replacement-recording-card',
            },
            'recordingInfo': <String, Object?>{
              'state': 'recording',
              'revision': 1,
              'observedAt': now.toIso8601String(),
            },
          },
        });
        expect(port.runtimeSnapshot.recordingObservation?.revision, 1);
        expect(port.runtimeSnapshot.recordingInfo.startedAt, now);
        expect(
          recordingCardElapsedSeconds(
            port.runtimeSnapshot.recordingInfo,
            now: now,
          ),
          0,
        );
      },
    );

    test('unavailable driver fails closed without fallback success', () async {
      const port = UnavailableRecordingCardPort();
      final file = _file();

      final connect = await port.connect();
      final devices = await port.scanDevices();
      final scan = await port.scanFiles();
      final download = await port.downloadFileToLocalCache(file);
      final deleted = await port.deleteFileFromDevice(file);
      final start = await port.startRecording();

      expect(connect.ok, isFalse);
      expect(connect.error?.code, 'NATIVE_RECORDING_CARD_DRIVER_UNAVAILABLE');
      expect(devices.ok, isFalse);
      expect(scan.ok, isFalse);
      expect(download.ok, isFalse);
      expect(deleted.ok, isFalse);
      expect(start.ok, isFalse);
      expect(
        port.runtimeSnapshot.deviceState.connectionState,
        RecordingCardConnectionState.error,
      );
      expect(port.runtimeSnapshot.files, isEmpty);
    });

    test('missing MethodChannel plugin maps to unavailable error', () async {
      final channel = MethodChannel(
        'huahuoai/recording_card_missing_${DateTime.now().microsecondsSinceEpoch}',
      );
      final port = MethodChannelRecordingCardPort(methodChannel: channel);

      final result = await port.connect();

      expect(result.ok, isFalse);
      expect(result.error?.code, 'NATIVE_RECORDING_CARD_DRIVER_UNAVAILABLE');
      await port.dispose();
    });

    test('disposing the port disconnects native before teardown', () async {
      const channel = MethodChannel(
        'huahuoai/recording_card_dispose_disconnect',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
        };
      });
      final port = MethodChannelRecordingCardPort(methodChannel: channel);

      await port.dispose();

      expect(calls, <String>['disconnect']);
      expect(
        port.runtimeSnapshot.deviceState.connectionState,
        RecordingCardConnectionState.disconnected,
      );
    });

    test(
      'foreground connection query never publishes or replaces a newer event',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_connection_query_owner',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>.broadcast();
        final lateQuery = Completer<Object?>();
        var queryCount = 0;
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getConnectionState') {
            queryCount += 1;
            return queryCount == 1 ? _connectedDeviceMap() : lateQuery.future;
          }
          if (call.method == 'disconnect') {
            return <String, Object?>{
              'connectionState': 'disconnected',
              'connectionStage': 'idle',
            };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        final observed = <RecordingCardConnectionState>[];
        final subscription = port.subscribeRuntimeSnapshot(
          (snapshot) => observed.add(snapshot.deviceState.connectionState),
        );

        final first = await port.getConnectionState();

        expect(first.ok, isTrue);
        expect(
          port.runtimeSnapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(observed, <RecordingCardConnectionState>[
          RecordingCardConnectionState.disconnected,
        ]);

        final staleQuery = port.getConnectionState();
        events.add(<String, Object?>{
          'type': 'connection_state',
          'connectionState': 'connected',
          'connectionStage': 'connected',
          'displayName': 'Huahuo FW920 B',
          'safeDeviceFingerprint': 'card-fingerprint-2',
        });
        await Future<void>.delayed(Duration.zero);
        lateQuery.complete(_connectedDeviceMap());
        final stale = await staleQuery;

        expect(stale.ok, isFalse);
        expect(stale.error?.code, 'RECORDING_CARD_CONNECTION_QUERY_STALE');
        expect(
          port.runtimeSnapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-2',
        );
        expect(observed.last, RecordingCardConnectionState.connected);

        subscription.unsubscribe();
        await port.dispose();
      },
    );

    test('a newer connection command owns the runtime snapshot', () async {
      const channel = MethodChannel(
        'huahuoai/recording_card_connection_command_owner',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final lateDisconnect = Completer<Object?>();
      var disconnectCalls = 0;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'connect') {
          final arguments = call.arguments as Map<Object?, Object?>?;
          return arguments?['safeDeviceFingerprint'] == 'card-fingerprint-2'
              ? _connectedDeviceBMap()
              : _connectedDeviceMap();
        }
        if (call.method == 'disconnect') {
          disconnectCalls += 1;
          return disconnectCalls == 1
              ? lateDisconnect.future
              : <String, Object?>{
                  'connectionState': 'disconnected',
                  'connectionStage': 'idle',
                };
        }
        return null;
      });
      final port = MethodChannelRecordingCardPort(methodChannel: channel);
      await port.connect();
      final observedFingerprints = <String?>[];
      final subscription = port.subscribeRuntimeSnapshot(
        (snapshot) => observedFingerprints.add(
          snapshot.deviceState.safeDeviceFingerprint,
        ),
      );

      final staleDisconnect = port.disconnect();
      await Future<void>.delayed(Duration.zero);
      final connectedB = await port.connect(
        request: const RecordingCardConnectRequest(
          safeDeviceFingerprint: 'card-fingerprint-2',
        ),
      );
      lateDisconnect.complete(<String, Object?>{
        'connectionState': 'disconnected',
        'connectionStage': 'idle',
      });
      final disconnectedA = await staleDisconnect;

      expect(connectedB.ok, isTrue);
      expect(disconnectedA.ok, isFalse);
      expect(
        disconnectedA.error?.code,
        'RECORDING_CARD_DEVICE_OPERATION_STALE',
      );
      expect(
        port.runtimeSnapshot.deviceState.safeDeviceFingerprint,
        'card-fingerprint-2',
      );
      expect(observedFingerprints, isNot(contains(null)));

      subscription.unsubscribe();
      await port.dispose();
    });

    test(
      'late download receipt cannot merge into a replacement card directory',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_download_device_session_owner',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>(sync: true);
        final downloadStarted = Completer<void>();
        final downloadResult = Completer<Object?>();
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'connect':
              final arguments = call.arguments as Map<Object?, Object?>?;
              return arguments?['safeDeviceFingerprint'] == 'card-fingerprint-2'
                  ? _connectedDeviceBMap()
                  : _connectedDeviceMap();
            case 'downloadFileToLocalCache':
              downloadStarted.complete();
              return downloadResult.future;
            case 'disconnect':
              return <String, Object?>{
                'connectionState': 'disconnected',
                'connectionStage': 'idle',
              };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        await port.connect();
        events.add(<String, Object?>{
          'type': 'runtime_snapshot',
          'snapshot': <String, Object?>{
            'deviceState': _connectedDeviceMap(),
            'recordingInfo': <String, Object?>{'state': 'idle'},
            'files': <Object?>[_fileMap()],
          },
        });
        final pendingDownload = port.downloadFileToLocalCache(
          port.runtimeSnapshot.files.single,
        );
        await downloadStarted.future;

        await port.connect(
          request: const RecordingCardConnectRequest(
            safeDeviceFingerprint: 'card-fingerprint-2',
          ),
        );
        events.add(<String, Object?>{
          'type': 'runtime_snapshot',
          'snapshot': <String, Object?>{
            'deviceState': _connectedDeviceBMap(),
            'recordingInfo': <String, Object?>{'state': 'idle'},
            'files': <Object?>[
              <String, Object?>{..._fileMap(), 'deviceFileId': 'card-b-file-1'},
            ],
          },
        });
        downloadResult.complete(_downloadedMap());

        final receipt = await pendingDownload;

        expect(receipt.ok, isTrue);
        expect(
          receipt.value?.appPrivateUri,
          'app-private://recording-card/card-20260701090000.m4a',
        );
        expect(
          port.runtimeSnapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-2',
        );
        final replacementFile = port.runtimeSnapshot.files.single;
        expect(replacementFile.deviceFileId, 'card-b-file-1');
        expect(
          replacementFile.syncState,
          RecordingCardFileSyncState.deviceOnly,
        );
        expect(replacementFile.localFileId, isNull);
        expect(replacementFile.appPrivateUri, isNull);

        await port.dispose();
      },
    );

    test(
      'connection change suppresses late device info and directory results',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_device_session_owner',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final lateInfo = Completer<Object?>();
        final lateFiles = Completer<Object?>();
        final lateRecording = Completer<Object?>();
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'connect') {
            final arguments = call.arguments as Map<Object?, Object?>?;
            return arguments?['safeDeviceFingerprint'] == 'card-fingerprint-2'
                ? _connectedDeviceBMap()
                : _connectedDeviceMap();
          }
          if (call.method == 'refreshDeviceInfo') return lateInfo.future;
          if (call.method == 'scanFiles') return lateFiles.future;
          if (call.method == 'readRecordingState') {
            return lateRecording.future;
          }
          if (call.method == 'disconnect') {
            return <String, Object?>{
              'connectionState': 'disconnected',
              'connectionStage': 'idle',
            };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);
        await port.connect();

        final info = port.refreshDeviceInfo();
        final files = port.scanFiles();
        final recording = port.readRecordingState();
        await Future<void>.delayed(Duration.zero);
        await port.connect(
          request: const RecordingCardConnectRequest(
            safeDeviceFingerprint: 'card-fingerprint-2',
          ),
        );
        lateInfo.complete(<String, Object?>{
          'deviceState': _connectedDeviceMap(),
          'recordingInfo': const <String, Object?>{'state': 'idle'},
          'files': const <Object?>[],
        });
        lateFiles.complete(<String, Object?>{
          'files': <Object?>[_fileMap()],
        });
        lateRecording.complete(const <String, Object?>{'state': 'recording'});

        final infoResult = await info;
        final fileResult = await files;
        final recordingResult = await recording;
        expect(infoResult.error?.code, 'RECORDING_CARD_DEVICE_SESSION_STALE');
        expect(fileResult.error?.code, 'RECORDING_CARD_DEVICE_SESSION_STALE');
        expect(
          recordingResult.error?.code,
          'RECORDING_CARD_DEVICE_SESSION_STALE',
        );
        expect(
          port.runtimeSnapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-2',
        );
        expect(port.runtimeSnapshot.files, isEmpty);
        expect(port.runtimeSnapshot.loadingFiles, isFalse);

        await port.dispose();
      },
    );

    test('newest same-session directory scan owns the runtime files', () async {
      const channel = MethodChannel(
        'huahuoai/recording_card_directory_scan_owner',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final lateOldDirectory = Completer<Object?>();
      var scanCalls = 0;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'connect') return _connectedDeviceMap();
        if (call.method == 'disconnect') {
          return <String, Object?>{
            'connectionState': 'disconnected',
            'connectionStage': 'idle',
          };
        }
        if (call.method == 'scanFiles') {
          scanCalls += 1;
          if (scanCalls == 1) return lateOldDirectory.future;
          return <String, Object?>{
            'files': <Object?>[
              <String, Object?>{
                ..._fileMap(),
                'deviceFileId': 'card-file-new',
                'localFileKey': 'card-20260701090100',
                'deviceFilename': '20260701090100',
              },
            ],
          };
        }
        return null;
      });
      final port = MethodChannelRecordingCardPort(methodChannel: channel);
      await port.connect();

      final oldScan = port.scanFiles();
      await Future<void>.delayed(Duration.zero);
      final newScan = await port.scanFiles();
      lateOldDirectory.complete(<String, Object?>{
        'files': <Object?>[_fileMap()],
      });
      final oldResult = await oldScan;

      expect(newScan.ok, isTrue);
      expect(oldResult.error?.code, 'RECORDING_CARD_DEVICE_SESSION_STALE');
      expect(port.runtimeSnapshot.files, hasLength(1));
      expect(port.runtimeSnapshot.files.single.deviceFileId, 'card-file-new');
      expect(port.runtimeSnapshot.loadingFiles, isFalse);

      await port.dispose();
    });

    test(
      'late device refresh preserves a newer same-session directory scan',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_refresh_directory_owner',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final lateDeviceInfo = Completer<Object?>();
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'connect') return _connectedDeviceMap();
          if (call.method == 'refreshDeviceInfo') return lateDeviceInfo.future;
          if (call.method == 'scanFiles') {
            return <String, Object?>{
              'files': <Object?>[
                <String, Object?>{
                  ..._fileMap(),
                  'deviceFileId': 'card-file-new',
                  'localFileKey': 'card-20260701090100',
                  'deviceFilename': '20260701090100',
                },
              ],
            };
          }
          if (call.method == 'disconnect') {
            return <String, Object?>{
              'connectionState': 'disconnected',
              'connectionStage': 'idle',
            };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);
        await port.connect();

        final oldRefresh = port.refreshDeviceInfo();
        await Future<void>.delayed(Duration.zero);
        final newScan = await port.scanFiles();
        lateDeviceInfo.complete(<String, Object?>{
          'deviceState': <String, Object?>{
            ..._connectedDeviceMap(),
            'displayName': 'Refreshed card',
          },
          'recordingInfo': const <String, Object?>{'state': 'paused'},
          'files': <Object?>[_fileMap()],
        });
        final refreshResult = await oldRefresh;

        expect(newScan.ok, isTrue);
        expect(refreshResult.ok, isTrue);
        expect(port.runtimeSnapshot.deviceState.displayName, 'Refreshed card');
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.paused,
        );
        expect(port.runtimeSnapshot.files, hasLength(1));
        expect(port.runtimeSnapshot.files.single.deviceFileId, 'card-file-new');
        expect(port.runtimeSnapshot.loadingFiles, isFalse);

        await port.dispose();
      },
    );

    test(
      'platform and malformed payload failures are explicit errors',
      () async {
        const channel = MethodChannel('huahuoai/recording_card_contract_fail');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'connect') {
            throw PlatformException(
              code: 'RECORDING_CARD_NOT_CONNECTED',
              message: 'GATT_ERROR hidden from UI',
            );
          }
          return <String, Object?>{
            'localFileKey': 'card-20260701090000',
            'appPrivateUri': 'file:///Users/run/raw.m4a',
          };
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);

        final connect = await port.connect();
        final download = await port.downloadFileToLocalCache(_file());

        expect(connect.ok, isFalse);
        expect(connect.error?.code, 'RECORDING_CARD_NOT_CONNECTED');
        expect(download.ok, isFalse);
        expect(download.error?.code, 'NATIVE_RECORDING_CARD_MALFORMED_PAYLOAD');
        await port.dispose();
      },
    );

    test(
      'force scan and unbind use explicit MethodChannel request fields',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_unbind_contract',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final calls = <String, Map<Object?, Object?>>{};
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls[call.method] =
              (call.arguments as Map<Object?, Object?>?) ?? const {};
          return switch (call.method) {
            'connect' => _connectedDeviceMap(),
            'scanFiles' => <String, Object?>{
              'files': <Object?>[_fileMap()],
            },
            'startRecording' => <String, Object?>{'state': 'recording'},
            'unbindDevice' => <String, Object?>{
              'connectionState': 'disconnected',
              'connectionStage': 'idle',
            },
            _ => null,
          };
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);
        const bindingToken = '00112233445566778899aabbccddeeff';

        final connected = await port.connect(
          request: const RecordingCardConnectRequest(
            safeDeviceFingerprint: 'card-fingerprint-1',
            expectedSerialNumber: 'SP63A03003',
            overallTimeoutMs: 15000,
            bindingTokenHex: bindingToken,
            forceScan: true,
          ),
        );
        await port.scanFiles();
        await port.startRecording();
        final unbound = await port.unbindDevice(
          bindingTokenHex: bindingToken,
          deleteDeviceFiles: true,
        );

        expect(connected.ok, isTrue);
        expect(calls['connect'], containsPair('forceScan', true));
        expect(calls['connect'], containsPair('bindingToken', bindingToken));
        expect(
          calls['connect'],
          containsPair('safeDeviceFingerprint', 'card-fingerprint-1'),
        );
        expect(
          calls['connect'],
          containsPair('expectedSerialNumber', 'SP63A03003'),
        );
        expect(calls['unbindDevice'], <Object?, Object?>{
          'bindingToken': bindingToken,
          'deleteDeviceFiles': true,
        });
        expect(unbound.ok, isTrue);
        expect(
          port.runtimeSnapshot.deviceState.connectionState,
          RecordingCardConnectionState.disconnected,
        );
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(port.runtimeSnapshot.files, isEmpty);
        expect(
          const RecordingCardConnectRequest().toChannelMap(),
          isNot(contains('forceScan')),
        );
        await port.dispose();
      },
    );

    test(
      'native unbind rejection preserves the connected runtime snapshot',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_unbind_rejected',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'connect' => _connectedDeviceMap(),
            'scanFiles' => <String, Object?>{
              'files': <Object?>[_fileMap()],
            },
            'unbindDevice' => throw PlatformException(
              code: 'RECORDING_CARD_UNBIND_REJECTED',
              message: 'Device rejected unbind',
            ),
            _ => null,
          };
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);
        const bindingToken = '00112233445566778899aabbccddeeff';
        await port.connect();
        await port.scanFiles();

        final result = await port.unbindDevice(bindingTokenHex: bindingToken);

        expect(result.ok, isFalse);
        expect(result.error?.code, 'RECORDING_CARD_UNBIND_REJECTED');
        expect(
          port.runtimeSnapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
        expect(port.runtimeSnapshot.files, hasLength(1));
        await port.dispose();
      },
    );

    test(
      'Bluetooth name uses a bounded UTF-8 MethodChannel request and preserves failures',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_bluetooth_name_contract',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final names = <String>[];
        var rejectNext = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'setBluetoothName') return null;
          final arguments = call.arguments as Map<Object?, Object?>;
          final name = arguments['bluetoothName'] as String;
          names.add(name);
          if (rejectNext) {
            throw PlatformException(
              code: 'RECORDING_CARD_BLUETOOTH_NAME_REJECTED',
            );
          }
          return <String, Object?>{
            ..._connectedDeviceMap(),
            'displayName': name,
          };
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);

        final renamed = await port.setBluetoothName(bluetoothName: '无限花火 A');

        expect(renamed.ok, isTrue);
        expect(names, <String>['无限花火 A']);
        expect(renamed.value?.displayName, '无限花火 A');
        expect(port.runtimeSnapshot.deviceState.displayName, '无限花火 A');

        rejectNext = true;
        final rejected = await port.setBluetoothName(bluetoothName: '花火录音卡');

        expect(rejected.ok, isFalse);
        expect(rejected.error?.code, 'RECORDING_CARD_BLUETOOTH_NAME_REJECTED');
        expect(port.runtimeSnapshot.deviceState.displayName, '无限花火 A');

        final invalidEmpty = await port.setBluetoothName(bluetoothName: '   ');
        final invalidControl = await port.setBluetoothName(
          bluetoothName: '花火\u0000录音卡',
        );
        final invalidOversized = await port.setBluetoothName(
          bluetoothName: '花' * 11,
        );

        expect(
          invalidEmpty.error?.code,
          'RECORDING_CARD_BLUETOOTH_NAME_INVALID',
        );
        expect(
          invalidControl.error?.code,
          'RECORDING_CARD_BLUETOOTH_NAME_INVALID',
        );
        expect(
          invalidOversized.error?.code,
          'RECORDING_CARD_BLUETOOTH_NAME_INVALID',
        );
        expect(names, <String>['无限花火 A', '花火录音卡']);
        expect(recordingCardBluetoothNameUtf8ByteLength('花' * 10), 30);
        expect(normalizeRecordingCardBluetoothName('花' * 10), isNotNull);
        expect(normalizeRecordingCardBluetoothName('花' * 11), isNull);
        await port.dispose();
      },
    );

    test(
      'account claim channel accepts only one opaque SHA-256 field',
      () async {
        const channel = MethodChannel('huahuoai/recording_card_claim_contract');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        var malformed = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'readAccountBindingClaim');
          return <String, Object?>{
            'opaqueClaim': malformed ? 'ABCDEF' : 'a' * 64,
          };
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);

        final result = await port.readAccountBindingClaim();

        expect(result.ok, isTrue);
        expect(result.value?.opaqueClaim, 'a' * 64);
        expect(port.runtimeSnapshot.deviceState.safeDeviceFingerprint, isNull);

        malformed = true;
        final rejected = await port.readAccountBindingClaim();
        expect(rejected.ok, isFalse);
        expect(rejected.error?.code, 'NATIVE_RECORDING_CARD_MALFORMED_PAYLOAD');
        await port.dispose();
      },
    );

    test(
      'SN ownership methods keep identity transient and proof strict',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_ownership_contract',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        const payloadJson =
            '{"protocolVersion":"recording-card-proof.v1","purpose":"bind"}';
        var rejectProof = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'readAccountBindingIdentity':
              expect(call.arguments, isNull);
              return <String, Object?>{'serialNumber': 'SNABC1234'};
            case 'signAccountBindingChallenge':
              expect(call.arguments, <String, Object?>{
                'payloadJson': payloadJson,
              });
              if (rejectProof) {
                throw PlatformException(
                  code: 'RECORDING_CARD_ATTESTATION_UNSUPPORTED',
                );
              }
              return <String, Object?>{
                'scheme': 'card-v1',
                'keyId': 'key_1',
                'signature': 'A' * 86,
              };
            default:
              throw StateError('unexpected ${call.method}');
          }
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);

        final identity = await port.readAccountBindingIdentity();
        final proof = await port.signAccountBindingChallenge(
          payloadJson: payloadJson,
        );

        expect(identity.value?.serialNumber, 'SNABC1234');
        expect(proof.value?.scheme, 'card-v1');
        expect(proof.value?.keyId, 'key_1');
        expect(port.runtimeSnapshot.deviceState.safeDeviceFingerprint, isNull);
        expect(port.runtimeSnapshot.toString(), isNot(contains('SNABC1234')));

        rejectProof = true;
        final unsupported = await port.signAccountBindingChallenge(
          payloadJson: payloadJson,
        );
        expect(unsupported.ok, isFalse);
        expect(
          unsupported.error?.code,
          'RECORDING_CARD_ATTESTATION_UNSUPPORTED',
        );
        await port.dispose();
      },
    );

    test('download result requires canonical private-library URI', () {
      final parsed = parseRecordingCardDownloadedFile(<String, Object?>{
        'localFileKey': 'card-20260701090000',
        'localFileId': 'card-20260701090000',
        'appPrivateUri': 'app-private://recordings/source.m4a',
        'sizeBytes': 4096,
      });

      expect(parsed, isNull);
    });

    test('directory rows retain suspect or missing size confidence', () {
      final suspect = parseRecordingCardScannedFile(<String, Object?>{
        'deviceFileId': 'card-file-suspect',
        'localFileKey': 'card-suspect',
        'deviceFilename': '20260701090001',
        'sizeBytes': 8192,
        'sizeConfidence': 'suspect',
      });
      final missing = parseRecordingCardScannedFile(<String, Object?>{
        'deviceFileId': 'card-file-missing',
        'localFileKey': 'card-missing',
        'deviceFilename': '20260701090002',
      });

      expect(suspect, isNotNull);
      expect(suspect!.sizeBytes, 8192);
      expect(suspect.sizeConfidence, RecordingCardFileSizeConfidence.suspect);
      expect(suspect.recordedAt, DateTime(2026, 7, 1, 9, 0, 1).toUtc());
      expect(suspect.recordedAt?.toLocal(), DateTime(2026, 7, 1, 9, 0, 1));
      expect(missing, isNotNull);
      expect(missing!.sizeBytes, isNull);
      expect(missing.sizeConfidence, isNull);
      expect(missing.recordedAt, DateTime(2026, 7, 1, 9, 0, 2).toUtc());
      expect(missing.recordedAt?.toLocal(), DateTime(2026, 7, 1, 9, 0, 2));
    });

    test('directory filename rejects an impossible recording date', () {
      final parsed = parseRecordingCardScannedFile(<String, Object?>{
        'deviceFileId': 'card-file-invalid-date',
        'localFileKey': 'card-invalid-date',
        'deviceFilename': '20260230090000',
      });

      expect(parsed, isNotNull);
      expect(parsed!.recordedAt, isNull);
    });

    test(
      'recording state tracks RN-style elapsed duration transitions',
      () async {
        var now = DateTime.utc(2026, 7, 12, 9);
        const channel = MethodChannel(
          'huahuoai/recording_card_recording_elapsed',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'connect':
              return _connectedDeviceMap();
            case 'startRecording':
            case 'resumeRecording':
              return <String, Object?>{'state': 'recording'};
            case 'pauseRecording':
              return <String, Object?>{'state': 'paused'};
            case 'stopRecording':
              return <String, Object?>{'state': 'idle'};
            case 'disconnect':
              return <String, Object?>{
                'connectionState': 'disconnected',
                'connectionStage': 'idle',
              };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          clock: () => now,
        );
        await port.connect();

        final started = await port.startRecording();
        expect(started.ok, isTrue);
        expect(started.value?.startedAt, now);
        expect(started.value, same(port.runtimeSnapshot.recordingInfo));
        expect(port.runtimeSnapshot.recordingInfo.startedAt, now);
        expect(
          recordingCardElapsedSeconds(
            port.runtimeSnapshot.recordingInfo,
            now: now,
          ),
          0,
        );

        now = now.add(const Duration(seconds: 72));
        final paused = await port.pauseRecording();
        expect(paused.ok, isTrue);
        expect(paused.value, same(port.runtimeSnapshot.recordingInfo));
        expect(paused.value?.durationSeconds, 72);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.paused,
        );
        expect(port.runtimeSnapshot.recordingInfo.startedAt, isNull);
        expect(port.runtimeSnapshot.recordingInfo.durationSeconds, 72);

        now = now.add(const Duration(seconds: 10));
        final resumed = await port.resumeRecording();
        expect(resumed.ok, isTrue);
        expect(resumed.value, same(port.runtimeSnapshot.recordingInfo));
        expect(resumed.value?.durationSeconds, 72);
        expect(port.runtimeSnapshot.recordingInfo.startedAt, now);
        expect(port.runtimeSnapshot.recordingInfo.durationSeconds, 72);

        now = now.add(const Duration(seconds: 8));
        final stopped = await port.stopRecording();
        expect(stopped.ok, isTrue);
        expect(stopped.value, same(port.runtimeSnapshot.recordingInfo));
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(port.runtimeSnapshot.recordingInfo.currentFileName, isNull);
        expect(port.runtimeSnapshot.recordingInfo.startedAt, isNull);
        expect(port.runtimeSnapshot.recordingInfo.durationSeconds, 0);

        await port.dispose();
      },
    );

    test(
      'unknown file format is omitted from native download request',
      () async {
        const channel = MethodChannel('huahuoai/recording_card_unknown_format');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        Map<Object?, Object?>? arguments;
        messenger.setMockMethodCallHandler(channel, (call) async {
          arguments = (call.arguments as Map<Object?, Object?>?)?.cast();
          return _downloadedMap();
        });
        final port = MethodChannelRecordingCardPort(methodChannel: channel);

        final result = await port.downloadFileToLocalCache(_file());

        expect(result.ok, isTrue);
        expect(arguments, isNot(contains('format')));
        expect(arguments?['deviceFilename'], '20260701090000');
        await port.dispose();
      },
    );

    test('failure codes retain a stable transfer stage classification', () {
      expect(
        recordingCardFailureStage('RECORDING_CARD_NOT_CONNECTED'),
        RecordingCardFailureStage.connection,
      );
      expect(
        recordingCardFailureStage('RECORDING_CARD_INVALID_FILE'),
        RecordingCardFailureStage.request,
      );
      expect(
        recordingCardFailureStage('RECORDING_CARD_DOWNLOAD_TIMEOUT'),
        RecordingCardFailureStage.transfer,
      );
      expect(
        recordingCardFailureStage('RECORDING_CARD_DOWNLOAD_SIZE_MISMATCH'),
        RecordingCardFailureStage.verification,
      );
      expect(
        recordingCardFailureStage('RECORDING_CARD_LOCAL_STORAGE_FAILED'),
        RecordingCardFailureStage.storage,
      );
      expect(
        recordingCardFailureStage(
          'RECORDING_CARD_WIFI_BATCH_CHECKPOINT_FAILED',
        ),
        RecordingCardFailureStage.storage,
      );
      expect(
        recordingCardFailureStage('RECORDING_CARD_WIFI_BATCH_PERSIST_FAILED'),
        RecordingCardFailureStage.storage,
      );
      expect(
        recordingCardFailureStage('RECORDING_CARD_OPERATION_BUSY'),
        RecordingCardFailureStage.coordination,
      );
      expect(
        recordingCardFailureStage('RECORDING_CARD_OPERATION_DEFERRED'),
        RecordingCardFailureStage.coordination,
      );
      expect(
        recordingCardFailureStage('RECORDING_CARD_COMMAND_IN_PROGRESS'),
        RecordingCardFailureStage.coordination,
      );
    });

    test('successful MethodChannel payloads parse safe DTOs', () async {
      const channel = MethodChannel('huahuoai/recording_card_contract_success');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'connect':
            return _connectedDeviceMap();
          case 'scanDevices':
            return <String, Object?>{
              'devices': <Object?>[_discoveredDeviceMap()],
            };
          case 'scanFiles':
            return <String, Object?>{
              'files': <Object?>[_fileMap()],
            };
          case 'downloadFileToLocalCache':
            return _downloadedMap();
          case 'verifyWifiHandoff':
            return <String, Object?>{'status': 'ready'};
          case 'downloadFileOverWifi':
            return _downloadedMap();
          case 'prepareWifiSession':
            expect(
              (call.arguments as Map<Object?, Object?>)['files'],
              isA<List<Object?>>(),
            );
            return <String, Object?>{
              'ssid': 'FW920_TEST',
              'password': '12345678',
            };
          case 'joinWifiNetwork':
            expect(call.arguments, <String, Object?>{
              'ssid': 'FW920_TEST',
              'password': '12345678',
            });
            return true;
          case 'openWifiSession':
            expect(
              (call.arguments as Map<Object?, Object?>)['files'],
              isA<List<Object?>>(),
            );
            return <String, Object?>{
              'sessionId': 'wifi-session-1',
              'openedAt': '2026-07-15T09:00:00.000Z',
              'files': <Object?>[_fileMap()],
            };
          case 'downloadFileInWifiSession':
            final arguments = call.arguments as Map<Object?, Object?>;
            expect(arguments['fileIndex'], 0);
            expect(arguments['fileCount'], 1);
            expect(arguments['aggregateReceivedBytes'], 0);
            expect(arguments['aggregateTotalBytes'], 4096);
            expect(arguments['batchId'], 'wifi-session-1');
            return _downloadedMap();
          case 'closeWifiSession':
          case 'cancelWifiSession':
            return true;
          case 'deleteFileFromDevice':
            return <String, Object?>{
              'deleted': true,
              'deviceFileId': 'card-file-1',
              'deviceFilename': '20260701090000',
            };
        }
        return null;
      });
      final port = MethodChannelRecordingCardPort(methodChannel: channel);

      final connect = await port.connect();
      final devices = await port.scanDevices();
      final files = await port.scanFiles();
      final downloaded = await port.downloadFileToLocalCache(
        files.value!.single,
      );
      final handoff = await port.verifyWifiHandoff();
      final wifiDownloaded = await port.downloadFileOverWifi(
        files.value!.single,
      );
      final credentials = await port.prepareWifiSession(
        <RecordingCardScannedFile>[files.value!.single],
      );
      final joined = await port.joinWifiNetwork(credentials.value!);
      final session = await port.openWifiSession(<RecordingCardScannedFile>[
        files.value!.single,
      ]);
      final sessionDownloaded = await port.downloadFileInWifiSession(
        files.value!.single,
      );
      final closed = await port.closeWifiSession();

      expect(
        connect.value?.connectionState,
        RecordingCardConnectionState.connected,
      );
      expect(connect.value?.serialNumber, 'SP63A03003');
      expect(devices.value?.single.safeDeviceFingerprint, 'card-fingerprint-1');
      expect(devices.value?.single.serialNumber, 'SP63A03003');
      expect(
        port.runtimeSnapshot.discoveredDevices.single.displayName,
        'Huahuo FW920',
      );
      expect(files.value?.single.deviceFilename, '20260701090000');
      expect(
        files.value?.single.syncState,
        RecordingCardFileSyncState.deviceOnly,
      );
      expect(
        downloaded.value?.appPrivateUri,
        'app-private://recording-card/card-20260701090000.m4a',
      );
      expect(downloaded.value?.localFileId, 'card-20260701090000');
      expect(handoff.value?.status, RecordingCardWifiHandoffStatus.ready);
      expect(
        wifiDownloaded.value?.appPrivateUri,
        'app-private://recording-card/card-20260701090000.m4a',
      );
      expect(
        port.runtimeSnapshot.files.single.syncState,
        RecordingCardFileSyncState.synced,
      );
      expect(credentials.value?.ssid, 'FW920_TEST');
      expect(joined.value, isTrue);
      expect(session.value?.sessionId, 'wifi-session-1');
      expect(session.value?.files.single.deviceFileId, 'card-file-1');
      expect(sessionDownloaded.value?.sizeBytes, 4096);
      expect(closed.value, isTrue);

      final deleted = await port.deleteFileFromDevice(files.value!.single);
      expect(deleted.value?.deleted, isTrue);
      expect(port.runtimeSnapshot.files, isEmpty);
      await port.dispose();
    });

    test('malformed advertisement SN is omitted without dropping scan row', () {
      final row = _discoveredDeviceMap()..['serialNumber'] = 'SN\nunsafe';

      final device = parseRecordingCardDiscoveredDevice(row);

      expect(device, isNotNull);
      expect(device?.serialNumber, isNull);
      expect(device?.safeDeviceFingerprint, 'card-fingerprint-1');
    });

    test('advertisement SN uses the ownership-compatible ASCII envelope', () {
      for (final serialNumber in <String>[
        'ABC123',
        'AB-CD:12',
        'sp63-a03003',
        'A'.padRight(64, '9'),
      ]) {
        final row = _discoveredDeviceMap()..['serialNumber'] = serialNumber;

        expect(
          parseRecordingCardDiscoveredDevice(row)?.serialNumber,
          serialNumber,
        );
      }

      for (final serialNumber in <String>[
        'ABCDE',
        '-ABCDE',
        'ABC 123',
        'ABC.123',
        'ABC_123',
        'A-----',
        'A'.padRight(65, '9'),
      ]) {
        final row = _discoveredDeviceMap()..['serialNumber'] = serialNumber;
        final device = parseRecordingCardDiscoveredDevice(row);

        expect(device, isNotNull);
        expect(device?.serialNumber, isNull);
      }
    });

    test('malformed connected SN is omitted without dropping device state', () {
      final row = _connectedDeviceMap()..['serialNumber'] = 'SN\nunsafe';

      final device = parseRecordingCardDeviceState(row);

      expect(device, isNotNull);
      expect(device?.serialNumber, isNull);
      expect(device?.displayName, 'Huahuo FW920');
    });

    test(
      'failed Wi-Fi close and cancel always clear Dart session context',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_wifi_failed_cleanup',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>();
        final downloadArguments = <Map<Object?, Object?>>[];
        var closeShouldThrow = true;
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'openWifiSession':
              return <String, Object?>{
                'sessionId': 'stale-wifi-session',
                'files': <Object?>[_fileMap()],
              };
            case 'closeWifiSession':
              if (closeShouldThrow) {
                throw PlatformException(
                  code: 'RECORDING_CARD_WIFI_CLOSE_FAILED',
                );
              }
              return true;
            case 'cancelWifiSession':
              return <String, Object?>{'cancelled': false};
            case 'downloadFileInWifiSession':
              downloadArguments.add(
                Map<Object?, Object?>.from(
                  call.arguments! as Map<Object?, Object?>,
                ),
              );
              return _downloadedMap();
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        final file = _file();

        expect(
          (await port.openWifiSession(<RecordingCardScannedFile>[file])).ok,
          isTrue,
        );
        final failedClose = await port.closeWifiSession();
        expect(failedClose.ok, isFalse);
        expect(failedClose.error?.code, 'RECORDING_CARD_WIFI_CLOSE_FAILED');
        expect((await port.downloadFileInWifiSession(file)).ok, isTrue);
        expect(downloadArguments.single, isNot(contains('sessionId')));
        expect(downloadArguments.single, isNot(contains('batchId')));
        expect(downloadArguments.single, isNot(contains('fileIndex')));
        expect(downloadArguments.single, isNot(contains('fileCount')));
        expect(
          downloadArguments.single,
          isNot(contains('aggregateReceivedBytes')),
        );
        expect(
          downloadArguments.single,
          isNot(contains('aggregateTotalBytes')),
        );

        closeShouldThrow = false;
        expect(
          (await port.openWifiSession(<RecordingCardScannedFile>[file])).ok,
          isTrue,
        );
        events.add(<String, Object?>{
          'type': 'transfer_progress',
          'progress': <String, Object?>{
            'localFileKey': file.localFileKey,
            'receivedBytes': 1024,
            'totalBytes': 4096,
            'correlationId': 'wifi-cancel-failure',
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(port.runtimeSnapshot.transferProgress, isNotNull);

        final failedCancel = await port.cancelWifiSession();
        expect(failedCancel.ok, isFalse);
        expect(
          failedCancel.error?.code,
          'NATIVE_RECORDING_CARD_MALFORMED_PAYLOAD',
        );
        expect(port.runtimeSnapshot.transferProgress, isNotNull);
        expect((await port.downloadFileInWifiSession(file)).ok, isTrue);
        expect(downloadArguments.last, isNot(contains('sessionId')));
        expect(downloadArguments.last, isNot(contains('batchId')));
        expect(downloadArguments.last, isNot(contains('fileIndex')));
        expect(downloadArguments.last, isNot(contains('fileCount')));
        expect(
          downloadArguments.last,
          isNot(contains('aggregateReceivedBytes')),
        );
        expect(downloadArguments.last, isNot(contains('aggregateTotalBytes')));

        await port.dispose();
      },
    );

    test('late Wi-Fi open cannot restore a cancelled session', () async {
      const channel = MethodChannel('huahuoai/recording_card_wifi_stale_open');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final events = StreamController<Object?>();
      final firstOpenStarted = Completer<void>();
      final firstOpenResult = Completer<Object?>();
      final downloadArguments = <Map<Object?, Object?>>[];
      var openCalls = 0;
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await events.close();
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'openWifiSession':
            openCalls += 1;
            if (openCalls == 1) {
              firstOpenStarted.complete();
              return firstOpenResult.future;
            }
            return <String, Object?>{'sessionId': 'wifi-session-current'};
          case 'cancelWifiSession':
            return true;
          case 'downloadFileInWifiSession':
            downloadArguments.add(
              Map<Object?, Object?>.from(
                call.arguments! as Map<Object?, Object?>,
              ),
            );
            return _downloadedMap();
          case 'disconnect':
            return <String, Object?>{
              'connectionState': 'disconnected',
              'connectionStage': 'idle',
            };
        }
        return null;
      });
      final port = MethodChannelRecordingCardPort(
        methodChannel: channel,
        nativeEvents: events.stream,
      );
      final file = _file();

      final staleOpen = port.openWifiSession(<RecordingCardScannedFile>[file]);
      await firstOpenStarted.future;
      expect((await port.cancelWifiSession()).value, isTrue);
      firstOpenResult.complete(<String, Object?>{
        'sessionId': 'wifi-session-stale',
      });
      final staleResult = await staleOpen;

      expect(staleResult.ok, isFalse);
      expect(staleResult.error?.code, 'RECORDING_CARD_WIFI_SESSION_STALE');
      expect(
        (await port.openWifiSession(<RecordingCardScannedFile>[file])).ok,
        isTrue,
      );
      expect((await port.downloadFileInWifiSession(file)).ok, isTrue);
      expect(downloadArguments.single['sessionId'], 'wifi-session-current');
      expect(downloadArguments.single['batchId'], 'wifi-session-current');

      await port.dispose();
    });

    test(
      'late Wi-Fi teardown preserves replacement session and committed receipt',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_wifi_stale_teardown',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>(sync: true);
        final downloadStarted = Completer<void>();
        final downloadResult = Completer<Object?>();
        final cancelStarted = Completer<void>();
        final cancelResult = Completer<Object?>();
        final closeStarted = Completer<void>();
        final closeResult = Completer<Object?>();
        final downloadArguments = <Map<Object?, Object?>>[];
        var openCalls = 0;
        var downloadCalls = 0;
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'openWifiSession':
              openCalls += 1;
              return <String, Object?>{'sessionId': 'wifi-session-$openCalls'};
            case 'downloadFileInWifiSession':
              downloadCalls += 1;
              downloadArguments.add(
                Map<Object?, Object?>.from(
                  call.arguments! as Map<Object?, Object?>,
                ),
              );
              if (downloadCalls == 1) {
                downloadStarted.complete();
                return downloadResult.future;
              }
              return _downloadedMap();
            case 'cancelWifiSession':
              cancelStarted.complete();
              return cancelResult.future;
            case 'closeWifiSession':
              closeStarted.complete();
              return closeResult.future;
            case 'disconnect':
              return <String, Object?>{
                'connectionState': 'disconnected',
                'connectionStage': 'idle',
              };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        final file = _file();
        const replacementFile = RecordingCardScannedFile(
          deviceFileId: 'card-file-2',
          localFileKey: 'card-20260701090100',
          deviceFilename: '20260701090100',
          sizeBytes: 8192,
        );
        events.add(<String, Object?>{
          'type': 'runtime_snapshot',
          'snapshot': <String, Object?>{
            'deviceState': _connectedDeviceMap(),
            'recordingInfo': <String, Object?>{'state': 'idle'},
            'files': <Object?>[
              _fileMap(),
              <String, Object?>{
                'deviceFileId': replacementFile.deviceFileId,
                'localFileKey': replacementFile.localFileKey,
                'deviceFilename': replacementFile.deviceFilename,
                'sizeBytes': replacementFile.sizeBytes,
                'syncState': 'deviceOnly',
              },
            ],
          },
        });

        expect(
          (await port.openWifiSession(<RecordingCardScannedFile>[file])).ok,
          isTrue,
        );
        final committedDownload = port.downloadFileInWifiSession(file);
        await downloadStarted.future;
        final pendingCancel = port.cancelWifiSession();
        await cancelStarted.future;
        expect(
          (await port.openWifiSession(<RecordingCardScannedFile>[
            replacementFile,
          ])).value?.sessionId,
          'wifi-session-2',
        );
        events.add(<String, Object?>{
          'type': 'transfer_progress',
          'progress': <String, Object?>{
            'localFileKey': replacementFile.localFileKey,
            'receivedBytes': 1024,
            'totalBytes': replacementFile.sizeBytes,
            'correlationId': 'wifi-session-2-progress',
            'transport': 'wifi',
            'batchId': 'wifi-session-2',
          },
        });
        events.add(<String, Object?>{
          'type': 'runtime_snapshot',
          'snapshot': <String, Object?>{
            'deviceState': _connectedDeviceMap(),
            'recordingInfo': <String, Object?>{'state': 'idle'},
            'files': <Object?>[_fileMap()],
          },
        });
        downloadResult.complete(_downloadedMap());

        expect((await committedDownload).ok, isTrue);
        expect(
          port.runtimeSnapshot.files
              .singleWhere(
                (candidate) => candidate.localFileKey == file.localFileKey,
              )
              .syncState,
          RecordingCardFileSyncState.synced,
        );
        expect(
          port.runtimeSnapshot.transferProgress?.correlationId,
          'wifi-session-2-progress',
        );
        cancelResult.complete(true);
        expect((await pendingCancel).value, isTrue);
        expect(
          port.runtimeSnapshot.transferProgress?.correlationId,
          'wifi-session-2-progress',
        );
        expect(
          (await port.downloadFileInWifiSession(replacementFile)).ok,
          isTrue,
        );
        expect(downloadArguments.last['sessionId'], 'wifi-session-2');

        final pendingClose = port.closeWifiSession();
        await closeStarted.future;
        expect(
          (await port.openWifiSession(<RecordingCardScannedFile>[
            replacementFile,
          ])).value?.sessionId,
          'wifi-session-3',
        );
        closeResult.complete(true);
        expect((await pendingClose).value, isTrue);
        expect(
          (await port.downloadFileInWifiSession(replacementFile)).ok,
          isTrue,
        );
        expect(downloadArguments.last['sessionId'], 'wifi-session-3');

        await port.dispose();
      },
    );

    test(
      'Wi-Fi join requires a strict receipt and preserves native denial',
      () async {
        const channel = MethodChannel('huahuoai/recording_card_wifi_join');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        var deny = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'joinWifiNetwork');
          if (deny) {
            throw PlatformException(code: 'RECORDING_CARD_WIFI_JOIN_DENIED');
          }
          return <String, Object?>{'joined': true};
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: const Stream<Object?>.empty(),
        );
        const credentials = RecordingCardWifiCredentials(
          ssid: 'FW920_TEST',
          password: '12345678', // secret-scan: allow
        );

        final malformed = await port.joinWifiNetwork(credentials);
        deny = true;
        final denied = await port.joinWifiNetwork(credentials);

        expect(malformed.ok, isFalse);
        expect(
          malformed.error?.code,
          'NATIVE_RECORDING_CARD_MALFORMED_PAYLOAD',
        );
        expect(denied.ok, isFalse);
        expect(denied.error?.code, 'RECORDING_CARD_WIFI_JOIN_DENIED');
        await port.dispose();
      },
    );

    test('mock native runtime events update snapshot subscribers', () async {
      final events = StreamController<Object?>();
      final port = MethodChannelRecordingCardPort(nativeEvents: events.stream);
      final snapshots = <RecordingCardRuntimeSnapshot>[];
      final subscription = port.subscribeRuntimeSnapshot(snapshots.add);

      events.add(<String, Object?>{
        'type': 'runtime_snapshot',
        'snapshot': <String, Object?>{
          'deviceState': _connectedDeviceMap(),
          'recordingInfo': <String, Object?>{'state': 'recording'},
          'files': <Object?>[_fileMap()],
          'lastDeviceUpdatedAt': '2026-07-01T09:00:00Z',
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        snapshots.last.deviceState.connectionState,
        RecordingCardConnectionState.connected,
      );
      expect(snapshots.last.deviceState.serialNumber, 'SP63A03003');
      expect(
        snapshots.last.recordingInfo.state,
        RecordingCardRecordingState.recording,
      );
      expect(snapshots.last.files.single.localFileKey, 'card-20260701090000');

      events.add(<String, Object?>{
        'type': 'connection_state',
        'deviceState': <String, Object?>{
          'connectionState': 'ble_ready',
          'connectionStage': 'connected',
          'batteryPercent': 85,
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(snapshots.last.deviceState.serialNumber, 'SP63A03003');

      subscription.unsubscribe();
      await events.close();
      await port.dispose();
    });

    test(
      'native inventory updates preserve a completed local download',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_completed_download_inventory_merge',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>();
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'connect':
              return _connectedDeviceMap();
            case 'scanFiles':
              return <String, Object?>{
                'files': <Object?>[_fileMap()],
              };
            case 'downloadFileToLocalCache':
              return _downloadedMap();
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        await port.connect();
        final files = await port.scanFiles();
        await port.downloadFileToLocalCache(files.value!.single);
        expect(
          port.runtimeSnapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );

        events.add(<String, Object?>{
          'type': 'runtime_snapshot',
          'snapshot': <String, Object?>{
            'deviceState': _connectedDeviceMap(),
            'recordingInfo': <String, Object?>{'state': 'idle'},
            'files': <Object?>[_fileMap()],
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          port.runtimeSnapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );
        expect(
          port.runtimeSnapshot.files.single.appPrivateUri,
          _downloadedMap()['appPrivateUri'],
        );

        await port.scanFiles();
        expect(
          port.runtimeSnapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );

        await port.dispose();
      },
    );

    test(
      'missing and stale recording observations preserve active timer',
      () async {
        var now = DateTime.utc(2026, 7, 15, 9);
        final events = StreamController<Object?>();
        final port = MethodChannelRecordingCardPort(
          nativeEvents: events.stream,
          clock: () => now,
        );
        events.add(
          _runtimeEvent(
            recordingInfo: <String, Object?>{
              'state': 'recording',
              'observationSource': 'recordingInfo',
              'revision': 10,
              'observedAt': now.toIso8601String(),
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        now = now.add(const Duration(seconds: 40));

        events.add(
          _runtimeEvent(
            recordingInfo: <String, Object?>{
              'state': 'unknown',
              'revision': 11,
              'observedAt': now.toIso8601String(),
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );
        expect(
          recordingCardElapsedSeconds(
            port.runtimeSnapshot.recordingInfo,
            now: now,
          ),
          40,
        );

        events.add(<String, Object?>{
          'type': 'recording_state',
          'recordingInfo': <String, Object?>{
            'state': 'idle',
            'observationSource': 'statusNotification',
            'revision': 9,
            'observedAt': now.toIso8601String(),
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );

        events.add(<String, Object?>{
          'type': 'recording_state',
          'recordingInfo': <String, Object?>{
            'state': 'idle',
            'observationSource': 'statusNotification',
            'revision': 11,
            'observedAt': now.toIso8601String(),
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(port.runtimeSnapshot.recordingInfo.durationSeconds, 0);

        await events.close();
        await port.dispose();
      },
    );

    test(
      'physical recording event starts timer and only explicit newer stop resets it',
      () async {
        var now = DateTime.utc(2026, 7, 17, 13);
        final events = StreamController<Object?>();
        final port = MethodChannelRecordingCardPort(
          nativeEvents: events.stream,
          clock: () => now,
        );

        events.add(<String, Object?>{
          'type': 'connection_state',
          'deviceState': _connectedDeviceMap(),
        });
        await Future<void>.delayed(Duration.zero);

        events.add(<String, Object?>{
          'type': 'recording_state',
          'recordingInfo': <String, Object?>{
            'state': 'recording',
            'observationSource': 'statusNotification',
            'revision': 20,
            'observedAt': now.toIso8601String(),
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(port.runtimeSnapshot.recordingInfo.startedAt, now);

        now = now.add(const Duration(seconds: 16));
        events.add(_runtimeEvent(recordingInfo: null));
        await Future<void>.delayed(Duration.zero);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );
        expect(
          recordingCardElapsedSeconds(
            port.runtimeSnapshot.recordingInfo,
            now: now,
          ),
          16,
        );

        events.add(<String, Object?>{
          'type': 'recording_state',
          'recordingInfo': <String, Object?>{
            'state': 'idle',
            'observationSource': 'deviceInfo',
            'revision': 19,
            'observedAt': now.toIso8601String(),
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );

        events.add(<String, Object?>{
          'type': 'recording_state',
          'recordingInfo': <String, Object?>{
            'state': 'idle',
            'observationSource': 'statusNotification',
            'revision': 21,
            'observedAt': now.toIso8601String(),
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(port.runtimeSnapshot.recordingInfo.durationSeconds, 0);
        expect(port.runtimeSnapshot.recordingInfo.startedAt, isNull);

        await events.close();
        await port.dispose();
      },
    );

    test(
      'recording invalidations coalesce and disconnect clears native timer anchor',
      () async {
        var now = DateTime(2026, 9, 5, 9, 0, 42).toUtc();
        const channel = MethodChannel(
          'huahuoai/recording_card_recording_invalidation',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>();
        final firstRead = Completer<Object?>();
        var readCalls = 0;
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'connect':
              return _connectedDeviceMap();
            case 'readRecordingState':
              readCalls += 1;
              if (readCalls == 1) return firstRead.future;
              return <String, Object?>{
                'state': 'recording',
                'currentFileName': '20260905090000.m4a',
                'startedAt': DateTime(2026, 9, 5, 9).toUtc().toIso8601String(),
                'durationSeconds': 0,
              };
            case 'disconnect':
              return <String, Object?>{
                'connectionState': 'disconnected',
                'connectionStage': 'idle',
              };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
          clock: () => now,
        );
        await port.connect();

        events.add(const <String, Object?>{
          'type': 'recording_state_invalidated',
        });
        events.add(const <String, Object?>{
          'type': 'recording_state_invalidated',
        });
        events.add(const <String, Object?>{
          'type': 'recording_state_invalidated',
        });
        await Future<void>.delayed(Duration.zero);
        expect(readCalls, 1);

        firstRead.complete(<String, Object?>{
          'state': 'recording',
          'currentFileName': '20260905090000.m4a',
          'startedAt': DateTime(2026, 9, 5, 9).toUtc().toIso8601String(),
          'durationSeconds': 0,
        });
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(readCalls, 2);
        expect(
          port.runtimeSnapshot.recordingInfo.startedAt,
          DateTime(2026, 9, 5, 9).toUtc(),
        );
        expect(
          recordingCardElapsedSeconds(
            port.runtimeSnapshot.recordingInfo,
            now: now,
          ),
          42,
        );

        now = now.add(const Duration(seconds: 1));
        events.add(const <String, Object?>{
          'type': 'connection_state',
          'deviceState': <String, Object?>{
            'connectionState': 'disconnected',
            'connectionStage': 'idle',
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(port.runtimeSnapshot.recordingInfo.durationSeconds, 0);
        expect(port.runtimeSnapshot.recordingObservation, isNull);

        await port.dispose();
      },
    );

    test(
      'recording invalidation retries one transient authoritative read failure',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_recording_invalidation_retry',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final events = StreamController<Object?>();
        var readCalls = 0;
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await events.close();
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'connect':
              return _connectedDeviceMap();
            case 'readRecordingState':
              readCalls += 1;
              if (readCalls == 1) {
                throw PlatformException(
                  code: 'RECORDING_CARD_READ_TIMEOUT',
                  message: 'temporary timeout',
                );
              }
              return <String, Object?>{
                'state': 'recording',
                'currentFileName': '20260905090000.m4a',
              };
            case 'disconnect':
              return <String, Object?>{
                'connectionState': 'disconnected',
                'connectionStage': 'idle',
              };
          }
          return null;
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
          recordingStateInvalidationRetryDelays: const <Duration>[
            Duration.zero,
            Duration.zero,
          ],
        );
        await port.connect();

        events.add(const <String, Object?>{
          'type': 'recording_state_invalidated',
        });
        for (var attempt = 0; attempt < 10 && readCalls < 2; attempt += 1) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(readCalls, 2);
        expect(
          port.runtimeSnapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );

        await port.dispose();
      },
    );

    for (final boundary in <String>['connect', 'event', 'query']) {
      test(
        'new session releases pending recording reads via $boundary',
        () async {
          final harness = _OwnershipPortHarness();
          final oldRead = Completer<Object?>();
          final newRead = Completer<Object?>();
          var readCalls = 0;
          harness.responses['readRecordingState'] = () {
            readCalls += 1;
            return readCalls == 1 ? oldRead.future : newRead.future;
          };
          await harness.port.connect();
          final obsolete = harness.port.readRecordingState();
          harness.invalidateRecording();
          await Future<void>.delayed(Duration.zero);
          harness.deviceState = _connectedDeviceBMap();
          switch (boundary) {
            case 'connect':
              await harness.port.connect();
            case 'event':
              harness.publishConnection();
            case 'query':
              await harness.port.getConnectionState();
          }
          harness.invalidateRecording();
          await Future<void>.delayed(Duration.zero);
          expect(readCalls, 2);
          final current = harness.port.readRecordingState();
          oldRead.complete(<String, Object?>{'state': 'idle'});
          expect(
            (await obsolete).error?.code,
            'RECORDING_CARD_DEVICE_SESSION_STALE',
          );
          final joined = harness.port.readRecordingState();
          await Future<void>.delayed(Duration.zero);
          expect(readCalls, 2);
          newRead.complete(<String, Object?>{
            'state': 'recording',
            'currentFileName': 'new-card.m4a',
            'revision': 1,
          });
          expect(
            (await current).value?.state,
            RecordingCardRecordingState.recording,
          );
          expect(
            (await joined).value?.state,
            RecordingCardRecordingState.recording,
          );
          expect(
            harness.port.runtimeSnapshot.recordingInfo.startedAt,
            isNotNull,
          );
        },
      );
    }

    for (final method in <String>[
      'cancelFileTransfer',
      'cancelWifiSession',
      'downloadFileToLocalCache',
      'downloadFileInWifiSession',
      'downloadFailure',
      'deleteFileFromDevice',
    ]) {
      for (final replaceCard in <bool>[false, true]) {
        if (method == 'deleteFileFromDevice' && !replaceCard) continue;
        test(
          'late $method preserves replacement transfer (card=$replaceCard)',
          () async {
            final harness = _OwnershipPortHarness();
            final lateResponse = Completer<Object?>();
            harness.responses[method == 'downloadFailure'
                ? 'downloadFileToLocalCache'
                : method] = () =>
                lateResponse.future;
            await harness.port.connect();
            await harness.port.scanFiles();
            if (method.startsWith('cancel') ||
                method == 'deleteFileFromDevice') {
              harness.progress('old-transfer');
            }
            final Future<RecordingCardResult<Object>> operation;
            switch (method) {
              case 'cancelFileTransfer':
                operation = harness.port.cancelFileTransfer();
              case 'cancelWifiSession':
                operation = harness.port.cancelWifiSession();
              case 'deleteFileFromDevice':
                operation = harness.port.deleteFileFromDevice(_file());
              case 'downloadFileInWifiSession':
                operation = harness.port.downloadFileInWifiSession(_file());
              default:
                operation = harness.port.downloadFileToLocalCache(_file());
            }
            harness.progress('old-transfer');
            await Future<void>.delayed(Duration.zero);
            if (replaceCard) {
              harness.deviceState = _connectedDeviceBMap();
              harness.publishConnection();
              expect(harness.port.runtimeSnapshot.transferProgress, isNull);
              expect(harness.port.runtimeSnapshot.files, isEmpty);
              await harness.port.scanFiles();
            }
            harness.progress('new-transfer');
            if (method == 'downloadFailure') {
              lateResponse.completeError(
                PlatformException(code: 'TRANSFER_FAILED'),
              );
            } else {
              lateResponse.complete(
                method.startsWith('cancel')
                    ? <String, Object?>{'cancelled': true}
                    : method == 'deleteFileFromDevice'
                    ? <String, Object?>{
                        'deviceFileId': _file().deviceFileId,
                        'deleted': true,
                      }
                    : _downloadedMap(),
              );
            }
            final result = await operation;
            final preservesCommittedReceipt =
                method == 'cancelWifiSession' ||
                method == 'downloadFileToLocalCache' ||
                method == 'downloadFileInWifiSession';
            if (preservesCommittedReceipt) {
              expect(result.ok, isTrue);
            } else {
              expect(result.error?.code, contains('STALE'));
            }
            expect(
              harness.port.runtimeSnapshot.transferProgress?.correlationId,
              'new-transfer',
            );
            expect(
              harness.port.runtimeSnapshot.downloadingFileKey,
              _file().localFileKey,
            );
            expect(
              harness.port.runtimeSnapshot.files.single.syncState,
              replaceCard
                  ? RecordingCardFileSyncState.deviceOnly
                  : method == 'downloadFileToLocalCache' ||
                        method == 'downloadFileInWifiSession'
                  ? RecordingCardFileSyncState.synced
                  : method.startsWith('cancel')
                  ? RecordingCardFileSyncState.deviceOnly
                  : RecordingCardFileSyncState.downloading,
            );
          },
        );
      }
    }

    for (final cancelFirst in <bool>[false, true]) {
      test(
        'cancellation owns download failure ordering (cancelFirst=$cancelFirst)',
        () async {
          final harness = _OwnershipPortHarness();
          final downloadReply = Completer<Object?>();
          final cancelReply = Completer<Object?>();
          harness.responses['downloadFileToLocalCache'] = () =>
              downloadReply.future;
          harness.responses['cancelFileTransfer'] = () => cancelReply.future;
          await harness.port.connect();
          await harness.port.scanFiles();
          final download = harness.port.downloadFileToLocalCache(_file());
          harness.progress('cancel-owned-transfer');
          final cancel = harness.port.cancelFileTransfer();
          await Future<void>.delayed(Duration.zero);
          if (cancelFirst) {
            cancelReply.complete(<String, Object?>{'cancelled': true});
            expect((await cancel).ok, isTrue);
            downloadReply.completeError(
              PlatformException(code: 'TRANSFER_CANCELLED'),
            );
            expect((await download).error?.code, contains('STALE'));
          } else {
            downloadReply.completeError(
              PlatformException(code: 'TRANSFER_CANCELLED'),
            );
            expect((await download).ok, isFalse);
            cancelReply.complete(<String, Object?>{'cancelled': true});
            expect((await cancel).ok, isTrue);
          }
          expect(
            harness.port.runtimeSnapshot.files.single.syncState,
            RecordingCardFileSyncState.deviceOnly,
          );
          expect(harness.port.runtimeSnapshot.transferProgress, isNull);
          expect(harness.port.runtimeSnapshot.downloadingFileKey, isNull);
        },
      );
    }

    for (final method in <String>[
      'openWifiSession',
      'closeWifiSession',
      'cancelWifiSession',
    ]) {
      test('late $method preserves newer Wi-Fi context', () async {
        final harness = _OwnershipPortHarness();
        final oldReply = Completer<Object?>();
        harness.responses[method] = () => oldReply.future;
        await harness.port.connect();
        final Future<RecordingCardResult<Object>> operation;
        switch (method) {
          case 'openWifiSession':
            operation = harness.port.openWifiSession(<RecordingCardScannedFile>[
              _file(),
            ]);
          case 'closeWifiSession':
            operation = harness.port.closeWifiSession();
          default:
            operation = harness.port.cancelWifiSession();
        }
        await Future<void>.delayed(Duration.zero);
        harness.responses['openWifiSession'] = () => <String, Object?>{
          'sessionId': 'current-wifi-session',
          'files': <Object?>[_fileMap()],
        };
        expect(
          (await harness.port.openWifiSession(<RecordingCardScannedFile>[
            _file(),
          ])).ok,
          isTrue,
        );
        harness.progress('current-wifi-transfer');
        oldReply.complete(
          method == 'openWifiSession'
              ? <String, Object?>{
                  'sessionId': 'old-wifi-session',
                  'files': <Object?>[_fileMap()],
                }
              : <String, Object?>{'cancelled': true},
        );
        final result = await operation;
        if (method == 'openWifiSession') {
          expect(result.error?.code, contains('STALE'));
        } else {
          expect(result.ok, isTrue);
        }
        expect(
          harness.port.runtimeSnapshot.transferProgress?.correlationId,
          'current-wifi-transfer',
        );
        expect(
          (await harness.port.downloadFileInWifiSession(_file())).ok,
          isTrue,
        );
        final arguments = harness.calls.last.arguments as Map<Object?, Object?>;
        expect(arguments['sessionId'], 'current-wifi-session');
        expect(arguments['batchId'], 'current-wifi-session');
        expect(arguments['fileIndex'], 0);
      });
    }

    for (final duringOpen in <bool>[false, true]) {
      test(
        'Wi-Fi survives observed BLE loss (duringOpen=$duringOpen)',
        () async {
          final harness = _OwnershipPortHarness();
          final openReply = Completer<Object?>();
          final downloadReply = Completer<Object?>();
          harness.responses['openWifiSession'] = () => openReply.future;
          harness.responses['downloadFileInWifiSession'] = () =>
              downloadReply.future;
          await harness.port.connect();
          await harness.port.scanFiles();
          final opened = harness.port.openWifiSession(
            <RecordingCardScannedFile>[_file()],
          );
          await Future<void>.delayed(Duration.zero);
          void loseBle() {
            harness.deviceState = <String, Object?>{
              'connectionState': 'disconnected',
              'connectionStage': 'idle',
            };
            harness.publishConnection();
            expect(
              harness.port.runtimeSnapshot.recordingInfo.state,
              RecordingCardRecordingState.idle,
            );
          }

          if (duringOpen) loseBle();
          openReply.complete(<String, Object?>{
            'sessionId': 'wifi-without-ble',
            'files': <Object?>[_fileMap()],
          });
          expect((await opened).ok, isTrue);
          final downloaded = harness.port.downloadFileInWifiSession(_file());
          harness.progress('wifi-without-ble-transfer');
          if (!duringOpen) loseBle();
          await Future<void>.delayed(Duration.zero);
          final arguments =
              harness.calls.last.arguments as Map<Object?, Object?>;
          expect(arguments['sessionId'], 'wifi-without-ble');
          expect(
            harness.port.runtimeSnapshot.transferProgress?.correlationId,
            'wifi-without-ble-transfer',
          );
          downloadReply.complete(_downloadedMap());
          expect((await downloaded).ok, isTrue);
          expect(
            harness.port.runtimeSnapshot.files.single.syncState,
            RecordingCardFileSyncState.synced,
          );
        },
      );
    }

    for (final embedded in <bool>[false, true]) {
      test('retired progress cannot reappear (embedded=$embedded)', () async {
        final harness = _OwnershipPortHarness();
        harness.responses['cancelFileTransfer'] = () => <String, Object?>{
          'cancelled': true,
        };
        await harness.port.connect();
        await harness.port.scanFiles();
        harness.progress('retired-transfer');
        final oldProgress = harness.port.runtimeSnapshot.transferProgress!;
        expect((await harness.port.cancelFileTransfer()).ok, isTrue);
        void replay() {
          if (!embedded) {
            harness.progress(oldProgress.correlationId);
            return;
          }
          harness.events.add(<String, Object?>{
            'type': 'runtime_snapshot',
            'snapshot': <String, Object?>{
              'deviceState': _connectedDeviceMap(),
              'recordingInfo': <String, Object?>{'state': 'recording'},
              'files': <Object?>[_fileMap()],
              'downloadingFileKey': oldProgress.localFileKey,
              'transferProgress': <String, Object?>{
                'localFileKey': oldProgress.localFileKey,
                'receivedBytes': 2048,
                'totalBytes': 4096,
                'correlationId': oldProgress.correlationId,
              },
            },
          });
        }

        replay();
        expect(harness.port.runtimeSnapshot.transferProgress, isNull);
        expect(harness.port.runtimeSnapshot.downloadingFileKey, isNull);
        harness.progress('current-transfer');
        replay();
        expect(
          harness.port.runtimeSnapshot.transferProgress?.correlationId,
          'current-transfer',
        );
        if (embedded) {
          expect(
            harness.port.runtimeSnapshot.recordingInfo.state,
            RecordingCardRecordingState.recording,
          );
        }
      });
    }

    test(
      'replacement card does not inherit synced annotations for the same file key',
      () async {
        final harness = _OwnershipPortHarness();
        await harness.port.connect();
        await harness.port.scanFiles();
        expect(
          (await harness.port.downloadFileToLocalCache(_file())).ok,
          isTrue,
        );
        expect(
          harness.port.runtimeSnapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );
        harness.events.add(<String, Object?>{
          'type': 'runtime_snapshot',
          'snapshot': <String, Object?>{
            'deviceState': _connectedDeviceBMap(),
            'recordingInfo': <String, Object?>{'state': 'idle'},
            'files': <Object?>[_fileMap()],
          },
        });
        final file = harness.port.runtimeSnapshot.files.single;
        expect(file.syncState, RecordingCardFileSyncState.deviceOnly);
        expect(file.appPrivateUri, isNull);
        expect(file.localFileId, isNull);
      },
    );

    test(
      'transfer progress is safe and native cancellation clears it',
      () async {
        const channel = MethodChannel(
          'huahuoai/recording_card_cancel_transfer',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return <String, Object?>{'cancelled': true};
        });
        final events = StreamController<Object?>();
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          nativeEvents: events.stream,
        );
        events.add(<String, Object?>{
          'type': 'transfer_progress',
          'progress': <String, Object?>{
            'localFileKey': 'card-20260701090000',
            'receivedBytes': 1024,
            'totalBytes': 4096,
            'correlationId': 'transfer-abc123',
            'directorySizeMismatch': true,
          },
        });
        await Future<void>.delayed(Duration.zero);

        expect(port.runtimeSnapshot.transferProgress?.fraction, .25);
        expect(
          port.runtimeSnapshot.transferProgress?.directorySizeMismatch,
          isTrue,
        );
        final cancelled = await port.cancelFileTransfer();

        expect(cancelled.value, isTrue);
        expect(calls, <String>['cancelFileTransfer']);
        expect(port.runtimeSnapshot.transferProgress, isNull);
        expect(port.runtimeSnapshot.downloadingFileKey, isNull);

        await events.close();
        await port.dispose();
      },
    );
  });
}

final class _OwnershipPortHarness {
  _OwnershipPortHarness() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final response = responses[call.method];
      if (response != null) return response();
      return switch (call.method) {
        'connect' || 'getConnectionState' => deviceState,
        'scanFiles' => <String, Object?>{
          'files': <Object?>[_fileMap()],
        },
        'downloadFileToLocalCache' ||
        'downloadFileInWifiSession' => _downloadedMap(),
        'disconnect' => <String, Object?>{
          'connectionState': 'disconnected',
          'connectionStage': 'idle',
        },
        _ => null,
      };
    });
    port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
      recordingStateInvalidationRetryDelays: const <Duration>[Duration.zero],
    );
    addTearDown(() async {
      await port.dispose();
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  final channel = const MethodChannel(
    'huahuoai/recording_card_ownership_audit',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final events = StreamController<Object?>(sync: true);
  final responses = <String, FutureOr<Object?> Function()>{};
  final calls = <MethodCall>[];
  Map<String, Object?> deviceState = _connectedDeviceMap();
  late final MethodChannelRecordingCardPort port;

  void invalidateRecording() {
    events.add(<String, Object?>{'type': 'recording_state_invalidated'});
  }

  void publishConnection() {
    events.add(<String, Object?>{
      'type': 'connection_state',
      'deviceState': deviceState,
    });
  }

  void progress(String correlationId) {
    events.add(<String, Object?>{
      'type': 'transfer_progress',
      'progress': <String, Object?>{
        'localFileKey': _file().localFileKey,
        'receivedBytes': 1024,
        'totalBytes': 4096,
        'correlationId': correlationId,
      },
    });
  }
}

Map<String, Object?> _runtimeEvent({required Object? recordingInfo}) {
  return <String, Object?>{
    'type': 'runtime_snapshot',
    'snapshot': <String, Object?>{
      'deviceState': _connectedDeviceMap(),
      'recordingInfo': recordingInfo,
      'files': const <Object?>[],
    },
  };
}

RecordingCardScannedFile _file() {
  return const RecordingCardScannedFile(
    deviceFileId: 'card-file-1',
    localFileKey: 'card-20260701090000',
    deviceFilename: '20260701090000',
    sizeBytes: 4096,
  );
}

Map<String, Object?> _connectedDeviceMap() {
  return <String, Object?>{
    'connectionState': 'ble_ready',
    'connectionStage': 'connected',
    'displayName': 'Huahuo FW920',
    'safeDeviceFingerprint': 'card-fingerprint-1',
    'serialNumber': 'SP63A03003',
    'batteryPercent': 86,
    'recordingFormat': 'm4a',
    'lastInfoRefreshedAt': '2026-07-01T09:00:00Z',
  };
}

Map<String, Object?> _connectedDeviceBMap() {
  return <String, Object?>{
    ..._connectedDeviceMap(),
    'displayName': 'Huahuo FW920 B',
    'safeDeviceFingerprint': 'card-fingerprint-2',
    'serialNumber': 'SP63A03004',
  };
}

Map<String, Object?> _discoveredDeviceMap() {
  return <String, Object?>{
    'displayName': 'Huahuo FW920',
    'safeDeviceFingerprint': 'card-fingerprint-1',
    'serialNumber': 'SP63A03003',
    'rssi': -42,
    'isConnectable': true,
    'lastSeenAt': '2026-07-01T09:00:00Z',
  };
}

Map<String, Object?> _fileMap() {
  return <String, Object?>{
    'deviceFileId': 'card-file-1',
    'localFileKey': 'card-20260701090000',
    'deviceFilename': '20260701090000',
    'sizeBytes': 4096,
    'recordedAt': '2026-07-01T09:00:00Z',
    'sizeConfidence': 'trusted',
    'syncState': 'deviceOnly',
  };
}

Map<String, Object?> _downloadedMap() {
  return <String, Object?>{
    'localFileKey': 'card-20260701090000',
    'localFileId': 'card-20260701090000',
    'appPrivateUri': 'app-private://recording-card/card-20260701090000.m4a',
    'displayName': '20260701090000.m4a',
    'durationSeconds': 38,
    'sizeBytes': 4096,
    'format': 'm4a',
    'mimeType': 'audio/mp4',
  };
}
