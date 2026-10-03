import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

abstract interface class DesktopWindowController {
  Future<void> startDragging();

  Future<void> minimize();

  Future<bool> isMaximized();

  Future<void> maximize();

  Future<void> unmaximize();

  Future<void> close();

  void addStateListener(VoidCallback listener);

  void removeStateListener(VoidCallback listener);

  void dispose();
}

final class NativeDesktopWindowController
    with WindowListener
    implements DesktopWindowController {
  NativeDesktopWindowController() {
    windowManager.addListener(this);
  }

  final Set<VoidCallback> _listeners = <VoidCallback>{};

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> close() => windowManager.close();

  @override
  void addStateListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeStateListener(VoidCallback listener) =>
      _listeners.remove(listener);

  @override
  void onWindowMaximize() => _notifyListeners();

  @override
  void onWindowUnmaximize() => _notifyListeners();

  @override
  void onWindowRestore() => _notifyListeners();

  void _notifyListeners() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _listeners.clear();
  }
}

class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({required this.child, this.controller, super.key});

  final Widget child;
  final DesktopWindowController? controller;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

final class _DesktopWindowFrameState extends State<DesktopWindowFrame> {
  late DesktopWindowController _controller;
  late bool _ownsController;
  bool _maximized = false;
  String _workspaceTitle = '个人创作';

  @override
  void initState() {
    super.initState();
    _attachController(widget.controller);
  }

  @override
  void didUpdateWidget(covariant DesktopWindowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _detachController();
    _attachController(widget.controller);
  }

  void _attachController(DesktopWindowController? supplied) {
    _ownsController = supplied == null;
    _controller = supplied ?? NativeDesktopWindowController();
    _controller.addStateListener(_refreshWindowState);
    unawaited(_refreshWindowState());
  }

  void _detachController() {
    _controller.removeStateListener(_refreshWindowState);
    if (_ownsController) _controller.dispose();
  }

  Future<void> _refreshWindowState() async {
    final maximized = await _controller.isMaximized();
    if (mounted && maximized != _maximized) {
      setState(() => _maximized = maximized);
    }
  }

  Future<void> _toggleMaximized() async {
    if (await _controller.isMaximized()) {
      await _controller.unmaximize();
    } else {
      await _controller.maximize();
    }
    await _refreshWindowState();
  }

