import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/native_port_providers.dart';
import '../../../app/di/onboarding_providers.dart';
import '../../../app/bootstrap/core_provider_module.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../chat/application/voice_message_controller.dart';
import '../../transcription/presentation/live_transcription_failure_dialog.dart';
import 'v3_initial_positioning_progress_page.dart';
import '../application/content_line_onboarding_controller.dart';
import '../application/first_launch_device_setup_controller.dart';
import '../data/first_launch_device_setup_repository.dart';
import '../data/onboarding_progress_repository.dart';
import '../../ui_v3/domain/positioning_lifecycle.dart';

class ContentLineOnboardingPage extends ConsumerWidget {
  const ContentLineOnboardingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(contentLineOnboardingControllerProvider);
    final lifecycle = ref.watch(positioningLifecycleCoordinatorProvider);
    if (lifecycle != null &&
        lifecycle.access == InitialPositioningAccess.checking) {
      Future<void>.microtask(lifecycle.continueRecovery);
    }
    final access = lifecycle?.access;
    if (access != null &&
        access != InitialPositioningAccess.notStarted &&
        access != InitialPositioningAccess.retryableFailure) {
      return V3PageScaffold(
        title: '基础定位',
        fallbackRoute: AppRoutePaths.home,
        children: [
          Text(switch (access) {
            InitialPositioningAccess.completed => '你已完成基础定位。后续通过深度定位更新当前报告。',
            InitialPositioningAccess.running => '已有基础定位任务，正在恢复原任务，不会重复提交。',
            InitialPositioningAccess.recovering => '基础定位已完成，正在恢复正式报告。',
            InitialPositioningAccess.checking => '正在核对当前账号的定位状态…',
            _ => '暂时无法核对定位状态，问卷答案已保留。请继续恢复，不会重复生成。',
          }),
          TextButton(
            onPressed: () => context.push(AppRoutePaths.positioningReport),
            child: const Text('查看定位报告与进度'),
          ),
          TextButton(
            onPressed: lifecycle?.continueRecovery,
            child: const Text('继续恢复'),
          ),
        ],
      );
    }
    ref.watch(feedAiVoiceMessageControllerProvider.select(identityHashCode));
    final voiceController = ref.read(feedAiVoiceMessageControllerProvider);
    final state = controller.state;
    final journey = ref.watch(firstLaunchDeviceSetupControllerProvider);
    final revision = journey.accountRevision;
    final deferAction = journey.requiresPositioning
        ? TextButton(
            key: const ValueKey('onboarding-defer'),
            onPressed: () => _exitStartupPositioning(
              context,
              journey,
              revision,
              FirstLaunchStepStatus.deferred,
            ),
            child: const Text('稍后填写'),
          )
        : null;
    final accepted = controller.acceptedRun;
    final failed = accepted?.lifecycle == OnboardingAcceptedRunLifecycle.failed;
    final errorCode =
        state.errorCode ?? (failed ? accepted?.failureCode : null);
    final showingReport = state.hasServerReport;
    final acceptedRunPending =
        state.positioningReceipt != null &&
        !showingReport &&
        !state.isSubmitting &&
        errorCode == null &&
        !failed;
    final reportRetryAvailable =
        !showingReport &&
        !state.isSubmitting &&
        state.isLastQuestion &&
        errorCode != null;
    if (showingReport) {
      return const V3InitialPositioningProgressPage();
    }
    if (acceptedRunPending) {
      final journey = ref.watch(firstLaunchDeviceSetupControllerProvider);
      final firstLoginEligible = ref.watch(
        sessionStoreProvider.select(
          (store) => store.state.isFirstLoginSessionEligible,
        ),
      );
      final continuesStartup =
          journey.snapshot.hasStarted || firstLoginEligible;
      final registered = controller.isBackendRegistered;
      final task = ref.watch(initialPositioningTaskStateProvider);
      final registrationFailed =
          accepted?.registrationErrorCode != null ||
          (task.agentRunId == accepted?.agentRunId && task.errorCode != null);
      return V3PageScaffold(
        title: '基础定位',
        trailing: deferAction,
        subtitle: registered ? '后台已接管，报告将在后台生成' : '消息已接受，正在确认后台接管',
        fallbackRoute: continuesStartup
            ? AppRoutePaths.firstLaunchDeviceSetup
            : AppRoutePaths.home,
        bottomBar: V3PrimaryButton(
          label: registered
              ? continuesStartup
                    ? '继续完成设置'
                    : '返回首页'
              : '重试确认提交',
          enabled: registered || registrationFailed,
          busy: !registered && !registrationFailed,
          onPressed: () {
            unawaited(_continueAcceptedSubmission(context, ref, controller));
          },
        ),
        children: [
          Text(
            registered
                ? '无需在此等待，生成完成后会在消息提醒中通知你。'
                : '请保持应用开启，确认后台接管后即可离开。问卷和任务回执已保留，重试不会重复生成。',
          ),
          if (registrationFailed) ...[
            const SizedBox(height: 12),
            const Text('后台接管尚未确认，请检查网络后重试确认提交。'),
          ],
          TextButton(
            onPressed: registered
                ? () => context.push('/v3/positioning/progress')
                : null,
            child: const Text('查看定位报告与进度'),
          ),
        ],
      );
    }
    return V3PageScaffold(
      title: '基础定位',
      trailing: deferAction,
      subtitle: '用几张卡片，梳理你的真实起点',
      inlineTitle: true,
      topBarLeadingWidth: 70,
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 18),
      fallbackRoute: '/v3',
      // ignore: sort_child_properties_last
      children: [
        const SizedBox(height: 10),
        _IntroCard(
          title: state.mode == null
              ? '先选一下你的当前状态'
              : state.currentQuestion?.title ?? '初步了解',
          detail: state.mode == null
              ? '我们会根据你的现状，收集建立第一条内容方向所需的信息。'
              : state.currentQuestion?.detail ?? '不用写标准答案，想到什么先写什么。',
          progress: state.mode == null
              ? null
              : (state.stepIndex + 1) / state.questions.length,
          progressText: state.mode == null
              ? null
              : '${state.stepIndex + 1}/${state.questions.length}',
        ),
        const SizedBox(height: 18),
        if (state.mode == null)
          _ModePicker(
            enabled: !state.isSubmitting,
            onSelected: controller.selectMode,
          )
        else
          _QuestionCard(
            key: ValueKey(
              'onboarding-question-editor-${state.currentQuestion!.id}',
            ),
            question: state.currentQuestion!,
            value: state.answers[state.currentQuestion!.id],
            enabled: !state.isSubmitting,
            voiceController: voiceController,
            onOpenMicrophoneSettings: () => ref
                .read(platformPermissionsPortProvider)
                .openAppSettings(
                  PlatformPermissionKind.microphone,
                  impactAcknowledged: true,
                ),
            onChanged: (answer) =>
                controller.updateAnswer(state.currentQuestion!.id, answer),
          ),
        if (errorCode != null) ...[
          const SizedBox(height: 16),
          _ErrorMessage(message: _onboardingError(errorCode)),
        ],
      ],
      bottomBar: state.mode == null
          ? null
          : Row(
              children: [
                SizedBox(
                  width: 108,
                  child: V3OutlineButton(
                    key: const ValueKey('onboarding-back'),
                    label: '上一张',
                    icon: Icons.chevron_left_rounded,
                    enabled: !state.isSubmitting,
                    onPressed: controller.goBack,
                  ),
                ),
                const SizedBox(width: 19),
                SizedBox(
                  width: state.isLastQuestion ? 172 : 108,
                  child: V3PrimaryButton(
                    key: const ValueKey('onboarding-primary'),
                    label: state.isSubmitting
                        ? '正在提交'
                        : reportRetryAvailable
                        ? '重新生成报告'
                        : state.isLastQuestion
                        ? '完成并生成报告'
                        : '下一张',
                    icon: state.isSubmitting
                        ? null
                        : reportRetryAvailable
                        ? Icons.refresh_rounded
                        : state.isLastQuestion
                        ? Icons.auto_awesome_rounded
                        : null,
                    trailing:
                        !state.isSubmitting &&
                            !reportRetryAvailable &&
                            !state.isLastQuestion
                        ? const Icon(Icons.chevron_right_rounded, size: 20)
                        : null,
                    leading: state.isSubmitting
                        ? SizedBox(
                            key: const ValueKey('onboarding-submit-progress'),
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: HuahuoV3Theme.tokensOf(context).onPrimary,
                            ),
                          )
                        : null,
                    enabled: state.canContinue && !state.isSubmitting,
                    busy: state.isSubmitting,
                    onPressed: state.isLastQuestion
                        ? () => _submit(context, ref, controller)
                        : controller.goNext,
                  ),
                ),
              ],
            ),
      bottomBarPadding: const EdgeInsets.fromLTRB(22, 6, 22, 0),
    );
  }

  Future<void> _submit(
    BuildContext context,
    WidgetRef ref,
    ContentLineOnboardingController controller,
  ) async {
    if (!controller.state.isComplete || controller.state.isSubmitting) return;
    final journey = ref.read(firstLaunchDeviceSetupControllerProvider);
    final revision = journey.accountRevision;
    try {
      final receipt = await controller.startBackground();
      if (revision != journey.accountRevision || !context.mounted) return;
      if (receipt == null) {
        if (journey.requiresPositioning) {
          _exitStartupPositioning(
            context,
            journey,
            revision,
            FirstLaunchStepStatus.failed,
          );
          return;
        }
        showV3Snack(context, '基础定位尚未提交成功，请在当前问卷重试');
        return;
      }
      await _continueAcceptedSubmission(context, ref, controller);
    } catch (_) {
      if (context.mounted && revision == journey.accountRevision) {
        if (journey.requiresPositioning) {
          _exitStartupPositioning(
            context,
            journey,
            revision,
            FirstLaunchStepStatus.failed,
          );
          return;
        }
        showV3Snack(context, '基础定位尚未提交成功，请在当前问卷重试');
      }
    }
  }

  void _exitStartupPositioning(
    BuildContext context,
    FirstLaunchDeviceSetupController journey,
    int revision,
    FirstLaunchStepStatus outcome,
  ) {
    if (revision != journey.accountRevision || !journey.requiresPositioning) {
      return;
    }
    final saved = journey.finishPositioning(
      outcome,
      expectedAccountRevision: revision,
      errorCode: outcome == FirstLaunchStepStatus.failed
          ? 'POSITIONING_SUBMISSION_FAILED'
          : null,
    );
    if (!saved) {
      showV3Snack(context, '暂时无法保存启动进度，请重试');
      return;
    }
    GoRouter.maybeOf(context)?.go(AppRoutePaths.firstLaunchDeviceSetup);
  }

  void _continueSetup(
    BuildContext context,
    WidgetRef ref,
    FirstLaunchDeviceSetupController journey,
    int revision,
  ) {
    if (!journey.snapshot.hasStarted &&
        !ref.read(sessionStoreProvider).state.isFirstLoginSessionEligible) {
      GoRouter.maybeOf(context)?.go(AppRoutePaths.home);
      return;
    }
    final saved = journey.finishPositioning(
      FirstLaunchStepStatus.submitted,
      expectedAccountRevision: revision,
    );
    if (!saved) {
      showV3Snack(context, '任务已接受，启动进度保存失败，请重试');
      return;
    }
    GoRouter.maybeOf(context)?.go(
      journey.snapshot.isComplete
          ? AppRoutePaths.home
          : AppRoutePaths.firstLaunchDeviceSetup,
    );
  }

  Future<void> _continueAcceptedSubmission(
    BuildContext context,
    WidgetRef ref,
    ContentLineOnboardingController controller,
  ) async {
    final accepted = controller.acceptedRun;
    if (accepted == null) return;
    final journey = ref.read(firstLaunchDeviceSetupControllerProvider);
    final revision = journey.accountRevision;
    final registered = await ref.read(initialPositioningRunRegistrarProvider)(
      accepted.agentRunId,
    );
    if (!context.mounted || revision != journey.accountRevision) return;
    if (!registered || !controller.isBackendRegistered) {
      showV3Snack(context, '任务回执已保留，后台接管尚未确认，请重试确认提交');
      return;
    }
    _continueSetup(context, ref, journey, revision);
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({
    required this.title,
    required this.detail,
    this.progress,
    this.progressText,
  });

  final String title;
  final String detail;
  final double? progress;
  final String? progressText;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      variant: V3CardVariant.outlined,
      radius: progress == null ? 16 : 8,
      padding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: progress == null ? 126 : 150),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '初步了解',
              style: HuahuoV3Theme.meta.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              key: const ValueKey('onboarding-question-title'),
              style: HuahuoV3Theme.h1.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(detail, style: TextStyle(color: colors.muted, height: 1.55)),
            if (progress != null) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        key: const ValueKey('onboarding-progress'),
                        value: progress,
                        minHeight: 6,
                        color: colors.primary,
                        backgroundColor: colors.surfaceMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    progressText!,
                    style: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModePicker extends StatelessWidget {
  const _ModePicker({required this.enabled, required this.onSelected});

  final bool enabled;
  final ValueChanged<OnboardingIntakeMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ModeOption(
          key: const ValueKey('onboarding-mode-business'),
          icon: Icons.business_center_outlined,
          title: '有业务',
          detail: '已经有产品、服务或明确成交对象',
          enabled: enabled,
          onTap: () => onSelected(OnboardingIntakeMode.business),
        ),
        const SizedBox(height: 12),
        _ModeOption(
          key: const ValueKey('onboarding-mode-no-business'),
          icon: Icons.explore_outlined,
          title: '没业务',
          detail: '还在找方向、表达主题或用户画像',
          enabled: enabled,
          onTap: () => onSelected(OnboardingIntakeMode.noBusiness),
        ),
      ],
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.icon,
    required this.title,
    required this.detail,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      variant: V3CardVariant.outlined,
      onTap: enabled ? onTap : null,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Icon(icon, color: colors.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: colors.muted),
        ],
      ),
    );
  }
}

