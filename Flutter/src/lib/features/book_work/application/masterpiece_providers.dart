import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/auth/session_store.dart';
import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../ui_v3/application/knowledge_library_controller.dart';
import '../data/masterpiece_generation_repository.dart';
import '../data/masterpiece_repository.dart';
import 'masterpiece_controller.dart';
import 'masterpiece_generation_controller.dart';

final masterpieceGenerationStoreProvider =
    ChangeNotifierProvider.autoDispose<PersistentMasterpieceGenerationStore?>((
      ref,
    ) {
      final identity = ref.watch(
        sessionStoreProvider.select((store) {
          final state = store.state;
          return state.authState == SessionAuthState.authenticated
              ? (state.user?.userId, state.workspace?.workspaceId)
              : (null, null);
        }),
      );
      final userId = identity.$1;
      final workspaceId = identity.$2;
      if (userId == null || workspaceId == null) return null;
      return PersistentMasterpieceGenerationStore(
        ref.watch(appPreferencesDaoProvider),
        '$userId\u0000$workspaceId',
      );
    });

final masterpieceControllerProvider =
    ChangeNotifierProvider.autoDispose<MasterpieceController>((ref) {
      final identity = ref.watch(
        sessionStoreProvider.select((store) {
          final state = store.state;
          return state.authState == SessionAuthState.authenticated
              ? (state.user?.userId, state.workspace?.workspaceId)
              : (null, null);
        }),
      );
      final userId = identity.$1;
      final workspaceId = identity.$2;
      if (userId == null || workspaceId == null) {
        return MasterpieceController.signedOut();
      }
      final controller = MasterpieceController(
        generation: MasterpieceGenerationController(
          remote: RemoteMasterpieceGenerationRepository(
            ref.watch(apiClientProvider),
            workspaceId,
          ),
          store: ref.watch(masterpieceGenerationStoreProvider.notifier)!,
          identity: '$userId\u0000$workspaceId',
          orchestrator: ref.watch(taskOrchestratorProvider),
        ),
        remote: RemoteMasterpieceRepository(
          ref.watch(apiClientProvider),
          workspaceId,
        ),
        store: PersistentMasterpieceDraftStore(
          ref.watch(appPreferencesDaoProvider),
          '$userId\u0000$workspaceId',
        ),
      );
      final activity = ref.read(appActivityCoordinatorProvider);
      controller.generation!.setForeground(activity.state.canRunForegroundWork);
      Timer? reconciliation;
      var requestedRevision = 0;
      var forceRequested = false;
      var reconciling = false;
      Future<void> reconcileChanges() async {
        if (reconciling) return;
        reconciling = true;
        try {
          var handledRevision = -1;
          while (activity.state.canRunForegroundWork &&
              handledRevision != requestedRevision) {
            handledRevision = requestedRevision;
            final force = forceRequested;
            forceRequested = false;
            await controller.refresh(force: force);
          }
        } finally {
          reconciling = false;
        }
      }

      void scheduleReconciliation({bool force = false}) {
        requestedRevision += 1;
        forceRequested = forceRequested || force;
        reconciliation?.cancel();
        if (!activity.state.canRunForegroundWork) return;
        reconciliation = Timer(const Duration(milliseconds: 500), () {
          unawaited(reconcileChanges());
        });
      }

      ref.listen(
        appActivityCoordinatorProvider.select(
          (value) => value.state.canRunForegroundWork,
        ),
        (_, canRunForegroundWork) {
          controller.generation!.setForeground(canRunForegroundWork);
          if (canRunForegroundWork) {
            scheduleReconciliation();
          } else {
            reconciliation?.cancel();
            unawaited(controller.flushDraft());
          }
        },
      );
      ref.listen(
        knowledgeLibraryControllerProvider.select(
          (value) => value.workspaceContentCursor,
        ),
        (_, __) => scheduleReconciliation(force: true),
      );
      scheduleReconciliation();
      ref.onDispose(() => reconciliation?.cancel());
      void Function()? release;
      void synchronizeRetention() {
        if (controller.draft?.intentLocked == true ||
            (controller.generation?.intent != null &&
                controller.generation?.intent?.canDiscard != true)) {
          release ??= ref.keepAlive().close;
        } else {
          release?.call();
          release = null;
        }
      }

      controller.addListener(synchronizeRetention);
      synchronizeRetention();
      ref.onDispose(() => controller.removeListener(synchronizeRetention));
      return controller;
    });
