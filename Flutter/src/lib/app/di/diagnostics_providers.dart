import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/diagnostic_log_dao.dart';
import '../../core/diagnostics/diagnostic_export_service.dart';
import '../../core/diagnostics/diagnostic_logger.dart';
import '../lifecycle/app_activity_coordinator.dart';
import '../runtime/runtime_provider_module.dart';
import 'database_providers.dart';
import 'media_cache_providers.dart';

// resident-provider: Shares one account-scoped diagnostic log dao identity across dependent controllers.
final diagnosticLogDaoProvider = Provider<DiagnosticLogDao>((ref) {
  final runtime = ref.watch(databaseWorkerRuntimeProvider);
  return DiagnosticLogDao(
    ref.watch(appDatabaseProvider),
    worker: runtime,
    writeQueue: runtime.writeQueue,
  );
});

// resident-provider: Preserves the diagnostic logger dependency identity across route changes.
final diagnosticLoggerProvider = Provider<DiagnosticLogger>((ref) {
  final activity = ref.watch(appActivityCoordinatorProvider.notifier);
  final logger = DiagnosticLogger(
    dao: ref.watch(diagnosticLogDaoProvider),
    flushInterval: const Duration(seconds: 1),
    canDeferFlush: () => activity.state.isForeground,
  );
  ref.listen<bool>(
    appActivityCoordinatorProvider.select(
      (coordinator) => coordinator.state.isForeground,
    ),
    (_, foreground) {
      if (foreground) return;
      try {
        logger.flush();
      } catch (_) {}
    },
  );
  ref.onDispose(logger.dispose);
  return logger;
});

// resident-provider: Shares one diagnostic export service dependency for the full account session.
final diagnosticExportServiceProvider = Provider<DiagnosticExportService>((
  ref,
) {
  return DiagnosticExportService(
    dao: ref.watch(diagnosticLogDaoProvider),
    performanceSnapshot: () {
      final compressed = ref.read(resourceImageCacheProvider);
      return ref
          .read(appPerformanceRuntimeProvider)
          .capture(
            compressedImageCache: <String, Object?>{
              'available': true,
              'currentEntries': compressed.memoryEntryCount,
              'currentBytes': compressed.memoryBytes,
              'maximumBytes': compressed.memoryLimitBytes,
              'diskMaximumBytes': compressed.diskLimitBytes,
            },
          );
    },
  );
});
