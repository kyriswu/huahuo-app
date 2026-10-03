import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/billing/application/billing_controller.dart';
import 'package:huahuoai_app/features/billing/data/android_payment_port.dart';
import 'package:huahuoai_app/features/billing/data/billing_api.dart';
import 'package:huahuoai_app/features/billing/data/billing_pending_order_store.dart';
import 'package:huahuoai_app/features/billing/data/ios_store_purchase_port.dart';

void main() {
  test('disabled Android channel never creates an order', () async {
    final api = _FakeBillingApi(
      _catalog(BillingPlatform.android, enabled: false),
    );
    final controller = _controller(api: api, platform: BillingPlatform.android);
    await controller.load();

    await controller.purchaseAndroid(
      product: controller.state.products.first,
      provider: BillingProvider.wechat,
    );

    expect(api.androidOrderCalls, 0);
    expect(controller.state.errorCode, 'BILLING_PROVIDER_UNAVAILABLE');
  });

  test(
    'StoreKit transaction completes only after server verification',
    () async {
      final api = _FakeBillingApi(_catalog(BillingPlatform.ios, enabled: true));
      final ios = _FakeIOSStore();
      final controller = _controller(
        api: api,
        ios: ios,
        platform: BillingPlatform.ios,
      );
      controller.startPurchaseStreams();
      await controller.load();

      ios.emit(
        const IOSPurchaseUpdate(
          key: 'transaction-1',
          productId: 'com.hangzhouchuda.huahuoai.pro.monthly',
          purchaseId: 'transaction-1',
          state: IOSPurchaseState.purchased,
          verificationData: 'signed-transaction',
        ),
      );
      await _flushEvents();

      expect(api.verifyCalls, 1);
      expect(ios.completed, <String>['transaction-1']);
      expect(controller.state.status, BillingStatus.active);
    },
  );

  test('failed Apple verification keeps transaction incomplete', () async {
    final api = _FakeBillingApi(
      _catalog(BillingPlatform.ios, enabled: true),
      verificationFailure: true,
    );
    final ios = _FakeIOSStore();
    final controller = _controller(
      api: api,
      ios: ios,
      platform: BillingPlatform.ios,
    );
    controller.startPurchaseStreams();
    await controller.load();

    ios.emit(
      const IOSPurchaseUpdate(
        key: 'transaction-2',
        productId: 'com.hangzhouchuda.huahuoai.pro.monthly',
        purchaseId: 'transaction-2',
        state: IOSPurchaseState.restored,
        verificationData: 'signed-transaction',
      ),
    );
    await _flushEvents();

    expect(ios.completed, isEmpty);
    expect(controller.state.errorCode, 'BILLING_PURCHASE_INVALID');
  });

  test('starting purchase stream does not automatically restore', () async {
    final ios = _FakeIOSStore();
    final controller = _controller(
      api: _FakeBillingApi(_catalog(BillingPlatform.ios, enabled: true)),
      ios: ios,
      platform: BillingPlatform.ios,
    );

    controller.startPurchaseStreams();
    expect(ios.restoreCalls, 0);

    await controller.restoreIOSPurchases();
    expect(ios.restoreCalls, 1);
    expect(controller.state.status, BillingStatus.idle);
  });

  test('StoreKit startup update loads catalog before verification', () async {
    final api = _FakeBillingApi(_catalog(BillingPlatform.ios, enabled: true));
    final ios = _FakeIOSStore();
    final controller = _controller(
      api: api,
      ios: ios,
      platform: BillingPlatform.ios,
    );
    controller.startPurchaseStreams();

    ios.emit(
      const IOSPurchaseUpdate(
        key: 'startup-transaction',
        productId: 'com.hangzhouchuda.huahuoai.pro.monthly',
        purchaseId: 'startup-transaction',
        state: IOSPurchaseState.purchased,
        verificationData: 'signed-startup-transaction',
      ),
    );
    await _flushEvents();

    expect(api.verifyCalls, 1);
    expect(ios.completed, <String>['startup-transaction']);
    expect(controller.state.status, BillingStatus.active);
  });

  test('pending or mismatched Apple entitlement is never completed', () async {
    for (final membership in <MembershipEntitlement>[
      const MembershipEntitlement(
        tier: MembershipTier.pro,
        status: MembershipEntitlementStatus.pending,
        autoRenewEnabled: true,
        cancelAtPeriodEnd: false,
        productSku: 'pro_30d',
      ),
      const MembershipEntitlement(
        tier: MembershipTier.max,
        status: MembershipEntitlementStatus.active,
        autoRenewEnabled: true,
        cancelAtPeriodEnd: false,
        productSku: 'max_365d',
      ),
    ]) {
      final api = _FakeBillingApi(
        _catalog(BillingPlatform.ios, enabled: true),
        verificationMembership: membership,
      );
      final ios = _FakeIOSStore();
      final controller = _controller(
        api: api,
        ios: ios,
        platform: BillingPlatform.ios,
      );
      controller.startPurchaseStreams();
      await controller.load();

      ios.emit(
        const IOSPurchaseUpdate(
          key: 'unconfirmed-transaction',
          productId: 'com.hangzhouchuda.huahuoai.pro.monthly',
          purchaseId: 'unconfirmed-transaction',
          state: IOSPurchaseState.purchased,
          verificationData: 'signed-transaction',
        ),
      );
      await _flushEvents();

      expect(ios.completed, isEmpty);
      expect(controller.state.status, isNot(BillingStatus.active));
      controller.dispose();
    }
  });

  test('iOS subscribes only to StoreKit and starts once', () {
    final android = _FakeAndroidPayment();
    final ios = _FakeIOSStore();
    final controller = _controller(
      api: _FakeBillingApi(_catalog(BillingPlatform.ios, enabled: true)),
      android: android,
      ios: ios,
      platform: BillingPlatform.ios,
    );

    controller.startPurchaseStreams();
    controller.startPurchaseStreams();

    expect(ios.listenCount, 1);
    expect(android.listenCount, 0);
  });

  test('Android subscribes only to its payment bridge and starts once', () {
    final android = _FakeAndroidPayment();
    final ios = _FakeIOSStore();
    final controller = _controller(
      api: _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true)),
      android: android,
      ios: ios,
      platform: BillingPlatform.android,
    );

    controller.startPurchaseStreams();
    controller.startPurchaseStreams();

    expect(android.listenCount, 1);
    expect(ios.listenCount, 0);
  });

  test('active purchase stream errors fail closed without escaping', () async {
    final ios = _FakeIOSStore();
    final controller = _controller(
      api: _FakeBillingApi(_catalog(BillingPlatform.ios, enabled: true)),
      ios: ios,
      platform: BillingPlatform.ios,
    );
    controller.startPurchaseStreams();

    ios.emitError(StateError('StoreKit stream unavailable'));
    await _flushEvents();

    expect(controller.state.status, BillingStatus.failed);
    expect(controller.state.errorCode, 'BILLING_PROVIDER_UNAVAILABLE');
  });

  test(
    'pending Android order is isolated by user scope and recovered',
    () async {
      final store = _FakePendingOrders()..values['user:a'] = 'order_pending_a';
      final api =
          _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
            ..orderResult = const PaymentOrder(
              orderId: 'order_pending_a',
              orderNo: 'HH1',
              sku: 'pro_30d',
              provider: BillingProvider.wechat,
              status: PaymentOrderStatus.providerPending,
            );
      final controller = BillingController(
        api: api,
        androidPayment: _FakeAndroidPayment(),
        iosStore: _FakeIOSStore(),
        pendingOrders: store,
        platform: BillingPlatform.android,
        userScope: 'user:a',
        orderPollAttempts: 1,
        orderPollInterval: Duration.zero,
        delay: (_) async {},
      );

      await controller.recoverPendingOrder();

      expect(api.requestedOrders, <String>['order_pending_a']);
      expect(controller.state.pendingOrderId, 'order_pending_a');
      expect(store.values['user:b'], isNull);
    },
  );

  test('missing agreements and StoreKit prices fail closed', () async {
    final androidApi = _FakeBillingApi(
      _catalog(
        BillingPlatform.android,
        enabled: true,
        agreements: const <BillingAgreement>[],
      ),
    );
    final android = _controller(
      api: androidApi,
      platform: BillingPlatform.android,
    );
    await android.load();
    await android.purchaseAndroid(
      product: android.state.products.single,
      provider: BillingProvider.wechat,
    );
    expect(androidApi.androidOrderCalls, 0);
    expect(android.state.errorCode, 'BILLING_AGREEMENTS_UNAVAILABLE');

    final iosStore = _FakeIOSStore()..storeProducts = <IOSStoreProduct>[];
    final ios = _controller(
      api: _FakeBillingApi(_catalog(BillingPlatform.ios, enabled: true)),
      ios: iosStore,
      platform: BillingPlatform.ios,
    );
    await ios.load();
    expect(ios.canPurchase(ios.state.products.single), isFalse);
    expect(ios.state.errorCode, 'BILLING_STORE_PRODUCT_UNAVAILABLE');
  });

  test('catalog refresh failure clears stale purchase authority', () async {
    final api = _FakeBillingApi(
      _catalog(BillingPlatform.android, enabled: true),
    );
    final controller = _controller(api: api, platform: BillingPlatform.android);
    await controller.load();
    expect(controller.canPurchase(controller.state.products.single), isTrue);

    api.catalogFailure = true;
    await controller.load();

    expect(controller.state.products, isEmpty);
    expect(controller.state.agreements, isEmpty);
    expect(controller.agreementsReady, isFalse);
    expect(controller.state.errorCode, 'BILLING_CATALOG_UNAVAILABLE');
  });

  test('Android intent reuses keys until cancellation then rotates', () async {
    final api =
        _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
          ..createResults.addAll(<ApiResult<PaymentOrder>>[
            _failure<PaymentOrder>(
              'BILLING_PROVIDER_UNAVAILABLE',
              retryable: true,
            ),
            _failure<PaymentOrder>(
              'BILLING_PROVIDER_UNAVAILABLE',
              retryable: true,
            ),
          ]);
    final payment = _FakeAndroidPayment();
    final store = _FakePendingOrders();
    final controller = _controller(
      api: api,
      android: payment,
      pendingOrders: store,
      platform: BillingPlatform.android,
    );
    await controller.load();
    final product = controller.state.products.single;

    await controller.purchaseAndroid(
      product: product,
      provider: BillingProvider.wechat,
    );
    await controller.purchaseAndroid(
      product: product,
      provider: BillingProvider.wechat,
    );
    expect(api.clientOrderKeys[0], api.clientOrderKeys[1]);
    expect(api.orderIdempotencyKeys[0], api.orderIdempotencyKeys[1]);
    expect(
      api.agreementVersionRequests.first.keys,
      containsAll(<String>['membership_service', 'purchase_refund', 'privacy']),
    );

    payment.startResults.add(AndroidPaymentClientResult.cancelled);
    await controller.purchaseAndroid(
      product: product,
      provider: BillingProvider.wechat,
    );
    api.createResults.add(
      _failure<PaymentOrder>('BILLING_PROVIDER_UNAVAILABLE', retryable: true),
    );
    await controller.purchaseAndroid(
      product: product,
      provider: BillingProvider.wechat,
    );
    expect(api.clientOrderKeys[2], isNot(api.clientOrderKeys[3]));
  });

  test('pending-order preferences persist only scoped order ID', () {
    final preferences = AppPreferencesDao(AppDatabase());
    final store = AppPreferencesBillingPendingOrderStore(
      preferences: preferences,
      now: () => DateTime.utc(2026, 8, 7),
    );

    store.save('user:private-account', 'order_safe_1');

    final records = preferences.listPreferences();
    expect(records, hasLength(1));
    expect(records.single['value'], 'order_safe_1');
    expect(
      records.single['preference_key'],
      startsWith('billing-pending-order-'),
    );
    final snapshot = jsonEncode(records);
    expect(snapshot, isNot(contains('user:private-account')));
    expect(snapshot, isNot(contains('pro_30d')));
    expect(snapshot, isNot(contains('wechat')));
    expect(snapshot, isNot(contains('android-order-')));
    expect(snapshot, isNot(contains('requestKey')));
  });

  test('changing Android Provider rotates the purchase intent', () async {
    final api =
        _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
          ..createResults.addAll(<ApiResult<PaymentOrder>>[
            _failure<PaymentOrder>(
              'BILLING_PROVIDER_UNAVAILABLE',
              retryable: true,
            ),
            _failure<PaymentOrder>(
              'BILLING_PROVIDER_UNAVAILABLE',
              retryable: true,
            ),
          ]);
    final controller = _controller(api: api, platform: BillingPlatform.android);
    await controller.load();

    await controller.purchaseAndroid(
      product: controller.state.products.single,
      provider: BillingProvider.wechat,
    );
    await controller.purchaseAndroid(
      product: controller.state.products.single,
      provider: BillingProvider.alipay,
    );

    expect(api.clientOrderKeys[0], isNot(api.clientOrderKeys[1]));
  });

  test(
    'bounded polling recovers transient errors and grants only server membership',
    () async {
      final store = _FakePendingOrders()..values['user:test'] = 'order_poll_1';
      final api =
          _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
            ..orderResults.addAll(<ApiResult<PaymentOrder>>[
              _success(
                _paymentOrder(status: PaymentOrderStatus.providerPending),
              ),
              _failure<PaymentOrder>(
                'BILLING_PROVIDER_RESPONSE_INVALID',
                retryable: true,
              ),
              _success(
                _paymentOrder(
                  status: PaymentOrderStatus.succeeded,
                  membership: _activeMembership(),
                ),
              ),
            ]);
      final delays = <Duration>[];
      final controller = _controller(
        api: api,
        pendingOrders: store,
        platform: BillingPlatform.android,
        orderPollAttempts: 3,
        delay: (duration) async => delays.add(duration),
      );

      await controller.recoverPendingOrder();

      expect(api.requestedOrders, hasLength(3));
      expect(delays, hasLength(2));
      expect(controller.state.status, BillingStatus.active);
      expect(controller.state.membership?.tier, MembershipTier.pro);
      expect(store.values['user:test'], isNull);
    },
  );

  test('exhausted pending polling stays recoverable', () async {
    final store = _FakePendingOrders()..values['user:test'] = 'order_pending_1';
    final api = _FakeBillingApi(
      _catalog(BillingPlatform.android, enabled: true),
    );
    final controller = _controller(
      api: api,
      pendingOrders: store,
      platform: BillingPlatform.android,
      orderPollAttempts: 2,
    );

    await controller.recoverPendingOrder();
    expect(controller.state.status, BillingStatus.pending);
    expect(controller.state.errorCode, isNull);
    expect(store.values['user:test'], 'order_pending_1');

    api.orderResult = _paymentOrder(
      status: PaymentOrderStatus.succeeded,
      membership: _activeMembership(),
    );
    await controller.retryPendingOrder();
    expect(controller.state.status, BillingStatus.active);
  });

  test('succeeded order with mismatched entitlement fails closed', () async {
    final store = _FakePendingOrders()..values['user:test'] = 'order_bad_1';
    final api =
        _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
          ..orderResult = _paymentOrder(
            status: PaymentOrderStatus.succeeded,
            membership: const MembershipEntitlement(
              tier: MembershipTier.max,
              status: MembershipEntitlementStatus.active,
              autoRenewEnabled: false,
              cancelAtPeriodEnd: false,
              productSku: 'max_365d',
            ),
          );
    final controller = _controller(
      api: api,
      pendingOrders: store,
      platform: BillingPlatform.android,
    );

    await controller.recoverPendingOrder();

    expect(controller.state.status, BillingStatus.failed);
    expect(controller.state.errorCode, 'BILLING_ORDER_MEMBERSHIP_INVALID');
    expect(store.values['user:test'], 'order_bad_1');
  });

  test(
    'older order completion cannot overwrite a newer confirmation',
    () async {
      final first = Completer<ApiResult<PaymentOrder>>();
      final second = Completer<ApiResult<PaymentOrder>>();
      final store = _FakePendingOrders()..values['user:test'] = 'order_old';
      final api =
          _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
            ..orderFutures.addAll(<Future<ApiResult<PaymentOrder>>>[
              first.future,
              second.future,
            ]);
      final controller = _controller(
        api: api,
        pendingOrders: store,
        platform: BillingPlatform.android,
      );

      final oldConfirmation = controller.recoverPendingOrder();
      await Future<void>.delayed(Duration.zero);
      store.values['user:test'] = 'order_new';
      final newConfirmation = controller.recoverPendingOrder();
      second.complete(
        _success(
          _paymentOrder(
            orderId: 'order_new',
            status: PaymentOrderStatus.succeeded,
            membership: _activeMembership(),
          ),
        ),
      );
      await newConfirmation;
      first.complete(
        _success(
          _paymentOrder(
            orderId: 'order_old',
            status: PaymentOrderStatus.providerPending,
          ),
        ),
      );
      await oldConfirmation;

      expect(controller.state.status, BillingStatus.active);
      expect(controller.state.pendingOrderId, isNull);
    },
  );

  test('late order completion after disposal is ignored', () async {
    final gate = Completer<ApiResult<PaymentOrder>>();
    final store = _FakePendingOrders()..values['user:test'] = 'order_disposed';
    final api = _FakeBillingApi(
      _catalog(BillingPlatform.android, enabled: true),
    )..orderFutures.add(gate.future);
    final controller = _controller(
      api: api,
      pendingOrders: store,
      platform: BillingPlatform.android,
    );
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    final pending = controller.recoverPendingOrder();
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    controller.dispose();
    gate.complete(
      _success(
        _paymentOrder(
          orderId: 'order_disposed',
          status: PaymentOrderStatus.succeeded,
          membership: _activeMembership(),
        ),
      ),
    );
    await pending;

    expect(notifications, 1);
  });

  test(
    'transaction pages deduplicate and keep controller accounts isolated',
    () async {
      final apiA =
          _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
            ..transactionResults.addAll(
              <ApiResult<MobileBillingTransactionPage>>[
                _success(
                  MobileBillingTransactionPage(
                    items: <MobileBillingTransaction>[
                      _transaction('transaction_a'),
                    ],
                    nextCursor: 'cursor-2',
                  ),
                ),
                _success(
                  MobileBillingTransactionPage(
                    items: <MobileBillingTransaction>[
                      _transaction('transaction_a'),
                      _transaction('transaction_b'),
                    ],
                  ),
                ),
              ],
            );
      final apiB =
          _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
            ..transactionResults.add(
              _success(
                MobileBillingTransactionPage(
                  items: <MobileBillingTransaction>[
                    _transaction('transaction_c'),
                  ],
                ),
              ),
            );
      final controllerA = _controller(
        api: apiA,
        platform: BillingPlatform.android,
      );
      final controllerB = _controller(
        api: apiB,
        platform: BillingPlatform.android,
      );

      await controllerA.loadTransactions();
      await controllerA.loadMoreTransactions();
      await controllerB.loadTransactions();

      expect(
        controllerA.transactions.map((item) => item.transactionId),
        <String>['transaction_a', 'transaction_b'],
      );
      expect(controllerB.transactions.single.transactionId, 'transaction_c');
      expect(apiA.transactionCursors, <String?>[null, 'cursor-2']);
    },
  );

  test('transaction pagination rejects a repeated cursor', () async {
    final api =
        _FakeBillingApi(_catalog(BillingPlatform.android, enabled: true))
          ..transactionResults.addAll(<ApiResult<MobileBillingTransactionPage>>[
            _success(
              MobileBillingTransactionPage(
                items: <MobileBillingTransaction>[
                  _transaction('transaction_1'),
                ],
                nextCursor: 'cursor-repeat',
              ),
            ),
            _success(
              MobileBillingTransactionPage(
                items: <MobileBillingTransaction>[
                  _transaction('transaction_2'),
                ],
                nextCursor: 'cursor-repeat',
              ),
            ),
          ]);
    final controller = _controller(api: api, platform: BillingPlatform.android);

    await controller.loadTransactions();
    await controller.loadMoreTransactions();

    expect(controller.transactionStatus, BillingTransactionStatus.failed);
    expect(
      controller.transactionErrorCode,
      'BILLING_TRANSACTION_CURSOR_INVALID',
    );
    expect(controller.transactions.single.transactionId, 'transaction_1');
  });

  test(
    'Mobile Billing API maps safe transactions and rejects receipt leakage',
    () async {
      final transport = _BillingTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'transactionId': 'transaction_safe',
                  'sku': 'pro_30d',
                  'status': 'succeeded',
                },
              ],
              'nextCursor': 'cursor-safe',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'transactionId': 'transaction_private',
                  'sku': 'pro_30d',
                  'status': 'succeeded',
                  'receipt': 'must-not-leak',
                },
              ],
            },
          },
        ),
      ]);
      final api = MobileBillingApi(BillingClient(_billingClient(transport)));

      final safe = await api.transactions(cursor: 'opaque cursor', limit: 20);
      final private = await api.transactions();

      expect(safe.data?.items.single.transactionId, 'transaction_safe');
      expect(safe.data?.nextCursor, 'cursor-safe');
      expect(private.error?.code, 'API_RESPONSE_INVALID');
      expect(transport.requests.first.url.queryParameters, <String, String>{
        'cursor': 'opaque cursor',
        'limit': '20',
      });
    },
  );
}

