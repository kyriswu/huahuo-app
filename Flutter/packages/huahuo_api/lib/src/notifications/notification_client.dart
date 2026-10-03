import '../api/api_client.dart';
import '../api/idempotency.dart';

typedef NotificationDataParser<T> = T? Function(Object? value);

/// Shared transport for the public notification inbox.
///
/// Application facades retain DTO validation and local resolution policy so
/// platform cache schemas and Push integrations remain independent.
final class NotificationClient {
  const NotificationClient(this._apiClient);

  final ApiClient _apiClient;

  Future<ApiResult<T>> list<T>({
    required NotificationDataParser<T> parseData,
    String? cursor,
    int? limit,
  }) => _apiClient.request<T>(
    ApiRequestOptions<T>(
      endpointId: 'notifications',
      query: <String, Object?>{
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
      parseData: parseData,
    ),
  );

  Future<ApiResult<T>> markRead<T>({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    required NotificationDataParser<T> parseData,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) => _apiClient.request<T>(
    ApiRequestOptions<T>(
      endpointId: 'markNotificationRead',
      pathParams: <String, Object>{'notificationId': notificationId},
      body: const <String, Object?>{},
      idempotency: idempotency,
      idempotencyStore: idempotencyStore,
      parseData: parseData,
    ),
  );
}
