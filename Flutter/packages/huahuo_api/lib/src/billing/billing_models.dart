import '../api/domain_clients.dart';
import '../api/api_envelope.dart';

enum BillingPlatform { android, ios }

enum BillingProvider { wechat, alipay, appStore }

enum MembershipTier { free, pilotPaid, pro, max }

enum PaymentOrderStatus {
  created,
  providerPending,
  cancelled,
  closed,
  failed,
  paid,
  granting,
  succeeded,
  refunded,
}

enum MembershipEntitlementStatus {
  pending,
  active,
  gracePeriod,
  cancelled,
  expired,
  refunded,
  revoked,
}

final class BillingAgreement {
  const BillingAgreement({
    required this.type,
    required this.version,
    required this.url,
  });

  factory BillingAgreement.fromValue(Object? value) {
    final object = asObjectMap(value);
    if (object == null) {
      throw const FormatException('agreement must be an object');
    }
    _requireOnlyFields(object, const <String>{
      'type',
      'version',
      'url',
    }, 'agreement');
    return BillingAgreement(
      type: _requiredString(object, 'type'),
      version: _requiredString(object, 'version'),
      url: _requiredHttpsUrl(object, 'url'),
    );
  }

  final String type;
  final String version;
  final Uri url;
}

final class BillingProduct {
  const BillingProduct({
    required this.sku,
    required this.tier,
    required this.period,
    required this.title,
    required this.enabled,
    required this.benefits,
    required this.availableProviders,
    this.providerProductId,
    this.priceMinor,
    this.currency,
    this.displayPrice,
    this.disabledReason,
  });

  factory BillingProduct.fromValue(
    Object? value, {
    required BillingPlatform platform,
  }) {
    final object = asObjectMap(value);
    if (object == null) {
      throw const FormatException('billing product must be an object');
    }
    _requireOnlyFields(object, const <String>{
      'sku',
      'tier',
      'period',
      'title',
      'providerProductId',
      'priceMinor',
      'currency',
      'enabled',
      'disabledReason',
      'benefits',
    }, 'billing product');
    final rawBenefits = object['benefits'];
    if (rawBenefits is! List) {
      throw const FormatException('benefits must be a list');
    }
    final sku = _knownSKU(_requiredString(object, 'sku'));
    final tier = _membershipTier(_requiredString(object, 'tier'));
    if (_skuTiers[sku] != tier) {
      throw const FormatException('billing SKU tier does not match API 28');
    }
    if (!object.containsKey('disabledReason')) {
      throw const FormatException('disabledReason must be present');
    }
    final enabled = _requiredBool(object, 'enabled');
    final disabledReason = _optionalString(object, 'disabledReason');
    if (!enabled && disabledReason == null) {
      throw const FormatException('disabled product requires disabledReason');
    }
    final providerProductId = _optionalString(object, 'providerProductId');
    int? priceMinor;
    String? currency;
    if (platform == BillingPlatform.android) {
      final rawPriceMinor = object['priceMinor'];
      if (rawPriceMinor is! int || rawPriceMinor <= 0) {
        throw const FormatException(
          'Android priceMinor must be a positive integer',
        );
      }
      priceMinor = rawPriceMinor;
      currency = _requiredString(object, 'currency');
      if (currency != 'CNY') {
        throw const FormatException('Android currency must be CNY');
      }
    } else {
      if (object.containsKey('priceMinor') || object.containsKey('currency')) {
        throw const FormatException(
          'iOS catalog must not provide server-side price fields',
        );
      }
      if (providerProductId != _iosProductIds[sku]) {
        throw const FormatException(
          'iOS providerProductId does not match the fixed SKU',
        );
      }
    }
    return BillingProduct(
      sku: sku,
      tier: tier,
      period: _requiredString(object, 'period'),
      title: _requiredString(object, 'title'),
      enabled: enabled,
      benefits: List<String>.unmodifiable(rawBenefits.map(_nonEmptyListString)),
      availableProviders: platform == BillingPlatform.android
          ? const <BillingProvider>[
              BillingProvider.wechat,
              BillingProvider.alipay,
            ]
          : const <BillingProvider>[BillingProvider.appStore],
      providerProductId: providerProductId,
      priceMinor: priceMinor,
      currency: currency,
      displayPrice: priceMinor == null ? null : _formatCnyMinor(priceMinor),
      disabledReason: disabledReason,
    );
  }

