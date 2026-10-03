// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/navigation/safe_navigation.dart';
import '../../shared/ui_v3/v3_components.dart';
import '../../shared/ui_v3/v3_glass_foundations.dart';
import '../bootstrap/app_providers.dart';
import '../di/chat_providers.dart';
import '../../features/assets/data/asset_api.dart';
import '../../features/auth/presentation/auth_screen.dart';
import '../../features/auth/presentation/legal_document_page.dart';
import '../../features/chat/application/voice_message_controller.dart';
import '../../features/chat/domain/chat_models.dart';
import '../../features/onboarding/presentation/content_line_onboarding_page.dart';
import '../../features/onboarding/presentation/v3_first_launch_device_setup_page.dart';
import '../../features/onboarding/presentation/v3_initial_positioning_progress_page.dart';
import '../../features/recordings/application/recording_library_ui_controller.dart';
import '../../features/recordings/domain/recording_library.dart';
import '../../features/ui_v3/application/note_append_controller.dart';
import '../../features/ui_v3/application/knowledge_library_controller.dart';
import '../../features/ui_v3/domain/feed_item_models.dart';
import '../../features/ui_v3/domain/ui_v3_models.dart';
import '../../features/ui_v3/presentation/v3_account_profile_page.dart';
import '../../features/ui_v3/presentation/v3_activity_calendar_page.dart';
import '../../features/ui_v3/presentation/v3_aggregation_agent_chat_page.dart';
import '../../features/ui_v3/presentation/v3_feed_aggregation_task_page.dart';
import '../../features/ui_v3/presentation/v3_app_shell.dart';
import '../../features/ui_v3/presentation/v3_assets_page.dart';
import '../../features/ui_v3/presentation/v3_batch_transcription_page.dart';
import '../../features/ui_v3/presentation/v3_capture_pages.dart';
import '../../features/ui_v3/presentation/v3_chat_page.dart';
import '../../features/ui_v3/presentation/v3_creation_canvas_page.dart';
import '../../features/ui_v3/presentation/v3_creation_history_page.dart';
import '../../features/ui_v3/presentation/v3_digital_twin_page.dart';
import '../../features/ui_v3/presentation/v3_document_import_page.dart';
import '../../features/ui_v3/presentation/v3_feed_item_detail_page.dart';
import '../../features/ui_v3/presentation/v3_feed_search_page.dart';
import '../../features/ui_v3/presentation/v3_graph_fullscreen_page.dart';
import '../../features/ui_v3/presentation/v3_help_center_page.dart';
import '../../features/ui_v3/presentation/v3_internal_recording_page.dart';
import '../../features/ui_v3/presentation/v3_knowledge_library_page.dart';
import '../../features/ui_v3/presentation/v3_link_import_page.dart';
import '../../features/ui_v3/presentation/v3_local_recording_library_page.dart';
import '../../features/ui_v3/presentation/v3_meeting_capture_page.dart';
import '../../features/ui_v3/presentation/v3_my_assets_page.dart';
import '../../features/ui_v3/presentation/v3_note_append_page.dart';
import '../../features/ui_v3/presentation/v3_note_page.dart';
import '../../features/ui_v3/presentation/v3_notifications_page.dart';
import '../../features/ui_v3/presentation/v3_positioning_report_page.dart';
import '../../features/ui_v3/presentation/v3_profile_placeholder_pages.dart';
import '../../features/ui_v3/presentation/v3_profile_side_panel.dart';
import '../../features/ui_v3/presentation/v3_recording_card_control_page.dart';
import '../../features/ui_v3/presentation/v3_recording_card_detail_page.dart';
import '../../features/ui_v3/presentation/v3_recording_card_files_page.dart';
import '../../features/ui_v3/presentation/v3_recording_card_live_page.dart';
import '../../features/ui_v3/presentation/v3_transcription_detail_page.dart';
import '../../features/ui_v3/presentation/v3_voiceprint_page.dart';
import '../../features/ui_v3/presentation/v3_work_ai_task_page.dart';
import '../../features/ui_v3/presentation/v3_workbench_generated_page.dart';
import '../../features/ui_v3/presentation/v3_workbench_generating_page.dart';
import '../../features/ui_v3/presentation/v3_workbench_material_picker_page.dart';
import '../../features/ui_v3/presentation/v3_workbench_page.dart';
import 'app_route_paths.dart';
import 'route_parameter_parser.dart';

const appRouteExtraCodec = AppRouteExtraCodec();

final class AppRouteExtraCodec extends Codec<Object?, Object?> {
  const AppRouteExtraCodec();

  @override
  Converter<Object?, Object?> get decoder => const _AppRouteExtraDecoder();

  @override
  Converter<Object?, Object?> get encoder => const _AppRouteExtraEncoder();
}

final class _AppRouteExtraEncoder extends Converter<Object?, Object?> {
  const _AppRouteExtraEncoder();

  @override
  Object? convert(Object? input) {
    final canvasIntent = switch (input) {
      CanvasEntryIntent value => value,
      AssetCanvasSeed value => CanvasEntryIntent.asset(value),
      DailyTopicCanvasSeed value => CanvasEntryIntent.dailyTopic(value),
      AssistantReplyCanvasSeed value => CanvasEntryIntent.assistantReply(value),
      _ => null,
    };
    if (canvasIntent != null) {
      if (!canvasIntent.isValid) return null;
      return <String, Object?>{
        'schema': 'huahuo-route-extra',
        'version': 1,
        'kind': 'canvasEntryIntent',
        'payload': _encodeCanvasIntent(canvasIntent),
      };
    }
    if (input is Map<String, String>) {
      return <String, Object?>{
        'schema': 'huahuo-route-extra',
        'version': 1,
        'kind': 'stringMap',
        'payload': input,
      };
    }
    try {
      return <String, Object?>{
        'schema': 'huahuo-route-extra',
        'version': 1,
        'kind': 'json',
        'payload': jsonDecode(jsonEncode(input)),
      };
    } on JsonUnsupportedObjectError {
      return null;
    }
  }
}

final class _AppRouteExtraDecoder extends Converter<Object?, Object?> {
  const _AppRouteExtraDecoder();

  @override
  Object? convert(Object? input) {
    final envelope = _routeExtraMap(input);
    if (envelope == null ||
        envelope['schema'] != 'huahuo-route-extra' ||
        envelope['version'] != 1) {
      return null;
    }
    return switch (envelope['kind']) {
      'canvasEntryIntent' => _decodeCanvasIntent(envelope['payload']),
      'stringMap' => _decodeStringMap(envelope['payload']),
      'json' => envelope['payload'],
      _ => null,
    };
  }
}

Map<String, Object?> _encodeCanvasIntent(CanvasEntryIntent intent) =>
    switch (intent) {
      CanvasBlankEntryIntent() => const <String, Object?>{'type': 'blank'},
      CanvasDailyTopicEntryIntent(:final seed) => <String, Object?>{
        'type': 'dailyTopic',
        'seed': <String, Object?>{
          'recommendationId': seed.recommendationId,
          'topicId': seed.topicId,
          'title': seed.title,
          'briefMarkdown': seed.briefMarkdown,
          'sourceRefs': seed.sourceRefs
              .map(
                (sourceRef) => <String, Object?>{
                  'hotspotId': sourceRef.hotspotId,
                  'label': sourceRef.label,
                },
              )
              .toList(growable: false),
          'sourceRevisionId': seed.sourceRevisionId,
          'sourceHash': seed.sourceHash,
          'linkedReference': _encodeLinkedMaterial(seed.linkedReference),
        },
      },
      CanvasAssetEntryIntent(:final seed) => <String, Object?>{
        'type': 'asset',
        'seed': <String, Object?>{
          'assetId': seed.assetId,
          'title': seed.title,
          'stage': seed.stage.wireValue,
          'sourceMarkdown': seed.sourceMarkdown,
          'partRevisionId': seed.partRevisionId,
          'sourceHash': seed.sourceHash,
          'linkedReference': _encodeLinkedMaterial(seed.linkedReference),
          if (seed.initialSourceMode case final mode?)
            'initialSourceMode': mode.wireValue,
        },
      },
      CanvasExistingNoteEntryIntent(:final noteId) => <String, Object?>{
        'type': 'existingNote',
        'noteId': noteId,
      },
      CanvasHistoryEntryIntent(:final historyId) => <String, Object?>{
        'type': 'history',
        'historyId': historyId,
      },
      CanvasAssistantReplyEntryIntent(:final seed) => <String, Object?>{
        'type': 'assistantReply',
        'seed': <String, Object?>{
          'title': seed.title,
          'markdown': seed.markdown,
        },
      },
    };

