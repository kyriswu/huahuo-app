import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../features/billing/application/billing_controller.dart';
import '../../features/billing/data/android_payment_port.dart';
import '../../features/billing/data/billing_api.dart';
import '../../features/billing/data/billing_pending_order_store.dart';
import '../../features/billing/data/ios_store_purchase_port.dart';
import '../bootstrap/core_provider_module.dart';
import 'database_providers.dart';

// resident-provider: Shares one billing api dependency for the full account session.
final billingApiProvider = Provider<BillingApiPort>((ref) {
  return MobileBillingApi(BillingClient(ref.watch(apiClientProvider)));
});

// resident-provider: Shares one android payment port dependency for the full account session.
final androidPaymentPortProvider = Provider<AndroidPaymentPort>((ref) {
  return MethodChannelAndroidPaymentPort();
});

// resident-provider: Shares one ios store purchase port dependency for the full account session.
final iosStorePurchasePortProvider = Provider<IOSStorePurchasePort>((ref) {
  return AppStorePurchasePort();
});

// resident-provider: Shares one account-scoped billing pending order store identity across dependent controllers.
final billingPendingOrderStoreProvider = Provider<BillingPendingOrderStore>((
  ref,
) {
  return AppPreferencesBillingPendingOrderStore(
    preferences: ref.watch(appPreferencesDaoProvider),
  );
});

// resident-provider: Keeps the billing platform value consistent across sibling route consumers.
final billingPlatformProvider = Provider<BillingPlatform>((ref) {
  return defaultTargetPlatform == TargetPlatform.iOS
      ? BillingPlatform.ios
      : BillingPlatform.android;
});

// resident-provider: Preserves the billing controller state machine across route transitions.
final billingControllerProvider = ChangeNotifierProvider<BillingController>((
  ref,
) {
  final userScope = ref.watch(authenticatedUserDataScopeProvider);
  BillingApiPort api = const UnavailableBillingApi();
  if (userScope != 'anonymous') {
    try {
      api = ref.watch(billingApiProvider);
    } on StateError catch (error) {
      if (error.message != 'DEVICE_IDENTITY_NOT_RESOLVED') rethrow;
    }
  }
  final controller = BillingController(
    api: api,
    androidPayment: ref.watch(androidPaymentPortProvider),
    iosStore: ref.watch(iosStorePurchasePortProvider),
    pendingOrders: ref.watch(billingPendingOrderStoreProvider),
    platform: ref.watch(billingPlatformProvider),
    userScope: userScope,
  );
  controller.startPurchaseStreams();
  return controller;
});
