import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

typedef DeviceIdGenerator = String Function();

abstract interface class DeviceIdentityDriver {
  FutureOr<String?> read({required String key});

  FutureOr<bool> write({required String key, required String value});
}

final class FlutterSecureDeviceIdentityDriver implements DeviceIdentityDriver {
  const FlutterSecureDeviceIdentityDriver({
    this.storage = const FlutterSecureStorage(),
  });

  final FlutterSecureStorage storage;

  @override
  Future<String?> read({required String key}) => storage.read(key: key);

  @override
  Future<bool> write({required String key, required String value}) async {
    await storage.write(key: key, value: value);
    return true;
  }
}

final class ApplicationSupportDeviceIdentityDriver
    implements DeviceIdentityDriver {
  ApplicationSupportDeviceIdentityDriver({
    Future<Directory> Function()? applicationSupportDirectory,
  }) : _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       _useIosSandbox = applicationSupportDirectory == null;

  final Future<Directory> Function() _applicationSupportDirectory;
  final bool _useIosSandbox;

  @override
  Future<String?> read({required String key}) async {
    final pendingFile = _file();
    final file = pendingFile is File ? pendingFile : await pendingFile;
    final existsWatch = Stopwatch()..start();
    final exists = file.existsSync();
    _logDeviceIdentityStage('mirror_file_exists_complete', existsWatch);
    if (!exists) return null;
    final readWatch = Stopwatch()..start();
    final value = file.readAsStringSync().trim();
    _logDeviceIdentityStage('mirror_file_read_complete', readWatch);
    return value;
  }

  @override
  Future<bool> write({required String key, required String value}) async {
    final pendingFile = _file();
    final file = pendingFile is File ? pendingFile : await pendingFile;
    final temporary = File('${file.path}.tmp');
    try {
      file.parent.createSync(recursive: true);
      if (temporary.existsSync()) temporary.deleteSync();
      temporary.writeAsStringSync(value);
      if (file.existsSync()) file.deleteSync();
      temporary.renameSync(file.path);
      return true;
    } catch (_) {
      if (temporary.existsSync()) temporary.deleteSync();
      return false;
    }
  }

  FutureOr<File> _file() {
    if (_useIosSandbox && Platform.isIOS) {
      final container = Directory.systemTemp.parent;
      _logDeviceIdentityStage('support_directory_ios_sandbox');
      return _fileUnder(
        Directory(
          '${container.path}${Platform.pathSeparator}Library'
          '${Platform.pathSeparator}Application Support',
        ),
      );
    }
    final watch = Stopwatch()..start();
    _logDeviceIdentityStage('support_directory_start');
    return _applicationSupportDirectory().then((root) {
      _logDeviceIdentityStage('support_directory_success', watch);
      return _fileUnder(root);
    });
  }

  File _fileUnder(Directory root) {
    return File(
      '${root.path}${Platform.pathSeparator}HuahuoAI'
      '${Platform.pathSeparator}install-device-id',
    );
  }
}

final class ResilientDeviceIdentityDriver implements DeviceIdentityDriver {
  const ResilientDeviceIdentityDriver({
    required this.primary,
    required this.fallback,
    this.primaryOperationTimeout = const Duration(seconds: 2),
  });

  final DeviceIdentityDriver primary;
  final DeviceIdentityDriver fallback;
  final Duration primaryOperationTimeout;

  @override
  Future<String?> read({required String key}) async {
    final fallbackWatch = Stopwatch()..start();
    _logDeviceIdentityStage('fallback_read_start');
    try {
      final value = await fallback.read(key: key);
      _logDeviceIdentityStage(
        value == null ? 'fallback_read_empty' : 'fallback_read_success',
        fallbackWatch,
      );
      if (value != null) return value;
    } catch (_) {
      _logDeviceIdentityStage('fallback_read_failed', fallbackWatch);
    }

    final primaryWatch = Stopwatch()..start();
    _logDeviceIdentityStage('primary_read_start');
    try {
      final value = await Future<String?>.value(
        primary.read(key: key),
      ).timeout(primaryOperationTimeout);
      _logDeviceIdentityStage(
        value == null ? 'primary_read_empty' : 'primary_read_success',
        primaryWatch,
      );
      if (value != null) {
        unawaited(_refreshFallback(key: key, value: value));
        return value;
      }
    } on TimeoutException {
      _logDeviceIdentityStage('primary_read_timeout', primaryWatch);
    } catch (_) {
      _logDeviceIdentityStage('primary_read_failed', primaryWatch);
      return null;
    }
    return null;
  }

