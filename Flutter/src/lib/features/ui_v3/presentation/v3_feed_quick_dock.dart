import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_chat_mark.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../chat/domain/chat_models.dart';
import 'v3_feed_capture_sheets.dart';
import 'v3_feed_navigation_sheets.dart';

/// AI-feeding controls embedded in the shell's first bottom-mode page.
class V3FeedQuickDock extends StatelessWidget {
  const V3FeedQuickDock({
    this.enabled = true,
    this.canActivate,
    this.onOpenWorkbench,
    super.key,
  });

  static const preferredWidth = 224.0;
  static const minimumUsableWidth = 134.0;

  final bool enabled;
  final bool Function()? canActivate;
  final VoidCallback? onOpenWorkbench;

  VoidCallback? _guardAction(VoidCallback action) => enabled
      ? () {
          if (canActivate?.call() ?? true) action();
        }
      : null;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: V3FloatingGlassDockSurface(
              borderRadius: 27,
              child: SizedBox(
                height: 54,
                child: Stack(
                  children: [
                    Row(
                      children: [
                        _DockAction(
                          semanticLabel: '新建',
                          icon: LucideIcons.plus,
                          label: '',
                          showLabel: false,
                          onTap: _guardAction(
                            () => _showMoreWaysSheet(context),
                          ),
                        ),
                        _DockAction(
                          semanticLabel: '独白',
                          icon: Icons.face_retouching_natural_outlined,
                          label: '独白',
                          onTap: _guardAction(() => _showCreateSheet(context)),
                        ),
                        _DockAction(
                          semanticLabel: '创作空间',
                          icon: LucideIcons.penLine,
                          label: '创作空间',
                          onTap: _guardAction(
                            onOpenWorkbench ??
                                () => context.go('/v3?mode=workbench'),
                          ),
                        ),
                      ],
                    ),
                    for (final left in const <double>[75, 149])
                      Positioned(
                        key: ValueKey<String>('feed-dock-divider-$left'),
                        left: left,
                        top: 14,
                        width: 1,
                        height: 26,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.muted.withValues(alpha: .11),
                              borderRadius: BorderRadius.circular(.5),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showCreateSheet(BuildContext context) async {
  final route = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x2E121212),
    elevation: 0,
    builder: (_) => const _CreateNoteSheet(),
  );
  if (route == null || !context.mounted) return;
  if (route == '/v3/feed/monologue') {
    await showV3MonologueQuickCapture(context);
  } else {
    await showV3TextQuickCapture(context);
  }
}

Future<void> _showMoreWaysSheet(BuildContext context) async {
  final action = await showModalBottomSheet<V3FeedImportAction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x1f17191b),
    elevation: 0,
    builder: (sheetContext) => V3FeedMoreWaysSheet(
      onClose: () => Navigator.of(sheetContext).pop(),
      onSelected: (value) => Navigator.of(sheetContext).pop(value),
    ),
  );
  if (!context.mounted || action == null) return;
  context.push(switch (action) {
    V3FeedImportAction.link => AppRoutePaths.freshLinkImport,
    V3FeedImportAction.document => AppRoutePaths.freshDocumentImport,
    V3FeedImportAction.media => AppRoutePaths.freshMediaImport,
    V3FeedImportAction.recording => AppRoutePaths.freshRecordSource,
  });
}

class _CreateNoteSheet extends StatelessWidget {
  const _CreateNoteSheet();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      key: const ValueKey<String>('feed-create-note-sheet'),
      color: colors.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: 326,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 10,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFD3D3D0),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const SizedBox(width: 56, height: 5),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                top: 29,
                child: Text(
                  '创建',
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 20,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
              ),
              Positioned(
                right: 24,
                top: 18,
                child: V3CloseButton(
                  key: const ValueKey<String>('feed-create-note-close'),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                top: 76,
                child: _CreateNoteOption(
                  key: const ValueKey<String>('feed-create-monologue'),
                  icon: Icons.graphic_eq_rounded,
                  title: '独白',
                  subtitle: '用语音讲下此刻的想法，实时转写成一篇属于你的笔记与感想。',
                  onTap: () => Navigator.of(context).pop('/v3/feed/monologue'),
                ),
              ),
              Positioned(
                left: 84,
                right: 24,
                top: 172,
                child: Divider(height: 1, thickness: 1, color: colors.line),
              ),
              Positioned(
                left: 24,
                right: 24,
                top: 173,
                child: _CreateNoteOption(
                  key: const ValueKey<String>('feed-create-text'),
                  icon: Icons.edit_note_rounded,
                  title: '文字',
                  subtitle: '进入沉浸写作，把零散灵感整理成一篇笔记与想法。',
                  onTap: () => Navigator.of(context).pop('/v3/feed/note'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateNoteOption extends StatelessWidget {
  const _CreateNoteOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      button: true,
      label: title,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 96,
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 22, color: colors.ink),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 16,
                          height: 1.5,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 13,
                          height: 18 / 13,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, size: 22, color: colors.ink),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Stable left-bottom chat entry embedded by each physical home-mode page.
class V3ChatEntry extends StatelessWidget {
  const V3ChatEntry({
    this.onTap,
    this.interactive = true,
    this.borderless = false,
    super.key,
  });

  final VoidCallback? onTap;
  final bool interactive;
  final bool borderless;

  @override
  Widget build(BuildContext context) {
    final onPressed = interactive
        ? onTap ??
              () => context.push(
                '/v3/feed/chat?entry=$thoughtGraphChatEntryRouteValue',
              )
        : null;
    final entry = Semantics(
      button: true,
      enabled: interactive,
      excludeSemantics: true,
      label: '聊一聊',
      child: Tooltip(
        message: '聊一聊',
        child: SizedBox.square(
          dimension: 48,
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: Center(
                child: V3ChatMark(size: 48, showSurface: !borderless),
              ),
            ),
          ),
        ),
      ),
    );
    if (interactive) return entry;
    return ExcludeSemantics(child: IgnorePointer(child: entry));
  }
}

class _DockAction extends StatelessWidget {
  const _DockAction({
    required this.semanticLabel,
    required this.icon,
    required this.label,
    required this.onTap,
    this.showLabel = true,
  });

  final String semanticLabel;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final foreground = colors.ink.withValues(alpha: showLabel ? .86 : 1);
    return Expanded(
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: semanticLabel,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(24),
            child: Opacity(
              opacity: onTap == null ? .38 : 1,
              child: showLabel
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 5,
                          child: Icon(icon, size: 20, color: foreground),
                        ),
                        Positioned(
                          left: 2,
                          right: 2,
                          top: 32,
                          height: 18,
                          child: Text(
                            label,
                            textScaler: TextScaler.noScaling,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            style: TextStyle(
                              color: colors.ink.withValues(alpha: .88),
                              fontSize: 11,
                              height: 16 / 11,
                              fontWeight: FontWeight.w400,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Center(child: Icon(icon, size: 24, color: foreground)),
            ),
          ),
        ),
      ),
    );
  }
}
