import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';

class V3RecordingCardBatteryBadge extends StatelessWidget {
  const V3RecordingCardBatteryBadge({
    required this.percent,
    this.valueKey,
    super.key,
  });

  final int? percent;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final normalized = percent?.clamp(0, 100).toInt();
    final visualLabel = normalized == null ? '--' : '$normalized%';
    final semanticLabel = normalized == null ? '录音卡电量未知' : '录音卡电量 $normalized%';
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          key: valueKey,
          width: 48,
          height: 24,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  normalized == null
                      ? Icons.battery_unknown_rounded
                      : Icons.battery_full_rounded,
                  size: 14,
                  color: colors.muted,
                ),
                const SizedBox(width: 3),
                Text(
                  visualLabel,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.muted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
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
