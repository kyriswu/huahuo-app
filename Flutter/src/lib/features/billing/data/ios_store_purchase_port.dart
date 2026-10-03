import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

enum IOSPurchaseState { pending, purchased, restored, cancelled, error }

final class IOSStoreProduct {
  const IOSStoreProduct({
    required this.productId,
    required this.title,
    required this.localizedPrice,
  });

  final String productId;
  final String title;
  final String localizedPrice;
}

final class IOSPurchaseUpdate {
  const IOSPurchaseUpdate({
    required this.key,
    required this.productId,
    required this.state,
    required this.verificationData,
    this.purchaseId,
    this.errorCode,
  });

  final String key;
  final String productId;
  final String? purchaseId;
  final IOSPurchaseState state;
  final String verificationData;
  final String? errorCode;
}

abstract interface class IOSStorePurchasePort {
  Stream<IOSPurchaseUpdate> get purchaseUpdates;

  Future<List<IOSStoreProduct>> loadProducts(Set<String> productIds);

  Future<bool> purchase({
    required String productId,
    required String appAccountToken,
  });

  Future<void> restorePurchases();

  Future<void> completePurchase(String purchaseKey);
}

final class AppStorePurchasePort implements IOSStorePurchasePort {
  AppStorePurchasePort({InAppPurchase? store})
    : _store = store ?? InAppPurchase.instance {
    _updates = _store.purchaseStream
        .expand((details) => details)
        .map(_mapPurchase)
        .asBroadcastStream();
  }

  final InAppPurchase _store;
  late final Stream<IOSPurchaseUpdate> _updates;
  final Map<String, ProductDetails> _products = <String, ProductDetails>{};
  final Map<String, PurchaseDetails> _pending = <String, PurchaseDetails>{};

  @override
  Stream<IOSPurchaseUpdate> get purchaseUpdates => _updates;

  @override
  Future<List<IOSStoreProduct>> loadProducts(Set<String> productIds) async {
    if (!await _store.isAvailable()) return const <IOSStoreProduct>[];
    final response = await _store.queryProductDetails(productIds);
    if (response.error != null) return const <IOSStoreProduct>[];
    _products
      ..clear()
      ..addEntries(
        response.productDetails.map((item) => MapEntry(item.id, item)),
      );
    return List<IOSStoreProduct>.unmodifiable(
      response.productDetails.map(
        (item) => IOSStoreProduct(
          productId: item.id,
          title: item.title,
          localizedPrice: item.price,
        ),
      ),
    );
  }

  @override
  Future<bool> purchase({
    required String productId,
    required String appAccountToken,
  }) async {
    final product = _products[productId];
    if (product == null || !_uuidPattern.hasMatch(appAccountToken)) {
      return false;
    }
    return _store.buyNonConsumable(
      purchaseParam: PurchaseParam(
        productDetails: product,
        applicationUserName: appAccountToken,
      ),
    );
  }

  @override
  Future<void> restorePurchases() => _store.restorePurchases();

  @override
  Future<void> completePurchase(String purchaseKey) async {
    final details = _pending.remove(purchaseKey);
    if (details != null && details.pendingCompletePurchase) {
      await _store.completePurchase(details);
    }
  }

  IOSPurchaseUpdate _mapPurchase(PurchaseDetails details) {
    final key = _purchaseKey(details);
    if (details.pendingCompletePurchase) {
      _pending[key] = details;
    }
    return IOSPurchaseUpdate(
      key: key,
      productId: details.productID,
      purchaseId: details.purchaseID,
      state: switch (details.status) {
        PurchaseStatus.pending => IOSPurchaseState.pending,
        PurchaseStatus.purchased => IOSPurchaseState.purchased,
        PurchaseStatus.restored => IOSPurchaseState.restored,
        PurchaseStatus.canceled => IOSPurchaseState.cancelled,
        PurchaseStatus.error => IOSPurchaseState.error,
      },
      verificationData: details.verificationData.serverVerificationData,
      errorCode: details.error?.code,
    );
  }
}

String _purchaseKey(PurchaseDetails details) {
  final purchaseID = details.purchaseID?.trim();
  if (purchaseID != null && purchaseID.isNotEmpty) return purchaseID;
  final transactionDate = details.transactionDate?.trim();
  return '${details.productID}:${transactionDate ?? 'pending'}';
}

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
