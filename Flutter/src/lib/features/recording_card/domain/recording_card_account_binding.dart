final class RecordingCardBindingResult<T> {
  const RecordingCardBindingResult._({
    required this.ok,
    this.value,
    this.errorCode,
  });

  factory RecordingCardBindingResult.success(T value) {
    return RecordingCardBindingResult<T>._(ok: true, value: value);
  }

  factory RecordingCardBindingResult.failure(String errorCode) {
    return RecordingCardBindingResult<T>._(ok: false, errorCode: errorCode);
  }

  final bool ok;
  final T? value;
  final String? errorCode;
}

final class RecordingCardCloudBinding {
  const RecordingCardCloudBinding({
    required this.bindingId,
    required this.deviceId,
    required this.serialNumberMasked,
    required this.status,
    required this.bindingGeneration,
    required this.boundAt,
    this.displayName,
    this.modelCode,
    this.firmwareVersion,
  });

  final String bindingId;
  final String deviceId;
  final String serialNumberMasked;
  final String? displayName;
  final String? modelCode;
  final String? firmwareVersion;
  final String status;
  final int bindingGeneration;
  final DateTime boundAt;
}

abstract interface class RecordingCardCloudBindingPort {
  Future<RecordingCardBindingResult<RecordingCardCloudBinding?>>
  currentBinding();

  Future<RecordingCardBindingResult<RecordingCardCloudBinding>> bind({
    required String serialNumber,
    required String idempotencyKey,
    String? displayName,
  });

  Future<RecordingCardBindingResult<bool>> unbind({
    required RecordingCardCloudBinding binding,
    required String idempotencyKey,
  });
}

abstract interface class RecordingCardSnAuthorizationCachePort {
  Future<bool> matches(String serialNumber);

  Future<void> remember(String serialNumber);

  Future<void> clear();
}

final class UnavailableRecordingCardSnAuthorizationCache
    implements RecordingCardSnAuthorizationCachePort {
  const UnavailableRecordingCardSnAuthorizationCache();

  @override
  Future<bool> matches(String serialNumber) async => false;

  @override
  Future<void> remember(String serialNumber) async {}

  @override
  Future<void> clear() async {}
}

String? normalizeRecordingCardSerialNumberForOwnership(String value) {
  final normalized = StringBuffer();
  for (final codeUnit in value.trim().codeUnits) {
    if (codeUnit >= 0x61 && codeUnit <= 0x7a) {
      normalized.writeCharCode(codeUnit - 0x20);
    } else if ((codeUnit >= 0x41 && codeUnit <= 0x5a) ||
        (codeUnit >= 0x30 && codeUnit <= 0x39)) {
      normalized.writeCharCode(codeUnit);
    } else if (codeUnit == 0x2d ||
        codeUnit == 0x3a ||
        codeUnit == 0x20 ||
        codeUnit == 0x09) {
      continue;
    } else {
      return null;
    }
  }
  final result = normalized.toString();
  return result.length >= 6 && result.length <= 64 ? result : null;
}
