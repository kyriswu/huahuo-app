import '../contracts/json_readers.dart';

final class SharedMonthlyCredit {
  const SharedMonthlyCredit({
    required this.policyVersion,
    required this.quotaCredits,
    required this.periodStart,
    required this.periodEnd,
    required this.availableCredits,
    required this.reservedCredits,
    required this.settledCredits,
    required this.expiresAt,
  });

  factory SharedMonthlyCredit.fromJson(Map<String, Object?> json) {
    final policyVersion = requiredString(json, 'policyVersion');
    if (policyVersion != 'credit-policy-v1') {
      throw FormatException('unsupported credit policy: $policyVersion');
    }
    final quotaCredits = requiredNonNegativeInt(json, 'quotaCredits');
    if (quotaCredits != 10000000) {
      throw FormatException('unsupported monthly quota: $quotaCredits');
    }
    return SharedMonthlyCredit(
      policyVersion: policyVersion,
      quotaCredits: quotaCredits,
      periodStart: requiredDateTime(json, 'periodStart'),
      periodEnd: requiredDateTime(json, 'periodEnd'),
      availableCredits: requiredNonNegativeInt(json, 'availableCredits'),
      reservedCredits: requiredNonNegativeInt(json, 'reservedCredits'),
      settledCredits: requiredNonNegativeInt(json, 'settledCredits'),
      expiresAt: requiredDateTime(json, 'expiresAt'),
    );
  }

  final String policyVersion;
  final int quotaCredits;
  final DateTime periodStart;
  final DateTime periodEnd;
  final int availableCredits;
  final int reservedCredits;
  final int settledCredits;
  final DateTime expiresAt;
}

final class SharedPermanentCredit {
  const SharedPermanentCredit({
    required this.availableCredits,
    required this.reservedCredits,
  });

  factory SharedPermanentCredit.fromJson(Map<String, Object?> json) =>
      SharedPermanentCredit(
        availableCredits: requiredNonNegativeInt(json, 'availableCredits'),
        reservedCredits: requiredNonNegativeInt(json, 'reservedCredits'),
      );

  final int availableCredits;
  final int reservedCredits;
}

final class SharedAccountAdmission {
  const SharedAccountAdmission({
    required this.runAdmission,
    required this.outstandingUncoveredCredits,
  });

  factory SharedAccountAdmission.fromJson(Map<String, Object?> json) {
    final runAdmission = requiredString(json, 'runAdmission');
    if (!_runAdmissions.contains(runAdmission)) {
      throw FormatException('unsupported runAdmission: $runAdmission');
    }
    return SharedAccountAdmission(
      runAdmission: runAdmission,
      outstandingUncoveredCredits: requiredNonNegativeInt(
        json,
        'outstandingUncoveredCredits',
      ),
    );
  }

  final String runAdmission;
  final int outstandingUncoveredCredits;
}

final class SharedAccountMembershipResponse {
  const SharedAccountMembershipResponse({
    required this.membershipId,
    required this.levelCode,
    required this.status,
    required this.expiresAt,
    required this.monthlyCredit,
    required this.permanentCredit,
    required this.account,
  });

  factory SharedAccountMembershipResponse.fromJson(Map<String, Object?> json) {
    final membership = requiredObject(json, 'membership');
    final levelCode = requiredString(membership, 'levelCode');
    final status = requiredString(membership, 'status');
    if (!_accountMembershipLevels.contains(levelCode) ||
        !_accountMembershipStatuses.contains(status)) {
      throw FormatException('unsupported membership: $levelCode/$status');
    }
    if (!membership.containsKey('expiresAt')) {
      throw const FormatException('membership.expiresAt must be present');
    }
    final expiresAt = membership['expiresAt'] == null
        ? null
        : requiredDateTime(membership, 'expiresAt');
    if ((levelCode == 'free' || levelCode == 'pilot_paid') &&
        expiresAt != null) {
      throw FormatException('$levelCode membership must not expire');
    }
    if ((levelCode == 'pro' || levelCode == 'max') && expiresAt == null) {
      throw FormatException('$levelCode membership requires expiresAt');
    }
    return SharedAccountMembershipResponse(
      membershipId: requiredString(membership, 'membershipId'),
      levelCode: levelCode,
      status: status,
      expiresAt: expiresAt,
      monthlyCredit: SharedMonthlyCredit.fromJson(
        requiredObject(json, 'monthlyCredit'),
      ),
      permanentCredit: SharedPermanentCredit.fromJson(
        requiredObject(json, 'permanentCredit'),
      ),
      account: SharedAccountAdmission.fromJson(requiredObject(json, 'account')),
    );
  }

