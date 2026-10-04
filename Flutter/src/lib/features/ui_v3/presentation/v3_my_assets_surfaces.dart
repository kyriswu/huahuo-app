import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di/media_cache_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/native_file_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../chat/application/resource_image_reader.dart';
import '../application/photo_album_controller.dart';
import '../domain/photo_album_models.dart';
import '../domain/knowledge_library_models.dart';

enum _AssetSearchGroup { time, source, tags, sort }

class V3AssetSearchFilters extends StatefulWidget {
  const V3AssetSearchFilters({
    required this.filters,
    required this.availableTags,
    required this.onChanged,
    super.key,
  });

  final KnowledgeAssetSearchFilters filters;
  final List<String> availableTags;
  final ValueChanged<KnowledgeAssetSearchFilters> onChanged;

  @override
  State<V3AssetSearchFilters> createState() => _V3AssetSearchFiltersState();
}

class _V3AssetSearchFiltersState extends State<V3AssetSearchFilters> {
  _AssetSearchGroup? _expanded;

  @override
  Widget build(BuildContext context) {
    final filters = widget.filters;
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  key: const ValueKey('asset-search-all'),
                  label: const Text('全部'),
                  selected: !filters.hasFilters,
                  onSelected: (_) {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setState(() => _expanded = null);
                    widget.onChanged(KnowledgeAssetSearchFilters());
                  },
                ),
              ),
              _groupChip(
                _AssetSearchGroup.time,
                filters.time == KnowledgeTimeFilter.all
                    ? '时间'
                    : filters.time.label,
                filters.time != KnowledgeTimeFilter.all,
              ),
              _groupChip(
                _AssetSearchGroup.source,
                filters.source == KnowledgeSourceCategory.all
                    ? '类型'
                    : _sourceLabel(filters.source),
                filters.source != KnowledgeSourceCategory.all,
              ),
              _groupChip(
                _AssetSearchGroup.tags,
                filters.tags.isEmpty ? '标签' : '标签 ${filters.tags.length}',
                filters.tags.isNotEmpty,
              ),
              _groupChip(_AssetSearchGroup.sort, filters.sort.label, false),
            ],
          ),
        ),
        if (_expanded case final group?)
          Container(
            key: ValueKey('asset-search-options-${group.name}'),
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(switch (group) {
                  _AssetSearchGroup.time => '按笔记更新时间',
                  _AssetSearchGroup.source => '按笔记来源类型',
                  _AssetSearchGroup.tags => '来自实际笔记 · 多选时匹配任一标签',
                  _AssetSearchGroup.sort => '结果排序',
                }, style: TextStyle(color: colors.muted, fontSize: 12)),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 144),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: _options(group),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _groupChip(_AssetSearchGroup group, String label, bool active) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          key: ValueKey('asset-search-group-${group.name}'),
          label: Text(label),
          selected: active,
          showCheckmark: false,
          avatar: Icon(
            _expanded == group ? Icons.expand_less : Icons.expand_more,
            size: 16,
          ),
          onSelected: (_) {
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() => _expanded = _expanded == group ? null : group);
          },
        ),
      );

  List<Widget> _options(_AssetSearchGroup group) {
    final filters = widget.filters;
    return switch (group) {
      _AssetSearchGroup.time => [
        for (final value in KnowledgeTimeFilter.values.where(
          (value) => value != KnowledgeTimeFilter.custom,
        ))
          ChoiceChip(
            key: ValueKey('asset-search-time-${value.name}'),
            label: Text(value.label),
            selected: filters.time == value,
            onSelected: (_) => widget.onChanged(filters.copyWith(time: value)),
          ),
      ],
      _AssetSearchGroup.source => [
        for (final value in KnowledgeSourceCategory.values)
          ChoiceChip(
            key: ValueKey('asset-search-source-${value.name}'),
            label: Text(_sourceLabel(value)),
            selected: filters.source == value,
            onSelected: (_) =>
                widget.onChanged(filters.copyWith(source: value)),
          ),
      ],
      _AssetSearchGroup.tags => [
        if (widget.availableTags.isEmpty) const Text('当前笔记还没有标签'),
        for (final tag in widget.availableTags)
          FilterChip(
            key: ValueKey('asset-search-tag-$tag'),
            label: Text(tag),
            selected: filters.tags.contains(tag.toLowerCase()),
            onSelected: (selected) {
              final tags = {...filters.tags};
              if (selected) {
                tags.add(tag.toLowerCase());
              } else {
                tags.remove(tag.toLowerCase());
              }
              widget.onChanged(filters.copyWith(tags: tags));
            },
          ),
      ],
      _AssetSearchGroup.sort => [
        for (final value in V3KnowledgeSort.values)
          ChoiceChip(
            key: ValueKey('asset-search-sort-${value.name}'),
            label: Text(value.label),
            selected: filters.sort == value,
            onSelected: (_) => widget.onChanged(filters.copyWith(sort: value)),
          ),
      ],
    };
  }

  String _sourceLabel(KnowledgeSourceCategory value) => switch (value) {
    KnowledgeSourceCategory.all => '全部类型',
    KnowledgeSourceCategory.manual => '文字笔记',
    _ => value.label,
  };
}

