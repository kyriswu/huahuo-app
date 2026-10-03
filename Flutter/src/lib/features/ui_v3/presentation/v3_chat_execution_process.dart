import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';

enum V3ChatExecutionKind { workspace, noteLibrary, referencedNote, dailyTopics }

class V3ChatExecutionProcess extends StatelessWidget {
  const V3ChatExecutionProcess({
    required this.kind,
    required this.activeStep,
    this.finished = false,
    super.key,
  });

  final V3ChatExecutionKind kind;
  final int activeStep;
  final bool finished;

  List<String> get _labels => switch (kind) {
    V3ChatExecutionKind.workspace => const <String>['读取工作空间'],
    V3ChatExecutionKind.noteLibrary => const <String>[
      '检索笔记库',
      '筛选高相关笔记',
      '生成选题建议',
    ],
    V3ChatExecutionKind.referencedNote => const <String>[
      '读取引用笔记',
      '检索相关内容',
      '生成选题建议',
    ],
    V3ChatExecutionKind.dailyTopics => const <String>[
      '检索今日热点',
      '筛选高相关话题',
      '生成选题建议',
    ],
  };

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final current = activeStep.clamp(0, _labels.length - 1);
    return Column(
      key: const ValueKey<String>('chat-assistant-thinking-bubble'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '执行过程',
          style: TextStyle(
            color: tokens.ink,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        for (var index = 0; index < _labels.length; index += 1)
          Padding(
            padding: EdgeInsets.only(
              bottom: index == _labels.length - 1 ? 0 : 6,
            ),
            child: _V3ChatExecutionStep(
              label: _labels[index],
              completed: finished || index < current,
              active: !finished && index == current,
            ),
          ),
      ],
    );
  }
}

class _V3ChatExecutionStep extends StatelessWidget {
  const _V3ChatExecutionStep({
    required this.label,
    required this.completed,
    required this.active,
  });

  final String label;
  final bool completed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    if (!completed && !active) {
      return SizedBox(
        height: 34,
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: tokens.line),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: tokens.muted,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text('等待中', style: TextStyle(color: tokens.muted, fontSize: 11)),
          ],
        ),
      );
    }
    if (completed) {
      return SizedBox(
        height: 34,
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: tokens.success,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.check_rounded,
                size: 14,
                color: tokens.onPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: tokens.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text('已完成', style: TextStyle(color: tokens.muted, fontSize: 11)),
          ],
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minHeight: 61),
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 7),
      decoration: BoxDecoration(
        color: tokens.accent.withValues(alpha: .035),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tokens.accent.withValues(alpha: .36)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              V3AgentRunGlyph(
                key: const ValueKey<String>('chat-assistant-thinking-progress'),
                color: tokens.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: tokens.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text('进行中', style: TextStyle(color: tokens.accent, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '正在处理，请稍候…',
                style: TextStyle(color: tokens.muted, fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class V3AgentRunGlyph extends StatefulWidget {
  const V3AgentRunGlyph({required this.color, super.key});

  final Color color;

  @override
  State<V3AgentRunGlyph> createState() => _V3AgentRunGlyphState();
}

class _V3AgentRunGlyphState extends State<V3AgentRunGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final _tickerMetrics = RuntimeTickerMetricsLease('chat_agent_glyph');

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: V3MotionTokens.activityPulse,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shouldAnimate =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller.stop(canceled: false);
    }
    _tickerMetrics.sync(context, active: shouldAnimate);
  }

  @override
  void dispose() {
    _tickerMetrics.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      container: true,
      label: 'Agent 正在运行',
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: 18,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => CustomPaint(
              painter: _V3AgentRunGlyphPainter(
                progress: disableAnimations ? 0 : _controller.value,
                color: widget.color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _V3AgentRunGlyphPainter extends CustomPainter {
  const _V3AgentRunGlyphPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const rayCount = 8;
    final center = Offset(size.width / 2, size.height / 2);
    final innerRadius = size.shortestSide * .22;
    final outerRadius = size.shortestSide * .46;
    final phase = progress * rayCount;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.shortestSide * .11;

    for (var index = 0; index < rayCount; index += 1) {
      final angle = (index / rayCount) * math.pi * 2 - math.pi / 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final distance = (phase - index) % rayCount;
      final intensity = 1 - distance / rayCount;
      paint.color = color.withValues(alpha: .18 + intensity * .82);
      canvas.drawLine(
        center + direction * innerRadius,
        center + direction * outerRadius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_V3AgentRunGlyphPainter oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}
