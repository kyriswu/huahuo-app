import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../chat/application/chat_run_tracker.dart';
import '../application/knowledge_library_controller.dart';
import '../application/photo_album_controller.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_library_models.dart';
import '../domain/knowledge_note_outline.dart';
import '../domain/photo_album_models.dart';
import '../domain/v3_deposit_models.dart';
import 'v3_knowledge_local_surfaces.dart';
import 'v3_my_assets_surfaces.dart';

export 'v3_my_assets_surfaces.dart' show V3PhotoAlbumPreviewPage;

class V3MyAssetsPage extends ConsumerStatefulWidget {
  const V3MyAssetsPage({
    this.initialSection,
    this.initialSearch = false,
    this.initialQuery,
    super.key,
  });

  final V3MyAssetsSection? initialSection;
  final bool initialSearch;
  final String? initialQuery;

  V3MyAssetsSection get resolvedInitialSection =>
      initialSection ?? V3MyAssetsSection.deposited;

  @override
  ConsumerState<V3MyAssetsPage> createState() => _V3MyAssetsPageState();
}

class _V3MyAssetsPageState extends ConsumerState<V3MyAssetsPage> {
  final _depositSearchFocusNode = FocusNode();
  late final TextEditingController _searchController;
  late bool _searchActive;
  var _searchFilters = KnowledgeAssetSearchFilters();
  KnowledgeLibraryController? _searchOwner;
  int _searchIndexRevision = -1;
  List<V3FeedItem> _assetSearchNotes = const [];
  List<String> _assetSearchTags = const [];
  (int, KnowledgeAssetSearchFilters, String, int)? _searchResultKey;
  List<V3FeedItem> _assetSearchResults = const [];
  String? _depositFolderId;
  final Map<String, List<String>> _folderOrderByParent =
      <String, List<String>>{};
  final Set<String> _collapsedDepositFolderIds = <String>{};

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text:
          widget.initialQuery ??
          ref.read(knowledgeLibraryControllerProvider).depositQuery,
    );
    _searchActive =
        widget.initialSearch || _searchController.text.trim().isNotEmpty;
    _depositSearchFocusNode.addListener(_handleSearchFocus);
    if (_searchActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(knowledgeLibraryControllerProvider)
            .setDepositQuery(_searchController.text);
        _depositSearchFocusNode.requestFocus();
      });
    }
    ref.listenManual<int>(
      appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.foregroundGeneration,
      ),
      (_, __) => _reloadVisibleAssetsOnForeground(),
    );
    _scheduleNotesRefresh();
  }

  @override
  void didUpdateWidget(covariant V3MyAssetsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolvedInitialSection != V3MyAssetsSection.mediaResources &&
        widget.resolvedInitialSection == V3MyAssetsSection.mediaResources) {
      unawaited(ref.read(photoAlbumControllerProvider).load());
    }
    if (oldWidget.resolvedInitialSection != widget.resolvedInitialSection &&
        widget.resolvedInitialSection != V3MyAssetsSection.mediaResources) {
      _scheduleNotesRefresh();
    }
  }

  @override
  void dispose() {
    _depositSearchFocusNode.removeListener(_handleSearchFocus);
    _depositSearchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _handleSearchFocus() {
    if (_depositSearchFocusNode.hasFocus && !_searchActive) {
      setState(() => _searchActive = true);
    }
  }

  void _resetSearch({bool close = false}) {
    _depositSearchFocusNode.unfocus();
    _searchController.clear();
    ref.read(knowledgeLibraryControllerProvider).setDepositQuery('');
    setState(() {
      _searchFilters = KnowledgeAssetSearchFilters();
      if (close) _searchActive = false;
    });
  }

  void _scheduleNotesRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.resolvedInitialSection == V3MyAssetsSection.mediaResources ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      unawaited(_refreshNotes());
    });
  }

  List<V3FeedItem> _searchAssets(
    KnowledgeLibraryController controller,
    String query,
  ) {
    final revision = controller.noteIndexSnapshot.revision;
    if (!identical(_searchOwner, controller) ||
        _searchIndexRevision != revision) {
      _searchOwner = controller;
      _searchIndexRevision = revision;
      _searchResultKey = null;
      _assetSearchNotes = controller.notes
          .where((note) => controller.isDeposited(note.id))
          .toList(growable: false);
      final tagsByIdentity = <String, String>{};
      for (final note in _assetSearchNotes) {
        for (final tag in controller.effectiveTags(note)) {
          final label = tag.trim();
          if (label.isNotEmpty) {
            tagsByIdentity.putIfAbsent(label.toLowerCase(), () => label);
          }
        }
      }
      _assetSearchTags = tagsByIdentity.values.toList()
        ..sort(
          (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
        );
    }
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final key = (revision, _searchFilters, query, day);
    if (_searchResultKey != key) {
      _assetSearchResults = _searchFilters.apply(
        _assetSearchNotes,
        query: query,
        tagsFor: controller.effectiveTags,
        now: now,
      );
      _searchResultKey = key;
    }
    return _assetSearchResults;
  }

  Future<void> _refreshNotes() async {
    final controller = ref.read(knowledgeLibraryControllerProvider);
    if (controller.hasWorkspaceContentSync) {
      await controller.synchronizeWorkspaceContent();
    }
  }

  void _reloadVisibleAssetsOnForeground() {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    if (widget.resolvedInitialSection == V3MyAssetsSection.mediaResources) {
      unawaited(ref.read(photoAlbumControllerProvider).load());
    } else {
      unawaited(_refreshNotes());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(knowledgeLibraryControllerProvider);
    final album = ref.watch(photoAlbumControllerProvider);
    final taskTracker = ref.watch(chatRunTrackerProvider);
    final colors = HuahuoV3Theme.tokensOf(context);
    final section = widget.resolvedInitialSection;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: Column(
          children: [
            V3PageTopBar(
              title: '我的资产',
              fallbackRoute: '/v3/feed',
              showBack: true,
              height: 54,
              actions: section == V3MyAssetsSection.mediaResources
                  ? <Widget>[
                      IconButton(
                        key: const ValueKey('photo-album-refresh'),
                        tooltip: '刷新云端影像',
                        onPressed:
                            album.status == PhotoAlbumStatus.importing ||
                                album.isDeleting
                            ? null
                            : () => album.load(forceRemote: true),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                      IconButton(
                        key: const ValueKey('photo-album-upload'),
                        tooltip: '从相册添加照片',
                        onPressed:
                            album.status == PhotoAlbumStatus.importing ||
                                album.isDeleting
                            ? null
                            : _pickAlbumPhotos,
                        icon: album.status == PhotoAlbumStatus.importing
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add_photo_alternate_outlined),
                      ),
                    ]
                  : controller.hasWorkspaceContentSync
                  ? <Widget>[
                      IconButton(
                        key: const ValueKey('my-assets-refresh'),
                        tooltip: '同步文件夹和笔记',
                        onPressed:
                            controller.graphReadModel.sourceState ==
                                KnowledgeGraphSourceState.loading
                            ? null
                            : _refreshNotes,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ]
                  : const <Widget>[],
            ),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: section == V3MyAssetsSection.mediaResources
                  ? V3MyAssetsPhotoAlbumGrid(
                      controller: album,
                      onOpen: _openPhoto,
                    )
                  : _buildDepositedPage(controller, taskTracker),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDepositedPage(
    KnowledgeLibraryController controller,
    DerivedPartRunTrackingPort taskTracker,
  ) {
    final currentFolder = _depositFolderId == null
        ? null
        : controller.depositFolderFor(_depositFolderId!);
    final currentFolderId = currentFolder?.id;
    final query = controller.depositQuery.trim();
    final searching = _searchActive || query.isNotEmpty;
    final ancestors = currentFolder == null
        ? const <V3DepositFolder>[]
        : controller.depositFolderAncestors(currentFolder.id);
    final folders = !searching
        ? _orderedDepositFolders(
            currentFolderId,
            controller.depositFoldersIn(currentFolderId),
          )
        : const <V3DepositFolder>[];
    final notes = !controller.workspaceFoldersReady
        ? const <V3FeedItem>[]
        : searching
        ? _searchAssets(controller, query)
        : controller.depositedNotes(folderId: currentFolderId);
    final searchLeadingEntries = <Widget>[
      if (searching) ...[
        V3AssetSearchFilters(
          key: const ValueKey('asset-search-filters'),
          filters: _searchFilters,
          availableTags: _assetSearchTags,
          onChanged: (filters) => setState(() => _searchFilters = filters),
        ),
        Text(
          controller.graphReadModel.sourceState ==
                  KnowledgeGraphSourceState.ready
              ? '搜索范围：全部资产 · ${notes.length} 条匹配'
              : '搜索范围：全部资产 · 已加载 ${notes.length} 条匹配',
          key: const ValueKey('asset-search-result-count'),
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).muted,
            fontSize: 12,
          ),
        ),
      ],
      if (controller.hasWorkspaceContentSync &&
          controller.graphReadModel.sourceState ==
              KnowledgeGraphSourceState.loading)
        Padding(
          key: const ValueKey('my-assets-sync-loading'),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 8),
              Text(
                controller.workspaceFoldersReady ? '目录已就绪，正在同步笔记…' : '正在同步文件夹…',
              ),
            ],
          ),
        ),
      if (controller.hasWorkspaceContentSync &&
          controller.graphReadModel.sourceState ==
              KnowledgeGraphSourceState.failure)
        Padding(
          key: const ValueKey('my-assets-sync-error'),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              const Text('文件夹和笔记同步失败，已加载的内容仍可查看'),
              TextButton(
                key: const ValueKey('my-assets-sync-retry'),
                onPressed: _refreshNotes,
                child: const Text('重试同步'),
              ),
            ],
          ),
        ),
      if (searching &&
          notes.isEmpty &&
          controller.workspaceFoldersReady &&
          controller.graphReadModel.sourceState !=
              KnowledgeGraphSourceState.loading)
        Column(
          key: const ValueKey('asset-search-empty'),
          children: [
            const SizedBox(height: 24),
            const Text('没有匹配的笔记'),
            TextButton(onPressed: _resetSearch, child: const Text('清空搜索条件')),
          ],
        ),
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: HuahuoV3Theme.tokensOf(context).surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      const Icon(Icons.search_rounded, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: V3SearchTextField(
                          key: const ValueKey('my-assets-search-target'),
                          fieldKey: const ValueKey('my-assets-search'),
                          controller: _searchController,
                          focusNode: _depositSearchFocusNode,
                          hintText: '搜索标题、正文或标签',
                          style: const TextStyle(fontSize: 14, height: 1.3),
                          onChanged: (value) {
                            controller.setDepositQuery(value);
                            setState(() => _searchActive = true);
                          },
                          onSubmitted: (_) => _depositSearchFocusNode.unfocus(),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          key: const ValueKey('asset-search-clear-query'),
                          tooltip: '清空搜索',
                          onPressed: () {
                            _searchController.clear();
                            controller.setDepositQuery('');
                            setState(() {});
                          },
                          icon: const Icon(Icons.close_rounded, size: 18),
                        )
                      else
                        const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
              if (searching)
                TextButton(
                  key: const ValueKey('asset-search-cancel'),
                  onPressed: () => _resetSearch(close: true),
                  child: const Text('取消'),
                ),
              if (!searching) ...[
                const SizedBox(width: 8),
                V3MyAssetsToolbarButton(
                  key: const ValueKey('my-assets-sort'),
                  tooltip: '排序',
                  icon: Icons.swap_vert_rounded,
                  onPressed: () => _showMyAssetsSort(controller),
                ),
                const SizedBox(width: 4),
                V3MyAssetsToolbarButton(
                  key: const ValueKey('asset-create-deposit-folder'),
                  tooltip: currentFolder == null
                      ? '新建根文件夹'
                      : '在${currentFolder.name}中新建文件夹',
                  icon: Icons.create_new_folder_outlined,
                  emphasized: true,
                  onPressed: () => _createDepositFolder(
                    controller,
                    parentFolderId: currentFolderId,
                  ),
                ),
                const SizedBox(width: 4),
                V3MyAssetsToolbarButton(
                  key: const ValueKey('asset-create-note'),
                  tooltip: '新建笔记',
                  icon: Icons.edit_note_rounded,
                  emphasized: true,
                  onPressed: () => context.push('/v3/feed/note'),
                ),
              ],
            ],
          ),
        ),
        if (!searching && currentFolder != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('asset-deposit-folder-back'),
                  tooltip: '返回上级文件夹',
                  onPressed: () => setState(
                    () => _depositFolderId = currentFolder.parentFolderId,
                  ),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: ListView(
                      key: const ValueKey(
                        'asset-deposit-folder-horizontal-list',
                      ),
                      scrollDirection: Axis.horizontal,
                      children: [
                        Center(
                          child: TextButton(
                            key: const ValueKey('asset-deposit-root'),
                            onPressed: () =>
                                setState(() => _depositFolderId = null),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 40),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            child: const Text('已沉淀'),
                          ),
                        ),
                        for (final folder in ancestors) ...[
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 17,
                            color: HuahuoV3Theme.tokensOf(context).muted,
                          ),
                          TextButton(
                            key: ValueKey(
                              'asset-deposit-breadcrumb-${folder.id}',
                            ),
                            onPressed: folder.id == currentFolderId
                                ? null
                                : () => setState(
                                    () => _depositFolderId = folder.id,
                                  ),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 40),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            child: Text(folder.name),
                          ),
                        ],
                        if (folders.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 10,
                            ),
                            child: VerticalDivider(
                              width: 1,
                              color: HuahuoV3Theme.tokensOf(context).line,
                            ),
                          ),
                        ],
                        for (final folder in folders)
                          _AssetFolderDirectoryRow(
                            key: ValueKey('asset-deposit-folder-${folder.id}'),
                            folder: folder,
                            noteCount: controller.depositFolderNoteCount(
                              folder.id,
                            ),
                            childFolderCount: controller
                                .depositFolderChildCount(folder.id),
                            onOpen: () =>
                                setState(() => _depositFolderId = folder.id),
                            onActions: () =>
                                _manageDepositFolder(controller, folder),
                            onMoveNote: (noteId) => _moveDepositNote(
                              controller,
                              noteId: noteId,
                              folder: folder,
                            ),
                            onReorderFolder: (draggedFolderId) =>
                                _reorderDepositFolders(
                                  currentFolderId,
                                  draggedFolderId,
                                  folder.id,
                                  folders,
                                ),
                            onDragStarted: _showFolderDragInstruction,
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('asset-deposit-folder-actions'),
                  tooltip: '管理文件夹 ${currentFolder.name}',
                  onPressed: () =>
                      _manageDepositFolder(controller, currentFolder),
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
              ],
            ),
          ),
        Expanded(
          child: _AssetNoteList(
            key: PageStorageKey<String>(
              searching
                  ? 'asset-search-results'
                  : 'asset-deposited-${currentFolderId ?? 'root'}',
            ),
            notes: notes,
            emptyLabel: searching
                ? '没有找到匹配的笔记'
                : currentFolder == null
                ? '这里还没有已沉淀内容'
                : '该文件夹还没有笔记或子文件夹',
            controller: controller,
            taskTracker: taskTracker,
            sections: currentFolder == null && !searching
                ? [
                    for (final folder in folders)
                      _AssetNoteSection(
                        header: _AssetFolderSectionHeader(
                          key: ValueKey('asset-deposit-folder-${folder.id}'),
                          folder: folder,
                          noteCount: controller.depositFolderNoteCount(
                            folder.id,
                          ),
                          onOpen: () =>
                              setState(() => _depositFolderId = folder.id),
                          expanded: !_collapsedDepositFolderIds.contains(
                            folder.id,
                          ),
                          onToggle: () => setState(() {
                            if (!_collapsedDepositFolderIds.remove(folder.id)) {
                              _collapsedDepositFolderIds.add(folder.id);
                            }
                          }),
                          onActions: () =>
                              _manageDepositFolder(controller, folder),
                          onMoveNote: (noteId) => _moveDepositNote(
                            controller,
                            noteId: noteId,
                            folder: folder,
                          ),
                          onReorderFolder: (draggedFolderId) =>
                              _reorderDepositFolders(
                                currentFolderId,
                                draggedFolderId,
                                folder.id,
                                folders,
                              ),
                          onDragStarted: _showFolderDragInstruction,
                        ),
                        notes: _collapsedDepositFolderIds.contains(folder.id)
                            ? const <V3FeedItem>[]
                            : controller.depositedNotes(folderId: folder.id),
                      ),
                  ]
                : const <_AssetNoteSection>[],
            leadingEntries: [...searchLeadingEntries],
            onOpen: _openContent,
            onActions: (note) =>
                _showNoteActions(controller, note, inDeposits: true),
            onDragStarted: searching
                ? null
                : () => showV3Snack(context, '拖到目标文件夹后松手'),
          ),
        ),
      ],
    );
  }

  List<V3DepositFolder> _orderedDepositFolders(
    String? parentFolderId,
    List<V3DepositFolder> folders,
  ) {
    final key = parentFolderId ?? '__root__';
    final currentIds = folders.map((folder) => folder.id).toSet();
    final order = _folderOrderByParent.putIfAbsent(key, () {
      final initial = <V3DepositFolder>[...folders]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return initial.map((folder) => folder.id).toList(growable: true);
    });
    order
      ..removeWhere((id) => !currentIds.contains(id))
      ..addAll(
        folders.map((folder) => folder.id).where((id) => !order.contains(id)),
      );
    final rank = <String, int>{
      for (var index = 0; index < order.length; index++) order[index]: index,
    };
    return <V3DepositFolder>[...folders]
      ..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
  }

  void _reorderDepositFolders(
    String? parentFolderId,
    String draggedFolderId,
    String targetFolderId,
    List<V3DepositFolder> visibleFolders,
  ) {
    if (draggedFolderId == targetFolderId) return;
    final key = parentFolderId ?? '__root__';
    final order = _folderOrderByParent.putIfAbsent(
      key,
      () => visibleFolders.map((folder) => folder.id).toList(growable: true),
    );
    final from = order.indexOf(draggedFolderId);
    final target = order.indexOf(targetFolderId);
    if (from < 0 || target < 0) return;
    setState(() {
      order
        ..removeAt(from)
        ..insert(target, draggedFolderId);
    });
    showV3Snack(context, '已调整文件夹顺序');
  }

  void _showFolderDragInstruction() {
    showV3Snack(context, '拖到目标位置后松手');
  }

  Future<void> _moveDepositNote(
    KnowledgeLibraryController controller, {
    required String noteId,
    required V3DepositFolder folder,
  }) async {
    final result = await controller.moveDepositContentToWorkspaceFolder(
      contentId: noteId,
      folderId: folder.id,
    );
    if (!mounted) return;
    if (!result.isSuccess || result.data == null) {
      showV3Snack(context, _workspaceFolderFailureMessage(result.errorCode));
      return;
    }
    showV3Snack(context, '已移动到「${folder.name}」');
  }

  Future<void> _showMyAssetsSort(KnowledgeLibraryController controller) async {
    final sort = await showV3ActionSheet<V3KnowledgeSort>(
      context: context,
      title: '排序方式',
      items: [
        for (final candidate in V3KnowledgeSort.values)
          V3ActionSheetItem(
            value: candidate,
            icon: switch (candidate) {
              V3KnowledgeSort.recentlyUpdated => Icons.update_rounded,
              V3KnowledgeSort.earliestCreated => Icons.history_rounded,
              V3KnowledgeSort.name => Icons.sort_by_alpha_rounded,
            },
            label: candidate.label,
            selected: controller.depositSort == candidate,
          ),
      ],
    );
    if (sort != null) controller.setDepositSort(sort);
  }

  Future<void> _createDepositFolder(
    KnowledgeLibraryController controller, {
    String? parentFolderId,
  }) async {
    final name = await showV3TextInputSheet(
      context: context,
      title: '新建文件夹',
      initialValue: '',
      label: '文件夹名称',
      confirmLabel: '创建',
      maxLength: 20,
      inputKey: const ValueKey('asset-deposit-folder-name'),
      prefixIcon: Icons.folder_outlined,
      suggestions: const <String>['正在学习', '灵感与创作'],
      validator: (value) {
        final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
        if (normalized.isEmpty) return '请输入文件夹名称';
        if (!controller.canUseDepositFolderName(
          name: normalized,
          parentFolderId: parentFolderId,
        )) {
          return '已存在同名文件夹';
        }
        return null;
      },
    );
    if (name == null || !mounted) return;
    final result = await controller.createWorkspaceDepositFolder(
      name,
      parentFolderId: parentFolderId,
    );
    if (!mounted) return;
    final folder = result.data;
    if (!result.isSuccess || folder == null) {
      showV3Snack(context, _workspaceFolderFailureMessage(result.errorCode));
      return;
    }
    setState(() => _depositFolderId = folder.id);
    showV3Snack(context, '已创建文件夹');
  }

  Future<void> _manageDepositFolder(
    KnowledgeLibraryController controller,
    V3DepositFolder folder,
  ) async {
    final action = await showV3ActionSheet<_AssetDepositFolderAction>(
      context: context,
      title: folder.name,
      items: const [
        V3ActionSheetItem(
          value: _AssetDepositFolderAction.rename,
          icon: Icons.drive_file_rename_outline_rounded,
          label: '重命名',
        ),
        V3ActionSheetItem(
          value: _AssetDepositFolderAction.reorder,
          icon: Icons.swap_vert_rounded,
          label: '拖动调整顺序',
        ),
        V3ActionSheetItem(
          value: _AssetDepositFolderAction.delete,
          icon: Icons.delete_outline_rounded,
          label: '删除文件夹',
          destructive: true,
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _AssetDepositFolderAction.rename:
        await _renameDepositFolder(controller, folder);
        return;
      case _AssetDepositFolderAction.reorder:
        _showFolderDragInstruction();
        return;
      case _AssetDepositFolderAction.delete:
        await _deleteDepositFolder(controller, folder);
        return;
    }
  }

  Future<void> _renameDepositFolder(
    KnowledgeLibraryController controller,
    V3DepositFolder folder,
  ) async {
    final name = await showV3TextInputSheet(
      context: context,
      title: '重命名文件夹',
      initialValue: folder.name,
      label: '文件夹名称',
      confirmLabel: '保存',
      maxLength: 20,
      inputKey: const ValueKey('asset-deposit-folder-rename'),
      prefixIcon: Icons.folder_outlined,
      validator: (value) {
        final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
        if (normalized.isEmpty) return '请输入文件夹名称';
        if (!controller.canUseDepositFolderName(
          name: normalized,
          parentFolderId: folder.parentFolderId,
          excludingFolderId: folder.id,
        )) {
          return '已存在同名文件夹';
        }
        return null;
      },
    );
    if (name == null || !mounted) return;
    final result = await controller.renameWorkspaceDepositFolder(
      folderId: folder.id,
      name: name,
    );
    if (!mounted) return;
    if (!result.isSuccess || result.data == null) {
      showV3Snack(context, _workspaceFolderFailureMessage(result.errorCode));
      return;
    }
    showV3Snack(context, '文件夹已重命名');
  }

  Future<void> _deleteDepositFolder(
    KnowledgeLibraryController controller,
    V3DepositFolder folder,
  ) async {
    final confirmed = await showV3DestructiveConfirmationSheet(
      context: context,
      title: '删除文件夹',
      message: '删除后，文件夹内笔记不会被删除',
      itemLabel: folder.name,
      warning: '${controller.depositFolderNoteCount(folder.id)} 条笔记将移至「未归档」',
      itemIcon: Icons.folder_delete_outlined,
    );
    if (!confirmed || !mounted) return;
    final result = await controller.deleteWorkspaceDepositFolder(folder.id);
    if (!mounted) return;
    if (!result.isSuccess || result.data != true) {
      showV3Snack(context, _workspaceFolderFailureMessage(result.errorCode));
      return;
    }
    setState(() => _depositFolderId = folder.parentFolderId);
    showV3Snack(context, '文件夹已删除');
  }

  Future<void> _showNoteActions(
    KnowledgeLibraryController controller,
    V3FeedItem note, {
    bool inDeposits = false,
  }) async {
    final action = await showV3KnowledgeNoteActions(
      context: context,
      note: note,
      inDeposits: inDeposits,
      isDeposited: controller.isDeposited(note.id),
    );
    if (!mounted || action == null) return;
    if (action == V3KnowledgeNoteAction.share) {
      await shareV3KnowledgeNoteAsMarkdown(context, ref, note);
      return;
    }
    await handleV3KnowledgeNoteAction(context, ref, note, action);
  }

  void _openContent(String contentId) {
    context.push('/v3/feed/items/${Uri.encodeComponent(contentId)}?stage=raw');
  }

  Future<void> _pickAlbumPhotos() async {
    final result = await ref.read(photoAlbumControllerProvider).pickAndImport();
    if (!mounted || result == null) return;
    final message = result.importedCount == 0
        ? '所选照片已在云端影像中'
        : result.duplicateCount == 0
        ? '已保存 ${result.importedCount} 张到云端影像'
        : '已保存 ${result.importedCount} 张，跳过 ${result.duplicateCount} 张重复照片';
    showV3Snack(context, message);
  }

  Future<void> _openPhoto(V3PhotoAlbumEntry entry) async {
    final result = await context.push<PhotoAlbumDeleteResult>(
      AppRoutePaths.photoAlbumPreview(entry.resourceId),
    );
    if (!mounted || result == null) return;
    showV3Snack(context, photoAlbumDeleteSuccessMessage(result));
  }
}

enum _AssetDepositFolderAction { rename, reorder, delete }

enum V3MyAssetsSection {
  deposited('deposited', '已沉淀'),
  mediaResources('media', '影像');

  const V3MyAssetsSection(this.routeName, this.label);

  final String routeName;
  final String label;
}

V3MyAssetsSection v3MyAssetsSectionFromRouteParameter(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == V3MyAssetsSection.mediaResources.routeName) {
    return V3MyAssetsSection.mediaResources;
  }
  return V3MyAssetsSection.deposited;
}

