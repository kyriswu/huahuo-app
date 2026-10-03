import 'package:huahuo_api/huahuo_api.dart';

final class MobileBillingTransaction {
  MobileBillingTransaction({
    required String transactionId,
    required String sku,
    required String status,
  }) : transactionId = _requiredValue(transactionId, 'transactionId'),
       sku = _requiredValue(sku, 'sku'),
       status = _requiredValue(status, 'status') {
    if (!_billingSkus.contains(this.sku)) {
      throw FormatException('Unsupported billing transaction SKU: ${this.sku}');
    }
  }

  factory MobileBillingTransaction.fromContract(ApiContractObject value) {
    return MobileBillingTransaction(
      transactionId: value.requireString('transactionId'),
      sku: value.requireString('sku'),
      status: value.requireString('status'),
    );
  }

  final String transactionId;
  final String sku;
  final String status;
}

final class MobileBillingTransactionPage {
  const MobileBillingTransactionPage({required this.items, this.nextCursor});

  final List<MobileBillingTransaction> items;
  final String? nextCursor;
}

abstract interface class BillingApiPort {
  Future<ApiResult<BillingCatalog>> catalog(BillingPlatform platform);

  Future<ApiResult<PaymentOrder>> createAndroidOrder({
    required String sku,
    required BillingProvider provider,
    required String clientOrderKey,
    required Map<String, String> agreementVersions,
    required String idempotencyKey,
  });

  Future<ApiResult<PaymentOrder>> order(String orderId);

  Future<ApiResult<MembershipEntitlement>> verifyIOSPurchase({
    required String productId,
    required String purchaseId,
    required String verificationData,
    required String clientTransactionKey,
    required String idempotencyKey,
  });

  Future<ApiResult<MembershipEntitlement>> membership();

  Future<ApiResult<MobileBillingTransactionPage>> transactions({
    String? cursor,
    int limit = 20,
  });
}

final class UnavailableBillingApi implements BillingApiPort {
  const UnavailableBillingApi({this.code = 'BILLING_AUTH_REQUIRED'});

  final String code;

  ApiResult<T> _unavailable<T>() => ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'Billing API is unavailable before authenticated bootstrap',
      userMessageKey: 'billing.api.unavailable',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<BillingCatalog>> catalog(BillingPlatform platform) async =>
      _unavailable();

  @override
  Future<ApiResult<PaymentOrder>> createAndroidOrder({
    required String sku,
    required BillingProvider provider,
    required String clientOrderKey,
    required Map<String, String> agreementVersions,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ApiResult<PaymentOrder>> order(String orderId) async => _unavailable();

  @override
  Future<ApiResult<MembershipEntitlement>> verifyIOSPurchase({
    required String productId,
    required String purchaseId,
    required String verificationData,
    required String clientTransactionKey,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<ApiResult<MembershipEntitlement>> membership() async => _unavailable();

  @override
  Future<ApiResult<MobileBillingTransactionPage>> transactions({
    String? cursor,
    int limit = 20,
  }) async => _unavailable();
}

final class MobileBillingApi implements BillingApiPort {
  const MobileBillingApi(this._client);

  final BillingClient _client;

  @override
  Future<ApiResult<BillingCatalog>> catalog(BillingPlatform platform) =>
      _client.catalog(platform);

  @override
  Future<ApiResult<PaymentOrder>> createAndroidOrder({
    required String sku,
    required BillingProvider provider,
    required String clientOrderKey,
    required Map<String, String> agreementVersions,
    required String idempotencyKey,
  }) => _client.createAndroidOrder(
    sku: sku,
    provider: provider,
    clientOrderKey: clientOrderKey,
    agreementVersions: agreementVersions,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<ApiResult<PaymentOrder>> order(String orderId) =>
      _client.order(orderId);

  @override
  Future<ApiResult<MembershipEntitlement>> verifyIOSPurchase({
    required String productId,
    required String purchaseId,
    required String verificationData,
    required String clientTransactionKey,
    required String idempotencyKey,
  }) => _client.verifyIOSPurchase(
    productId: productId,
    purchaseId: purchaseId,
    verificationData: verificationData,
    clientTransactionKey: clientTransactionKey,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<ApiResult<MembershipEntitlement>> membership() => _client.membership();

  @override
  Future<ApiResult<MobileBillingTransactionPage>> transactions({
    String? cursor,
    int limit = 20,
  }) async {
    final result = await _client.transactions(cursor: cursor, limit: limit);
    final page = result.data;
    if (!result.ok || page == null) {
      return ApiResult<MobileBillingTransactionPage>.failure(
        error:
            result.error ??
            const AppFailure(
              code: 'BILLING_TRANSACTIONS_LOAD_FAILED',
              category: AppFailureCategory.api,
              message: 'Billing transaction response is unavailable',
              userMessageKey: 'billing.transactions.failed',
            ),
        status: result.status,
        traceId: result.traceId,
        authExpired: result.authExpired,
        retryAfterSeconds: result.retryAfterSeconds,
        idempotencyStore: result.idempotencyStore,
        responseHeaders: result.responseHeaders,
      );
    }
    try {
      return ApiResult<MobileBillingTransactionPage>.success(
        data: MobileBillingTransactionPage(
          items: List<MobileBillingTransaction>.unmodifiable(
            page.items.map(MobileBillingTransaction.fromContract),
          ),
          nextCursor: _optionalCursor(page.nextCursor),
        ),
        status: result.status ?? 200,
        traceId: result.traceId,
        idempotencyStore: result.idempotencyStore,
        responseHeaders: result.responseHeaders,
      );
    } on FormatException catch (error) {
      return ApiResult<MobileBillingTransactionPage>.failure(
        error: AppFailure(
          code: 'API_RESPONSE_INVALID',
          category: AppFailureCategory.api,
          message: 'Billing transaction response is invalid',
          userMessageKey: 'billing.transactions.invalid',
          cause: error,
        ),
        status: result.status,
        traceId: result.traceId,
        idempotencyStore: result.idempotencyStore,
        responseHeaders: result.responseHeaders,
      );
    }
  }
}

String _requiredValue(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw FormatException('$name must not be empty');
  return normalized;
}

String? _optionalCursor(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

const _billingSkus = <String>{'pro_30d', 'pro_365d', 'max_365d'};
