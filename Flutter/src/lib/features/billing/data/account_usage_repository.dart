// Public constructor names describe injected capabilities, not private fields.
// ignore_for_file: prefer_initializing_formals

import 'package:huahuo_api/account_usage.dart';
import 'package:huahuo_api/foundation.dart';
import 'package:huahuo_api/workspace.dart';

import '../domain/account_usage_repository.dart';

final class UnavailableAccountUsageRepository
    implements AccountUsageRepository {
  const UnavailableAccountUsageRepository({
    this.code = 'ACCOUNT_USAGE_AUTH_REQUIRED',
  });

  final String code;

  @override
  Future<MobileAccountUsageResult<List<MobileQuotaBalance>>>
  quotaBalances() async => MobileAccountUsageResult.unavailable(code);

  @override
  Future<MobileAccountUsageResult<MobileAccountCreditPage>> credits({
    String? cursor,
    int limit = 50,
  }) async =>
      MobileAccountUsageResult<MobileAccountCreditPage>.unavailable(code);

  @override
  Future<MobileAccountUsageResult<MobileAccountMembership>>
  membership() async =>
      MobileAccountUsageResult<MobileAccountMembership>.unavailable(code);

  @override
  Future<MobileAccountUsageResult<MobileRunUsage>> runUsage(
    String runId,
  ) async => MobileAccountUsageResult<MobileRunUsage>.unavailable(code);

  @override
  Future<MobileAccountUsageResult<MobileWorkspaceStorageUsage>>
  storageUsage() async =>
      MobileAccountUsageResult<MobileWorkspaceStorageUsage>.unavailable(code);
}

final class RemoteAccountUsageRepository implements AccountUsageRepository {
  RemoteAccountUsageRepository({
    required AccountUsageClient client,
    required WorkspaceLifecycleClient workspaceClient,
    required String? Function() workspaceId,
  }) : _client = client,
       _workspaceClient = workspaceClient,
       _workspaceId = workspaceId;

  final AccountUsageClient _client;
  final WorkspaceLifecycleClient _workspaceClient;
  final String? Function() _workspaceId;

