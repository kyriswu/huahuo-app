import 'package:flutter/material.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

Future<String?> showDesktopFeatureCommandPalette({
  required BuildContext context,
  required List<FeatureEntry> entries,
}) {
  var query = '';
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final normalized = query.trim().toLowerCase();
        final visible = entries
            .where((entry) {
              final descriptor = entry.descriptor;
              return normalized.isEmpty ||
                  descriptor.title.toLowerCase().contains(normalized) ||
                  descriptor.id.value.toLowerCase().contains(normalized) ||
                  descriptor.domain.name.toLowerCase().contains(normalized);
            })
            .toList(growable: false);
        return Dialog(
          child: SizedBox(
            width: 620,
            height: 540,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                  child: TextField(
                    key: const ValueKey<String>('feature-command-query'),
                    contextMenuBuilder:
                        HuahuoTextEditing.buildEditableContextMenu,
                    autofocus: true,
                    onChanged: (value) => setDialogState(() => query = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(LucideIcons.search, size: 18),
                      hintText: '搜索功能',
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: visible.isEmpty
                      ? const Center(child: Text('没有匹配的功能'))
                      : ListView.builder(
                          key: const ValueKey<String>(
                            'feature-command-results',
                          ),
                          itemCount: visible.length,
                          itemBuilder: (context, index) =>
                              _FeatureCommandRow(entry: visible[index]),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

final class _FeatureCommandRow extends StatelessWidget {
  const _FeatureCommandRow({required this.entry});

  final FeatureEntry entry;

  @override
  Widget build(BuildContext context) {
    final route = entry
        .bindingFor(ProductPlatform.desktop)
        .entryPoints
        .where((point) => point.kind == FeatureEntryKind.route)
        .first;
    return ListTile(
      key: ValueKey<String>('feature-command-${entry.descriptor.id.value}'),
      title: Text(entry.descriptor.title),
      subtitle: Text(featureDomainLabel(entry.descriptor.domain)),
      trailing: const Icon(LucideIcons.arrowRight, size: 16),
      onTap: () => Navigator.pop(context, route.locator),
    );
  }
}

String featureDomainLabel(FeatureDomain domain) => switch (domain) {
  FeatureDomain.runtime => '运行时',
  FeatureDomain.account => '账户',
  FeatureDomain.content => '内容',
  FeatureDomain.knowledge => '知识',
  FeatureDomain.notifications => '通知',
  FeatureDomain.ingestion => '采集',
  FeatureDomain.recordings => '录音与转写',
  FeatureDomain.chat => 'Chat 与 Agent',
  FeatureDomain.creation => '创作',
  FeatureDomain.digitalTwin => '数字分身',
  FeatureDomain.native => '原生能力',
};
