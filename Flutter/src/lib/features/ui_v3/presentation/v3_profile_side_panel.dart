import 'package:huahuoai_app/app/di/account_usage_providers.dart';
// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/billing_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/bootstrap/asset_projection_cache_scope.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/api/scoped_read_cache.dart';
import '../../../core/diagnostics/diagnostic_export_service.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../notifications/application/push_registration_controller.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../settings/widgets/v3_appearance_settings_card.dart';
import '../../settings/application/settings_controller.dart';
import '../application/deep_positioning_controller.dart';
import '../application/knowledge_library_controller.dart';
import '../application/note_metrics_controller.dart';
import '../application/profile_capability_controller.dart';
import '../application/user_profile_controller.dart';
import '../domain/profile_capability_models.dart';
import '../domain/profile_workspace_models.dart';
import 'v3_account_profile_page.dart';
import 'v3_help_center_page.dart';
import 'v3_recording_card_control_page.dart';
import '../../billing/widgets/v3_membership_page.dart';

export 'v3_profile_home_page.dart' show V3ProfileHomePage;

Future<void> showV3ProfileSidePanel(BuildContext context) async {
  final router = GoRouter.of(context);
  while (true) {
    if (!context.mounted) return;
    final colors = HuahuoV3Theme.tokensOf(context);
    final destination = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭我的面板',
      barrierColor: colors.ink.withValues(alpha: .08),
      transitionDuration: V3MotionTokens.resolve(
        context,
        V3MotionTokens.panelRoute,
      ),
      pageBuilder: (context, animation, secondaryAnimation) =>
          const SizedBox.shrink(),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionalTranslation(
              translation: Offset(-1 + curved.value, 0),
              child: GestureDetector(
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -260) Navigator.of(context).pop();
                },
                child: const V3GlassHomeScope(
                  enabled: false,
                  child: _ProfilePanel(
                    key: ValueKey<String>('v3-profile-side-panel'),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (destination == null || !context.mounted) return;
    if (!await visitChildRoute(router, destination)) return;
  }
}

class V3ProfilePlaceholderPage extends ConsumerWidget {
  const V3ProfilePlaceholderPage({required this.section, super.key});

  final String section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HuahuoV3Theme.tokensOf(context);
    if (section == '设置' || section == '诊断') {
      return _V3SettingsPage(showDiagnosticsFirst: section == '诊断');
    }
    if (section == '外观与显示') {
      return const _V3AppearancePage();
    }
    if (section == '日报提醒') {
      return const _V3ReminderPage();
    }
    if (section == '权限隐私' || section == '权限管理') {
      return const _V3PermissionsPage();
    }
    if (section == '版本更新') {
      return const _V3VersionPage();
    }
    if (section == '账号与安全') {
      return const _V3AccountSecurityPage();
    }
    if (section == '帮助与反馈') {
      return const _V3HelpFeedbackPage();
    }
    if (section == '会员充值') {
      return V3MembershipPage(
        billingController: billingControllerProvider,
        accountUsageController: accountUsageControllerProvider,
      );
    }
    final detail = switch (section) {
      '观点库' => '已沉淀的观点会在这里按主题、来源与时间检索。',
      '成长记录' => '成长记录服务尚未在当前后端契约中开放。',
      '帮助与反馈' => '帮助与反馈提交接口尚未在当前后端契约中开放。',
      _ => '$section 暂无可用服务。',
    };
    return V3PageScaffold(
      title: section,
      children: [
        V3Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                detail,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.45,
                  fontWeight: FontWeight.w400,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 18),
              V3OutlineButton(
                label: '完成',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _V3AccountSecurityPage extends ConsumerStatefulWidget {
  const _V3AccountSecurityPage();

  @override
  ConsumerState<_V3AccountSecurityPage> createState() =>
      _V3AccountSecurityPageState();
}

class _V3AccountSecurityPageState
    extends ConsumerState<_V3AccountSecurityPage> {
  late final ProfileAccountSecurityController _controller;
  late ProfileAccountSecuritySnapshot _security;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(profileAccountSecurityControllerProvider);
    _security = _controller.snapshot;
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final session = ref.watch(sessionStoreProvider).state;
    final user = session.user;
    return V3PageScaffold(
      title: '账号与安全',
      children: [
        V3Card(
          child: Column(
            children: [
              _SecurityActionRow(
                key: const ValueKey('account-security-phone'),
                icon: Icons.phone_iphone_rounded,
                label: '手机号换绑',
                value:
                    _security.maskedPhone ?? user?.maskedPhoneNumber ?? '未绑定',
                onTap: _changePhone,
              ),
              _SecurityActionRow(
                key: const ValueKey('account-security-cancel'),
                icon: Icons.delete_forever_outlined,
                label: '注销账号',
                value: '不可恢复',
                onTap: _showAccountCancellationUnavailable,
                destructive: true,
                last: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '手机号换绑和账号注销需在账号服务接入后提交。',
          style: TextStyle(color: colors.muted, fontSize: 14, height: 1.45),
        ),
      ],
    );
  }

  Future<void> _changePhone() async {
    final value = await showV3TextInputDialog(
      context: context,
      title: '手机号换绑',
      initialValue: '',
      label: '新手机号',
      maxLength: 11,
      inputKey: const ValueKey('account-security-phone-input'),
      validator: (value) =>
          RegExp(r'^1\d{10}$').hasMatch(value) ? null : '请输入 11 位手机号',
    );
    if (!mounted || value == null) return;
    final result = await _controller.rebindPhone(value);
    if (!mounted || !_applySecurityResult(result)) return;
    showV3Snack(context, '手机号已换绑');
  }

  Future<void> _showAccountCancellationUnavailable() {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final colors = HuahuoV3Theme.tokensOf(dialogContext);
        return V3GlassDialogFrame(
          title: '账号注销服务尚未接入',
          content: Text(
            '账号注销会永久删除与账号关联的云端内容，且无法恢复。\n\n'
            '当前服务端尚未提供账号注销接口，未向服务端发起请求；账号、登录状态和本地凭据均保持不变。',
            style: TextStyle(color: colors.text, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  bool _applySecurityResult(
    ProfileCapabilityResult<ProfileAccountSecuritySnapshot> result,
  ) {
    final snapshot = result.data;
    if (!result.ok || snapshot == null) {
      showV3Snack(
        context,
        '操作失败：${result.errorCode ?? 'PROFILE_SECURITY_FAILED'}',
      );
      return false;
    }
    setState(() => _security = snapshot);
    return true;
  }
}

class _SecurityActionRow extends StatelessWidget {
  const _SecurityActionRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.last = false,
    this.destructive = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool last;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final foreground = destructive ? colors.danger : colors.ink;
    final secondary = destructive ? colors.danger : colors.muted;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: colors.line)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: secondary, fontSize: 13),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: secondary),
          ],
        ),
      ),
    );
  }
}

class _V3HelpFeedbackPage extends StatelessWidget {
  const _V3HelpFeedbackPage();

  @override
  Widget build(BuildContext context) => const V3HelpCenterPage();
}

class _V3SettingsPage extends ConsumerStatefulWidget {
  const _V3SettingsPage({required this.showDiagnosticsFirst});

  final bool showDiagnosticsFirst;

  @override
  ConsumerState<_V3SettingsPage> createState() => _V3SettingsPageState();
}

class _V3SettingsPageState extends ConsumerState<_V3SettingsPage> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() => ref.read(settingsControllerProvider).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsControllerProvider).state;
    if (widget.showDiagnosticsFirst) {
      return _V3DiagnosticsPage(state: state);
    }
    return V3PageScaffold(
      title: '设置',
      children: <Widget>[
        const _M06SettingsSectionLabel('账户与安全'),
        _M06SettingsRow(
          key: const ValueKey('settings-account-security'),
          icon: Icons.person_outline_rounded,
          title: '账号与安全',
          value: '手机号绑定',
          onTap: () =>
              context.push('/v3/profile/${Uri.encodeComponent('账号与安全')}'),
        ),
        _M06SettingsRow(
          key: const ValueKey('settings-permission-privacy'),
          icon: Icons.privacy_tip_outlined,
          title: '权限隐私',
          value: _permissionSummaryLabel(state),
          onTap: () =>
              context.push('/v3/profile/${Uri.encodeComponent('权限隐私')}'),
        ),
        const SizedBox(height: 18),
        const _M06SettingsSectionLabel('帮助与反馈'),
        _M06SettingsRow(
          key: const ValueKey('settings-help'),
          icon: Icons.help_outline_rounded,
          title: '使用帮助',
          onTap: () =>
              context.push('/v3/profile/${Uri.encodeComponent('帮助与反馈')}'),
        ),
        _M06SettingsRow(
          key: const ValueKey('settings-feedback'),
          icon: Icons.chat_bubble_outline_rounded,
          title: '使用反馈',
          onTap: () =>
              context.push('/v3/profile/${Uri.encodeComponent('帮助与反馈')}'),
        ),
        const SizedBox(height: 18),
        const _M06SettingsSectionLabel('外观与显示'),
        const V3AppearanceSettingsCard(),
        const SizedBox(height: 18),
        const _M06SettingsSectionLabel('版本与支持'),
        _M06SettingsRow(
          key: const ValueKey('settings-version'),
          icon: Icons.system_update_alt_rounded,
          title: '版本更新',
          value: '检查更新',
          onTap: () =>
              context.push('/v3/profile/${Uri.encodeComponent('版本更新')}'),
        ),
        _M06SettingsRow(
          key: const ValueKey('settings-about'),
          icon: Icons.info_outline_rounded,
          title: '关于我们',
          onTap: () => showAboutDialog(
            context: context,
            applicationName: '花火 AI',
            applicationLegalese: '用 AI 连接灵感、知识与创作。',
          ),
        ),
      ],
    );
  }
}

