import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/auth/session_store.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_brand_mark.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import 'legal_document_page.dart';

const _authFontFamily = 'PingFang SC';
const _authFontFallback = <String>['Helvetica Neue', 'Noto Sans SC', 'Roboto'];

TextStyle _brandTitleStyle(HuahuoV3ThemeTokens colors) => TextStyle(
  color: colors.ink,
  fontFamily: _authFontFamily,
  fontFamilyFallback: _authFontFallback,
  fontSize: HuahuoV3Theme.pageTitleSize,
  height: 1.1,
  fontWeight: FontWeight.w700,
  letterSpacing: 0,
);

TextStyle _subtitleStyle(HuahuoV3ThemeTokens colors) => TextStyle(
  color: colors.muted,
  fontFamily: _authFontFamily,
  fontFamilyFallback: _authFontFallback,
  fontSize: 15,
  height: 1.35,
  fontWeight: FontWeight.w400,
  letterSpacing: 0,
);

TextStyle _footerStyle(HuahuoV3ThemeTokens colors) => TextStyle(
  color: colors.muted,
  fontFamily: _authFontFamily,
  fontFamilyFallback: _authFontFallback,
  fontSize: 12.5,
  height: 1.3,
  fontWeight: FontWeight.w400,
  letterSpacing: 0,
);

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  late final TextEditingController _phoneController;
  late final TextEditingController _codeController;
  Timer? _cooldownTicker;

  @override
  void initState() {
    super.initState();
    _phoneController = TextEditingController();
    _codeController = TextEditingController();
    _phoneController.addListener(_syncPhoneDraft);
    _codeController.addListener(_syncCodeDraft);
  }

  @override
  void dispose() {
    _phoneController.removeListener(_syncPhoneDraft);
    _codeController.removeListener(_syncCodeDraft);
    _cooldownTicker?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _syncPhoneDraft() {
    ref.read(authControllerProvider.notifier).setPhone(_phoneController.text);
  }

  void _syncCodeDraft() {
    ref.read(authControllerProvider.notifier).setCode(_codeController.text);
  }

  void _setCooldownTickerActive(bool active) {
    if (!active) {
      _cooldownTicker?.cancel();
      _cooldownTicker = null;
      return;
    }
    _cooldownTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      final cooldown = ref
          .read(authControllerProvider.notifier)
          .state
          .cooldownSecondsRemaining(DateTime.now().toUtc());
      if (cooldown <= 0) {
        _cooldownTicker?.cancel();
        _cooldownTicker = null;
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(authControllerProvider);
    final session = ref.watch(sessionStoreProvider).state;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final colors = HuahuoV3Theme.tokensOf(context);
        final state = controller.state;
        final visibleErrorCode =
            state.lastErrorCode ?? _sessionErrorCode(session);
        final now = DateTime.now().toUtc();
        final cooldown = state.cooldownSecondsRemaining(now);
        _setCooldownTickerActive(cooldown > 0);
        final isExpiredSession = _isExpiredSessionCode(visibleErrorCode);

        return Scaffold(
          backgroundColor: colors.canvas,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final topPadding = constraints.maxHeight > 780 ? 18.0 : 10.0;
                const bottomPadding = 10.0;

                return SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.manual,
                  padding: EdgeInsets.fromLTRB(
                    24,
                    topPadding,
                    24,
                    bottomPadding,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(
                        0,
                        constraints.maxHeight - topPadding - bottomPadding,
                      ),
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const V3BrandMark(),
                          const SizedBox(height: 12),
                          Text(
                            '无限花火',
                            textAlign: TextAlign.center,
                            style: _brandTitleStyle(colors),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            isExpiredSession
                                ? '登录状态已失效，请重新登录。'
                                : '登录后开始沉淀你的内容资产',
                            textAlign: TextAlign.center,
                            style: _subtitleStyle(colors),
                          ),
                          const SizedBox(height: 26),
                          _LoginCard(
                            phoneController: _phoneController,
                            codeController: _codeController,
                            phoneEnabled: !state.isCommittingLogin,
                            codeEnabled: !state.isCommittingLogin,
                            sendEnabled:
                                !state.isSendingCode &&
                                !state.isLoggingIn &&
                                cooldown <= 0,
                            loginEnabled: !state.isLoggingIn,
                            agreementEnabled: !state.isCommittingLogin,
                            agreementAccepted: state.agreementAccepted,
                            isSendingCode: state.isSendingCode,
                            isLoggingIn: state.isLoggingIn,
                            cooldown: cooldown,
                            errorCode: visibleErrorCode,
                            onSendCode: () {
                              _syncPhoneDraft();
                              ref
                                  .read(authControllerProvider.notifier)
                                  .sendSmsCode();
                            },
                            onAgreementChanged: (value) => ref
                                .read(authControllerProvider.notifier)
                                .setAgreementAccepted(value),
                            onLogin:
                                huahuoV3UiEnabled &&
                                    huahuoV3DemoAuthBypassEnabled
                                ? () => context.go('/v3/workbench')
                                : () {
                                    _syncPhoneDraft();
                                    _syncCodeDraft();
                                    ref
                                        .read(authControllerProvider.notifier)
                                        .login();
                                  },
                          ),
                          const SizedBox(height: 20),
                          const _PublicHelpEntries(),
                          const Spacer(),
                          const SizedBox(height: 18),
                          Text(
                            '登录即表示同意相关协议内容',
                            textAlign: TextAlign.center,
                            style: _footerStyle(colors),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.phoneController,
    required this.codeController,
    required this.phoneEnabled,
    required this.codeEnabled,
    required this.sendEnabled,
    required this.loginEnabled,
    required this.agreementEnabled,
    required this.agreementAccepted,
    required this.isSendingCode,
    required this.isLoggingIn,
    required this.cooldown,
    required this.errorCode,
    required this.onSendCode,
    required this.onAgreementChanged,
    required this.onLogin,
  });

  final TextEditingController phoneController;
  final TextEditingController codeController;
  final bool phoneEnabled;
  final bool codeEnabled;
  final bool sendEnabled;
  final bool loginEnabled;
  final bool agreementEnabled;
  final bool agreementAccepted;
  final bool isSendingCode;
  final bool isLoggingIn;
  final int cooldown;
  final String? errorCode;
  final VoidCallback onSendCode;
  final ValueChanged<bool> onAgreementChanged;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      key: const ValueKey<String>('auth-login-card'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: colors.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 336),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _FieldLabel('手机号'),
              const SizedBox(height: 8),
              _PhoneInputField(
                controller: phoneController,
                enabled: phoneEnabled,
              ),
              const SizedBox(height: 20),
              const _FieldLabel('验证码'),
              const SizedBox(height: 8),
              _CodeInputField(
                controller: codeController,
                enabled: codeEnabled,
                sendEnabled: sendEnabled,
                isSendingCode: isSendingCode,
                cooldown: cooldown,
                onSendCode: onSendCode,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 18,
                child: _AgreementRow(
                  enabled: agreementEnabled,
                  accepted: agreementAccepted,
                  onChanged: onAgreementChanged,
                ),
              ),
              const SizedBox(height: 12),
              _PrimaryLoginButton(
                enabled: loginEnabled,
                loading: isLoggingIn,
                onPressed: onLogin,
              ),
              if (errorCode != null) ...[
                const SizedBox(height: 14),
                _AuthErrorPanel(errorCode: errorCode!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 24,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(
            color: colors.ink,
            fontFamily: _authFontFamily,
            fontFamilyFallback: _authFontFallback,
            fontSize: 15,
            height: 1.2,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _PhoneInputField extends StatelessWidget {
  const _PhoneInputField({required this.controller, required this.enabled});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return _InputShell(
      shellKey: const ValueKey<String>('auth-phone-shell'),
      enabled: enabled,
      child: Row(
        children: [
          Text(
            '+86',
            style: TextStyle(
              color: colors.ink,
              fontFamily: _authFontFamily,
              fontFamilyFallback: _authFontFallback,
              fontSize: 16,
              height: 1.2,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: colors.muted,
          ),
          const SizedBox(width: 14),
          SizedBox(
            height: 24,
            child: VerticalDivider(width: 1, color: colors.line),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: V3CenteredInput(
              minHeight: 52,
              enabled: enabled,
              builder: (focusNode) => TextField(
                key: const ValueKey<String>('auth-phone-input'),
                controller: controller,
                focusNode: focusNode,
                contextMenuBuilder: V3TextEditing.buildContextMenu,
                enabled: enabled,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: _inputTextStyle(colors),
                strutStyle: const StrutStyle(
                  fontFamily: _authFontFamily,
                  fontFamilyFallback: _authFontFallback,
                  fontSize: 16,
                  height: 1.2,
                  forceStrutHeight: true,
                ),
                decoration: _inputDecoration('请输入手机号', colors),
                textAlignVertical: TextAlignVertical.center,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeInputField extends StatelessWidget {
  const _CodeInputField({
    required this.controller,
    required this.enabled,
    required this.sendEnabled,
    required this.isSendingCode,
    required this.cooldown,
    required this.onSendCode,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool sendEnabled;
  final bool isSendingCode;
  final int cooldown;
  final VoidCallback onSendCode;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Row(
      children: [
        Expanded(
          child: _InputShell(
            shellKey: const ValueKey<String>('auth-code-shell'),
            enabled: enabled,
            child: V3CenteredInput(
              minHeight: 52,
              enabled: enabled,
              builder: (focusNode) => TextField(
                key: const ValueKey<String>('auth-code-input'),
                controller: controller,
                focusNode: focusNode,
                contextMenuBuilder: V3TextEditing.buildContextMenu,
                enabled: enabled,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: _inputTextStyle(colors),
                strutStyle: const StrutStyle(
                  fontFamily: _authFontFamily,
                  fontFamilyFallback: _authFontFallback,
                  fontSize: 16,
                  height: 1.2,
                  forceStrutHeight: true,
                ),
                decoration: _inputDecoration('请输入验证码', colors),
                textAlignVertical: TextAlignVertical.center,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        _CodeSendButton(
          enabled: sendEnabled,
          loading: isSendingCode,
          label: cooldown > 0 ? '${cooldown}s' : '获取验证码',
          onPressed: onSendCode,
        ),
      ],
    );
  }
}

class _InputShell extends StatelessWidget {
  const _InputShell({
    required this.enabled,
    required this.child,
    this.shellKey,
  });

  final bool enabled;
  final Widget child;
  final Key? shellKey;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return AnimatedOpacity(
      duration: V3MotionTokens.resolve(context, V3MotionTokens.quick),
      opacity: enabled ? 1 : 0.72,
      child: DecoratedBox(
        key: shellKey,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.line),
        ),
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _CodeSendButton extends StatelessWidget {
  const _CodeSendButton({
    required this.enabled,
    required this.loading,
    required this.label,
    required this.onPressed,
  });

  final bool enabled;
  final bool loading;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final foreground = enabled ? colors.ink : colors.muted;
    return Semantics(
      key: const ValueKey<String>('auth-send-code'),
      button: true,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onPressed : null,
        child: AnimatedOpacity(
          duration: V3MotionTokens.resolve(context, V3MotionTokens.compact),
          opacity: enabled ? 1 : 0.66,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.line),
            ),
            child: SizedBox(
              width: 122,
              height: 52,
              child: Center(
                child: loading
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: foreground,
                        ),
                      )
                    : Text(
                        label,
                        style: TextStyle(
                          color: foreground,
                          fontFamily: _authFontFamily,
                          fontFamilyFallback: _authFontFallback,
                          fontSize: 16,
                          height: 1.2,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AgreementRow extends StatelessWidget {
  const _AgreementRow({
    required this.enabled,
    required this.accepted,
    required this.onChanged,
  });

  final bool enabled;
  final bool accepted;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final textStyle = TextStyle(
      color: colors.muted,
      fontFamily: _authFontFamily,
      fontFamilyFallback: _authFontFallback,
      fontSize: 12,
      height: 4 / 3,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    );
    return Semantics(
      key: const ValueKey<String>('auth-agreement'),
      checked: accepted,
      enabled: enabled,
      label: '我已阅读并同意《用户协议》与《隐私政策》',
      onTap: enabled ? () => onChanged(!accepted) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged(!accepted) : null,
        child: Padding(
          padding: EdgeInsets.zero,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: V3MotionTokens.resolve(
                  context,
                  V3MotionTokens.compact,
                ),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: accepted ? colors.primary : colors.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: accepted ? colors.primary : colors.line,
                    width: 1.3,
                  ),
                ),
                child: accepted
                    ? Icon(
                        Icons.check_rounded,
                        color: colors.onPrimary,
                        size: 12,
                      )
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 0,
                  runSpacing: 0,
                  children: [
                    Text('我已阅读并同意', style: textStyle),
                    _InlineLegalDocumentLink(
                      key: const ValueKey('auth-user-agreement-link'),
                      label: '《用户协议》',
                      style: textStyle,
                      onTap: () =>
                          context.push(LegalDocumentKind.userAgreement.route),
                    ),
                    Text('与', style: textStyle),
                    _InlineLegalDocumentLink(
                      key: const ValueKey('auth-privacy-policy-link'),
                      label: '《隐私政策》',
                      style: textStyle,
                      onTap: () =>
                          context.push(LegalDocumentKind.privacyPolicy.route),
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

class _InlineLegalDocumentLink extends StatelessWidget {
  const _InlineLegalDocumentLink({
    required this.label,
    required this.style,
    required this.onTap,
    super.key,
  });

  final String label;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Text(label, style: style.copyWith(fontWeight: FontWeight.w500)),
      ),
    );
  }
}

class _PrimaryLoginButton extends StatelessWidget {
  const _PrimaryLoginButton({
    required this.enabled,
    required this.loading,
    required this.onPressed,
  });

  final bool enabled;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      key: const ValueKey<String>('auth-login'),
      button: true,
      enabled: enabled,
      label: '登录 / 注册',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onPressed : null,
        child: AnimatedContainer(
          duration: V3MotionTokens.resolve(context, V3MotionTokens.compact),
          height: 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: enabled ? colors.primary : colors.muted,
            borderRadius: BorderRadius.circular(12),
          ),
          child: loading
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.onPrimary,
                  ),
                )
              : Text(
                  '登录 / 注册',
                  style: TextStyle(
                    color: colors.onPrimary,
                    fontFamily: _authFontFamily,
                    fontFamilyFallback: _authFontFallback,
                    fontSize: 16,
                    height: 1.1,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
        ),
      ),
    );
  }
}

class _PublicHelpEntries extends StatelessWidget {
  const _PublicHelpEntries();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(
          child: _PublicHelpEntry(
            key: ValueKey('auth-help-center'),
            icon: Icons.help_outline_rounded,
            label: '帮助中心',
            route: '/help',
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: _PublicHelpEntry(
            key: ValueKey('auth-customer-service'),
            icon: Icons.headset_mic_outlined,
            label: '联系客服',
            route: '/help/customer-service',
          ),
        ),
      ],
    );
  }
}

class _PublicHelpEntry extends StatelessWidget {
  const _PublicHelpEntry({
    required this.icon,
    required this.label,
    required this.route,
    super.key,
  });

  final IconData icon;
  final String label;
  final String route;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: colors.line),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => context.push(route),
          child: SizedBox(
            height: 50,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: colors.ink),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontFamily: _authFontFamily,
                        fontFamilyFallback: _authFontFallback,
                        fontSize: 13,
                        height: 16 / 13,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthErrorPanel extends StatelessWidget {
  const _AuthErrorPanel({required this.errorCode});

  final String errorCode;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.danger.withValues(alpha: .35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: colors.danger, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _messageForError(errorCode),
                style: TextStyle(
                  color: colors.danger,
                  fontFamily: _authFontFamily,
                  fontFamilyFallback: _authFontFallback,
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

TextStyle _inputTextStyle(HuahuoV3ThemeTokens colors) => TextStyle(
  color: colors.ink,
  fontFamily: _authFontFamily,
  fontFamilyFallback: _authFontFallback,
  fontSize: 16,
  height: 1.2,
  fontWeight: FontWeight.w400,
  letterSpacing: 0,
);

InputDecoration _inputDecoration(String hint, HuahuoV3ThemeTokens colors) {
  return V3TextEditing.inlineDecoration.copyWith(
    hintText: hint,
    hintStyle: TextStyle(
      color: colors.muted,
      fontFamily: _authFontFamily,
      fontFamilyFallback: _authFontFallback,
      fontSize: 16,
      height: 1.2,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    counterText: '',
  );
}

String? _sessionErrorCode(SessionState session) {
  if (session.authState != SessionAuthState.expired) {
    return null;
  }
  return session.lastAuthErrorCode ?? 'AUTH_SESSION_EXPIRED';
}

bool _isExpiredSessionCode(String? code) {
  return code == 'TOKEN_EXPIRED' ||
      code == 'AUTH_SESSION_EXPIRED' ||
      code == 'UNAUTHORIZED';
}

String _messageForError(String code) {
  switch (code) {
    case 'AUTH_PHONE_INVALID':
    case 'PHONE_INVALID':
      return '请输入有效手机号。';
    case 'AUTH_SMS_REQUEST_MISSING':
      return '请先获取验证码。';
    case 'SMS_REQUEST_ID_MISSING':
      return '服务端未返回验证码票据，请重新获取验证码。';
    case 'AUTH_SMS_CODE_INVALID':
      return '请输入 6 位验证码。';
    case 'SMS_CODE_INVALID':
      return '验证码不正确或已失效，请重新获取后再试。';
    case 'SMS_CODE_EXPIRED':
      return '验证码已过期，请重新获取。';
    case 'AUTH_AGREEMENT_REQUIRED':
    case 'AGREEMENT_REQUIRED':
      return '请先同意用户协议和隐私政策。';
    case 'AUTH_SMS_COOLDOWN':
    case 'SMS_RATE_LIMITED':
    case 'RATE_LIMITED':
      return '验证码倒计时结束后可重新获取。';
    case 'SECURE_TOKEN_CLEAR_FAILED':
      return '登录凭证清理失败，请重试或重新登录。';
    case 'SECURE_TOKEN_WRITE_FAILED':
      return '登录凭证保存失败，请重试。';
    case 'TOKEN_EXPIRED':
    case 'AUTH_SESSION_EXPIRED':
    case 'UNAUTHORIZED':
      return '登录状态已失效，请重新登录。';
    case 'ACCOUNT_BLOCKED':
      return '账号状态异常，请联系运营。';
    case 'WORKSPACE_NOT_READY':
    case 'WORKSPACE_SYNC_FAILED':
    case 'WORKSPACE_CREATE_FAILED':
      return '个人空间正在恢复，请稍后刷新后重试。';
    case 'SMS_PROVIDER_FAILED':
      return '验证码发送失败，若持续失败请联系运营。';
    case 'SMS_PROVIDER_REJECTED':
      return '短信服务拒绝了本次请求，请联系运营检查签名、模板和账号资质。';
    case 'SMS_PROVIDER_NOT_CONFIGURED':
      return '短信服务暂未配置，请联系运营。';
    case 'API_BASE_URL_UNCONFIGURED':
      return '登录服务未配置，请联系开发人员。';
    case 'AUTH_SMS_REQUEST_FAILED':
      return '验证码请求失败，请重试。';
    case 'AUTH_SMS_IN_PROGRESS':
      return '验证码请求中，请稍候。';
    case 'AUTH_LOGIN_REQUEST_FAILED':
      return '登录请求失败，请重试。';
    case 'AUTH_LOGIN_IN_PROGRESS':
      return '正在登录，请稍候。';
    default:
      return '登录失败，请稍后重试。';
  }
}
