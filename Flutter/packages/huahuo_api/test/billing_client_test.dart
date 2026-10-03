import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'billing catalog is strict and platform-derived for Android/iOS',
    () async {
      final transport = _BillingTransport(<ApiTransportResponse>[
        _billingResponse(_catalog(platform: BillingPlatform.android)),
        _billingResponse(_catalog(platform: BillingPlatform.ios)),
      ]);
      final client = BillingClient(_client(transport));

      final android = await client.catalog(BillingPlatform.android);
      final ios = await client.catalog(BillingPlatform.ios);

      expect(android.ok, isTrue);
      expect(android.data?.items.map((item) => item.sku), <String>[
        'pro_30d',
        'pro_365d',
        'max_365d',
      ]);
      expect(android.data?.items.first.priceMinor, 1500);
      expect(android.data?.items.first.currency, 'CNY');
      expect(android.data?.items.first.displayPrice, '¥15.00');
      expect(android.data?.items.first.availableProviders, <BillingProvider>[
        BillingProvider.wechat,
        BillingProvider.alipay,
      ]);
      expect(android.data?.appAccountToken, isNull);

      expect(ios.ok, isTrue);
      expect(
        ios.data?.items.first.providerProductId,
        'com.hangzhouchuda.huahuoai.pro.monthly',
      );
      expect(ios.data?.items.first.priceMinor, isNull);
      expect(ios.data?.items.first.currency, isNull);
      expect(ios.data?.items.first.displayPrice, isNull);
      expect(ios.data?.items.first.availableProviders, <BillingProvider>[
        BillingProvider.appStore,
      ]);
      expect(ios.data?.appAccountToken, '123e4567-e89b-42d3-a456-426614174000');
      expect(transport.requests[0].url.queryParameters['platform'], 'android');
      expect(transport.requests[1].url.queryParameters['platform'], 'ios');
    },
  );

  test(
    'Android order sends no client amount and requires standard key',
    () async {
      final transport = _BillingTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'order': <String, Object?>{
                'orderId': 'order_1',
                'orderNo': 'HH202608020001',
                'sku': 'pro_30d',
                'provider': 'wechat',
                'status': 'provider_pending',
              },
              'wechat': <String, Object?>{
                'appId': 'wx-app',
                'partnerId': 'merchant',
                'prepayId': 'prepay_1',
                'package': 'Sign=WXPay',
                'nonceStr': 'nonce',
                'timeStamp': '1786000000',
                'sign': 'safe-launch-signature',
              },
            },
          },
        ),
      ]);

      final result = await BillingClient(_client(transport)).createAndroidOrder(
        sku: 'pro_30d',
        provider: BillingProvider.wechat,
        clientOrderKey: 'client-order-1',
        agreementVersions: const <String, String>{
          'membership_service': '2026-08-02',
        },
        idempotencyKey: 'billing-order-1',
      );

      expect(result.ok, isTrue);
      final request = transport.requests.single;
      final body = jsonDecode(request.body!) as Map<String, dynamic>;
      expect(body['sku'], 'pro_30d');
      expect(body, isNot(contains('amountMinor')));
      expect(body, isNot(contains('durationDays')));
      expect(request.headers['Idempotency-Key'], 'billing-order-1');
      expect(result.data?.launchPayload?['prepayId'], 'prepay_1');
    },
  );

  test(
    'order recovery unwraps nested order without requiring launch payload',
    () async {
      final transport = _BillingTransport(<ApiTransportResponse>[
        _billingResponse(<String, Object?>{
          'order': <String, Object?>{
            ..._order(status: 'succeeded'),
            'membership': _entitlement(status: 'active'),
          },
        }),
      ]);

      final result = await BillingClient(_client(transport)).order('order_1');

      expect(result.ok, isTrue);
      expect(result.data?.status, PaymentOrderStatus.succeeded);
      expect(result.data?.membership?.tier, MembershipTier.pro);
      expect(result.data?.launchPayload, isNull);
    },
  );

  test(
    'order responses bind request identity and reject nested credentials',
    () async {
      final wrongSku = _order()..['sku'] = 'pro_365d';
      final transport = _BillingTransport(<ApiTransportResponse>[
        _billingResponse(<String, Object?>{
          'order': wrongSku,
          'wechat': <String, Object?>{'prepayId': 'prepay'},
        }),
        _billingResponse(<String, Object?>{
          'order': _order(provider: 'alipay'),
          'alipay': <String, Object?>{'orderString': 'signed-order'},
        }),
        _billingResponse(<String, Object?>{
          'order': <String, Object?>{..._order(), 'orderId': 'order_other'},
        }),
        _billingResponse(<String, Object?>{
          'order': _order(),
          'wechat': <String, Object?>{
            'prepayId': 'prepay',
            'metadata': <String, Object?>{'Private_Key': 'must-not-leak'},
          },
        }),
      ]);
      final client = BillingClient(_client(transport));

      Future<ApiResult<PaymentOrder>> create(String key) =>
          client.createAndroidOrder(
            sku: 'pro_30d',
            provider: BillingProvider.wechat,
            clientOrderKey: 'client-$key',
            agreementVersions: const <String, String>{},
            idempotencyKey: key,
          );

      expect((await create('wrong-sku')).error?.code, 'API_RESPONSE_INVALID');
      expect(
        (await create('wrong-provider')).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await client.order('order_1')).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await create('nested-secret')).error?.code,
        'API_RESPONSE_INVALID',
      );
    },
  );

  test(
    'created Android order rejects missing, duplicate or mismatched launch',
    () async {
      final transport = _BillingTransport(<ApiTransportResponse>[
        _billingResponse(<String, Object?>{'order': _order()}),
        _billingResponse(<String, Object?>{
          'order': _order(),
          'wechat': <String, Object?>{'prepayId': 'prepay'},
          'alipay': <String, Object?>{'orderString': 'signed-order'},
        }),
        _billingResponse(<String, Object?>{
          'order': _order(provider: 'wechat'),
          'alipay': <String, Object?>{'orderString': 'signed-order'},
        }),
      ]);
      final client = BillingClient(_client(transport));

      for (var index = 0; index < 3; index += 1) {
        final result = await client.createAndroidOrder(
          sku: 'pro_30d',
          provider: BillingProvider.wechat,
          clientOrderKey: 'client-$index',
          agreementVersions: const <String, String>{},
          idempotencyKey: 'key-$index',
        );
        expect(result.error?.code, 'API_RESPONSE_INVALID');
      }
      expect(
        () => client.createAndroidOrder(
          sku: 'pro_30d',
          provider: BillingProvider.appStore,
          clientOrderKey: 'client-ios',
          agreementVersions: const <String, String>{},
          idempotencyKey: 'key-ios',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'iOS entitlement states are closed and verification is idempotent',
    () async {
      for (final status in <String>[
        'pending',
        'active',
        'grace_period',
        'cancelled',
        'expired',
        'refunded',
        'revoked',
      ]) {
        expect(
          MembershipEntitlement.fromValue(_entitlement(status: status)).status,
          isA<MembershipEntitlementStatus>(),
        );
      }
      for (final invalid in <String>['trial', 'unavailable']) {
        expect(
          () => MembershipEntitlement.fromValue(_entitlement(status: invalid)),
          throwsFormatException,
        );
      }

      final transport = _BillingTransport(<ApiTransportResponse>[
        _billingResponse(<String, Object?>{
          'membership': _entitlement(status: 'grace_period'),
        }),
      ]);
      final result = await BillingClient(_client(transport)).verifyIOSPurchase(
        productId: 'com.hangzhouchuda.huahuoai.pro.monthly',
        purchaseId: 'transaction_1',
        verificationData: 'signed-transaction',
        clientTransactionKey: 'client-transaction-1',
        idempotencyKey: 'verify-key-1',
      );
      expect(result.data?.status, MembershipEntitlementStatus.gracePeriod);
      expect(
        transport.requests.single.headers['Idempotency-Key'],
        'verify-key-1',
      );
    },
  );

  test('Android order states are closed to API 28', () {
    for (final status in <String>[
      'created',
      'provider_pending',
      'cancelled',
      'closed',
      'failed',
      'paid',
      'granting',
      'succeeded',
      'refunded',
    ]) {
      expect(
        PaymentOrder.fromValue(_order(status: status)).status,
        isA<PaymentOrderStatus>(),
      );
    }
    expect(
      () => PaymentOrder.fromValue(_order(status: 'processing')),
      throwsFormatException,
    );
  });

  test(
    'transactions enforce pagination and reject private Provider fields',
    () async {
      final transport = _BillingTransport(<ApiTransportResponse>[
        _billingResponse(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'transactionId': 'transaction_redacted_1',
              'sku': 'pro_30d',
              'status': 'succeeded',
            },
          ],
          'nextCursor': 'transaction-cursor-2',
        }),
        _billingResponse(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'transactionId': 'transaction_2',
              'verificationData': 'raw-receipt',
            },
          ],
        }),
        _billingResponse(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'transactionId': 'transaction_3',
              'metadata': <String, Object?>{
                'Provider-Signature': 'must-not-be-returned',
              },
            },
          ],
        }),
      ]);
      final client = BillingClient(_client(transport));

      final page = await client.transactions(cursor: 'cursor-1', limit: 100);
      final leaked = await client.transactions(limit: 20);
      final caseVariedLeak = await client.transactions(limit: 20);

      expect(page.data?.nextCursor, 'transaction-cursor-2');
      expect(transport.requests.first.url.queryParameters, <String, String>{
        'cursor': 'cursor-1',
        'limit': '100',
      });
      expect(leaked.error?.code, 'API_RESPONSE_INVALID');
      expect(caseVariedLeak.error?.code, 'API_RESPONSE_INVALID');
      expect(() => client.transactions(limit: 0), throwsArgumentError);
      expect(() => client.transactions(limit: 101), throwsArgumentError);
    },
  );

  test(
    'catalog rejects legacy fields and platform contract violations',
    () async {
      final legacy = _catalog(platform: BillingPlatform.ios);
      (legacy['items'] as List).cast<Map<String, Object?>>().first
        ..['availableProviders'] = <Object?>['app_store']
        ..['appleProductId'] = 'legacy-product';
      final missingContext = _catalog(platform: BillingPlatform.ios)
        ..remove('purchaseContext');
      final badAndroidPrice = _catalog(platform: BillingPlatform.android);
      (badAndroidPrice['items'] as List)
              .cast<Map<String, Object?>>()
              .first['priceMinor'] =
          15.5;
      final serverIOSPrice = _catalog(platform: BillingPlatform.ios);
      (serverIOSPrice['items'] as List)
              .cast<Map<String, Object?>>()
              .first['displayPrice'] =
          '¥15';
      final transport = _BillingTransport(<ApiTransportResponse>[
        _billingResponse(legacy),
        _billingResponse(missingContext),
        _billingResponse(badAndroidPrice),
        _billingResponse(serverIOSPrice),
      ]);
      final client = BillingClient(_client(transport));

      expect(
        (await client.catalog(BillingPlatform.ios)).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await client.catalog(BillingPlatform.ios)).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await client.catalog(BillingPlatform.android)).error?.code,
        'API_RESPONSE_INVALID',
      );
      expect(
        (await client.catalog(BillingPlatform.ios)).error?.code,
        'API_RESPONSE_INVALID',
      );
    },
  );
}