class _V3DiagnosticsPage extends ConsumerWidget {
  const _V3DiagnosticsPage({required this.state});

  final SettingsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final export = state.diagnosticExportState;
    final exporting = export.status == DiagnosticExportStatus.exporting;
    return V3PageScaffold(
      title: '诊断',
      children: [
        V3Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                diagnosticPrivacyNotice,
                style: TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('settings-diagnostics-export'),
                onPressed: exporting
                    ? null
                    : () => _copyDiagnosticSnapshot(context, ref),
                icon: exporting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.copy_all_outlined),
                label: Text(exporting ? '正在生成' : '复制诊断快照'),
              ),
              if (export.package != null) ...[
                const SizedBox(height: 10),
                Text(
                  '最近快照包含 ${export.package!.eventCount} 条诊断事件',
                  style: TextStyle(
                    color: HuahuoV3Theme.tokensOf(context).muted,
                    fontSize: 12,
                  ),
                ),
              ],
              if (export.status == DiagnosticExportStatus.failed) ...[
                const SizedBox(height: 10),
                Text(
                  '诊断快照生成失败，请重试',
                  style: TextStyle(
                    color: HuahuoV3Theme.tokensOf(context).danger,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _copyDiagnosticSnapshot(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = ref.read(settingsControllerProvider);
  await controller.exportDiagnostics();
  final package = controller.state.diagnosticExportState.package;
  if (!context.mounted || package == null) return;
  await V3TextEditing.copy(context, package.jsonText);
}

class _M06SettingsSectionLabel extends StatelessWidget {
  const _M06SettingsSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      label,
      style: TextStyle(
        color: HuahuoV3Theme.tokensOf(context).muted,
        fontSize: 11,
      ),
    ),
  );
}

class _M06SettingsRow extends StatelessWidget {
  const _M06SettingsRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.value,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 54,
        child: Row(
          children: [
            Icon(icon, size: 19, color: colors.ink),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
            if (value != null && value!.isNotEmpty) ...[
              Text(value!, style: TextStyle(color: colors.muted, fontSize: 12)),
              const SizedBox(width: 4),
            ],
            Icon(Icons.chevron_right_rounded, color: colors.muted, size: 18),
          ],
        ),
      ),
    );
  }
}