class _AssetSummaryChip extends StatelessWidget {
  const _AssetSummaryChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          label,
          style: TextStyle(color: colors.muted, fontSize: 10, height: 1.1),
        ),
      ),
    );
  }
}

final class _AssetDerivedTaskState {
  const _AssetDerivedTaskState({required this.stage, required this.status});

  final V3DerivedTaskStage stage;
  final String status;
}

List<_AssetDerivedTaskState> _assetDerivedTasks(
  V3FeedItem note,
  DerivedPartRunTrackingPort tracker,
) {
  final states = <_AssetDerivedTaskState>[];
  for (final stage in V3DerivedTaskStage.values) {
    final localStatus = switch (stage) {
      V3DerivedTaskStage.outline => tracker.derivedOutlineStatus(note.id),
      V3DerivedTaskStage.sprout => tracker.derivedGerminationStatus(note.id),
    };
    final remoteStatus = note.activeDerivedTasks
        .where((task) => task.stage == stage && !task.isTerminal)
        .map((task) => task.status)
        .firstOrNull;
    final status = localStatus ?? remoteStatus;
    if (status == null || _isAssetDerivedTerminalStatus(status)) continue;
    states.add(_AssetDerivedTaskState(stage: stage, status: status));
  }
  return List<_AssetDerivedTaskState>.unmodifiable(states);
}

