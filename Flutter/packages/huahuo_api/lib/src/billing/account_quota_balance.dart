import '../api/api_envelope.dart';

final class AccountQuotaBalance {
  const AccountQuotaBalance({
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

  factory AccountQuotaBalance.fromJson(Map<String, Object?> json) {
    num amount(String key, {bool signed = false}) {
      final value = json[key];
      if (value is! num || !value.isFinite || (!signed && value < 0)) {
        throw FormatException('Invalid quota $key');
      }
      return value;
    }

    DateTime? date(String key) {
      final value = json[key];
      if (value == null) return null;
      final parsed = value is String ? DateTime.tryParse(value) : null;
      if (parsed == null) throw FormatException('Invalid quota $key');
      return parsed;
    }

    final type = json['quotaType'];
    if (type is! String || type.trim().isEmpty) {
      throw const FormatException('Missing quota type');
    }
    return AccountQuotaBalance(
      quotaType: type,
      limit: amount('limitAmount'),
      used: amount('usedAmount'),
      reserved: amount('reservedAmount'),
      adjusted: amount('adjustedAmount', signed: true),
      remaining: amount('remainingAmount'),
      uncovered: amount('uncoveredAmount'),
      periodStart: date('periodStart'),
      periodEnd: date('periodEnd'),
    );
  }

  final String quotaType;
  final num limit;
  final num used;
  final num reserved;
  final num adjusted;
  final num remaining;
  final num uncovered;
  final DateTime? periodStart;
  final DateTime? periodEnd;
}

List<AccountQuotaBalance> parseAccountQuotaBalances(Object? value) {
  final object = asObjectMap(value);
  final quota = asObjectMap(object?['quotaSummary']);
  final balances = quota?['balances'];
  if (balances is! List || balances.isEmpty) {
    throw const FormatException('Missing quota balances');
  }
  final types = <String>{};
  return List<AccountQuotaBalance>.unmodifiable(
    balances.map((value) {
      final json = asObjectMap(value);
      if (json == null) {
        throw const FormatException('Invalid quota balance');
      }
      final balance = AccountQuotaBalance.fromJson(json);
      if (!types.add(balance.quotaType)) {
        throw const FormatException('Duplicate quota balance');
      }
      return balance;
    }),
  );
}
