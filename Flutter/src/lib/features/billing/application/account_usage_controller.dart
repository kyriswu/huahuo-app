// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../domain/account_usage_repository.dart';

enum AccountUsageStatus { idle, loading, ready, partial, unavailable, failure }

final class AccountUsageController extends ChangeNotifier {
  AccountUsageController({required AccountUsageRepository repository})
    : _repository = repository;

  final AccountUsageRepository _repository;
  final List<MobilePermanentCreditLot> _creditLots =
      <MobilePermanentCreditLot>[];
  final Set<String> _seenCreditCursors = <String>{};
  final Map<String, MobileRunUsage> _runUsages = <String, MobileRunUsage>{};
  final Map<String, String> _runUsageErrors = <String, String>{};
  final Set<String> _runUsageInFlight = <String>{};
  bool _creditPageInFlight = false;
  AccountUsageStatus _status = AccountUsageStatus.idle;
  MobileAccountMembership? _membership;
  MobileAccountCreditPage? _creditSummary;
  MobileWorkspaceStorageUsage? _storageUsage;
  String? _nextCreditCursor;
  String? _membershipErrorCode;
  String? _creditErrorCode;
  String? _storageErrorCode;
  bool _disposed = false;
  Future<void>? _loadInFlight;
  int _creditRevision = 0;
  List<MobileQuotaBalance>? _quotaBalances;
  String? _quotaErrorCode;
  DateTime? _updatedAt;

  AccountUsageStatus get status => _status;
  MobileAccountMembership? get membership => _membership;
  MobileAccountCreditPage? get creditSummary => _creditSummary;
  MobileWorkspaceStorageUsage? get storageUsage => _storageUsage;
  List<MobilePermanentCreditLot> get creditLots =>
      List<MobilePermanentCreditLot>.unmodifiable(_creditLots);
  String? get membershipErrorCode => _membershipErrorCode;
  String? get creditErrorCode => _creditErrorCode;
  String? get storageErrorCode => _storageErrorCode;
  bool get hasMoreCredits => _nextCreditCursor != null;
  bool get loading => _status == AccountUsageStatus.loading;
  List<MobileQuotaBalance>? get quotaBalances => _quotaBalances;
  String? get quotaErrorCode => _quotaErrorCode;
  DateTime? get updatedAt => _updatedAt;
  bool get loadingMoreCredits => _creditPageInFlight;

  MobileRunUsage? runUsageFor(String runId) => _runUsages[runId.trim()];
  String? runUsageErrorFor(String runId) => _runUsageErrors[runId.trim()];
  bool isRunUsageLoading(String runId) =>
      _runUsageInFlight.contains(runId.trim());

  Future<void> load() {
    if (_disposed) return Future<void>.value();
    return _loadInFlight ??= _load().whenComplete(() => _loadInFlight = null);
  }

  Future<void> _load() async {
    _creditRevision += 1;
    _status = AccountUsageStatus.loading;
    notifyListeners();
    final results = await Future.wait<Object>(<Future<Object>>[
      _loadMembership(),
      _loadCredits(),
      _loadStorageUsage(),
      _loadQuotaBalances(),
    ]);
    if (_disposed) return;
    final membershipResult =
        results[0] as MobileAccountUsageResult<MobileAccountMembership>;
    final creditResult =
        results[1] as MobileAccountUsageResult<MobileAccountCreditPage>;
    final storageResult =
        results[2] as MobileAccountUsageResult<MobileWorkspaceStorageUsage>;
    final quotaResult =
        results[3] as MobileAccountUsageResult<List<MobileQuotaBalance>>;
    _membershipErrorCode = null;
    _creditErrorCode = null;
    _storageErrorCode = null;
    _quotaErrorCode = null;
    if (membershipResult.status == MobileAccountUsageResultStatus.success &&
        membershipResult.data != null) {
      _membership = membershipResult.data;
    } else {
      _membershipErrorCode =
          membershipResult.errorCode ?? 'ACCOUNT_MEMBERSHIP_LOAD_FAILED';
    }
    if (creditResult.status == MobileAccountUsageResultStatus.success &&
        creditResult.data != null) {
      _applyCreditPage(creditResult.data!, reset: true);
    } else {
      _creditErrorCode = creditResult.errorCode ?? 'ACCOUNT_CREDIT_LOAD_FAILED';
    }
    if (storageResult.status == MobileAccountUsageResultStatus.success &&
        storageResult.data != null) {
      _storageUsage = storageResult.data;
    } else {
      _storageErrorCode =
          storageResult.errorCode ?? 'WORKSPACE_STORAGE_LOAD_FAILED';
    }
    if (quotaResult.status == MobileAccountUsageResultStatus.success &&
        quotaResult.data != null) {
      _quotaBalances = List.unmodifiable(quotaResult.data!);
    } else {
      _quotaErrorCode = quotaResult.errorCode ?? 'ACCOUNT_QUOTA_LOAD_FAILED';
    }
    final successCount = <bool>[
      _membershipErrorCode == null,
      _creditErrorCode == null,
      _storageErrorCode == null,
      _quotaErrorCode == null,
    ].where((success) => success).length;
    if (successCount > 0) _updatedAt = DateTime.now();
    if (successCount == 4) {
      _status = AccountUsageStatus.ready;
    } else if (successCount > 0) {
      _status = AccountUsageStatus.partial;
    } else {
      final unavailable =
          membershipResult.status ==
              MobileAccountUsageResultStatus.unavailable &&
          creditResult.status == MobileAccountUsageResultStatus.unavailable &&
          storageResult.status == MobileAccountUsageResultStatus.unavailable &&
          quotaResult.status == MobileAccountUsageResultStatus.unavailable;
      _status = unavailable
          ? AccountUsageStatus.unavailable
          : AccountUsageStatus.failure;
    }
    notifyListeners();
  }

