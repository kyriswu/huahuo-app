import 'package:huahuoai_app/app/di/account_usage_providers.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../chat/application/resource_image_reader.dart';
import '../../billing/application/account_usage_controller.dart';
import '../../billing/widgets/account_usage_panel.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../application/user_profile_controller.dart';
import '../application/voiceprint_controller.dart';

class V3AccountProfilePage extends ConsumerStatefulWidget {
  const V3AccountProfilePage({super.key});

  @override
  ConsumerState<V3AccountProfilePage> createState() =>
      _V3AccountProfilePageState();
}

class _V3AccountProfilePageState extends ConsumerState<V3AccountProfilePage>
    with AppActivityRouteAware<V3AccountProfilePage> {
  late final OrchestratedPoller _usagePoller;
  bool _nicknameSaving = false;
  bool _voiceprintSummaryLoading = true;
  bool? _voiceprintSummarySynced;

  @override
  void initState() {
    super.initState();
    _usagePoller = OrchestratedPoller(
      orchestrator: ref.read(taskOrchestratorProvider),
      spec: TaskSpec(
        key: 'account:usage-refresh',
        owner: 'account-usage-page',
        priority: TaskPriority.userVisible,
        resources: const {TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 25),
      ),
      interval: const Duration(seconds: 30),
      maxBackoff: const Duration(minutes: 2),
      activityMetrics: ref.read(runtimeActivityMetricsProvider),
      poll: (token) async {
        if (!activityRouteCanRun) return false;
        final usage = ref.read(accountUsageControllerProvider);
        await usage.load();
        token.throwIfCancelled();
        if (usage.status == AccountUsageStatus.failure ||
            usage.status == AccountUsageStatus.unavailable) {
          throw StateError('Account usage unavailable');
        }
        return activityRouteCanRun;
      },
    );
    ref.listenManual(accountUsageControllerProvider, (previous, next) {
      if (identical(previous, next)) return;
      Future<void>.microtask(() async {
        if (activityRouteCanRun) await next.load();
      });
    });
    Future<void>.microtask(_refreshVoiceprintSummary);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (activityRouteCanRun) _usagePoller.start();
    });
  }

  @override
  void onActivityRouteBecameActive() => _usagePoller.start();

  @override
  void onActivityRouteBecameInactive() => _usagePoller.stop();

  @override
  void dispose() {
    _usagePoller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(userProfileControllerProvider).state;
    final controller = ref.read(userProfileControllerProvider);
    final accountUsage = ref.watch(accountUsageControllerProvider);
    final voiceprintState = ref.watch(voiceprintControllerProvider).state;
    final colors = HuahuoV3Theme.tokensOf(context);
    final saving = state.status == UserProfileSaveStatus.saving;
    final canEditProfile = state.profile.authenticated && !saving;
    final realVoiceprintCount = voiceprintState.profiles
        .where((profile) => !profile.isDemo)
        .length;
    return V3PageScaffold(
      title: '账号与服务',
      centerTitle: true,
      onRefresh: accountUsage.load,
      fallbackRoute: '/v3/profile',
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        V3Card(
          glass: false,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              V3ProfileAvatarPreview(avatar: state.draftAvatar, size: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.draftNickname.trim().isEmpty
                          ? '花火用户'
                          : state.draftNickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        height: 22 / 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      state.profile.maskedPhoneNumber,
                      style: TextStyle(color: colors.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '无限花火账号',
                      style: TextStyle(color: colors.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Semantics(
                button: true,
                enabled: canEditProfile,
                label: '修改昵称',
                onTap: canEditProfile
                    ? () => _editNickname(context, controller)
                    : null,
                child: ExcludeSemantics(
                  child: SizedBox.square(
                    dimension: 44,
                    child: IconButton(
                      key: const ValueKey('profile-nickname-button'),
                      tooltip: '修改昵称',
                      constraints: const BoxConstraints.expand(),
                      onPressed: canEditProfile
                          ? () => _editNickname(context, controller)
                          : null,
                      icon: _nicknameSaving
                          ? const SizedBox.square(
                              dimension: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.edit_outlined, size: 19),
                    ),
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: '修改头像',
                child: V3LiquidGlassSurface(
                  tone: V3GlassTone.cool,
                  borderRadius: 20,
                  child: IconButton(
                    key: const ValueKey('profile-avatar-button'),
                    tooltip: '修改头像',
                    onPressed: canEditProfile
                        ? () => _showAvatarSourceSheet(context, controller)
                        : null,
                    icon: saving && !_nicknameSaving
                        ? const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_camera_outlined, size: 19),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _MembershipSummaryCard(
          status: _membershipStatusLabel(
            accountUsage.membership?.levelCode,
            accountUsage.membership?.status,
          ),
          loading: accountUsage.loading,
          onTap: () =>
              context.push('/v3/profile/${Uri.encodeComponent('会员充值')}'),
        ),
        const SizedBox(height: 16),
        AccountUsagePanel(controller: accountUsage),
        const SizedBox(height: 26),
        const V3SectionTitle('我的服务'),
        const SizedBox(height: 4),
        _AccountServiceRow(
          key: const ValueKey('account-service-voiceprint'),
          icon: Icons.graphic_eq_rounded,
          title: '声纹识别',
          value: _voiceprintSummaryLabel(
            realProfileCount: realVoiceprintCount,
            loading: _voiceprintSummaryLoading,
            syncSucceeded: _voiceprintSummarySynced,
            errorCode: voiceprintState.errorCode,
          ),
          onTap: () => context.push('/v3/profile/voiceprint'),
        ),
        _AccountServiceRow(
          key: const ValueKey('account-service-recordings'),
          icon: Icons.mic_none_rounded,
          title: '录音文件',
          value: '独白 · 内录 · 外录',
          onTap: () => context.push('/v3/profile/recordings'),
        ),
        _AccountServiceRow(
          key: const ValueKey('account-service-creation-history'),
          icon: Icons.edit_note_rounded,
          title: '自由创作历史',
          value: '继续编辑原始内容',
          onTap: () => context.push('/v3/workbench/history'),
        ),
        _AccountServiceRow(
          key: const ValueKey('account-service-conversation-history'),
          icon: Icons.chat_bubble_outline_rounded,
          title: '对话记录',
          value: '全部记录',
          onTap: () => context.push('/v3/feed/chat?history=1'),
          last: true,
        ),
        if (state.errorCode != null) ...[
          const SizedBox(height: 12),
          Text(
            _profileErrorText(state.errorCode!),
            style: TextStyle(color: colors.danger, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Future<void> _refreshVoiceprintSummary() async {
    final synced = await ref
        .read(voiceprintControllerProvider)
        .refreshProfiles();
    if (!mounted) return;
    setState(() {
      _voiceprintSummaryLoading = false;
      _voiceprintSummarySynced = synced;
    });
  }

  Future<void> _editNickname(
    BuildContext context,
    UserProfileController controller,
  ) async {
    final currentNickname = controller.state.draftNickname.trim();
    final nickname = await showV3TextInputDialog(
      context: context,
      title: '修改昵称',
      initialValue: currentNickname,
      label: '昵称',
      maxLength: 64,
      validator: _nicknameValidationError,
      inputKey: const ValueKey('profile-nickname-input'),
    );
    if (nickname == null || nickname == currentNickname) return;
    controller.updateNickname(nickname);
    setState(() => _nicknameSaving = true);
    final saved = await controller.save();
    if (!context.mounted) return;
    setState(() => _nicknameSaving = false);
    showV3Snack(context, saved ? '昵称已更新' : '昵称同步失败，请重试');
  }

  Future<void> _showAvatarSourceSheet(
    BuildContext context,
    UserProfileController controller,
  ) async {
    final source = await showV3ActionSheet<UserProfileAvatarSource>(
      context: context,
      title: '更换头像',
      message: '选择后将同步头像到云端',
      listKey: const ValueKey('profile-avatar-source-list'),
      items: const [
        V3ActionSheetItem<UserProfileAvatarSource>(
          value: UserProfileAvatarSource.photoLibrary,
          icon: Icons.photo_library_outlined,
          label: '从相册选择',
        ),
        V3ActionSheetItem<UserProfileAvatarSource>(
          value: UserProfileAvatarSource.camera,
          icon: Icons.photo_camera_outlined,
          label: '拍照',
        ),
      ],
    );
    if (source == null) return;
    final selected = await controller.chooseAvatar(source);
    if (!context.mounted) return;
    if (!selected) {
      if (controller.state.errorCode != null) {
        showV3Snack(context, '头像选择失败，请重新尝试');
      }
      return;
    }
    final saved = await controller.save();
    if (!context.mounted) return;
    showV3Snack(context, saved ? '头像已更新' : '头像同步失败，请重试');
  }
}

class _MembershipSummaryCard extends StatelessWidget {
  const _MembershipSummaryCard({
    required this.status,
    required this.loading,
    required this.onTap,
  });

  final String status;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFFB7BAC7);
    return Material(
      color: const Color(0xFF111322),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('account-membership-entry'),
        onTap: onTap,
        child: SizedBox(
          height: 116,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        '无限花火会员',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        loading ? '正在读取会员状态' : status,
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '三个 Agent 与 10 GB 工作区，随时开启',
                        style: TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const Text(
                  '立即开通',
                  style: TextStyle(
                    color: Color(0xFFF0C77A),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFFF0C77A),
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountServiceRow extends StatelessWidget {
  const _AccountServiceRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.last = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: colors.line)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.ink),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
            Text(value, style: TextStyle(color: colors.muted, fontSize: 12)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: colors.muted, size: 18),
          ],
        ),
      ),
    );
  }
}

String _membershipStatusLabel(String? levelCode, String? status) {
  if (levelCode == null || levelCode == 'free') return '未开通';
  if (status == 'active' || status == 'grace_period') return '已开通';
  if (status == 'pending') return '待生效';
  return '未开通';
}

String _voiceprintSummaryLabel({
  required int realProfileCount,
  required bool loading,
  required bool? syncSucceeded,
  required String? errorCode,
}) {
  if (realProfileCount > 0) return '已录入';
  if (loading) return '正在同步';
  if (errorCode == 'VOICEPRINT_PROFILE_SYNC_FAILED' || syncSucceeded != true) {
    return '同步异常';
  }
  return '未录入';
}

String? _nicknameValidationError(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '请输入昵称';
  if (normalized.runes.length > 64 || utf8.encode(normalized).length > 256) {
    return '昵称不能超过 64 个字符';
  }
  if (normalized.runes.any((rune) => rune <= 0x1f || rune == 0x7f)) {
    return '昵称包含不支持的字符';
  }
  return null;
}

class V3ProfileAvatarPreview extends ConsumerWidget {
  const V3ProfileAvatarPreview({
    required this.avatar,
    this.size = 60,
    super.key,
  });

  final UserProfileAvatar? avatar;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cacheExtent = (size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 2048)
        .toInt();
    final source = avatar?.source;
    final localPath = avatar?.localPath;
    final resourceId = avatar?.avatarResourceId?.trim();
    final playbackUrl = avatar?.playbackUrl;
    final image = localPath != null
        ? Image.file(
            File(localPath),
            fit: BoxFit.cover,
            cacheWidth: cacheExtent,
            cacheHeight: cacheExtent,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          )
        : resourceId != null && resourceId.isNotEmpty
        ? _CachedAvatarImage(
            resourceId: resourceId,
            cache: ref.watch(resourceImageCacheProvider),
            cacheExtent: cacheExtent,
          )
        : playbackUrl != null
        ? Image.network(
            playbackUrl.toString(),
            fit: BoxFit.cover,
            cacheWidth: cacheExtent,
            cacheHeight: cacheExtent,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          )
        : null;
    return V3LiquidGlassSurface(
      borderRadius: size / 2,
      child: SizedBox.square(
        dimension: size,
        child: ClipOval(
          child:
              image ??
              ColoredBox(
                color: Colors.white.withValues(alpha: .12),
                child: Icon(
                  switch (source) {
                    UserProfileAvatarSource.photoLibrary =>
                      Icons.image_outlined,
                    UserProfileAvatarSource.camera => Icons.camera_alt_outlined,
                    null => Icons.person_outline_rounded,
                  },
                  size: size * .45,
                  color: HuahuoV3Theme.tokensOf(context).ink,
                ),
              ),
        ),
      ),
    );
  }
}

class _CachedAvatarImage extends StatelessWidget {
  const _CachedAvatarImage({
    required this.resourceId,
    required this.cache,
    required this.cacheExtent,
  });

  final String resourceId;
  final ResourceImageReader cache;
  final int cacheExtent;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CachedResourceImage>(
      future: cache.load(resourceId),
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image == null) return const SizedBox.shrink();
        return Image.memory(
          image.bytes,
          fit: BoxFit.cover,
          cacheWidth: cacheExtent,
          cacheHeight: cacheExtent,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      },
    );
  }
}

String _profileErrorText(String code) {
  return switch (code) {
    'USER_PROFILE_LOGIN_REQUIRED' => '请先登录后再修改个人资料',
    'USER_PROFILE_LOAD_FAILED' => '云端资料读取失败，请稍后重试',
    'USER_PROFILE_AVATAR_PICK_FAILED' => '头像选择失败，请重新尝试',
    'USER_PROFILE_AVATAR_PREPARE_FAILED' => '头像处理失败，请重新选择',
    'USER_PROFILE_AVATAR_UPLOAD_FAILED' => '头像上传失败，请重新尝试',
    'USER_PROFILE_SAVE_RESPONSE_INVALID' => '资料保存后回显异常，请稍后刷新查看',
    _ => '资料保存失败，请重新尝试（$code）',
  };
}
