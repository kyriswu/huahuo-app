import 'account_usage_models.dart';

export 'account_usage_models.dart';

abstract interface class AccountUsageRepository {
  Future<MobileAccountUsageResult<MobileAccountMembership>> membership();

  Future<MobileAccountUsageResult<MobileAccountCreditPage>> credits({
    String? cursor,
    int limit = 50,
  });

  Future<MobileAccountUsageResult<MobileRunUsage>> runUsage(String runId);

  Future<MobileAccountUsageResult<MobileWorkspaceStorageUsage>> storageUsage();

  Future<MobileAccountUsageResult<List<MobileQuotaBalance>>> quotaBalances();
}