  final String sku;
  final MembershipTier tier;
  final String period;
  final String title;
  final bool enabled;
  final List<String> benefits;
  final List<BillingProvider> availableProviders;
  final String? providerProductId;
  final int? priceMinor;
  final String? currency;
  final String? displayPrice;
  final String? disabledReason;

  BillingProduct withStorePrice(String localizedPrice) => BillingProduct(
    sku: sku,
    tier: tier,
    period: period,
    title: title,
    enabled: enabled,
    benefits: benefits,
    availableProviders: availableProviders,
    providerProductId: providerProductId,
    priceMinor: priceMinor,
    currency: currency,
    displayPrice: localizedPrice.trim(),
    disabledReason: disabledReason,
  );
}

final class BillingCatalog {
  const BillingCatalog({
    required this.catalogRevision,
    required this.items,
    required this.agreements,
    this.appAccountToken,
  });

  factory BillingCatalog.fromValue(
    Object? value, {
    required BillingPlatform platform,
  }) {
    final object = asObjectMap(value);
    if (object == null) {
      throw const FormatException('billing catalog must be an object');
    }
    _requireOnlyFields(object, const <String>{
      'catalogRevision',
      'items',
      'agreements',
      'purchaseContext',
    }, 'billing catalog');
    final rawItems = object['items'];
    final rawAgreements = object['agreements'];
    if (rawItems is! List || rawAgreements is! List) {
      throw const FormatException('billing catalog lists are invalid');
    }
    final items = List<BillingProduct>.unmodifiable(
      rawItems.map(
        (item) => BillingProduct.fromValue(item, platform: platform),
      ),
    );
    final skus = items.map((item) => item.sku).toSet();
    if (items.length != 3 || !skus.containsAll(_knownSkus)) {
      throw const FormatException(
        'billing catalog must contain each fixed SKU exactly once',
      );
    }
    String? appAccountToken;
    if (platform == BillingPlatform.ios) {
      final purchaseContext = asObjectMap(object['purchaseContext']);
      if (purchaseContext == null) {
        throw const FormatException('iOS purchaseContext is required');
      }
      _requireOnlyFields(purchaseContext, const <String>{
        'appAccountToken',
      }, 'purchaseContext');
      appAccountToken = _requiredString(purchaseContext, 'appAccountToken');
      if (!_uuidPattern.hasMatch(appAccountToken)) {
        throw const FormatException('appAccountToken must be a UUID');
      }
    } else if (object.containsKey('purchaseContext')) {
      throw const FormatException(
        'Android catalog must not contain iOS purchaseContext',
      );
    }
    return BillingCatalog(
      catalogRevision: _requiredString(object, 'catalogRevision'),
      items: items,
      agreements: List<BillingAgreement>.unmodifiable(
        rawAgreements.map(BillingAgreement.fromValue),
      ),
      appAccountToken: appAccountToken,
    );
  }

  final String catalogRevision;
  final List<BillingProduct> items;
  final List<BillingAgreement> agreements;
  final String? appAccountToken;
}

final class MembershipEntitlement {
  const MembershipEntitlement({
    required this.tier,
    required this.status,
    required this.autoRenewEnabled,
    required this.cancelAtPeriodEnd,
    this.provider,
    this.productSku,
    this.startedAt,
    this.expiresAt,
  });

  factory MembershipEntitlement.fromValue(Object? value) {
    final object = asObjectMap(value);
    if (object == null) {
      throw const FormatException('membership must be an object');
    }
    return MembershipEntitlement(
      tier: _membershipTier(
        _optionalString(object, 'tier') ?? _requiredString(object, 'levelCode'),
      ),
      status: _entitlementStatus(_requiredString(object, 'status')),
      autoRenewEnabled: _optionalBool(object, 'autoRenewEnabled') ?? false,
      cancelAtPeriodEnd: _optionalBool(object, 'cancelAtPeriodEnd') ?? false,
      provider: _optionalString(object, 'provider'),
      productSku: _optionalString(object, 'productSku'),
      startedAt: _optionalDate(object, 'startedAt'),
      expiresAt: _optionalDate(object, 'expiresAt'),
    );
  }

