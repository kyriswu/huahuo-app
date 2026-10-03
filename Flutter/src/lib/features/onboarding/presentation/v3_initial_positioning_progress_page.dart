import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di/onboarding_providers.dart';
import '../../ui_v3/presentation/v3_positioning_report_page.dart';

class V3InitialPositioningProgressPage extends ConsumerWidget {
  const V3InitialPositioningProgressPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(initialPositioningTaskStateProvider);
    return V3PositioningReportPage(taskId: task.agentRunId);
  }
}
