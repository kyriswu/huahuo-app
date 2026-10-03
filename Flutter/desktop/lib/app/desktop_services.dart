import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_product/huahuo_product.dart';

import '../features/assets/data/desktop_assets_adapters.dart';
import '../features/assets/domain/desktop_assets_port.dart';
import '../features/auth/data/desktop_auth_adapters.dart';
import '../features/auth/domain/desktop_auth_port.dart';
import '../features/book_work/data/desktop_book_work_adapters.dart';
import '../features/book_work/domain/desktop_book_work_port.dart';
import '../features/calendar/data/desktop_activity_calendar_adapter.dart';
import '../features/calendar/domain/desktop_activity_calendar_port.dart';
import '../features/chat/application/desktop_chat_note_creator.dart';
import '../features/chat/data/desktop_chat_adapters.dart';
import '../features/chat/data/desktop_chat_recovery_store.dart'
    show LocalDesktopChatRecoveryStore;
import '../features/chat/data/desktop_resource_image_cache.dart'
    show RemoteDesktopResourceImageCache;
import '../features/chat/domain/desktop_chat_port.dart';
import '../features/chat/domain/desktop_chat_recovery_models.dart';
import '../features/chat/domain/desktop_resource_image_cache.dart';
import '../features/documents/data/desktop_document_sync_adapters.dart';
import '../features/documents/data/desktop_document_import_adapter.dart';
import '../features/documents/data/desktop_raw_note_creator.dart';
import '../features/documents/domain/desktop_document_sync_port.dart';
import '../features/documents/domain/desktop_document_import_port.dart';
import '../features/documents/domain/desktop_raw_note_creator.dart';
import '../features/integration/data/desktop_api_domains_adapters.dart';
import '../features/integration/domain/desktop_api_domains_port.dart';
import '../features/notifications/data/desktop_notifications_adapters.dart';
import '../features/notifications/domain/desktop_notifications_port.dart';
import '../features/recordings/data/desktop_recordings_adapters.dart';
import '../features/recordings/domain/desktop_recordings_port.dart';
import '../features/support/data/desktop_support_asset_repository.dart';
import '../features/topics/data/desktop_topics_adapters.dart'
    show RemoteDesktopTopicsPort;
import '../features/topics/data/desktop_topics_cache.dart'
    show LocalDesktopTopicsCache;
import '../features/topics/domain/desktop_topics_port.dart';

const desktopProductionApiBaseUrl = 'https://chuda.cc';

/// Desktop editor writes follow the mobile Workspace default. A deployment can
/// still stop writeback explicitly while preserving the durable local outbox.
const desktopDocumentWriteEnabled = bool.fromEnvironment(
  'HUAHUO_DOCUMENT_WRITE_ENABLED',
  defaultValue: true,
);

final _ianaTimeZonePattern = RegExp(r'^[A-Za-z]+(?:/[A-Za-z0-9_+\-]+)+$');

Uri? resolveDesktopApiBaseUrl(String configuredValue) {
  final candidate = configuredValue.trim().isEmpty
      ? desktopProductionApiBaseUrl
      : configuredValue.trim();
  final parsed = Uri.tryParse(candidate);
  if (parsed == null ||
      parsed.scheme != 'https' ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      (parsed.path.isNotEmpty && parsed.path != '/') ||
      parsed.hasQuery ||
      parsed.hasFragment) {
    return null;
  }
  return parsed.replace(path: '');
}

/// The public login contract accepts an IANA zone, not platform abbreviations.
String resolveDesktopTimeZone(
  String configuredValue, {
  String? localTimeZoneName,
}) {
  for (final candidate in <String>[configuredValue, localTimeZoneName ?? '']) {
    final normalized = candidate.trim();
    if (normalized == 'UTC' || _ianaTimeZonePattern.hasMatch(normalized)) {
      return normalized;
    }
  }
  return 'UTC';
}

final class DesktopServices {
  const DesktopServices({
    required this.auth,
    required this.assets,
    required this.documents,
    required this.chat,
    required this.demoMode,
    this.documentImporter = const UnavailableDesktopDocumentImportPort(),
    this.rawNoteCreator = const UnavailableDesktopRawNoteCreator(),
    this.chatRecovery = const UnavailableDesktopChatRecoveryStore(),
    this.chatNoteCreator = const UnavailableDesktopChatNoteCreator(),
    this.resourceImageCache = const UnavailableDesktopResourceImageCache(),
    this.workspace = const UnavailableDesktopApiDomains(),
    this.catalog = const UnavailableDesktopApiDomains(),
    this.subscription = const UnavailableDesktopApiDomains(),
    this.accountUsage = const UnavailableDesktopApiDomains(),
    this.bookWork = const UnavailableDesktopBookWorkPort(),
    this.topics = const UnavailableDesktopTopicsPort(),
    this.topicsCache = const UnavailableDesktopTopicsCache(),
    this.notifications = const UnavailableDesktopNotificationsPort(),
    this.recordings = const UnavailableDesktopRecordingsPort(),
    this.recordingLibrary = const UnavailableProductRecordingsRepository(),
    this.activityCalendar = const UnavailableDesktopActivityCalendarPort(),
    this.workspaceManagement = const UnavailableWorkspaceManagementRepository(),
    this.home = const UnavailableProductHomeRepository(),
    this.support = const UnavailableProductSupportRepository(),
    this.creations = const UnavailableProductCreationsRepository(),
    this.proposals = const UnavailableProductDocumentProposalsRepository(),
    this.digitalTwin = const UnavailableProductDigitalTwinRepository(),
  });