ApiTransportResponse _billingResponse(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

Map<String, Object?> _catalog({required BillingPlatform platform}) =>
    <String, Object?>{
      'catalogRevision': 'billing-catalog-v1',
      'items': <Object?>[
        _product(
          platform: platform,
          sku: 'pro_30d',
          tier: 'pro',
          period: '30d',
          priceMinor: 1500,
          providerProductId: 'com.hangzhouchuda.huahuoai.pro.monthly',
        ),
        _product(
          platform: platform,
          sku: 'pro_365d',
          tier: 'pro',
          period: '365d',
          priceMinor: 9900,
          providerProductId: 'com.hangzhouchuda.huahuoai.pro.annual',
        ),
        _product(
          platform: platform,
          sku: 'max_365d',
          tier: 'max',
          period: '365d',
          priceMinor: 29900,
          providerProductId: 'com.hangzhouchuda.huahuoai.max.annual',
        ),
      ],
      'agreements': <Object?>[
        <String, Object?>{
          'type': 'membership_service',
          'version': '2026-08-07',
          'url': 'https://huahuo.ai/legal/membership',
        },
      ],
      if (platform == BillingPlatform.ios)
        'purchaseContext': <String, Object?>{
          'appAccountToken': '123e4567-e89b-42d3-a456-426614174000',
        },
    };

Map<String, Object?> _product({
  required BillingPlatform platform,
  required String sku,
  required String tier,
  required String period,
  required int priceMinor,
  required String providerProductId,
}) => <String, Object?>{
  'sku': sku,
  'tier': tier,
  'period': period,
  'title': sku,
  if (platform == BillingPlatform.ios) 'providerProductId': providerProductId,
  if (platform == BillingPlatform.android) 'priceMinor': priceMinor,
  if (platform == BillingPlatform.android) 'currency': 'CNY',
  'enabled': true,
  'disabledReason': null,
  'benefits': <Object?>['chat', 'asr', 'storage'],
};

Map<String, Object?> _order({
  String provider = 'wechat',
  String status = 'provider_pending',
}) => <String, Object?>{
  'orderId': 'order_1',
  'orderNo': 'HH202608020001',
  'sku': 'pro_30d',
  'provider': provider,
  'status': status,
};

Map<String, Object?> _entitlement({required String status}) =>
    <String, Object?>{
      'tier': 'pro',
      'status': status,
      'provider': 'app_store',
      'productSku': 'pro_30d',
      'startedAt': '2026-08-01T00:00:00Z',
      'expiresAt': '2026-09-01T00:00:00Z',
      'autoRenewEnabled': status != 'cancelled',
      'cancelAtPeriodEnd': status == 'cancelled',
    };

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-test',
    platform: 'ios',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
    getAccessToken: () async => 'access-token',
  ),
  transport: transport,
);

final class _BillingTransport implements ApiTransport {
  _BillingTransport(this._responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}