  final MembershipTier tier;
  final MembershipEntitlementStatus status;
  final String? provider;
  final String? productSku;
  final DateTime? startedAt;
  final DateTime? expiresAt;
  final bool autoRenewEnabled;
  final bool cancelAtPeriodEnd;

  bool get isActive =>
      status == MembershipEntitlementStatus.active ||
      status == MembershipEntitlementStatus.gracePeriod;
}

final class PaymentOrder {
  const PaymentOrder({
    required this.orderId,
    required this.orderNo,
    required this.sku,
    required this.provider,
    required this.status,
    this.amountMinor,
    this.currency,
    this.expiresAt,
    this.membership,
    this.launchPayload,
  });

  factory PaymentOrder.fromValue(Object? value) {
    final object = asObjectMap(value);
    if (object == null) {
      throw const FormatException('payment order must be an object');
    }
    final rawAmount = object['amountMinor'];
    if (rawAmount != null && (rawAmount is! int || rawAmount <= 0)) {
      throw const FormatException('amountMinor must be a positive integer');
    }
    final membership = object['membership'];
    final provider = _billingProvider(_requiredString(object, 'provider'));
    if (provider == BillingProvider.appStore) {
      throw const FormatException(
        'Android order provider must be wechat/alipay',
      );
    }
    final currency = _optionalString(object, 'currency');
    if (rawAmount != null && currency != 'CNY') {
      throw const FormatException('Android order currency must be CNY');
    }
    return PaymentOrder(
      orderId: _safeID(_requiredString(object, 'orderId'), 'orderId'),
      orderNo: _safeID(_requiredString(object, 'orderNo'), 'orderNo'),
      sku: _knownSKU(_requiredString(object, 'sku')),
      provider: provider,
      status: _orderStatus(_requiredString(object, 'status')),
      amountMinor: rawAmount as int?,
      currency: currency,
      expiresAt: _optionalDate(object, 'expiresAt'),
      membership: membership == null
          ? null
          : MembershipEntitlement.fromValue(membership),
      launchPayload:
          asObjectMap(object['wechat']) ?? asObjectMap(object['alipay']),
    );
  }

  final String orderId;
  final String orderNo;
  final String sku;
  final BillingProvider provider;
  final PaymentOrderStatus status;
  final int? amountMinor;
  final String? currency;
  final DateTime? expiresAt;
  final MembershipEntitlement? membership;
  final Map<String, Object?>? launchPayload;

  bool get isTerminal => const <PaymentOrderStatus>{
    PaymentOrderStatus.cancelled,
    PaymentOrderStatus.closed,
    PaymentOrderStatus.failed,
    PaymentOrderStatus.succeeded,
    PaymentOrderStatus.refunded,
  }.contains(status);
}

final class BillingTransactionPage {
  const BillingTransactionPage({required this.items, this.nextCursor});

  factory BillingTransactionPage.fromValue(Object? value) {
    final page = ApiContractPage.fromValue(value);
    for (final item in page.items) {
      _rejectPrivateTransactionFields(item.fields);
    }
    return BillingTransactionPage(
      items: page.items,
      nextCursor: page.nextCursor,
    );
  }

  final List<ApiContractObject> items;
  final String? nextCursor;
}

String _requiredString(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value.trim();
}

String? _optionalString(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string when present');
  }
  return value.trim();
}

bool _requiredBool(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

bool? _optionalBool(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

Uri _requiredHttpsUrl(Map<String, Object?> object, String key) {
  final uri = Uri.tryParse(_requiredString(object, key));
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw FormatException('$key must be an HTTPS URL');
  }
  return uri;
}

DateTime? _optionalDate(Map<String, Object?> object, String key) {
  final value = _optionalString(object, key);
  if (value == null) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$key must be an ISO timestamp');
  return parsed.toUtc();
}

String _nonEmptyListString(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('list value must be a non-empty string');
  }
  return value.trim();
}