bool _isAssetDerivedTerminalStatus(String status) => const <String>{
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'conflict',
}.contains(status);

String _assetDerivedTaskLabel(_AssetDerivedTaskState task) {
  final prefix = task.stage.label;
  return switch (task.status) {
    'admitting' || 'queued' => '$prefix排队中',
    'finalizing' => '$prefix正在写入资产',
    _ => '$prefix运行中',
  };
}

class _AssetDerivedTaskIndicator extends StatelessWidget {
  const _AssetDerivedTaskIndicator({required this.tasks});

  final List<_AssetDerivedTaskState> tasks;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final label = tasks.map(_assetDerivedTaskLabel).join(' · ');
    return Semantics(
      label: label,
      child: Row(
        key: ValueKey('asset-derived-task-$label'),
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.7,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _assetPlainExcerpt(V3FeedItem note) {
  final summary = note.summaryBody?.trim();
  final source = summary != null && summary.isNotEmpty
      ? summary
      : note.rawBody.trim();
  if (source.isEmpty) return '暂无摘要';
  return source
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^\)]+\)'),
        (match) => match.group(1) ?? '',
      )
      .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'[*_`>]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _formatAssetRelativeDate(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final date = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final prefix = date == today
      ? '今天'
      : date == today.subtract(const Duration(days: 1))
      ? '昨天'
      : '${local.month}月${local.day}日';
  return '$prefix ${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

