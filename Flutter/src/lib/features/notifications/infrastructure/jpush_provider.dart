import 'dart:async';
import 'dart:io';

import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:jpush_flutter/jpush_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/native/platform_permissions_port.dart';
import '../domain/push_message.dart';
import 'push_provider.dart';

final class JPushProvider implements PushProvider {
  JPushProvider({
    required PushRuntimeConfig config,
    required PlatformPermissionsPort permissions,
    JPushFlutterInterface? jpush,
  }) : _config = config,
       _permissions = permissions,
       _jpush = jpush ?? JPush.newJPush();

  final PushRuntimeConfig _config;
  final PlatformPermissionsPort _permissions;
  final JPushFlutterInterface _jpush;
  final _foreground = StreamController<PushParseResult>.broadcast();
  final _opened = StreamController<PushParseResult>.broadcast();
  final _connections = StreamController<void>.broadcast();
  bool _initialized = false;
  Future<void>? _initialization;
  bool _disposed = false;
  Future<PushParseResult?>? _initialMessageRead;
  bool? _platformConfigured;

  static const _platformChannel = MethodChannel(
    'huahuoai/platform_permissions',
  );

  @override
  bool get isConfigured =>
      !_disposed && _config.isConfigured && _platformConfigured != false;

  @override
  Stream<void> get connections => _connections.stream;

  @override
  Stream<PushParseResult> get foregroundMessages => _foreground.stream;

  @override
  Stream<PushParseResult> get openedMessages => _opened.stream;

  @override
  Future<void> initialize() {
    if (_initialized || _disposed || !isConfigured) return Future<void>.value();
    final active = _initialization;
    if (active != null) return active;
    final future = _initializeOnce();
    _initialization = future;
    return future.whenComplete(() => _initialization = null);
  }

  Future<void> _initializeOnce() async {
    if (_initialized || _disposed || !isConfigured) return;
    if (Platform.isAndroid) {
      try {
        _platformConfigured =
            await _platformChannel.invokeMethod<bool>(
              'isJPushConfigured',
              <String, Object?>{'appKey': _config.appKey},
            ) ??
            false;
      } on MissingPluginException {
        _platformConfigured = false;
      }
      if (_disposed || !isConfigured) return;
    }
    _jpush.addEventHandler(
      onReceiveNotification: (payload) async {
        if (_disposed) return;
        if (Platform.isAndroid &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          _clearAndroidForegroundNotification(payload);
        }
        _foreground.add(
          parsePushMessage(payload, receiveType: PushReceiveType.foreground),
        );
      },
      onOpenNotification: (payload) async {
        if (_disposed) return;
        _opened.add(
          parsePushMessage(payload, receiveType: PushReceiveType.opened),
        );
      },
      onConnected: (_) async {
        if (!_disposed) _connections.add(null);
      },
      onReceiveMessage: (_) async {},
      onReceiveNotificationAuthorization: (_) async {},
      onNotifyMessageUnShow: (_) async {},
      onInAppMessageClick: (_) async {},
      onInAppMessageShow: (_) async {},
      onNotifyButtonClick: (_) async {},
      onCommandResult: (_) async {},
      onReceiveDeviceToken: (_) async {},
      onVoipMessage: (_) async {},
    );
    _jpush.setup(
      appKey: _config.appKey,
      channel: _config.channel,
      production: _config.production,
      debug: _config.debug,
    );
    if (Platform.isIOS) {
      _jpush.setUnShowAtTheForeground(unShow: true);
    }
    _initialized = true;
  }

  @override
  Future<bool> requestPermission() async {
    if (!isConfigured) return false;
    final result = await _permissions.requestPermissions(
      const <PlatformPermissionKind>{PlatformPermissionKind.notification},
    );
    final granted = _readNotificationPermission(result);
    if (!granted) return false;
    await initialize();
    if (!isConfigured) return false;
    if (Platform.isIOS) {
      _jpush.applyPushAuthority(
        const NotificationSettingsIOS(sound: true, alert: true, badge: true),
      );
    }
    return granted;
  }

  @override
  Future<bool> isNotificationEnabled() async {
    if (!isConfigured) return false;
    final permission = await _permissions.loadPermissionSummary();
    if (!_readNotificationPermission(permission)) {
      return false;
    }
    await initialize();
    if (!isConfigured) return false;
    try {
      return await _jpush.isNotificationEnabled();
    } catch (_) {
      throw const PushProviderFailure('PUSH_NOTIFICATION_STATUS_UNAVAILABLE');
    }
  }

  @override
  Future<String?> getRegistrationId() async {
    if (!isConfigured) return null;
    await initialize();
    if (!isConfigured) return null;
    try {
      final value = (await _jpush.getRegistrationID()).trim();
      return RegExp(r'^[A-Za-z0-9_-]{8,256}$').hasMatch(value) ? value : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PushParseResult?> getInitialMessage() {
    if (!isConfigured) return Future<PushParseResult?>.value();
    return _initialMessageRead ??= _readInitialMessage();
  }

  Future<PushParseResult?> _readInitialMessage() async {
    try {
      await initialize();
      if (!isConfigured) {
        throw const PushProviderFailure('PUSH_INITIAL_MESSAGE_UNAVAILABLE');
      }
      final payload = await _jpush.getLaunchAppNotification();
      if (payload.isEmpty) return null;
      return parsePushMessage(payload, receiveType: PushReceiveType.coldStart);
    } catch (_) {
      _initialMessageRead = null;
      throw const PushProviderFailure('PUSH_INITIAL_MESSAGE_UNAVAILABLE');
    }
  }

  bool _readNotificationPermission(
    PlatformPermissionResult<List<PlatformPermissionSummary>> result,
  ) {
    if (!result.ok || result.value == null) {
      throw const PushProviderFailure('PUSH_PERMISSION_STATUS_UNAVAILABLE');
    }
    for (final permission in result.value!) {
      if (permission.kind != PlatformPermissionKind.notification) continue;
      return switch (permission.status) {
        PlatformPermissionStatus.granted => true,
        PlatformPermissionStatus.denied ||
        PlatformPermissionStatus.blocked ||
        PlatformPermissionStatus.notDetermined => false,
        PlatformPermissionStatus.unavailable ||
        PlatformPermissionStatus.systemManaged =>
          throw const PushProviderFailure('PUSH_PERMISSION_STATUS_UNAVAILABLE'),
      };
    }
    throw const PushProviderFailure('PUSH_PERMISSION_STATUS_UNAVAILABLE');
  }

  void _clearAndroidForegroundNotification(Map<String, dynamic> payload) {
    final extras = payload['extras'];
    if (extras is! Map) return;
    final rawId = extras['cn.jpush.android.NOTIFICATION_ID'];
    final notificationId = rawId is int
        ? rawId
        : int.tryParse(rawId?.toString() ?? '');
    if (notificationId != null && notificationId > 0) {
      _jpush.clearNotification(notificationId: notificationId);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait<void>(<Future<void>>[
      _foreground.close(),
      _opened.close(),
      _connections.close(),
    ]);
  }
}
