import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/database/app_preferences_dao.dart';
import '../runtime/database_worker_runtime.dart';
import '../runtime/runtime_provider_module.dart';

// resident-provider: Shares one account-scoped local database snapshot store identity across dependent controllers.
final localDatabaseSnapshotStoreProvider =
    Provider<LocalDatabaseSnapshotStore?>((ref) {
      return null;
    });

// resident-provider: Preserves the app database dependency identity across route changes.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final runtime = ref.watch(databaseWorkerRuntimeProvider);
  final useWorker = runtime.configured;
  // performance-rfc: database-worker-persistence
  return AppDatabase(
    snapshotStore: ref.watch(localDatabaseSnapshotStoreProvider),
    metrics: ref.watch(databaseMetricsProvider),
    writeWorker: useWorker ? runtime : null,
    writeQueue: useWorker ? runtime.writeQueue : null,
  );
});

// resident-provider: Preserves the database worker runtime dependency identity across route changes.
final databaseWorkerRuntimeProvider = Provider<DatabaseWorkerRuntime>((ref) {
  final runtime = DatabaseWorkerRuntime(
    snapshotStore: ref.watch(localDatabaseSnapshotStoreProvider),
    enabled: ref.watch(
      performanceFeatureFlagsProvider.select(
        (flags) => flags.databaseWorkerEnabled,
      ),
    ),
    metrics: ref.watch(databaseMetricsProvider),
  );
  ref.onDispose(() {
    unawaited(() async {
      try {
        await runtime.dispose();
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'huahuo database runtime',
            context: ErrorDescription(
              'while disposing the database worker runtime',
            ),
          ),
        );
      }
    }());
  });
  return runtime;
});

// resident-provider: Shares one account-scoped app preferences dao identity across dependent controllers.
final appPreferencesDaoProvider = Provider<AppPreferencesDao>((ref) {
  final runtime = ref.watch(databaseWorkerRuntimeProvider);
  return AppPreferencesDao(
    ref.watch(appDatabaseProvider),
    worker: runtime,
    writeQueue: runtime.writeQueue,
  );
});