  final String membershipId;
  final String levelCode;
  final String status;
  final DateTime? expiresAt;
  final SharedMonthlyCredit monthlyCredit;
  final SharedPermanentCredit permanentCredit;
  final SharedAccountAdmission account;
}

final class SharedPermanentCreditLot {
  const SharedPermanentCreditLot({
    required this.lotId,
    required this.originKind,
    required this.originalCredits,
    required this.availableCredits,
    required this.reservedCredits,
    required this.createdAt,
    required this.expiresAt,
  });

  factory SharedPermanentCreditLot.fromJson(Map<String, Object?> json) {
    final originKind = requiredString(json, 'originKind');
    if (!_creditOriginKinds.contains(originKind)) {
      throw FormatException('unsupported credit originKind: $originKind');
    }
    requireNull(json, 'expiresAt');
    return SharedPermanentCreditLot(
      lotId: requiredString(json, 'lotId'),
      originKind: originKind,
      originalCredits: requiredNonNegativeInt(json, 'originalCredits'),
      availableCredits: requiredNonNegativeInt(json, 'availableCredits'),
      reservedCredits: requiredNonNegativeInt(json, 'reservedCredits'),
      createdAt: requiredDateTime(json, 'createdAt'),
      expiresAt: null,
    );
  }

  final String lotId;
  final String originKind;
  final int originalCredits;
  final int availableCredits;
  final int reservedCredits;
  final DateTime createdAt;
  final DateTime? expiresAt;
}

final class SharedPermanentCreditPage {
  const SharedPermanentCreditPage({
    required this.availableCredits,
    required this.reservedCredits,
    required this.lots,
    this.nextCursor,
  });

  factory SharedPermanentCreditPage.fromJson(Map<String, Object?> json) =>
      SharedPermanentCreditPage(
        availableCredits: requiredNonNegativeInt(json, 'availableCredits'),
        reservedCredits: requiredNonNegativeInt(json, 'reservedCredits'),
        lots: requiredObjectList(
          json,
          'lots',
        ).map(SharedPermanentCreditLot.fromJson).toList(growable: false),
        nextCursor: optionalString(json, 'nextCursor'),
      );

  final int availableCredits;
  final int reservedCredits;
  final List<SharedPermanentCreditLot> lots;
  final String? nextCursor;
}

final class SharedAccountCreditSummary {
  const SharedAccountCreditSummary({
    required this.monthlyCredit,
    required this.permanentCredit,
    required this.account,
  });

  factory SharedAccountCreditSummary.fromJson(Map<String, Object?> json) =>
      SharedAccountCreditSummary(
        monthlyCredit: SharedMonthlyCredit.fromJson(
          requiredObject(json, 'monthlyCredit'),
        ),
        permanentCredit: SharedPermanentCreditPage.fromJson(
          requiredObject(json, 'permanentCredit'),
        ),
        account: SharedAccountAdmission.fromJson(
          requiredObject(json, 'account'),
        ),
      );

  final SharedMonthlyCredit monthlyCredit;
  final SharedPermanentCreditPage permanentCredit;
  final SharedAccountAdmission account;
}

final class SharedProviderCost {
  const SharedProviderCost({required this.amount, required this.currency});

  factory SharedProviderCost.fromJson(Map<String, Object?> json) {
    final amount = requiredString(json, 'amount');
    if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(amount)) {
      throw FormatException('provider amount must be a non-negative decimal');
    }
    return SharedProviderCost(
      amount: amount,
      currency: requiredString(json, 'currency'),
    );
  }

  final String amount;
  final String currency;
}

final class SharedRunUsageMeasurement {
  const SharedRunUsageMeasurement({
    required this.usageKind,
    required this.measurementStatus,
    required this.accountedCredits,
    this.rawInputTokens,
    this.rawOutputTokens,
    this.mediaQuantity,
    this.successfulAnalyzedImageCount,
    this.mediaDurationSeconds,
    this.providerCost,
  });