  @override
  Future<bool> write({required String key, required String value}) async {
    final fallbackWatch = Stopwatch()..start();
    _logDeviceIdentityStage('fallback_write_start');
    try {
      if (await fallback.write(key: key, value: value)) {
        _logDeviceIdentityStage('fallback_write_success', fallbackWatch);
        return true;
      }
    } catch (_) {
      _logDeviceIdentityStage('fallback_write_failed', fallbackWatch);
    }

    final primaryWatch = Stopwatch()..start();
    _logDeviceIdentityStage('primary_write_start');
    try {
      final saved = await Future<bool>.value(
        primary.write(key: key, value: value),
      ).timeout(primaryOperationTimeout);
      _logDeviceIdentityStage(
        saved ? 'primary_write_success' : 'primary_write_rejected',
        primaryWatch,
      );
      return saved;
    } catch (_) {
      _logDeviceIdentityStage('primary_write_failed', primaryWatch);
      return false;
    }
  }

  Future<void> _refreshFallback({
    required String key,
    required String value,
  }) async {
    final watch = Stopwatch()..start();
    _logDeviceIdentityStage('mirror_refresh_start');
    try {
      await fallback.write(key: key, value: value);
      _logDeviceIdentityStage('mirror_refresh_success', watch);
    } catch (_) {
      _logDeviceIdentityStage('mirror_refresh_failed', watch);
      // The secure value remains authoritative when mirroring is unavailable.
    }
  }
}

void _logDeviceIdentityStage(String stage, [Stopwatch? watch]) {
  final elapsed = watch == null
      ? ''
      : ' elapsed_ms=${watch.elapsedMilliseconds}';
  debugPrint('HUAHUO_DEVICE_IDENTITY stage=$stage$elapsed');
}

final class DeviceIdentityException implements Exception {
  const DeviceIdentityException(this.code, [this.cause]);

  final String code;
  final Object? cause;

  @override
  String toString() => code;
}

final class DeviceIdentityStore {
  DeviceIdentityStore({
    required DeviceIdentityDriver driver,
    String? overrideDeviceId,
    DeviceIdGenerator? generateDeviceId,
  }) : _driver = driver,
       _overrideDeviceId =
           overrideDeviceId ?? const String.fromEnvironment('HUAHUO_DEVICE_ID'),
       _generateDeviceId = generateDeviceId ?? generateInstallDeviceId;

  static const storageKey = 'huahuo.ai.install.device-id';

  final DeviceIdentityDriver _driver;
  final String _overrideDeviceId;
  final DeviceIdGenerator _generateDeviceId;
  Future<String>? _pendingResolution;

  Future<String> resolve() {
    final pending = _pendingResolution;
    if (pending != null) {
      return pending;
    }

    final next = _resolve();
    _pendingResolution = next;
    next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        if (identical(_pendingResolution, next)) {
          _pendingResolution = null;
        }
      },
    );
    return next;
  }

  Future<String> _resolve() async {
    if (_overrideDeviceId.isNotEmpty) {
      if (!isSafeDeviceId(_overrideDeviceId)) {
        throw const DeviceIdentityException('DEVICE_IDENTITY_OVERRIDE_INVALID');
      }
      return _overrideDeviceId;
    }

    final stored = await _readStoredDeviceId();
    if (stored != null && isSafeDeviceId(stored)) {
      return stored;
    }

    final String generated;
    try {
      generated = _generateDeviceId();
    } catch (cause) {
      throw DeviceIdentityException('DEVICE_IDENTITY_GENERATION_FAILED', cause);
    }
    if (!isSafeDeviceId(generated)) {
      throw const DeviceIdentityException('DEVICE_IDENTITY_GENERATION_FAILED');
    }

    try {
      final written = await _driver.write(key: storageKey, value: generated);
      if (!written) {
        throw const DeviceIdentityException('DEVICE_IDENTITY_WRITE_FAILED');
      }
    } on DeviceIdentityException {
      rethrow;
    } catch (cause) {
      throw DeviceIdentityException('DEVICE_IDENTITY_WRITE_FAILED', cause);
    }
    return generated;
  }

  Future<String?> _readStoredDeviceId() async {
    try {
      return await _driver.read(key: storageKey);
    } catch (cause) {
      throw DeviceIdentityException('DEVICE_IDENTITY_READ_FAILED', cause);
    }
  }
}

bool isSafeDeviceId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$').hasMatch(value);
}

String generateInstallDeviceId() {
  final random = Random.secure();
  final suffix = List<String>.generate(
    20,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    growable: false,
  ).join();
  return 'flutter-$suffix';
}
