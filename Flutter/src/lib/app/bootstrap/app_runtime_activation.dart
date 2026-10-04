import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/database_providers.dart';
import '../di/auth_providers.dart';
import '../../features/book_work/application/masterpiece_providers.dart';
import '../lifecycle/app_activity_coordinator.dart';
import '../runtime/database_worker_runtime.dart';
import 'app_bootstrap_controller.dart';
import 'push_runtime_activation.dart';
import 'recovery_runtime_activation.dart';

/// Starts process-wide runtimes after the provider graph is available.
final class AppRuntimeActivation extends StatelessWidget {
  const AppRuntimeActivation({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DatabaseWorkerActivation(
      runtimeProvider: databaseWorkerRuntimeProvider,
      foregroundProvider: appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.canRunForegroundWork,
      ),
      child: PushRuntimeActivation(
        child: RecoveryRuntimeActivation(
          child: _MasterpieceRuntimeActivation(child: child),
        ),
      ),
    );
  }
}

class _MasterpieceRuntimeActivation extends ConsumerWidget {
  const _MasterpieceRuntimeActivation({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(
      appBootstrapControllerProvider.select(
        (controller) => controller.state.status == AppBootstrapStatus.ready,
      ),
    );
    if (ready) ref.watch(masterpieceControllerProvider.select((_) => true));
    return child;
  }
}
