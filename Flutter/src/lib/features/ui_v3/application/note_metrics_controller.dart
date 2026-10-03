import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/scoped_read_cache.dart';
import '../../../core/database/app_preferences_dao.dart';
import '../data/note_metrics_repository.dart';
import 'package:huahuo_api/huahuo_api.dart';

// resident-provider: Shares one account-scoped note metrics repository identity across dependent controllers.
final noteMetricsRepositoryProvider = Provider<NoteMetricsRepository>(
  (ref) => const UnavailableNoteMetricsRepository(),
);

// resident-provider: Shares one account-scoped note metrics read cache identity across dependent controllers.
final noteMetricsReadCacheProvider = Provider<ScopedReadCache?>((ref) => null);

// resident-provider: Keeps the note metrics cache bypass value consistent across sibling route consumers.
/// The runtime overrides this while uploads/imports/derived work can change
/// the visible asset-growth projection.
final noteMetricsCacheBypassProvider = Provider<bool>((ref) => false);

// resident-provider: Keeps the note metrics cache revision value consistent across sibling route consumers.
/// Changes with the asset-projection task lifecycle. A metrics GET captures
/// this value so a stale response cannot restore a snapshot after a task
/// transition invalidates it.
final noteMetricsCacheRevisionProvider = Provider<String>((ref) => '');

// resident-provider: Shares one account-scoped asset growth period repository identity across dependent controllers.
final assetGrowthPeriodRepositoryProvider =
    Provider<AssetGrowthPeriodRepository?>((ref) => null);

// resident-provider: Preserves the asset growth period controller state machine across route transitions.
final assetGrowthPeriodControllerProvider =
    ChangeNotifierProvider<AssetGrowthPeriodController>((ref) {
      return AssetGrowthPeriodController(
        repository: ref.watch(assetGrowthPeriodRepositoryProvider),
      )..restore();
    });

// resident-provider: Preserves the note metrics controller state machine across route transitions.
final noteMetricsControllerProvider =
    ChangeNotifierProvider<NoteMetricsController>((ref) {
      final controller = NoteMetricsController(
        repository: ref.watch(noteMetricsRepositoryProvider),
        cache: ref.watch(noteMetricsReadCacheProvider),
        cacheBypass: () => ref.read(noteMetricsCacheBypassProvider),
        cacheRevision: () => ref.read(noteMetricsCacheRevisionProvider),
      );
      controller.load();
      return controller;
    });

enum NoteMetricsStatus { loading, ready, failed }

enum AssetGrowthPeriod {
  week('week', 7),
  month('month', 30);

  const AssetGrowthPeriod(this.wireName, this.dayCount);

  final String wireName;
  final int dayCount;

  static AssetGrowthPeriod? tryParse(String? value) {
    for (final period in values) {
      if (period.wireName == value?.trim()) return period;
    }
    return null;
  }
}

final class AssetGrowthPeriodRepository {
  AssetGrowthPeriodRepository({
    required AppPreferencesDao dao,
    required String userScope,
    DateTime Function()? now,
  }) : _dao = dao,
       _preferenceKey =
           'profile.asset-growth-period.${_preferenceScopeHash(userScope)}',
       _now = now ?? DateTime.now;

  final AppPreferencesDao _dao;
  final String _preferenceKey;
  final DateTime Function() _now;

  @visibleForTesting
  String get preferenceKey => _preferenceKey;

  AssetGrowthPeriod load() {
    final parsed = AssetGrowthPeriod.tryParse(_dao.readValue(_preferenceKey));
    if (parsed != null) return parsed;
    save(AssetGrowthPeriod.week);
    return AssetGrowthPeriod.week;
  }

  void save(AssetGrowthPeriod period) {
    _dao.upsertValue(
      preferenceKey: _preferenceKey,
      value: period.wireName,
      updatedAt: _now().toUtc().toIso8601String(),
    );
  }
}

final class AssetGrowthPeriodController extends ChangeNotifier {
  AssetGrowthPeriodController({AssetGrowthPeriodRepository? repository})
    : _repository = repository;

