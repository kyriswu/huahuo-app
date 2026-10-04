import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../core/api/scoped_read_cache.dart';
import '../../features/positioning/application/positioning_progress_controller.dart';
import '../../features/positioning/data/positioning_progress_repository.dart';
import '../bootstrap/core_provider_module.dart';
import '../runtime/runtime_provider_module.dart';
import 'database_providers.dart';

/// Each surface owns and disposes its reader. A scope change replaces the
/// factory and invalidates all responses from the previous scope immediately.
final positioningProgressControllerFactoryProvider =
    Provider.autoDispose<PositioningProgressController Function()>((ref) {
      final userScope = ref.watch(authenticatedUserDataScopeProvider);
      final workspaceId = ref.watch(
        sessionStoreProvider.select(
          (store) => store.state.workspace?.workspaceId,
        ),
      );
      var valid = true;
      ref.onDispose(() => valid = false);
      bool isCurrentScope() =>
          valid &&
          ref.read(authenticatedUserDataScopeProvider) == userScope &&
          ref.read(sessionStoreProvider).state.workspace?.workspaceId ==
              workspaceId;
      return () => PositioningProgressController(
        repository: workspaceId == null || userScope == 'anonymous'
            ? null
            : RemotePositioningProgressRepository(
                client: () =>
                    PositioningProgressClient(ref.read(apiClientProvider)),
                cache: ScopedReadCache(
                  dao: ref.read(appPreferencesDaoProvider),
                  userScope: userScope,
                  workspaceScope: workspaceId,
                  fallbackTtl: ref.read(appCachePolicyProvider).cacheTtl,
                ),
                workspaceId: workspaceId,
              ),
        orchestrator: ref.read(taskOrchestratorProvider),
        activityMetrics: ref.read(runtimeActivityMetricsProvider),
        userScope: userScope,
        workspaceId: workspaceId,
        isCurrentScope: isCurrentScope,
      );
    });