class V3MyAssetsToolbarButton extends StatelessWidget {
  const V3MyAssetsToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.emphasized = false,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: BorderSide(color: emphasized ? colors.accent : colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 40,
            child: Icon(
              icon,
              size: 20,
              color: emphasized ? colors.accent : colors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class V3MyAssetsPhotoAlbumGrid extends StatelessWidget {
  const V3MyAssetsPhotoAlbumGrid({
    required this.controller,
    required this.onOpen,
    super.key,
  });

  final PhotoAlbumController controller;
  final ValueChanged<V3PhotoAlbumEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    if (controller.status == PhotoAlbumStatus.loading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    if (controller.entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Text(
            controller.errorCode == null ? '从右上角添加照片' : '照片暂时无法读取，请稍后重试',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.muted),
          ),
        ),
      );
    }
    return GridView.builder(
      key: const PageStorageKey<String>('photo-album-grid'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
      ),
      itemCount: controller.entries.length,
      itemBuilder: (context, index) {
        final entry = controller.entries[index];
        return Semantics(
          button: true,
          label: '查看照片 ${entry.displayName}',
          child: InkWell(
            key: ValueKey('photo-album-item-${entry.id}'),
            onTap: () => onOpen(entry),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: _CloudPhoto(entry: entry, fit: BoxFit.cover),
            ),
          ),
        );
      },
    );
  }
}

class V3PhotoAlbumPreviewPage extends ConsumerStatefulWidget {
  const V3PhotoAlbumPreviewPage({required this.resourceId, super.key});

  final String resourceId;

  @override
  ConsumerState<V3PhotoAlbumPreviewPage> createState() =>
      _V3PhotoAlbumPreviewPageState();
}

