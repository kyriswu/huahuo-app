import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/auth/data/auth_api.dart';
import 'package:huahuoai_app/features/backend_contracts/data/backend_contract_api.dart';
import 'package:huahuoai_app/features/chat/data/chat_api.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/data/hotspot_note_repository.dart';
import 'package:integration_test/integration_test.dart';

const _backendUrl = String.fromEnvironment(
  'HUAHUO_BACKEND_PROBE_URL',
  defaultValue: 'http://127.0.0.1:18080',
);
const _probeAccessToken = String.fromEnvironment(
  'HUAHUO_BACKEND_PROBE_ACCESS_TOKEN',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('concrete simulator traverses live Home and Chat contracts', (
    tester,
  ) async {
    final entries = <_ProbeEntry>[];
    final anonymousClient = _client();

    final appConfig = await anonymousClient.request<Map<String, Object?>>(
      const ApiRequestOptions<Map<String, Object?>>(
        endpointId: 'appConfig',
        parseData: asObjectMap,
      ),
    );
    entries.add(
      _ProbeEntry(
        label: '应用配置',
        endpoint: 'GET /api/v1/app/config',
        result: appConfig.ok
            ? 'HTTP ${appConfig.status} / PASS'
            : _apiError(appConfig),
        healthy: appConfig.ok,
      ),
    );

    final token = await _resolveProbeToken(entries, anonymousClient);
    if (token != null && token.isNotEmpty) {
      final authenticatedClient = _client(accessToken: token);
      final hotspotResult = await _loadHotspots(authenticatedClient);
      entries.add(
        _ProbeEntry(
          label: '首页热点推荐',
          endpoint: 'GET /api/v1/home',
          result: hotspotResult.result,
          healthy: hotspotResult.healthy,
        ),
      );

      final workspaceRetry =
          await BackendContractApi(
            apiClient: authenticatedClient,
          ).retryWorkspaceCreate(
            idempotency: const IdempotencyRequestContext(
              explicitKey: 'ios-simulator-workspace-retry-001',
              operation: 'backend-probe-workspace-retry',
            ),
          );
      entries.add(
        _ProbeEntry(
          label: 'Workspace 恢复',
          endpoint: 'POST /api/v1/workspace/retry-create',
          result: workspaceRetry.ok
              ? 'HTTP ${workspaceRetry.status} / PASS'
              : _apiError(workspaceRetry),
          healthy: workspaceRetry.ok,
        ),
      );

      final chatApi = RemoteProjectChatRepository(
        apiClient: authenticatedClient,
      );
      final catalog = await AgentCatalogClient(authenticatedClient).profiles();
      entries.add(
        _ProbeEntry(
          label: '聊一聊能力目录',
          endpoint: 'GET /api/v1/agent-profiles',
          result: catalog.ok
              ? 'HTTP ${catalog.status} / ${catalog.data?.items.length ?? 0} 个 Agent'
              : _apiError(catalog),
          healthy:
              catalog.ok &&
              (catalog.data?.items.any(
                    (item) => item.agentProfileId == 'self_media_creation',
                  ) ??
                  false),
        ),
      );

      final chatNonce = DateTime.now().microsecondsSinceEpoch.toString();
      final createThread = await chatApi.createThread(
        scene: ChatScene.feedAi,
        idempotency: IdempotencyRequestContext(
          explicitKey: 'ios-simulator-chat-thread-$chatNonce',
          operation: 'backend-probe-chat-thread',
        ),
      );
      entries.add(
        _ProbeEntry(
          label: '聊一聊建线程',
          endpoint: 'POST /api/v1/chat/threads',
          result: createThread.ok
              ? 'HTTP ${createThread.status} / PASS'
              : _apiError(createThread),
          healthy: createThread.ok,
        ),
      );
      final threadId = createThread.data?.threadId;
      if (threadId != null) {
        final sent = await chatApi.sendTextMessage(
          threadId: threadId,
          scene: ChatScene.feedAi,
          content: '请用一句话回复：普通聊天后端探测成功。',
          idempotency: IdempotencyRequestContext(
            explicitKey: 'ios-simulator-chat-message-$chatNonce',
            operation: 'backend-probe-chat-message',
          ),
        );
        entries.add(
          _ProbeEntry(
            label: '聊一聊发送消息',
            endpoint: 'POST /api/v1/chat/threads/{threadId}/messages',
            result: sent.ok
                ? 'HTTP ${sent.status} / ${sent.data?.nextAction.type.name ?? 'accepted'}'
                : _apiError(sent),
            healthy: sent.ok,
          ),
        );
        final durableReply = sent.ok
            ? await _waitForAssistant(chatApi, threadId)
            : const _ProbeResult(
                result: 'SKIPPED / MESSAGE_REJECTED',
                healthy: false,
              );
        entries.add(
          _ProbeEntry(
            label: '聊一聊持久回复',
            endpoint: 'GET /api/v1/chat/threads/{threadId}',
            result: durableReply.result,
            healthy: durableReply.healthy,
          ),
        );
      } else {
        entries.addAll(const <_ProbeEntry>[
          _ProbeEntry(
            label: '聊一聊发送消息',
            endpoint: 'POST /api/v1/chat/threads/{threadId}/messages',
            result: 'SKIPPED / THREAD_CREATE_FAILED',
            healthy: false,
          ),
          _ProbeEntry(
            label: '聊一聊持久回复',
            endpoint: 'GET /api/v1/chat/threads/{threadId}',
            result: 'SKIPPED / THREAD_CREATE_FAILED',
            healthy: false,
          ),
        ]);
      }
    } else {
      entries.addAll(const <_ProbeEntry>[
        _ProbeEntry(
          label: '首页热点推荐',
          endpoint: 'GET /api/v1/home',
          result: 'SKIPPED / LOGIN_FAILED',
          healthy: false,
        ),
        _ProbeEntry(
          label: 'Workspace 恢复',
          endpoint: 'POST /api/v1/workspace/retry-create',
          result: 'SKIPPED / LOGIN_FAILED',
          healthy: false,
        ),
        _ProbeEntry(
          label: '聊一聊能力目录',
          endpoint: 'GET /api/v1/agent-profiles',
          result: 'SKIPPED / LOGIN_FAILED',
          healthy: false,
        ),
        _ProbeEntry(
          label: '聊一聊建线程',
          endpoint: 'POST /api/v1/chat/threads',
          result: 'SKIPPED / LOGIN_FAILED',
          healthy: false,
        ),
        _ProbeEntry(
          label: '聊一聊发送消息',
          endpoint: 'POST /api/v1/chat/threads/{threadId}/messages',
          result: 'SKIPPED / LOGIN_FAILED',
          healthy: false,
        ),
        _ProbeEntry(
          label: '聊一聊持久回复',
          endpoint: 'GET /api/v1/chat/threads/{threadId}',
          result: 'SKIPPED / LOGIN_FAILED',
          healthy: false,
        ),
      ]);
    }

    await tester.pumpWidget(_ProbeReport(entries: entries));
    await tester.pumpAndSettle();
    expect(appConfig.ok, isTrue);
    expect(entries, hasLength(9));
    debugPrint(
      'BACKEND_PROBE_RESULTS ${entries.map((entry) => '${entry.label}=${entry.result}').join('; ')}',
    );
    await binding.takeScreenshot('backend_live_contract_probe_overview');
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('backend_live_contract_probe_chat');
    debugPrint('BACKEND_PROBE_SCREEN_READY');
    await Future<void>.delayed(const Duration(seconds: 25));
  });
}