  factory SharedRunUsageMeasurement.fromJson(Map<String, Object?> json) {
    final usageKind = requiredString(json, 'usageKind');
    final measurementStatus = requiredString(json, 'measurementStatus');
    if (!_usageKinds.contains(usageKind) ||
        !_measurementStatuses.contains(measurementStatus)) {
      throw FormatException(
        'unsupported usage measurement: $usageKind/$measurementStatus',
      );
    }
    return SharedRunUsageMeasurement(
      usageKind: usageKind,
      rawInputTokens: optionalNonNegativeInt(json, 'rawInputTokens'),
      rawOutputTokens: optionalNonNegativeInt(json, 'rawOutputTokens'),
      mediaQuantity: optionalNonNegativeInt(json, 'mediaQuantity'),
      successfulAnalyzedImageCount: optionalNonNegativeInt(
        json,
        'successfulAnalyzedImageCount',
      ),
      mediaDurationSeconds: optionalNonNegativeNumber(
        json,
        'mediaDurationSeconds',
      ),
      providerCost: json['providerCost'] == null
          ? null
          : SharedProviderCost.fromJson(requiredObject(json, 'providerCost')),
      measurementStatus: measurementStatus,
      accountedCredits: requiredNonNegativeInt(json, 'accountedCredits'),
    );
  }

  final String usageKind;
  final int? rawInputTokens;
  final int? rawOutputTokens;
  final int? mediaQuantity;
  final int? successfulAnalyzedImageCount;
  final double? mediaDurationSeconds;
  final SharedProviderCost? providerCost;
  final String measurementStatus;
  final int accountedCredits;
}

final class SharedRunUsage {
  const SharedRunUsage({
    required this.runId,
    required this.policyVersion,
    required this.rawInputTokens,
    required this.rawOutputTokens,
    required this.accountedCredits,
    required this.settlementStatus,
    required this.assistantResultPersisted,
    required this.measurements,
  });

  factory SharedRunUsage.fromJson(Map<String, Object?> json) {
    final policyVersion = requiredString(json, 'policyVersion');
    final settlementStatus = requiredString(json, 'settlementStatus');
    if (policyVersion != 'credit-policy-v1' ||
        !_settlementStatuses.contains(settlementStatus)) {
      throw FormatException(
        'unsupported Run usage policy/status: $policyVersion/$settlementStatus',
      );
    }
    return SharedRunUsage(
      runId: requiredString(json, 'runId'),
      policyVersion: policyVersion,
      rawInputTokens: requiredNonNegativeInt(json, 'rawInputTokens'),
      rawOutputTokens: requiredNonNegativeInt(json, 'rawOutputTokens'),
      accountedCredits: requiredNonNegativeInt(json, 'accountedCredits'),
      settlementStatus: settlementStatus,
      assistantResultPersisted: requiredBool(json, 'assistantResultPersisted'),
      measurements: requiredObjectList(
        json,
        'measurements',
      ).map(SharedRunUsageMeasurement.fromJson).toList(growable: false),
    );
  }

  final String runId;
  final String policyVersion;
  final int rawInputTokens;
  final int rawOutputTokens;
  final int accountedCredits;
  final String settlementStatus;
  final bool assistantResultPersisted;
  final List<SharedRunUsageMeasurement> measurements;
}

const _runAdmissions = <String>{'allowed', 'blocked_uncovered_credit'};
const _accountMembershipLevels = <String>{'free', 'pilot_paid', 'pro', 'max'};
const _accountMembershipStatuses = <String>{
  'pending',
  'active',
  'grace_period',
  'cancelled',
  'expired',
  'refunded',
  'revoked',
};
const _creditOriginKinds = <String>{
  'admin_grant',
  'admin_adjustment',
  'migration',
  'future_catalog',
};
const _usageKinds = <String>{
  'text_input',
  'text_output',
  'image_analysis',
  'video_analysis',
  'generated_image',
  'embedding',
};
const _measurementStatuses = <String>{
  'measured',
  'fallback',
  'zero_cost',
  'unavailable',
};
const _settlementStatuses = <String>{'pending', 'settled', 'uncovered'};
