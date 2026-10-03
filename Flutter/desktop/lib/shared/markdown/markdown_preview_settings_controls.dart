import 'dart:async';

import 'package:flutter/material.dart';

import 'markdown_presentation_template.dart';
import 'markdown_preview_preferences.dart';
import 'markdown_preview_preferences_store.dart';

/// Controls intended for the Markdown preview group in the Writing settings.
///
/// This widget deliberately provides controls only, not its own card or page
/// frame, so it can live inside the desktop settings surface without nesting
/// visual containers.
class MarkdownPreviewSettingsControls extends StatelessWidget {
  const MarkdownPreviewSettingsControls({required this.controller, super.key});

  final MarkdownPreviewPreferencesController controller;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<MarkdownPreviewPreferences>(
        valueListenable: controller,
        builder: (context, preferences, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _SettingOption(
              label: '阅读模板',
              detail: '为同一篇 Markdown 选择不同的内容结构和阅读节奏，不改变正文内容。',
              child: _MarkdownPreviewThemeGrid(
                value: preferences.theme,
                onChanged: (theme) =>
                    _update(preferences.copyWith(theme: theme)),
              ),
            ),
            const Divider(height: 25),
            _SettingOption(
              label: '阅读密度',
              detail: '控制阅读页面的留白、行距和内容宽度。',
              child: SegmentedButton<MarkdownPreviewProfile>(
                key: const ValueKey<String>('markdown-preview-profile'),
                showSelectedIcon: false,
                segments: const <ButtonSegment<MarkdownPreviewProfile>>[
                  ButtonSegment(
                    value: MarkdownPreviewProfile.quiet,
                    label: Text('安静'),
                  ),
                  ButtonSegment(
                    value: MarkdownPreviewProfile.compact,
                    label: Text('紧凑'),
                  ),
                  ButtonSegment(
                    value: MarkdownPreviewProfile.paper,
                    label: Text('纸张'),
                  ),
                ],
                selected: <MarkdownPreviewProfile>{preferences.profile},
                onSelectionChanged: (selection) =>
                    _update(preferences.copyWith(profile: selection.first)),
              ),
            ),
            const Divider(height: 25),
            _SettingOption(
              label: '预览配色',
              detail: '单独设置 Markdown 阅读页的明暗模式。',
              child: SegmentedButton<MarkdownPreviewColorMode>(
                key: const ValueKey<String>('markdown-preview-color-mode'),
                showSelectedIcon: false,
                segments: const <ButtonSegment<MarkdownPreviewColorMode>>[
                  ButtonSegment(
                    value: MarkdownPreviewColorMode.system,
                    label: Text('跟随应用'),
                  ),
                  ButtonSegment(
                    value: MarkdownPreviewColorMode.light,
                    label: Text('明亮'),
                  ),
                  ButtonSegment(
                    value: MarkdownPreviewColorMode.dark,
                    label: Text('暗黑'),
                  ),
                ],
                selected: <MarkdownPreviewColorMode>{preferences.colorMode},
                onSelectionChanged: (selection) =>
                    _update(preferences.copyWith(colorMode: selection.first)),
              ),
            ),
            const Divider(height: 25),
            _PreviewTextScaleControl(
              value: preferences.textScale,
              onChanged: (value) =>
                  _update(preferences.copyWith(textScale: value)),
            ),
            const Divider(height: 19),
            SwitchListTile(
              key: const ValueKey<String>('markdown-preview-table-of-contents'),
              contentPadding: EdgeInsets.zero,
              title: const Text('显示目录'),
              subtitle: const Text('文稿含有标题时，在预览开头生成结构目录。'),
              value: preferences.showTableOfContents,
              onChanged: (value) =>
                  _update(preferences.copyWith(showTableOfContents: value)),
            ),
            const Divider(height: 1),
            SwitchListTile(
              key: const ValueKey<String>('markdown-preview-remote-images'),
              contentPadding: EdgeInsets.zero,
              title: const Text('加载远程图片'),
              subtitle: const Text('仅加载 HTTPS 图片；开启后可能向图片服务器发出请求。'),
              value: preferences.allowRemoteImages,
              onChanged: (value) =>
                  _update(preferences.copyWith(allowRemoteImages: value)),
            ),
          ],
        ),
      );

  void _update(MarkdownPreviewPreferences preferences) {
    unawaited(controller.update(preferences));
  }
}

class _MarkdownPreviewThemeGrid extends StatelessWidget {
  const _MarkdownPreviewThemeGrid({
    required this.value,
    required this.onChanged,
  });

