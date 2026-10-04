import 'package:huahuo_api/huahuo_api.dart';

import '../../../core/api/scoped_read_cache.dart';
import '../domain/positioning_progress_repository.dart';

final class RemotePositioningProgressRepository
    implements PositioningProgressRepository {
  RemotePositioningProgressRepository({
    required this._client,
    required this._cache,
    required this._workspaceId,
  });

  final PositioningProgressClient Function() _client;
  final ScopedReadCache _cache;
  final String _workspaceId;
  WorkspacePositioningProgress? _progress;
  String? _etag;
  static const _cacheKey = 'workspacePositioningProgress';

  @override
  PositioningCoverage? readCached() {
    final cached = _cache.readFallback(_cacheKey, _workspaceId);
    final progress = parseWorkspacePositioningProgress(cached?.payload);
    if (progress == null) return null;
    _progress = progress;
    _etag = cached!.etag;
    return _coverage(progress, stale: true);
  }

  @override
  Future<PositioningCoverage?> refresh({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return null;
    final response = await _client().read(
      workspaceId: _workspaceId,
      ifNoneMatch: _etag,
    );
    if (!isCurrent()) return null;
    if (response.isNotModified && _progress != null) {
      return _coverage(_progress!);
    }
    if (!response.ok || response.data == null) {
      throw StateError('POSITIONING_PROGRESS_UNAVAILABLE');
    }
    final progress = response.data!;
    _cache.write(
      _cacheKey,
      _workspaceId,
      etag: response.etag,
      payload: _progressPayload(progress),
    );
    _progress = progress;
    _etag = response.etag;
    return _coverage(progress);
  }
}

PositioningCoverage _coverage(
  WorkspacePositioningProgress progress, {
  bool stale = false,
}) => PositioningCoverage(
  coldStartPercent: progress.coldStartPercent,
  completedPercent: progress.completedPercent,
  isStale: stale || progress.validationStatus == 'last_known_good',
);

Map<String, Object?> _progressPayload(WorkspacePositioningProgress progress) =>
    {
      'schemaVersion': progress.schemaVersion,
      'source': progress.source,
      'available': true,
      'projectionVersion': progress.projectionVersion,
      'status': progress.status,
      'validationStatus': progress.validationStatus,
      'completedPercent': progress.completedPercent,
      'coldStartPercent': progress.coldStartPercent,
      'coldStartCompleted': progress.coldStartCompleted,
      'modules': [
        for (final module in progress.modules)
          {
            'id': module.id,
            'label': module.label,
            'weight': module.weight,
            'score': module.score,
            'state': module.state,
            'summary': module.summary,
          },
      ],
      'nextFocus': [
        for (final focus in progress.nextFocus)
          {
            'title': focus.title,
            'detail': focus.detail,
            'moduleId': focus.moduleId,
          },
      ],
      'updatedFiles': progress.updatedFiles,
      'lastUpdated': progress.lastUpdated?.toUtc().toIso8601String(),
    };
