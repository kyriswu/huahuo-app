import 'package:huahuo_api/huahuo_api.dart';
import '../domain/notification_models.dart';
import '../domain/push_registration.dart';

abstract interface class PushDeviceApiPort {
  Future<ApiResult<PushDeviceMutationReceipt>> registerDevice({
    required PushDeviceRegistration registration,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore,
  });

  Future<ApiResult<PushDeviceMutationReceipt>> unregisterDevice({
    required String deviceId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore,
  });
}

final class PushDeviceApi implements PushDeviceApiPort {
  const PushDeviceApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<ApiResult<PushDeviceMutationReceipt>> registerDevice({
    required PushDeviceRegistration registration,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (!registration.isValid) {
      return Future<ApiResult<PushDeviceMutationReceipt>>.value(
        _invalid('PUSH_DEVICE_REGISTRATION_INVALID', idempotencyStore),
      );
    }
    return _apiClient.request<PushDeviceMutationReceipt>(
      ApiRequestOptions<PushDeviceMutationReceipt>(
        endpointId: 'registerNotificationDevice',
        body: registration.toJson(),
        idempotency: idempotency,
        idempotencyStore: idempotencyStore,
        parseData: (value) => _parseReceipt(
          value,
          expectedDeviceId: registration.deviceId,
          expectedStatus: 'active',
        ),
      ),
    );
  }

  @override
  Future<ApiResult<PushDeviceMutationReceipt>> unregisterDevice({
    required String deviceId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (!isSafeNotificationIdentifier(deviceId)) {
      return Future<ApiResult<PushDeviceMutationReceipt>>.value(
        _invalid('PUSH_DEVICE_ID_INVALID', idempotencyStore),
      );
    }
    return _apiClient.request<PushDeviceMutationReceipt>(
      ApiRequestOptions<PushDeviceMutationReceipt>(
        endpointId: 'unregisterNotificationDevice',
        pathParams: <String, Object>{'deviceId': deviceId},
        idempotency: idempotency,
        idempotencyStore: idempotencyStore,
        parseData: (value) => _parseReceipt(
          value,
          expectedDeviceId: deviceId,
          expectedStatus: 'revoked',
        ),
      ),
    );
  }
}

final class UnavailablePushDeviceApi implements PushDeviceApiPort {
  const UnavailablePushDeviceApi();

  @override
  Future<ApiResult<PushDeviceMutationReceipt>> registerDevice({
    required PushDeviceRegistration registration,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => _unavailable(idempotencyStore);

  @override
  Future<ApiResult<PushDeviceMutationReceipt>> unregisterDevice({
    required String deviceId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => _unavailable(idempotencyStore);
}

PushDeviceMutationReceipt? _parseReceipt(
  Object? value, {
  required String expectedDeviceId,
  required String expectedStatus,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final receipt = PushDeviceMutationReceipt.fromJson(object);
  if (receipt.deviceId != expectedDeviceId ||
      receipt.status != expectedStatus) {
    throw const FormatException('Push device receipt does not match request');
  }
  return receipt;
}

ApiResult<PushDeviceMutationReceipt> _invalid(
  String code,
  SubmissionKeyStore store,
) => ApiResult<PushDeviceMutationReceipt>.failure(
  error: AppFailure(
    code: code,
    category: AppFailureCategory.api,
    message: 'Push device request is invalid',
    userMessageKey: 'push.$code',
  ),
  idempotencyStore: store,
);

ApiResult<PushDeviceMutationReceipt> _unavailable(SubmissionKeyStore store) =>
    ApiResult<PushDeviceMutationReceipt>.failure(
      error: const AppFailure(
        code: 'PUSH_DEVICE_SERVICE_NOT_READY',
        category: AppFailureCategory.compatibility,
        message: 'Push device service is not ready',
        userMessageKey: 'push.serviceNotReady',
        isRetryable: true,
        recoveryActions: <String>['retry'],
      ),
      idempotencyStore: store,
    );
