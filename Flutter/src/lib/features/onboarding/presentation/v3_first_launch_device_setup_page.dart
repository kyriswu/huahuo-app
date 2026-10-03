import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/onboarding_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../recording_card/widgets/v3_recording_card_connection_dialog.dart';
import '../data/first_launch_device_setup_repository.dart';

class V3FirstLaunchDeviceSetupPage extends ConsumerStatefulWidget {
  const V3FirstLaunchDeviceSetupPage({super.key});

  @override
  ConsumerState<V3FirstLaunchDeviceSetupPage> createState() =>
      _V3FirstLaunchDeviceSetupPageState();
}

class _V3FirstLaunchDeviceSetupPageState
    extends ConsumerState<V3FirstLaunchDeviceSetupPage> {
  bool _operationInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final journey = ref.read(firstLaunchDeviceSetupControllerProvider);
      if (journey.phase == FirstLaunchJourneyPhase.notStarted ||
          journey.requiresPositioning) {
        context.go('/onboarding');
      } else if (journey.allowsHome) {
        context.go(AppRoutePaths.home);
      }
    });
  }

  void _continueAfterSave(bool saved) {
    if (!mounted) return;
    if (!saved) {
      showV3Snack(context, '暂时无法保存启动进度，请重试');
      return;
    }
    if (ref.read(firstLaunchDeviceSetupControllerProvider).allowsHome) {
      context.go(AppRoutePaths.home);
    }
  }

  Future<void> _openVoiceprintEnrollment() async {
    if (_operationInFlight) return;
    final journey = ref.read(firstLaunchDeviceSetupControllerProvider);
    if (!journey.allowsVoiceprintEnrollment) return;
    final revision = journey.accountRevision;
    _operationInFlight = true;
    try {
      final result = await context.push<bool>(
        Uri(
          path: '/v3/profile/voiceprint/enroll',
          queryParameters: const {'name': '我的声纹', 'startup': '1'},
        ).toString(),
      );
      if (!mounted || revision != journey.accountRevision) return;
      final outcome = switch (result) {
        true => FirstLaunchStepStatus.succeeded,
        false => FirstLaunchStepStatus.failed,
        null => FirstLaunchStepStatus.deferred,
      };
      _continueAfterSave(
        journey.finishVoiceprint(
          outcome,
          expectedAccountRevision: revision,
          errorCode: result == false ? 'VOICEPRINT_ENROLL_FAILED' : null,
        ),
      );
    } catch (_) {
      if (mounted && revision == journey.accountRevision) {
        _continueAfterSave(
          journey.finishVoiceprint(
            FirstLaunchStepStatus.failed,
            expectedAccountRevision: revision,
            errorCode: 'VOICEPRINT_ENROLL_FAILED',
          ),
        );
      }
    } finally {
      _operationInFlight = false;
    }
  }

  void _deferVoiceprint() {
    _continueAfterSave(
      ref
          .read(firstLaunchDeviceSetupControllerProvider)
          .finishVoiceprint(FirstLaunchStepStatus.deferred),
    );
  }

  void _deferRecordingCard() {
    _continueAfterSave(
      ref
          .read(firstLaunchDeviceSetupControllerProvider)
          .finishRecordingCard(FirstLaunchStepStatus.deferred),
    );
  }

  Future<void> _searchRecordingCards() async {
    if (_operationInFlight) return;
    final journey = ref.read(firstLaunchDeviceSetupControllerProvider);
    if (journey.phase != FirstLaunchJourneyPhase.recordingCardRequired) return;
    final revision = journey.accountRevision;
    final recordingCard = ref.read(recordingCardControllerProvider);
    _operationInFlight = true;
    try {
      final result = await showV3RecordingCardConnectionDialog(
        context,
        controller: recordingCard,
        requireSerialConfirmation: true,
        exitAfterFailure: true,
      );
      if (!mounted || revision != journey.accountRevision) return;
      final serial = normalizeFirstLaunchRecordingCardSerial(
        result.serialNumber,
      );
      final outcome = switch (result.outcome) {
        RecordingCardConnectionOutcome.connected when serial != null =>
          FirstLaunchStepStatus.succeeded,
        RecordingCardConnectionOutcome.deferred =>
          FirstLaunchStepStatus.deferred,
        _ => FirstLaunchStepStatus.failed,
      };
      _continueAfterSave(
        journey.finishRecordingCard(
          outcome,
          expectedAccountRevision: revision,
          serialNumber: serial,
          errorCode:
              result.errorCode ??
              (outcome == FirstLaunchStepStatus.failed
                  ? 'RECORDING_CARD_IDENTITY_UNAVAILABLE'
                  : null),
        ),
      );
    } catch (_) {
      if (mounted && revision == journey.accountRevision) {
        _continueAfterSave(
          journey.finishRecordingCard(
            FirstLaunchStepStatus.failed,
            expectedAccountRevision: revision,
            errorCode: 'RECORDING_CARD_CONNECT_FAILED',
          ),
        );
      }
    } finally {
      _operationInFlight = false;
    }
  }

  Future<void> _reconnectRecordingCard() async {
    if (_operationInFlight) return;
    final journey = ref.read(firstLaunchDeviceSetupControllerProvider);
    final revision = journey.accountRevision;
    final recordingCard = ref.read(recordingCardControllerProvider);
    _operationInFlight = true;
    try {
      await recordingCard.disconnect();
      if (!mounted ||
          revision != journey.accountRevision ||
          journey.phase != FirstLaunchJourneyPhase.recordingCardRequired) {
        return;
      }
      if (recordingCard.state.snapshot.deviceState.isOperationallyConnected) {
        _continueAfterSave(
          journey.finishRecordingCard(
            FirstLaunchStepStatus.failed,
            expectedAccountRevision: revision,
            errorCode: 'RECORDING_CARD_DISCONNECT_FAILED',
          ),
        );
        return;
      }
    } catch (_) {
      if (mounted && revision == journey.accountRevision) {
        _continueAfterSave(
          journey.finishRecordingCard(
            FirstLaunchStepStatus.failed,
            expectedAccountRevision: revision,
            errorCode: 'RECORDING_CARD_DISCONNECT_FAILED',
          ),
        );
      }
      return;
    } finally {
      _operationInFlight = false;
    }
    if (mounted &&
        revision == journey.accountRevision &&
        journey.phase == FirstLaunchJourneyPhase.recordingCardRequired) {
      await _searchRecordingCards();
    }
  }

  void _confirmRecordingCardOwnership() {
    final device = ref
        .read(recordingCardControllerProvider)
        .state
        .snapshot
        .deviceState;
    final serial = normalizeFirstLaunchRecordingCardSerial(device.serialNumber);
    if (!device.isOperationallyConnected || serial == null) {
      _continueAfterSave(
        ref
            .read(firstLaunchDeviceSetupControllerProvider)
            .finishRecordingCard(
              FirstLaunchStepStatus.failed,
              errorCode: 'RECORDING_CARD_IDENTITY_UNAVAILABLE',
            ),
      );
      return;
    }
    _continueAfterSave(
      ref
          .read(firstLaunchDeviceSetupControllerProvider)
          .finishRecordingCard(
            FirstLaunchStepStatus.succeeded,
            serialNumber: serial,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final journey = ref.watch(firstLaunchDeviceSetupControllerProvider);
    final device =
        journey.phase == FirstLaunchJourneyPhase.recordingCardRequired
        ? ref.watch(recordingCardControllerProvider).state.snapshot.deviceState
        : null;
    final page = switch (journey.phase) {
      FirstLaunchJourneyPhase.voiceprintRequired => _VoiceprintGuideStep(
        totalSteps: journey.snapshot.hasChatGuide ? 4 : 3,
        onEnroll: () => unawaited(_openVoiceprintEnrollment()),
        onDefer: _deferVoiceprint,
      ),
      FirstLaunchJourneyPhase.recordingCardRequired
          when device!.isOperationallyConnected =>
        _RecordingCardOwnershipConfirmationStep(
          totalSteps: journey.snapshot.hasChatGuide ? 4 : 3,
          device: device,
          onConfirm: _confirmRecordingCardOwnership,
          onReconnect: () => unawaited(_reconnectRecordingCard()),
          onDefer: _deferRecordingCard,
        ),
      FirstLaunchJourneyPhase.recordingCardRequired => _RecordingCardGuideStep(
        totalSteps: journey.snapshot.hasChatGuide ? 4 : 3,
        onSearch: () => unawaited(_searchRecordingCards()),
        onDefer: _deferRecordingCard,
      ),
      _ => const _GuideLoadingPage(),
    };
    return PopScope(canPop: false, child: page);
  }
}

class _VoiceprintGuideStep extends StatelessWidget {
  const _VoiceprintGuideStep({
    required this.onEnroll,
    required this.onDefer,
    required this.totalSteps,
  });

  final int totalSteps;
  final VoidCallback onEnroll;
  final VoidCallback onDefer;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3PageScaffold(
      title: '首次设备设置',
      subtitle: '录入或稍后处理，都将继续录音卡引导',
      trailing: TextButton(
        key: const ValueKey('first-launch-voiceprint-skip'),
        onPressed: onDefer,
        child: const Text('稍后录入'),
      ),
      showBack: false,
      inlineTitle: true,
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
      bottomBar: V3PrimaryButton(
        key: const ValueKey('first-launch-voiceprint-enroll'),
        label: '去录入声纹',
        onPressed: onEnroll,
      ),
      children: [
        _GuideHeader(
          step: '2 / $totalSteps',
          icon: Icons.graphic_eq_rounded,
          title: '录入你的声纹',
          detail: '让后续录音转写更容易识别并标注“我”的发言。',
        ),
        const SizedBox(height: 22),
        const V3SectionTitle('有什么用'),
        Text(
          '多人对话转写时，声纹会帮助系统区分你的发言，减少后续手动修改说话人的次数。',
          style: TextStyle(color: colors.text, height: 1.62),
        ),
        const SizedBox(height: 22),
        const V3SectionTitle('怎么录入'),
        const _GuideStep(
          number: '1',
          title: '准备安静环境',
          detail: '点击下方按钮，按提示允许麦克风。',
        ),
        const _GuideStep(
          number: '2',
          title: '自然朗读 10 秒',
          detail: '保持正常音量，让系统采集连续、清晰的声音样本。',
        ),
        const _GuideStep(
          number: '3',
          title: '确认后上传',
          detail: '样本仅用于识别你的发言；云端受理后，本机临时样本会被删除。',
          last: true,
        ),
      ],
    );
  }
}