class _QuestionCard extends StatefulWidget {
  const _QuestionCard({
    required this.question,
    required this.value,
    required this.enabled,
    required this.voiceController,
    required this.onOpenMicrophoneSettings,
    required this.onChanged,
    super.key,
  });

  final OnboardingIntakeQuestion question;
  final Object? value;
  final bool enabled;
  final VoiceMessageController voiceController;
  final Future<void> Function() onOpenMicrophoneSettings;
  final ValueChanged<Object> onChanged;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  static int _voiceOwnerSequence = 0;
  late final TextEditingController _textController;
  late final String _voiceSessionOwner;
  bool _ownsVoiceCapture = false;
  int? _voiceInsertionStart;
  int _voiceAppliedLength = 0;
  final LiveTranscriptionFailureDialogGate _voiceFailureDialogGate =
      LiveTranscriptionFailureDialogGate();

  @override
  void initState() {
    super.initState();
    _voiceSessionOwner =
        'onboarding:${widget.question.id}:${++_voiceOwnerSequence}';
    _textController = TextEditingController(text: _textValue(widget.value));
    widget.voiceController.addListener(_handleVoiceChanged);
  }

  @override
  void didUpdateWidget(covariant _QuestionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.voiceController, widget.voiceController)) {
      oldWidget.voiceController.removeListener(_handleVoiceChanged);
      if (_ownsVoiceCapture) {
        unawaited(
          oldWidget.voiceController.endCaptureForLeave(
            owner: _voiceSessionOwner,
          ),
        );
      }
      _resetVoiceSession();
      widget.voiceController.addListener(_handleVoiceChanged);
    }
  }

  @override
  void dispose() {
    widget.voiceController.removeListener(_handleVoiceChanged);
    if (_ownsVoiceCapture) {
      unawaited(
        widget.voiceController.endCaptureForLeave(owner: _voiceSessionOwner),
      );
    }
    _textController.dispose();
    super.dispose();
  }

  static String _textValue(Object? value) => value is String ? value : '';

  void _resetVoiceSession() {
    _ownsVoiceCapture = false;
    _voiceInsertionStart = null;
    _voiceAppliedLength = 0;
  }

  void _handleVoiceChanged() {
    if (!mounted) return;
    final state = widget.voiceController.state;
    if (!state.belongsToLiveTranscript(_voiceSessionOwner)) return;
    final insertionStart = _voiceInsertionStart;
    if (_ownsVoiceCapture && insertionStart != null) {
      final current = _textController.text;
      final start = insertionStart.clamp(0, current.length);
      final end = (start + _voiceAppliedLength).clamp(start, current.length);
      final available =
          widget.question.maximumLength - (current.length - (end - start));
      final rawTranscript = state.liveTranscriptText;
      final transcript = rawTranscript.substring(
        0,
        rawTranscript.length.clamp(0, available.clamp(0, rawTranscript.length)),
      );
      final next = current.replaceRange(start, end, transcript);
      if (next != current) {
        _textController.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: start + transcript.length),
        );
        widget.onChanged(next);
      }
      _voiceAppliedLength = transcript.length;
    }
    if (state.status == VoiceMessageControllerStatus.failed &&
        _ownsVoiceCapture) {
      final errorCode =
          state.lastErrorCode ?? 'ONBOARDING_VOICE_TRANSCRIPTION_FAILED';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            _presentVoiceFailure(
              errorCode,
              wasTranscribing: state.liveTranscriptText.trim().isNotEmpty,
              attemptId: state.liveTranscriptAttemptId,
            ),
          );
        }
      });
      _resetVoiceSession();
    }
    setState(() {});
  }

  Future<void> _toggleVoiceTranscription() async {
    final voice = widget.voiceController;
    final state = voice.state;
    if (!widget.enabled || state.isBusy) return;
    if (state.isCaptureActive) {
      if (!_ownsVoiceCapture) {
        _voiceFailureDialogGate.beginAttempt();
        await _presentVoiceFailure(
          'CHAT_LIVE_TRANSCRIPT_SESSION_BUSY',
          attemptId: state.liveTranscriptAttemptId,
        );
        return;
      }
      final stopped = await voice.stopAndTranscribe(owner: _voiceSessionOwner);
      if (!mounted) return;
      _resetVoiceSession();
      if (!stopped && voice.state.lastErrorCode == null) {
        await _presentVoiceFailure(
          'VOICE_TRANSCRIPTION_FAILED',
          wasTranscribing: true,
          attemptId: voice.state.liveTranscriptAttemptId,
        );
      }
      setState(() {});
      return;
    }

    final selection = _textController.selection;
    _voiceInsertionStart = selection.isValid
        ? selection.baseOffset.clamp(0, _textController.text.length)
        : _textController.text.length;
    _voiceAppliedLength = 0;
    _ownsVoiceCapture = true;
    _voiceFailureDialogGate.beginAttempt();
    final started = await voice.startLiveTranscription(
      owner: _voiceSessionOwner,
    );
    if (!mounted) return;
    if (!started) {
      final errorCode =
          voice.state.lastErrorCode ?? 'VOICE_TRANSCRIPTION_FAILED';
      _resetVoiceSession();
      await _presentVoiceFailure(
        errorCode,
        attemptId: voice.state.liveTranscriptAttemptId,
      );
    }
    setState(() {});
  }

  Future<void> _presentVoiceFailure(
    String errorCode, {
    bool wasTranscribing = false,
    int? attemptId,
  }) async {
    if (!mounted ||
        !_voiceFailureDialogGate.claim(
          owner: _voiceSessionOwner,
          attemptId: attemptId,
        )) {
      return;
    }
    late final LiveTranscriptionFailureDialogAction action;
    try {
      action = await showLiveTranscriptionFailureDialog(
        context: context,
        errorCode: errorCode,
        wasTranscribing: wasTranscribing,
      );
    } finally {
      _voiceFailureDialogGate.release();
    }
    if (!mounted) return;
    switch (action) {
      case LiveTranscriptionFailureDialogAction.openSettings:
        await widget.onOpenMicrophoneSettings();
        break;
      case LiveTranscriptionFailureDialogAction.retry:
        await _toggleVoiceTranscription();
        break;
      case LiveTranscriptionFailureDialogAction.dismiss:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      key: ValueKey('onboarding-question-${widget.question.id}'),
      variant: V3CardVariant.outlined,
      radius: 8,
      padding: const EdgeInsets.all(18),
      child: widget.question.input == OnboardingIntakeInput.text
          ? _buildTextAnswer(colors)
          : ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    widget.question.input == OnboardingIntakeInput.multiChoice
                    ? 128
                    : 68,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child:
                    widget.question.input == OnboardingIntakeInput.multiChoice
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final option in _visibleChoices) ...[
                            _buildChoice(
                              widget.question,
                              widget.value,
                              option,
                              colors,
                            ),
                            const SizedBox(height: 10),
                          ],
                          if (widget.question.allowCustomAnswer)
                            _AddChoiceButton(
                              enabled: widget.enabled,
                              onTap: _addCustomChoice,
                              colors: colors,
                            ),
                        ],
                      )
                    : Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final option in _visibleChoices)
                            _buildChoice(
                              widget.question,
                              widget.value,
                              option,
                              colors,
                            ),
                          if (widget.question.allowCustomAnswer)
                            _AddChoiceButton(
                              enabled: widget.enabled,
                              onTap: _addCustomChoice,
                              colors: colors,
                            ),
                        ],
                      ),
              ),
            ),
    );
  }

  Widget _buildTextAnswer(HuahuoV3ThemeTokens colors) {
    final voice = widget.voiceController.state;
    final voiceEngaged =
        _ownsVoiceCapture && (voice.isBusy || voice.isCaptureActive);
    return SizedBox(
      height: 166,
      child: Stack(
        children: [
          Positioned.fill(
            child: TextFormField(
              controller: _textController,
              contextMenuBuilder: V3TextEditing.buildContextMenu,
              enabled: widget.enabled,
              expands: true,
              maxLines: null,
              minLines: null,
              maxLength: widget.question.maximumLength,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(color: colors.ink, fontSize: 14, height: 1.5),
              onChanged: widget.onChanged,
              decoration: InputDecoration(
                hintText: '不用写标准答案，想到什么先写什么',
                counterText: '',
                filled: true,
                fillColor: colors.surface,
                contentPadding: const EdgeInsets.fromLTRB(14, 14, 54, 42),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.line),
                ),
              ),
            ),
          ),
          Positioned(
            left: 14,
            bottom: 12,
            child: Text(
              '${_textController.text.length}/${widget.question.maximumLength}',
              style: TextStyle(color: colors.muted, fontSize: 11),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 6,
            child: Tooltip(
              message: voiceEngaged ? '停止语音输入' : '语音输入',
              child: IconButton(
                key: ValueKey('onboarding-voice-input-${widget.question.id}'),
                onPressed: widget.enabled ? _toggleVoiceTranscription : null,
                icon: Icon(
                  voiceEngaged ? Icons.stop_circle_rounded : Icons.mic_rounded,
                  color: voiceEngaged ? colors.accent : colors.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<String> get _visibleChoices {
    final custom = <String>[];
    final value = widget.value;
    if (value is String && !widget.question.options.contains(value)) {
      custom.add(value);
    } else if (value is List<String>) {
      custom.addAll(
        value.where((answer) => !widget.question.options.contains(answer)),
      );
    }
    return <String>[...widget.question.options, ...custom];
  }

  Future<void> _addCustomChoice() async {
    if (!widget.enabled) return;
    final value = await showV3TextInputDialog(
      context: context,
      title: '添加自定义选项',
      initialValue: '',
      label: '请输入你的答案',
      confirmLabel: '添加',
      maxLength: widget.question.maximumLength,
      inputKey: ValueKey('onboarding-custom-${widget.question.id}'),
      validator: (answer) => answer.trim().isEmpty ? '请输入内容' : null,
    );
    if (!mounted || value == null) return;
    final custom = value.trim();
    if (widget.question.input == OnboardingIntakeInput.singleChoice) {
      widget.onChanged(custom);
      return;
    }
    final selected = widget.value is List<String>
        ? List<String>.from(widget.value! as List<String>)
        : <String>[];
    if (!selected.contains(custom) && selected.length >= 8) {
      showV3Snack(context, '最多选择 8 项');
      return;
    }
    if (!selected.contains(custom)) selected.add(custom);
    widget.onChanged(selected);
  }

  Widget _buildChoice(
    OnboardingIntakeQuestion question,
    Object? value,
    String option,
    HuahuoV3ThemeTokens colors,
  ) {
    return _ChoiceButton(
      key: ValueKey<String>('onboarding-option-${question.id}-$option'),
      label: option,
      selected: _isSelected(question, value, option),
      multi: question.input == OnboardingIntakeInput.multiChoice,
      enabled: widget.enabled,
      onTap: () => widget.onChanged(_nextValue(question, value, option)),
      colors: colors,
    );
  }

  bool _isSelected(
    OnboardingIntakeQuestion question,
    Object? value,
    String option,
  ) {
    return question.input == OnboardingIntakeInput.multiChoice
        ? value is List<String> && value.contains(option)
        : value == option;
  }

  Object _nextValue(
    OnboardingIntakeQuestion question,
    Object? value,
    String option,
  ) {
    if (question.input == OnboardingIntakeInput.singleChoice) return option;
    final selected = value is List<String>
        ? List<String>.from(value)
        : <String>[];
    return selected.contains(option)
        ? (selected..remove(option))
        : (selected..add(option));
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    super.key,
    required this.label,
    required this.selected,
    required this.multi,
    required this.enabled,
    required this.onTap,
    required this.colors,
  });

  final String label;
  final bool selected;
  final bool multi;
  final bool enabled;
  final VoidCallback onTap;
  final HuahuoV3ThemeTokens colors;

  @override
  Widget build(BuildContext context) {
    final background = multi
        ? selected
              ? const Color(0xFFFFF7E8)
              : colors.surfaceMuted
        : selected
        ? const Color(0xFFF0F6F3)
        : colors.surface;
    final border = multi
        ? Colors.transparent
        : selected
        ? colors.primary.withValues(alpha: .45)
        : colors.line;
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: 36,
            maxWidth: MediaQuery.sizeOf(context).width - 80,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: multi ? 12 : 19,
              vertical: 8,
            ),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddChoiceButton extends StatelessWidget {
  const _AddChoiceButton({
    required this.enabled,
    required this.onTap,
    required this.colors,
  });

  final bool enabled;
  final VoidCallback onTap;
  final HuahuoV3ThemeTokens colors;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '添加自定义选项',
      child: SizedBox.square(
        dimension: 36,
        child: IconButton.outlined(
          key: const ValueKey('onboarding-add-custom-option'),
          padding: EdgeInsets.zero,
          onPressed: enabled ? onTap : null,
          icon: const Icon(Icons.add_rounded, size: 20),
          style: IconButton.styleFrom(
            foregroundColor: colors.primary,
            side: BorderSide(color: colors.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Row(
      key: const ValueKey('onboarding-error'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, color: colors.danger),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: colors.danger, height: 1.45),
          ),
        ),
      ],
    );
  }
}

String _onboardingError(String code) => switch (code) {
  'ONBOARDING_REQUIRED_FIELDS_INVALID' => '请先完成当前问题。',
  'ONBOARDING_AGENT_PROMPT_INVALID' => '问卷内容不完整，请检查后重试。',
  'ONBOARDING_AGENT_REPORT_UNAVAILABLE' => '报告暂未生成，请稍后重试。',
  'ONBOARDING_AGENT_RECEIPT_INVALID' => '服务端未确认定位任务，请稍后重试。',
  'ONBOARDING_AGENT_SEND_FAILED' ||
  'CHAT_AGENT_CATALOG_UNAVAILABLE' ||
  'AGENT_PROFILE_NOT_SELECTABLE' => '基础定位服务暂不可用，请稍后重试。',
  'CHAT_AGENT_RUN_RECEIPT_REQUIRED' => '服务端未确认定位任务，请稍后重试。',
  'ONBOARDING_AGENT_RUN_TIMEOUT' => '定位报告生成超时，请稍后重试。',
  'ONBOARDING_AGENT_RUN_CANCELLED' => '定位任务已取消。',
  'ONBOARDING_AGENT_RUN_ORPHANED' => '定位任务运行异常，请稍后重试。',
  'ONBOARDING_AGENT_RUN_DEGRADED' ||
  'ONBOARDING_AGENT_RUN_SYSTEM_FALLBACK' => '定位服务未生成正式报告，请稍后重试。',
  'AGENT_PLAN_INVALID' => '基础定位服务正在调整，请稍后重试。',
  'ONBOARDING_COMPLETION_INVALID' => '报告已生成，但定位状态暂未完成，请稍后重试。',
  'ONBOARDING_CONTENT_LINE_CREATE_FAILED' => '报告已生成，但保存定位失败，请重试。',
  'ONBOARDING_PROGRESS_SAVE_FAILED' => '当前进度暂时无法保存，请稍后重试。',
  _ => '基础定位失败：$code',
};