Future<String?> _resolveProbeToken(
  List<_ProbeEntry> entries,
  ApiClient anonymousClient,
) async {
  final injectedToken = _probeAccessToken.trim();
  if (injectedToken.isNotEmpty) {
    entries.add(
      const _ProbeEntry(
        label: '短信验证码',
        endpoint: 'POST /api/v1/auth/sms-code',
        result: 'SKIPPED / EPHEMERAL_QA_TOKEN',
        healthy: true,
      ),
    );
    final status = await AuthApi(
      apiClient: _client(accessToken: injectedToken),
    ).getUserStatus(accessToken: injectedToken);
    entries.add(
      _ProbeEntry(
        label: '短期测试登录态',
        endpoint: 'GET /api/v1/me/status',
        result: status.ok
            ? 'HTTP ${status.status} / ${status.value?.workspace.status.name ?? 'ready'}'
            : 'HTTP ${status.status} / ${status.error?.code ?? 'UNKNOWN'}',
        healthy: status.ok,
      ),
    );
    return status.ok ? injectedToken : null;
  }

  final authApi = AuthApi(apiClient: anonymousClient);
  final sms = await authApi.sendSmsCode(
    phone: '13800009175',
    correlationId: 'ios-simulator-sms-probe',
    idempotency: const IdempotencyRequestContext(
      explicitKey: 'ios-simulator-sms-probe-001',
      operation: 'backend-probe-sms',
      scene: 'login',
    ),
  );
  entries.add(
    _ProbeEntry(
      label: '短信验证码',
      endpoint: 'POST /api/v1/auth/sms-code',
      result: sms.ok
          ? 'HTTP ${sms.status} / PASS'
          : 'HTTP ${sms.status} / ${sms.error?.code ?? 'UNKNOWN'}',
      healthy: sms.ok,
    ),
  );

  final login = await authApi.login(
    request: const SmsLoginRequest(
      phone: '13800009175',
      smsRequestId: 'local-bypass',
      code: '112233',
      deviceId: 'ios-simulator-3e40e1d7',
      agreementAccepted: true,
      clientVersion: '0.1.0',
    ),
    correlationId: 'ios-simulator-login-probe',
    idempotency: const IdempotencyRequestContext(
      explicitKey: 'ios-simulator-login-probe-001',
      operation: 'backend-probe-login',
      scene: 'login',
    ),
  );
  entries.add(
    _ProbeEntry(
      label: '本地测试登录',
      endpoint: 'POST /api/v1/auth/login',
      result: login.ok
          ? 'HTTP ${login.status} / ${login.value!.workspaceStatus.name}'
          : 'HTTP ${login.status} / ${login.error?.code ?? 'UNKNOWN'}',
      healthy: login.ok,
    ),
  );
  return login.value?.tokens.accessToken;
}

