import '../../../core/native/platform_permissions_port.dart';
import '../domain/push_message.dart';

final class PushProviderFailure implements Exception {
  const PushProviderFailure(this.code);

  final String code;
}

final class PushRuntimeConfig {
  const PushRuntimeConfig({
    required this.appKey,
    this.channel = 'huahuo-production',
    this.production = true,
    this.debug = false,
  });

  factory PushRuntimeConfig.fromEnvironment() => const PushRuntimeConfig(
    appKey: String.fromEnvironment('JPUSH_APP_KEY'),
    channel: String.fromEnvironment(
      'JPUSH_CHANNEL',
      defaultValue: 'huahuo-production',
    ),
    production:
        bool.fromEnvironment('dart.vm.product') ||
        bool.fromEnvironment('dart.vm.profile') ||
        bool.fromEnvironment('JPUSH_APNS_PRODUCTION'),
    debug: bool.fromEnvironment('JPUSH_SDK_DEBUG'),
  );

  final String appKey;
  final String channel;
  final bool production;
  final bool debug;

  bool get isConfigured => RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(appKey);
}

abstract interface class PushProvider {
  bool get isConfigured;
  Future<void> initialize();
  Future<bool> requestPermission();
  Future<bool> isNotificationEnabled();
  Future<String?> getRegistrationId();
  Future<PushParseResult?> getInitialMessage();
  Stream<PushParseResult> get foregroundMessages;
  Stream<PushParseResult> get openedMessages;
  Stream<void> get connections;
  Future<void> dispose();
}

final class UnavailablePushProvider implements PushProvider {
  const UnavailablePushProvider();

  @override
  bool get isConfigured => false;

  @override
  Stream<void> get connections => const Stream<void>.empty();

  @override
  Stream<PushParseResult> get foregroundMessages =>
      const Stream<PushParseResult>.empty();

  @override
  Stream<PushParseResult> get openedMessages =>
      const Stream<PushParseResult>.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<String?> getRegistrationId() async => null;

  @override
  Future<PushParseResult?> getInitialMessage() async => null;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isNotificationEnabled() async => false;

  @override
  Future<bool> requestPermission() async => false;
}

bool notificationPermissionGranted(List<PlatformPermissionSummary>? rows) {
  if (rows == null) return false;
  for (final row in rows) {
    if (row.kind == PlatformPermissionKind.notification) {
      return row.status == PlatformPermissionStatus.granted;
    }
  }
  return false;
}
