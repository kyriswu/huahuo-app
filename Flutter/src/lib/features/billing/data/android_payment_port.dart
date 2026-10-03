// ignore_for_file: prefer_initializing_formals

import 'package:flutter/services.dart';
import 'package:huahuo_api/huahuo_api.dart';

enum AndroidPaymentClientResult { returned, cancelled, unavailable, failed }

final class AndroidPaymentEvent {
  const AndroidPaymentEvent({
    required this.provider,
    required this.orderId,
    required this.result,
    this.clientCode,
  });

  final BillingProvider provider;
  final String orderId;
  final AndroidPaymentClientResult result;
  final String? clientCode;
}

abstract interface class AndroidPaymentPort {
  Stream<AndroidPaymentEvent> get events;

  Future<bool> isAvailable(BillingProvider provider);

  Future<AndroidPaymentClientResult> start({
    required BillingProvider provider,
    required String orderId,
    required Map<String, Object?> launchPayload,
  });
}

final class MethodChannelAndroidPaymentPort implements AndroidPaymentPort {
  MethodChannelAndroidPaymentPort({
    MethodChannel methodChannel = const MethodChannel('huahuoai/payment'),
    EventChannel eventChannel = const EventChannel('huahuoai/payment/events'),
  }) : _methodChannel = methodChannel,
       _events = eventChannel.receiveBroadcastStream().map(_parseEvent);

  final MethodChannel _methodChannel;
  final Stream<AndroidPaymentEvent> _events;

  @override
  Stream<AndroidPaymentEvent> get events => _events;

  @override
  Future<bool> isAvailable(BillingProvider provider) async {
    if (provider == BillingProvider.appStore) return false;
    try {
      return await _methodChannel.invokeMethod<bool>(
            provider == BillingProvider.wechat
                ? 'isWechatInstalled'
                : 'isAlipayAvailable',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<AndroidPaymentClientResult> start({
    required BillingProvider provider,
    required String orderId,
    required Map<String, Object?> launchPayload,
  }) async {
    if (provider == BillingProvider.appStore || !_safeID.hasMatch(orderId)) {
      return AndroidPaymentClientResult.failed;
    }
    try {
      final result = await _methodChannel.invokeMethod<String>(
        provider == BillingProvider.wechat
            ? 'startWechatPay'
            : 'startAlipayPay',
        <String, Object?>{'orderId': orderId, ...launchPayload},
      );
      return _clientResult(result);
    } on PlatformException catch (error) {
      return error.code == 'PAYMENT_PROVIDER_NOT_CONFIGURED'
          ? AndroidPaymentClientResult.unavailable
          : AndroidPaymentClientResult.failed;
    } on MissingPluginException {
      return AndroidPaymentClientResult.unavailable;
    }
  }
}

AndroidPaymentEvent _parseEvent(Object? value) {
  if (value is! Map) throw const FormatException('payment event must be a map');
  final provider = switch (value['provider']) {
    'wechat' => BillingProvider.wechat,
    'alipay' => BillingProvider.alipay,
    _ => throw const FormatException('payment event provider is invalid'),
  };
  final orderId = value['orderId'];
  final result = value['result'];
  if (orderId is! String || !_safeID.hasMatch(orderId) || result is! String) {
    throw const FormatException('payment event is invalid');
  }
  return AndroidPaymentEvent(
    provider: provider,
    orderId: orderId,
    result: _clientResult(result),
    clientCode: value['clientCode'] is String
        ? value['clientCode'] as String
        : null,
  );
}

AndroidPaymentClientResult _clientResult(String? value) => switch (value) {
  'returned' => AndroidPaymentClientResult.returned,
  'cancelled' => AndroidPaymentClientResult.cancelled,
  'unavailable' => AndroidPaymentClientResult.unavailable,
  _ => AndroidPaymentClientResult.failed,
};

final _safeID = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$');
