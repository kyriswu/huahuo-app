import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../application/app_appearance_controller.dart';
import '../domain/app_appearance_preset.dart';

class V3AppearanceSettingsCard extends ConsumerWidget {
  const V3AppearanceSettingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appAppearanceControllerProvider);
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      key: const ValueKey('settings-appearance-card'),
      glass: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const V3SectionTitle('外观主题'),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final itemWidth = (constraints.maxWidth - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final preset in AppAppearancePreset.supportedValues)
                    SizedBox(
                      width: itemWidth,
                      child: _AppearanceChoice(
                        preset: preset,
                        selected: controller.preset == preset,
                        onTap: () => ref
                            .read(appAppearanceControllerProvider)
                            .selectPreset(preset),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: colors.line),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: V3SectionTitle('字体大小')),
              Text(
                controller.textSizePreset.label,
                key: const ValueKey('settings-text-size-value'),
                style: HuahuoV3Theme.meta.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Text(
            '预览文字大小',
            key: const ValueKey('settings-text-size-preview'),
            style: HuahuoV3Theme.body.copyWith(color: colors.text),
          ),
          Slider(
            key: const ValueKey('settings-text-size-slider'),
            min: 0,
            max: (AppTextSizePreset.values.length - 1).toDouble(),
            divisions: AppTextSizePreset.values.length - 1,
            value: controller.textSizePreset.index.toDouble(),
            label: controller.textSizePreset.label,
            onChanged: (value) {
              final index = value.round().clamp(
                0,
                AppTextSizePreset.values.length - 1,
              );
              ref
                  .read(appAppearanceControllerProvider)
                  .selectTextSizePreset(AppTextSizePreset.values[index]);
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final preset in AppTextSizePreset.values)
                Text(
                  preset.label,
                  style: HuahuoV3Theme.compactLabel.copyWith(
                    color: preset == controller.textSizePreset
                        ? colors.accent
                        : colors.muted,
                  ),
                ),
            ],
          ),
          if (controller.errorCode != null) ...[
            const SizedBox(height: 10),
            Text(
              '主题保存失败，请重试',
              key: const ValueKey('settings-appearance-error'),
              style: HuahuoV3Theme.meta.copyWith(color: colors.danger),
            ),
          ],
        ],
      ),
    );
  }
}

class _AppearanceChoice extends StatelessWidget {
  const _AppearanceChoice({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final AppAppearancePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final preview = _previewColor(preset);
    return Semantics(
      button: true,
      selected: selected,
      label: '主题：${preset.label}',
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .10)
            : colors.surfaceMuted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected ? colors.primary : colors.line,
            width: selected ? 1.2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('appearance-preset-${preset.wireName}'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: preview,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.line),
                    ),
                    child: preset == AppAppearancePreset.system
                        ? Icon(
                            Icons.brightness_auto_outlined,
                            size: 14,
                            color: colors.ink,
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preset.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HuahuoV3Theme.meta.copyWith(
                        color: colors.text,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check_rounded, size: 17, color: colors.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _previewColor(AppAppearancePreset preset) => switch (preset) {
    AppAppearancePreset.system => const Color(0xFFE6E9EB),
    AppAppearancePreset.light => const Color(0xFFFFFFFF),
    AppAppearancePreset.dark => const Color(0xFF242424),
    AppAppearancePreset.mistBlue => const Color(0xFF9CBACB),
    AppAppearancePreset.pineGreen => const Color(0xFF829A8B),
    AppAppearancePreset.warmGold => const Color(0xFFB7894A),
    AppAppearancePreset.sakura => const Color(0xFFE58AAD),
    AppAppearancePreset.aurora => const Color(0xFF28B7C8),
  };
}