BillingController _controller({
  required BillingApiPort api,
  required BillingPlatform platform,
  _FakeAndroidPayment? android,
  _FakeIOSStore? ios,
  _FakePendingOrders? pendingOrders,
  int orderPollAttempts = 1,
  Future<void> Function(Duration)? delay,
}) => BillingController(
  api: api,
  androidPayment: android ?? _FakeAndroidPayment(),
  iosStore: ios ?? _FakeIOSStore(),
  pendingOrders: pendingOrders ?? _FakePendingOrders(),
  platform: platform,
  userScope: 'user:test',
  orderPollAttempts: orderPollAttempts,
  orderPollInterval: Duration.zero,
  delay: delay ?? (_) async {},
);

BillingCatalog _catalog(
  BillingPlatform platform, {
  required bool enabled,
  List<BillingAgreement>? agreements,
}) {
  final ios = platform == BillingPlatform.ios;
  return BillingCatalog(
    catalogRevision: 'billing-catalog-v1',
    appAccountToken: ios ? '123e4567-e89b-42d3-a456-426614174000' : null,
    agreements:
        agreements ??
        <BillingAgreement>[
          for (final type in <String>{
            'membership_service',
            'purchase_refund',
            'privacy',
            if (ios) 'auto_renew',
          })
            BillingAgreement(
              type: type,
              version: '2026-08-02',
              url: Uri.parse('https://huahuo.ai/legal/$type'),
            ),
        ],
    items: <BillingProduct>[
      BillingProduct(
        sku: 'pro_30d',
        tier: MembershipTier.pro,
        period: ios ? 'monthly' : 'days_30',
        title: ios ? 'PRO 连续包月' : 'PRO 30天',
        enabled: enabled,
        benefits: const <String>['chat_2_daily'],
        availableProviders: ios
            ? const <BillingProvider>[BillingProvider.appStore]
            : const <BillingProvider>[
                BillingProvider.wechat,
                BillingProvider.alipay,
              ],
        providerProductId: ios
            ? 'com.hangzhouchuda.huahuoai.pro.monthly'
            : null,
        displayPrice: ios ? null : '¥15',
      ),
    ],
  );
}