class _AssetFolderSectionHeader extends StatelessWidget {
  const _AssetFolderSectionHeader({
    required this.folder,
    required this.noteCount,
    required this.onOpen,
    required this.expanded,
    required this.onToggle,
    required this.onActions,
    required this.onMoveNote,
    required this.onReorderFolder,
    required this.onDragStarted,
    super.key,
  });

  final V3DepositFolder folder;
  final int noteCount;
  final VoidCallback onOpen;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onActions;
  final ValueChanged<String> onMoveNote;
  final ValueChanged<String> onReorderFolder;
  final VoidCallback onDragStarted;

  @override
  Widget build(BuildContext context) {
    final dragData = _AssetFolderDragPayload(folder.id);
    return LongPressDraggable<_AssetDragPayload>(
      key: ValueKey('asset-folder-drag-${folder.id}'),
      data: dragData,
      onDragStarted: onDragStarted,
      feedback: Material(
        color: Colors.transparent,
        elevation: 10,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width - 40,
          child: _surface(context, highlighted: true, interactive: false),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: .24,
        child: _target(context, dragData),
      ),
      child: _target(context, dragData),
    );
  }

  Widget _target(BuildContext context, _AssetFolderDragPayload dragData) {
    return DragTarget<_AssetDragPayload>(
      onWillAcceptWithDetails: (details) => switch (details.data) {
        _AssetNoteDragPayload() => true,
        _AssetFolderDragPayload(:final folderId) =>
          folderId != dragData.folderId,
      },
      onAcceptWithDetails: (details) {
        switch (details.data) {
          case _AssetNoteDragPayload(:final noteId):
            onMoveNote(noteId);
          case _AssetFolderDragPayload(:final folderId):
            onReorderFolder(folderId);
        }
      },
      builder: (context, candidates, _) => _surface(
        context,
        highlighted: candidates.isNotEmpty,
        interactive: true,
      ),
    );
  }

