import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';
import 'billing_models.dart';

final class BillingClient {
  const BillingClient(this._api);

  final ApiClient _api;

  Future<ApiResult<BillingCatalog>> catalog(BillingPlatform platform) =>
      _api.request<BillingCatalog>(
        ApiRequestOptions<BillingCatalog>(
          endpointId: 'billingCatalog',
          query: <String, Object?>{'platform': platform.name},
          parseData: (value) =>
              BillingCatalog.fromValue(value, platform: platform),
        ),
      );

  Future<ApiResult<PaymentOrder>> createAndroidOrder({
    required String sku,
    required BillingProvider provider,
    required String clientOrderKey,
    required Map<String, String> agreementVersions,
    required String idempotencyKey,
  }) {
    if (provider != BillingProvider.wechat &&
        provider != BillingProvider.alipay) {
      throw ArgumentError.value(
        provider,
        'provider',
        'Android orders support only WeChat or Alipay',
      );
    }
    return _api.request<PaymentOrder>(
      ApiRequestOptions<PaymentOrder>(
        endpointId: 'createAndroidBillingOrder',
        body: <String, Object?>{
          'sku': sku,
          'provider': _providerWire(provider),
          'clientOrderKey': clientOrderKey,
          'agreementVersions': agreementVersions,
        },
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) => _parseOrderPayload(
          value,
          requireLaunchPayload: true,
          expectedSku: sku,
          expectedProvider: provider,
        ),
      ),
    );
  }

  Future<ApiResult<PaymentOrder>> order(String orderId) =>
      _api.request<PaymentOrder>(
        ApiRequestOptions<PaymentOrder>(
          endpointId: 'billingOrder',
          pathParams: <String, Object>{'orderId': orderId},
          parseData: (value) => _parseOrderPayload(
            value,
            requireLaunchPayload: false,
            expectedOrderId: orderId,
          ),
        ),
      );

  Future<ApiResult<MembershipEntitlement>> verifyIOSPurchase({
    required String productId,
    required String purchaseId,
    required String verificationData,
    required String clientTransactionKey,
    required String idempotencyKey,
  }) => _api.request<MembershipEntitlement>(
    ApiRequestOptions<MembershipEntitlement>(
      endpointId: 'verifyIOSBillingPurchase',
      body: <String, Object?>{
        'productId': productId,
        'purchaseId': purchaseId,
        'verificationData': verificationData,
        'clientTransactionKey': clientTransactionKey,
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parseMembershipPayload,
    ),
  );

  Future<ApiResult<BillingTransactionPage>> transactions({
    String? cursor,
    int limit = 20,
  }) {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Expected a value from 1 to 100',
      );
    }
    return _api.request<BillingTransactionPage>(
      ApiRequestOptions<BillingTransactionPage>(
        endpointId: 'billingTransactions',
        query: <String, Object?>{'cursor': cursor, 'limit': limit},
        parseData: BillingTransactionPage.fromValue,
      ),
    );
  }

  Future<ApiResult<MembershipEntitlement>> membership() =>
      _api.request<MembershipEntitlement>(
        ApiRequestOptions<MembershipEntitlement>(
          endpointId: 'membership',
          parseData: _parseMembershipPayload,
        ),
      );
}

PaymentOrder _parseOrderPayload(
  Object? value, {
  required bool requireLaunchPayload,
  String? expectedOrderId,
  String? expectedSku,
  BillingProvider? expectedProvider,
}) {
  final object = asObjectMap(value);
  if (object == null) {
    throw const FormatException('order data must be an object');
  }
  final order = asObjectMap(object['order']) ?? object;
  final wechat = asObjectMap(object['wechat']) ?? asObjectMap(order['wechat']);
  final alipay = asObjectMap(object['alipay']) ?? asObjectMap(order['alipay']);
  final launchCount = <Map<String, Object?>?>[
    wechat,
    alipay,
  ].whereType<Map<String, Object?>>().length;
  if (launchCount > 1 || (requireLaunchPayload && launchCount != 1)) {
    throw const FormatException(
      'Android order must contain exactly one Provider launch payload',
    );
  }
  final merged = <String, Object?>{
    ...order,
    if (wechat != null) 'wechat': _safeLaunchPayload(wechat),
    if (alipay != null) 'alipay': _safeLaunchPayload(alipay),
  };
  final parsed = PaymentOrder.fromValue(merged);
  if (expectedOrderId != null && parsed.orderId != expectedOrderId) {
    throw const FormatException(
      'Order response ID does not match request path',
    );
  }
  if (expectedSku != null && parsed.sku != expectedSku) {
    throw const FormatException('Created order SKU does not match request');
  }
  if (expectedProvider != null && parsed.provider != expectedProvider) {
    throw const FormatException(
      'Created order Provider does not match request',
    );
  }
  if ((parsed.provider == BillingProvider.wechat && wechat == null) ||
      (parsed.provider == BillingProvider.alipay && alipay == null)) {
    if (requireLaunchPayload || launchCount != 0) {
      throw const FormatException(
        'Provider launch payload does not match the order Provider',
      );
    }
  }
  return parsed;
}

Map<String, Object?> _safeLaunchPayload(Map<String, Object?> payload) {
  if (payload.isEmpty) {
    throw const FormatException('Provider launch payload must not be empty');
  }
  _rejectLaunchCredentials(payload);
  return Map<String, Object?>.unmodifiable(payload);
}

void _rejectLaunchCredentials(Object? value) {
  const forbidden = <String>{
    'privatekey',
    'merchantprivatekey',
    'apisecret',
    'providersecret',
    'credentials',
  };
  if (value is List) {
    for (final item in value) {
      _rejectLaunchCredentials(item);
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      final normalizedKey = entry.key.toString().toLowerCase().replaceAll(
        RegExp('[^a-z0-9]'),
        '',
      );
      if (forbidden.contains(normalizedKey)) {
        throw const FormatException(
          'Provider launch payload exposes credentials',
        );
      }
      _rejectLaunchCredentials(entry.value);
    }
  }
}

MembershipEntitlement _parseMembershipPayload(Object? value) {
  final object = asObjectMap(value);
  final membership = object?['membership'];
  return MembershipEntitlement.fromValue(membership ?? value);
}

String _providerWire(BillingProvider provider) => switch (provider) {
  BillingProvider.wechat => 'wechat',
  BillingProvider.alipay => 'alipay',
  BillingProvider.appStore => 'app_store',
};
