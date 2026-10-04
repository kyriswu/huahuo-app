import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/data/authenticated_resource_image_cache.dart';
import '../../features/chat/data/chat_api.dart';
import '../bootstrap/core_provider_module.dart';

// resident-provider: Shares one account-scoped resource image cache identity across dependent controllers.
final resourceImageCacheProvider = Provider<AuthenticatedResourceImageCache>((
  ref,
) {
  final workspaceId = ref.watch(
    sessionStoreProvider.select((store) => store.state.workspace?.workspaceId),
  );
  final cache = AuthenticatedResourceImageCache(
    playbackClient: ChatImagePlaybackClient(ref.watch(apiClientProvider)),
    userScope: ref.watch(authenticatedUserDataScopeProvider),
    workspaceScope: workspaceId ?? 'workspace-unavailable',
  );
  ref.onDispose(cache.dispose);
  return cache;
});