class _V3PhotoAlbumPreviewPageState
    extends ConsumerState<V3PhotoAlbumPreviewPage> {
  var _deleting = false;
  var _saving = false;
  var _remoteAvailabilityCheckScheduled = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<PhotoAlbumController>(
      photoAlbumControllerProvider,
      (_, next) => _requestRemoteAvailabilityCheck(next),
      fireImmediately: true,
    );
  }

  @override
  void didUpdateWidget(covariant V3PhotoAlbumPreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resourceId == widget.resourceId) return;
    _remoteAvailabilityCheckScheduled = false;
    _requestRemoteAvailabilityCheck(ref.read(photoAlbumControllerProvider));
  }

  Future<void> _delete(V3PhotoAlbumEntry entry) async {
    if (_deleting || _saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '删除这张影像？',
        message: '删除后会立即停止播放和后续使用；被内容引用的影像无法删除。',
        primaryLabel: '删除',
        onPrimary: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    final result = await ref
        .read(photoAlbumControllerProvider)
        .deleteResource(entry.resourceId);
    if (!mounted) return;
    if (result != null) {
      if (!canReturnToPreviousRoute(context)) {
        showV3Snack(context, photoAlbumDeleteSuccessMessage(result));
      }
      await returnToPreviousRoute(
        context,
        result: result,
        fallbackRoute: AppRoutePaths.assetsMedia,
      );
      return;
    }
    setState(() => _deleting = false);
    showV3Snack(context, _photoDeleteFailureMessage());
  }

  Future<void> _save(V3PhotoAlbumEntry entry) async {
    if (_saving || _deleting) return;
    setState(() => _saving = true);
    try {
      final image = await ref
          .read(resourceImageCacheProvider)
          .load(entry.resourceId);
      final saved = await ref
          .read(photoAlbumNativeFilePortProvider)
          .saveImageToGallery(
            bytes: image.bytes,
            displayName: _photoAlbumGalleryDisplayName(
              entry.displayName,
              image.mimeType,
            ),
            mimeType: image.mimeType,
          );
      if (!mounted) return;
      showV3Snack(
        context,
        saved.ok && saved.value == true ? '图片已保存到本地相册' : '保存图片失败，请重试',
      );
    } on Object {
      if (mounted) showV3Snack(context, '保存图片失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _photoDeleteFailureMessage() {
    return switch (ref.read(photoAlbumControllerProvider).errorCode) {
      'RESOURCE_IN_USE' => '影像仍被笔记、聊天或任务使用，无法删除',
      _ => '删除失败，请稍后重试',
    };
  }

  void _leavePreview() {
    unawaited(
      returnToPreviousRoute(context, fallbackRoute: AppRoutePaths.assetsMedia),
    );
  }

  void _requestRemoteAvailabilityCheck(PhotoAlbumController controller) {
    if (_photoAlbumEntry(controller, widget.resourceId) != null) return;
    if (_remoteAvailabilityCheckScheduled || _deleting) return;
    _remoteAvailabilityCheckScheduled = true;
    scheduleMicrotask(() {
      if (!mounted || _deleting) return;
      unawaited(
        _checkRemoteAvailability(
          controller: controller,
          resourceId: widget.resourceId,
        ),
      );
    });
  }

  Future<void> _checkRemoteAvailability({
    required PhotoAlbumController controller,
    required String resourceId,
  }) async {
    await controller.load(forceRemote: true);
    if (!mounted || _deleting || widget.resourceId != resourceId) return;
    final latest = ref.read(photoAlbumControllerProvider);
    if (!identical(latest, controller)) {
      _remoteAvailabilityCheckScheduled = false;
      _requestRemoteAvailabilityCheck(latest);
      return;
    }
    if (_photoAlbumEntry(latest, resourceId) == null) {
      _leavePreview();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final album = ref.watch(photoAlbumControllerProvider);
    final entry = _photoAlbumEntry(album, widget.resourceId);
    if (entry == null) {
      return Scaffold(
        key: const ValueKey('photo-album-preview-unavailable'),
        backgroundColor: colors.canvas,
        body: const Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final previewEntry = entry;
    return Scaffold(
      key: const ValueKey('photo-album-preview'),
      backgroundColor: colors.canvas,
      appBar: AppBar(
        leading: V3NavigationBackButton(
          tooltip: '返回',
          onPressed: _leavePreview,
        ),
        title: Text(previewEntry.displayName),
        actions: [
          IconButton(
            key: const ValueKey('photo-album-save'),
            tooltip: '保存到本地',
            onPressed: _saving || _deleting ? null : () => _save(previewEntry),
            icon: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_rounded),
          ),
          IconButton(
            key: const ValueKey('photo-album-delete'),
            tooltip: '删除影像',
            onPressed: _deleting || _saving
                ? null
                : () => _delete(previewEntry),
            icon: _deleting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: _CloudPhoto(
            entry: previewEntry,
            fit: BoxFit.contain,
            highResolution: true,
          ),
        ),
      ),
    );
  }
}

V3PhotoAlbumEntry? _photoAlbumEntry(
  PhotoAlbumController controller,
  String resourceId,
) {
  for (final entry in controller.entries) {
    if (entry.resourceId == resourceId) return entry;
  }
  return null;
}

String _photoAlbumGalleryDisplayName(String displayName, String mimeType) {
  final extension = switch (mimeType.trim().toLowerCase()) {
    'image/jpeg' => '.jpg',
    'image/webp' => '.webp',
    _ => '.png',
  };
  var stem = displayName
      .trim()
      .replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_')
      .replaceAll('..', '_')
      .replaceFirst(RegExp(r'\.(?:jpe?g|png|webp)$', caseSensitive: false), '')
      .trim();
  if (stem.isEmpty || stem == '.') stem = '花火影像';
  final maxStemLength = 128 - extension.length;
  final boundedStem = StringBuffer();
  for (final rune in stem.runes) {
    final character = String.fromCharCode(rune);
    if (boundedStem.length + character.length > maxStemLength) break;
    boundedStem.write(character);
  }
  stem = boundedStem.toString();
  return '$stem$extension';
}

String photoAlbumDeleteSuccessMessage(PhotoAlbumDeleteResult result) =>
    result.isPendingCleanup ? '已停止使用影像，正在完成清理' : '影像已删除';

class _CloudPhoto extends ConsumerStatefulWidget {
  const _CloudPhoto({
    required this.entry,
    required this.fit,
    this.highResolution = false,
  });

  final V3PhotoAlbumEntry entry;
  final BoxFit fit;
  final bool highResolution;

  @override
  ConsumerState<_CloudPhoto> createState() => _CloudPhotoState();
}

class _CloudPhotoState extends ConsumerState<_CloudPhoto> {
  late Future<CachedResourceImage> _image;

  @override
  void initState() {
    super.initState();
    _image = ref.read(resourceImageCacheProvider).load(widget.entry.resourceId);
  }

  @override
  void didUpdateWidget(covariant _CloudPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.resourceId != widget.entry.resourceId) {
      _image = ref
          .read(resourceImageCacheProvider)
          .load(widget.entry.resourceId);
    }
  }

  void _retry() {
    setState(() {
      _image = ref
          .read(resourceImageCacheProvider)
          .load(widget.entry.resourceId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return FutureBuilder<CachedResourceImage>(
      future: _image,
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image != null) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final dpr = MediaQuery.devicePixelRatioOf(context);
              final quality = widget.highResolution ? 2.0 : 1.0;
              final cacheWidth = constraints.maxWidth.isFinite
                  ? (constraints.maxWidth * dpr * quality)
                        .ceil()
                        .clamp(1, 4096)
                        .toInt()
                  : null;
              final cacheHeight = constraints.maxHeight.isFinite
                  ? (constraints.maxHeight * dpr * quality)
                        .ceil()
                        .clamp(1, 4096)
                        .toInt()
                  : null;
              return Image.memory(
                image.bytes,
                key: ValueKey<String>(
                  'photo-${widget.entry.resourceId}-${widget.entry.version}-'
                  '$cacheWidth-$cacheHeight',
                ),
                fit: widget.fit,
                gaplessPlayback: true,
                cacheWidth: cacheWidth,
                cacheHeight: cacheHeight,
                frameBuilder: widget.highResolution
                    ? (context, child, frame, synchronous) {
                        if (synchronous || frame != null) return child;
                        return Image.memory(
                          image.bytes,
                          fit: widget.fit,
                          cacheWidth: cacheWidth?.clamp(1, 512).toInt(),
                          cacheHeight: cacheHeight?.clamp(1, 512).toInt(),
                        );
                      }
                    : null,
                errorBuilder: (_, __, ___) => const _PhotoUnavailable(),
              );
            },
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return ColoredBox(
            color: colors.surfaceMuted,
            child: const Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return Center(
          child: IconButton(
            tooltip: '重新加载影像',
            onPressed: _retry,
            icon: const Icon(Icons.refresh_rounded),
          ),
        );
      },
    );
  }
}

class _PhotoUnavailable extends StatelessWidget {
  const _PhotoUnavailable();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: HuahuoV3Theme.tokensOf(context).surfaceMuted,
    child: const Center(child: Icon(Icons.broken_image_outlined, size: 32)),
  );
}
