import 'notification_models.dart';

final class PushDeviceRegistration {
  const PushDeviceRegistration({
    required this.deviceId,
    required this.platform,
    required this.pushProvider,
    required this.pushToken,
    required this.notificationPermission,
    required this.appVersion,
  });

  final String deviceId;
  final String platform;
  final String pushProvider;
  final String pushToken;
  final String notificationPermission;
  final String appVersion;

  bool get isValid =>
      isSafeNotificationIdentifier(deviceId) &&
      (platform == 'ios' || platform == 'android') &&
      pushProvider == 'jpush' &&
      RegExp(r'^[A-Za-z0-9_-]{8,256}$').hasMatch(pushToken) &&
      notificationPermission == 'authorized' &&
      RegExp(r'^[0-9A-Za-z.+-]{1,64}$').hasMatch(appVersion);

  Map<String, Object?> toJson() => <String, Object?>{
    'deviceId': deviceId,
    'platform': platform,
    'pushProvider': pushProvider,
    'pushToken': pushToken,
    'notificationPermission': notificationPermission,
    'appVersion': appVersion,
  };
}

final class PushDeviceMutationReceipt {
  const PushDeviceMutationReceipt({
    required this.deviceId,
    required this.status,
    required this.updatedAt,
  });

  factory PushDeviceMutationReceipt.fromJson(Map<String, Object?> json) {
    if (json.length != 3 ||
        !json.keys.toSet().containsAll(const <String>{
          'deviceId',
          'status',
          'updatedAt',
        })) {
      throw const FormatException('push device receipt fields are invalid');
    }
    final deviceId = json['deviceId'];
    final status = json['status'];
    final updatedAt = json['updatedAt'];
    if (deviceId is! String || !isSafeNotificationIdentifier(deviceId)) {
      throw const FormatException('deviceId is invalid');
    }
    if (status is! String ||
        !const <String>{'active', 'revoked'}.contains(status)) {
      throw const FormatException('status is invalid');
    }
    if (updatedAt is! String ||
        !_timestampWithTimezone.hasMatch(updatedAt) ||
        DateTime.tryParse(updatedAt) == null) {
      throw const FormatException('updatedAt is invalid');
    }
    return PushDeviceMutationReceipt(
      deviceId: deviceId,
      status: status,
      updatedAt: updatedAt,
    );
  }

  final String deviceId;
  final String status;
  final String updatedAt;
}

final RegExp _timestampWithTimezone = RegExp(
  r'^\d{4}-\d{2}-\d{2}T.+(?:[zZ]|[+-]\d{2}:\d{2})$',
);
