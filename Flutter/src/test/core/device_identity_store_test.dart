import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/device/device_identity_store.dart';

void main() {
  group('DeviceIdentityStore', () {
    test(
      'reuses a valid stored install identity without rewriting it',
      () async {
        final driver = _MemoryDeviceIdentityDriver(
          value: 'flutter-stored-00000001',
        );
        final store = DeviceIdentityStore(
          driver: driver,
          generateDeviceId: () => 'flutter-generated-00000001',
        );

        final deviceId = await store.resolve();

        expect(deviceId, 'flutter-stored-00000001');
        expect(driver.readCount, 1);
        expect(driver.writeCount, 0);
      },
    );

    test(
      'generates and persists one safe identity for concurrent callers',
      () async {
        final driver = _MemoryDeviceIdentityDriver();
        var generatedCount = 0;
        final store = DeviceIdentityStore(
          driver: driver,
          generateDeviceId: () {
            generatedCount += 1;
            return 'flutter-generated-00000001';
          },
        );

        final resolved = await Future.wait<String>([
          store.resolve(),
          store.resolve(),
          store.resolve(),
        ]);

        expect(resolved, everyElement('flutter-generated-00000001'));
        expect(generatedCount, 1);
        expect(driver.value, 'flutter-generated-00000001');
        expect(driver.writeCount, 1);
        expect(isSafeDeviceId(resolved.first), isTrue);
      },
    );

    test(
      'valid explicit override takes precedence without touching storage',
      () async {
        final driver = _MemoryDeviceIdentityDriver(
          value: 'flutter-stored-00000001',
          throwOnRead: true,
        );
        final store = DeviceIdentityStore(
          driver: driver,
          overrideDeviceId: 'ci-device-000000001',
        );

        expect(await store.resolve(), 'ci-device-000000001');
        expect(driver.readCount, 0);
        expect(driver.writeCount, 0);
      },
    );

    test(
      'rejects malformed explicit override instead of falling back',
      () async {
        final store = DeviceIdentityStore(
          driver: _MemoryDeviceIdentityDriver(),
          overrideDeviceId: 'unsafe device id',
        );

        await expectLater(
          store.resolve(),
          throwsA(
            isA<DeviceIdentityException>().having(
              (error) => error.code,
              'code',
              'DEVICE_IDENTITY_OVERRIDE_INVALID',
            ),
          ),
        );
      },
    );

    test(
      'replaces malformed stored identity only after a safe write',
      () async {
        final driver = _MemoryDeviceIdentityDriver(value: 'not safe');
        final store = DeviceIdentityStore(
          driver: driver,
          generateDeviceId: () => 'flutter-replacement-000001',
        );

        expect(await store.resolve(), 'flutter-replacement-000001');
        expect(driver.value, 'flutter-replacement-000001');
        expect(driver.writeCount, 1);
      },
    );

    test('fails closed when persistent storage cannot read or write', () async {
      final readFailure = DeviceIdentityStore(
        driver: _MemoryDeviceIdentityDriver(throwOnRead: true),
      );
      final writeFailure = DeviceIdentityStore(
        driver: _MemoryDeviceIdentityDriver(writeSucceeds: false),
        generateDeviceId: () => 'flutter-generated-00000001',
      );
      final generationFailure = DeviceIdentityStore(
        driver: _MemoryDeviceIdentityDriver(),
        generateDeviceId: () => throw StateError('random unavailable'),
      );

      await expectLater(
        readFailure.resolve(),
        throwsA(
          isA<DeviceIdentityException>().having(
            (error) => error.code,
            'code',
            'DEVICE_IDENTITY_READ_FAILED',
          ),
        ),
      );
      await expectLater(
        writeFailure.resolve(),
        throwsA(
          isA<DeviceIdentityException>().having(
            (error) => error.code,
            'code',
            'DEVICE_IDENTITY_WRITE_FAILED',
          ),
        ),
      );
      await expectLater(
        generationFailure.resolve(),
        throwsA(
          isA<DeviceIdentityException>().having(
            (error) => error.code,
            'code',
            'DEVICE_IDENTITY_GENERATION_FAILED',
          ),
        ),
      );
    });

    test(
      'uses the app-private fallback when the primary backend fails',
      () async {
        final fallback = _MemoryDeviceIdentityDriver(
          value: 'flutter-fallback-00000001',
        );
        final driver = ResilientDeviceIdentityDriver(
          primary: _MemoryDeviceIdentityDriver(throwOnRead: true),
          fallback: fallback,
        );

        expect(
          await DeviceIdentityStore(driver: driver).resolve(),
          'flutter-fallback-00000001',
        );
      },
    );

    test(
      'uses the app-private fallback when the primary backend hangs',
      () async {
        final driver = ResilientDeviceIdentityDriver(
          primary: _PendingDeviceIdentityDriver(),
          fallback: _MemoryDeviceIdentityDriver(
            value: 'flutter-fallback-00000001',
          ),
          primaryOperationTimeout: const Duration(milliseconds: 1),
        );

        expect(
          await DeviceIdentityStore(driver: driver).resolve(),
          'flutter-fallback-00000001',
        );
      },
    );

    test('does not await mirror refresh after a primary read', () async {
      final driver = ResilientDeviceIdentityDriver(
        primary: _MemoryDeviceIdentityDriver(
          value: 'flutter-primary-000000001',
        ),
        fallback: _ReadNullWritePendingDeviceIdentityDriver(),
      );

      expect(
        await DeviceIdentityStore(
          driver: driver,
        ).resolve().timeout(const Duration(milliseconds: 100)),
        'flutter-primary-000000001',
      );
    });

    test('persists when either private backend remains writable', () async {
      final fallback = _MemoryDeviceIdentityDriver();
      final driver = ResilientDeviceIdentityDriver(
        primary: _MemoryDeviceIdentityDriver(writeSucceeds: false),
        fallback: fallback,
      );
      final store = DeviceIdentityStore(
        driver: driver,
        generateDeviceId: () => 'flutter-generated-00000001',
      );

      expect(await store.resolve(), 'flutter-generated-00000001');
      expect(fallback.value, 'flutter-generated-00000001');
    });
  });
}

final class _MemoryDeviceIdentityDriver implements DeviceIdentityDriver {
  _MemoryDeviceIdentityDriver({
    this.value,
    this.throwOnRead = false,
    this.writeSucceeds = true,
  });

  String? value;
  final bool throwOnRead;
  final bool writeSucceeds;
  var readCount = 0;
  var writeCount = 0;

  @override
  FutureOr<String?> read({required String key}) {
    readCount += 1;
    if (throwOnRead) {
      throw StateError('read failed');
    }
    return value;
  }

  @override
  FutureOr<bool> write({required String key, required String value}) {
    writeCount += 1;
    if (writeSucceeds) {
      this.value = value;
    }
    return writeSucceeds;
  }
}

final class _PendingDeviceIdentityDriver implements DeviceIdentityDriver {
  @override
  Future<String?> read({required String key}) => Completer<String?>().future;

  @override
  Future<bool> write({required String key, required String value}) =>
      Completer<bool>().future;
}

final class _ReadNullWritePendingDeviceIdentityDriver
    implements DeviceIdentityDriver {
  @override
  String? read({required String key}) => null;

  @override
  Future<bool> write({required String key, required String value}) =>
      Completer<bool>().future;
}