  @override
  Future<MobileAccountUsageResult<List<MobileQuotaBalance>>>
  quotaBalances() async {
    try {
      final result = await _client.quotaBalances();
      final data = result.data;
      if (!result.ok || data == null) return _failure(result);
      return MobileAccountUsageResult.success(
        List<MobileQuotaBalance>.unmodifiable(
          data.map(
            (value) => MobileQuotaBalance(
              quotaType: value.quotaType,
              limit: value.limit,
              used: value.used,
              reserved: value.reserved,
              adjusted: value.adjusted,
              remaining: value.remaining,
              uncovered: value.uncovered,
              periodStart: value.periodStart,
              periodEnd: value.periodEnd,
            ),
          ),
        ),
      );
    } on FormatException {
      return const MobileAccountUsageResult.failure(
        'ACCOUNT_QUOTA_RESPONSE_INVALID',
      );
    } on Object {
      return const MobileAccountUsageResult.failure(
        'ACCOUNT_QUOTA_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileAccountUsageResult<MobileAccountMembership>> membership() async {
    try {
      final result = await _client.membershipDetail();
      final data = result.data;
      if (!result.ok || data == null) return _failure(result);
      return MobileAccountUsageResult<MobileAccountMembership>.success(
        _mapMembership(data),
      );
    } on FormatException {
      return const MobileAccountUsageResult<MobileAccountMembership>.failure(
        'ACCOUNT_MEMBERSHIP_RESPONSE_INVALID',
      );
    } on Object {
      return const MobileAccountUsageResult<MobileAccountMembership>.failure(
        'ACCOUNT_MEMBERSHIP_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileAccountUsageResult<MobileAccountCreditPage>> credits({
    String? cursor,
    int limit = 50,
  }) async {
    try {
      final result = await _client.creditSummary(cursor: cursor, limit: limit);
      final data = result.data;
      if (!result.ok || data == null) return _failure(result);
      return MobileAccountUsageResult<MobileAccountCreditPage>.success(
        _mapCredits(data),
      );
    } on ArgumentError {
      return const MobileAccountUsageResult<MobileAccountCreditPage>.failure(
        'ACCOUNT_CREDIT_REQUEST_INVALID',
      );
    } on FormatException {
      return const MobileAccountUsageResult<MobileAccountCreditPage>.failure(
        'ACCOUNT_CREDIT_RESPONSE_INVALID',
      );
    } on Object {
      return const MobileAccountUsageResult<MobileAccountCreditPage>.failure(
        'ACCOUNT_CREDIT_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileAccountUsageResult<MobileRunUsage>> runUsage(
    String runId,
  ) async {
    try {
      final result = await _client.runUsageDetail(runId);
      final data = result.data;
      if (!result.ok || data == null) return _failure(result);
      return MobileAccountUsageResult<MobileRunUsage>.success(
        _mapRunUsage(data),
      );
    } on ArgumentError {
      return const MobileAccountUsageResult<MobileRunUsage>.failure(
        'RUN_USAGE_ID_INVALID',
      );
    } on FormatException {
      return const MobileAccountUsageResult<MobileRunUsage>.failure(
        'RUN_USAGE_RESPONSE_INVALID',
      );
    } on Object {
      return const MobileAccountUsageResult<MobileRunUsage>.failure(
        'RUN_USAGE_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileAccountUsageResult<MobileWorkspaceStorageUsage>>
  storageUsage() async {
    final workspaceId = _workspaceId()?.trim();
    if (workspaceId == null || workspaceId.isEmpty) {
      return const MobileAccountUsageResult<
        MobileWorkspaceStorageUsage
      >.unavailable('WORKSPACE_CONTEXT_UNAVAILABLE');
    }
    try {
      final result = await _workspaceClient.storageUsage(workspaceId);
      final data = result.data;
      if (!result.ok || data == null) return _failure(result);
      return MobileAccountUsageResult<MobileWorkspaceStorageUsage>.success(
        MobileWorkspaceStorageUsage(
          userLogicalTotalBytes: data.userLogicalTotalBytes,
          limitBytes: data.limitBytes,
          remainingBytes: data.remainingBytes,
          fileCountLimit: data.fileCountLimit,
          measurementStatus: data.measurementStatus,
          currentContentBytes: data.currentContentBytes,
          retainedHistoryBytes: data.retainedHistoryBytes,
          resourceBytes: data.resourceBytes,
          logicalTotalBytes: data.logicalTotalBytes,
          formalProjectionBytes: data.formalProjectionBytes,
          unmeasuredObjectCount: data.unmeasuredObjectCount,
          calculatedAt: data.calculatedAt,
        ),
      );
    } on ArgumentError {
      return const MobileAccountUsageResult<
        MobileWorkspaceStorageUsage
      >.failure('WORKSPACE_STORAGE_REQUEST_INVALID');
    } on FormatException {
      return const MobileAccountUsageResult<
        MobileWorkspaceStorageUsage
      >.failure('WORKSPACE_STORAGE_RESPONSE_INVALID');
    } on Object {
      return const MobileAccountUsageResult<
        MobileWorkspaceStorageUsage
      >.failure('WORKSPACE_STORAGE_LOAD_FAILED');
    }
  }
}

MobileAccountMembership _mapMembership(SharedAccountMembershipResponse value) {
  return MobileAccountMembership(
    membershipId: value.membershipId,
    levelCode: value.levelCode,
    status: value.status,
    expiresAt: value.expiresAt,
    monthlyCredit: _monthlyPool(value.monthlyCredit),
    permanentCredit: MobileCreditPool(
      availableCredits: value.permanentCredit.availableCredits,
      reservedCredits: value.permanentCredit.reservedCredits,
    ),
    runAdmission: value.account.runAdmission,
    outstandingUncoveredCredits: value.account.outstandingUncoveredCredits,
  );
}

MobileAccountCreditPage _mapCredits(SharedAccountCreditSummary value) {
  return MobileAccountCreditPage(
    monthlyCredit: _monthlyPool(value.monthlyCredit),
    permanentCredit: MobileCreditPool(
      availableCredits: value.permanentCredit.availableCredits,
      reservedCredits: value.permanentCredit.reservedCredits,
    ),
    lots: List<MobilePermanentCreditLot>.unmodifiable(
      value.permanentCredit.lots.map(
        (lot) => MobilePermanentCreditLot(
          lotId: lot.lotId,
          originKind: lot.originKind,
          originalCredits: lot.originalCredits,
          availableCredits: lot.availableCredits,
          reservedCredits: lot.reservedCredits,
          createdAt: lot.createdAt,
        ),
      ),
    ),
    runAdmission: value.account.runAdmission,
    outstandingUncoveredCredits: value.account.outstandingUncoveredCredits,
    nextCursor: value.permanentCredit.nextCursor,
  );
}

MobileCreditPool _monthlyPool(SharedMonthlyCredit value) => MobileCreditPool(
  availableCredits: value.availableCredits,
  reservedCredits: value.reservedCredits,
  quotaCredits: value.quotaCredits,
  settledCredits: value.settledCredits,
  policyVersion: value.policyVersion,
  periodStart: value.periodStart,
  periodEnd: value.periodEnd,
  expiresAt: value.expiresAt,
);

MobileRunUsage _mapRunUsage(SharedRunUsage value) => MobileRunUsage(
  runId: value.runId,
  policyVersion: value.policyVersion,
  rawInputTokens: value.rawInputTokens,
  rawOutputTokens: value.rawOutputTokens,
  accountedCredits: value.accountedCredits,
  settlementStatus: value.settlementStatus,
  assistantResultPersisted: value.assistantResultPersisted,
  measurements: List<MobileRunUsageMeasurement>.unmodifiable(
    value.measurements.map(
      (measurement) => MobileRunUsageMeasurement(
        usageKind: measurement.usageKind,
        measurementStatus: measurement.measurementStatus,
        accountedCredits: measurement.accountedCredits,
        rawInputTokens: measurement.rawInputTokens,
        rawOutputTokens: measurement.rawOutputTokens,
        mediaQuantity: measurement.mediaQuantity,
        successfulAnalyzedImageCount: measurement.successfulAnalyzedImageCount,
        mediaDurationSeconds: measurement.mediaDurationSeconds,
      ),
    ),
  ),
);

MobileAccountUsageResult<T> _failure<T>(ApiResult<Object?> result) {
  final code = result.error?.code ?? 'ACCOUNT_USAGE_LOAD_FAILED';
  return code == 'API_BASE_URL_UNCONFIGURED' || code.endsWith('_UNAVAILABLE')
      ? MobileAccountUsageResult<T>.unavailable(code)
      : MobileAccountUsageResult<T>.failure(code);
}
