import '../api/api_client.dart';
import '../api/idempotency.dart';

typedef AuthDataParser<T> = T? Function(Object? value);

/// Shared Auth endpoint orchestration.
///
/// Application facades retain ownership of request serialization, DTO parsing,
/// storage, and presentation-specific result mapping. This client deliberately
/// does not normalize caller bodies so deployed platform compatibility fields
/// remain byte-for-byte under each application's control.
final class AuthClient {
  const AuthClient(this._apiClient);

  final ApiClient _apiClient;

  Future<ApiResult<T>> requestSmsCode<T>({
    required String phone,
    required AuthDataParser<T> parseData,
    String scene = 'login',
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) {
    return _apiClient.request<T>(
      ApiRequestOptions<T>(
        endpointId: 'authSmsCode',
        body: <String, Object?>{'phone': phone, 'scene': scene},
        correlationId: correlationId,
        idempotency: idempotency,
        parseData: parseData,
      ),
    );
  }

  Future<ApiResult<T>> login<T>({
    required Map<String, Object?> body,
    required AuthDataParser<T> parseData,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) {
    return _apiClient.request<T>(
      ApiRequestOptions<T>(
        endpointId: 'authLogin',
        body: body,
        correlationId: correlationId,
        idempotency: idempotency,
        parseData: parseData,
      ),
    );
  }

  Future<ApiResult<T>> refresh<T>({
    required String refreshToken,
    required AuthDataParser<T> parseData,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) {
    return _apiClient.request<T>(
      ApiRequestOptions<T>(
        endpointId: 'authRefresh',
        body: <String, Object?>{'refreshToken': refreshToken},
        correlationId: correlationId,
        idempotency: idempotency,
        parseData: parseData,
      ),
    );
  }

  Future<ApiResult<T>> getUserStatus<T>({
    required AuthDataParser<T> parseData,
    String? accessToken,
    String? correlationId,
  }) {
    return _apiClient.request<T>(
      ApiRequestOptions<T>(
        endpointId: 'meStatus',
        accessTokenOverride: accessToken,
        correlationId: correlationId,
        parseData: parseData,
      ),
    );
  }

  Future<ApiResult<T>> updateUserTimeZone<T>({
    required String timeZone,
    required String accessToken,
    required AuthDataParser<T> parseData,
    String? correlationId,
    IdempotencyRequestContext? idempotency,
  }) {
    return _apiClient.request<T>(
      ApiRequestOptions<T>(
        endpointId: 'updateMeTimezone',
        body: <String, Object?>{'timeZone': timeZone},
        accessTokenOverride: accessToken,
        correlationId: correlationId,
        idempotency: idempotency,
        parseData: parseData,
      ),
    );
  }
}
