import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/database/app_preferences_dao.dart';

const _dailyTopicCacheContentVersion = 2;

abstract interface class DailyTopicPort {
  Future<ApiResult<DailyTopicRecommendationPage>> list(String workspaceId);

  Future<ApiResult<DailyTopicRecommendation>> get(
    String workspaceId,
    String recommendationId,
  );

  Future<ApiResult<DailyTopicRecommendation>> markRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  });

  Future<ApiResult<DailyTopicRecommendation>> dismiss(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  });

  Future<ApiResult<DailyTopicUseResult>> use(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  });
}

final class RemoteDailyTopicPort implements DailyTopicPort {
  const RemoteDailyTopicPort(this._client);

  final DailyTopicRecommendationClient _client;

  @override
  Future<ApiResult<DailyTopicRecommendationPage>> list(String workspaceId) =>
      _client.list(workspaceId);

  @override
  Future<ApiResult<DailyTopicRecommendation>> get(
    String workspaceId,
    String recommendationId,
  ) => _client.get(workspaceId, recommendationId);

  @override
  Future<ApiResult<DailyTopicRecommendation>> markRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) => _client.markRead(
    workspaceId,
    recommendationId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<ApiResult<DailyTopicRecommendation>> dismiss(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) => _client.dismiss(
    workspaceId,
    recommendationId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<ApiResult<DailyTopicUseResult>> use(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) => _client.use(
    workspaceId,
    recommendationId,
    topicId: topicId,
    idempotencyKey: idempotencyKey,
  );
}

enum DailyTopicLoadStatus { idle, loading, ready, failed, workspacePending }

enum DailyTopicRefreshTrigger {
  initialization,
  workspaceReady,
  foregroundResume,
  foregroundCheck,
  userRequested;

  bool get bypassesFreshness => this == workspaceReady || this == userRequested;
}

final class DailyTopicState {
  const DailyTopicState({
    this.status = DailyTopicLoadStatus.idle,
    this.recommendation,
    this.errorCode,
    this.fromCache = false,
    this.updatedAt,
  });

  final DailyTopicLoadStatus status;
  final DailyTopicRecommendation? recommendation;
  final String? errorCode;
  final bool fromCache;
  final DateTime? updatedAt;

  bool get isLoading => status == DailyTopicLoadStatus.loading;
  bool get isReady => recommendation != null;
}

/// Account- and Workspace-scoped production daily recommendation state.
final class DailyTopicController extends ChangeNotifier {
  DailyTopicController({
    required DailyTopicPort port,
    required AppPreferencesDao preferences,
    required String userScope,
    required String? Function() workspaceId,
    required bool Function() workspaceReady,
    required Duration Function() cacheTtl,
    DateTime Function()? now,
  }) : _port = port,
       _preferences = preferences,
       _userScope = userScope,
       _workspaceId = workspaceId,
       _workspaceReady = workspaceReady,
       _cacheTtl = cacheTtl,
       _now = now ?? DateTime.now;

  final DailyTopicPort _port;
  final AppPreferencesDao _preferences;
  final String _userScope;
  final String? Function() _workspaceId;
  final bool Function() _workspaceReady;
  final Duration Function() _cacheTtl;
  final DateTime Function() _now;

  DailyTopicState _state = const DailyTopicState();
  bool _initialized = false;
  bool _disposed = false;
  DateTime? _cacheExpiresAt;
  String? _refreshedLocalDate;
  String? _refreshedWorkspaceId;
  Future<void>? _refreshing;
  DailyTopicRefreshTrigger? _pendingRefresh;
  String? _activeWorkspaceId;
  String? _activeRefreshLocalDate;

  DailyTopicState get state => _state;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    _restoreCache();
    await refresh(DailyTopicRefreshTrigger.initialization);
  }

  Future<void> load({bool force = false}) => refresh(
    force
        ? DailyTopicRefreshTrigger.userRequested
        : DailyTopicRefreshTrigger.foregroundCheck,
  );

  Future<void> refresh(DailyTopicRefreshTrigger trigger) {
    if (_disposed) return Future<void>.value();
    final inFlight = _refreshing;
    if (inFlight != null) {
      if (_shouldLatch(trigger)) _latchRefresh(trigger);
      return inFlight;
    }

    late final Future<void> operation;
    operation = _runRefreshLoop(trigger).whenComplete(() {
      if (identical(_refreshing, operation)) {
        _refreshing = null;
        _activeWorkspaceId = null;
        _activeRefreshLocalDate = null;
      }
    });
    _refreshing = operation;
    return operation;
  }

  Future<void> _runRefreshLoop(DailyTopicRefreshTrigger initial) async {
    var trigger = initial;
    while (!_disposed) {
      _pendingRefresh = null;
      await _refreshOnce(trigger);
      final pending = _pendingRefresh;
      if (pending == null) return;
      trigger = pending;
    }
  }

  Future<void> _refreshOnce(DailyTopicRefreshTrigger trigger) async {
    final workspaceId = _workspaceId()?.trim();
    _activeWorkspaceId = workspaceId;
    _activeRefreshLocalDate = _currentLocalDate;
    if (!_workspaceReady() || workspaceId?.isNotEmpty != true) {
      final retained = _recommendationForWorkspace(workspaceId);
      _set(
        DailyTopicState(
          status: DailyTopicLoadStatus.workspacePending,
          recommendation: retained,
          fromCache: retained != null && _state.fromCache,
          updatedAt: retained == null ? null : _state.updatedAt,
          errorCode: 'WORKSPACE_NOT_READY',
        ),
      );
      return;
    }
    final resolvedWorkspaceId = workspaceId!;
    if (!trigger.bypassesFreshness && _hasFreshCacheFor(resolvedWorkspaceId)) {
      return;
    }
    final retained = _recommendationForWorkspace(resolvedWorkspaceId);
    _set(
      DailyTopicState(
        status: DailyTopicLoadStatus.loading,
        recommendation: retained,
        fromCache: retained != null && _state.fromCache,
        updatedAt: retained == null ? null : _state.updatedAt,
      ),
    );
    try {
      final result = await _port.list(resolvedWorkspaceId);
      if (!_isCurrentWorkspace(resolvedWorkspaceId)) {
        _latchRefresh(DailyTopicRefreshTrigger.workspaceReady);
        return;
      }
      if (!result.ok || result.data == null) {
        _fail(
          _dailyTopicErrorCode(result.error?.code, result.status),
          workspaceId: resolvedWorkspaceId,
        );
        return;
      }
      final selected = _selectCurrent(
        result.data!.items,
        workspaceId: resolvedWorkspaceId,
      );
      final refreshedAt = _nowUtc();
      _cacheExpiresAt = refreshedAt.add(_resolvedCacheTtl());
      _refreshedLocalDate = _currentLocalDate;
      _refreshedWorkspaceId = resolvedWorkspaceId;
      _set(
        DailyTopicState(
          status: DailyTopicLoadStatus.ready,
          recommendation: selected,
          fromCache: false,
          updatedAt: refreshedAt,
        ),
      );
      _persistCache();
    } catch (_) {
      if (!_isCurrentWorkspace(resolvedWorkspaceId)) {
        _latchRefresh(DailyTopicRefreshTrigger.workspaceReady);
        return;
      }
      _fail('DAILY_TOPIC_SYNC_FAILED', workspaceId: resolvedWorkspaceId);
    }
  }

  Future<DailyTopicRecommendation?> open(String recommendationId) async {
    if (!_canCallWorkspace()) return null;
    final workspaceId = _workspaceId()!.trim();
    try {
      final result = await _port.get(workspaceId, recommendationId);
      final detail = result.data;
      if (!result.ok || detail == null) {
        _fail(
          _dailyTopicErrorCode(result.error?.code, result.status),
          workspaceId: workspaceId,
        );
        return null;
      }
      _acceptDetail(detail);
      if (detail.readAt == null) {
        final marked = await _markReadWithRetry(workspaceId, detail);
        if (marked != null) return marked;
      }
      return detail;
    } catch (_) {
      _fail('DAILY_TOPIC_DETAIL_FAILED', workspaceId: workspaceId);
      return null;
    }
  }

  Future<DailyTopicUseResult?> use({
    required String recommendationId,
    String? topicId,
  }) async {
    if (!_canCallWorkspace()) return null;
    final workspaceId = _workspaceId()!.trim();
    try {
      final result = await _port.use(
        workspaceId,
        recommendationId,
        topicId: topicId,
        idempotencyKey: _idempotency('use', recommendationId),
      );
      if (!result.ok || result.data == null) {
        _fail(
          _dailyTopicErrorCode(result.error?.code, result.status),
          workspaceId: workspaceId,
        );
        return null;
      }
      _cacheExpiresAt = null;
      unawaited(load(force: true));
      return result.data;
    } catch (_) {
      _fail('DAILY_TOPIC_USE_FAILED', workspaceId: workspaceId);
      return null;
    }
  }

  Future<bool> dismiss(DailyTopicRecommendation recommendation) async {
    if (!_canCallWorkspace()) return false;
    final workspaceId = _workspaceId()!.trim();
    var detail = recommendation;
    final idempotencyKey = _idempotency(
      'dismiss',
      recommendation.recommendationId,
    );
    try {
      for (var attempt = 0; attempt < 2; attempt += 1) {
        final result = await _port.dismiss(
          workspaceId,
          detail.recommendationId,
          etag: detail.etag,
          idempotencyKey: idempotencyKey,
        );
        if (result.ok && result.data != null) return _acceptDismissal();
        if (attempt == 0 && result.status == 412) {
          final reread = await _port.get(workspaceId, detail.recommendationId);
          if (!reread.ok || reread.data == null) break;
          detail = reread.data!;
          if (!detail.isReady) return _acceptDismissal();
          continue;
        }
        _fail(
          _dailyTopicErrorCode(result.error?.code, result.status),
          workspaceId: workspaceId,
        );
        return false;
      }
      _fail('DAILY_TOPIC_DISMISS_FAILED', workspaceId: workspaceId);
      return false;
    } catch (_) {
      _fail('DAILY_TOPIC_DISMISS_FAILED', workspaceId: workspaceId);
      return false;
    }
  }

  Future<DailyTopicRecommendation?> _markReadWithRetry(
    String workspaceId,
    DailyTopicRecommendation recommendation,
  ) async {
    var detail = recommendation;
    final idempotencyKey = _idempotency(
      'read',
      recommendation.recommendationId,
    );
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final result = await _port.markRead(
        workspaceId,
        detail.recommendationId,
        etag: detail.etag,
        idempotencyKey: idempotencyKey,
      );
      if (result.ok && result.data != null) {
        _acceptDetail(result.data!);
        return result.data;
      }
      if (attempt == 0 && result.status == 412) {
        final reread = await _port.get(workspaceId, detail.recommendationId);
        if (!reread.ok || reread.data == null) break;
        detail = reread.data!;
        continue;
      }
      _fail(
        _dailyTopicErrorCode(result.error?.code, result.status),
        workspaceId: workspaceId,
      );
      return null;
    }
    _fail('DAILY_TOPIC_READ_FAILED', workspaceId: workspaceId);
    return null;
  }

  bool _acceptDismissal() {
    _cacheExpiresAt = null;
    _set(const DailyTopicState(status: DailyTopicLoadStatus.ready));
    _persistCache();
    unawaited(load(force: true));
    return true;
  }

  bool _canCallWorkspace() {
    if (_workspaceReady() && _workspaceId()?.trim().isNotEmpty == true) {
      return true;
    }
    final workspaceId = _workspaceId()?.trim();
    final retained = _recommendationForWorkspace(workspaceId);
    _set(
      DailyTopicState(
        status: DailyTopicLoadStatus.workspacePending,
        recommendation: retained,
        fromCache: retained != null && _state.fromCache,
        updatedAt: retained == null ? null : _state.updatedAt,
        errorCode: 'WORKSPACE_NOT_READY',
      ),
    );
    return false;
  }

  bool _hasFreshCacheFor(String workspaceId) {
    final expiresAt = _cacheExpiresAt;
    return expiresAt != null &&
        _nowUtc().isBefore(expiresAt) &&
        _refreshedLocalDate == _currentLocalDate &&
        _refreshedWorkspaceId == workspaceId;
  }

  DailyTopicRecommendation? _selectCurrent(
    List<DailyTopicRecommendation> recommendations, {
    required String workspaceId,
  }) {
    final ready =
        recommendations
            .where((item) => item.isReady && item.workspaceId == workspaceId)
            .toList(growable: false)
          ..sort(_compareNewestRecommendation);
    for (final item in ready) {
      if (item.recommendationKind == 'daily_topic_report') return item;
    }
    return ready.isEmpty ? null : ready.first;
  }

  void _acceptDetail(DailyTopicRecommendation detail) {
    _cacheExpiresAt = _nowUtc().add(_resolvedCacheTtl());
    _set(
      DailyTopicState(
        status: DailyTopicLoadStatus.ready,
        recommendation: detail,
        updatedAt: _nowUtc(),
      ),
    );
    _persistCache();
  }

  void _fail(String code, {String? workspaceId}) {
    final retained = workspaceId == null
        ? _state.recommendation
        : _recommendationForWorkspace(workspaceId);
    _set(
      DailyTopicState(
        status: retained == null
            ? DailyTopicLoadStatus.failed
            : DailyTopicLoadStatus.ready,
        recommendation: retained,
        fromCache: _state.fromCache,
        updatedAt: _state.updatedAt,
        errorCode: code,
      ),
    );
  }

  void _restoreCache() {
    if (_userScope == 'anonymous') return;
    try {
      final raw = _preferences.readValue(_cacheKey);
      if (raw == null) return;
      final value = jsonDecode(raw);
      final object = value is Map ? _stringMap(value) : null;
      if (object == null ||
          object['contentVersion'] != _dailyTopicCacheContentVersion) {
        return;
      }
      final expiresAt = DateTime.tryParse(object['expiresAt'] as String? ?? '');
      final updatedAt = DateTime.tryParse(
        object['updatedAt'] as String? ?? '',
      )?.toUtc();
      final recommendation = _recommendationFromCache(object['recommendation']);
      if (expiresAt == null ||
          recommendation == null ||
          recommendation.workspaceId != _workspaceId()?.trim()) {
        return;
      }
      _cacheExpiresAt = expiresAt.toUtc();
      _refreshedWorkspaceId = recommendation.workspaceId;
      _refreshedLocalDate = _validLocalDate(
        object['refreshedLocalDate'],
        fallback: updatedAt,
      );
      _state = DailyTopicState(
        status: DailyTopicLoadStatus.ready,
        recommendation: recommendation,
        fromCache: true,
        updatedAt: updatedAt,
      );
      notifyListeners();
    } catch (_) {
      // A malformed local cache is disposable and cannot block remote reads.
    }
  }

  void _persistCache() {
    if (_userScope == 'anonymous') return;
    try {
      final recommendation = _state.recommendation;
      final expiresAt = _cacheExpiresAt;
      if (recommendation == null || expiresAt == null) {
        _preferences.deleteValue(_cacheKey);
        return;
      }
      _preferences.upsertValue(
        preferenceKey: _cacheKey,
        value: jsonEncode(<String, Object?>{
          'contentVersion': _dailyTopicCacheContentVersion,
          'expiresAt': expiresAt.toIso8601String(),
          'updatedAt': (_state.updatedAt ?? _nowUtc()).toIso8601String(),
          'refreshedLocalDate': _refreshedLocalDate ?? _currentLocalDate,
          'recommendation': _recommendationToCache(recommendation),
        }),
        updatedAt: _nowUtc().toIso8601String(),
      );
    } catch (_) {
      // Cache persistence is an optimization, never a production operation.
    }
  }

  String get _cacheKey {
    final workspace = _workspaceId()?.trim() ?? 'workspace-pending';
    final digest = sha256
        .convert(utf8.encode('$_userScope\u0000$workspace'))
        .toString()
        .substring(0, 24);
    return 'daily-topic-$digest';
  }

  Duration _resolvedCacheTtl() {
    try {
      final value = _cacheTtl();
      if (value > Duration.zero && value <= const Duration(days: 1)) {
        return value;
      }
    } catch (_) {}
    return const Duration(minutes: 5);
  }

  DateTime _nowUtc() => _now().toUtc();

  String get _currentLocalDate => _localDateKey(_now().toLocal());

  bool _isCurrentWorkspace(String workspaceId) =>
      !_disposed && _workspaceReady() && _workspaceId()?.trim() == workspaceId;

  DailyTopicRecommendation? _recommendationForWorkspace(String? workspaceId) {
    final recommendation = _state.recommendation;
    return recommendation?.workspaceId == workspaceId ? recommendation : null;
  }

  bool _shouldLatch(DailyTopicRefreshTrigger trigger) =>
      trigger.bypassesFreshness ||
      _activeWorkspaceId != _workspaceId()?.trim() ||
      _activeRefreshLocalDate != _currentLocalDate;

  void _latchRefresh(DailyTopicRefreshTrigger trigger) {
    final pending = _pendingRefresh;
    if (pending == null ||
        _refreshPriority(trigger) > _refreshPriority(pending)) {
      _pendingRefresh = trigger;
    }
  }

  String _idempotency(String action, String recommendationId) =>
      'daily-topic-$action-$recommendationId-${_nowUtc().microsecondsSinceEpoch}';

  void _set(DailyTopicState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingRefresh = null;
    super.dispose();
  }
}