  Future<void> _showCommandSurface(String title, String message) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _detachController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final perimeter = _maximized ? 0.0 : 6.0;
    final radius = _maximized ? BorderRadius.zero : BorderRadius.circular(9);
    final frameColor = highContrast
        ? colors.surface
        : colors.surface.withValues(alpha: dark ? 0.74 : 0.68);
    return Padding(
      padding: EdgeInsets.all(perimeter),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: highContrast
              ? Border.all(color: colors.outline)
              : Border.all(
                  color: Colors.white.withValues(alpha: dark ? 0.10 : 0.34),
                ),
          boxShadow: _maximized
              ? const <BoxShadow>[]
              : <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.24 : 0.14),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: ColoredBox(
            color: frameColor,
            child: Column(
              children: [
                _buildTitleBar(context),
                Expanded(
                  child: ColoredBox(color: colors.surface, child: widget.child),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleBar(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('desktop-title-bar'),
      height: 40,
      child: Material(
        color: Colors.transparent,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Semantics(
              label: '花火 AI',
              image: true,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Image.asset(
                  'assets/images/huahuo_brand_mark.png',
                  width: 18,
                  height: 18,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
            const SizedBox(width: 7),
            PopupMenuButton<String>(
              key: const ValueKey<String>('workspace-picker'),
              tooltip: '切换工作区',
              onSelected: (value) => setState(() => _workspaceTitle = value),
              itemBuilder: (context) => const [
                PopupMenuItem(value: '个人创作', child: Text('个人创作')),
                PopupMenuItem(value: '花火桌面端', child: Text('花火桌面端')),
                PopupMenuItem(value: '七月内容计划', child: Text('七月内容计划')),
              ],
              child: _TitleBarLabel(
                label: _workspaceTitle,
                icon: LucideIcons.chevronsUpDown,
              ),
            ),
            const SizedBox(width: 3),
            _TitleIconAction(
              tooltip: '后退',
              icon: LucideIcons.arrowLeft,
              onPressed: () =>
                  unawaited(_showCommandSurface('后退', '当前工作区没有更早的页面。')),
            ),
            _TitleIconAction(
              tooltip: '前进',
              icon: LucideIcons.arrowRight,
              onPressed: () =>
                  unawaited(_showCommandSurface('前进', '当前工作区没有可前进的页面。')),
            ),
            const _TitleBarSeparator(),
            _TitleMenu(
              label: '文件',
              items: const [
                ('新建文稿', '新建文稿请使用笔记栏顶部的按钮。'),
                ('最小化窗口', 'minimize'),
                ('关闭窗口', 'close'),
              ],
              onSelected: (value) {
                if (value == 'minimize') {
                  unawaited(_controller.minimize());
                } else if (value == 'close') {
                  unawaited(_controller.close());
                } else {
                  unawaited(_showCommandSurface('新建文稿', value));
                }
              },
            ),
            _TitleMenu(
              label: '编辑',
              items: const [
                ('编辑快捷键', '使用 Ctrl/Cmd + K 调出创作助手。'),
                ('文稿信息', '文稿信息可从编辑器右上角菜单查看。'),
              ],
              onSelected: (value) =>
                  unawaited(_showCommandSurface('编辑', value)),
            ),
            _TitleMenu(
              label: '视图',
              items: const [('切换最大化', 'maximize'), ('聚焦模式', '聚焦模式可在设置中开启。')],
              onSelected: (value) {
                if (value == 'maximize') {
                  unawaited(_toggleMaximized());
                } else {
                  unawaited(_showCommandSurface('视图', value));
                }
              },
            ),
            _TitleMenu(
              label: '帮助',
              items: const [
                ('桌面编辑器帮助', '查看快捷键、图谱和沉淀流程说明。'),
                ('关于花火 AI', 'about'),
              ],
              onSelected: (value) {
                if (value == 'about') {
                  showAboutDialog(
                    context: context,
                    applicationName: '花火 AI 创作桌面',
                    applicationVersion: 'Desktop Editor',
                  );
                } else {
                  unawaited(_showCommandSurface('帮助', value));
                }
              },
            ),
            Expanded(
              child: GestureDetector(
                key: const ValueKey<String>('desktop-title-drag-region'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => unawaited(_controller.startDragging()),
                onDoubleTap: () => unawaited(_toggleMaximized()),
              ),
            ),
            _CaptionButton(
              key: const ValueKey<String>('window-minimize'),
              tooltip: '最小化',
              icon: LucideIcons.minus,
              onPressed: () => unawaited(_controller.minimize()),
            ),
            _CaptionButton(
              key: const ValueKey<String>('window-maximize'),
              tooltip: _maximized ? '还原' : '最大化',
              icon: _maximized ? LucideIcons.copy : LucideIcons.square,
              onPressed: () => unawaited(_toggleMaximized()),
            ),
            _CaptionButton(
              key: const ValueKey<String>('window-close'),
              tooltip: '关闭',
              icon: LucideIcons.x,
              destructive: true,
              onPressed: () => unawaited(_controller.close()),
            ),
          ],
        ),
      ),
    );
  }
}

final class _TitleBarLabel extends StatelessWidget {
  const _TitleBarLabel({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          Icon(icon, size: 12, color: colors.onSurfaceVariant),
        ],
      ),
    );
  }
}

final class _TitleIconAction extends StatelessWidget {
  const _TitleIconAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 28,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 14),
      ),
    );
  }
}

final class _TitleBarSeparator extends StatelessWidget {
  const _TitleBarSeparator();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 7),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

final class _TitleMenu extends StatelessWidget {
  const _TitleMenu({
    required this.label,
    required this.items,
    required this.onSelected,
  });

  final String label;
  final List<(String, String)> items;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: label,
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem(value: item.$2, child: Text(item.$1)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
        child: Text(
          label,
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
        ),
      ),
    );
  }
}

final class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 46,
      height: 40,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (destructive && states.contains(WidgetState.hovered)) {
              return Colors.white;
            }
            return colors.onSurfaceVariant;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (destructive && states.contains(WidgetState.hovered)) {
              return const Color(0xFFC42B1C);
            }
            if (states.contains(WidgetState.pressed)) {
              return colors.onSurface.withValues(alpha: 0.12);
            }
            if (states.contains(WidgetState.hovered)) {
              return colors.onSurface.withValues(alpha: 0.07);
            }
            return Colors.transparent;
          }),
        ),
        icon: Icon(icon, size: destructive ? 15 : 13.5),
      ),
    );
  }
}
