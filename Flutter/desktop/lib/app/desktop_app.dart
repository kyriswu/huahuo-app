import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../features/editor/application/desktop_graph_preferences.dart';
import '../features/editor/data/desktop_graph_preferences_store.dart'
    show LocalDesktopGraphPreferencesStore;
import '../features/editor/data/local_document_media_store.dart'
    show LocalDocumentMediaStore;
import '../features/editor/data/local_document_store.dart'
    show LocalDocumentStore;
import '../features/editor/domain/document_media_store.dart';
import '../features/editor/domain/document_store.dart';
import '../features/editor/presentation/editor_workspace.dart';
import '../shared/theme/desktop_theme.dart';
import '../shared/widgets/desktop_ambient_background.dart';
import '../shared/widgets/desktop_window_frame.dart';
import 'desktop_services.dart';
import 'desktop_feature_registry.dart';
import 'desktop_router.dart';

class HuahuoDesktopApp extends StatefulWidget {
  const HuahuoDesktopApp({
    super.key,
    this.documentStore,
    this.themeMode = ThemeMode.system,
    this.palette = DesktopAccentPalette.graphite,
    this.windowController,
    this.graphPreferencesStore,
    this.documentMediaStore,
    this.services,
    this.incomingDocumentPaths = const <String>[],
  });

  final DocumentStore? documentStore;
  final ThemeMode themeMode;
  final DesktopAccentPalette palette;
  final DesktopWindowController? windowController;
  final DesktopGraphPreferencesStore? graphPreferencesStore;
  final DocumentMediaStore? documentMediaStore;
  final DesktopServices? services;
  final List<String> incomingDocumentPaths;

  @override
  State<HuahuoDesktopApp> createState() => _HuahuoDesktopAppState();
}

class _HuahuoDesktopAppState extends State<HuahuoDesktopApp> {
  late ThemeMode _themeMode;
  late DesktopAccentPalette _palette;
  late DocumentStore _documentStore;
  late DocumentMediaStore _documentMediaStore;
  late DesktopGraphPreferencesStore _graphPreferencesStore;
  late DesktopServices _services;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.themeMode;
    _palette = widget.palette;
    _documentStore = widget.documentStore ?? LocalDocumentStore();
    _documentMediaStore =
        widget.documentMediaStore ?? LocalDocumentMediaStore();
    _graphPreferencesStore =
        widget.graphPreferencesStore ?? LocalDesktopGraphPreferencesStore();
    _services = widget.services ?? DesktopServices.fromEnvironment();
    _router = createDesktopRouter(
      commands: desktopFeatureCommands(ProductFeatureCatalog.entries),
      pageBuilder: _buildRoutedWorkspace,
    );
  }

  @override
  void didUpdateWidget(covariant HuahuoDesktopApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeMode != widget.themeMode) {
      _themeMode = widget.themeMode;
    }
    if (oldWidget.palette != widget.palette) {
      _palette = widget.palette;
    }
    if (oldWidget.documentStore != widget.documentStore) {
      _documentStore = widget.documentStore ?? LocalDocumentStore();
    }
    if (oldWidget.documentMediaStore != widget.documentMediaStore) {
      _documentMediaStore =
          widget.documentMediaStore ?? LocalDocumentMediaStore();
    }
    if (oldWidget.graphPreferencesStore != widget.graphPreferencesStore) {
      _graphPreferencesStore =
          widget.graphPreferencesStore ?? LocalDesktopGraphPreferencesStore();
    }
    if (oldWidget.services != widget.services) {
      _services = widget.services ?? DesktopServices.fromEnvironment();
    }
  }

  void _setThemeMode(ThemeMode themeMode) {
    if (_themeMode == themeMode) return;
    setState(() => _themeMode = themeMode);
  }

  void _setPalette(DesktopAccentPalette palette) {
    if (_palette == palette) return;
    setState(() => _palette = palette);
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  Widget _buildRoutedWorkspace(
    BuildContext context,
    String location,
    bool routeFailed,
  ) {
    if (routeFailed) {
      return DesktopAmbientBackground(
        child: DesktopWindowFrame(
          controller: widget.windowController,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(LucideIcons.routeOff, size: 32),
                    const SizedBox(height: 16),
                    Text(
                      '无法打开此位置',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      location,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () => _router.go('/brain'),
                      icon: const Icon(LucideIcons.network),
                      label: const Text('返回思想图谱'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Consumer(
      builder: (context, ref, child) => DesktopAmbientBackground(
        child: DesktopWindowFrame(
          controller: widget.windowController,
          child: EditorWorkspace(
            initialLocation: location,
            featureEntries: ref.watch(desktopVisibleFeaturesProvider),
            onNavigateLocation: _router.go,
            documentStore: _documentStore,
            themeMode: _themeMode,
            palette: _palette,
            onThemeModeChanged: _setThemeMode,
            onPaletteChanged: _setPalette,
            graphPreferencesStore: _graphPreferencesStore,
            documentMediaStore: _documentMediaStore,
            authPort: _services.auth,
            assetsPort: _services.assets,
            documentSyncPort: _services.documents,
            documentImporter: _services.documentImporter,
            rawNoteCreator: _services.rawNoteCreator,
            chatPort: _services.chat,
            chatRecoveryStore: _services.chatRecovery,
            chatNoteCreator: _services.chatNoteCreator,
            resourceImageCache: _services.resourceImageCache,
            workspacePort: _services.workspace,
            catalogPort: _services.catalog,
            subscriptionPort: _services.subscription,
            accountUsagePort: _services.accountUsage,
            bookWorkPort: _services.bookWork,
            topicsPort: _services.topics,
            topicsCache: _services.topicsCache,
            notificationsPort: _services.notifications,
            recordingsPort: _services.recordings,
            recordingLibraryRepository: _services.recordingLibrary,
            activityCalendarPort: _services.activityCalendar,
            workspaceManagementRepository: _services.workspaceManagement,
            homeRepository: _services.home,
            supportRepository: _services.support,
            creationsRepository: _services.creations,
            proposalsRepository: _services.proposals,
            digitalTwinRepository: _services.digitalTwin,
            demoMode: _services.demoMode,
            incomingDocumentPaths: widget.incomingDocumentPaths,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp.router(
        title: '花火 AI 创作桌面',
        debugShowCheckedModeBanner: false,
        theme: HuahuoDesktopTheme.light(palette: _palette),
        darkTheme: HuahuoDesktopTheme.dark(palette: _palette),
        themeMode: _themeMode,
        localizationsDelegates:
            FlutterQuillLocalizations.localizationsDelegates,
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
        routerConfig: _router,
      ),
    );
  }
}
