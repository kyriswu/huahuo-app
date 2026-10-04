import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/workspace/data/workspace_recovery_repository.dart';
import '../bootstrap/core_provider_module.dart';

final workspaceRecoveryRepositoryProvider =
    Provider<WorkspaceRecoveryRepository>((ref) {
      return WorkspaceRecoveryRepository(
        apiClient: ref.watch(apiClientProvider),
      );
    });