class _V3AppearancePage extends StatelessWidget {
  const _V3AppearancePage();

  @override
  Widget build(BuildContext context) => const V3PageScaffold(
    title: '外观与显示',
    children: [V3AppearanceSettingsCard()],
  );
}

class _V3ReminderPage extends ConsumerWidget {
  const _V3ReminderPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsControllerProvider).state;
    return V3PageScaffold(
      title: '日报提醒',
      children: [
        _DailyReminderSettingsCard(state: state),
        const SizedBox(height: 24),
        const V3SectionTitle('通知预览'),
        const SizedBox(height: 8),
        V3Card(
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('你的花火日报已生成', style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 4),
              Text('回顾今天的对话与灵感记录'),
            ],
          ),
        ),
      ],
    );
  }
}

String _permissionSummaryLabel(SettingsState state) {
  if (state.permissionLoadStatus == SettingsLoadStatus.loading) {
    return '正在读取';
  }
  final applicable = state.permissionRows
      .where((row) => row.status != PlatformPermissionStatus.unavailable)
      .toList(growable: false);
  final granted = applicable
      .where((row) => row.status == PlatformPermissionStatus.granted)
      .length;
  return applicable.isEmpty ? '查看' : '已授权 $granted 项';
}

class _V3PermissionsPage extends ConsumerStatefulWidget {
  const _V3PermissionsPage();

  @override
  ConsumerState<_V3PermissionsPage> createState() => _V3PermissionsPageState();
}

class _V3PermissionsPageState extends ConsumerState<_V3PermissionsPage> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _refreshPermissions);
    Future<void>.microtask(_refreshPermissions);
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _refreshPermissions() async {
    if (!mounted) return;
    await ref.read(settingsControllerProvider).refreshPermissions();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsControllerProvider).state;
    final connectionPermissions = state.permissionRows
        .where(
          (permission) =>
              const <PlatformPermissionKind>{
                PlatformPermissionKind.bluetooth,
                PlatformPermissionKind.nearbyDevices,
                PlatformPermissionKind.localNetwork,
              }.contains(permission.kind) &&
              permission.status != PlatformPermissionStatus.unavailable,
        )
        .toList(growable: false);
    final recordingPermissions = state.permissionRows
        .where(
          (permission) =>
              const <PlatformPermissionKind>{
                PlatformPermissionKind.microphone,
                PlatformPermissionKind.camera,
                PlatformPermissionKind.mediaLibrary,
                PlatformPermissionKind.notification,
              }.contains(permission.kind) &&
              permission.status != PlatformPermissionStatus.unavailable,
        )
        .toList(growable: false);
    return V3PageScaffold(
      title: '权限隐私',
      centerTitle: true,
      topBarHeight: 54,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        if (state.permissionLoadStatus == SettingsLoadStatus.loading)
          const LinearProgressIndicator(
            key: ValueKey('permission-status-loading'),
            minHeight: 2,
          ),
        if (state.permissionLoadStatus == SettingsLoadStatus.loading)
          const SizedBox(height: 12),
        Text(
          '权限由系统统一管理，可在这里发起授权或前往系统设置调整。',
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).muted,
            fontSize: 13,
            height: 20 / 13,
          ),
        ),
        const SizedBox(height: 28),
        Text(
          '设备连接',
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).muted,
            fontSize: 12,
            height: 18 / 12,
          ),
        ),
        const SizedBox(height: 6),
        _PermissionSettingsCard(
          title: '设备连接',
          permissions: connectionPermissions,
          activePermissionKind: state.activePermissionKind,
          operationLocked:
              state.permissionOperationPhase != PermissionOperationPhase.idle,
        ),
        const SizedBox(height: 22),
        Text(
          '录音与通知',
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).muted,
            fontSize: 12,
            height: 18 / 12,
          ),
        ),
        const SizedBox(height: 6),
        _PermissionSettingsCard(
          title: '录音与通知',
          permissions: recordingPermissions,
          activePermissionKind: state.activePermissionKind,
          operationLocked:
              state.permissionOperationPhase != PermissionOperationPhase.idle,
        ),
        if (state.permissionError != null) ...[
          const SizedBox(height: 10),
          Text(
            '权限读取失败：${state.permissionError!.code}',
            style: TextStyle(
              color: HuahuoV3Theme.tokensOf(context).danger,
              fontSize: 13,
            ),
          ),
        ],
        const SizedBox(height: 26),
        Text(
          '说明',
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).ink,
            fontSize: 14,
            height: 20 / 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '麦克风权限不会替代录音卡设备录音；关闭权限只影响对应系统能力。',
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).muted,
            fontSize: 12,
            height: 18 / 12,
          ),
        ),
      ],
    );
  }
}

