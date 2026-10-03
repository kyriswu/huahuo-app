// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables, curly_braces_in_flow_control_structures

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../application/user_profile_controller.dart';
import 'v3_account_profile_page.dart';

class V3ProfileHomePage extends ConsumerWidget {
  const V3ProfileHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final profile = ref.watch(userProfileControllerProvider).state.profile;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 52,
                child: Row(
                  children: [
                    V3NavigationBackButton(
                      onPressed: () => returnToPreviousRoute(context),
                    ),
                    const SizedBox(width: 6),
                    V3ProfileAvatarPreview(avatar: profile.avatar, size: 36),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '我的',
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 20,
                          height: 1.25,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    _ProfileHomeIconButton(
                      tooltip: '设置',
                      icon: LucideIcons.settings,
                      onTap: () => context.push(
                        '/v3/profile/${Uri.encodeComponent('设置')}',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 72,
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => context.push('/v3/profile/account'),
                      child: V3ProfileAvatarPreview(
                        avatar: profile.avatar,
                        size: 64,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 17,
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            profile.maskedPhoneNumber,
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _ProfileHomeIconButton(
                      tooltip: '更换头像',
                      icon: LucideIcons.camera,
                      onTap: () => context.push('/v3/profile/account'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ProfileHomeSection(
                title: '我的功能',
                rows: [
                  _ProfileHomeRowData(
                    icon: Icons.hub_outlined,
                    label: '数字孪生',
                    route: '/v3/profile/digital-twin',
                  ),
                  _ProfileHomeRowData(
                    icon: Icons.local_library_outlined,
                    label: '外部世界',
                    route: '/v3/profile/knowledge',
                  ),
                  _ProfileHomeRowData(
                    icon: Icons.inventory_2_outlined,
                    label: '我的资产',
                    route: '/v3/profile/assets',
                  ),
                  _ProfileHomeRowData(
                    icon: Icons.graphic_eq_rounded,
                    label: '录音文件',
                    route: '/v3/profile/recordings',
                  ),
                  _ProfileHomeRowData(
                    icon: Icons.school_outlined,
                    label: '花火商学院',
                    route: '/v3/profile/academy',
                  ),
                  _ProfileHomeRowData(
                    icon: Icons.settings_outlined,
                    label: '设置',
                    route: '/v3/profile/${Uri.encodeComponent('设置')}',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileHomeIconButton extends StatelessWidget {
  const _ProfileHomeIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        fixedSize: const Size.square(40),
        padding: EdgeInsets.zero,
        shape: CircleBorder(side: BorderSide(color: colors.line)),
      ),
    );
  }
}

final class _ProfileHomeRowData {
  const _ProfileHomeRowData({
    required this.icon,
    required this.label,
    required this.route,
  });

  final IconData icon;
  final String label;
  final String route;
}

class _ProfileHomeSection extends StatelessWidget {
  const _ProfileHomeSection({required this.title, required this.rows});

  final String title;
  final List<_ProfileHomeRowData> rows;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: colors.muted, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 8),
        for (final row in rows)
          InkWell(
            onTap: () => context.push(row.route),
            child: SizedBox(
              height: 50,
              child: Row(
                children: [
                  Icon(row.icon, size: 20, color: colors.text),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      row.label,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 15,
                        height: 1.35,
                      ),
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, size: 18, color: colors.muted),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
