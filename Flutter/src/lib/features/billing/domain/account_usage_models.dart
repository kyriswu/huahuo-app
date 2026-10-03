enum MobileAccountUsageResultStatus { success, unavailable, failure }

final class MobileCreditPool {
  const MobileCreditPool({
    required this.availableCredits,
    required this.reservedCredits,
    this.quotaCredits,
    this.settledCredits,
    this.policyVersion,
    this.periodStart,
    this.periodEnd,
    this.expiresAt,
  });

  final int availableCredits;
  final int reservedCredits;
  final int? quotaCredits;
  final int? settledCredits;
  final String? policyVersion;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final DateTime? expiresAt;
}

final class MobileAccountMembership {
  const MobileAccountMembership({
    required this.membershipId,
    required this.levelCode,
    required this.status,
    required this.expiresAt,
    required this.monthlyCredit,
    required this.permanentCredit,
    required this.runAdmission,
    required this.outstandingUncoveredCredits,
  });

  final String membershipId;
  final String levelCode;
  final String status;
  final DateTime? expiresAt;
  final MobileCreditPool monthlyCredit;
  final MobileCreditPool permanentCredit;
  final String runAdmission;
  final int outstandingUncoveredCredits;
}

final class MobilePermanentCreditLot {
  const MobilePermanentCreditLot({
    required this.lotId,
    required this.originKind,
    required this.originalCredits,
    required this.availableCredits,
    required this.reservedCredits,
    required this.createdAt,
  });

  final String lotId;
  final String originKind;
  final int originalCredits;
  final int availableCredits;
  final int reservedCredits;
  final DateTime createdAt;
}

final class MobileAccountCreditPage {
  const MobileAccountCreditPage({
    required this.monthlyCredit,
    required this.permanentCredit,
    required this.lots,
    required this.runAdmission,
    required this.outstandingUncoveredCredits,
    this.nextCursor,
  });

  final MobileCreditPool monthlyCredit;
  final MobileCreditPool permanentCredit;
  final List<MobilePermanentCreditLot> lots;
  final String runAdmission;
  final int outstandingUncoveredCredits;
  final String? nextCursor;
}

final class MobileWorkspaceStorageUsage {
  const MobileWorkspaceStorageUsage({
    required this.userLogicalTotalBytes,
    required this.limitBytes,
    required this.remainingBytes,
    required this.fileCountLimit,
    required this.measurementStatus,
    this.currentContentBytes,
    this.retainedHistoryBytes,
    this.resourceBytes,
    this.logicalTotalBytes,
    this.formalProjectionBytes,
    this.unmeasuredObjectCount,
    this.calculatedAt,
  });

  final int userLogicalTotalBytes;
  final int limitBytes;
  final int remainingBytes;
  final int? fileCountLimit;
  final String measurementStatus;
  final int? currentContentBytes;
  final int? retainedHistoryBytes;
  final int? resourceBytes;
  final int? logicalTotalBytes;
  final int? formalProjectionBytes;
  final int? unmeasuredObjectCount;
  final DateTime? calculatedAt;
}

final class MobileQuotaBalance {
  const MobileQuotaBalance({
    required this.quotaType,
    required this.limit,
    required this.used,
    required this.reserved,
    required this.adjusted,
    required this.remaining,
    required this.uncovered,
    this.periodStart,
    this.periodEnd,
  });

  final String quotaType;
  final num limit;
  final num used;
  final num reserved;
  final num adjusted;
  final num remaining;
  final num uncovered;
  final DateTime? periodStart;
  final DateTime? periodEnd;

  num get effectiveLimit => limit + adjusted;
}

final class MobileRunUsageMeasurement {
  const MobileRunUsageMeasurement({
    required this.usageKind,
    required this.measurementStatus,
    required this.accountedCredits,
    this.rawInputTokens,
    this.rawOutputTokens,
    this.mediaQuantity,
    this.successfulAnalyzedImageCount,
    this.mediaDurationSeconds,
  });

  final String usageKind;
  final String measurementStatus;
  final int accountedCredits;
  final int? rawInputTokens;
  final int? rawOutputTokens;
  final int? mediaQuantity;
  final int? successfulAnalyzedImageCount;
  final num? mediaDurationSeconds;
}

final class MobileRunUsage {
  const MobileRunUsage({
    required this.runId,
    required this.policyVersion,
    required this.rawInputTokens,
    required this.rawOutputTokens,
    required this.accountedCredits,
    required this.settlementStatus,
    required this.assistantResultPersisted,
    required this.measurements,
  });

  final String runId;
  final String policyVersion;
  final int rawInputTokens;
  final int rawOutputTokens;
  final int accountedCredits;
  final String settlementStatus;
  final bool assistantResultPersisted;
  final List<MobileRunUsageMeasurement> measurements;
}

final class MobileAccountUsageResult<T> {
  const MobileAccountUsageResult._({
    required this.status,
    this.data,
    this.errorCode,
  });

  const MobileAccountUsageResult.success(T data)
    : this._(status: MobileAccountUsageResultStatus.success, data: data);

  const MobileAccountUsageResult.unavailable(String errorCode)
    : this._(
        status: MobileAccountUsageResultStatus.unavailable,
        errorCode: errorCode,
      );

  const MobileAccountUsageResult.failure(String errorCode)
    : this._(
        status: MobileAccountUsageResultStatus.failure,
        errorCode: errorCode,
      );

  final MobileAccountUsageResultStatus status;
  final T? data;
  final String? errorCode;
}