  final AssetGrowthPeriodRepository? _repository;
  AssetGrowthPeriod _period = AssetGrowthPeriod.week;
  bool _restored = false;
  String? _errorCode;

  AssetGrowthPeriod get period => _period;
  bool get restored => _restored;
  String? get errorCode => _errorCode;

  void restore() {
    try {
      _period = _repository?.load() ?? AssetGrowthPeriod.week;
      _errorCode = null;
    } catch (_) {
      _period = AssetGrowthPeriod.week;
      _errorCode = 'ASSET_GROWTH_PERIOD_RESTORE_FAILED';
    }
    _restored = true;
    notifyListeners();
  }

  bool selectPeriod(AssetGrowthPeriod period) {
    if (_period == period && _errorCode == null) return true;
    try {
      _repository?.save(period);
      _period = period;
      _errorCode = null;
      notifyListeners();
      return true;
    } catch (_) {
      _errorCode = 'ASSET_GROWTH_PERIOD_SAVE_FAILED';
      notifyListeners();
      return false;
    }
  }
}

String _preferenceScopeHash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final unit in value.trim().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

@immutable
final class NoteMetricsState {
  const NoteMetricsState({
    this.status = NoteMetricsStatus.loading,
    this.days = const <WorkspaceNoteMetricDay>[],
    this.coverage,
    this.hasMore = false,
    this.nextCursor,
    this.errorCode,
    this.isLoadingMore = false,
  });

  final NoteMetricsStatus status;
  final List<WorkspaceNoteMetricDay> days;
  final WorkspaceNoteMetricsCoverage? coverage;
  final bool hasMore;
  final String? nextCursor;
  final String? errorCode;
  final bool isLoadingMore;

  bool get isLoading => status == NoteMetricsStatus.loading;
  bool get hasData => coverage != null && days.isNotEmpty;
  WorkspaceNoteMetricDay? get currentDay => days.isEmpty ? null : days.first;

