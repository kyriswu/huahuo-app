import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_account_binding_controller.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_account_binding.dart';

void main() {
  final now = DateTime.utc(2026, 8, 21, 8);

  test('bind reads identity and performs one direct server mutation', () async {
    final port = _FakeOwnershipPort(now: now);
    final hardware = _FakeHardware.connected();
    final cache = _FakeAuthorizationCache();
    final controller = RecordingCardCloudBindingController(
      port: port,
      hardware: hardware,
      authenticated: true,
      authorizationCache: cache,
      clock: () => now,
      random: Random(7),
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.state.status, RecordingCardCloudBindingStatus.unbound);

    final succeeded = await controller.bindConnectedCard(displayName: '我的录音卡');

    expect(succeeded, isTrue);
    expect(controller.state.status, RecordingCardCloudBindingStatus.bound);
    expect(controller.state.binding?.serialNumberMasked, '****1234');
    expect(hardware.readCount, 1);
    expect(port.bindCount, 1);
    expect(port.lastSerialNumber, 'SNABC1234');
    expect(port.lastDisplayName, '我的录音卡');
    expect(cache.serialNumber, 'SNABC1234');
    expect(cache.clearCount, 1);
    expect(
      port.lastIdempotencyKey,
      matches(RegExp(r'^recording-card-bind-\d+-[a-f0-9]{24}$')),
    );
    expect(controller.state.toString(), isNot(contains('SNABC1234')));
  });

  test('unregistered SN error is propagated from direct bind', () async {
    final port = _FakeOwnershipPort(now: now)
      ..bindError = 'RECORDING_CARD_NOT_REGISTERED';
    final hardware = _FakeHardware.connected();
    final controller = RecordingCardCloudBindingController(
      port: port,
      hardware: hardware,
      authenticated: true,
      clock: () => now,
      random: Random(9),
    );
    addTearDown(controller.dispose);
    await controller.load();

    expect(await controller.bindConnectedCard(), isFalse);
    expect(controller.state.errorCode, 'RECORDING_CARD_NOT_REGISTERED');
    expect(hardware.readCount, 1);
    expect(port.bindCount, 1);
  });

  test('owner can unbind while recording card is offline', () async {
    final port = _FakeOwnershipPort(now: now)..binding = _binding(now);
    final hardware = _FakeHardware();
    final cache = _FakeAuthorizationCache()..serialNumber = 'SNABC1234';
    var localReleaseCount = 0;
    final controller = RecordingCardCloudBindingController(
      port: port,
      hardware: hardware,
      authenticated: true,
      authorizationCache: cache,
      onUnbound: () async => localReleaseCount += 1,
      clock: () => now,
      random: Random(11),
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.state.status, RecordingCardCloudBindingStatus.bound);
    expect(await controller.unbindCurrentCard(), isTrue);
    expect(controller.state.status, RecordingCardCloudBindingStatus.unbound);
    expect(port.unbindCount, 1);
    expect(localReleaseCount, 1);
    expect(cache.serialNumber, isNull);
    expect(cache.clearCount, 1);
    expect(hardware.readCount, 0);
    expect(
      port.lastIdempotencyKey,
      matches(RegExp(r'^recording-card-unbind-\d+-[a-f0-9]{24}$')),
    );
  });

  test('unbind latches device and cloud phases in order', () async {
    final port = _FakeOwnershipPort(now: now)..binding = _binding(now);
    final controller = RecordingCardCloudBindingController(
      port: port,
      hardware: _FakeHardware.connected(),
      authenticated: true,
      clock: () => now,
      random: Random(13),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final phases = <RecordingCardUnbindPhase>[];
    controller.addListener(() => phases.add(controller.state.unbindPhase));

    final succeeded = await controller.unbindCurrentCard(
      beforeCloudUnbind: () async {
        expect(port.unbindCount, 0);
        return null;
      },
    );

    expect(succeeded, isTrue);
    expect(
      phases,
      containsAllInOrder(<RecordingCardUnbindPhase>[
        RecordingCardUnbindPhase.disconnectingDevice,
        RecordingCardUnbindPhase.unbindingCloud,
        RecordingCardUnbindPhase.completed,
      ]),
    );
    expect(port.unbindCount, 1);
  });

  test(
    'device-stage failure prevents cloud unbind and keeps binding',
    () async {
      final port = _FakeOwnershipPort(now: now)..binding = _binding(now);
      final controller = RecordingCardCloudBindingController(
        port: port,
        hardware: _FakeHardware.connected(),
        authenticated: true,
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.load();

      final succeeded = await controller.unbindCurrentCard(
        beforeCloudUnbind: () async => 'TEST_DEVICE_DISCONNECT_FAILED',
      );

      expect(succeeded, isFalse);
      expect(controller.state.unbindPhase, RecordingCardUnbindPhase.failed);
      expect(controller.state.binding?.bindingId, 'binding_1');
      expect(controller.state.errorCode, 'TEST_DEVICE_DISCONNECT_FAILED');
      expect(port.unbindCount, 0);
    },
  );

  test('bind requires connected idle hardware but unbind does not', () async {
    final port = _FakeOwnershipPort(now: now);
    final hardware = _FakeHardware();
    final controller = RecordingCardCloudBindingController(
      port: port,
      hardware: hardware,
      authenticated: true,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.load();

    expect(await controller.bindConnectedCard(), isFalse);
    expect(
      controller.state.errorCode,
      'RECORDING_CARD_ACCOUNT_BIND_NOT_CONNECTED',
    );

    hardware.snapshot = const RecordingCardBindingHardwareSnapshot(
      connected: true,
      recordingIdle: false,
      transferActive: false,
      commandBusy: false,
    );
    await controller.load();
    expect(await controller.bindConnectedCard(), isFalse);
    expect(
      controller.state.errorCode,
      'RECORDING_CARD_ACCOUNT_BIND_RECORDING_ACTIVE',
    );
  });

  test('connection authorization reuses a matching local SN cache', () async {
    final port = _FakeOwnershipPort(now: now);
    final ownership = _FakeOwnershipIdentityPort();
    final cache = _FakeAuthorizationCache();
    final authorization = RecordingCardCloudConnectionAuthorization(
      port: port,
      ownership: ownership,
      authenticated: true,
      authorizationCache: cache,
      clock: () => now,
      random: Random(13),
    );
    const device = RecordingCardDeviceState(
      connectionState: RecordingCardConnectionState.connected,
      displayName: 'Huahuo Recording Card',
    );

    expect((await authorization.authorizeConnection(device)).ok, isTrue);
    expect((await authorization.authorizeConnection(device)).ok, isTrue);

    expect(ownership.readCount, 2);
    expect(port.bindCount, 1);
    expect(cache.matchCount, 2);
    expect(cache.rememberCount, 1);
    expect(cache.serialNumber, 'SNAB1234');
    expect(port.lastSerialNumber, 'SNAB1234');
    expect(port.lastDisplayName, 'Huahuo Recording Card');
    expect(
      port.lastIdempotencyKey,
      matches(RegExp(r'^recording-card-connect-\d+-[a-f0-9]{24}$')),
    );
  });

  test('discovery cache match is read-only and avoids cloud binding', () async {
    final port = _FakeOwnershipPort(now: now);
    final cache = _FakeAuthorizationCache()..serialNumber = 'SP63A03003';
    final authorization = RecordingCardCloudConnectionAuthorization(
      port: port,
      ownership: _FakeOwnershipIdentityPort(),
      authenticated: true,
      authorizationCache: cache,
    );

    final cached = await authorization.matchesCachedSerial('sp63-a03003');
    final authorized = await authorization.authorizeDiscoveredDevice(
      serialNumber: 'SP63A03003',
      displayName: '会议录音卡',
    );

    expect(cached.value, isTrue);
    expect(authorized.value, isTrue);
    expect(port.bindCount, 0);
  });

  test('selected discovery preserves cloud rejection before BLE', () async {
    final port = _FakeOwnershipPort(now: now)
      ..bindError = 'RECORDING_CARD_ALREADY_BOUND';
    final authorization = RecordingCardCloudConnectionAuthorization(
      port: port,
      ownership: _FakeOwnershipIdentityPort(),
      authenticated: true,
    );

    final result = await authorization.authorizeDiscoveredDevice(
      serialNumber: 'SP63A03003',
      displayName: '会议录音卡',
    );

    expect(result.error?.code, 'RECORDING_CARD_ALREADY_BOUND');
    expect(port.bindCount, 1);
  });

  test('different cached SN falls back to the cloud', () async {
    final port = _FakeOwnershipPort(now: now)
      ..bindError = 'RECORDING_CARD_ACCOUNT_LIMIT_REACHED';
    final ownership = _FakeOwnershipIdentityPort(serialNumber: 'SP63A00002');
    final cache = _FakeAuthorizationCache()..serialNumber = 'SP63A00001';
    final authorization = RecordingCardCloudConnectionAuthorization(
      port: port,
      ownership: ownership,
      authenticated: true,
      authorizationCache: cache,
    );

    final result = await authorization.authorizeConnection(
      const RecordingCardDeviceState(
        connectionState: RecordingCardConnectionState.connected,
      ),
    );

    expect(result.error?.code, 'RECORDING_CARD_ACCOUNT_LIMIT_REACHED');
    expect(port.bindCount, 1);
    expect(port.lastSerialNumber, 'SP63A00002');
    expect(cache.serialNumber, 'SP63A00001');
    expect(cache.rememberCount, 0);
  });

  test('connection authorization propagates exact cloud rejection', () async {
    final port = _FakeOwnershipPort(now: now)
      ..bindError = 'RECORDING_CARD_ALREADY_BOUND';
    final ownership = _FakeOwnershipIdentityPort();
    final authorization = RecordingCardCloudConnectionAuthorization(
      port: port,
      ownership: ownership,
      authenticated: true,
    );

    final result = await authorization.authorizeConnection(
      const RecordingCardDeviceState(
        connectionState: RecordingCardConnectionState.connected,
      ),
    );

    expect(result.ok, isFalse);
    expect(result.error?.code, 'RECORDING_CARD_ALREADY_BOUND');
    expect(ownership.readCount, 1);
    expect(port.bindCount, 1);
  });

  test(
    'connection authorization rejects missing login before SN read',
    () async {
      final port = _FakeOwnershipPort(now: now);
      final ownership = _FakeOwnershipIdentityPort();
      final authorization = RecordingCardCloudConnectionAuthorization(
        port: port,
        ownership: ownership,
        authenticated: false,
      );

      final result = await authorization.authorizeConnection(
        const RecordingCardDeviceState(
          connectionState: RecordingCardConnectionState.connected,
        ),
      );

      expect(result.error?.code, 'RECORDING_CARD_CLOUD_BINDING_AUTH_REQUIRED');
      expect(ownership.readCount, 0);
      expect(port.bindCount, 0);
    },
  );

  test('SN normalization matches the Backend ownership contract', () {
    expect(
      normalizeRecordingCardSerialNumberForOwnership(' sn-ab:12 34 '),
      'SNAB1234',
    );
    expect(normalizeRecordingCardSerialNumberForOwnership('SN_BAD_1'), isNull);
    expect(normalizeRecordingCardSerialNumberForOwnership('short'), isNull);
  });
}

RecordingCardCloudBinding _binding(DateTime now) => RecordingCardCloudBinding(
  bindingId: 'binding_1',
  deviceId: 'device_1',
  serialNumberMasked: '****1234',
  status: 'active',
  bindingGeneration: 4,
  boundAt: now,
);

final class _FakeOwnershipPort implements RecordingCardCloudBindingPort {
  _FakeOwnershipPort({required this.now});

  final DateTime now;
  RecordingCardCloudBinding? binding;
  String? bindError;
  int bindCount = 0;
  int unbindCount = 0;
  String? lastSerialNumber;
  String? lastDisplayName;
  String? lastIdempotencyKey;

  @override
  Future<RecordingCardBindingResult<RecordingCardCloudBinding?>>
  currentBinding() async => RecordingCardBindingResult.success(binding);

  @override
  Future<RecordingCardBindingResult<RecordingCardCloudBinding>> bind({
    required String serialNumber,
    required String idempotencyKey,
    String? displayName,
  }) async {
    bindCount += 1;
    lastSerialNumber = serialNumber;
    lastDisplayName = displayName;
    lastIdempotencyKey = idempotencyKey;
    final error = bindError;
    if (error != null) return RecordingCardBindingResult.failure(error);
    binding = _binding(now);
    return RecordingCardBindingResult.success(binding!);
  }

  @override
  Future<RecordingCardBindingResult<bool>> unbind({
    required RecordingCardCloudBinding binding,
    required String idempotencyKey,
  }) async {
    unbindCount += 1;
    lastIdempotencyKey = idempotencyKey;
    this.binding = null;
    return RecordingCardBindingResult.success(true);
  }
}

final class _FakeHardware implements RecordingCardCloudBindingHardwarePort {
  _FakeHardware({
    this.snapshot = const RecordingCardBindingHardwareSnapshot(
      connected: false,
      recordingIdle: true,
      transferActive: false,
      commandBusy: false,
    ),
  });

  factory _FakeHardware.connected() => _FakeHardware(
    snapshot: const RecordingCardBindingHardwareSnapshot(
      connected: true,
      recordingIdle: true,
      transferActive: false,
      commandBusy: false,
    ),
  );

  RecordingCardBindingHardwareSnapshot snapshot;
  int readCount = 0;

  @override
  RecordingCardBindingHardwareSnapshot get bindingSnapshot => snapshot;

  @override
  Future<RecordingCardResult<RecordingCardOwnershipIdentity>>
  readIdentity() async {
    readCount += 1;
    return RecordingCardResult.success(
      const RecordingCardOwnershipIdentity(serialNumber: 'SNABC1234'),
    );
  }
}

final class _FakeOwnershipIdentityPort
    implements RecordingCardOwnershipProofPort {
  _FakeOwnershipIdentityPort({this.serialNumber = 'sn-ab:12 34'});

  final String serialNumber;
  int readCount = 0;

  @override
  Future<RecordingCardResult<RecordingCardOwnershipIdentity>>
  readAccountBindingIdentity() async {
    readCount += 1;
    return RecordingCardResult.success(
      RecordingCardOwnershipIdentity(serialNumber: serialNumber),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardOwnershipProof>>
  signAccountBindingChallenge({required String payloadJson}) async {
    return RecordingCardResult.failure(
      recordingCardFailure(
        'UNUSED',
        'SN-only authorization must not request a challenge signature',
      ),
    );
  }
}

final class _FakeAuthorizationCache
    implements RecordingCardSnAuthorizationCachePort {
  String? serialNumber;
  int matchCount = 0;
  int rememberCount = 0;
  int clearCount = 0;

  @override
  Future<bool> matches(String serialNumber) async {
    matchCount += 1;
    return this.serialNumber == serialNumber;
  }

  @override
  Future<void> remember(String serialNumber) async {
    rememberCount += 1;
    this.serialNumber = serialNumber;
  }

  @override
  Future<void> clear() async {
    clearCount += 1;
    serialNumber = null;
  }
}