  factory DesktopServices.fromEnvironment() {
    const rawBaseUrl = String.fromEnvironment(
      'HUAHUO_API_BASE_URL',
      defaultValue: desktopProductionApiBaseUrl,
    );
    const rawTimeZone = String.fromEnvironment('HUAHUO_TIME_ZONE');
    const demoMode = bool.fromEnvironment('HUAHUO_DESKTOP_DEMO');
    final baseUrl = resolveDesktopApiBaseUrl(rawBaseUrl);
    if (baseUrl == null) {
      return DesktopServices(
        auth: const UnavailableDesktopAuthPort(),
        assets: const UnavailableDesktopAssetsPort(),
        documents: UnavailableDesktopDocumentSyncPort(),
        chat: demoMode
            ? const DemoDesktopChatPort()
            : const UnavailableDesktopChatPort(),
        workspace: const UnavailableDesktopApiDomains(),
        catalog: const UnavailableDesktopApiDomains(),
        subscription: const UnavailableDesktopApiDomains(),
        accountUsage: const UnavailableDesktopApiDomains(),
        bookWork: const UnavailableDesktopBookWorkPort(),
        topics: const UnavailableDesktopTopicsPort(),
        topicsCache: const UnavailableDesktopTopicsCache(),
        notifications: const UnavailableDesktopNotificationsPort(),
        demoMode: demoMode,
      );
    }

    const tokenStore = SecureDesktopTokenStore();
    final runtime = ApiClientRuntime(
      clientVersion: '0.1.0',
      deviceId: 'desktop-${Platform.localHostname}',
      platform: Platform.isWindows ? 'windows' : 'macos',
      locale: Platform.localeName.replaceAll('_', '-'),
      timeZone: resolveDesktopTimeZone(
        rawTimeZone,
        localTimeZoneName: DateTime.now().timeZoneName,
      ),
    );
    final client = ApiClientFactory.create(
      baseUrl: baseUrl,
      runtime: runtime,
      transport: HttpApiTransport(),
      getAccessToken: tokenStore.readAccessToken,
      traceIdFactory: () =>
          'desktop-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      onAuthExpired: (failure) {
        if (const <String>{
          'AUTH_SESSION_EXPIRED',
          'TOKEN_EXPIRED',
        }.contains(failure.code.trim())) {
          return tokenStore.clearAccessToken();
        }
      },
    );
    final apiDomains = RemoteDesktopApiDomains(client);
    return DesktopServices(
      auth: RemoteDesktopAuthPort(
        client,
        tokenStore,
        runtime: DesktopAuthRuntime(
          deviceId: runtime.deviceId,
          clientVersion: runtime.clientVersion,
          timeZone: runtime.timeZone,
        ),
      ),
      assets: RemoteDesktopAssetsPort(client),
      documents: RemoteDesktopDocumentSyncPort(
        client,
        remoteWriteEnabled: desktopDocumentWriteEnabled,
      ),
      documentImporter: RemoteDesktopDocumentImportPort(client),
      rawNoteCreator: RemoteDesktopRawNoteCreator(client),
      chat: demoMode
          ? const DemoDesktopChatPort()
          : RemoteDesktopChatPort(client),
      chatRecovery: LocalDesktopChatRecoveryStore(),
      chatNoteCreator: RemoteDesktopChatNoteCreator(client),
      resourceImageCache: RemoteDesktopResourceImageCache(apiClient: client),
      workspace: apiDomains,
      catalog: apiDomains,
      subscription: apiDomains,
      accountUsage: apiDomains,
      bookWork: RemoteDesktopBookWorkPort(client),
      topics: RemoteDesktopTopicsPort(client),
      topicsCache: LocalDesktopTopicsCache(),
      notifications: RemoteDesktopNotificationsPort(client),
      recordings: RemoteDesktopRecordingsPort(client),
      recordingLibrary: RemoteProductRecordingsRepository(client),
      activityCalendar: RemoteDesktopActivityCalendarPort(client),
      workspaceManagement: RemoteWorkspaceManagementRepository(client),
      home: RemoteProductHomeRepository(client),
      support: DesktopSupportAssetRepository(),
      creations: RemoteProductCreationsRepository(client),
      proposals: RemoteProductDocumentProposalsRepository(client),
      digitalTwin: RemoteProductDigitalTwinRepository(client),
      demoMode: demoMode,
    );
  }

  final DesktopAuthPort auth;
  final DesktopAssetsPort assets;
  final DesktopDocumentSyncPort documents;
  final DesktopDocumentImportPort documentImporter;
  final DesktopRawNoteCreator rawNoteCreator;
  final DesktopChatPort chat;
  final DesktopChatRecoveryStore chatRecovery;
  final DesktopChatNoteCreator chatNoteCreator;
  final DesktopResourceImageCache resourceImageCache;
  final DesktopWorkspacePort workspace;
  final DesktopCatalogPort catalog;
  final DesktopSubscriptionPort subscription;
  final DesktopAccountUsagePort accountUsage;
  final DesktopBookWorkPort bookWork;
  final DesktopTopicsPort topics;
  final DesktopTopicsCache topicsCache;
  final DesktopNotificationsPort notifications;
  final DesktopRecordingsPort recordings;
  final ProductRecordingsRepository recordingLibrary;
  final DesktopActivityCalendarPort activityCalendar;
  final WorkspaceManagementRepository workspaceManagement;
  final ProductHomeRepository home;
  final ProductSupportRepository support;
  final ProductCreationsRepository creations;
  final ProductDocumentProposalsRepository proposals;
  final ProductDigitalTwinRepository digitalTwin;
  final bool demoMode;
}