MembershipEntitlement _activeMembership() => const MembershipEntitlement(
  tier: MembershipTier.pro,
  status: MembershipEntitlementStatus.active,
  autoRenewEnabled: false,
  cancelAtPeriodEnd: false,
  productSku: 'pro_30d',
);

PaymentOrder _paymentOrder({
  String orderId = 'order_poll_1',
  PaymentOrderStatus status = PaymentOrderStatus.providerPending,
  MembershipEntitlement? membership,
}) => PaymentOrder(
  orderId: orderId,
  orderNo: 'HH-$orderId',
  sku: 'pro_30d',
  provider: BillingProvider.wechat,
  status: status,
  membership: membership,
);

MobileBillingTransaction _transaction(String id) => MobileBillingTransaction(
  transactionId: id,
  sku: 'pro_30d',
  status: 'succeeded',
);

final class _FakeBillingApi implements BillingApiPort {
  _FakeBillingApi(
    this.catalogValue, {
    this.verificationFailure = false,
    this.verificationMembership,
  });

  final BillingCatalog catalogValue;
  final bool verificationFailure;
  final MembershipEntitlement? verificationMembership;
  bool catalogFailure = false;
  int androidOrderCalls = 0;
  int verifyCalls = 0;
  final List<String> clientOrderKeys = <String>[];
  final List<String> orderIdempotencyKeys = <String>[];
  final List<Map<String, String>> agreementVersionRequests =
      <Map<String, String>>[];
  final List<String?> transactionCursors = <String?>[];
  final List<String> requestedOrders = <String>[];
  PaymentOrder? orderResult;
  final List<ApiResult<PaymentOrder>> createResults =
      <ApiResult<PaymentOrder>>[];
  final List<ApiResult<PaymentOrder>> orderResults =
      <ApiResult<PaymentOrder>>[];
  final List<Future<ApiResult<PaymentOrder>>> orderFutures =
      <Future<ApiResult<PaymentOrder>>>[];
  final List<ApiResult<MobileBillingTransactionPage>> transactionResults =
      <ApiResult<MobileBillingTransactionPage>>[];

