part of 'product_feature_catalog.dart';

FeatureEntry _shared(
  String id,
  FeatureDomain domain,
  String title,
  String mobileRoute,
  String desktopRoute,
  List<String> endpoints,
  List<String> states,
) => FeatureEntry(
  descriptor: FeatureDescriptor(
    id: FeatureId(id),
    domain: domain,
    title: title,
    backendEndpointIds: endpoints,
    states: states,
    platformPolicy: FeaturePlatformPolicy.shared,
    acceptanceScenarios: <String>['$id.success', '$id.failure', '$id.retry'],
  ),
  mobile: _enabled(
    ProductPlatform.mobile,
    mobileRoute,
    'src/lib/app/navigation/app_routes.dart',
  ),
  desktop: _enabled(
    ProductPlatform.desktop,
    desktopRoute,
    _desktopEvidence(id),
  ),
);

FeatureEntry _blocked(
  String id,
  FeatureDomain domain,
  String title,
  String mobileRoute,
  List<String> endpoints,
  List<String> states,
  String reason,
) => FeatureEntry(
  descriptor: FeatureDescriptor(
    id: FeatureId(id),
    domain: domain,
    title: title,
    backendEndpointIds: endpoints,
    states: states,
    platformPolicy: FeaturePlatformPolicy.shared,
    acceptanceScenarios: <String>['$id.contractBlocked'],
  ),
  mobile: _enabled(
    ProductPlatform.mobile,
    mobileRoute,
    'src/lib/app/navigation/app_routes.dart',
  ),
  desktop: FeatureBinding(
    platform: ProductPlatform.desktop,
    availability: FeatureAvailability.blocked,
    entryPoints: const [],
    implementationEvidence: const [],
    reason: reason,
  ),
);

FeatureEntry _deferred(
  String id,
  String title,
  String mobileRoute,
) => FeatureEntry(
  descriptor: FeatureDescriptor(
    id: FeatureId(id),
    domain: FeatureDomain.native,
    title: title,
    backendEndpointIds: const <String>[],
    states: const <String>['idle', 'active', 'failure'],
    platformPolicy: FeaturePlatformPolicy.desktopNativeDeferred,
    acceptanceScenarios: <String>['$id.mobile', '$id.desktopHidden'],
  ),
  mobile: _enabled(
    ProductPlatform.mobile,
    mobileRoute,
    'src/lib/app/navigation/app_routes.dart',
  ),
  desktop: FeatureBinding(
    platform: ProductPlatform.desktop,
    availability: FeatureAvailability.hidden,
    entryPoints: const <FeatureEntryPoint>[],
    implementationEvidence: const <String>[],
    reason:
        'Approved 2026-09-03 native Desktop deferral; no disabled or placeholder entry may be shown.',
  ),
);

FeatureBinding _enabled(
  ProductPlatform platform,
  String route,
  String evidence,
) => FeatureBinding(
  platform: platform,
  availability: FeatureAvailability.enabled,
  entryPoints: <FeatureEntryPoint>[
    FeatureEntryPoint(kind: FeatureEntryKind.route, locator: route),
    if (platform == ProductPlatform.desktop) ...<FeatureEntryPoint>[
      FeatureEntryPoint(kind: FeatureEntryKind.sidebar, locator: route),
      FeatureEntryPoint(kind: FeatureEntryKind.parent, locator: route),
      FeatureEntryPoint(kind: FeatureEntryKind.command, locator: route),
    ],
  ],
  implementationEvidence: <String>[evidence],
);

String _desktopEvidence(String id) => switch (id) {
  'account.support' =>
    'desktop/lib/features/support/widgets/desktop_support_workspace.dart',
  'account.workspace' =>
    'desktop/lib/features/workspaces/widgets/desktop_workspace_management_workspace.dart',
  'account.positioning' =>
    'desktop/lib/features/positioning/widgets/desktop_positioning_dashboard.dart',
  'content.home' =>
    'desktop/lib/features/home/widgets/desktop_home_workspace.dart',
  'notifications.inbox' =>
    'desktop/lib/features/notifications/widgets/desktop_notifications_workspace.dart',
  'knowledge.graph' =>
    'desktop/lib/features/editor/presentation/desktop_knowledge_graph.dart',
  'content.calendar' =>
    'desktop/lib/features/calendar/widgets/desktop_activity_calendar_workspace.dart',
  'ingestion.text' =>
    'desktop/lib/features/documents/data/desktop_raw_note_creator.dart',
  'ingestion.document' =>
    'desktop/lib/features/documents/data/desktop_document_import_adapter.dart',
  'ingestion.media' =>
    'desktop/lib/features/recordings/data/desktop_recordings_adapters.dart',
  'recordings.library' || 'recordings.transcription' =>
    'desktop/lib/features/recordings/widgets/desktop_recording_library_workspace.dart',
  'chat.conversations' =>
    'desktop/lib/features/chat/data/desktop_chat_adapters.dart',
  'chat.agent' =>
    'desktop/lib/features/agent/application/desktop_agent_controller.dart',
  'creation.workspace' =>
    'desktop/lib/features/creations/widgets/desktop_creation_workspace.dart',
  'creation.proposals' =>
    'desktop/lib/features/proposals/widgets/desktop_document_proposals_workspace.dart',
  'creation.bookWork' =>
    'desktop/lib/features/book_work/application/desktop_book_work_controller.dart',
  'digitalTwin.workspace' =>
    'desktop/lib/features/digital_twin/widgets/desktop_digital_twin_workspace.dart',
  'content.assets' =>
    'desktop/lib/features/assets/data/desktop_assets_adapters.dart',
  'knowledge.notes' =>
    'desktop/lib/features/documents/data/desktop_document_sync_adapters.dart',
  _ => 'desktop/lib/features/editor/presentation/editor_workspace.dart',
};