class _RecordingCardGuideStep extends StatelessWidget {
  const _RecordingCardGuideStep({
    required this.totalSteps,
    required this.onSearch,
    required this.onDefer,
  });

  final int totalSteps;
  final VoidCallback onSearch;
  final VoidCallback onDefer;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3PageScaffold(
      title: '首次设备设置',
      subtitle: totalSteps == 4 ? '连接或稍后处理，下一步去主页认识聊一聊' : '连接或稍后处理，都可完成本次启动引导',
      trailing: TextButton(
        key: const ValueKey('first-launch-recording-card-skip'),
        onPressed: onDefer,
        child: const Text('稍后连接'),
      ),
      showBack: false,
      inlineTitle: true,
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
      bottomBar: V3PrimaryButton(
        key: const ValueKey('first-launch-recording-card-search'),
        label: '搜索附近录音卡',
        onPressed: onSearch,
      ),
      children: [
        _GuideHeader(
          step: '3 / $totalSteps',
          icon: Icons.credit_card_rounded,
          title: '连接录音卡',
          detail: '先搜索附近录音卡，再核对机身 SN 码，确认后完成连接。',
        ),
        const SizedBox(height: 22),
        const V3SectionTitle('连接前准备'),
        Text(
          '多人同时配对时，请务必核对机身背面的 SN 码，确认列表中的设备就是你手上的录音卡。',
          style: TextStyle(
            color: colors.accent,
            fontWeight: FontWeight.w600,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        const _GuideStep(
          number: '1',
          title: '查看机身 SN 码',
          detail: '在录音卡背面找到 SN 码，记住其 6 位。',
        ),
        const _GuideStep(
          number: '2',
          title: '保持设备开机',
          detail: '将录音卡放在手机附近，避免与他人的设备混放。',
        ),
        const _GuideStep(
          number: '3',
          title: '搜索附近设备',
          detail: '点击下方按钮，系统会列出可连接的录音卡。',
        ),
        const _GuideStep(
          number: '4',
          title: '核对后连接',
          detail: '仅当设备名称与机身 SN 码一致时确认连接。',
          last: true,
        ),
      ],
    );
  }
}

class _RecordingCardOwnershipConfirmationStep extends StatelessWidget {
  const _RecordingCardOwnershipConfirmationStep({
    required this.totalSteps,
    required this.device,
    required this.onConfirm,
    required this.onReconnect,
    required this.onDefer,
  });