class _V3VersionPage extends StatelessWidget {
  const _V3VersionPage();

  @override
  Widget build(BuildContext context) =>
      const V3PageScaffold(title: '版本更新', children: [_VersionUpdateCard()]);
}

class _DailyReminderSettingsCard extends ConsumerWidget {
  const _DailyReminderSettingsCard({required this.state});

  final SettingsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(settingsControllerProvider);
    final time = TimeOfDay(
      hour: state.dailyReminderMinutes ~/ 60,
      minute: state.dailyReminderMinutes % 60,
    );
    return V3Card(
      key: const ValueKey('settings-daily-reminder'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('settings-daily-reminder-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('日报提醒'),
            subtitle: const Text('提醒偏好保存在本机，通知排程服务接入后生效'),
            value: state.dailyReminderEnabled,
            onChanged: controller.setDailyReminderEnabled,
          ),
          const SizedBox(height: 4),
          SegmentedButton<DailyReminderSchedule>(
            key: const ValueKey('settings-daily-reminder-schedule'),
            segments: <ButtonSegment<DailyReminderSchedule>>[
              for (final schedule in DailyReminderSchedule.values)
                ButtonSegment<DailyReminderSchedule>(
                  value: schedule,
                  label: Text(schedule.label),
                ),
            ],
            selected: <DailyReminderSchedule>{state.dailyReminderSchedule},
            onSelectionChanged: state.dailyReminderEnabled
                ? (selection) =>
                      controller.setDailyReminderSchedule(selection.first)
                : null,
          ),
          const SizedBox(height: 8),
          ListTile(
            key: const ValueKey('settings-daily-reminder-time'),
            contentPadding: EdgeInsets.zero,
            enabled: state.dailyReminderEnabled,
            leading: const Icon(Icons.schedule_rounded),
            title: const Text('提醒时间'),
            trailing: Text(
              MaterialLocalizations.of(context).formatTimeOfDay(time),
            ),
            onTap: state.dailyReminderEnabled
                ? () async {
                    final selected = await showTimePicker(
                      context: context,
                      initialTime: time,
                    );
                    if (selected == null) return;
                    controller.setDailyReminderMinutes(
                      selected.hour * 60 + selected.minute,
                    );
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

class _PermissionSettingsCard extends ConsumerWidget {
  const _PermissionSettingsCard({
    required this.title,
    required this.permissions,
    required this.activePermissionKind,
    required this.operationLocked,
  });

  final String title;
  final List<PlatformPermissionSummary> permissions;
  final PlatformPermissionKind? activePermissionKind;
  final bool operationLocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return V3Card(
      key: ValueKey<String>('settings-permission-group-$title'),
      padding: EdgeInsets.zero,
      glass: false,
      variant: V3CardVariant.outlined,
      radius: 12,
      child: Column(
        children: [
          for (var i = 0; i < permissions.length; i++)
            _PermissionRow(
              permission: permissions[i],
              last: i == permissions.length - 1,
              busy: activePermissionKind == permissions[i].kind,
              onTap: operationLocked
                  ? null
                  : () => _handlePermission(context, ref, permissions[i]),
            ),
        ],
      ),
    );
  }

  Future<void> _handlePermission(
    BuildContext context,
    WidgetRef ref,
    PlatformPermissionSummary permission,
  ) async {
    final controller = ref.read(settingsControllerProvider);
    if (permission.recoveryAction == PermissionRecoveryAction.request) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => V3GlassDialog(
          title: '允许使用${permission.kind.label}？',
          message: permission.impactText,
          primaryLabel: '继续授权',
          onPrimary: () => Navigator.of(dialogContext).pop(true),
        ),
      );
      if (confirmed != true || !context.mounted) return;
      await controller.requestPermission(permission.kind);
      if (!context.mounted ||
          permission.kind != PlatformPermissionKind.notification) {
        return;
      }
      final pushState = ref.read(pushRegistrationControllerProvider).state;
      switch (pushState.status) {
        case PushRegistrationStatus.unconfigured:
          showV3Snack(context, '系统推送尚未配置');
        case PushRegistrationStatus.denied:
          showV3Snack(context, '通知权限未开启');
        case PushRegistrationStatus.failed:
          showV3Snack(context, '系统推送暂时不可用，请稍后重试');
        case PushRegistrationStatus.idle ||
            PushRegistrationStatus.initializing ||
            PushRegistrationStatus.permissionRequired ||
            PushRegistrationStatus.registering ||
            PushRegistrationStatus.registered:
          break;
      }
      return;
    }
    if (permission.recoveryAction != PermissionRecoveryAction.openSettings) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '前往系统设置？',
        message: permission.impactText,
        primaryLabel: '前往设置',
        onPrimary: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed != true) return;
    await controller.openPermissionSettings(
      permission.kind,
      impactAcknowledged: true,
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.permission,
    required this.onTap,
    required this.last,
    required this.busy,
  });

  final PlatformPermissionSummary permission;
  final VoidCallback? onTap;
  final bool last;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final canRecover =
        permission.recoveryAction != PermissionRecoveryAction.none &&
        onTap != null;
    final granted = permission.status == PlatformPermissionStatus.granted;
    final statusLabel = switch (permission.status) {
      PlatformPermissionStatus.granted => '已授权',
      PlatformPermissionStatus.notDetermined => '待授权',
      PlatformPermissionStatus.denied => '重新授权',
      PlatformPermissionStatus.blocked => '去设置',
      PlatformPermissionStatus.systemManaged => '系统管理',
      PlatformPermissionStatus.unavailable => '不可用',
    };
    final statusColor = granted
        ? colors.success
        : permission.status == PlatformPermissionStatus.unavailable
        ? colors.muted
        : colors.accent;
    return InkWell(
      onTap: canRecover ? onTap : null,
      child: Container(
        constraints: const BoxConstraints(minHeight: 90),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: colors.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    permission.kind.label,
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 15,
                      height: 20 / 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    permission.impactText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.muted,
                      fontSize: 12,
                      height: 18 / 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (busy)
              const SizedBox.square(
                key: ValueKey('permission-operation-progress'),
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Container(
                constraints: const BoxConstraints(minWidth: 66),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: HuahuoV3Theme.semanticSurface(
                    statusColor,
                    colors.surface,
                    opacity: .11,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  statusLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12,
                    height: 16 / 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VersionUpdateCard extends ConsumerStatefulWidget {
  const _VersionUpdateCard();

  @override
  ConsumerState<_VersionUpdateCard> createState() => _VersionUpdateCardState();
}

class _VersionUpdateCardState extends ConsumerState<_VersionUpdateCard> {
  bool _checking = false;
  String? _status;
  bool _statusFailed = false;
  bool _statusUnavailable = false;

  ProfileVersionController get _controller =>
      ref.read(profileVersionControllerProvider);

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadInstalledVersion);
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final statusColor = _statusFailed
        ? colors.danger
        : _statusUnavailable
        ? colors.muted
        : colors.success;
    return V3Card(
      key: const ValueKey('settings-version-update'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const V3SectionTitle('版本更新'),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前版本 ${_controller.current.displayLabel}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '检查不会自动下载或安装',
                      style: TextStyle(color: colors.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                key: const ValueKey('settings-check-update'),
                onPressed: _checking ? null : _check,
                child: Text(_checking ? '检查中' : '检查更新'),
              ),
            ],
          ),
          if (_status != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  _statusFailed
                      ? Icons.error_outline_rounded
                      : _statusUnavailable
                      ? Icons.info_outline_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 18,
                  color: statusColor,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(_status!, style: TextStyle(color: statusColor)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('settings-version-introduction'),
              onPressed: _showVersionIntroduction,
              icon: const Icon(Icons.notes_rounded, size: 18),
              label: const Text('版本介绍'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _status = null;
      _statusFailed = false;
      _statusUnavailable = false;
    });
    await _controller.loadCurrent();
    if (!mounted) return;
    final result = await _controller.checkForUpdate();
    if (!mounted) return;
    final check = result.data;
    final demoUnavailable =
        result.errorCode == 'PROFILE_VERSION_CHECK_DEMO_UNAVAILABLE';
    setState(() {
      _checking = false;
      _statusFailed = !result.ok && !demoUnavailable;
      _statusUnavailable = demoUnavailable;
      _status = demoUnavailable
          ? '版本检查服务尚未接入'
          : !result.ok || check == null
          ? '检查失败：${result.errorCode ?? 'PROFILE_VERSION_CHECK_FAILED'}'
          : check.updateAvailable
          ? '发现新版本 ${check.latestVersion ?? ''}'
          : '当前已是最新版本';
    });
  }

  Future<void> _loadInstalledVersion() async {
    await _controller.loadCurrent();
    if (mounted) setState(() {});
  }

  Future<void> _showVersionIntroduction() => showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final current = _controller.current;
      final colors = HuahuoV3Theme.tokensOf(dialogContext);
      return V3GlassDialogFrame(
        title: '版本介绍',
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 430),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current.releaseTitle,
                  key: const ValueKey('settings-version-release-title'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '版本 ${current.displayLabel} · 随安装包离线提供',
                  style: TextStyle(color: colors.muted, fontSize: 12.5),
                ),
                if (current.releaseSummary.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(current.releaseSummary),
                ],
                if (current.highlights.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  for (final highlight in current.highlights)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.check_circle_outline_rounded,
                            size: 17,
                            color: colors.accent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(highlight)),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}

class _ProfilePanel extends ConsumerWidget {
  const _ProfilePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final library = ref.watch(knowledgeLibraryControllerProvider);
    final positioningStage =
        ref.watch(deepPositioningControllerProvider).result?.positioningStage ??
        0;
    final growth = calculateGrowthProgress(
      personalContentCount: 0,
      explicitDepositCount: library.growthLedgerCount,
      completedCreationCount: 0,
      positioningStage: positioningStage,
    );
    final userProfile = ref.watch(userProfileControllerProvider).state.profile;
    final width = MediaQuery.sizeOf(context).width * .625;
    final safe = MediaQuery.paddingOf(context);
    const panelRadius = BorderRadius.only(
      topRight: Radius.circular(24),
      bottomRight: Radius.circular(24),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: panelRadius,
        boxShadow: [
          BoxShadow(
            color: colors.ink.withValues(alpha: .11),
            blurRadius: 34,
            spreadRadius: -10,
            offset: const Offset(10, 0),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: panelRadius,
        child: Material(
          color: colors.surface,
          surfaceTintColor: Colors.transparent,
          child: SizedBox(
            width: width,
            height: MediaQuery.sizeOf(context).height,
            child: Stack(
              children: [
                ListView(
                  padding: EdgeInsets.fromLTRB(
                    safe.left + 16,
                    safe.top + 16,
                    16,
                    safe.bottom + 14,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 46),
                      child: _ProfileHeader(
                        profile: userProfile,
                        onTap: () => _go(context, '/v3/profile/account'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _MembershipLevelCard(growth: growth),
                    const SizedBox(height: 10),
                    _ProfileAssetGrowthCard(
                      onOpen: () => _go(context, '/v3/profile/calendar'),
                    ),
                    const SizedBox(height: 10),
                    V3RecordingCardCompactControl(
                      onOpenManagement: () =>
                          _go(context, '/v3/recording-card'),
                    ),
                    const SizedBox(height: 14),
                    Material(
                      type: MaterialType.transparency,
                      child: Column(
                        children: [
                          _MenuItem(
                            Icons.hub_outlined,
                            '数字孪生',
                            onTap: () =>
                                _go(context, AppRoutePaths.digitalTwin),
                          ),
                          _MenuItem(
                            Icons.local_library_outlined,
                            '外部世界',
                            onTap: () => _go(context, '/v3/profile/knowledge'),
                          ),
                          _MenuItem(
                            Icons.inventory_2_outlined,
                            '我的资产',
                            onTap: () => _go(context, '/v3/profile/assets'),
                          ),
                          _MenuItem(
                            Icons.school_outlined,
                            '花火商学院',
                            onTap: () => _go(context, '/v3/profile/academy'),
                          ),
                          _MenuItem(
                            Icons.settings_outlined,
                            '设置',
                            onTap: () => _go(
                              context,
                              '/v3/profile/${Uri.encodeComponent('设置')}',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    V3OutlineButton(
                      label: '退出登录',
                      icon: Icons.logout,
                      onPressed: () => _confirmLogout(context, ref),
                    ),
                  ],
                ),
                Positioned(
                  top: safe.top + 16,
                  right: 10,
                  child: V3CloseButton(
                    key: const ValueKey<String>('profile-panel-close'),
                    tooltip: '关闭我的面板',
                    color: colors.ink,
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _go(BuildContext context, String route) {
    Navigator.of(context, rootNavigator: true).pop(route);
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => V3GlassDialog(
        title: '确认退出登录？',
        message: '退出后需要重新获取验证码登录。',
        primaryLabel: '确认',
        onPrimary: () {
          Navigator.of(dialogContext).pop(true);
        },
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    final router = GoRouter.maybeOf(context);
    var revoked = false;
    try {
      revoked = await ref
          .read(pushRegistrationControllerProvider)
          .unregisterBeforeLogout();
    } catch (_) {}
    if (!context.mounted) return;
    if (!revoked) {
      showV3Snack(context, '推送解绑尚未完成，登录状态已保留，请联网后重试退出');
      return;
    }
    try {
      ref.read(pushRuntimeControllerProvider).clearForLogout();
    } catch (_) {}
    final session = ref.read(sessionStoreProvider).state;
    final workspaceId = session.workspace?.workspaceId;
    if (workspaceId != null && workspaceId.trim().isNotEmpty) {
      try {
        ScopedReadCache(
          dao: ref.read(appPreferencesDaoProvider),
          userScope: ref.read(authenticatedUserDataScopeProvider),
          workspaceScope: workspaceId,
        ).clearScope();
      } catch (_) {
        // Cache removal is best effort and must never block a logout.
      }
    }
    await ref
        .read(sessionStoreProvider)
        .logout(loggedOutAt: DateTime.now().toUtc());
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    router?.go('/auth');
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.onTap});

  final UserProfileSnapshot profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final displayName = profile.nickname;
    final subtitle = profile.maskedPhoneNumber;
    return Semantics(
      button: true,
      label: '查看个人资料',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('profile-header-account-entry'),
          onTap: onTap,
          child: Row(
            children: [
              if (profile.avatar == null)
                const V3LiquidGlassSurface(
                  borderRadius: 26,
                  child: SizedBox.square(
                    dimension: 52,
                    child: ClipOval(
                      child: CustomPaint(painter: _GrayscalePortraitPainter()),
                    ),
                  ),
                )
              else
                V3ProfileAvatarPreview(avatar: profile.avatar, size: 52),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.muted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w400,
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

class _GrayscalePortraitPainter extends CustomPainter {
  const _GrayscalePortraitPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final skin = Paint()..color = const Color(0xFFD1D1CF);
    final hair = Paint()..color = const Color(0xFF4A4A49);
    final shirt = Paint()..color = const Color(0xFF353535);
    final highlight = Paint()..color = Colors.white.withValues(alpha: .42);

    canvas.drawCircle(
      center,
      size.width * .5,
      Paint()..color = const Color(0xFFE8E8E7),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx, size.height * .43),
        width: size.width * .43,
        height: size.height * .48,
      ),
      skin,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * .25,
          size.height * .14,
          size.width * .50,
          size.height * .29,
        ),
        Radius.circular(size.width * .23),
      ),
      hair,
    );
    canvas.drawCircle(Offset(size.width * .37, size.height * .43), 1.4, hair);
    canvas.drawCircle(Offset(size.width * .63, size.height * .43), 1.4, hair);
    canvas.drawLine(
      Offset(size.width * .43, size.height * .57),
      Offset(size.width * .57, size.height * .57),
      Paint()
        ..color = const Color(0xFF7B7B79)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * .17,
          size.height * .70,
          size.width * .66,
          size.height * .36,
        ),
        Radius.circular(size.width * .26),
      ),
      shirt,
    );
    canvas.drawOval(
      Rect.fromLTWH(
        size.width * .42,
        size.height * .61,
        size.width * .16,
        size.height * .22,
      ),
      skin,
    );
    canvas.drawCircle(
      Offset(size.width * .37, size.height * .34),
      3.2,
      highlight,
    );
  }

  @override
  bool shouldRepaint(covariant _GrayscalePortraitPainter oldDelegate) => false;
}

class _MembershipLevelCard extends StatelessWidget {
  const _MembershipLevelCard({required this.growth});

  final GrowthProgress growth;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      key: const ValueKey('profile-membership-level'),
      padding: const EdgeInsets.fromLTRB(11, 9, 8, 9),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.workspace_premium_outlined,
                size: 18,
                color: colors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '当前等级 Lv.${growth.level}',
                  maxLines: 1,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: growth.fraction,
              minHeight: 5,
              color: colors.accent,
              backgroundColor: colors.line,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            growth.level >= 10
                ? '共沉淀 ${growth.totalPoints} 条 · 已达最高等级'
                : growth.level == 1
                ? '完成首次社媒定位后升至 Lv.2'
                : growth.level == 2
                ? '完成进一步定位后升至 Lv.3'
                : '共沉淀 ${growth.totalPoints} 条 · '
                      '再沉淀 ${growth.pointsToNextLevel} 条升至 Lv.${growth.level + 1}',
            style: TextStyle(fontSize: 10.5, color: colors.muted),
          ),
        ],
      ),
    );
  }
}

class _ProfileAssetGrowthCard extends ConsumerStatefulWidget {
  const _ProfileAssetGrowthCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  ConsumerState<_ProfileAssetGrowthCard> createState() =>
      _ProfileAssetGrowthCardState();
}

class _ProfileAssetGrowthCardState
    extends ConsumerState<_ProfileAssetGrowthCard>
    with AppActivityRouteAware<_ProfileAssetGrowthCard> {
  OrchestratedPoller? _liveRefreshPoller;
  bool _hasLiveAssetWork = false;
  bool _liveRefreshInFlight = false;
  NoteMetricsController? _liveRefreshController;
  bool _queuedRefresh = false;
  bool _queuedRefreshForce = false;
  bool _queuedRefreshInvalidatesCache = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<AssetProjectionFreshness>(
      assetProjectionFreshnessProvider,
      (previous, next) {
        if (previous == null || previous.revision == next.revision) return;
        _configureLiveRefresh(next.hasActiveWork);
        unawaited(_reloadMetrics(force: true, invalidateCache: true));
      },
    );
    _configureLiveRefresh(
      ref.read(assetProjectionFreshnessProvider).hasActiveWork,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (activityRouteCanRun) {
        unawaited(ref.read(noteMetricsControllerProvider).refresh());
      }
    });
  }

  @override
  void dispose() {
    _liveRefreshPoller?.dispose();
    super.dispose();
  }

  @override
  void onActivityRouteBecameActive() {
    if (_hasLiveAssetWork) {
      _startLiveRefresh(immediate: true);
    } else {
      unawaited(ref.read(noteMetricsControllerProvider).refresh());
    }
  }

  @override
  void onActivityRouteBecameInactive() {
    _liveRefreshPoller?.stop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final metrics = ref.watch(noteMetricsControllerProvider).state;
    final selectedPeriod = ref
        .watch(assetGrowthPeriodControllerProvider)
        .period;
    final period = metrics.growthSeriesFor(selectedPeriod);
    return V3Card(
      key: const ValueKey('profile-asset-growth-card'),
      onTap: widget.onOpen,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_graph_rounded, size: 16, color: colors.accent),
              const SizedBox(width: 5),
              const Expanded(
                child: Text(
                  '资产新增',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              if (metrics.errorCode != null)
                IconButton(
                  key: const ValueKey('profile-note-metrics-retry'),
                  tooltip: '重试新增统计',
                  onPressed: () => unawaited(
                    _reloadMetrics(force: true, invalidateCache: true),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              for (final period in AssetGrowthPeriod.values)
                _ProfileAssetPeriodButton(
                  period: period,
                  selected: period == selectedPeriod,
                  onPressed: () {
                    final saved = ref
                        .read(assetGrowthPeriodControllerProvider)
                        .selectPeriod(period);
                    if (saved || !mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('周期偏好保存失败，请稍后重试')),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            period == null
                ? metrics.isLoading
                      ? '${selectedPeriod.summaryLabel} -- 条'
                      : '${selectedPeriod.summaryLabel}统计暂不可用'
                : '${selectedPeriod.summaryLabel} ${period.totalCount} 条',
            key: const ValueKey('profile-asset-period-summary'),
            maxLines: 1,
            style: TextStyle(
              color: colors.text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          if (metrics.isLoading && !metrics.hasData)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (period == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                metrics.errorCode == null ? '所选周期的数据覆盖尚不完整' : '新增统计加载失败，请重试',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
            )
          else
            SizedBox(
              height: 48,
              width: double.infinity,
              child: V3AssetGrowthSparkline(
                key: const ValueKey('profile-asset-growth-line'),
                values: period.days.map((day) => day.count).toList(),
                height: 48,
                semanticLabel: '${selectedPeriod.summaryLabel}趋势',
              ),
            ),
        ],
      ),
    );
  }

  void _configureLiveRefresh(bool hasLiveWork) {
    _hasLiveAssetWork = hasLiveWork;
    if (hasLiveWork) {
      _startLiveRefresh();
    } else {
      _liveRefreshPoller?.stop();
    }
  }

  void _startLiveRefresh({bool immediate = false}) {
    if (!activityRouteCanRun) return;
    _liveRefreshPoller ??= OrchestratedPoller(
      orchestrator: ref.read(taskOrchestratorProvider),
      // performance-rfc: unified-network-pollers
      spec: TaskSpec(
        key: 'profile.asset-metrics.account',
        owner: 'profile.asset-metrics',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 15),
      ),
      interval: const Duration(seconds: 10),
      maxBackoff: const Duration(seconds: 30),
      activityMetrics: ref.read(runtimeActivityMetricsProvider),
      poll: (_) async {
        if (!mounted || !_hasLiveAssetWork || !activityRouteCanRun) {
          return false;
        }
        await _reloadMetrics();
        return mounted && _hasLiveAssetWork && activityRouteCanRun;
      },
    );
    _liveRefreshPoller!.start(immediate: immediate);
  }

  Future<void> _reloadMetrics({
    bool force = true,
    bool invalidateCache = false,
  }) async {
    if (!activityRouteCanRun) return;
    if (_liveRefreshInFlight) {
      _queuedRefresh = true;
      _queuedRefreshForce = _queuedRefreshForce || force;
      _queuedRefreshInvalidatesCache =
          _queuedRefreshInvalidatesCache || invalidateCache;
      if (force || invalidateCache) {
        _liveRefreshController?.supersedePendingLoads();
      }
      return;
    }
    _liveRefreshInFlight = true;
    final controller = ref.read(noteMetricsControllerProvider);
    final library = ref.read(knowledgeLibraryControllerProvider);
    _liveRefreshController = controller;
    try {
      await Future.wait<Object?>([
        controller.load(force: force, invalidateCache: invalidateCache),
        library.synchronizeWorkspaceContent(forceSnapshot: invalidateCache),
      ]);
    } finally {
      _liveRefreshInFlight = false;
      _liveRefreshController = null;
      if (mounted && _queuedRefresh) {
        final queuedForce = _queuedRefreshForce;
        final queuedInvalidatesCache = _queuedRefreshInvalidatesCache;
        _queuedRefresh = false;
        _queuedRefreshForce = false;
        _queuedRefreshInvalidatesCache = false;
        unawaited(
          _reloadMetrics(
            force: queuedForce,
            invalidateCache: queuedInvalidatesCache,
          ),
        );
      }
    }
  }
}

extension on AssetGrowthPeriod {
  String get selectorLabel => switch (this) {
    AssetGrowthPeriod.week => '周',
    AssetGrowthPeriod.month => '月',
  };

  String get summaryLabel => switch (this) {
    AssetGrowthPeriod.week => '近 7 天新增',
    AssetGrowthPeriod.month => '近 30 天新增',
  };
}

class _ProfileAssetPeriodButton extends StatelessWidget {
  const _ProfileAssetPeriodButton({
    required this.period,
    required this.selected,
    required this.onPressed,
  });

  final AssetGrowthPeriod period;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return InkWell(
      key: ValueKey('profile-asset-period-${period.name}'),
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 24,
        width: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.surfaceMuted : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          period.selectorLabel,
          maxLines: 1,
          style: TextStyle(
            fontSize: 10.5,
            color: selected ? colors.text : colors.muted,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem(this.icon, this.label, {required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 9, 0),
        child: Column(
          children: [
            SizedBox(
              height: 37,
              child: Row(
                children: [
                  SizedBox(
                    width: 27,
                    child: Icon(icon, size: 18, color: colors.ink),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: colors.text,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 17, color: colors.muted),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