  final MarkdownPreviewTheme value;
  final ValueChanged<MarkdownPreviewTheme> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 10.0;
      final columns = constraints.maxWidth < 520 ? 1 : 2;
      final tileWidth =
          (constraints.maxWidth - (gap * (columns - 1))) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: <Widget>[
          for (final template in MarkdownPresentationTemplateRegistry.templates)
            SizedBox(
              width: tileWidth,
              child: _MarkdownPreviewThemeTile(
                template: template,
                selected: template.theme == value,
                onTap: () => onChanged(template.theme),
              ),
            ),
        ],
      );
    },
  );
}

class _MarkdownPreviewThemeTile extends StatelessWidget {
  const _MarkdownPreviewThemeTile({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final MarkdownPresentationTemplate template;
  final bool selected;
  final VoidCallback onTap;

  String get _layoutLabel => switch (template.layout) {
    MarkdownPresentationLayout.article => '长文',
    MarkdownPresentationLayout.parchment => '纸页',
    MarkdownPresentationLayout.magazine => '特写',
    MarkdownPresentationLayout.focus => '专注',
    MarkdownPresentationLayout.research => '研读',
    MarkdownPresentationLayout.brief => '简报',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? colors.primary : colors.onSurface;
    final selectedSurface = Color.alphaBlend(
      colors.primary.withValues(alpha: .08),
      colors.surfaceContainerLow,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${template.label}模板，${template.description}',
      child: Material(
        color: selected ? selectedSurface : colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        child: InkWell(
          key: ValueKey<String>(
            'markdown-preview-theme-${template.theme.storageValue}',
          ),
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            height: 176,
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 1.3 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: _TemplateMiniature(template: template),
                      ),
                      if (selected)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surface.withValues(alpha: .9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: Icon(
                                Icons.check_circle,
                                size: 15,
                                color: colors.primary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _layoutLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  template.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  template.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TemplateMiniature extends StatelessWidget {
  const _TemplateMiniature({required this.template});

  final MarkdownPresentationTemplate template;

  @override
  Widget build(BuildContext context) {
    final palette = _TemplatePalette.fromLayout(
      Theme.of(context).colorScheme,
      template.layout,
    );
    final content = switch (template.layout) {
      MarkdownPresentationLayout.article => _ArticleMiniature(palette: palette),
      MarkdownPresentationLayout.parchment => _ParchmentMiniature(
        palette: palette,
      ),
      MarkdownPresentationLayout.magazine => _MagazineMiniature(
        palette: palette,
      ),
      MarkdownPresentationLayout.focus => _FocusMiniature(palette: palette),
      MarkdownPresentationLayout.research => _ResearchMiniature(
        palette: palette,
      ),
      MarkdownPresentationLayout.brief => _BriefMiniature(palette: palette),
    };
    return DecoratedBox(
      key: ValueKey<String>(
        'markdown-preview-template-preview-${template.theme.storageValue}',
      ),
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.edge),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(3), child: content),
    );
  }
}

class _TemplatePalette {
  const _TemplatePalette({
    required this.canvas,
    required this.paper,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.edge,
  });

  final Color canvas;
  final Color paper;
  final Color ink;
  final Color muted;
  final Color accent;
  final Color edge;

  factory _TemplatePalette.fromLayout(
    ColorScheme colors,
    MarkdownPresentationLayout layout,
  ) {
    final quiet = _TemplatePalette(
      canvas: colors.surface,
      paper: colors.surfaceContainerLow,
      ink: colors.onSurface,
      muted: colors.onSurfaceVariant,
      accent: colors.primary,
      edge: colors.outlineVariant,
    );
    final warmPaper = Color.alphaBlend(
      const Color(0x1AB88648),
      colors.surfaceContainerLow,
    );
    final quietLine = colors.onSurface.withValues(alpha: .68);
    final mutedLine = colors.onSurfaceVariant.withValues(alpha: .55);
    return switch (layout) {
      MarkdownPresentationLayout.article => quiet,
      MarkdownPresentationLayout.parchment => _TemplatePalette(
        canvas: warmPaper,
        paper: colors.surface.withValues(alpha: .68),
        ink: quietLine,
        muted: mutedLine,
        accent: const Color(0xFF966A32),
        edge: Color.alphaBlend(const Color(0x2A8A6535), colors.outlineVariant),
      ),
      MarkdownPresentationLayout.magazine => _TemplatePalette(
        canvas: colors.inverseSurface,
        paper: colors.surface,
        ink: colors.onInverseSurface,
        muted: colors.onInverseSurface.withValues(alpha: .7),
        accent: colors.tertiary,
        edge: colors.inversePrimary.withValues(alpha: .45),
      ),
      MarkdownPresentationLayout.focus => _TemplatePalette(
        canvas: Color.alphaBlend(
          colors.primary.withValues(alpha: .24),
          colors.inverseSurface,
        ),
        paper: colors.inverseSurface.withValues(alpha: .82),
        ink: colors.onInverseSurface,
        muted: colors.onInverseSurface.withValues(alpha: .56),
        accent: colors.inversePrimary,
        edge: colors.onInverseSurface.withValues(alpha: .18),
      ),
      MarkdownPresentationLayout.research => _TemplatePalette(
        canvas: colors.surfaceContainerLow,
        paper: colors.surface,
        ink: colors.onSurface,
        muted: colors.onSurfaceVariant.withValues(alpha: .74),
        accent: colors.primary,
        edge: colors.outlineVariant,
      ),
      MarkdownPresentationLayout.brief => _TemplatePalette(
        canvas: colors.surface,
        paper: colors.secondaryContainer,
        ink: colors.onSurface,
        muted: colors.onSurfaceVariant,
        accent: colors.secondary,
        edge: colors.outlineVariant,
      ),
    };
  }
}

class _ArticleMiniature extends StatelessWidget {
  const _ArticleMiniature({required this.palette});

  final _TemplatePalette palette;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey<String>(
      'markdown-preview-template-structure-quiet-article',
    ),
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _MiniLine(color: palette.accent, widthFactor: .22, height: 3),
        const SizedBox(height: 6),
        _MiniLine(color: palette.ink, widthFactor: .7, height: 7),
        const SizedBox(height: 4),
        _MiniLine(color: palette.muted, widthFactor: .38, height: 3),
        const Spacer(),
        Align(
          alignment: Alignment.center,
          child: FractionallySizedBox(
            widthFactor: .72,
            child: Column(
              children: <Widget>[
                _MiniLine(color: palette.muted, widthFactor: 1, height: 3),
                const SizedBox(height: 4),
                _MiniLine(color: palette.muted, widthFactor: .92, height: 3),
                const SizedBox(height: 4),
                _MiniLine(color: palette.muted, widthFactor: .98, height: 3),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ParchmentMiniature extends StatelessWidget {
  const _ParchmentMiniature({required this.palette});

  final _TemplatePalette palette;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey<String>(
      'markdown-preview-template-structure-paper-parchment',
    ),
    padding: const EdgeInsets.all(7),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: palette.paper,
        border: Border.all(color: palette.edge),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 12,
            top: 8,
            bottom: 8,
            child: Container(
              width: 1,
              color: palette.accent.withValues(alpha: .5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(23, 12, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _MiniLine(color: palette.muted, widthFactor: .3, height: 3),
                const SizedBox(height: 6),
                _MiniLine(color: palette.ink, widthFactor: .78, height: 7),
                const SizedBox(height: 9),
                _MiniLine(color: palette.muted, widthFactor: .96, height: 3),
                const SizedBox(height: 4),
                _MiniLine(color: palette.muted, widthFactor: .87, height: 3),
                const Spacer(),
                _MiniLine(color: palette.accent, widthFactor: .28, height: 2),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _MagazineMiniature extends StatelessWidget {
  const _MagazineMiniature({required this.palette});

  final _TemplatePalette palette;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey<String>(
      'markdown-preview-template-structure-editorial-magazine',
    ),
    padding: const EdgeInsets.all(9),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _MiniLine(color: palette.accent, widthFactor: .18, height: 3),
        const SizedBox(height: 6),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _MiniLine(color: palette.ink, widthFactor: 1, height: 8),
                      const SizedBox(height: 4),
                      _MiniLine(color: palette.ink, widthFactor: .7, height: 8),
                      const Spacer(),
                      _MiniLine(
                        color: palette.muted,
                        widthFactor: .95,
                        height: 3,
                      ),
                      const SizedBox(height: 4),
                      _MiniLine(
                        color: palette.muted,
                        widthFactor: .84,
                        height: 3,
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.accent.withValues(alpha: .78),
                    border: Border(
                      top: BorderSide(
                        color: palette.ink.withValues(alpha: .78),
                        width: 3,
                      ),
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: 18,
                      color: palette.ink.withValues(alpha: .42),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FocusMiniature extends StatelessWidget {
  const _FocusMiniature({required this.palette});

  final _TemplatePalette palette;

  @override
  Widget build(BuildContext context) => Center(
    key: const ValueKey<String>(
      'markdown-preview-template-structure-focus-reader',
    ),
    child: FractionallySizedBox(
      widthFactor: .5,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _MiniLine(color: palette.accent, widthFactor: .26, height: 3),
          const SizedBox(height: 8),
          _MiniLine(color: palette.ink, widthFactor: 1, height: 7),
          const SizedBox(height: 5),
          _MiniLine(color: palette.ink, widthFactor: .72, height: 7),
          const SizedBox(height: 12),
          _MiniLine(color: palette.muted, widthFactor: .94, height: 3),
          const SizedBox(height: 5),
          _MiniLine(color: palette.muted, widthFactor: 1, height: 3),
          const SizedBox(height: 5),
          _MiniLine(color: palette.muted, widthFactor: .88, height: 3),
        ],
      ),
    ),
  );
}

class _ResearchMiniature extends StatelessWidget {
  const _ResearchMiniature({required this.palette});

  final _TemplatePalette palette;

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey<String>(
      'markdown-preview-template-structure-research-outline',
    ),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Container(
        key: const ValueKey<String>(
          'markdown-preview-template-research-outline-rail',
        ),
        width: 34,
        color: palette.paper,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          children: <Widget>[
            _MiniDot(color: palette.accent),
            _MiniRail(color: palette.edge),
            _MiniDot(color: palette.muted),
            _MiniRail(color: palette.edge),
            _MiniDot(color: palette.muted),
            const Spacer(),
            _MiniDot(color: palette.muted),
          ],
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 11, 11, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _MiniLine(color: palette.accent, widthFactor: .2, height: 3),
              const SizedBox(height: 6),
              _MiniLine(color: palette.ink, widthFactor: .8, height: 7),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _MiniLine(
                      color: palette.muted,
                      widthFactor: 1,
                      height: 3,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MiniLine(
                      color: palette.muted,
                      widthFactor: 1,
                      height: 3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              _MiniLine(color: palette.muted, widthFactor: .92, height: 3),
              const SizedBox(height: 5),
              _MiniLine(color: palette.muted, widthFactor: .76, height: 3),
            ],
          ),
        ),
      ),
    ],
  );
}

class _BriefMiniature extends StatelessWidget {
  const _BriefMiniature({required this.palette});

  final _TemplatePalette palette;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey<String>(
      'markdown-preview-template-structure-brief-executive',
    ),
    padding: const EdgeInsets.all(10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(height: 4, color: palette.accent),
        const SizedBox(height: 7),
        _MiniLine(color: palette.ink, widthFactor: .55, height: 7),
        const SizedBox(height: 7),
        Row(
          children: <Widget>[
            Expanded(child: _BriefMetric(palette: palette)),
            const SizedBox(width: 7),
            Expanded(child: _BriefMetric(palette: palette)),
          ],
        ),
        const SizedBox(height: 7),
        _BriefAction(color: palette.accent, lineColor: palette.muted),
        const SizedBox(height: 4),
        _BriefAction(color: palette.muted, lineColor: palette.muted),
      ],
    ),
  );
}

class _BriefMetric extends StatelessWidget {
  const _BriefMetric({required this.palette});

  final _TemplatePalette palette;

  @override
  Widget build(BuildContext context) => Container(
    height: 20,
    padding: const EdgeInsets.all(5),
    color: palette.paper,
    child: _MiniLine(color: palette.ink, widthFactor: .72, height: 3),
  );
}

class _BriefAction extends StatelessWidget {
  const _BriefAction({required this.color, required this.lineColor});

  final Color color;
  final Color lineColor;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Container(width: 6, height: 6, color: color),
      const SizedBox(width: 5),
      Expanded(child: _MiniLine(color: lineColor, widthFactor: 1, height: 3)),
    ],
  );
}

class _MiniLine extends StatelessWidget {
  const _MiniLine({
    required this.color,
    required this.widthFactor,
    required this.height,
  });

  final Color color;
  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      ),
    ),
  );
}

class _MiniDot extends StatelessWidget {
  const _MiniDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _MiniRail extends StatelessWidget {
  const _MiniRail({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Align(
      alignment: Alignment.topCenter,
      child: Container(width: 1, color: color),
    ),
  );
}

class _SettingOption extends StatelessWidget {
  const _SettingOption({
    required this.label,
    required this.detail,
    required this.child,
  });

  final String label;
  final String detail;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 3),
        Text(
          detail,
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12.5),
        ),
        const SizedBox(height: 11),
        child,
      ],
    );
  }
}

class _PreviewTextScaleControl extends StatelessWidget {
  const _PreviewTextScaleControl({
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final percentage = (value * 100).round();
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Markdown 预览文字大小 $percentage%',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('预览文字大小', style: Theme.of(context).textTheme.bodyLarge),
              const Spacer(),
              Text(
                '$percentage%',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '仅影响阅读预览，不改变文稿正文。',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12.5),
          ),
          Slider(
            key: const ValueKey<String>('markdown-preview-text-scale'),
            value: value,
            min: MarkdownPreviewPreferences.minimumTextScale,
            max: MarkdownPreviewPreferences.maximumTextScale,
            divisions: 16,
            label: '$percentage%',
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
