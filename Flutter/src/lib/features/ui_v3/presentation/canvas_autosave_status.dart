import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';

class CanvasAutosaveFailureBar extends StatelessWidget {
  const CanvasAutosaveFailureBar({
    required this.onRetry,
    this.message = '草稿暂未自动保存',
    this.actionLabel = '重试',
    super.key,
  });

  final VoidCallback onRetry;
  final String message;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final background = Color.alphaBlend(
      tokens.danger.withValues(alpha: .10),
      tokens.surface,
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.only(left: 22, right: 10),
      color: background,
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: tokens.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: tokens.text)),
          ),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}