  @override
  Future<ApiResult<BillingCatalog>> catalog(BillingPlatform platform) async =>
      catalogFailure
      ? _failure<BillingCatalog>('BILLING_CATALOG_UNAVAILABLE')
      : _success(catalogValue);

  @override
  Future<ApiResult<PaymentOrder>> createAndroidOrder({
    required String sku,
    required BillingProvider provider,
    required String clientOrderKey,
    required Map<String, String> agreementVersions,
    required String idempotencyKey,
  }) async {
    androidOrderCalls += 1;
    clientOrderKeys.add(clientOrderKey);
    orderIdempotencyKeys.add(idempotencyKey);
    agreementVersionRequests.add(Map<String, String>.of(agreementVersions));
    if (createResults.isNotEmpty) return createResults.removeAt(0);
    return _success(
      PaymentOrder(
        orderId: 'order_1',
        orderNo: 'HH1',
        sku: sku,
        provider: provider,
        status: PaymentOrderStatus.providerPending,
        launchPayload: const <String, Object?>{'prepayId': 'opaque'},
      ),
    );
  }

  @override
  Future<ApiResult<MembershipEntitlement>> membership() async => _success(
    const MembershipEntitlement(
      tier: MembershipTier.free,
      status: MembershipEntitlementStatus.expired,
      autoRenewEnabled: false,
      cancelAtPeriodEnd: false,
    ),
  );

