import 'dart:async';

import 'package:flutter/material.dart';

import '../navigation/safe_navigation.dart';
import '../theme/huahuo_v3_theme.dart';

Future<void> returnFromV3LongRunningTask(
  BuildContext context, {
  String fallbackRoute = '/v3',
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await returnToPreviousRoute(context, fallbackRoute: fallbackRoute);
}

class V3LongRunningTaskNotice extends StatefulWidget {
  const V3LongRunningTaskNotice({
    this.onReturn,
    this.fallbackRoute = '/v3',
    this.message = '处理可能需要较长时间，可先返回其他界面，稍后从「消息通知」重新进入查看。',
    super.key,
  });

  final FutureOr<void> Function()? onReturn;
  final String fallbackRoute;
  final String message;

  @override
  State<V3LongRunningTaskNotice> createState() =>
      _V3LongRunningTaskNoticeState();
}

class _V3LongRunningTaskNoticeState extends State<V3LongRunningTaskNotice> {
  bool _returning = false;

  Future<void> _return() async {
    if (_returning) return;
    setState(() => _returning = true);
    try {
      final onReturn = widget.onReturn;
      if (onReturn != null) {
        await onReturn();
      } else {
        await returnFromV3LongRunningTask(
          context,
          fallbackRoute: widget.fallbackRoute,
        );
      }
    } finally {
      if (mounted) setState(() => _returning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: colors.surfaceMuted,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('long-running-task-return'),
        onTap: _returning ? null : _return,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 20, color: colors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.message,
                      style: TextStyle(
                        color: colors.muted,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _returning ? '正在返回…' : '先返回，稍后查看',
                      style: TextStyle(
                        color: colors.accent,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
