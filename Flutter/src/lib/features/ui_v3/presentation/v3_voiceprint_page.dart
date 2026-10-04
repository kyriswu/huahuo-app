import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../app/di/onboarding_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../onboarding/data/first_launch_device_setup_repository.dart';
import '../application/voiceprint_controller.dart';
import '../domain/voiceprint_profile.dart';

enum _VoiceprintProfileAction { rename, rerecord, delete }

class V3VoiceprintPage extends ConsumerStatefulWidget {
  const V3VoiceprintPage({
    this.enrollmentOnly = false,
    this.startupJourney = false,
    this.initialProfileName,
    this.targetProfileId,
    super.key,
  });

  final bool enrollmentOnly;
  final bool startupJourney;
  final String? initialProfileName;
  final String? targetProfileId;

  @override
  ConsumerState<V3VoiceprintPage> createState() => _V3VoiceprintPageState();
}

class _V3VoiceprintPageState extends ConsumerState<V3VoiceprintPage> {
  bool _exiting = false;
  bool _captureAttempted = false;
  int? _startupAccountRevision;

  bool get enrollmentOnly => widget.enrollmentOnly;
  bool get startupJourney => widget.startupJourney;
  String? get initialProfileName => widget.initialProfileName;
  String? get targetProfileId => widget.targetProfileId;

