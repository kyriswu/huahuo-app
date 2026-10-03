// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/idempotency.dart';
import '../../core/auth/session_store.dart';
import '../../core/tasking/orchestrated_poller.dart';
import '../../core/tasking/task_orchestrator.dart';
import '../../shared/ui_v3/v3_brand_mark.dart';
import '../bootstrap/app_bootstrap_controller.dart';
import '../bootstrap/app_providers.dart';
import '../runtime/runtime_provider_module.dart';
import 'app_route_observer.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    _watchdog = Timer(const Duration(seconds: 16), () {
      if (!mounted) {
        return;
      }
      ref.read(appBootstrapControllerProvider).markRestoreTimedOut();
    });
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appBootstrapControllerProvider);
    return const Scaffold(
      backgroundColor: Color(0xFFFFFFFF),
      body: V3LaunchBrandLockup(
        markKey: ValueKey<String>('splash-brand-mark'),
        wordmarkKey: ValueKey<String>('splash-brand-wordmark'),
      ),
    );
  }
}

class RestoreFailedScreen extends ConsumerWidget {
  const RestoreFailedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bootstrap = ref.watch(appBootstrapControllerProvider).state;
    final errorCode = bootstrap.errorCode ?? 'SESSION_RESTORE_FAILED';
    final secureStorageUnavailable = const <String>{
      'SECURE_TOKEN_READ_FAILED',
      'SECURE_TOKEN_CLEAR_FAILED',
    }.contains(errorCode);
    final controller = ref.read(appBootstrapControllerProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('会话恢复失败：$errorCode'),
                if (secureStorageUnavailable) ...[
                  const SizedBox(height: 8),
                  const Text('设备登录信息暂时无法读取，请使用手机号重新登录。'),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => unawaited(
                    secureStorageUnavailable
                        ? controller.resetToLogin()
                        : controller.restore(),
                  ),
                  child: Text(secureStorageUnavailable ? '使用手机号登录' : '重试'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => unawaited(
                    secureStorageUnavailable
                        ? controller.restore()
                        : controller.resetToLogin(),
                  ),
                  child: Text(secureStorageUnavailable ? '重试读取凭据' : '使用手机号登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WorkspaceStatusScreen extends ConsumerStatefulWidget {
  const WorkspaceStatusScreen({super.key});

  @override
  ConsumerState<WorkspaceStatusScreen> createState() =>
      _WorkspaceStatusScreenState();
}

class _WorkspaceStatusScreenState extends ConsumerState<WorkspaceStatusScreen>
    with AppActivityRouteAware<WorkspaceStatusScreen> {
  bool _retrying = false;
  bool _refreshingStatus = false;
  String? _errorCode;
  late final OrchestratedPoller _statusPoller;

  @override
  void initState() {
    super.initState();
    _statusPoller = OrchestratedPoller(
      orchestrator: ref.read(taskOrchestratorProvider),
      // performance-rfc: workspace-status-polling
      spec: TaskSpec(
        key: 'workspace:create-status-poll',
        owner: 'workspace-status-poll',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 15),
      ),
      interval: const Duration(seconds: 2),
      maxBackoff: const Duration(seconds: 30),
      activityMetrics: ref.read(runtimeActivityMetricsProvider),
      poll: (token) async {
        await _refreshCreatingWorkspace();
        token.throwIfCancelled();
        return mounted &&
            activityRouteCanRun &&
            ref.read(sessionStoreProvider).state.workspaceStatus ==
                SessionWorkspaceStatus.creating;
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _statusPoller.start();
    });
  }

  @override
  void dispose() {
    _statusPoller.dispose();
    super.dispose();
  }

  @override
  void onActivityRouteBecameActive() => _statusPoller.start();

  @override
  void onActivityRouteBecameInactive() => _statusPoller.stop();

  Future<void> _refreshCreatingWorkspace() async {
    if (!activityRouteCanRun) return;
    final session = ref.read(sessionStoreProvider).state;
    if (_refreshingStatus ||
        session.workspaceStatus != SessionWorkspaceStatus.creating) {
      return;
    }
    if (mounted) setState(() => _refreshingStatus = true);
    try {
      await ref.read(appBootstrapControllerProvider).refreshStatus();
    } finally {
      if (mounted) setState(() => _refreshingStatus = false);
    }
  }

  Future<void> _retryWorkspace() async {
    if (_retrying) return;
    if (ref.read(sessionStoreProvider).state.workspaceStatus ==
        SessionWorkspaceStatus.creating) {
      await _refreshCreatingWorkspace();
      return;
    }
    setState(() {
      _retrying = true;
      _errorCode = null;
    });
    final result = await ref
        .read(backendContractApiProvider)
        .retryWorkspaceCreate(
          idempotency: IdempotencyRequestContext(
            operation: 'workspace-retry-create',
            scene: 'workspace-recovery',
            explicitKey:
                'workspace-retry-${DateTime.now().toUtc().microsecondsSinceEpoch}',
          ),
        );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _retrying = false;
        _errorCode = result.error?.code ?? 'WORKSPACE_RETRY_FAILED';
      });
      return;
    }
    final bootstrap = ref.read(appBootstrapControllerProvider);
    for (var attempt = 0; attempt < 8; attempt += 1) {
      await bootstrap.refreshStatus();
      if (!mounted) return;
      final session = ref.read(sessionStoreProvider).state;
      if (!session.needsWorkspaceRetry &&
          session.workspaceStatus == SessionWorkspaceStatus.ready) {
        break;
      }
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    if (!mounted) return;
    setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionStoreProvider).state;
    final bootstrap = ref.watch(appBootstrapControllerProvider).state;
    final creating = session.workspaceStatus == SessionWorkspaceStatus.creating;
    final retrying =
        _retrying ||
        _refreshingStatus ||
        bootstrap.status == AppBootstrapStatus.restoring;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  creating
                      ? Icons.hourglass_top_rounded
                      : Icons.cloud_off_outlined,
                  size: 40,
                ),
                const SizedBox(height: 16),
                Text(
                  creating ? '正在准备你的工作区' : '工作区暂时不可用',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  creating ? '正在检查恢复进度，请稍候。' : '点击下方按钮重新发起恢复。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                IconButton(
                  tooltip: creating ? '刷新工作区状态' : '重新创建工作区',
                  onPressed: retrying ? null : _retryWorkspace,
                  icon: retrying
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
                if (_errorCode != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '暂时无法开始恢复，请稍后重试。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