  Future<void> loadMoreCredits() async {
    final cursor = _nextCreditCursor;
    if (cursor == null ||
        _status == AccountUsageStatus.loading ||
        _creditPageInFlight) {
      return;
    }
    _creditPageInFlight = true;
    final revision = _creditRevision;
    notifyListeners();
    MobileAccountUsageResult<MobileAccountCreditPage> result;
    try {
      result = await _repository.credits(cursor: cursor, limit: 50);
    } on Object {
      result = const MobileAccountUsageResult<MobileAccountCreditPage>.failure(
        'ACCOUNT_CREDIT_LOAD_FAILED',
      );
    } finally {
      _creditPageInFlight = false;
    }
    if (_disposed) return;
    if (revision != _creditRevision) {
      notifyListeners();
      return;
    }
    final page = result.data;
    if (result.status != MobileAccountUsageResultStatus.success ||
        page == null) {
      _creditErrorCode = result.errorCode ?? 'ACCOUNT_CREDIT_LOAD_FAILED';
      notifyListeners();
      return;
    }
    _creditErrorCode = null;
    _applyCreditPage(page, reset: false);
    notifyListeners();
  }

  Future<MobileAccountUsageResult<MobileRunUsage>> loadRunUsage(
    String runId,
  ) async {
    final normalized = runId.trim();
    if (normalized.isEmpty) {
      return const MobileAccountUsageResult<MobileRunUsage>.failure(
        'RUN_USAGE_ID_INVALID',
      );
    }
    if (!_runUsageInFlight.add(normalized)) {
      return const MobileAccountUsageResult<MobileRunUsage>.failure(
        'RUN_USAGE_REQUEST_IN_PROGRESS',
      );
    }
    notifyListeners();
    MobileAccountUsageResult<MobileRunUsage> result;
    try {
      result = await _repository.runUsage(normalized);
    } on Object {
      result = const MobileAccountUsageResult<MobileRunUsage>.failure(
        'RUN_USAGE_LOAD_FAILED',
      );
    }
    _runUsageInFlight.remove(normalized);
    if (_disposed) return result;
    if (result.status == MobileAccountUsageResultStatus.success &&
        result.data != null &&
        result.data!.runId == normalized) {
      _runUsages[normalized] = result.data!;
      _runUsageErrors.remove(normalized);
    } else {
      _runUsageErrors[normalized] = result.errorCode ?? 'RUN_USAGE_LOAD_FAILED';
    }
    notifyListeners();
    return result;
  }

  Future<MobileAccountUsageResult<MobileAccountMembership>>
  _loadMembership() async {
    try {
      return await _repository.membership();
    } on Object {
      return const MobileAccountUsageResult<MobileAccountMembership>.failure(
        'ACCOUNT_MEMBERSHIP_LOAD_FAILED',
      );
    }
  }

  Future<MobileAccountUsageResult<MobileAccountCreditPage>>
  _loadCredits() async {
    try {
      return await _repository.credits(limit: 50);
    } on Object {
      return const MobileAccountUsageResult<MobileAccountCreditPage>.failure(
        'ACCOUNT_CREDIT_LOAD_FAILED',
      );
    }
  }

  Future<MobileAccountUsageResult<MobileWorkspaceStorageUsage>>
  _loadStorageUsage() async {
    try {
      return await _repository.storageUsage();
    } on Object {
      return const MobileAccountUsageResult<
        MobileWorkspaceStorageUsage
      >.failure('WORKSPACE_STORAGE_LOAD_FAILED');
    }
  }

  Future<MobileAccountUsageResult<List<MobileQuotaBalance>>>
  _loadQuotaBalances() async {
    try {
      return await _repository.quotaBalances();
    } on Object {
      return const MobileAccountUsageResult.failure(
        'ACCOUNT_QUOTA_LOAD_FAILED',
      );
    }
  }

  void _applyCreditPage(MobileAccountCreditPage page, {required bool reset}) {
    if (reset) {
      _creditLots.clear();
      _seenCreditCursors.clear();
    }
    final existing = <String>{for (final lot in _creditLots) lot.lotId};
    for (final lot in page.lots) {
      if (existing.add(lot.lotId)) _creditLots.add(lot);
    }
    final next = _nonEmpty(page.nextCursor);
    if (next != null && !_seenCreditCursors.add(next)) {
      _nextCreditCursor = null;
      _creditErrorCode = 'ACCOUNT_CREDIT_CURSOR_INVALID';
    } else {
      _nextCreditCursor = next;
    }
    _creditSummary = page;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