  Widget _surface(
    BuildContext context, {
    required bool highlighted,
    required bool interactive,
  }) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: colors.surfaceMuted,
      shape: highlighted
          ? RoundedRectangleBorder(
              side: BorderSide(color: colors.accent, width: 1.4),
              borderRadius: BorderRadius.circular(10),
            )
          : null,
      borderRadius: highlighted ? null : BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, color: colors.primary, size: 18),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '$noteCount 条笔记',
                        style: TextStyle(fontSize: 10, color: colors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('asset-folder-toggle-${folder.id}'),
                  tooltip: expanded ? '收起 ${folder.name}' : '展开 ${folder.name}',
                  onPressed: interactive ? onToggle : null,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 44,
                  ),
                  padding: EdgeInsets.zero,
                  icon: V3DisclosureChevron(expanded: expanded, size: 18),
                ),
                IconButton(
                  key: interactive
                      ? ValueKey('asset-deposit-folder-actions-${folder.id}')
                      : null,
                  tooltip: '管理文件夹 ${folder.name}',
                  onPressed: interactive ? onActions : null,
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 44,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_vert_rounded, size: 17),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssetFolderDirectoryRow extends StatelessWidget {
  const _AssetFolderDirectoryRow({
    required this.folder,
    required this.noteCount,
    required this.childFolderCount,
    required this.onOpen,
    required this.onActions,
    required this.onMoveNote,
    required this.onReorderFolder,
    required this.onDragStarted,
    super.key,
  });

  final V3DepositFolder folder;
  final int noteCount;
  final int childFolderCount;
  final VoidCallback onOpen;
  final VoidCallback onActions;
  final ValueChanged<String> onMoveNote;
  final ValueChanged<String> onReorderFolder;
  final VoidCallback onDragStarted;

  @override
  Widget build(BuildContext context) {
    final dragData = _AssetFolderDragPayload(folder.id);
    return LongPressDraggable<_AssetDragPayload>(
      key: ValueKey('asset-folder-drag-${folder.id}'),
      data: dragData,
      onDragStarted: onDragStarted,
      feedback: Material(
        color: HuahuoV3Theme.tokensOf(context).canvas,
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 144,
          child: _target(context, dragData, interactive: false),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: .24,
        child: _target(context, dragData, interactive: true),
      ),
      child: _target(context, dragData, interactive: true),
    );
  }

  Widget _target(
    BuildContext context,
    _AssetFolderDragPayload dragData, {
    required bool interactive,
  }) {
    return DragTarget<_AssetDragPayload>(
      onWillAcceptWithDetails: (details) => switch (details.data) {
        _AssetNoteDragPayload() => true,
        _AssetFolderDragPayload(:final folderId) =>
          folderId != dragData.folderId,
      },
      onAcceptWithDetails: (details) {
        switch (details.data) {
          case _AssetNoteDragPayload(:final noteId):
            onMoveNote(noteId);
          case _AssetFolderDragPayload(:final folderId):
            onReorderFolder(folderId);
        }
      },
      builder: (context, candidates, _) => _surface(
        context,
        highlighted: candidates.isNotEmpty,
        interactive: interactive,
      ),
    );
  }

  Widget _surface(
    BuildContext context, {
    required bool highlighted,
    required bool interactive,
  }) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final total = childFolderCount + noteCount;
    return AnimatedContainer(
      duration: V3MotionTokens.responsive,
      width: 144,
      decoration: highlighted
          ? BoxDecoration(
              border: Border.all(color: colors.accent),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Semantics(
            button: true,
            label: '文件夹 ${folder.name}，$childFolderCount 个子文件夹，$noteCount 篇笔记',
            child: Row(
              children: [
                Icon(Icons.folder_outlined, color: colors.ink, size: 18),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (total > 0)
                  Text(
                    '$total',
                    style: TextStyle(fontSize: 11, color: colors.muted),
                  ),
                IconButton(
                  key: interactive
                      ? ValueKey('asset-deposit-folder-actions-${folder.id}')
                      : null,
                  tooltip: '管理文件夹 ${folder.name}',
                  onPressed: interactive ? onActions : null,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_horiz_rounded, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _AssetNoteSection {
  const _AssetNoteSection({required this.header, required this.notes});

  final Widget header;
  final List<V3FeedItem> notes;
}

sealed class _AssetDragPayload {
  const _AssetDragPayload();
}

final class _AssetNoteDragPayload extends _AssetDragPayload {
  const _AssetNoteDragPayload(this.noteId);

  final String noteId;
}

final class _AssetFolderDragPayload extends _AssetDragPayload {
  const _AssetFolderDragPayload(this.folderId);

  final String folderId;
}

class _AssetNoteDragFeedback extends StatelessWidget {
  const _AssetNoteDragFeedback({required this.note});

  final V3FeedItem note;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 10),
      decoration: BoxDecoration(
        color: colors.canvas,
        border: Border.all(color: colors.accent),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            note.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          Text(
            _assetPlainExcerpt(note),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.muted, fontSize: 13, height: 1.42),
          ),
        ],
      ),
    );
  }
}

class _AssetNoteList extends StatefulWidget {
  const _AssetNoteList({
    required this.notes,
    required this.emptyLabel,
    required this.controller,
    required this.taskTracker,
    required this.onOpen,
    required this.onActions,
    this.onDragStarted,
    this.sections = const <_AssetNoteSection>[],
    this.leadingEntries = const <Widget>[],
    super.key,
  });

  final List<V3FeedItem> notes;
  final String emptyLabel;
  final KnowledgeLibraryController controller;
  final DerivedPartRunTrackingPort taskTracker;
  final List<_AssetNoteSection> sections;
  final List<Widget> leadingEntries;
  final ValueChanged<String> onOpen;
  final ValueChanged<V3FeedItem> onActions;
  final VoidCallback? onDragStarted;

  @override
  State<_AssetNoteList> createState() => _AssetNoteListState();
}

class _AssetNoteListState extends State<_AssetNoteList> {
  final Set<String> _expandedNoteIds = <String>{};
  final Map<String, Set<String>> _expandedHeadingIds = <String, Set<String>>{};
  final Map<String, V3KnowledgeNoteOutline> _outlineCache =
      <String, V3KnowledgeNoteOutline>{};

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final entries = <Object>[...widget.leadingEntries];
    for (final section in widget.sections) {
      entries
        ..add(section.header)
        ..addAll(section.notes);
    }
    entries.addAll(widget.notes);
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            widget.emptyLabel,
            style: HuahuoV3Theme.body.copyWith(color: colors.muted),
          ),
        ),
      );
    }
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry case final Widget leading) return leading;
        final note = entry as V3FeedItem;
        final expanded = _expandedNoteIds.contains(note.id);
        final derivedTasks = _assetDerivedTasks(note, widget.taskTracker);
        final card = _buildSummaryNote(note, expanded, derivedTasks, colors);
        if (widget.onDragStarted == null) return card;
        return LongPressDraggable<_AssetDragPayload>(
          key: ValueKey('asset-note-drag-${note.id}'),
          data: _AssetNoteDragPayload(note.id),
          onDragStarted: widget.onDragStarted,
          feedback: Material(
            color: Colors.transparent,
            elevation: 10,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: MediaQuery.sizeOf(context).width - 44,
              child: _AssetNoteDragFeedback(note: note),
            ),
          ),
          childWhenDragging: Opacity(opacity: .18, child: card),
          child: card,
        );
      },
    );
  }

  Widget _buildSummaryNote(
    V3FeedItem note,
    bool expanded,
    List<_AssetDerivedTaskState> derivedTasks,
    HuahuoV3ThemeTokens colors,
  ) {
    final folderName = widget.controller.depositFolderNameFor(note.id);
    return DecoratedBox(
      key: ValueKey('knowledge-note-card-${note.id}'),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            label: '查看笔记 ${note.title}',
            child: InkWell(
              key: ValueKey('asset-note-open-${note.id}'),
              onTap: () => widget.onOpen(note.id),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            note.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          key: ValueKey('asset-note-expand-${note.id}'),
                          tooltip: '${expanded ? '收起' : '展开'} ${note.title}',
                          onPressed: () => _toggleNote(note.id),
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          icon: V3DisclosureChevron(expanded: expanded),
                        ),
                        IconButton(
                          key: ValueKey('asset-note-actions-${note.id}'),
                          tooltip: '笔记操作 ${note.title}',
                          onPressed: () => widget.onActions(note),
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.more_horiz_rounded, size: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _assetPlainExcerpt(note),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.muted,
                        fontSize: 13,
                        height: 1.42,
                      ),
                    ),
                    if (derivedTasks.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _AssetDerivedTaskIndicator(tasks: derivedTasks),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        _AssetSummaryChip(label: '来源 · ${note.source.label}'),
                        if (folderName != null)
                          _AssetSummaryChip(label: '文件夹 · $folderName'),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '${_formatAssetRelativeDate(note.updatedAt)} 更新',
                      style: TextStyle(color: colors.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded) _buildExpandedBody(note),
        ],
      ),
    );
  }

  void _toggleNote(String noteId) {
    setState(() {
      if (!_expandedNoteIds.remove(noteId)) {
        _expandedNoteIds.add(noteId);
      }
    });
  }

  V3KnowledgeOutlineStageContent _rawOutline(V3FeedItem note) {
    final cacheKey =
        '${note.id}|${note.updatedAt.microsecondsSinceEpoch}|${note.sproutReport?.id ?? ''}';
    final cached = _outlineCache[cacheKey];
    if (cached != null) return cached.stage(V3KnowledgeOutlineStage.raw);
    _outlineCache.removeWhere((key, _) => key.startsWith('${note.id}|'));
    final outline = V3KnowledgeNoteOutline.fromNote(note);
    _outlineCache[cacheKey] = outline;
    return outline.stage(V3KnowledgeOutlineStage.raw);
  }

  Widget _buildExpandedBody(V3FeedItem note) {
    final raw = _rawOutline(note);
    final leadingMarkdown = _leadingMarkdown(raw);
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      key: ValueKey('asset-note-expanded-${note.id}'),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: !raw.hasContent
            ? Text('暂无原始内容', style: TextStyle(color: colors.muted))
            : raw.hasHeadings
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (leadingMarkdown.isNotEmpty)
                    Padding(
                      key: ValueKey('asset-note-leading-${note.id}'),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: V3AssistantReplyMarkdown(source: leadingMarkdown),
                    ),
                  for (final heading in raw.headings)
                    _buildHeading(note.id, heading, 0),
                ],
              )
            : V3AssistantReplyMarkdown(
                key: ValueKey('asset-note-raw-body-${note.id}'),
                source: raw.source,
              ),
      ),
    );
  }

  String _leadingMarkdown(V3KnowledgeOutlineStageContent raw) {
    if (!raw.hasHeadings) return '';
    final firstHeadingLine = raw.headings.first.lineIndex;
    if (firstHeadingLine <= 0) return '';
    return raw.source
        .split(RegExp(r'\r?\n'))
        .take(firstHeadingLine)
        .join('\n')
        .trim();
  }

  Widget _buildHeading(
    String noteId,
    V3KnowledgeOutlineHeading heading,
    int depth,
  ) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final expandedHeadings = _expandedHeadingIds.putIfAbsent(
      noteId,
      () => <String>{},
    );
    final expanded = expandedHeadings.contains(heading.sectionId);
    return Padding(
      padding: EdgeInsets.only(left: (depth * 14).clamp(0, 56).toDouble()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('asset-heading-$noteId-${heading.sectionId}'),
            onTap: () => setState(() {
              if (!expandedHeadings.remove(heading.sectionId)) {
                expandedHeadings.add(heading.sectionId);
              }
            }),
            borderRadius: BorderRadius.circular(6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  V3DisclosureChevron(expanded: expanded, size: 19),
                  const SizedBox(width: 6),
                  Expanded(
                    child: V3AssistantReplyMarkdown(
                      source: '${'#' * heading.level} ${heading.title}',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            if (heading.directMarkdown.isNotEmpty)
              Padding(
                key: ValueKey(
                  'asset-heading-body-$noteId-${heading.sectionId}',
                ),
                padding: const EdgeInsets.fromLTRB(25, 2, 4, 8),
                child: V3AssistantReplyMarkdown(source: heading.directMarkdown),
              ),
            for (final child in heading.children)
              _buildHeading(noteId, child, depth + 1),
            if (heading.children.isEmpty && heading.directMarkdown.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(25, 2, 4, 8),
                child: Text(
                  '该标题下暂无正文',
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

String _workspaceFolderFailureMessage(String? errorCode) => switch (errorCode) {
  'WORKSPACE_FOLDER_NAME_INVALID' => '文件夹名称无效或已存在',
  'WORKSPACE_NOTE_SYNC_REQUIRED' => '笔记正在同步，完成后可移动到文件夹',
  'PRECONDITION_FAILED' || 'NOTE_BATCH_MOVE_CONFLICT' => '内容已在其他设备更新，已刷新后重试',
  'WORKSPACE_CONTEXT_UNAVAILABLE' ||
  'WORKSPACE_FOLDER_UNAVAILABLE' => '云端工作空间尚未就绪',
  _ => '云端目录操作失败，请重试',
};