Map<String, Object?>? _encodeLinkedMaterial(V3LinkedMaterialRef? reference) =>
    reference == null
    ? null
    : <String, Object?>{
        'id': reference.id,
        'source': reference.source.name,
        'title': reference.title,
        'summary': reference.summary,
      };

CanvasEntryIntent? _decodeCanvasIntent(Object? input) {
  final payload = _routeExtraMap(input);
  if (payload == null) return null;
  final intent = switch (payload['type']) {
    'blank' => const CanvasEntryIntent.blank(),
    'dailyTopic' => _decodeDailyTopicIntent(payload['seed']),
    'asset' => _decodeAssetIntent(payload['seed']),
    'existingNote' =>
      payload['noteId'] is String
          ? CanvasEntryIntent.existingNote(payload['noteId']! as String)
          : null,
    'history' =>
      payload['historyId'] is String
          ? CanvasEntryIntent.history(payload['historyId']! as String)
          : null,
    'assistantReply' => _decodeAssistantReplyIntent(payload['seed']),
    _ => null,
  };
  return intent?.isValid == true ? intent : null;
}

CanvasEntryIntent? _decodeAssetIntent(Object? input) {
  final seedPayload = _routeExtraMap(input);
  if (seedPayload == null ||
      seedPayload['assetId'] is! String ||
      seedPayload['title'] is! String ||
      seedPayload['stage'] is! String ||
      seedPayload['sourceMarkdown'] is! String ||
      seedPayload['partRevisionId'] is! String ||
      seedPayload['sourceHash'] is! String) {
    return null;
  }
  final stage = switch (seedPayload['stage']) {
    'raw' => AssetCanvasSourceStage.raw,
    'outline' => AssetCanvasSourceStage.outline,
    'germination' => AssetCanvasSourceStage.sprout,
    _ => null,
  };
  final initialSourceModeValue = seedPayload['initialSourceMode'];
  if (initialSourceModeValue != null && initialSourceModeValue is! String) {
    return null;
  }
  final initialSourceMode = AssetCanvasInitialSourceModeX.tryParse(
    initialSourceModeValue as String?,
  );
  final reference = _decodeLinkedMaterial(seedPayload['linkedReference']);
  if (stage == null ||
      reference == null ||
      (initialSourceModeValue != null && initialSourceMode == null)) {
    return null;
  }
  return CanvasEntryIntent.asset(
    AssetCanvasSeed(
      assetId: seedPayload['assetId']! as String,
      title: seedPayload['title']! as String,
      stage: stage,
      sourceMarkdown: seedPayload['sourceMarkdown']! as String,
      partRevisionId: seedPayload['partRevisionId']! as String,
      sourceHash: seedPayload['sourceHash']! as String,
      linkedReference: reference,
      initialSourceMode: initialSourceMode,
    ),
  );
}

CanvasEntryIntent? _decodeDailyTopicIntent(Object? input) {
  final seedPayload = _routeExtraMap(input);
  if (seedPayload == null ||
      seedPayload['recommendationId'] is! String ||
      seedPayload['topicId'] is! String ||
      seedPayload['title'] is! String ||
      seedPayload['briefMarkdown'] is! String ||
      seedPayload['sourceRefs'] is! List<Object?> ||
      seedPayload['sourceHash'] is! String ||
      (seedPayload['sourceRevisionId'] != null &&
          seedPayload['sourceRevisionId'] is! String)) {
    return null;
  }
  final sourceRefs = <DailyTopicCanvasSourceRef>[];
  for (final encodedRef in seedPayload['sourceRefs']! as List<Object?>) {
    final sourceRef = _routeExtraMap(encodedRef);
    if (sourceRef == null ||
        sourceRef['hotspotId'] is! String ||
        (sourceRef['label'] != null && sourceRef['label'] is! String)) {
      return null;
    }
    sourceRefs.add(
      DailyTopicCanvasSourceRef(
        hotspotId: sourceRef['hotspotId']! as String,
        label: sourceRef['label'] as String?,
      ),
    );
  }
  final linkedReferencePayload = seedPayload['linkedReference'];
  final linkedReference = linkedReferencePayload == null
      ? null
      : _decodeLinkedMaterial(linkedReferencePayload);
  if (linkedReferencePayload != null && linkedReference == null) return null;
  return CanvasEntryIntent.dailyTopic(
    DailyTopicCanvasSeed(
      recommendationId: seedPayload['recommendationId']! as String,
      topicId: seedPayload['topicId']! as String,
      title: seedPayload['title']! as String,
      briefMarkdown: seedPayload['briefMarkdown']! as String,
      sourceRefs: sourceRefs,
      sourceRevisionId: seedPayload['sourceRevisionId'] as String?,
      sourceHash: seedPayload['sourceHash']! as String,
      linkedReference: linkedReference,
    ),
  );
}

CanvasEntryIntent? _decodeAssistantReplyIntent(Object? input) {
  final seedPayload = _routeExtraMap(input);
  if (seedPayload == null ||
      seedPayload['title'] is! String ||
      seedPayload['markdown'] is! String) {
    return null;
  }
  return CanvasEntryIntent.assistantReply(
    AssistantReplyCanvasSeed(
      title: seedPayload['title']! as String,
      markdown: seedPayload['markdown']! as String,
    ),
  );
}

V3LinkedMaterialRef? _decodeLinkedMaterial(Object? input) {
  final payload = _routeExtraMap(input);
  if (payload == null ||
      payload['id'] is! String ||
      payload['source'] is! String ||
      payload['title'] is! String ||
      (payload['summary'] != null && payload['summary'] is! String)) {
    return null;
  }
  V3MaterialSource? source;
  for (final candidate in V3MaterialSource.values) {
    if (candidate.name == payload['source']) {
      source = candidate;
      break;
    }
  }
  if (source == null) return null;
  return V3LinkedMaterialRef(
    id: payload['id']! as String,
    source: source,
    title: payload['title']! as String,
    summary: payload['summary'] as String?,
  );
}

Map<String, String>? _decodeStringMap(Object? input) {
  final payload = _routeExtraMap(input);
  if (payload == null || payload.values.any((value) => value is! String)) {
    return null;
  }
  return payload.map((key, value) => MapEntry(key, value! as String));
}

String? _positioningReportTaskId(GoRouterState state) {
  final focusValues = state.uri.queryParametersAll['focus'];
  if (focusValues?.length != 1 || focusValues!.single != 'report') return null;
  final values = state.uri.queryParametersAll['taskId'];
  if (values?.length != 1) return null;
  final taskId = values!.single;
  return isSafeAgentRunIdentifier(taskId) ? taskId : null;
}

Map<String, Object?>? _routeExtraMap(Object? input) {
  if (input is! Map<Object?, Object?> ||
      input.keys.any((key) => key is! String)) {
    return null;
  }
  return <String, Object?>{
    for (final entry in input.entries) entry.key! as String: entry.value,
  };
}

typedef AppRouteBuilder =
    Widget Function(BuildContext context, GoRouterState state);

