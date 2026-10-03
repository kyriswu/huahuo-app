// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../data/android_payment_port.dart';
import '../data/billing_api.dart';
import '../data/billing_pending_order_store.dart';
import '../data/ios_store_purchase_port.dart';

enum BillingStatus {
  idle,
  loadingCatalog,
  creatingOrder,
  waitingForProvider,
  confirming,
  pending,
  active,
  cancelled,
  failed,
  restoring,
}

enum BillingTransactionStatus {
  idle,
  loading,
  ready,
  loadingMore,
  empty,
  unavailable,
  failed,
}

@immutable
final class BillingState {
  const BillingState({
    this.status = BillingStatus.idle,
    this.products = const <BillingProduct>[],
    this.agreements = const <BillingAgreement>[],
    this.membership,
    this.errorCode,
    this.pendingOrderId,
  });

  final BillingStatus status;
  final List<BillingProduct> products;
  final List<BillingAgreement> agreements;
  final MembershipEntitlement? membership;
  final String? errorCode;
  final String? pendingOrderId;

  bool get busy => const <BillingStatus>{
    BillingStatus.loadingCatalog,
    BillingStatus.creatingOrder,
    BillingStatus.waitingForProvider,
    BillingStatus.confirming,
    BillingStatus.restoring,
  }.contains(status);

  BillingState copyWith({
    BillingStatus? status,
    List<BillingProduct>? products,
    List<BillingAgreement>? agreements,
    MembershipEntitlement? membership,
    bool clearMembership = false,
    String? errorCode,
    bool clearError = false,
    String? pendingOrderId,
    bool clearPendingOrder = false,
  }) => BillingState(
    status: status ?? this.status,
    products: products ?? this.products,
    agreements: agreements ?? this.agreements,
    membership: clearMembership ? null : membership ?? this.membership,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    pendingOrderId: clearPendingOrder
        ? null
        : pendingOrderId ?? this.pendingOrderId,
  );
}

final class BillingController extends ChangeNotifier {
  BillingController({
    required BillingApiPort api,
    required AndroidPaymentPort androidPayment,
    required IOSStorePurchasePort iosStore,
    required BillingPendingOrderStore pendingOrders,
    required BillingPlatform platform,
    required String userScope,
    int orderPollAttempts = 4,
    Duration orderPollInterval = const Duration(seconds: 1),
    Future<void> Function(Duration)? delay,
  }) : _api = api,
       _androidPayment = androidPayment,
       _iosStore = iosStore,
       _pendingOrders = pendingOrders,
       _platform = platform,
       _userScope = userScope,
       _orderPollAttempts = orderPollAttempts,
       _orderPollInterval = orderPollInterval,
       _delay = delay ?? Future<void>.delayed {
    if (orderPollAttempts < 1 || orderPollAttempts > 10) {
      throw ArgumentError.value(
        orderPollAttempts,
        'orderPollAttempts',
        'must be between 1 and 10',
      );
    }
    if (orderPollInterval.isNegative) {
      throw ArgumentError.value(
        orderPollInterval,
        'orderPollInterval',
        'must not be negative',
      );
    }
  }

  final BillingApiPort _api;
  final AndroidPaymentPort _androidPayment;
  final IOSStorePurchasePort _iosStore;
  final BillingPendingOrderStore _pendingOrders;
  final BillingPlatform _platform;
  final String _userScope;
  final int _orderPollAttempts;
  final Duration _orderPollInterval;
  final Future<void> Function(Duration) _delay;
  StreamSubscription<IOSPurchaseUpdate>? _iosSubscription;
  StreamSubscription<AndroidPaymentEvent>? _androidSubscription;
  BillingCatalog? _catalog;
  _AndroidPurchaseIntent? _androidIntent;
  int _requestSequence = 0;
  int _loadSequence = 0;
  int _transactionSequence = 0;
  int _confirmationGeneration = 0;
  String? _confirmationOrderId;
  final Set<String> _iosVerificationInFlight = <String>{};
  Future<BillingCatalog?>? _verificationCatalogLoad;
  final Set<String> _storeProductIds = <String>{};
  final List<MobileBillingTransaction> _transactions =
      <MobileBillingTransaction>[];
  final Set<String> _seenTransactionCursors = <String>{};
  BillingTransactionStatus _transactionStatus = BillingTransactionStatus.idle;
  String? _nextTransactionCursor;
  String? _transactionErrorCode;
  bool _disposed = false;