  NoteMetricsState copyWith({
    NoteMetricsStatus? status,
    List<WorkspaceNoteMetricDay>? days,
    WorkspaceNoteMetricsCoverage? coverage,
    bool clearCoverage = false,
    bool? hasMore,
    String? nextCursor,
    bool clearNextCursor = false,
    String? errorCode,
    bool clearError = false,
    bool? isLoadingMore,
  }) => NoteMetricsState(
    status: status ?? this.status,
    days: List<WorkspaceNoteMetricDay>.unmodifiable(days ?? this.days),
    coverage: clearCoverage ? null : coverage ?? this.coverage,
    hasMore: hasMore ?? this.hasMore,
    nextCursor: clearNextCursor ? null : nextCursor ?? this.nextCursor,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

@immutable
final class AssetGrowthSeries {
  const AssetGrowthSeries(this.days);

  final List<WorkspaceNoteMetricDay> days;

  int get totalCount => days.fold(0, (total, day) => total + day.count);
}

extension NoteMetricsGrowthProjection on NoteMetricsState {
  AssetGrowthSeries? growthSeriesFor(AssetGrowthPeriod period) {
    final coverage = this.coverage;
    final current = coverage == null
        ? null
        : _metricCalendarDate(coverage.currentDate);
    final coverageStart = coverage == null
        ? null
        : _metricCalendarDate(coverage.startDate);
    final completeFrom = coverage == null
        ? null
        : _metricCalendarDate(coverage.completeFromDate);
    if (coverage == null || current == null || coverageStart == null) {
      return null;
    }
    final requestedStart = current.subtract(
      Duration(days: period.dayCount - 1),
    );
    if (!coverage.historyComplete &&
        (completeFrom == null || requestedStart.isBefore(completeFrom))) {
      return null;
    }

    final byDate = <String, WorkspaceNoteMetricDay>{
      for (final day in days) day.date: day,
    };
    final selected = <WorkspaceNoteMetricDay>[];
    for (var offset = 0; offset < period.dayCount; offset += 1) {
      final date = requestedStart.add(Duration(days: offset));
      final dateText = _metricDateText(date);
      final value = byDate[dateText];
      if (value != null) {
        selected.add(value);
      } else if (coverage.historyComplete && date.isBefore(coverageStart)) {
        selected.add(
          WorkspaceNoteMetricDay(date: dateText, count: 0, complete: true),
        );
      } else {
        return null;
      }
    }
    return AssetGrowthSeries(
      List<WorkspaceNoteMetricDay>.unmodifiable(selected),
    );
  }
}

final class NoteMetricsController extends ChangeNotifier {
  NoteMetricsController({
    required NoteMetricsRepository repository,
    ScopedReadCache? cache,
    bool Function()? cacheBypass,
    String Function()? cacheRevision,
    this.pageSize = 30,
  }) : _repository = repository,
       _cache = cache, // ignore: prefer_initializing_formals
       _cacheBypass = cacheBypass,
       _cacheRevision = cacheRevision;

  final NoteMetricsRepository _repository;
  final ScopedReadCache? _cache;
  final bool Function()? _cacheBypass;
  final String Function()? _cacheRevision;
  final int pageSize;
  NoteMetricsState _state = const NoteMetricsState();
  int _activeInitialLoads = 0;
  bool _loadMoreInFlight = false;
  int _requestGeneration = 0;
  bool _disposed = false;

  NoteMetricsState get state => _state;

  bool get _initialLoadInFlight => _activeInitialLoads > 0;

  /// Revalidates resident metrics without superseding an in-flight request.
  Future<void> refresh() async {
    if (_initialLoadInFlight || _loadMoreInFlight) return;
    await load(force: true);
  }

  Future<void> load({bool force = false, bool invalidateCache = false}) async {
    if ((_initialLoadInFlight || _loadMoreInFlight) &&
        !force &&
        !invalidateCache) {
      return;
    }
    final generation = ++_requestGeneration;
    final cacheRevision = _currentCacheRevision();
    if (invalidateCache) {
      invalidateInitialNoteMetricsCache(_cache, pageSize: pageSize);
    }
    if (!_isCurrentRequest(generation, cacheRevision)) return;
    _activeInitialLoads += 1;
    try {
      final cache = _cache;
      WorkspaceNoteMetricsPage? cachedPage;
      if (!force && !_shouldBypassCache() && cache != null) {
        final freshEntry = cache.readFallback(
          'workspaceNoteMetrics',
          _initialCacheKey(pageSize),
        );
        final cachedEntry =
            freshEntry ??
            cache.read('workspaceNoteMetrics', _initialCacheKey(pageSize));
        if (cachedEntry != null) {
          cachedPage = parseWorkspaceNoteMetricsPage(cachedEntry.payload);
          if (cachedPage == null || !_isInitialPageValid(cachedPage)) {
            cache.invalidate(
              'workspaceNoteMetrics',
              _initialCacheKey(pageSize),
            );
            cachedPage = null;
          } else {
            if (!_isCurrentRequest(generation, cacheRevision)) return;
            _replace(_stateForPage(cachedPage));
            if (freshEntry != null) return;
          }
        }
      }
      if (!_isCurrentRequest(generation, cacheRevision)) return;
      _replace(
        _state.copyWith(
          status: cachedPage == null
              ? NoteMetricsStatus.loading
              : NoteMetricsStatus.ready,
          clearError: true,
          isLoadingMore: false,
        ),
      );
      final page = await _repository.load(limit: pageSize);
      if (!_isCurrentRequest(generation, cacheRevision)) return;
      if (!_isInitialPageValid(page)) {
        throw const NoteMetricsException('NOTE_METRICS_PAGE_INVALID');
      }
      _writeCachedPage(page);
      _replace(_stateForPage(page));
    } on NoteMetricsException catch (error) {
      if (!_isCurrentRequest(generation, cacheRevision)) return;
      _replace(_stateAfterInitialFailure(error.code));
    } on Object {
      if (!_isCurrentRequest(generation, cacheRevision)) return;
      _replace(_stateAfterInitialFailure('NOTE_METRICS_LOAD_FAILED'));
    } finally {
      _activeInitialLoads -= 1;
    }
  }

  Future<void> loadMore() async {
    final current = _state;
    final cursor = current.nextCursor;
    if (_initialLoadInFlight ||
        _loadMoreInFlight ||
        current.isLoadingMore ||
        !current.hasMore ||
        cursor == null ||
        current.coverage == null ||
        current.days.isEmpty) {
      return;
    }
    final generation = ++_requestGeneration;
    final cacheRevision = _currentCacheRevision();
    if (!_isCurrentRequest(generation, cacheRevision)) return;
    _loadMoreInFlight = true;
    _replace(current.copyWith(isLoadingMore: true, clearError: true));
    try {
      final page = await _repository.load(limit: pageSize, cursor: cursor);
      if (!_isCurrentRequest(generation, cacheRevision)) return;
      final merged = _mergeOlderPage(current, page);
      final next = NoteMetricsState(
        status: NoteMetricsStatus.ready,
        days: merged,
        coverage: current.coverage,
        hasMore: page.hasMore,
        nextCursor: page.hasMore ? page.nextCursor : null,
      );
      _writeCachedState(next, page: page);
      _replace(next);
    } on NoteMetricsException catch (error) {
      if (!_isCurrentRequest(generation, cacheRevision)) return;
      _replace(current.copyWith(errorCode: error.code, isLoadingMore: false));
    } on Object {
      if (!_isCurrentRequest(generation, cacheRevision)) return;
      _replace(
        current.copyWith(
          errorCode: 'NOTE_METRICS_PAGE_LOAD_FAILED',
          isLoadingMore: false,
        ),
      );
    } finally {
      _loadMoreInFlight = false;
    }
  }

  List<WorkspaceNoteMetricDay> _mergeOlderPage(
    NoteMetricsState current,
    WorkspaceNoteMetricsPage page,
  ) {
    final coverage = current.coverage!;
    if (page.coverage.startAt != coverage.startAt ||
        page.coverage.startDate != coverage.startDate ||
        page.coverage.completeFromDate != coverage.completeFromDate ||
        page.coverage.currentDate != coverage.currentDate ||
        page.coverage.historyComplete != coverage.historyComplete ||
        !_hasValidPageDays(page) ||
        !_isCalendarDayBefore(current.days.last.date, page.days.first.date)) {
      throw const NoteMetricsException('NOTE_METRICS_PAGE_INVALID');
    }
    final seen = <String>{for (final day in current.days) day.date};
    final merged = <WorkspaceNoteMetricDay>[...current.days];
    for (final day in page.days) {
      if (!seen.add(day.date)) {
        throw const NoteMetricsException('NOTE_METRICS_PAGE_INVALID');
      }
      merged.add(day);
    }
    return List<WorkspaceNoteMetricDay>.unmodifiable(merged);
  }

  bool _isInitialPageValid(WorkspaceNoteMetricsPage page) =>
      _hasValidPageDays(page) &&
      page.days.first.date == page.coverage.currentDate;

  bool _hasValidPageDays(WorkspaceNoteMetricsPage page) {
    if (page.days.isEmpty ||
        (page.hasMore && page.nextCursor.isEmpty) ||
        (!page.hasMore && page.nextCursor.isNotEmpty)) {
      return false;
    }
    for (var index = 1; index < page.days.length; index += 1) {
      if (!_isCalendarDayBefore(
        page.days[index - 1].date,
        page.days[index].date,
      )) {
        return false;
      }
    }
    final finalDate = page.days.last.date;
    return page.hasMore
        ? finalDate != page.coverage.startDate
        : finalDate == page.coverage.startDate;
  }

  bool _isCalendarDayBefore(String newer, String older) {
    final newerDate = _metricCalendarDate(newer);
    final olderDate = _metricCalendarDate(older);
    if (newerDate == null || olderDate == null) return false;
    return _metricDateText(newerDate.subtract(const Duration(days: 1))) ==
        _metricDateText(olderDate);
  }

  NoteMetricsState _stateForPage(WorkspaceNoteMetricsPage page) =>
      NoteMetricsState(
        status: NoteMetricsStatus.ready,
        days: List<WorkspaceNoteMetricDay>.unmodifiable(page.days),
        coverage: page.coverage,
        hasMore: page.hasMore,
        nextCursor: page.hasMore ? page.nextCursor : null,
      );

  NoteMetricsState _stateAfterInitialFailure(String errorCode) {
    if (_state.hasData) {
      return _state.copyWith(
        status: NoteMetricsStatus.ready,
        errorCode: errorCode,
        isLoadingMore: false,
      );
    }
    return NoteMetricsState(
      status: NoteMetricsStatus.failed,
      errorCode: errorCode,
    );
  }

  void _writeCachedPage(WorkspaceNoteMetricsPage page) {
    try {
      _cache?.write(
        'workspaceNoteMetrics',
        _initialCacheKey(pageSize),
        etag: null,
        payload: _metricsCachePayload(page),
      );
    } on Object {
      // A persisted read cache is optional; preserve the successfully loaded page.
    }
  }

  void _writeCachedState(
    NoteMetricsState state, {
    required WorkspaceNoteMetricsPage page,
  }) {
    final coverage = state.coverage;
    if (coverage == null || state.days.isEmpty) return;
    _writeCachedPage(
      WorkspaceNoteMetricsPage(
        schemaVersion: page.schemaVersion,
        metricId: page.metricId,
        timezone: page.timezone,
        asOf: page.asOf,
        coverage: coverage,
        days: state.days,
        hasMore: state.hasMore,
        nextCursor: state.nextCursor ?? '',
      ),
    );
  }

  bool _shouldBypassCache() {
    try {
      return _cacheBypass?.call() ?? false;
    } on Object {
      return false;
    }
  }

  /// Network calls cannot be canceled, so advance the generation before a
  /// queued task-transition or user refresh begins.
  void supersedePendingLoads() {
    _requestGeneration += 1;
  }

  bool _isCurrentRequest(int generation, String cacheRevision) {
    return !_disposed &&
        generation == _requestGeneration &&
        cacheRevision == _currentCacheRevision();
  }

  String _currentCacheRevision() {
    try {
      return _cacheRevision?.call() ?? '';
    } on Object {
      return '';
    }
  }

  void _replace(NoteMetricsState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    supersedePendingLoads();
    super.dispose();
  }
}

String _initialCacheKey(int pageSize) => 'initial-$pageSize';

/// Removes just the cached initial profile-growth page for this scope.
void invalidateInitialNoteMetricsCache(
  ScopedReadCache? cache, {
  int pageSize = 30,
}) {
  if (cache == null) return;
  try {
    cache.invalidate('workspaceNoteMetrics', _initialCacheKey(pageSize));
  } on Object {
    // Metrics caching is optional; preserve the surrounding task transition.
  }
}

Map<String, Object?> _metricsCachePayload(WorkspaceNoteMetricsPage page) =>
    <String, Object?>{
      'schemaVersion': page.schemaVersion,
      'metricId': page.metricId,
      'timezone': page.timezone,
      'asOf': page.asOf.toUtc().toIso8601String(),
      'coverage': <String, Object?>{
        'startAt': page.coverage.startAt.toUtc().toIso8601String(),
        'startDate': page.coverage.startDate,
        'completeFromDate': page.coverage.completeFromDate,
        'currentDate': page.coverage.currentDate,
        'historyComplete': page.coverage.historyComplete,
      },
      'days': <Map<String, Object?>>[
        for (final day in page.days)
          <String, Object?>{
            'date': day.date,
            'count': day.count,
            'complete': day.complete,
          },
      ],
      'hasMore': page.hasMore,
      'nextCursor': page.nextCursor,
    };

DateTime? _metricCalendarDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
  final year = int.tryParse(value.substring(0, 4));
  final month = int.tryParse(value.substring(5, 7));
  final day = int.tryParse(value.substring(8, 10));
  if (year == null || month == null || day == null) return null;
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day
      ? parsed
      : null;
}

String _metricDateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