  @override
  Future<ApiResult<PaymentOrder>> order(String orderId) async {
    requestedOrders.add(orderId);
    if (orderFutures.isNotEmpty) return orderFutures.removeAt(0);
    if (orderResults.isNotEmpty) return orderResults.removeAt(0);
    return _success(
      orderResult ??
          PaymentOrder(
            orderId: orderId,
            orderNo: 'HH1',
            sku: 'pro_30d',
            provider: BillingProvider.wechat,
            status: PaymentOrderStatus.providerPending,
          ),
    );
  }

  @override
  Future<ApiResult<MembershipEntitlement>> verifyIOSPurchase({
    required String productId,
    required String purchaseId,
    required String verificationData,
    required String clientTransactionKey,
    required String idempotencyKey,
  }) async {
    verifyCalls += 1;
    if (verificationFailure) {
      return ApiResult<MembershipEntitlement>.failure(
        error: const AppFailure(
          code: 'BILLING_PURCHASE_INVALID',
          category: AppFailureCategory.api,
          message: 'invalid',
          userMessageKey: 'billing.invalid',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return _success(
      verificationMembership ??
          const MembershipEntitlement(
            tier: MembershipTier.pro,
            status: MembershipEntitlementStatus.active,
            autoRenewEnabled: true,
            cancelAtPeriodEnd: false,
          ),
    );
  }

  @override
  Future<ApiResult<MobileBillingTransactionPage>> transactions({
    String? cursor,
    int limit = 20,
  }) async {
    transactionCursors.add(cursor);
    if (transactionResults.isNotEmpty) {
      return transactionResults.removeAt(0);
    }
    return _success(
      const MobileBillingTransactionPage(items: <MobileBillingTransaction>[]),
    );
  }
}

ApiResult<T> _success<T>(T value) => ApiResult<T>.success(
  data: value,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

ApiResult<T> _failure<T>(String code, {bool retryable = false}) =>
    ApiResult<T>.failure(
      error: AppFailure(
        code: code,
        category: retryable
            ? AppFailureCategory.network
            : AppFailureCategory.api,
        message: code,
        userMessageKey: 'billing.test.$code',
        isRetryable: retryable,
      ),
      idempotencyStore: SubmissionKeyStore.empty,
    );

ApiClient _billingClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-test',
    platform: 'android',
    locale: 'zh-CN',
    getAccessToken: () => 'token',
  ),
  transport: transport,
);

final class _BillingTransport implements ApiTransport {
  _BillingTransport(this.responses);

  final List<ApiTransportResponse> responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}

final class _FakeAndroidPayment implements AndroidPaymentPort {
  _FakeAndroidPayment() {
    _events = StreamController<AndroidPaymentEvent>.broadcast(
      onListen: () => listenCount += 1,
    );
  }

  late final StreamController<AndroidPaymentEvent> _events;
  int listenCount = 0;
  bool available = true;
  final List<AndroidPaymentClientResult> startResults =
      <AndroidPaymentClientResult>[];

  @override
  Stream<AndroidPaymentEvent> get events => _events.stream;

  @override
  Future<bool> isAvailable(BillingProvider provider) async => available;

  @override
  Future<AndroidPaymentClientResult> start({
    required BillingProvider provider,
    required String orderId,
    required Map<String, Object?> launchPayload,
  }) async => startResults.isEmpty
      ? AndroidPaymentClientResult.returned
      : startResults.removeAt(0);
}

final class _FakeIOSStore implements IOSStorePurchasePort {
  _FakeIOSStore() {
    _updates = StreamController<IOSPurchaseUpdate>.broadcast(
      onListen: () => listenCount += 1,
    );
  }

  late final StreamController<IOSPurchaseUpdate> _updates;
  final List<String> completed = <String>[];
  int listenCount = 0;
  int restoreCalls = 0;
  List<IOSStoreProduct>? storeProducts;

  void emit(IOSPurchaseUpdate update) => _updates.add(update);

  void emitError(Object error) => _updates.addError(error);

  @override
  Stream<IOSPurchaseUpdate> get purchaseUpdates => _updates.stream;

  @override
  Future<void> completePurchase(String purchaseKey) async {
    completed.add(purchaseKey);
  }

  @override
  Future<List<IOSStoreProduct>> loadProducts(Set<String> productIds) async =>
      storeProducts ??
      productIds
          .map(
            (id) => IOSStoreProduct(
              productId: id,
              title: 'PRO',
              localizedPrice: '¥15.00',
            ),
          )
          .toList();

  @override
  Future<bool> purchase({
    required String productId,
    required String appAccountToken,
  }) async => true;

  @override
  Future<void> restorePurchases() async {
    restoreCalls += 1;
  }
}

final class _FakePendingOrders implements BillingPendingOrderStore {
  final Map<String, String> values = <String, String>{};

  @override
  void clear(String userScope) => values.remove(userScope);

  @override
  String? read(String userScope) => values[userScope];

  @override
  void save(String userScope, String orderId) => values[userScope] = orderId;
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