  @override
  void initState() {
    super.initState();
    if (startupJourney) {
      _startupAccountRevision = ref
          .read(firstLaunchDeviceSetupControllerProvider)
          .accountRevision;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      voiceprintControllerProvider.select((controller) => controller.state),
      (previous, next) {
        if (startupJourney &&
            _captureAttempted &&
            !_exiting &&
            next.status == VoiceprintStatus.failed) {
          scheduleMicrotask(() {
            if (mounted) {
              unawaited(_returnToManagement(context, enrollmentFailed: true));
            }
          });
        }
      },
    );
    final colors = HuahuoV3Theme.tokensOf(context);
    final state = ref.watch(voiceprintControllerProvider).state;
    final controller = ref.read(voiceprintControllerProvider);
    final targetProfile = _voiceprintProfileForId(
      state.profiles,
      targetProfileId,
    );
    final enrollmentVisible = enrollmentOnly;
    final suggestedName = _suggestedProfileName(state.profiles);
    final enrollmentName =
        state.pendingProfileName ??
        targetProfile?.name ??
        _routeProfileName(initialProfileName) ??
        suggestedName;
    final enrollmentTargetProfileId =
        state.targetProfileId ?? targetProfile?.id;
    final replacingExistingProfile = state.profiles.any(
      (profile) => profile.id == state.targetProfileId,
    );
    final page = V3PageScaffold(
      title: enrollmentVisible ? '录入声纹' : '声纹识别',
      centerTitle: true,
      showBack: !enrollmentOnly,
      fallbackRoute: enrollmentVisible ? '/v3/profile/voiceprint' : '/v3',
      trailing: enrollmentVisible
          ? startupJourney
                ? TextButton(
                    key: const ValueKey('voiceprint-startup-next'),
                    onPressed: _exiting
                        ? null
                        : () => unawaited(_returnToManagement(context)),
                    child: Text(_captureAttempted ? '下一步' : '稍后录入'),
                  )
                : null
          : IconButton(
              key: const ValueKey('voiceprint-help'),
              tooltip: '使用说明',
              onPressed: () => unawaited(_showUsageGuide(context)),
              icon: const Icon(Icons.help_outline_rounded),
            ),
      children: [
        if (!enrollmentVisible) ...[
          const _VoiceprintIntroduction(),
          const SizedBox(height: 14),
        ],
        const _VoiceprintPrivacyNotice(),
        const SizedBox(height: 16),
        if (!enrollmentVisible) ...[
          Row(
            children: [
              const Expanded(
                child: Text(
                  '声纹管理',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${state.profiles.length} 个声纹',
                style: TextStyle(color: colors.muted, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (state.profiles.isEmpty)
            const _VoiceprintEmptyState()
          else
            for (final profile in state.profiles) ...[
              _VoiceprintProfileCard(
                profile: profile,
                busy: state.isBusy,
                onMore: () => unawaited(
                  _showProfileActions(context, controller, profile),
                ),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 6),
          IgnorePointer(
            ignoring: state.isBusy,
            child: Opacity(
              opacity: state.isBusy ? .45 : 1,
              child: state.profiles.isEmpty
                  ? V3PrimaryButton(
                      label: '创建首个声纹',
                      icon: Icons.person_add_alt_1_outlined,
                      onPressed: () =>
                          unawaited(_createProfile(context, controller)),
                    )
                  : V3OutlineButton(
                      label: '新增声纹',
                      icon: Icons.person_add_alt_1_outlined,
                      onPressed: () =>
                          unawaited(_createProfile(context, controller)),
                    ),
            ),
          ),
        ] else ...[
          if (state.pendingProfileName != null || enrollmentOnly) ...[
            Text(
              state.pendingProfileName == null
                  ? '准备录入：$enrollmentName'
                  : !replacingExistingProfile
                  ? '正在录入：${state.pendingProfileName}'
                  : '正在重新录入：${state.pendingProfileName}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
          ],
          const _EnrollmentPreparationGuide(),
          const SizedBox(height: 14),
          const _EnrollmentCopyCard(),
          const SizedBox(height: 18),
          Center(
            child: Text(
              _durationText(state.elapsedSeconds),
              key: const ValueKey('voiceprint-duration'),
              style: const TextStyle(
                fontSize: 46,
                height: 1,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              state.status == VoiceprintStatus.recording
                  ? state.elapsedSeconds < voiceprintMinimumSeconds
                        ? '至少还需 ${voiceprintMinimumSeconds - state.elapsedSeconds} 秒'
                        : '录音时长已满足，可结束录入'
                  : '录制 10 秒，满 10 秒自动结束',
              style: TextStyle(color: colors.muted, fontSize: 13),
            ),
          ),
          const SizedBox(height: 18),
          V3Waveform(
            active: state.status == VoiceprintStatus.recording,
            samples: state.waveformLevels,
            height: 88,
          ),
          const SizedBox(height: 22),
          if (state.status == VoiceprintStatus.ready) ...[
            V3Card(
              child: CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: state.consentAccepted,
                onChanged: state.isBusy
                    ? null
                    : (value) => controller.setConsentAccepted(value == true),
                title: const Text(
                  '我同意将这段声音用于识别“我”的发言',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  '这段声音仅用于辅助识别你的发言；录入完成后，本机临时声音会被删除。',
                  style: TextStyle(fontSize: 12.5, height: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 12),
            V3PrimaryButton(
              label: state.status == VoiceprintStatus.submitting
                  ? '录入中'
                  : '确认录入',
              icon: Icons.verified_user_outlined,
              enabled: state.canSubmit,
              onPressed: () => unawaited(_submit(context, ref, controller)),
            ),
            const SizedBox(height: 10),
            V3OutlineButton(
              label: '放弃本次录音',
              icon: Icons.delete_outline,
              onPressed: () => unawaited(_discard(context, controller)),
            ),
          ] else if (state.status == VoiceprintStatus.recording) ...[
            V3PrimaryButton(
              label: state.canStop ? '结束录入' : '继续朗读',
              icon: state.canStop ? Icons.stop_rounded : Icons.mic_rounded,
              enabled: state.canStop,
              onPressed: () => unawaited(controller.stop()),
            ),
          ] else if (state.isBusy) ...[
            V3PrimaryButton(
              label: _busyLabel(state.status),
              icon: Icons.hourglass_top_rounded,
              enabled: false,
              onPressed: null,
            ),
          ] else ...[
            V3PrimaryButton(
              label: '开始录入',
              icon: Icons.mic_none_rounded,
              onPressed: () => unawaited(
                _beginEnrollment(
                  controller,
                  name: enrollmentName,
                  profileId: enrollmentTargetProfileId,
                ),
              ),
            ),
          ],
        ],
        if (state.errorCode != null) ...[
          const SizedBox(height: 14),
          _FailureCard(
            errorCode: state.errorCode!,
            onRetry: () => unawaited(
              state.errorCode == 'VOICEPRINT_PROFILE_SYNC_FAILED'
                  ? controller.refreshProfiles()
                  : state.pendingProfileName == null
                  ? _beginEnrollment(
                      controller,
                      name: enrollmentName,
                      profileId: enrollmentTargetProfileId,
                    )
                  : _beginEnrollment(
                      controller,
                      name: enrollmentName,
                      profileId: enrollmentTargetProfileId,
                    ),
            ),
            onOpenSettings: _isPermissionFailure(state.errorCode!)
                ? () => unawaited(
                    ref
                        .read(platformPermissionsPortProvider)
                        .openAppSettings(
                          PlatformPermissionKind.microphone,
                          impactAcknowledged: true,
                        ),
                  )
                : null,
          ),
        ],
      ],
    );
    if (!enrollmentOnly) return page;
    return PopScope<Object?>(
      canPop: _exiting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_exiting) {
          unawaited(_leaveEnrollment(context, controller));
        }
      },
      child: Stack(
        children: [
          page,
          Positioned(
            left: 10,
            top: MediaQuery.paddingOf(context).top + 4,
            child: V3NavigationBackButton(
              key: const ValueKey('voiceprint-enrollment-back'),
              tooltip: '返回',
              onPressed: () => unawaited(_leaveEnrollment(context, controller)),
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _beginEnrollment(
    VoiceprintController controller, {
    required String name,
    String? profileId,
  }) async {
    if (_exiting) return false;
    _captureAttempted = true;
    try {
      final started = await controller.beginProfileEnrollment(
        name: name,
        profileId: profileId,
      );
      if (!started && startupJourney && mounted) {
        await _returnToManagement(context, enrollmentFailed: true);
      }
      return started;
    } catch (_) {
      if (startupJourney && mounted) {
        await _returnToManagement(context, enrollmentFailed: true);
      }
      return false;
    }
  }

  Future<void> _releaseStartupEnrollment() async {
    final controller = ref.read(voiceprintControllerProvider);
    try {
      final released = await controller.abandonEnrollment(
        allowPendingSubmission: true,
      );
      if (!released && mounted) showV3Snack(context, '本次录入已结束，临时录音清理未完成');
    } catch (_) {
      if (mounted) showV3Snack(context, '本次录入已结束，临时录音清理未完成');
    }
  }

  Future<void> _createProfile(
    BuildContext context,
    VoiceprintController controller,
  ) async {
    final name = await showV3TextInputDialog(
      context: context,
      title: '新增声纹',
      initialValue: '',
      label: '声纹名称',
      confirmLabel: '继续',
      maxLength: 24,
      inputKey: const ValueKey('voiceprint-name-input'),
      validator: controller.profileNameError,
    );
    if (name == null || !context.mounted) return;
    _openEnrollment(context, name: name);
  }

  Future<void> _showUsageGuide(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '声纹识别使用说明',
        message:
            '1. 为要识别的人创建一个声纹名称。\n'
            '2. 在安静环境中，用正常语速自然朗读 10 秒，录音会自动结束。\n'
            '3. 录入完成后，后续转写可尝试将匿名说话人匹配为该名称。\n\n'
            '录入时请让手机距离嘴部约 20-40 厘米，不要用播放录音代替真人朗读。识别结果仍可能受环境噪声和多人同时说话影响。',
        primaryLabel: '知道了',
        onPrimary: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  Future<void> _submit(
    BuildContext context,
    WidgetRef ref,
    VoiceprintController controller,
  ) async {
    if (_exiting) return;
    bool submitted;
    try {
      submitted = await controller.submit();
    } catch (_) {
      submitted = false;
    }
    if (!context.mounted || _exiting) return;
    if (!submitted) {
      if (startupJourney) {
        showV3Snack(context, '本次声纹录入未完成，可稍后重试，继续录音卡引导');
        await _returnToManagement(context, enrollmentFailed: true);
      }
      return;
    }
    showV3Snack(context, '声纹已录入');
    await _returnToManagement(context, enrollmentSucceeded: true);
  }

  Future<void> _discard(
    BuildContext context,
    VoiceprintController controller,
  ) async {
    if (startupJourney) {
      await _returnToManagement(context);
      return;
    }
    final discarded = await controller.discardDraft();
    if (!discarded || !context.mounted) return;
    showV3Snack(context, '已删除本次录音');
    await _returnToManagement(context);
  }

  Future<void> _showProfileActions(
    BuildContext context,
    VoiceprintController controller,
    VoiceprintProfile profile,
  ) async {
    final action = await showV3ActionSheet<_VoiceprintProfileAction>(
      context: context,
      title: profile.name,
      items: const [
        V3ActionSheetItem(
          value: _VoiceprintProfileAction.rename,
          icon: Icons.edit_outlined,
          label: '重命名',
        ),
        V3ActionSheetItem(
          value: _VoiceprintProfileAction.rerecord,
          icon: Icons.mic_none_rounded,
          label: '重新录入',
          subtitle: '保留名称并重新采集声音',
        ),
        V3ActionSheetItem(
          value: _VoiceprintProfileAction.delete,
          icon: Icons.delete_outline,
          label: '删除声纹',
          destructive: true,
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _VoiceprintProfileAction.rename:
        await _renameProfile(context, controller, profile);
        return;
      case _VoiceprintProfileAction.rerecord:
        await _confirmRerecord(context, profile);
        return;
      case _VoiceprintProfileAction.delete:
        await _confirmDelete(context, controller, profile);
        return;
    }
  }

  Future<void> _renameProfile(
    BuildContext context,
    VoiceprintController controller,
    VoiceprintProfile profile,
  ) async {
    final name = await showV3TextInputDialog(
      context: context,
      title: '重命名声纹',
      initialValue: profile.name,
      label: '声纹名称',
      maxLength: 24,
      inputKey: const ValueKey('voiceprint-rename-input'),
      validator: (value) =>
          controller.profileNameError(value, excludingProfileId: profile.id),
    );
    if (name == null || !context.mounted) return;
    if (controller.renameProfile(profile.id, name)) {
      showV3Snack(context, '声纹已重命名');
    }
  }

  Future<void> _confirmRerecord(
    BuildContext context,
    VoiceprintProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '重新录入“${profile.name}”？',
        message: '录入成功后会更新该声纹的录入时间。',
        primaryLabel: '重新录入',
        onPrimary: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed == true && context.mounted) {
      _openEnrollment(context, profileId: profile.id);
    }
  }

  void _openEnrollment(
    BuildContext context, {
    String? name,
    String? profileId,
  }) {
    final queryParameters = <String, String>{
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (profileId != null && profileId.trim().isNotEmpty)
        'profileId': profileId.trim(),
    };
    final route = Uri(
      path: '/v3/profile/voiceprint/enroll',
      queryParameters: queryParameters,
    ).toString();
    unawaited(context.push<void>(route));
  }

  Future<void> _leaveEnrollment(
    BuildContext context,
    VoiceprintController controller,
  ) async {
    if (_exiting) return;
    if (startupJourney) {
      await _returnToManagement(context);
      return;
    }
    final abandoned = await controller.abandonEnrollment();
    if (!context.mounted) return;
    if (!abandoned) {
      showV3Snack(context, '正在处理声纹，请稍候');
      return;
    }
    await _returnToManagement(context);
  }

  Future<void> _returnToManagement(
    BuildContext context, {
    bool enrollmentSucceeded = false,
    bool enrollmentFailed = false,
  }) async {
    if (!mounted || _exiting) return;
    setState(() => _exiting = true);
    final result = startupJourney && !enrollmentSucceeded && !enrollmentFailed
        ? null
        : enrollmentSucceeded;
    if (startupJourney) unawaited(_releaseStartupEnrollment());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (startupJourney &&
          ref.read(firstLaunchDeviceSetupControllerProvider).accountRevision !=
              _startupAccountRevision) {
        return;
      }
      if (canReturnToPreviousRoute(context)) {
        unawaited(returnToPreviousRoute<bool>(context, result: result));
      } else if (startupJourney) {
        final saved = ref
            .read(firstLaunchDeviceSetupControllerProvider)
            .finishVoiceprint(
              result == true
                  ? FirstLaunchStepStatus.succeeded
                  : result == false
                  ? FirstLaunchStepStatus.failed
                  : FirstLaunchStepStatus.deferred,
              expectedAccountRevision: _startupAccountRevision,
              errorCode: result == false ? 'VOICEPRINT_ENROLL_FAILED' : null,
            );
        if (saved) {
          context.go(AppRoutePaths.firstLaunchDeviceSetup);
        } else {
          setState(() => _exiting = false);
          showV3Snack(context, '暂时无法保存启动进度，请重试');
        }
      } else {
        context.go('/v3/profile/voiceprint');
      }
    });
  }

  Future<void> _confirmDelete(
    BuildContext context,
    VoiceprintController controller,
    VoiceprintProfile profile,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '删除“${profile.name}”？',
        message: '删除后，后续转写将无法通过该声纹识别对应说话人。',
        cancelLabel: '取消',
        primaryLabel: '删除',
        onPrimary: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed != true) return;
    final deleted = await controller.deleteProfile(profile.id);
    if (context.mounted && deleted) showV3Snack(context, '声纹已删除');
  }
}

VoiceprintProfile? _voiceprintProfileForId(
  List<VoiceprintProfile> profiles,
  String? profileId,
) {
  if (profileId == null || profileId.trim().isEmpty) return null;
  for (final profile in profiles) {
    if (profile.id == profileId) return profile;
  }
  return null;
}

String? _routeProfileName(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _suggestedProfileName(List<VoiceprintProfile> profiles) {
  final names = profiles.map((profile) => profile.name.toLowerCase()).toSet();
  if (!names.contains('我的声纹')) return '我的声纹';
  for (var suffix = 2; suffix < 100; suffix++) {
    final candidate = '我的声纹 $suffix';
    if (!names.contains(candidate.toLowerCase())) return candidate;
  }
  return '新声纹';
}

class _VoiceprintEmptyState extends StatelessWidget {
  const _VoiceprintEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      child: Column(
        children: <Widget>[
          Icon(Icons.graphic_eq_rounded, size: 34, color: colors.success),
          const SizedBox(height: 10),
          const Text(
            '还没有声纹档案',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            '先创建名称，再按需要开始录入。',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.muted, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _VoiceprintIntroduction extends StatelessWidget {
  const _VoiceprintIntroduction();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '让 AI 认出已录入的声音',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          '录入后，转写时可尝试把匿名说话人标注为你保存的声纹名称。',
          style: TextStyle(color: colors.muted, fontSize: 14, height: 1.45),
        ),
        const SizedBox(height: 14),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.line),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: _SpeakerLabelExample(
                    label: '录入前',
                    speaker: '说话人 1',
                    emphasized: false,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(Icons.arrow_forward_rounded, size: 21),
                ),
                Expanded(
                  child: _SpeakerLabelExample(
                    label: '录入后',
                    speaker: '我的声纹',
                    emphasized: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SpeakerLabelExample extends StatelessWidget {
  const _SpeakerLabelExample({
    required this.label,
    required this.speaker,
    required this.emphasized,
  });

  final String label;
  final String speaker;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: colors.muted, fontSize: 11.5)),
        const SizedBox(height: 7),
        Row(
          children: [
            Icon(
              emphasized ? Icons.verified_rounded : Icons.person_outline,
              size: 17,
              color: emphasized ? colors.success : colors.muted,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                speaker,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          '你好，今天我们...',
          style: TextStyle(color: colors.muted, fontSize: 11.5),
        ),
      ],
    );
  }
}

class _EnrollmentPreparationGuide extends StatelessWidget {
  const _EnrollmentPreparationGuide();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      label: '录入前准备：保持环境安静，手机距离嘴部二十到四十厘米，使用正常语速自然朗读',
      child: Row(
        children: [
          for (final item in const <(IconData, String)>[
            (Icons.volume_off_outlined, '环境安静'),
            (Icons.straighten_rounded, '距离 20-40cm'),
            (Icons.record_voice_over_outlined, '自然朗读'),
          ]) ...[
            Expanded(
              child: Column(
                children: [
                  Icon(item.$1, size: 21, color: colors.accent),
                  const SizedBox(height: 5),
                  Text(
                    item.$2,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VoiceprintPrivacyNotice extends StatelessWidget {
  const _VoiceprintPrivacyNotice();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.success.withValues(alpha: .32)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.verified_user_outlined, size: 19, color: colors.success),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                '声纹属于敏感生物特征，仅用于辅助识别你的发言。你可以随时重新录入或删除。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: colors.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EnrollmentCopyCard extends StatelessWidget {
  const _EnrollmentCopyCard();

  @override
  Widget build(BuildContext context) {
    return V3Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.record_voice_over_outlined, size: 21),
              SizedBox(width: 8),
              Text(
                '请自然朗读以下内容',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 13),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Padding(
              padding: EdgeInsets.all(13),
              child: Text(
                voiceprintEnrollmentText,
                style: TextStyle(fontSize: 16, height: 1.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceprintProfileCard extends StatelessWidget {
  const _VoiceprintProfileCard({
    required this.profile,
    required this.busy,
    required this.onMore,
  });

  final VoiceprintProfile profile;
  final bool busy;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final date = profile.enrolledAt.toLocal();
    final dateText =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return V3Card(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Row(
        children: [
          CircleAvatar(
            radius: 23,
            backgroundColor: colors.success.withValues(alpha: .12),
            child: Icon(
              Icons.graphic_eq_rounded,
              size: 25,
              color: colors.success,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (profile.isDemo) ...[
                      const SizedBox(width: 7),
                      const _LegacyProfileBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  profile.isDemo
                      ? '创建于 $dateText · 待重新录入'
                      : '录入于 $dateText · 已生效',
                  style: TextStyle(color: colors.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('voiceprint-profile-more-${profile.id}'),
            tooltip: '管理 ${profile.name}',
            onPressed: busy ? null : onMore,
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
    );
  }
}

class _LegacyProfileBadge extends StatelessWidget {
  const _LegacyProfileBadge();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          '待录入',
          style: TextStyle(
            color: colors.accent,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({
    required this.errorCode,
    required this.onRetry,
    this.onOpenSettings,
  });

  final String errorCode;
  final VoidCallback onRetry;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.danger.withValues(alpha: .32)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _voiceprintErrorText(errorCode),
              style: TextStyle(
                color: colors.danger,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重试'),
                ),
                if (onOpenSettings != null)
                  TextButton.icon(
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: const Text('系统设置'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _durationText(int totalSeconds) {
  final normalized = totalSeconds.clamp(0, voiceprintMaximumSeconds).toInt();
  final minutes = normalized ~/ 60;
  final seconds = normalized % 60;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

String _busyLabel(VoiceprintStatus status) {
  return switch (status) {
    VoiceprintStatus.checkingPermission => '检查麦克风权限',
    VoiceprintStatus.starting => '正在开始录音',
    VoiceprintStatus.stopping => '正在完成录入',
    VoiceprintStatus.submitting => '正在录入',
    VoiceprintStatus.deleting => '正在删除',
    _ => '处理中',
  };
}

bool _isPermissionFailure(String code) =>
    code == 'VOICE_RECORDER_PERMISSION_DENIED' ||
    code == 'VOICE_RECORDER_PERMISSION_BLOCKED' ||
    code == 'VOICE_RECORDER_PERMISSION_UNAVAILABLE';

String _voiceprintErrorText(String code) {
  return switch (code) {
    'VOICEPRINT_LOGIN_REQUIRED' => '请先登录后再录入声纹',
    'VOICE_RECORDER_PERMISSION_DENIED' => '需要麦克风权限才能录入声纹',
    'VOICE_RECORDER_PERMISSION_BLOCKED' => '麦克风权限已被系统阻止',
    'VOICEPRINT_SAMPLE_TOO_SHORT' => '请连续朗读 10 秒',
    'VOICEPRINT_SAMPLE_DURATION_INVALID' => '录音时长不符合 10 秒要求，请重新录入',
    'VOICEPRINT_CONSENT_REQUIRED' => '请先确认声纹使用授权',
    'VOICEPRINT_SAMPLE_DELETE_FAILED' => '本机临时声音未能安全清理，本次录入未保存，请重试',
    'VOICEPRINT_SECURE_TRANSPORT_REQUIRED' => '当前无法完成声纹录入，请稍后再试',
    'VOICEPRINT_SAMPLE_FORMAT_INVALID' => '这段录音无法使用，请重新录入',
    'VOICEPRINT_SAMPLE_SELF_CHECK_FAILED' => '这段录音未能建立可靠声纹，请在安静环境中自然朗读后重新录入',
    'VOICEPRINT_SAMPLE_SIZE_INVALID' => '这段录音无法使用，请重新录入',
    'VOICEPRINT_UPLOAD_TOKEN_FAILED' ||
    'VOICEPRINT_OBJECT_UPLOAD_FAILED' ||
    'VOICEPRINT_UPLOAD_COMPLETE_FAILED' ||
    'UPLOAD_TOKEN_FAILED' ||
    'UPLOAD_OBJECT_FAILED' ||
    'UPLOAD_COMPLETE_FAILED' => '声纹录入失败，请检查网络后重试',
    'VOICEPRINT_TASK_POLL_FAILED' => '暂时无法确认录入状态，请稍后重试',
    'VOICEPRINT_TASK_POLL_TIMEOUT' => '声纹处理时间较长，请稍后重试',
    'VOICEPRINT_RESPONSE_INVALID' => '声纹功能暂时异常，请稍后重试',
    'VOICEPRINT_API_UNAVAILABLE' => '声纹功能暂不可用',
    'VOICEPRINT_PROFILE_SYNC_FAILED' => '暂时无法更新声纹档案，请稍后重试',
    'NETWORK_REQUEST_FAILED' => '网络连接失败，请检查网络后重试',
    _ => '声纹录入失败，请重新尝试',
  };
}