List<RouteBase> buildAppRoutes({
  required AppRouteBuilder splashBuilder,
  required AppRouteBuilder restoreFailedBuilder,
  required AppRouteBuilder workspaceRetryBuilder,
}) {
  return <RouteBase>[
    GoRoute(path: AppRoutePaths.splash, builder: splashBuilder),
    GoRoute(path: AppRoutePaths.restoreFailed, builder: restoreFailedBuilder),
    GoRoute(
      path: AppRoutePaths.auth,
      builder: (context, state) => const AuthScreen(),
    ),
    GoRoute(
      path: '/legal/user-agreement',
      builder: (context, state) =>
          const LegalDocumentPage(kind: LegalDocumentKind.userAgreement),
    ),
    GoRoute(
      path: '/legal/privacy-policy',
      builder: (context, state) =>
          const LegalDocumentPage(kind: LegalDocumentKind.privacyPolicy),
    ),
    GoRoute(
      path: '/help',
      builder: (context, state) => const V3HelpCenterPage(),
    ),
    GoRoute(
      path: '/help/article/:articleId',
      builder: (context, state) =>
          V3HelpArticlePage(articleId: state.pathParameters['articleId'] ?? ''),
    ),
    GoRoute(
      path: '/help/customer-service',
      builder: (context, state) => const V3CustomerServicePage(),
    ),
    GoRoute(path: '/workspace-retry', builder: workspaceRetryBuilder),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const ContentLineOnboardingPage(),
    ),
    GoRoute(
      path: '/v3/positioning/progress',
      builder: (context, state) => const V3InitialPositioningProgressPage(),
    ),
    GoRoute(
      path: AppRoutePaths.legacyPostPositioningSetup,
      redirect: (context, state) => AppRoutePaths.firstLaunchDeviceSetup,
    ),
    GoRoute(
      path: AppRoutePaths.firstLaunchDeviceSetup,
      builder: (context, state) => const V3FirstLaunchDeviceSetupPage(),
    ),
    GoRoute(
      path: AppRoutePaths.home,
      redirect: (context, state) =>
          state.uri.queryParameters['aggregate'] == '1'
          ? V3FeedAggregationTaskPage.newTaskRoute
          : null,
      builder: (context, state) => V3AppShell(
        initialMode: _homeModeFromQuery(state.uri.queryParameters['mode']),
        initialFeedNotes: state.uri.queryParameters['view'] != 'graph',
      ),
    ),
    GoRoute(
      path: '/v3/workbench',
      redirect: (context, state) =>
          AppRoutePaths.homeForMode(AppRoutePaths.workbenchMode),
    ),
    GoRoute(
      path: '/v3/masterpiece',
      redirect: (context, state) =>
          AppRoutePaths.homeForMode(AppRoutePaths.masterpieceMode),
    ),
    GoRoute(
      path: AppRoutePaths.workbenchMaterialsRoute,
      redirect: _redirectInvalidWorkbenchPurpose,
      builder: (context, state) => V3WorkbenchMaterialPickerPage(
        purpose: workbenchPurposeFromRoute(
          state.pathParameters['purpose'] ?? '',
        )!,
      ),
    ),
    GoRoute(
      path: AppRoutePaths.workbenchGeneratingRoute,
      redirect: _redirectInvalidWorkbenchPurpose,
      builder: (context, state) => V3WorkbenchGeneratingPage(
        resumeOperationId: state.uri.queryParameters['operationId'],
        purpose: workbenchPurposeFromRoute(
          state.pathParameters['purpose'] ?? '',
        )!,
      ),
    ),
    GoRoute(
      path: AppRoutePaths.workbenchGeneratedRoute,
      redirect: _redirectInvalidWorkbenchPurpose,
      builder: (context, state) => V3WorkbenchGeneratedPage(
        operationId: state.uri.queryParameters['operationId'],
        purpose: workbenchPurposeFromRoute(
          state.pathParameters['purpose'] ?? '',
        )!,
      ),
    ),
    GoRoute(
      path: '/v3/workbench/canvas',
      builder: (context, state) {
        final library = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(knowledgeLibraryControllerProvider);
        final resolution = resolveCanvasRouteEntry(
          extra: state.extra,
          queryParametersAll: state.uri.queryParametersAll,
          sourceNoteForId: library.noteForId,
          sourceLookupReady: library.cacheRestoreSucceeded,
        );
        final deferredSource = resolution.deferredSource;
        return deferredSource == null
            ? V3CreationCanvasPage(
                entryIntent: resolution.intent!,
                recoverySessionId:
                    state.uri.queryParameters['recoverySessionId'],
                recoveryRunId: state.uri.queryParameters['recoveryRunId'],
              )
            : _DeferredLegacyCanvasRoute(source: deferredSource);
      },
    ),
    GoRoute(
      path: '/v3/workbench/recommendations/:recommendationId',
      builder: (context, state) => V3WorkbenchRecommendationPage(
        recommendationId: state.pathParameters['recommendationId'] ?? '',
        initialTopicId: state.uri.queryParameters['topicId'],
      ),
    ),
    GoRoute(
      path: '/v3/workbench/video-analysis',
      redirect: (context, state) => '/v3/feed/chat?skill=video-analysis',
    ),
    GoRoute(
      path: '/v3/workbench/video-analysis/running',
      redirect: (context, state) => '/v3/feed/chat?skill=video-analysis',
    ),
    GoRoute(
      path: '/v3/workbench/video-analysis/result',
      redirect: (context, state) => '/v3/feed/chat?skill=video-analysis',
    ),
    GoRoute(
      path: AppRoutePaths.positioningReport,
      builder: (context, state) {
        final taskId = _positioningReportTaskId(state);
        return V3PositioningReportPage(taskId: taskId);
      },
    ),
    GoRoute(
      path: AppRoutePaths.digitalTwin,
      redirect: (context, state) {
        final fileValues = state.uri.queryParametersAll['file'];
        if (fileValues?.length != 1 ||
            !const {
              'social_positioning',
              'positioning',
            }.contains(fileValues!.single)) {
          return null;
        }
        final taskId = _positioningReportTaskId(state);
        return taskId == null
            ? AppRoutePaths.positioningReport
            : AppRoutePaths.positioningReportForTask(taskId);
      },
      builder: (context, state) {
        return V3DigitalTwinPage(
          materialId: state.uri.queryParameters['materialId'],
          importTaskId: state.uri.queryParameters['importTaskId'],
        );
      },
    ),
    GoRoute(path: '/v3/feed', redirect: (context, state) => AppRoutePaths.home),
    GoRoute(
      path: AppRoutePaths.search,
      builder: (context, state) => const V3FeedSearchPage(),
    ),
    GoRoute(
      path: '/v3/feed/graph',
      pageBuilder: (context, state) => CustomTransitionPage<void>(
        key: state.pageKey,
        restorationId: state.pageKey.value,
        transitionDuration: V3MotionTokens.resolve(
          context,
          V3MotionTokens.routeEnter,
        ),
        reverseTransitionDuration: V3MotionTokens.resolve(
          context,
          V3MotionTokens.routeExit,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
        child: const V3GraphFullscreenPage(),
      ),
    ),
    GoRoute(
      path: '/v3/workbench/has-opinion',
      redirect: (context, state) {
        final assetId = routeCanvasTopicId(
          state.uri.queryParameters['feedItemId'],
        );
        return assetId == null
            ? AppRoutePaths.canvas
            : AppRoutePaths.canvasForAsset(assetId);
      },
    ),
    GoRoute(
      path: '/v3/workbench/no-opinion',
      redirect: (context, state) => AppRoutePaths.canvas,
    ),
    GoRoute(
      path: '/v3/workbench/tasks/:taskId',
      builder: (context, state) =>
          V3WorkAiTaskPage(taskId: state.pathParameters['taskId'] ?? ''),
    ),
    GoRoute(
      path: '/v3/workbench/create/:mode',
      redirect: (context, state) => AppRoutePaths.canvas,
    ),
    GoRoute(
      path: '/v3/workbench/result/:mode',
      redirect: (context, state) => AppRoutePaths.canvas,
    ),
    GoRoute(
      path: '/v3/workbench/history',
      builder: (context, state) => const V3CreationHistoryPage(),
    ),
    GoRoute(
      path: AppRoutePaths.notifications,
      pageBuilder: (context, state) => CustomTransitionPage<void>(
        key: state.pageKey,
        restorationId: state.pageKey.value,
        opaque: false,
        barrierColor: const Color(0x52000000),
        barrierDismissible: true,
        child: const V3NotificationsPage(),
        transitionDuration: V3MotionTokens.resolve(
          context,
          V3MotionTokens.routeEnter,
        ),
        reverseTransitionDuration: V3MotionTokens.resolve(
          context,
          V3MotionTokens.routeExit,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    ),
    GoRoute(
      path: AppRoutePaths.assets,
      builder: (context, state) {
        final label = state.uri.queryParameters['label'];
        final focus = routeAssetFocus(state.uri.queryParameters['focus']);
        if (focus != null) {
          return V3AssetsPage(focus: focus);
        }
        return V3MyAssetsPage(
          initialSection: v3MyAssetsSectionFromRouteParameter(label),
        );
      },
    ),
    GoRoute(
      path: AppRoutePaths.photoAlbumPreviewRoute,
      redirect: (context, state) =>
          routePhotoAlbumResourceId(state.pathParameters['resourceId']) == null
          ? AppRoutePaths.assetsMedia
          : null,
      builder: (context, state) => V3PhotoAlbumPreviewPage(
        resourceId: routePhotoAlbumResourceId(
          state.pathParameters['resourceId'],
        )!,
      ),
    ),
    GoRoute(
      path: '/v3/assets/content-line/:contentLineId',
      builder: (context, state) => V3StructuredAssetDetailPage(
        assetType: EditableAssetType.contentLine,
        assetId: state.pathParameters['contentLineId'] ?? '',
      ),
    ),
    GoRoute(
      path: AppRoutePaths.recordSource,
      pageBuilder: (context, state) => _materialImportOverlayPage(
        context,
        state,
        const V3RecordSourcePage(),
      ),
    ),
    GoRoute(
      path: AppRoutePaths.meetingCapture,
      builder: (context, state) => V3MeetingCapturePage(
        freshEntry: state.uri.queryParameters['entry'] == 'fresh',
        distillToDigitalTwin:
            state.uri.queryParameters['distillToDigitalTwin'] == '1',
        initialDraftId: state.uri.queryParameters['draftId'],
      ),
    ),
    GoRoute(
      path: AppRoutePaths.internalRecording,
      builder: (context, state) => V3InternalRecordingPage(
        freshEntry: state.uri.queryParameters['entry'] == 'fresh',
        distillToDigitalTwin:
            state.uri.queryParameters['distillToDigitalTwin'] == '1',
        initialDraftId: state.uri.queryParameters['draftId'],
      ),
    ),
    GoRoute(
      path: AppRoutePaths.linkImport,
      pageBuilder: (context, state) => _materialImportOverlayPage(
        context,
        state,
        V3LinkImportPage(
          freshEntry: state.uri.queryParameters['entry'] == 'fresh',
          initialDraftId: state.uri.queryParameters['draftId'],
        ),
      ),
    ),
    GoRoute(
      path: '/v3/feed/import',
      redirect: (context, state) => AppRoutePaths.documentImport,
    ),
    GoRoute(
      path: AppRoutePaths.documentImport,
      pageBuilder: (context, state) => _materialImportOverlayPage(
        context,
        state,
        V3DocumentImportPage(
          freshEntry: state.uri.queryParameters['entry'] == 'fresh',
          initialTaskId: state.uri.queryParameters['taskId'],
          digitalTwinEntry: state.uri.queryParameters['digitalTwin'] == '1',
        ),
      ),
    ),
    GoRoute(
      path: '/v3/feed/import/local-recordings',
      redirect: (context, state) => AppRoutePaths.documentImport,
    ),
    GoRoute(
      path: AppRoutePaths.mediaImport,
      pageBuilder: (context, state) => _materialImportOverlayPage(
        context,
        state,
        V3DocumentImportPage(
          mode: V3DocumentImportMode.media,
          freshEntry: state.uri.queryParameters['entry'] == 'fresh',
        ),
      ),
    ),
    GoRoute(
      path: '/v3/feed/note',
      pageBuilder: (context, state) {
        final draft = state.extra;
        return _platformOrSheetExpansionPage(
          context,
          state,
          V3NotePage(
            initialTitle: draft is Map<String, String>
                ? draft['title'] ?? ''
                : '',
            initialBody: draft is Map<String, String>
                ? draft['body'] ?? ''
                : '',
          ),
        );
      },
    ),
    GoRoute(
      path: '/v3/feed/note/:itemId',
      builder: (context, state) =>
          V3NotePage(itemId: state.pathParameters['itemId']),
    ),
    GoRoute(
      path: '/v3/feed/upload',
      redirect: (context, state) => AppRoutePaths.documentImport,
    ),
    GoRoute(
      path: '/v3/feed/upload/parsing',
      redirect: (context, state) => AppRoutePaths.documentImport,
    ),
    GoRoute(
      path: '/v3/feed/monologue',
      pageBuilder: (context, state) => _platformOrSheetExpansionPage(
        context,
        state,
        const V3MonologuePage(),
      ),
    ),
    GoRoute(
      path: '/v3/feed/monologue/history',
      builder: (context, state) => const V3MonologueHistoryPage(),
    ),
    GoRoute(
      path: '/v3/feed/aggregation-agent/:sessionId',
      builder: (context, state) => V3AggregationAgentChatPage(
        sessionId: state.pathParameters['sessionId'] ?? '',
      ),
    ),
    GoRoute(
      path: '/v3/feed/aggregation/new',
      builder: (context, state) => V3FeedAggregationTaskPage(
        key: ValueKey(state.pageKey),
        taskId: '',
        startNew: true,
      ),
    ),
    GoRoute(
      path: '/v3/feed/aggregation',
      builder: (context, state) => V3FeedAggregationTaskPage(
        key: ValueKey(state.uri.toString()),
        taskId: state.uri.queryParameters['taskId'] ?? '',
      ),
    ),
    GoRoute(
      path: '/v3/feed/chat',
      redirect: (context, state) {
        if (state.uri.queryParametersAll.containsKey('threadId')) return null;
        return state.uri.queryParameters['skill'] ==
                    WorkbenchChatSkill.positioningLv1.routeValue ||
                state.uri.queryParameters['agentProfileId'] == 'positioning_lv1'
            ? '/onboarding'
            : null;
      },
      pageBuilder: (context, state) {
        final exactEntry = _ExactChatRouteContract.fromUri(state.uri);
        if (exactEntry.failure case final failure?) {
          return _platformOrSheetExpansionPage(
            context,
            state,
            _ChatRouteContractFailurePage(failure: failure),
          );
        }
        final requestedConversationPurpose = exactEntry.requested
            ? exactEntry.purpose!
            : ChatConversationPurpose.fromRoute(
                state.uri.queryParameters['purpose'],
              );
        final threadId = exactEntry.threadId;
        final requestedWindowId = state.uri.queryParameters['window'];
        final windowId = isSafeChatIdentifier(requestedWindowId ?? '')
            ? requestedWindowId
            : null;
        final requestedContentLineId =
            state.uri.queryParameters['contentLineId'];
        final contentLineId = isSafeChatIdentifier(requestedContentLineId ?? '')
            ? requestedContentLineId
            : null;
        final requestedFeedItemId = state.uri.queryParameters['itemId'];
        final feedItemId = isSafeChatIdentifier(requestedFeedItemId ?? '')
            ? requestedFeedItemId
            : null;
        final workbenchContext = WorkbenchChatContext.fromRoute(
          skill: state.uri.queryParameters['skill'],
          materialIds: state.uri.queryParameters['materialIds'],
        );
        final autoAnalyzeMaterials =
            workbenchContext?.materialIds.isNotEmpty == true &&
            state.uri.queryParameters['analyzeAssets'] == '1';
        final initialPrompt = _boundedChatPrompt(
          state.uri.queryParameters['prompt'],
        );
        final autoSubmitInitialPrompt =
            state.uri.queryParameters['autoSend'] == '1';
        final isStartupGuideEntry =
            state.uri.queryParameters['startupGuide'] == '1';
        final isAgentAssistedCreationEntry =
            state.uri.queryParameters['entry'] ==
                agentAssistedCreationChatEntryRouteValue &&
            workbenchContext?.materialIds.isNotEmpty == true &&
            initialPrompt != null &&
            autoSubmitInitialPrompt;
        final hasExplicitOrdinaryEntry =
            state.uri.queryParametersAll.containsKey('ordinaryEntryKind') ||
            state.uri.queryParametersAll.containsKey('ordinaryEntryId');
        final ordinaryEntryKinds =
            state.uri.queryParametersAll['ordinaryEntryKind'];
        final ordinaryEntryIds =
            state.uri.queryParametersAll['ordinaryEntryId'];
        final parsedOrdinaryEntryPoint =
            ordinaryEntryKinds?.length == 1 && ordinaryEntryIds?.length == 1
            ? OrdinaryChatEntryPoint.tryParse(
                kind: ordinaryEntryKinds!.single,
                entryId: ordinaryEntryIds!.single,
              )
            : null;
        final hasThoughtGraphEntry =
            state.uri.queryParameters['entry'] ==
            thoughtGraphChatEntryRouteValue;
        final hasFeedItemParameter = state.uri.queryParametersAll.containsKey(
          'itemId',
        );
        final hasContentLineParameter = state.uri.queryParametersAll
            .containsKey('contentLineId');
        final isValidThoughtGraphEntry =
            hasThoughtGraphEntry &&
            !hasExplicitOrdinaryEntry &&
            !hasFeedItemParameter &&
            !hasContentLineParameter &&
            workbenchContext == null;
        final explicitOrdinaryEntryMatchesRoute =
            parsedOrdinaryEntryPoint != null &&
            switch (parsedOrdinaryEntryPoint.kind) {
              OrdinaryChatEntryKind.asset =>
                !hasFeedItemParameter ||
                    feedItemId == parsedOrdinaryEntryPoint.entryId,
              OrdinaryChatEntryKind.dailyRecommendation =>
                !hasFeedItemParameter || feedItemId != null,
              OrdinaryChatEntryKind.thoughtGraph =>
                !hasFeedItemParameter &&
                    !hasContentLineParameter &&
                    workbenchContext == null,
            };
        final hasInvalidOrdinaryEntryRoute =
            (hasThoughtGraphEntry && !isValidThoughtGraphEntry) ||
            (hasExplicitOrdinaryEntry && !explicitOrdinaryEntryMatchesRoute) ||
            (hasFeedItemParameter && feedItemId == null);
        final OrdinaryChatEntryPoint? requestedOrdinaryEntryPoint;
        if (hasThoughtGraphEntry) {
          requestedOrdinaryEntryPoint = isValidThoughtGraphEntry
              ? OrdinaryChatEntryPoint.thoughtGraph
              : null;
        } else if (hasExplicitOrdinaryEntry) {
          requestedOrdinaryEntryPoint = explicitOrdinaryEntryMatchesRoute
              ? parsedOrdinaryEntryPoint
              : null;
        } else if (feedItemId != null) {
          requestedOrdinaryEntryPoint = OrdinaryChatEntryPoint.asset(
            feedItemId,
          );
        } else {
          requestedOrdinaryEntryPoint = null;
        }
        final routeAgentProfileId = exactEntry.requested
            ? exactEntry.agentProfileId
            : knownPublicChatAgentProfileId(
                state.uri.queryParameters['agentProfileId'],
              );
        final routeProfileSkill = WorkbenchChatSkill.fromAgentProfileId(
          routeAgentProfileId,
        );
        final selectedAgentProfileId =
            agentProfileIdForWorkbenchSkill(workbenchContext?.skill) ??
            routeAgentProfileId;
        final conversationPurpose = resolveChatConversationPurposeForAgent(
          requestedPurpose: requestedConversationPurpose,
          agentProfileId: selectedAgentProfileId,
        );
        final initialAgentProfileId =
            selectedAgentProfileId ??
            (conversationPurpose == ChatConversationPurpose.deepPositioning
                ? 'positioning_lv2'
                : null);
        final ordinaryEntryPoint =
            requestedOrdinaryEntryPoint != null &&
                conversationPurpose == ChatConversationPurpose.general &&
                workbenchContext == null &&
                !isAgentAssistedCreationEntry &&
                (initialAgentProfileId == null ||
                    initialAgentProfileId == standardCreationChatAgentProfileId)
            ? requestedOrdinaryEntryPoint
            : null;
        final pageWorkbenchContext =
            workbenchContext ??
            (routeProfileSkill == null
                ? null
                : WorkbenchChatContext(
                    skill: routeProfileSkill,
                    materialIds: const <String>[],
                  ));
        final launchMode = resolveChatLaunchMode(
          hasExactThread: threadId != null,
          opensHistory: state.uri.queryParameters['history'] == '1',
          hasExplicitWindow: windowId != null,
          hasSourceContext:
              contentLineId != null ||
              feedItemId != null ||
              workbenchContext?.materialIds.isNotEmpty == true ||
              initialPrompt != null ||
              isStartupGuideEntry ||
              hasInvalidOrdinaryEntryRoute,
          hasAgentEntry:
              initialAgentProfileId != null ||
              conversationPurpose != ChatConversationPurpose.general,
          isThoughtGraphEntry: isValidThoughtGraphEntry,
        );
        final page = V3ChatPage(
          key: ValueKey<String>(
            'feed-chat-${windowId ?? state.uri.toString()}',
          ),
          contentLineId: contentLineId,
          feedItemId: feedItemId,
          windowId: windowId,
          threadId: threadId,
          dailyTopicTitle: state.uri.queryParameters['dailyTopicTitle'],
          initialPrompt: initialPrompt,
          autoSubmitInitialPrompt: autoSubmitInitialPrompt,
          isAgentAssistedCreationEntry: isAgentAssistedCreationEntry,
          ordinaryEntryPoint: ordinaryEntryPoint,
          showHistoryOnStart: launchMode == ChatLaunchMode.history,
          startupGuide: isStartupGuideEntry,
          launchMode: launchMode,
          conversationPurpose: conversationPurpose,
          workbenchContext: pageWorkbenchContext,
          autoAnalyzeMaterials: autoAnalyzeMaterials,
        );
        final requiresRouteScopedChatController =
            launchMode != ChatLaunchMode.resumeRecent;
        return _platformOrSheetExpansionPage(
          context,
          state,
          requiresRouteScopedChatController
              ? ProviderScope(
                  key: ValueKey<String>(
                    'feed-chat-scope-${windowId ?? state.uri.toString()}',
                  ),
                  overrides: [
                    if (conversationPurpose == ChatConversationPurpose.general)
                      feedAiChatControllerProvider.overrideWith(
                        (routeRef) => createFeedAiChatController(
                          routeRef,
                          conversationPurpose: conversationPurpose,
                          initialAgentProfileId: initialAgentProfileId,
                          browseAllAgentProfiles:
                              launchMode == ChatLaunchMode.history &&
                              selectedAgentProfileId == null,
                          bindAgentProfileFromThread:
                              launchMode == ChatLaunchMode.exactThread,
                        ),
                      )
                    else
                      deepPositioningChatControllerProvider.overrideWith(
                        (routeRef) => createDeepPositioningChatController(
                          routeRef,
                          initialAgentProfileId: initialAgentProfileId,
                          bindAgentProfileFromThread:
                              launchMode == ChatLaunchMode.exactThread,
                        ),
                      ),
                    feedAiVoiceMessageControllerProvider.overrideWith(
                      (routeRef) => createFeedAiVoiceMessageController(
                        routeRef,
                        conversationPurpose: conversationPurpose,
                      ),
                    ),
                  ],
                  child: page,
                )
              : page,
        );
      },
    ),
    GoRoute(
      path: '/v3/feed/transcription-preview',
      builder: (context, state) => const V3TranscriptionDonePage(),
    ),
    GoRoute(
      path: '/v3/feed/assets/:assetId',
      builder: (context, state) =>
          V3FeedItemDetailPage(itemId: state.pathParameters['assetId'] ?? ''),
    ),
    GoRoute(
      path: '/v3/feed/items/:itemId/append/:source',
      redirect: (context, state) {
        final itemId = state.pathParameters['itemId'] ?? '';
        final source = NoteAppendSourceX.fromRoute(
          state.pathParameters['source'] ?? '',
        );
        return source == null ? AppRoutePaths.feedItem(itemId) : null;
      },
      builder: (context, state) => V3NoteAppendPage(
        targetNoteId: state.pathParameters['itemId'] ?? '',
        source: NoteAppendSourceX.fromRoute(
          state.pathParameters['source'] ?? '',
        )!,
      ),
    ),
    GoRoute(
      path: '/v3/feed/items/:itemId',
      builder: (context, state) => V3FeedItemDetailPage(
        itemId: state.pathParameters['itemId'] ?? '',
        initialStage: switch (state.uri.queryParameters['stage']) {
          'summary' => V3ContentStage.summary,
          'sprout' => V3ContentStage.sprout,
          _ => V3ContentStage.raw,
        },
        initialSectionId: state.uri.queryParameters['section'],
      ),
    ),
    GoRoute(
      path: AppRoutePaths.transcriptionJobRoute,
      builder: (context, state) => V3TranscriptionJobPage(
        jobId: state.pathParameters['jobId'] ?? '',
        source: RecordingFileSource.fromRoute(
          state.uri.queryParameters['source'],
        ),
        destination: state.uri.queryParameters['destination'] == 'raw'
            ? V3ContentStage.raw
            : V3ContentStage.summary,
      ),
    ),
    GoRoute(
      path: AppRoutePaths.transcriptionDoneRoute,
      builder: (context, state) => V3TranscriptionDetailPage(
        recordingId: state.pathParameters['recordingId'] ?? '',
        origin: RecordingFileSource.fromRoute(
          state.uri.queryParameters['source'],
        ),
        destination: state.uri.queryParameters['destination'] == 'raw'
            ? V3ContentStage.raw
            : V3ContentStage.summary,
      ),
    ),
    GoRoute(
      path: '/v3/profile',
      builder: (context, state) => const V3ProfileHomePage(),
    ),
    GoRoute(
      path: '/v3/profile/calendar',
      builder: (context, state) => V3ActivityCalendarPage(
        initialSelectedDay: routeCalendarDate(
          state.uri.queryParameters['date'],
        ),
      ),
    ),
    GoRoute(
      path: AppRoutePaths.knowledge,
      redirect: (context, state) {
        final tab = state.uri.queryParameters['tab']?.trim().toLowerCase();
        if (tab == 'mine') return '/v3/profile/assets?page=created';
        if (tab == 'deposit' || tab == 'deposits') {
          return '/v3/profile/assets?page=deposited';
        }
        return null;
      },
      builder: (context, state) => V3KnowledgeLibraryPage(
        initialTab: v3KnowledgeLibraryTabFromRouteParameter(
          state.uri.queryParameters['tab'],
        ),
      ),
    ),
    GoRoute(
      path: AppRoutePaths.knowledgeChannelRoute,
      redirect: (context, state) =>
          routeKnowledgeChannel(state.pathParameters['channelId']) == null
          ? AppRoutePaths.knowledgeSquare
          : null,
      builder: (context, state) => V3KnowledgeChannelDetailPage(
        channelId: routeKnowledgeChannel(state.pathParameters['channelId'])!.id,
      ),
    ),
    GoRoute(
      path: AppRoutePaths.knowledgeWorld,
      redirect: (context, state) {
        final rawPublicationId = state.uri.queryParameters['publicationId'];
        final publicationId = routeKnowledgePublicationId(rawPublicationId);
        if (rawPublicationId != null && publicationId == null) {
          return AppRoutePaths.knowledgeSquare;
        }
        final rawQuery = state.uri.queryParameters['q'];
        if (rawQuery != null && routeKnowledgeWorldQuery(rawQuery) == null) {
          return AppRoutePaths.knowledgeWorldDetail(
            publicationId: publicationId,
          );
        }
        return null;
      },
      builder: (context, state) => V3RemoteKnowledgeWorldDetailPage(
        publicationId: routeKnowledgePublicationId(
          state.uri.queryParameters['publicationId'],
        ),
        query: routeKnowledgeWorldQuery(state.uri.queryParameters['q']) ?? '',
      ),
    ),
    GoRoute(
      path: '/v3/profile/deposits',
      redirect: (context, state) => '/v3/profile/assets?page=deposited',
    ),
    GoRoute(
      path: '/v3/profile/assets',
      builder: (context, state) => V3MyAssetsPage(
        initialSection: v3MyAssetsSectionFromRouteParameter(
          state.uri.queryParameters['page'],
        ),
      ),
    ),
    GoRoute(
      path: '/v3/profile/account',
      builder: (context, state) => const V3AccountProfilePage(),
    ),
    GoRoute(
      path: '/v3/profile/recordings',
      builder: (context, state) => const V3PersonalRecordingLibraryPage(),
    ),
    GoRoute(
      path: '/v3/profile/voiceprint',
      builder: (context, state) => const V3VoiceprintPage(),
    ),
    GoRoute(
      path: '/v3/profile/voiceprint/enroll',
      builder: (context, state) => V3VoiceprintPage(
        enrollmentOnly: true,
        startupJourney: state.uri.queryParameters['startup'] == '1',
        initialProfileName: state.uri.queryParameters['name'],
        targetProfileId: state.uri.queryParameters['profileId'],
      ),
    ),
    GoRoute(
      path: '/v3/profile/academy',
      builder: (context, state) => const V3AcademyPlaceholderPage(),
    ),
    GoRoute(
      path: '/v3/profile/:section',
      redirect: (context, state) => state.pathParameters['section'] == '回收站'
          ? '/v3/profile/account'
          : null,
      pageBuilder: (context, state) => MaterialPage<void>(
        key: state.pageKey,
        restorationId: state.pageKey.value,
        child: V3ProfilePlaceholderPage(
          section: state.pathParameters['section'] ?? '设置',
        ),
      ),
    ),
    GoRoute(
      path: AppRoutePaths.recordingCardControl,
      builder: (context, state) => V3RecordingCardControlPage(
        initialWidgetAction: RecordingCardWidgetAction.fromRoute(
          state.uri.queryParameters['widgetAction'],
        ),
        widgetActionToken: state.uri.queryParameters['widgetToken'],
        widgetSnapshotEpochMs: int.tryParse(
          state.uri.queryParameters['widgetRevision'] ?? '',
        ),
      ),
    ),
    GoRoute(
      path: '/v3/recording-card/details',
      builder: (context, state) => V3RecordingCardDetailPage(
        focusLocalStorage:
            state.uri.queryParameters['focus'] == 'local-storage',
      ),
    ),
    GoRoute(
      path: AppRoutePaths.recordingCardFiles,
      builder: (context, state) => const V3RecordingCardFilesPage(),
    ),
    GoRoute(
      path: AppRoutePaths.transcriptionBatchRoute,
      builder: (context, state) => Consumer(
        builder: (context, ref, child) => V3BatchTranscriptionPage(
          batchId: state.pathParameters['batchId'] ?? '',
          focusItemId: state.uri.queryParameters['focusItem'],
          controller: ref.watch(recordingBatchTranscriptionControllerProvider),
          uploadController: ref.watch(
            recordingUploadControllerProvider.notifier,
          ),
        ),
      ),
    ),
    GoRoute(
      path: '/v3/recording-card',
      builder: (context, state) => V3RecordingCardLivePage(
        initialTab: V3RecordingLibraryTab.fromRoute(
          state.uri.queryParameters['tab'],
        ),
        focusLibrary: state.uri.queryParameters['focus'] == 'library',
      ),
    ),
  ];
}

enum CanvasLegacyRouteSourceKind { asset, dailyTopic }

@immutable
final class CanvasLegacyRouteSourceDescriptor {
  const CanvasLegacyRouteSourceDescriptor({
    required this.kind,
    required this.sourceId,
    this.topicTitle,
  });

  final CanvasLegacyRouteSourceKind kind;
  final String sourceId;
  final String? topicTitle;
}

@immutable
final class CanvasRouteEntryResolution {
  const CanvasRouteEntryResolution.ready(this.intent) : deferredSource = null;

  const CanvasRouteEntryResolution.deferred(this.deferredSource)
    : intent = null;

  final CanvasEntryIntent? intent;
  final CanvasLegacyRouteSourceDescriptor? deferredSource;
}

@visibleForTesting
CanvasRouteEntryResolution resolveCanvasRouteEntry({
  required Object? extra,
  required Map<String, List<String>> queryParametersAll,
  required bool sourceLookupReady,
  V3FeedItem? Function(String id)? sourceNoteForId,
}) {
  if (!sourceLookupReady && extra == null) {
    final deferred = _deferredLegacyCanvasSource(queryParametersAll);
    if (deferred != null) {
      return CanvasRouteEntryResolution.deferred(deferred);
    }
  }
  return CanvasRouteEntryResolution.ready(
    resolveCanvasEntryIntent(
      extra: extra,
      queryParametersAll: queryParametersAll,
      sourceNoteForId: sourceNoteForId,
    ),
  );
}

CanvasLegacyRouteSourceDescriptor? _deferredLegacyCanvasSource(
  Map<String, List<String>> queryParametersAll,
) {
  const identityKeys = <String>{
    'importAssetId',
    'initialNoteId',
    'historyId',
    'topicId',
  };
  final presentIdentityKeys = identityKeys
      .where(queryParametersAll.containsKey)
      .toList(growable: false);
  if (presentIdentityKeys.length != 1) return null;
  final identityKey = presentIdentityKeys.single;
  if (identityKey != 'importAssetId' && identityKey != 'topicId') return null;
  final identity = routeCanvasTopicId(
    _singleCanvasQueryValue(queryParametersAll, identityKey),
  );
  if (identity == null) return null;
  if (identityKey == 'importAssetId') {
    return CanvasLegacyRouteSourceDescriptor(
      kind: CanvasLegacyRouteSourceKind.asset,
      sourceId: identity,
    );
  }
  final topicTitleValues = queryParametersAll['topicTitle'];
  if (topicTitleValues != null && topicTitleValues.length != 1) return null;
  final rawTopicTitle = _singleCanvasQueryValue(
    queryParametersAll,
    'topicTitle',
  );
  final topicTitle = routeCanvasTopicTitle(rawTopicTitle);
  if (topicTitleValues != null &&
      (topicTitle == null || topicTitle != rawTopicTitle?.trim())) {
    return null;
  }
  return CanvasLegacyRouteSourceDescriptor(
    kind: CanvasLegacyRouteSourceKind.dailyTopic,
    sourceId: identity,
    topicTitle: topicTitle,
  );
}

@visibleForTesting
CanvasEntryIntent resolveCanvasEntryIntent({
  required Object? extra,
  required Map<String, List<String>> queryParametersAll,
  V3FeedItem? Function(String id)? sourceNoteForId,
}) {
  const blank = CanvasEntryIntent.blank();
  const identityKeys = <String>{
    'importAssetId',
    'initialNoteId',
    'historyId',
    'topicId',
  };
  final presentIdentityKeys = identityKeys
      .where(queryParametersAll.containsKey)
      .toList(growable: false);
  if (presentIdentityKeys.any((key) => queryParametersAll[key]?.length != 1)) {
    return blank;
  }

  if (extra != null) {
    final intent = switch (extra) {
      CanvasEntryIntent value => value,
      AssetCanvasSeed value => CanvasEntryIntent.asset(value),
      DailyTopicCanvasSeed value => CanvasEntryIntent.dailyTopic(value),
      AssistantReplyCanvasSeed value => CanvasEntryIntent.assistantReply(value),
      _ => null,
    };
    if (intent == null || !intent.isValid) return blank;
    if (presentIdentityKeys.isEmpty) return intent;
    if (presentIdentityKeys.length != 1 ||
        !_canvasIntentMatchesQuery(
          intent,
          presentIdentityKeys.single,
          queryParametersAll,
        )) {
      return blank;
    }
    return intent;
  }

  if (presentIdentityKeys.isEmpty) return blank;
  if (presentIdentityKeys.length != 1) return blank;
  final identityKey = presentIdentityKeys.single;
  final identity = routeCanvasTopicId(
    _singleCanvasQueryValue(queryParametersAll, identityKey),
  );
  if (identity == null) return blank;
  final topicTitleValues = queryParametersAll['topicTitle'];
  if (identityKey == 'topicId' &&
      topicTitleValues != null &&
      topicTitleValues.length != 1) {
    return blank;
  }
  final rawTopicTitle = _singleCanvasQueryValue(
    queryParametersAll,
    'topicTitle',
  );
  final topicTitle = routeCanvasTopicTitle(rawTopicTitle);
  if (identityKey == 'topicId' &&
      topicTitleValues != null &&
      (topicTitle == null || topicTitle != rawTopicTitle?.trim())) {
    return blank;
  }
  final intent = switch (identityKey) {
    'importAssetId' => _legacyAssetCanvasIntent(
      identity,
      sourceNoteForId: sourceNoteForId,
    ),
    'initialNoteId' => CanvasEntryIntent.existingNote(identity),
    'historyId' => CanvasEntryIntent.history(identity),
    'topicId' => _legacyTopicCanvasIntent(
      identity,
      topicTitle: topicTitle,
      sourceNoteForId: sourceNoteForId,
    ),
    _ => blank,
  };
  return intent.isValid ? intent : blank;
}

bool _canvasIntentMatchesQuery(
  CanvasEntryIntent intent,
  String identityKey,
  Map<String, List<String>> queryParametersAll,
) {
  final identity = routeCanvasTopicId(
    _singleCanvasQueryValue(queryParametersAll, identityKey),
  );
  if (identity == null) return false;
  return switch (intent) {
    CanvasAssetEntryIntent value =>
      identityKey == 'importAssetId' && value.assetId.trim() == identity,
    CanvasExistingNoteEntryIntent value =>
      identityKey == 'initialNoteId' && value.noteId.trim() == identity,
    CanvasHistoryEntryIntent value =>
      identityKey == 'historyId' && value.historyId.trim() == identity,
    CanvasDailyTopicEntryIntent value =>
      identityKey == 'topicId' && value.seed.topicId.trim() == identity,
    _ => false,
  };
}

CanvasEntryIntent _legacyAssetCanvasIntent(
  String assetId, {
  required V3FeedItem? Function(String id)? sourceNoteForId,
}) {
  final note = sourceNoteForId?.call(assetId);
  if (note == null || note.id != assetId) {
    return const CanvasEntryIntent.blank();
  }
  final seed = AssetCanvasSeed.tryFromItem(
    item: note,
    stage: V3ContentStage.raw,
  );
  return seed == null
      ? const CanvasEntryIntent.blank()
      : CanvasEntryIntent.asset(seed);
}

CanvasEntryIntent _legacyTopicCanvasIntent(
  String topicId, {
  required String? topicTitle,
  required V3FeedItem? Function(String id)? sourceNoteForId,
}) {
  final note = sourceNoteForId?.call(topicId);
  final revision = note?.rawPartRevisionId?.trim();
  if (note == null ||
      note.id != topicId ||
      note.rawBody.trim().isEmpty ||
      revision == null ||
      revision.isEmpty ||
      revision.length > 256) {
    return const CanvasEntryIntent.blank();
  }
  final sourceHash = AssetCanvasSeed.hashSourceMarkdown(note.rawBody);
  final seed = DailyTopicCanvasSeed(
    recommendationId: 'legacy-${sourceHash.substring(0, 32)}',
    topicId: topicId,
    title: topicTitle ?? note.title.trim(),
    briefMarkdown: note.rawBody,
    sourceRefs: const <DailyTopicCanvasSourceRef>[],
    sourceRevisionId: revision,
    sourceHash: sourceHash,
    linkedReference: V3LinkedMaterialRef(
      id: topicId,
      source: note.source,
      title: note.title.trim(),
      summary: note.summaryBody,
    ),
  );
  return seed.isValid
      ? CanvasEntryIntent.dailyTopic(seed)
      : const CanvasEntryIntent.blank();
}

String? _singleCanvasQueryValue(
  Map<String, List<String>> queryParametersAll,
  String key,
) {
  final values = queryParametersAll[key];
  return values?.length == 1 ? values!.single : null;
}

class _DeferredLegacyCanvasRoute extends ConsumerStatefulWidget {
  const _DeferredLegacyCanvasRoute({required this.source});

  final CanvasLegacyRouteSourceDescriptor source;

  @override
  ConsumerState<_DeferredLegacyCanvasRoute> createState() =>
      _DeferredLegacyCanvasRouteState();
}

class _DeferredLegacyCanvasRouteState
    extends ConsumerState<_DeferredLegacyCanvasRoute> {
  CanvasEntryIntent? _intent;
  String? _errorMessage;
  bool _loading = true;
  bool _cacheLoadFailed = false;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_resolve);
  }

  Future<void> _resolve({bool retryFailed = false}) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    final library = ref.read(knowledgeLibraryControllerProvider);
    final restored = await library.ensureCacheRestored(
      retryFailed: retryFailed,
    );
    if (!mounted) return;
    if (!restored) {
      setState(() {
        _loading = false;
        _cacheLoadFailed = true;
        _errorMessage = '资产数据暂时无法读取，请重试';
      });
      return;
    }
    final source = widget.source;
    final intent = switch (source.kind) {
      CanvasLegacyRouteSourceKind.asset => _legacyAssetCanvasIntent(
        source.sourceId,
        sourceNoteForId: library.noteForId,
      ),
      CanvasLegacyRouteSourceKind.dailyTopic => _legacyTopicCanvasIntent(
        source.sourceId,
        topicTitle: source.topicTitle,
        sourceNoteForId: library.noteForId,
      ),
    };
    if (intent is CanvasBlankEntryIntent) {
      setState(() {
        _loading = false;
        _cacheLoadFailed = false;
        _errorMessage = '当前来源没有可用于生成逐字稿的有效内容';
      });
      return;
    }
    setState(() {
      _loading = false;
      _cacheLoadFailed = false;
      _intent = intent;
    });
  }

  Future<void> _return() => returnToPreviousRoute(
    context,
    fallbackRoute: AppRoutePaths.homeForMode(AppRoutePaths.workbenchMode),
  );

  @override
  Widget build(BuildContext context) {
    final intent = _intent;
    if (intent != null) return V3CreationCanvasPage(entryIntent: intent);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loading)
                    const CircularProgressIndicator.adaptive()
                  else
                    const Icon(Icons.error_outline_rounded, size: 36),
                  const SizedBox(height: 16),
                  Text(
                    _loading ? '正在读取创作来源' : '创作来源加载失败',
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _loading ? '请稍候' : _errorMessage ?? '暂时无法打开',
                    textAlign: TextAlign.center,
                  ),
                  if (!_loading) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const ValueKey<String>('canvas-route-source-retry'),
                      onPressed: () => _resolve(retryFailed: _cacheLoadFailed),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                    TextButton.icon(
                      key: const ValueKey<String>('canvas-route-source-return'),
                      onPressed: _return,
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: const Text('返回'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Page<void> _materialImportOverlayPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  final animationDuration = V3MotionTokens.resolve(
    context,
    V3MotionTokens.routeEnter,
  );
  return CustomTransitionPage<void>(
    key: state.pageKey,
    restorationId: state.pageKey.value,
    opaque: false,
    barrierColor: const Color(0x1F17191B),
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: animationDuration,
    reverseTransitionDuration: V3MotionTokens.resolve(
      context,
      V3MotionTokens.routeExit,
    ),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
    child: child,
  );
}

String? _redirectInvalidWorkbenchPurpose(
  BuildContext context,
  GoRouterState state,
) => workbenchPurposeFromRoute(state.pathParameters['purpose'] ?? '') == null
    ? AppRoutePaths.homeForMode(AppRoutePaths.workbenchMode)
    : null;

V3HomeMode _homeModeFromQuery(String? value) => switch (value) {
  AppRoutePaths.workbenchMode => V3HomeMode.workbench,
  AppRoutePaths.masterpieceMode => V3HomeMode.masterpiece,
  _ => V3HomeMode.feed,
};

String? _boundedChatPrompt(String? value) {
  final prompt = value?.trim();
  if (prompt == null || prompt.isEmpty) return null;
  return prompt.length <= 1000 ? prompt : prompt.substring(0, 1000);
}

enum _ExactChatRouteFailure {
  invalidThreadId,
  invalidPurpose,
  invalidAgentProfile,
  invalidSkill,
  missingConversationIdentity,
  conflictingConversationIdentity;

  String get message => switch (this) {
    _ExactChatRouteFailure.invalidThreadId => '会话标识无效，未创建、恢复或切换到其他会话。',
    _ExactChatRouteFailure.invalidPurpose => '会话用途信息无效，未尝试加载该会话。',
    _ExactChatRouteFailure.invalidAgentProfile => '会话 Agent 信息无效，未尝试加载该会话。',
    _ExactChatRouteFailure.invalidSkill => '会话功能信息无效，未尝试加载该会话。',
    _ExactChatRouteFailure.missingConversationIdentity =>
      '链接缺少可信的会话用途或 Agent 信息，无法安全确定会话类型。',
    _ExactChatRouteFailure.conflictingConversationIdentity =>
      '会话用途与 Agent 信息不一致，未尝试加载该会话。',
  };
}

final class _ExactChatRouteContract {
  const _ExactChatRouteContract._({
    required this.requested,
    this.threadId,
    this.purpose,
    this.agentProfileId,
    this.failure,
  });

  const _ExactChatRouteContract.absent()
    : requested = false,
      threadId = null,
      purpose = null,
      agentProfileId = null,
      failure = null;

  factory _ExactChatRouteContract.fromUri(Uri uri) {
    final threadValues = uri.queryParametersAll['threadId'];
    if (threadValues == null) return const _ExactChatRouteContract.absent();
    if (threadValues.length != 1 ||
        !isSafeChatIdentifier(threadValues.single)) {
      return const _ExactChatRouteContract._(
        requested: true,
        failure: _ExactChatRouteFailure.invalidThreadId,
      );
    }

    final purposeValues = uri.queryParametersAll['purpose'];
    ChatConversationPurpose? purpose;
    if (purposeValues != null) {
      if (purposeValues.length != 1 ||
          (purpose = ChatConversationPurpose.tryParseRoute(
                purposeValues.single,
              )) ==
              null) {
        return const _ExactChatRouteContract._(
          requested: true,
          failure: _ExactChatRouteFailure.invalidPurpose,
        );
      }
    }

    final agentProfileValues = uri.queryParametersAll['agentProfileId'];
    String? agentProfileId;
    if (agentProfileValues != null) {
      if (agentProfileValues.length != 1 ||
          (agentProfileId = knownPublicChatAgentProfileId(
                agentProfileValues.single,
              )) ==
              null) {
        return const _ExactChatRouteContract._(
          requested: true,
          failure: _ExactChatRouteFailure.invalidAgentProfile,
        );
      }
    }

    final skillValues = uri.queryParametersAll['skill'];
    WorkbenchChatSkill? skill;
    if (skillValues != null) {
      if (skillValues.length != 1 ||
          (skill = WorkbenchChatSkill.tryParse(skillValues.single)) == null) {
        return const _ExactChatRouteContract._(
          requested: true,
          failure: _ExactChatRouteFailure.invalidSkill,
        );
      }
    }
    final skillAgentProfileId = agentProfileIdForWorkbenchSkill(skill);
    if (agentProfileId != null &&
        skillAgentProfileId != null &&
        agentProfileId != skillAgentProfileId) {
      return const _ExactChatRouteContract._(
        requested: true,
        failure: _ExactChatRouteFailure.conflictingConversationIdentity,
      );
    }
    final resolvedAgentProfileId = agentProfileId ?? skillAgentProfileId;
    final profilePurpose = resolvedAgentProfileId == null
        ? null
        : resolveChatConversationPurposeForAgent(
            requestedPurpose: ChatConversationPurpose.general,
            agentProfileId: resolvedAgentProfileId,
          );
    if (purpose != null &&
        profilePurpose != null &&
        purpose != profilePurpose) {
      return const _ExactChatRouteContract._(
        requested: true,
        failure: _ExactChatRouteFailure.conflictingConversationIdentity,
      );
    }
    final resolvedPurpose = purpose ?? profilePurpose;
    if (resolvedPurpose == null) {
      return const _ExactChatRouteContract._(
        requested: true,
        failure: _ExactChatRouteFailure.missingConversationIdentity,
      );
    }
    return _ExactChatRouteContract._(
      requested: true,
      threadId: threadValues.single,
      purpose: resolvedPurpose,
      agentProfileId: resolvedAgentProfileId,
    );
  }

  final bool requested;
  final String? threadId;
  final ChatConversationPurpose? purpose;
  final String? agentProfileId;
  final _ExactChatRouteFailure? failure;
}

class _ChatRouteContractFailurePage extends StatelessWidget {
  const _ChatRouteContractFailurePage({required this.failure});

  final _ExactChatRouteFailure failure;

  @override
  Widget build(BuildContext context) => V3PageScaffold(
    title: '无法打开会话',
    subtitle: failure.message,
    fallbackRoute: AppRoutePaths.home,
    children: <Widget>[
      V3Card(
        key: ValueKey<String>('chat-route-failure-${failure.name}'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: <Widget>[
              const Icon(Icons.link_off_rounded, size: 34),
              const SizedBox(height: 12),
              Text(
                '为避免打开错误会话，本次链接没有被执行。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => returnToPreviousRoute(
                  context,
                  fallbackRoute: AppRoutePaths.home,
                ),
                icon: Icon(
                  canReturnToPreviousRoute(context)
                      ? Icons.arrow_back_rounded
                      : Icons.home_outlined,
                ),
                label: Text(
                  canReturnToPreviousRoute(context) ? '返回上一级' : '返回思想图谱',
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

Page<void> _platformOrSheetExpansionPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  if (state.uri.queryParameters['presentation'] != 'sheet') {
    return MaterialPage<void>(
      key: state.pageKey,
      restorationId: state.pageKey.value,
      child: child,
    );
  }
  final duration = V3MotionTokens.resolve(context, V3MotionTokens.routeEnter);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    restorationId: state.pageKey.value,
    transitionDuration: duration,
    reverseTransitionDuration: V3MotionTokens.resolve(
      context,
      V3MotionTokens.routeExit,
    ),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
    child: child,
  );
}
