import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/assets/application/assets_controller.dart';
import '../../features/notifications/application/pending_message_projection.dart';
import '../../features/ui_v3/application/note_metrics_controller.dart';

@immutable
final class AssetProjectionFreshness {
  const AssetProjectionFreshness({
    required this.hasActiveWork,
    required this.revision,
  });

  final bool hasActiveWork;
  final String revision;

  @override
  bool operator ==(Object other) =>
      other is AssetProjectionFreshness &&
      other.hasActiveWork == hasActiveWork &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(hasActiveWork, revision);
}

// resident-provider: Preserves the asset projection freshness dependency identity across route changes.
/// Reuses the one durable task projection rather than maintaining another
/// recording/import/Agent state machine for cache freshness.
final assetProjectionFreshnessProvider = Provider<AssetProjectionFreshness>(
  (ref) => deriveAssetProjectionFreshness(
    ref.watch(pendingMessageProjectionProvider).items,
  ),
);

AssetProjectionFreshness deriveAssetProjectionFreshness(
  Iterable<PendingMessage> items,
) {
  final relevant = <PendingMessage>[
    for (final item in items)
      if (_isAssetAffectingTask(item)) item,
  ];
  final revisionParts = <String>[
    for (final item in relevant)
      '${item.id}\u0000${item.taskId ?? ''}\u0000${item.state.name}'
          '\u0000${item.stage ?? ''}\u0000${item.errorCode ?? ''}',
  ]..sort();
  return AssetProjectionFreshness(
    hasActiveWork: relevant.any(
      (item) => item.state == PendingMessageState.processing,
    ),
    revision: revisionParts.join('\u0001'),
  );
}

bool _isAssetAffectingTask(PendingMessage item) {
  if (!item.isTask) return false;
  return switch (item.source) {
    PendingMessageSource.aggregation ||
    PendingMessageSource.sprout ||
    PendingMessageSource.materialIngestion ||
    PendingMessageSource.documentImport ||
    PendingMessageSource.recordingTranscription => true,
    PendingMessageSource.agentTask =>
      item.targetType == 'asset' || item.targetType == 'recording',
    PendingMessageSource.remote =>
      item.targetType == 'asset' || item.targetType == 'recording',
    _ => false,
  };
}

/// Keeps the two stable asset projections coherent with task transitions while
/// leaving all unrelated cached endpoint projections untouched.
class AssetProjectionCacheScope extends ConsumerStatefulWidget {
  const AssetProjectionCacheScope({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AssetProjectionCacheScope> createState() =>
      _AssetProjectionCacheScopeState();
}

class _AssetProjectionCacheScopeState
    extends ConsumerState<AssetProjectionCacheScope> {
  @override
  Widget build(BuildContext context) {
    ref.listen<AssetProjectionFreshness>(assetProjectionFreshnessProvider, (
      previous,
      next,
    ) {
      if (previous == null || previous.revision == next.revision) return;
      invalidateAssetsMarkdownCache(ref.read(assetsReadCacheProvider));
      invalidateInitialNoteMetricsCache(ref.read(noteMetricsReadCacheProvider));
    });
    return ProviderScope(
      overrides: <Override>[
        assetsCacheBypassProvider.overrideWith(
          (ref) => ref.watch(assetProjectionFreshnessProvider).hasActiveWork,
        ),
        assetsCacheRevisionProvider.overrideWith(
          (ref) => ref.watch(assetProjectionFreshnessProvider).revision,
        ),
        noteMetricsCacheBypassProvider.overrideWith(
          (ref) => ref.watch(assetProjectionFreshnessProvider).hasActiveWork,
        ),
        noteMetricsCacheRevisionProvider.overrideWith(
          (ref) => ref.watch(assetProjectionFreshnessProvider).revision,
        ),
      ],
      child: widget.child,
    );
  }
}