String _knownSKU(String value) {
  if (!const <String>{'pro_30d', 'pro_365d', 'max_365d'}.contains(value)) {
    throw FormatException('Unsupported billing SKU: $value');
  }
  return value;
}

String _formatCnyMinor(int value) => '¥${(value / 100).toStringAsFixed(2)}';

MembershipTier _membershipTier(String value) => switch (value) {
  'free' => MembershipTier.free,
  'pilot_paid' => MembershipTier.pilotPaid,
  'pro' => MembershipTier.pro,
  'max' => MembershipTier.max,
  _ => throw FormatException('Unsupported membership tier: $value'),
};

BillingProvider _billingProvider(String value) => switch (value) {
  'wechat' => BillingProvider.wechat,
  'alipay' => BillingProvider.alipay,
  'app_store' => BillingProvider.appStore,
  _ => throw FormatException('Unsupported billing provider: $value'),
};

PaymentOrderStatus _orderStatus(String value) => switch (value) {
  'created' => PaymentOrderStatus.created,
  'provider_pending' => PaymentOrderStatus.providerPending,
  'cancelled' => PaymentOrderStatus.cancelled,
  'closed' => PaymentOrderStatus.closed,
  'failed' => PaymentOrderStatus.failed,
  'paid' => PaymentOrderStatus.paid,
  'granting' => PaymentOrderStatus.granting,
  'succeeded' => PaymentOrderStatus.succeeded,
  'refunded' => PaymentOrderStatus.refunded,
  _ => throw FormatException('Unsupported order status: $value'),
};

MembershipEntitlementStatus _entitlementStatus(String value) => switch (value) {
  'pending' => MembershipEntitlementStatus.pending,
  'active' => MembershipEntitlementStatus.active,
  'grace_period' => MembershipEntitlementStatus.gracePeriod,
  'cancelled' => MembershipEntitlementStatus.cancelled,
  'expired' => MembershipEntitlementStatus.expired,
  'refunded' => MembershipEntitlementStatus.refunded,
  'revoked' => MembershipEntitlementStatus.revoked,
  _ => throw FormatException('Unsupported entitlement status: $value'),
};

String _safeID(String value, String name) {
  if (!_safeIDPattern.hasMatch(value)) throw FormatException('$name is unsafe');
  return value;
}

final _safeIDPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$');
final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

const _knownSkus = <String>{'pro_30d', 'pro_365d', 'max_365d'};
const _skuTiers = <String, MembershipTier>{
  'pro_30d': MembershipTier.pro,
  'pro_365d': MembershipTier.pro,
  'max_365d': MembershipTier.max,
};
const _iosProductIds = <String, String>{
  'pro_30d': 'com.hangzhouchuda.huahuoai.pro.monthly',
  'pro_365d': 'com.hangzhouchuda.huahuoai.pro.annual',
  'max_365d': 'com.hangzhouchuda.huahuoai.max.annual',
};

void _requireOnlyFields(
  Map<String, Object?> object,
  Set<String> allowed,
  String name,
) {
  final unknown = object.keys
      .where((key) => !allowed.contains(key))
      .toList(growable: false);
  if (unknown.isNotEmpty) {
    throw FormatException('$name contains unsupported fields: $unknown');
  }
}

void _rejectPrivateTransactionFields(Object? value) {
  const forbidden = <String>{
    'verificationdata',
    'receipt',
    'rawreceipt',
    'signature',
    'providersignature',
    'providertransactionid',
    'fullprovidertransactionid',
    'originaltransactionid',
    'credentials',
    'providerpayload',
    'privatekey',
    'apisecret',
    'providersecret',
  };
  if (value is List) {
    for (final item in value) {
      _rejectPrivateTransactionFields(item);
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
        throw FormatException(
          'transaction exposes private field: ${entry.key}',
        );
      }
      _rejectPrivateTransactionFields(entry.value);
    }
  }
}