int _compareNewestRecommendation(
  DailyTopicRecommendation left,
  DailyTopicRecommendation right,
) {
  final byBusinessDate = right.businessDate.compareTo(left.businessDate);
  if (byBusinessDate != 0) return byBusinessDate;
  final byGeneratedAt =
      (right.generatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
        left.generatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
  if (byGeneratedAt != 0) return byGeneratedAt;
  return right.recommendationId.compareTo(left.recommendationId);
}

int _refreshPriority(DailyTopicRefreshTrigger trigger) => switch (trigger) {
  DailyTopicRefreshTrigger.foregroundCheck => 0,
  DailyTopicRefreshTrigger.initialization => 1,
  DailyTopicRefreshTrigger.foregroundResume => 2,
  DailyTopicRefreshTrigger.workspaceReady => 3,
  DailyTopicRefreshTrigger.userRequested => 4,
};

String _localDateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String? _validLocalDate(Object? value, {required DateTime? fallback}) {
  final candidate = value is String ? value.trim() : '';
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(candidate)) return candidate;
  return fallback == null ? null : _localDateKey(fallback.toLocal());
}

String _dailyTopicErrorCode(String? code, int? status) {
  if (status == 404 || code == 'NOT_FOUND' || code == 'ROUTE_NOT_FOUND') {
    return 'DAILY_TOPIC_SERVICE_UNAVAILABLE';
  }
  return code ?? 'DAILY_TOPIC_SYNC_FAILED';
}

Map<String, Object?>? _stringMap(Object value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, Object?> _recommendationToCache(
  DailyTopicRecommendation item,
) => <String, Object?>{
  'recommendationId': item.recommendationId,
  'workspaceId': item.workspaceId,
  'businessDate': item.businessDate,
  'recommendationKind': item.recommendationKind,
  'status': item.status,
  'title': item.title,
  'summaryMarkdown': item.summaryMarkdown,
  'etag': item.etag,
  if (item.generatedAt != null)
    'generatedAt': item.generatedAt!.toIso8601String(),
  if (item.readAt != null) 'readAt': item.readAt!.toIso8601String(),
  if (item.dismissedAt != null)
    'dismissedAt': item.dismissedAt!.toIso8601String(),
  if (item.expiresAt != null) 'expiresAt': item.expiresAt!.toIso8601String(),
  'topics': <Object?>[for (final topic in item.topics) topic.toJson()],
};

DailyTopicRecommendation? _recommendationFromCache(Object? value) {
  final object = value == null ? null : _stringMap(value);
  if (object == null) return null;
  try {
    return DailyTopicRecommendation.fromJson(object);
  } on FormatException {
    return null;
  }
}
