# 后端协议与核对结论

## 证据与优先级

本说明依据打包时本地 Flutter 源码、`huahuoai-all/source` 的对应路由/服务实现，以及 `huahuoai-docs/products/huahuo-ai/05-api` 文档核对。没有访问线上服务器；本地代码不等于已部署版本。

包内 `backend_reference/` 保留这些参考的原始内容与文件来源。需要复现当前客户端行为时，优先对照包内客户端、对应后端实现和测试；遇到冲突应由接口负责人确认，不应照搬旧文案猜测。

已发现的文档问题：

- `06-agent-chat-api.md` 有未解决的 Git 合并标记；原文保留，不替用户解决或伪造最终协议。
- `05-media-recording-asr-api.md` 同时保留旧版“不提供实时转写/App 直连 ASR”描述，以及新增实时会话路由。当前前后端代码实际支持后端授权后由 App 原生腾讯 SDK 使用临时 STS 凭据做实时识别；不是把长期密钥放在 App，也不是只有录音后异步上传。
- 路由目录和 `reports/api-integration/API_INTEGRATION_INDEX.md`（Flutter 工作区相对路径）的标记不能代替当前调用链。全量文档中的其他历史差异由 `PACKAGING_REPORT.md` 标记，完整冲突位置列在 `DEPENDENCIES.json`。

## 1. 公共请求层

- 业务路径前缀 `/api/v1`；鉴权为 `Authorization: Bearer <access-token>`。
- 沿用 `ApiClient` 的公共头、客户端/设备信息、语言、trace/request 标识和会话刷新逻辑。
- 需要幂等的写请求使用 `X-Idempotency-Key`；重试同一业务提交保留同一键，不能在网络结果未知时盲目重发不同键。
- 普通 JSON 包络为 `{ "success": true, "data": ... }` 或 `{ "success": false, "error": ... }`；SSE 是单独流式传输，不是反复拼接普通 JSON 响应。
- 完整字段解析和兼容行为以 `Flutter/packages/huahuo_api/lib/src/api/`、`Flutter/src/lib/features/chat/data/chat_api.dart` 与 `transcription/data/live_transcription_api.dart` 为准。

## 2. 会话与消息

| 方法/路径 | 当前实现用途 |
| --- | --- |
| `GET/POST /api/v1/chat/threads` | 列表与创建会话 |
| `GET/PATCH /api/v1/chat/threads/{threadId}` | 会话详情、历史和标题元数据 |
| `POST /api/v1/chat/threads/{threadId}/messages` | 提交 Agent 结构化输入，接收 Run 回执 |
| `GET /api/v1/chat/threads/{threadId}/events` | 会话增量进度，`afterSequence` 游标 |
| `GET /api/v1/chat/threads/{threadId}/runtime-invocations` 及 `/latest`、`/{agentRunId}` | 执行过程/摘要 |
| `POST /api/v1/chat/threads/{threadId}/voice-messages` | 原有录音资源消息链路，区别于实时转写文字草稿 |

文本消息使用公开 `agentProfileId` 与结构化 `input.content`。示意：

```json
{
  "agentProfileId": "<从自己的后端 Agent Profile 列表取得的 ID>",
  "input": { "content": [{ "type": "text", "text": "你好" }] }
}
```

媒体/文件不能只塞本机路径：需经媒体上传/完成接口取得服务端资源身份，再按现有 `ChatContextEnvelope`、附件上传器与结构化输入映射发送。不要自行提交内部模型、密钥池、Skill 路径或 Runtime 配置。

提交成功主要意味着任务已接收；`agentRunId`、Run 终态与同 thread 持久化 Assistant 消息共同构成完成链路。不要把临时 delta 或一个成功 HTTP 状态码保存为最终答案。

## 3. SSE 与回退

| 方法/路径 | 用途 |
| --- | --- |
| `GET /api/v1/agent/runs/{agentRunId}` | Run 状态/结果投影 |
| `GET /api/v1/agent/runs/{agentRunId}/events` | 按序事件回读 |
| `GET /api/v1/agent/runs/{agentRunId}/events/stream` | SSE 事件流 |
| `POST /api/v1/agent/runs/{agentRunId}/cancel` | 取消运行 |
| `POST /api/v1/agent/runs/{agentRunId}/confirm` | 需要确认的运行续接 |

客户端 `AgentRunClient.eventStream` 带 `Accept: text/event-stream`，以 `afterSequence` 和可选 `Last-Event-ID` 恢复游标。保留 SSE 解析器对跨网络块、事件边界和错误的处理。事件 payload 的完整模型保留在 `domain_clients.dart`，不能随意缩减成一个字符串 delta。

`ChatRunTracker` 管理连接、静默超时、重连、备用轮询、终态与检查点，`ChatThreadProgressPoller` 补会话进度，`ChatStreamRevealBuffer` 只负责 UI 呈现。代理层不能缓冲整个响应；后端当前设置 `text/event-stream`、`Cache-Control: no-cache, no-transform` 和 `X-Accel-Buffering: no`。新工程后端/网关需要提供等价的非缓冲行为。

## 4. 腾讯实时 ASR

创建会话：`POST /api/v1/realtime-asr/sessions`，需要 App Bearer token 和幂等头；请求为空对象，或仅带可选 `voiceprintProfileId`。客户端要求安全 HTTPS 服务地址。

当前后端 `RealtimeASRSessionResponse` 的 data 形状：

```json
{
  "sessionId": "<session-id>",
  "appId": 123456,
  "projectId": 0,
  "expiresAt": "<UTC ISO-8601>",
  "temporaryCredential": {
    "tmpSecretId": "<temporary-id>",
    "tmpSecretKey": "<temporary-key>",
    "token": "<sts-token>"
  }
}
```

这些只是字段示意，不是可用凭据。后端 `realtime_asr_service.go` 从腾讯 STS 签发临时凭据，客户端 `LiveAsrSessionCredential` 校验后仅以内存对象转发 native start 参数；不要打印、持久化或让通用幂等响应缓存存储它们。

完成会话：`POST /api/v1/realtime-asr/sessions/{sessionId}/complete`。无客户端计费时长或结算金额；后端按自己保存的会话区间/过期时间计算用量并幂等结算。客户端保留结束回报、停止/失败清理和重连会话处理。

接收方后端需要：鉴权/工作区归属检查、ASR 配额/额度、腾讯实时模型和受控凭据池、STS 授权、过期策略、会话记录及 completion 幂等。只实现一个返回假 token 的接口无法复现真实转写。

## 5. 参考范围

`backend_reference/huahuoai-all/` 提供选定路由、服务、领域模型、持久化及 STS provider 参考；其余后端依赖、部署、数据库迁移和生产密钥不在此交付范围。`backend_reference/api_docs/` 保留完整 App API 文档目录，供附件、鉴权、工作区、权限等边界查询。
