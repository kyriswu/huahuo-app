import 'package:flutter/material.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';

/// Compact safe rendering of the server-whitelisted runtime projection.
class ThreadRuntimeSummary extends StatelessWidget {
  const ThreadRuntimeSummary({required this.invocation, super.key});

  final SharedThreadRuntimeInvocation invocation;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final rows = <(String, String)>[
      ('状态', invocation.status),
      ('Agent', invocation.agentProfileId),
      ('模型', invocation.modelProfileId),
      ('技能', invocation.skillProfileIds.join('、')),
      ('输入类型', invocation.contentTypes.join('、')),
      (
        '工具',
        invocation.tools
            .map((item) => '${item.name} (${item.state})')
            .join('\n'),
      ),
      ('文件', invocation.files.map((item) => item.name).join('\n')),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: rows.length,
        separatorBuilder: (_, __) => Divider(color: colors.line, height: 20),
        itemBuilder: (_, index) {
          final row = rows[index];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.$1, style: TextStyle(color: colors.muted, fontSize: 12)),
              const SizedBox(height: 4),
              Text(
                row.$2.isEmpty ? '无' : row.$2,
                style: TextStyle(color: colors.ink, height: 1.4),
              ),
            ],
          );
        },
      ),
    );
  }
}
