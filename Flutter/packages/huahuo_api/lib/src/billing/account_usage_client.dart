import '../api/api_client.dart';
import '../api/api_contract_object.dart';
import '../api/request_parsing.dart';
import 'account_usage_models.dart';
import 'account_quota_balance.dart';

final class AccountUsageClient {
  const AccountUsageClient(this._api);

  final ApiClient _api;

  Future<ApiResult<List<AccountQuotaBalance>>> quotaBalances() =>
      _api.request<List<AccountQuotaBalance>>(
        ApiRequestOptions<List<AccountQuotaBalance>>(
          endpointId: 'home',
          parseData: parseAccountQuotaBalances,
        ),
      );

  Future<ApiResult<ApiContractObject>> membership() => _get('membership');

  Future<ApiResult<ApiContractObject>> credits() => _get('accountCredits');

  Future<ApiResult<ApiContractObject>> runUsage(String runId) =>
      _api.request<ApiContractObject>(
        ApiRequestOptions<ApiContractObject>(
          endpointId: 'runUsage',
          pathParams: <String, Object>{'runId': runId},
          parseData: parseApiObject,
        ),
      );

  Future<ApiResult<SharedAccountMembershipResponse>> membershipDetail() =>
      _api.request<SharedAccountMembershipResponse>(
        ApiRequestOptions<SharedAccountMembershipResponse>(
          endpointId: 'membership',
          parseData: (value) =>
              parseJsonModel(value, SharedAccountMembershipResponse.fromJson),
        ),
      );

  Future<ApiResult<SharedAccountCreditSummary>> creditSummary({
    String? cursor,
    int? limit,
  }) => _api.request<SharedAccountCreditSummary>(
    ApiRequestOptions<SharedAccountCreditSummary>(
      endpointId: 'accountCredits',
      query: <String, Object?>{
        'cursor': cursor,
        if (limit != null) 'limit': boundedPageLimit(limit),
      },
      parseData: (value) =>
          parseJsonModel(value, SharedAccountCreditSummary.fromJson),
    ),
  );

  Future<ApiResult<SharedRunUsage>> runUsageDetail(String runId) =>
      _api.request<SharedRunUsage>(
        ApiRequestOptions<SharedRunUsage>(
          endpointId: 'runUsage',
          pathParams: <String, Object>{
            'runId': requiredClientText(runId, 'runId'),
          },
          parseData: (value) => parseJsonModel(value, SharedRunUsage.fromJson),
        ),
      );

  Future<ApiResult<ApiContractObject>> _get(String endpointId) =>
      _api.request<ApiContractObject>(
        ApiRequestOptions<ApiContractObject>(
          endpointId: endpointId,
          parseData: parseApiObject,
        ),
      );
}