  BillingState _state = const BillingState();
  BillingState get state => _state;
  BillingPlatform get platform => _platform;
  BillingTransactionStatus get transactionStatus => _transactionStatus;
  List<MobileBillingTransaction> get transactions =>
      List<MobileBillingTransaction>.unmodifiable(_transactions);
  String? get transactionErrorCode => _transactionErrorCode;
  bool get hasMoreTransactions => _nextTransactionCursor != null;
  bool get agreementsReady => _hasRequiredAgreements(_state.agreements);

  bool canPurchase(BillingProduct product) {
    if (!product.enabled || !agreementsReady || product.displayPrice == null) {
      return false;
    }
    if (_platform == BillingPlatform.ios) {
      final productId = product.providerProductId;
      return productId != null && _storeProductIds.contains(productId);
    }
    return product.availableProviders.any(
      (provider) =>
          provider == BillingProvider.wechat ||
          provider == BillingProvider.alipay,
    );
  }

  void startPurchaseStreams() {
    switch (_platform) {
      case BillingPlatform.ios:
        if (_iosSubscription != null) return;
        _iosSubscription = _iosStore.purchaseUpdates.listen(
          _handleIOSPurchase,
          onError: _handlePurchaseStreamError,
        );
      case BillingPlatform.android:
        if (_androidSubscription != null) return;
        _androidSubscription = _androidPayment.events.listen(
          _handleAndroidEvent,
          onError: _handlePurchaseStreamError,
        );
    }
  }

