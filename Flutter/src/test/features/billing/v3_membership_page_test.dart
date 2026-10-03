import 'package:huahuoai_app/app/di/account_usage_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/di/billing_providers.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/billing/application/account_usage_controller.dart';
import 'package:huahuoai_app/features/billing/application/billing_controller.dart';
import 'package:huahuoai_app/features/billing/domain/account_usage_repository.dart';
import 'package:huahuoai_app/features/billing/data/android_payment_port.dart';
import 'package:huahuoai_app/features/billing/data/billing_api.dart';
import 'package:huahuoai_app/features/billing/data/billing_pending_order_store.dart';
import 'package:huahuoai_app/features/billing/data/ios_store_purchase_port.dart';
import 'package:huahuoai_app/features/billing/widgets/v3_membership_page.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  testWidgets('membership fixed theme does not inherit the outer palette', (
    tester,
  ) async {
    for (final theme in [
      HuahuoV3Theme.light(),
      HuahuoV3Theme.dark(palette: HuahuoV3Palette.sakura),
    ]) {
      await _pumpPage(tester, BillingPlatform.android, theme: theme);
      final context = tester.element(find.byType(V3NavigationBackButton).first);
      final tokens = HuahuoV3Theme.tokensOf(context);
      final localTheme = Theme.of(context);
      expect(localTheme.brightness, Brightness.dark);
      expect(tokens.ink, const Color(0xFFF7F7FA));
      expect(tokens.primary, const Color(0xFFE3B763));
      expect(localTheme.colorScheme.primary, tokens.primary);
      expect(localTheme.colorScheme.surface, tokens.surface);
      expect(localTheme.textTheme.bodyMedium!.color, tokens.text);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('Android membership page has one-time purchase copy only', (
    tester,
  ) async {
    await _pumpPage(tester, BillingPlatform.android);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('PRO 30天'), findsOneWidget);
    expect(
      tester
          .widget<V3PrimaryButton>(
            find.byKey(const ValueKey('billing-purchase-button')),
          )
          .label,
      startsWith('立即购买'),
    );
    expect(find.textContaining('连续包月'), findsNothing);
    expect(find.textContaining('自动续费'), findsNothing);
    expect(find.text('恢复购买'), findsNothing);
  });

  testWidgets('iOS membership page exposes StoreKit actions only', (
    tester,
  ) async {
    await _pumpPage(tester, BillingPlatform.ios);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('PRO 连续包月'), findsOneWidget);
    expect(
      tester
          .widget<V3PrimaryButton>(
            find.byKey(const ValueKey('billing-purchase-button')),
          )
          .label,
      startsWith('立即订阅'),
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.text('恢复购买'), findsOneWidget);
    expect(find.text('管理订阅'), findsOneWidget);
    expect(find.text('微信支付'), findsNothing);
    expect(find.text('支付宝'), findsNothing);
  });

  testWidgets('API28 failure never hides successful API27 membership', (
    tester,
  ) async {
    await _pumpPage(tester, BillingPlatform.android, catalogFailure: true);

    expect(
      find.byKey(const ValueKey('account-membership-status')),
      findsOneWidget,
    );
    expect(find.text('试点会员 · 已生效'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('account-credit-summary')),
      findsOneWidget,
    );
    expect(find.textContaining('9,000,000 / 10,000,000'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workspace-storage-usage')),
      findsOneWidget,
    );
    expect(find.text('1 GB / 30 GB'), findsOneWidget);
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('billing-error')),
      300,
      scrollable: scrollable,
    );
    expect(find.byKey(const ValueKey('billing-error')), findsOneWidget);
    expect(find.text('会员商品暂不可用'), findsOneWidget);
  });

  testWidgets('transaction list paginates without exposing internal IDs', (
    tester,
  ) async {
    final api = _PageBillingApi(BillingPlatform.android)
      ..transactionResults.addAll(<ApiResult<MobileBillingTransactionPage>>[
        _pageSuccess(
          MobileBillingTransactionPage(
            items: <MobileBillingTransaction>[
              MobileBillingTransaction(
                transactionId: 'internal_transaction_1',
                sku: 'pro_30d',
                status: 'succeeded',
              ),
            ],
            nextCursor: 'cursor-2',
          ),
        ),
        _pageSuccess(
          MobileBillingTransactionPage(
            items: <MobileBillingTransaction>[
              MobileBillingTransaction(
                transactionId: 'internal_transaction_2',
                sku: 'max_365d',
                status: 'refunded',
              ),
            ],
          ),
        ),
      ]);
    await _pumpPage(tester, BillingPlatform.android, billingApi: api);
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('billing-transactions-load-more')),
      300,
      scrollable: scrollable,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('billing-transactions-load-more')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('billing-transaction-row-0')),
      findsOneWidget,
    );
    expect(find.text('internal_transaction_1'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('billing-transactions-load-more')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('billing-transaction-row-1')),
      findsOneWidget,
    );
    expect(find.text('internal_transaction_2'), findsNothing);
    expect(api.transactionCursors, <String?>[null, 'cursor-2']);
  });

  testWidgets('transaction error retries into an honest empty state', (
    tester,
  ) async {
    final api = _PageBillingApi(BillingPlatform.android)
      ..transactionResults.addAll(<ApiResult<MobileBillingTransactionPage>>[
        ApiResult<MobileBillingTransactionPage>.failure(
          error: const AppFailure(
            code: 'BILLING_TRANSACTIONS_LOAD_FAILED',
            category: AppFailureCategory.network,
            message: 'temporary',
            userMessageKey: 'billing.transactions.retry',
            isRetryable: true,
          ),
          idempotencyStore: SubmissionKeyStore.empty,
        ),
        _pageSuccess(
          const MobileBillingTransactionPage(
            items: <MobileBillingTransaction>[],
          ),
        ),
      ]);
    await _pumpPage(tester, BillingPlatform.android, billingApi: api);
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('billing-transactions-retry')),
      300,
      scrollable: scrollable,
    );
    await tester.tap(find.byKey(const ValueKey('billing-transactions-retry')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('billing-transactions-empty')),
      findsOneWidget,
    );
  });

  testWidgets('missing required agreements disables purchase', (tester) async {
    final api = _PageBillingApi(
      BillingPlatform.android,
      agreements: const <BillingAgreement>[],
    );
    await _pumpPage(tester, BillingPlatform.android, billingApi: api);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();

    final checkbox = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('billing-agreement-checkbox')),
    );
    final button = tester.widget<V3PrimaryButton>(
      find.byKey(const ValueKey('billing-purchase-button')),
    );
    expect(checkbox.onChanged, isNull);
    expect(button.enabled, isFalse);
    expect(find.textContaining('必需协议暂不完整'), findsOneWidget);
  });

  testWidgets('privacy agreement opens the bundled reviewed policy', (
    tester,
  ) async {
    await _pumpPage(tester, BillingPlatform.android);
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('《隐私政策》'),
      300,
      scrollable: scrollable,
    );
    await tester.tap(find.text('《隐私政策》'));
    await tester.pumpAndSettle();

    expect(find.text('无限花火隐私政策'), findsWidgets);
    expect(find.textContaining('2026年08月20日'), findsWidgets);
    expect(find.textContaining('杭州触达科技有限公司'), findsWidgets);
  });

  testWidgets('workspace storage failure is shown without a local quota', (
    tester,
  ) async {
    await _pumpPage(tester, BillingPlatform.android, storageAvailable: false);

    expect(
      find.byKey(const ValueKey('workspace-storage-unavailable')),
      findsOneWidget,
    );
    expect(find.text('30 GB'), findsNothing);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  BillingPlatform platform, {
  bool catalogFailure = false,
  _PageBillingApi? billingApi,
  bool storageAvailable = true,
  ThemeData? theme,
}) async {
  final controller = BillingController(
    api:
        billingApi ?? _PageBillingApi(platform, catalogFailure: catalogFailure),
    androidPayment: _PageAndroidPort(),
    iosStore: _PageIOSPort(),
    pendingOrders: _PagePendingStore(),
    platform: platform,
    userScope: 'user:page-test',
  );
  controller.startPurchaseStreams();
  final accountUsage = AccountUsageController(
    repository: _PageAccountUsagePort(storageAvailable: storageAvailable),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        billingControllerProvider.overrideWith((ref) => controller),
        accountUsageControllerProvider.overrideWith((ref) => accountUsage),
      ],
      child: MaterialApp(
        theme: theme,
        home: V3MembershipPage(
          billingController: billingControllerProvider,
          accountUsageController: accountUsageControllerProvider,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _PageBillingApi implements BillingApiPort {
  _PageBillingApi(
    this.platform, {
    this.catalogFailure = false,
    this.agreements,
  });

  final BillingPlatform platform;
  final bool catalogFailure;
  final List<BillingAgreement>? agreements;
  final List<ApiResult<MobileBillingTransactionPage>> transactionResults =
      <ApiResult<MobileBillingTransactionPage>>[];
  final List<String?> transactionCursors = <String?>[];

  @override
  Future<ApiResult<BillingCatalog>> catalog(BillingPlatform platform) async {
    if (catalogFailure) {
      return ApiResult<BillingCatalog>.failure(
        error: const AppFailure(
          code: 'BILLING_CATALOG_UNAVAILABLE',
          category: AppFailureCategory.api,
          message: 'catalog unavailable',
          userMessageKey: 'billing.catalog.unavailable',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return _pageSuccess(
      BillingCatalog(
        catalogRevision: 'billing-catalog-v1',
        appAccountToken: platform == BillingPlatform.ios
            ? '123e4567-e89b-42d3-a456-426614174000'
            : null,
        agreements:
            agreements ??
            <BillingAgreement>[
              for (final type in <String>{
                'membership_service',
                'purchase_refund',
                'privacy',
                if (platform == BillingPlatform.ios) 'auto_renew',
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
            period: platform == BillingPlatform.ios ? 'monthly' : 'days_30',
            title: platform == BillingPlatform.ios ? 'PRO 连续包月' : 'PRO 30天',
            enabled: false,
            benefits: const <String>['chat_2_daily'],
            availableProviders: const <BillingProvider>[],
            providerProductId: platform == BillingPlatform.ios
                ? 'com.hangzhouchuda.huahuoai.pro.monthly'
                : null,
            displayPrice: platform == BillingPlatform.android ? '¥15' : null,
            disabledReason: 'provider_not_configured',
          ),
        ],
      ),
    );
  }

  @override
  Future<ApiResult<MembershipEntitlement>> membership() async => _pageSuccess(
    const MembershipEntitlement(
      tier: MembershipTier.free,
      status: MembershipEntitlementStatus.expired,
      autoRenewEnabled: false,
      cancelAtPeriodEnd: false,
    ),
  );

  @override
  Future<ApiResult<PaymentOrder>> createAndroidOrder({
    required String sku,
    required BillingProvider provider,
    required String clientOrderKey,
    required Map<String, String> agreementVersions,
    required String idempotencyKey,
  }) => throw UnimplementedError();

  @override
  Future<ApiResult<PaymentOrder>> order(String orderId) =>
      throw UnimplementedError();

  @override
  Future<ApiResult<MembershipEntitlement>> verifyIOSPurchase({
    required String productId,
    required String purchaseId,
    required String verificationData,
    required String clientTransactionKey,
    required String idempotencyKey,
  }) => throw UnimplementedError();

  @override
  Future<ApiResult<MobileBillingTransactionPage>> transactions({
    String? cursor,
    int limit = 20,
  }) async {
    transactionCursors.add(cursor);
    if (transactionResults.isNotEmpty) return transactionResults.removeAt(0);
    return _pageSuccess(
      const MobileBillingTransactionPage(items: <MobileBillingTransaction>[]),
    );
  }
}

final class _PageAccountUsagePort implements AccountUsageRepository {
  @override
  Future<MobileAccountUsageResult<List<MobileQuotaBalance>>>
  quotaBalances() async => const MobileAccountUsageResult.success([]);

  const _PageAccountUsagePort({this.storageAvailable = true});

  final bool storageAvailable;

  @override
  Future<MobileAccountUsageResult<MobileAccountCreditPage>> credits({
    String? cursor,
    int limit = 50,
  }) async => MobileAccountUsageResult<MobileAccountCreditPage>.success(
    MobileAccountCreditPage(
      monthlyCredit: _pageMonthlyCredit(),
      permanentCredit: const MobileCreditPool(
        availableCredits: 500,
        reservedCredits: 0,
      ),
      lots: const <MobilePermanentCreditLot>[],
      runAdmission: 'allowed',
      outstandingUncoveredCredits: 0,
    ),
  );

  @override
  Future<MobileAccountUsageResult<MobileAccountMembership>>
  membership() async =>
      MobileAccountUsageResult<MobileAccountMembership>.success(
        MobileAccountMembership(
          membershipId: 'membership-page-1',
          levelCode: 'pilot_paid',
          status: 'active',
          expiresAt: null,
          monthlyCredit: _pageMonthlyCredit(),
          permanentCredit: const MobileCreditPool(
            availableCredits: 500,
            reservedCredits: 0,
          ),
          runAdmission: 'allowed',
          outstandingUncoveredCredits: 0,
        ),
      );

  @override
  Future<MobileAccountUsageResult<MobileRunUsage>> runUsage(
    String runId,
  ) async => const MobileAccountUsageResult<MobileRunUsage>.failure(
    'RUN_USAGE_NOT_REQUESTED',
  );

  @override
  Future<MobileAccountUsageResult<MobileWorkspaceStorageUsage>>
  storageUsage() async => storageAvailable
      ? const MobileAccountUsageResult<MobileWorkspaceStorageUsage>.success(
          MobileWorkspaceStorageUsage(
            userLogicalTotalBytes: 1073741824,
            limitBytes: 32212254720,
            remainingBytes: 31138512896,
            fileCountLimit: null,
            measurementStatus: 'complete',
          ),
        )
      : const MobileAccountUsageResult<MobileWorkspaceStorageUsage>.failure(
          'WORKSPACE_STORAGE_UNAVAILABLE',
        );
}

MobileCreditPool _pageMonthlyCredit() => MobileCreditPool(
  quotaCredits: 10000000,
  availableCredits: 9000000,
  reservedCredits: 100000,
  settledCredits: 900000,
  policyVersion: 'credit-policy-v1',
  periodStart: DateTime.utc(2026, 8, 1),
  periodEnd: DateTime.utc(2026, 9, 1),
  expiresAt: DateTime.utc(2026, 9, 1),
);

ApiResult<T> _pageSuccess<T>(T value) => ApiResult<T>.success(
  data: value,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

final class _PageAndroidPort implements AndroidPaymentPort {
  @override
  Stream<AndroidPaymentEvent> get events => const Stream.empty();

  @override
  Future<bool> isAvailable(BillingProvider provider) async => false;

  @override
  Future<AndroidPaymentClientResult> start({
    required BillingProvider provider,
    required String orderId,
    required Map<String, Object?> launchPayload,
  }) async => AndroidPaymentClientResult.unavailable;
}

final class _PageIOSPort implements IOSStorePurchasePort {
  @override
  Stream<IOSPurchaseUpdate> get purchaseUpdates => const Stream.empty();

  @override
  Future<void> completePurchase(String purchaseKey) async {}

  @override
  Future<List<IOSStoreProduct>> loadProducts(Set<String> productIds) async =>
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
  }) async => false;

  @override
  Future<void> restorePurchases() async {}
}

final class _PagePendingStore implements BillingPendingOrderStore {
  @override
  void clear(String userScope) {}

  @override
  String? read(String userScope) => null;

  @override
  void save(String userScope, String orderId) {}
}