  final int totalSteps;
  final RecordingCardDeviceState device;
  final VoidCallback onConfirm;
  final VoidCallback onReconnect;
  final VoidCallback onDefer;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final serial = normalizeFirstLaunchRecordingCardSerial(device.serialNumber);
    final hasReadableSerial = serial != null && serial.isNotEmpty;
    final deviceName = device.displayName?.trim().isNotEmpty == true
        ? device.displayName!.trim()
        : '花火录音卡';
    return V3PageScaffold(
      title: '确认已连接的录音卡',
      subtitle: '确认或稍后处理，都可继续下一步',
      showBack: false,
      trailing: TextButton(
        key: const ValueKey('first-launch-recording-card-skip'),
        onPressed: onDefer,
        child: const Text('稍后连接'),
      ),
      inlineTitle: true,
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
      bottomBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          V3PrimaryButton(
            key: const ValueKey('first-launch-recording-card-reconnect'),
            label: '不是我的设备，重新连接',
            weak: true,
            onPressed: onReconnect,
          ),
          const SizedBox(height: 10),
          V3PrimaryButton(
            key: const ValueKey(
              'first-launch-recording-card-confirm-ownership',
            ),
            label: hasReadableSerial ? '确认是我的录音卡' : '下一步',
            onPressed: onConfirm,
          ),
        ],
      ),
      children: [
        _GuideHeader(
          step: '3 / $totalSteps',
          icon: Icons.credit_card_rounded,
          title: '已发现连接中的录音卡',
          detail: '连接成功不等于确认完成，请先核对机身设备编号。',
        ),
        const SizedBox(height: 22),
        const V3SectionTitle('核对当前设备'),
        Text(
          hasReadableSerial
              ? '设备编号：$serial\n请与机身编号核对，确认这是你手上的录音卡。'
              : '暂时没有读取到设备编号，可以先进入下一步，稍后重新连接。',
          style: TextStyle(
            color: colors.accent,
            fontWeight: FontWeight.w600,
            height: 1.55,
          ),
        ),
        const SizedBox(height: 18),
        const _GuideStep(
          number: '1',
          title: '查看机身设备编号',
          detail: '找到录音卡背面的完整设备编号。',
        ),
        _GuideStep(
          number: '2',
          title: '核对末 6 位',
          detail: hasReadableSerial
              ? '当前连接：$deviceName · $serial'
              : '等待系统读取当前连接设备的编号。',
        ),
        const _GuideStep(number: '3', title: '确认设备归属', detail: '仅在录音卡属于你时继续。'),
        const _GuideStep(
          number: '4',
          title: '完成启动设置',
          detail: '确认后记录设备连接并进入完成页。',
          last: true,
        ),
      ],
    );
  }
}

class _GuideLoadingPage extends StatelessWidget {
  const _GuideLoadingPage();

  @override
  Widget build(BuildContext context) {
    return const V3PageScaffold(
      title: '首次设备设置',
      subtitle: '正在恢复设置进度',
      showBack: false,
      children: <Widget>[
        Center(
          child: Padding(
            padding: EdgeInsets.only(top: 96),
            child: CircularProgressIndicator(),
          ),
        ),
      ],
    );
  }
}

class _GuideHeader extends StatelessWidget {
  const _GuideHeader({
    required this.step,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final String step;
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      variant: V3CardVariant.outlined,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: colors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step,
                  style: HuahuoV3Theme.meta.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(title, style: HuahuoV3Theme.h1),
                const SizedBox(height: 6),
                Text(
                  detail,
                  style: TextStyle(color: colors.muted, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.number,
    required this.title,
    required this.detail,
    this.last = false,
  });

  final String number;
  final String title;
  final String detail;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              number,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: HuahuoV3Theme.listTitle),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(color: colors.muted, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
