# iPhone 录音、独白与聊一聊专项复测报告

## 1. 验收环境

- 日期：2026-08-01
- 真机：`run的iPhone`，iOS 26.5.2，UDID
  `00008030-00160CC92E7A802E`
- Mobile 主 API：`https://chuda.cc`
- 录音/ASR API：`https://recording.chuda.cc`
- 录音计算节点：101.201.70.18，仅作为当前测试阶段的录音与 ASR 服务
- Work AI/Feed AI：禁止接入，本次未调用对应五个禁区端点

## 2. 真机故障事实

本报告读取的是手机 App 容器内的实际 SQLite 诊断记录，并与 101/39
服务端请求日志按秒对齐，不是 Mock 结果。

### 2.1 录音卡上传并转写

- 19:09、19:10 的多次重试均在 `requestingToken` 后进入
  `tokenFailed`。
- 客户端最终错误为 `SERVICE_BUSY`，对应 101
  `POST /api/v1/media/upload-token` 的 HTTP 503。
- 旧的 `UNAUTHORIZED` 已经消失，说明主站 Token 联邦验证已经生效。

### 2.2 独白

- 麦克风权限、原生开始、原生停止、草稿校验、本地登记全部成功。
- 19:09 生成的 WAV 为 169 KB，完整保存在 App 私有录音目录。
- 自动上传同样在 `upload-token` 返回 `SERVICE_BUSY`；实时凭据接口
  `POST /api/v1/realtime-asr/sessions` 同时返回 HTTP 503。
- 所以独白不是 iOS 麦克风、录音文件或 Flutter 原生 Bridge 故障，而是与录音卡
  共用的 101 服务端 Workspace 镜像故障。

### 2.3 聊一聊

- `GET /api/v1/chat/threads?limit=20`：HTTP 200。
- `GET /api/v1/chat/threads/{threadId}`：HTTP 200。
- `POST /api/v1/chat/threads/{threadId}/messages`：HTTP 400。
- 服务端已部署版本支持正式 `input.content[]`，失败原因不是正文格式，而是 Mobile
  没有提交 API 19 要求的公开 Agent/Meta Workspace 选择。
- 即便发送成功，旧 Mobile 只显示 `poll_task`，没有自动刷新 thread detail，助手
  异步回复也不会及时进入当前消息列表。

## 3. 根因与修复

### 3.1 101 测试服务

主站 `/api/v1/me/status` 对 101 的六次联邦校验全部返回 HTTP 200。101 随后把
主站 Workspace 镜像为 `ready`，但其数据库约束要求完整产品 Workspace 必须具有
bootstrap receipt、系统文件夹、Positioning、五类固定资产和 Book 基线，因此事务在
COMMIT 阶段回滚：`Ready Workspace requires a committed bootstrap receipt`。

根据“101 当前仅需正常转写”的测试约束，只在 101 数据库关闭
`workspaces_ready_contract_check` 触发器。以下安全边界继续保留：

- 主站 Token 必须通过 HTTPS `/me/status` 验证；
- Token 用户、Tenant、Workspace 必须与主站响应完全一致；
- 上传、对象完成、Recording、ASR 和实时 ASR 仍要求认证与用户归属；
- 主站 39 的 Workspace 约束完全不变。

回滚式事务探针已经证明联邦影子用户可创建 `ready/default` Workspace；测试用户与
Workspace 随事务回滚，没有留下探针数据。

### 3.2 Mobile Chat

- 普通聊一聊和个人 IP 使用公开 `renshe_content`；
- 获客使用 `huoke_content`；
- 视觉对话使用 `visual_chat`；
- 代表作使用 `self_media_creation`；
- 未发布的深度定位、视频分析和社媒定位在 Transport 前返回
  `CHAT_AGENT_ROUTE_UNAVAILABLE`，不静默回退；
- 所有文本继续使用 API 19 `input.content[]`，不发送内部 Agent、Skill、Prompt、
  Token、本地路径或 Work/Feed AI 路由字段；
- `poll_task` 现在会进行最多 30 次、间隔 2 秒的 bounded thread-detail 刷新；出现
  新的服务端 Assistant Message 后停止并清除 pending 状态；超时后保留手动刷新入口。

## 4. 自动化结果

| 范围 | 结果 |
| --- | --- |
| Chat API/Controller/Page | 42 PASS，0 FAIL |
| 录音上传、独白、实时 ASR、录音卡自动同步 | 37 PASS，0 FAIL |
| Mobile 全量测试 | 1059 PASS，0 FAIL |
| 修改文件定向 analyze | 0 issue |
| Mobile 完整 analyze | 0 error、0 warning、174 info；低于 180 基线 |
| SCM 映射 | 622 active files，PASS |
| 101 测试级 Workspace 事务探针 | PASS，已 ROLLBACK |

## 5. 真机复测状态

修复版本已由当前 Xcode Workspace 安装并启动到上述真机。App 启动后自动恢复了
两条此前停在 `tokenFailed` 的本地草稿：

| 时间 | 接口 | 结果 |
| --- | --- | --- |
| 19:38:15 | 第一条 `POST /media/upload-token` | HTTP 200 |
| 19:38:16 | 第一条 upload complete | HTTP 200 |
| 19:38:16 | 第一条 `POST /recordings` | HTTP 200 |
| 19:38:16 | 第二条 `POST /media/upload-token` | HTTP 200 |
| 19:38:16 | 第二条 upload complete | HTTP 200 |
| 19:38:16 | 第二条 `POST /recordings` | HTTP 200 |
| 19:38:44 | 两条 Tencent 文件 ASR | `transcribed`，attempt=1 |

这证明真机的主站 Token、录音网关、对象上传、Recording 创建和 Tencent 文件 ASR
均已恢复。20:29 至 20:42 又完成了新独白与新聊一聊请求：独白最终文本生成成功，
但 Workspace Note 后处理被 `NOTE_NOT_FOUND` 阻塞；聊一聊发送到达 39 后返回
`META_WORKSPACE_UNAVAILABLE`。完整时间线、服务端根因和客户端轮询修复见
`../backend-interaction/latest-zh.md`。