ApiClient _client({String? accessToken}) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse(_backendUrl),
    clientVersion: '0.1.0',
    deviceId: 'ios-simulator-3e40e1d7',
    platform: 'ios',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
    getAccessToken: accessToken == null ? null : () => accessToken,
    requestTimeout: const Duration(seconds: 10),
  ),
  transport: HttpApiTransport(),
);

Future<_ProbeResult> _loadHotspots(ApiClient client) async {
  try {
    final notes = await ApiHotspotNoteRepository(client).loadHotspots();
    return _ProbeResult(
      result: 'HTTP 200 / ${notes.length} 条热点',
      healthy: true,
    );
  } on StateError catch (error) {
    return _ProbeResult(result: '服务端阻塞 / ${error.message}', healthy: false);
  } on Object catch (error) {
    return _ProbeResult(result: '客户端异常 / ${error.runtimeType}', healthy: false);
  }
}

Future<_ProbeResult> _waitForAssistant(
  RemoteProjectChatRepository chatApi,
  String threadId,
) async {
  for (var attempt = 0; attempt < 15; attempt += 1) {
    if (attempt > 0) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final detail = await chatApi.getThreadDetail(threadId: threadId);
    if (!detail.ok || detail.data == null) continue;
    final assistants = detail.data!.messages.where(
      (message) => message.role == ChatMessageRole.assistant,
    );
    if (assistants.isNotEmpty) {
      return _ProbeResult(
        result:
            'HTTP ${detail.status} / PASS / ${assistants.last.visibleText ?? '已持久化'}',
        healthy: true,
      );
    }
  }
  return const _ProbeResult(
    result: 'TIMEOUT / 未读取到持久 Assistant Message',
    healthy: false,
  );
}

String _apiError<T>(ApiResult<T> result) =>
    'HTTP ${result.status ?? '-'} / ${result.error?.code ?? 'UNKNOWN'}';

final class _ProbeResult {
  const _ProbeResult({required this.result, required this.healthy});

  final String result;
  final bool healthy;
}

final class _ProbeEntry {
  const _ProbeEntry({
    required this.label,
    required this.endpoint,
    required this.result,
    required this.healthy,
  });

  final String label;
  final String endpoint;
  final String result;
  final bool healthy;
}

final class _ProbeReport extends StatelessWidget {
  const _ProbeReport({required this.entries});

  final List<_ProbeEntry> entries;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF13715B),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7F6),
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('后端真实请求测试')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: <Widget>[
              const Text(
                '无限花火 · iPhone 17 · iOS Simulator 26.5',
                style: TextStyle(fontSize: 13, color: Color(0xFF52615D)),
              ),
              const SizedBox(height: 6),
              const Text(
                '真实 HTTP，无 Fake；红色项为服务端返回或环境阻塞。',
                style: TextStyle(fontSize: 13, color: Color(0xFF52615D)),
              ),
              const SizedBox(height: 16),
              for (final entry in entries) ...<Widget>[
                _ProbeTile(entry: entry),
                const SizedBox(height: 10),
              ],
              const Text(
                '未调用 Work AI / Feed AI 禁止端点',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Color(0xFF52615D)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ProbeTile extends StatelessWidget {
  const _ProbeTile({required this.entry});

  final _ProbeEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = entry.healthy
        ? const Color(0xFF13715B)
        : const Color(0xFFB23A35);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD9E0DD)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              entry.healthy ? Icons.check_circle : Icons.error_outline,
              color: color,
              size: 22,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.endpoint,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF52615D),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    entry.result,
                    style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