  Future<void> load() async {
    final sequence = ++_loadSequence;
    _setState(
      _state.copyWith(status: BillingStatus.loadingCatalog, clearError: true),
    );
    ApiResult<BillingCatalog> catalogResult;
    try {
      catalogResult = await _api.catalog(_platform);
    } on Object {
      if (_isCurrentLoad(sequence)) {
        _failCatalog('BILLING_CATALOG_UNAVAILABLE');
      }
      return;
    }
    if (!_isCurrentLoad(sequence)) return;
    if (!catalogResult.ok || catalogResult.data == null) {
      _failCatalog(catalogResult.error?.code ?? 'BILLING_CATALOG_UNAVAILABLE');
      return;
    }
    _catalog = catalogResult.data;
    var products = _catalog!.items;
    String? catalogWarning;
    if (!_hasRequiredAgreements(_catalog!.agreements)) {
      catalogWarning = 'BILLING_AGREEMENTS_UNAVAILABLE';
    }
    _storeProductIds.clear();
    if (_platform == BillingPlatform.ios) {
      final productIDs = products
          .map((item) => item.providerProductId)
          .whereType<String>()
          .toSet();
      List<IOSStoreProduct> storeProducts;
      try {
        storeProducts = await _iosStore.loadProducts(productIDs);
      } on Object {
        storeProducts = const <IOSStoreProduct>[];
      }
      if (!_isCurrentLoad(sequence)) return;
      _storeProductIds.addAll(storeProducts.map((item) => item.productId));
      final prices = <String, String>{
        for (final item in storeProducts)
          if (item.localizedPrice.trim().isNotEmpty)
            item.productId: item.localizedPrice,
      };
      products = products
          .map(
            (item) =>
                item.providerProductId != null &&
                    prices[item.providerProductId] != null
                ? item.withStorePrice(prices[item.providerProductId]!)
                : item,
          )
          .toList(growable: false);
      if (products.any(
        (item) =>
            item.enabled &&
            (item.providerProductId == null ||
                prices[item.providerProductId] == null),
      )) {
        catalogWarning ??= 'BILLING_STORE_PRODUCT_UNAVAILABLE';
      }
    }
    ApiResult<MembershipEntitlement> membershipResult;
    try {
      membershipResult = await _api.membership();
    } on Object {
      membershipResult = ApiResult<MembershipEntitlement>.failure(
        error: const AppFailure(
          code: 'BILLING_MEMBERSHIP_LOAD_FAILED',
          category: AppFailureCategory.api,
          message: 'Billing membership request failed',
          userMessageKey: 'billing.membership.failed',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    if (!_isCurrentLoad(sequence)) return;
    catalogWarning ??= membershipResult.ok
        ? null
        : membershipResult.error?.code ?? 'BILLING_MEMBERSHIP_LOAD_FAILED';
    _setState(
      BillingState(
        status: membershipResult.data?.isActive == true
            ? BillingStatus.active
            : BillingStatus.idle,
        products: List<BillingProduct>.unmodifiable(products),
        agreements: _catalog!.agreements,
        membership: membershipResult.data,
        errorCode: catalogWarning,
      ),
    );
    if (_platform == BillingPlatform.android) await recoverPendingOrder();
  }

  Future<void> purchaseAndroid({
    required BillingProduct product,
    required BillingProvider provider,
  }) async {
    if (_platform != BillingPlatform.android ||
        (_state.busy && _state.status != BillingStatus.pending)) {
      return;
    }
    if (!agreementsReady) {
      _fail('BILLING_AGREEMENTS_UNAVAILABLE');
      return;
    }
    if (!product.enabled ||
        !product.availableProviders.contains(provider) ||
        (provider != BillingProvider.wechat &&
            provider != BillingProvider.alipay)) {
      _fail('BILLING_PROVIDER_UNAVAILABLE');
      return;
    }
    bool providerAvailable;
    try {
      providerAvailable = await _androidPayment.isAvailable(provider);
    } on Object {
      providerAvailable = false;
    }
    if (!providerAvailable) {
      _fail('BILLING_PAYMENT_APP_UNAVAILABLE');
      return;
    }
    final intent = _androidIntentFor(product.sku, provider);
    _setState(
      _state.copyWith(status: BillingStatus.creatingOrder, clearError: true),
    );
    ApiResult<PaymentOrder> result;
    try {
      result = await _api.createAndroidOrder(
        sku: product.sku,
        provider: provider,
        clientOrderKey: intent.requestKey,
        agreementVersions: _agreementVersions(),
        idempotencyKey: intent.requestKey,
      );
    } on Object {
      _fail('BILLING_ORDER_CREATE_FAILED');
      return;
    }
    final order = result.data;
    if (!result.ok || order == null || order.launchPayload == null) {
      _fail(result.error?.code ?? 'BILLING_ORDER_CREATE_FAILED');
      return;
    }
    try {
      _pendingOrders.save(_userScope, order.orderId);
    } on Object {
      _fail('BILLING_PENDING_ORDER_STORE_FAILED');
      return;
    }
    _setState(
      _state.copyWith(
        status: BillingStatus.waitingForProvider,
        pendingOrderId: order.orderId,
      ),
    );
    AndroidPaymentClientResult clientResult;
    try {
      clientResult = await _androidPayment.start(
        provider: provider,
        orderId: order.orderId,
        launchPayload: order.launchPayload!,
      );
    } on Object {
      clientResult = AndroidPaymentClientResult.failed;
    }
    if (clientResult == AndroidPaymentClientResult.cancelled) {
      _clearAndroidIntent();
      _setState(_state.copyWith(status: BillingStatus.cancelled));
      return;
    }
    await _confirmOrder(
      order.orderId,
      pendingErrorCode:
          clientResult == AndroidPaymentClientResult.unavailable ||
              clientResult == AndroidPaymentClientResult.failed
          ? 'BILLING_PROVIDER_UNAVAILABLE'
          : null,
    );
  }

  Future<void> purchaseIOS(BillingProduct product) async {
    if (_platform != BillingPlatform.ios || _state.busy) return;
    final productID = product.providerProductId;
    final appAccountToken = _catalog?.appAccountToken;
    if (!agreementsReady) {
      _fail('BILLING_AGREEMENTS_UNAVAILABLE');
      return;
    }
    if (!product.enabled ||
        productID == null ||
        product.displayPrice == null ||
        !_storeProductIds.contains(productID) ||
        appAccountToken == null) {
      _fail('BILLING_STORE_PRODUCT_UNAVAILABLE');
      return;
    }
    _setState(
      _state.copyWith(
        status: BillingStatus.waitingForProvider,
        clearError: true,
      ),
    );
    try {
      final started = await _iosStore.purchase(
        productId: productID,
        appAccountToken: appAccountToken,
      );
      if (!started) _fail('BILLING_STORE_PRODUCT_UNAVAILABLE');
    } on Object {
      _fail('BILLING_PROVIDER_UNAVAILABLE');
    }
  }

  Future<void> restoreIOSPurchases() async {
    if (_platform != BillingPlatform.ios || _state.busy) return;
    _setState(
      _state.copyWith(status: BillingStatus.restoring, clearError: true),
    );
    try {
      await _iosStore.restorePurchases();
      if (!_disposed && _state.status == BillingStatus.restoring) {
        _setState(
          _state.copyWith(
            status: _state.membership?.isActive == true
                ? BillingStatus.active
                : BillingStatus.idle,
            clearError: true,
          ),
        );
      }
    } catch (_) {
      _fail('BILLING_RESTORE_FAILED');
    }
  }

  Future<void> recoverPendingOrder() async {
    if (_platform != BillingPlatform.android) return;
    String? orderID;
    try {
      orderID = _pendingOrders.read(_userScope);
    } on Object {
      _fail('BILLING_PENDING_ORDER_STORE_FAILED');
      return;
    }
    if (orderID == null) return;
    await _confirmOrder(orderID);
  }

  Future<void> retryPendingOrder() => recoverPendingOrder();

  Future<void> _handleIOSPurchase(IOSPurchaseUpdate update) async {
    switch (update.state) {
      case IOSPurchaseState.pending:
        _setState(
          _state.copyWith(status: BillingStatus.confirming, clearError: true),
        );
      case IOSPurchaseState.cancelled:
        _setState(
          _state.copyWith(status: BillingStatus.cancelled, clearError: true),
        );
      case IOSPurchaseState.error:
        _fail(update.errorCode ?? 'BILLING_PURCHASE_FAILED');
      case IOSPurchaseState.purchased:
      case IOSPurchaseState.restored:
        if (!_iosVerificationInFlight.add(update.key)) return;
        if (update.key.trim().isEmpty) {
          _iosVerificationInFlight.remove(update.key);
          _fail('BILLING_PURCHASE_INVALID');
          return;
        }
        final purchaseID = update.purchaseId?.trim();
        if (purchaseID == null ||
            purchaseID.isEmpty ||
            update.verificationData.trim().isEmpty) {
          _iosVerificationInFlight.remove(update.key);
          _fail('BILLING_PURCHASE_INVALID');
          return;
        }
        await _catalogForVerification();
        final product = _catalogProductForProviderId(update.productId);
        if (product == null) {
          _iosVerificationInFlight.remove(update.key);
          _fail('BILLING_STORE_PRODUCT_UNAVAILABLE');
          return;
        }
        _setState(
          _state.copyWith(status: BillingStatus.confirming, clearError: true),
        );
        ApiResult<MembershipEntitlement> result;
        try {
          result = await _api.verifyIOSPurchase(
            productId: update.productId,
            purchaseId: purchaseID,
            verificationData: update.verificationData,
            clientTransactionKey: update.key,
            idempotencyKey: _verificationKey(update.key),
          );
        } on Object {
          result = ApiResult<MembershipEntitlement>.failure(
            error: const AppFailure(
              code: 'BILLING_PROVIDER_RESPONSE_INVALID',
              category: AppFailureCategory.network,
              message: 'Apple verification request failed',
              userMessageKey: 'billing.verify.retry',
              isRetryable: true,
            ),
            idempotencyStore: SubmissionKeyStore.empty,
          );
        }
        _iosVerificationInFlight.remove(update.key);
        if (!result.ok || result.data == null) {
          final code = result.error?.code ?? 'BILLING_PURCHASE_INVALID';
          if (code == 'BILLING_PURCHASE_PENDING' ||
              result.error?.isRetryable == true) {
            _setState(
              _state.copyWith(
                status: BillingStatus.confirming,
                errorCode: code,
              ),
            );
          } else {
            _fail(code);
          }
          return;
        }
        final membership = result.data!;
        if (!_membershipMatchesProduct(membership, product)) {
          if (membership.status == MembershipEntitlementStatus.pending) {
            _setState(
              _state.copyWith(
                status: BillingStatus.confirming,
                errorCode: 'BILLING_PURCHASE_PENDING',
              ),
            );
          } else {
            _fail('BILLING_PURCHASE_ENTITLEMENT_INVALID');
          }
          return;
        }
        try {
          await _iosStore.completePurchase(update.key);
        } on Object {
          _setState(
            _state.copyWith(
              status: BillingStatus.active,
              membership: membership,
              errorCode: 'BILLING_STORE_COMPLETE_FAILED',
            ),
          );
          return;
        }
        _setState(
          _state.copyWith(
            status: BillingStatus.active,
            membership: membership,
            clearError: true,
          ),
        );
    }
  }

  Future<void> _handleAndroidEvent(AndroidPaymentEvent event) async {
    if (event.orderId != _state.pendingOrderId) return;
    final intent = _currentAndroidIntent();
    if (intent != null && event.provider != intent.provider) return;
    if (event.result == AndroidPaymentClientResult.cancelled) {
      _clearAndroidIntent();
      _setState(_state.copyWith(status: BillingStatus.cancelled));
      return;
    }
    await _confirmOrder(
      event.orderId,
      pendingErrorCode:
          event.result == AndroidPaymentClientResult.unavailable ||
              event.result == AndroidPaymentClientResult.failed
          ? 'BILLING_PROVIDER_UNAVAILABLE'
          : null,
    );
  }

  void _handlePurchaseStreamError(Object error, StackTrace stackTrace) {
    _fail('BILLING_PROVIDER_UNAVAILABLE');
  }

  Future<void> loadTransactions() async {
    if (_transactionStatus == BillingTransactionStatus.loading) return;
    _transactionSequence += 1;
    _transactions.clear();
    _seenTransactionCursors.clear();
    _nextTransactionCursor = null;
    await _loadTransactionPage(reset: true, sequence: _transactionSequence);
  }

  Future<void> retryTransactions() => loadTransactions();

  Future<void> loadMoreTransactions() async {
    if (_nextTransactionCursor == null ||
        _transactionStatus == BillingTransactionStatus.loading ||
        _transactionStatus == BillingTransactionStatus.loadingMore) {
      return;
    }
    await _loadTransactionPage(reset: false, sequence: _transactionSequence);
  }

  Future<void> _loadTransactionPage({
    required bool reset,
    required int sequence,
  }) async {
    _transactionStatus = reset
        ? BillingTransactionStatus.loading
        : BillingTransactionStatus.loadingMore;
    _transactionErrorCode = null;
    _notify();
    ApiResult<MobileBillingTransactionPage> result;
    try {
      result = await _api.transactions(
        cursor: reset ? null : _nextTransactionCursor,
        limit: 20,
      );
    } on Object {
      result = ApiResult<MobileBillingTransactionPage>.failure(
        error: const AppFailure(
          code: 'BILLING_TRANSACTIONS_LOAD_FAILED',
          category: AppFailureCategory.network,
          message: 'Billing transaction request failed',
          userMessageKey: 'billing.transactions.failed',
          isRetryable: true,
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    if (_disposed || sequence != _transactionSequence) return;
    final page = result.data;
    if (!result.ok || page == null) {
      final code = result.error?.code ?? 'BILLING_TRANSACTIONS_LOAD_FAILED';
      _transactionStatus = _isUnavailableCode(code)
          ? BillingTransactionStatus.unavailable
          : BillingTransactionStatus.failed;
      _transactionErrorCode = code;
      _notify();
      return;
    }
    final next = _nonEmpty(page.nextCursor);
    if (next != null && !_seenTransactionCursors.add(next)) {
      _transactionStatus = BillingTransactionStatus.failed;
      _transactionErrorCode = 'BILLING_TRANSACTION_CURSOR_INVALID';
      _nextTransactionCursor = null;
      _notify();
      return;
    }
    final existing = <String>{
      for (final item in _transactions) item.transactionId,
    };
    for (final item in page.items) {
      if (existing.add(item.transactionId)) _transactions.add(item);
    }
    _nextTransactionCursor = next;
    _transactionStatus = _transactions.isEmpty
        ? BillingTransactionStatus.empty
        : BillingTransactionStatus.ready;
    _transactionErrorCode = null;
    _notify();
  }

  Future<void> _confirmOrder(String orderID, {String? pendingErrorCode}) async {
    if (_confirmationOrderId == orderID || _disposed) return;
    final generation = ++_confirmationGeneration;
    _confirmationOrderId = orderID;
    _setState(
      _state.copyWith(
        status: BillingStatus.confirming,
        pendingOrderId: orderID,
        clearError: true,
      ),
    );
    AppFailure? lastFailure;
    try {
      for (var attempt = 0; attempt < _orderPollAttempts; attempt += 1) {
        ApiResult<PaymentOrder> result;
        try {
          result = await _api.order(orderID);
        } on Object {
          result = ApiResult<PaymentOrder>.failure(
            error: const AppFailure(
              code: 'BILLING_ORDER_CONFIRM_FAILED',
              category: AppFailureCategory.network,
              message: 'Billing order confirmation failed',
              userMessageKey: 'billing.order.retry',
              isRetryable: true,
            ),
            idempotencyStore: SubmissionKeyStore.empty,
          );
        }
        if (!_isCurrentConfirmation(generation, orderID)) return;
        final order = result.data;
        if (!result.ok || order == null) {
          lastFailure = result.error;
          if (!_isRetryableOrderFailure(lastFailure)) {
            if (lastFailure?.code == 'BILLING_ORDER_NOT_FOUND') {
              _clearCompletedAndroidOrder();
              _setState(
                _state.copyWith(
                  status: BillingStatus.failed,
                  errorCode: lastFailure!.code,
                  clearPendingOrder: true,
                ),
              );
              return;
            }
            _fail(lastFailure?.code ?? 'BILLING_ORDER_CONFIRM_FAILED');
            return;
          }
        } else {
          lastFailure = null;
          final intent = _currentAndroidIntent();
          if (intent != null && (!intent.matches(order.sku, order.provider))) {
            _fail('BILLING_ORDER_RESPONSE_MISMATCH');
            return;
          }
          if (order.status == PaymentOrderStatus.succeeded) {
            final membership = order.membership;
            if (membership == null ||
                !_membershipMatchesSku(membership, order.sku)) {
              _fail('BILLING_ORDER_MEMBERSHIP_INVALID');
              return;
            }
            _clearCompletedAndroidOrder();
            _setState(
              _state.copyWith(
                status: BillingStatus.active,
                membership: membership,
                clearPendingOrder: true,
                clearError: true,
              ),
            );
            return;
          }
          if (order.isTerminal) {
            _clearCompletedAndroidOrder();
            final cancelled =
                order.status == PaymentOrderStatus.cancelled ||
                order.status == PaymentOrderStatus.closed;
            _setState(
              _state.copyWith(
                status: cancelled
                    ? BillingStatus.cancelled
                    : BillingStatus.failed,
                errorCode: _terminalOrderCode(order.status),
                clearPendingOrder: true,
              ),
            );
            return;
          }
        }
        if (attempt + 1 < _orderPollAttempts) {
          await _delay(_orderPollInterval);
          if (!_isCurrentConfirmation(generation, orderID)) return;
        }
      }
      _setState(
        _state.copyWith(
          status: BillingStatus.pending,
          pendingOrderId: orderID,
          errorCode: lastFailure?.code ?? pendingErrorCode,
          clearError: lastFailure == null && pendingErrorCode == null,
        ),
      );
    } finally {
      if (_isCurrentConfirmation(generation, orderID)) {
        _confirmationOrderId = null;
      }
    }
  }

  Map<String, String> _agreementVersions() => <String, String>{
    for (final agreement in _state.agreements)
      agreement.type: agreement.version,
  };

  bool _hasRequiredAgreements(List<BillingAgreement> agreements) {
    final versions = <String, String>{};
    for (final agreement in agreements) {
      if (versions.containsKey(agreement.type)) return false;
      versions[agreement.type] = agreement.version;
    }
    return versions.keys.toSet().containsAll(
      _requiredAgreementTypes(_platform),
    );
  }

  _AndroidPurchaseIntent _androidIntentFor(
    String sku,
    BillingProvider provider,
  ) {
    final current = _currentAndroidIntent();
    if (current != null && current.matches(sku, provider)) return current;
    return _androidIntent = _AndroidPurchaseIntent(
      sku: sku,
      provider: provider,
      requestKey: _newRequestKey('android-order'),
    );
  }

  _AndroidPurchaseIntent? _currentAndroidIntent() => _androidIntent;

  void _clearAndroidIntent() {
    _androidIntent = null;
  }

  void _clearCompletedAndroidOrder() {
    try {
      _pendingOrders.clear(_userScope);
    } on Object {
      // A later startup recovery will re-read and safely confirm the same order.
    }
    _clearAndroidIntent();
  }

  BillingProduct? _catalogProductForProviderId(String providerProductId) {
    final catalog = _catalog;
    if (catalog == null) return null;
    for (final product in catalog.items) {
      if (product.providerProductId == providerProductId) return product;
    }
    return null;
  }

  Future<BillingCatalog?> _catalogForVerification() async {
    if (_catalog != null) return _catalog;
    final current = _verificationCatalogLoad;
    if (current != null) return current;
    final future = () async {
      try {
        final result = await _api.catalog(BillingPlatform.ios);
        if (result.ok && result.data != null) _catalog = result.data;
      } on Object {
        return null;
      }
      return _catalog;
    }();
    _verificationCatalogLoad = future;
    try {
      return await future;
    } finally {
      if (identical(_verificationCatalogLoad, future)) {
        _verificationCatalogLoad = null;
      }
    }
  }

  bool _membershipMatchesProduct(
    MembershipEntitlement membership,
    BillingProduct product,
  ) =>
      membership.isActive &&
      membership.tier == product.tier &&
      (membership.productSku == null || membership.productSku == product.sku);

  bool _membershipMatchesSku(MembershipEntitlement membership, String sku) =>
      membership.isActive &&
      membership.tier == _tierForSku(sku) &&
      (membership.productSku == null || membership.productSku == sku);

  bool _isCurrentLoad(int sequence) => !_disposed && sequence == _loadSequence;

  bool _isCurrentConfirmation(int generation, String orderID) =>
      !_disposed &&
      generation == _confirmationGeneration &&
      _confirmationOrderId == orderID;

  String _newRequestKey(String prefix) {
    _requestSequence += 1;
    return '$prefix-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_requestSequence';
  }

  String _verificationKey(String purchaseKey) {
    final normalized = purchaseKey.replaceAll(RegExp('[^A-Za-z0-9_.:-]'), '_');
    return 'ios-verify-${normalized.substring(0, normalized.length.clamp(0, 96))}';
  }

  void _fail(String code) {
    _setState(_state.copyWith(status: BillingStatus.failed, errorCode: code));
  }

  void _failCatalog(String code) {
    _catalog = null;
    _storeProductIds.clear();
    _setState(BillingState(status: BillingStatus.failed, errorCode: code));
  }

  void _setState(BillingState value) {
    if (_disposed) return;
    _state = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadSequence += 1;
    _transactionSequence += 1;
    _confirmationGeneration += 1;
    unawaited(_iosSubscription?.cancel());
    unawaited(_androidSubscription?.cancel());
    super.dispose();
  }
}

final class _AndroidPurchaseIntent {
  const _AndroidPurchaseIntent({
    required this.sku,
    required this.provider,
    required this.requestKey,
  });

  final String sku;
  final BillingProvider provider;
  final String requestKey;

  bool matches(String sku, BillingProvider provider) =>
      this.sku == sku && this.provider == provider;
}

Set<String> _requiredAgreementTypes(BillingPlatform platform) => <String>{
  'membership_service',
  'purchase_refund',
  'privacy',
  if (platform == BillingPlatform.ios) 'auto_renew',
};

MembershipTier _tierForSku(String sku) => switch (sku) {
  'pro_30d' || 'pro_365d' => MembershipTier.pro,
  'max_365d' => MembershipTier.max,
  _ => throw ArgumentError.value(sku, 'sku', 'Unsupported billing SKU'),
};

bool _isRetryableOrderFailure(AppFailure? failure) =>
    failure == null ||
    failure.isRetryable ||
    failure.category == AppFailureCategory.network ||
    const <String>{
      'BILLING_PROVIDER_UNAVAILABLE',
      'BILLING_PROVIDER_RESPONSE_INVALID',
      'BILLING_ORDER_CONFIRM_FAILED',
      'API_NETWORK_FAILURE',
      'API_TIMEOUT',
    }.contains(failure.code);

String _terminalOrderCode(PaymentOrderStatus status) => switch (status) {
  PaymentOrderStatus.cancelled => 'BILLING_ORDER_CANCELLED',
  PaymentOrderStatus.closed => 'BILLING_ORDER_CLOSED',
  PaymentOrderStatus.failed => 'BILLING_ORDER_FAILED',
  PaymentOrderStatus.refunded => 'BILLING_ORDER_REFUNDED',
  _ => 'BILLING_ORDER_STATE_CONFLICT',
};

bool _isUnavailableCode(String code) =>
    code == 'BILLING_AUTH_REQUIRED' ||
    code == 'API_BASE_URL_UNCONFIGURED' ||
    code.endsWith('_UNAVAILABLE');

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
