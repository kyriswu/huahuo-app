# iOS 模拟器普通聊天专项测试报告

## 1. 测试信息

- 时间：2026-08-02 01:32-01:51（Asia/Shanghai）。
- 模拟器：iPhone 17 Pro，iOS 26.5，UDID
  `DC53F410-8577-4601-BC10-70A7BB931E04`。
- App：当前 `Flutter-Desk-Mobile` 工作树重新执行 Xcode Debug 构建并覆盖安装，
  不是模拟器中原有旧包。
- 主业务 API：`https://chuda.cc`，对应 39.107.250.25。
- 录音 API：`https://recording.chuda.cc`，对应 101.201.70.18。
- 测试范围：普通文本聊天的进入、历史线程、创建新线程、发送、失败状态、时间显示、
  错误提示和服务分流。
- 禁止范围：没有调用 Work AI/Feed AI 禁止端点。

## 2. 结论

普通聊天当前不能正常返回 AI 结果。

旧线程和新建线程均能进入；新线程也能创建，但发送文本后稳定返回业务错误
`META_WORKSPACE_UNAVAILABLE`，没有进入正常 Agent/模型回复阶段。新线程复现说明问题
不是旧线程 Workspace 绑定或历史数据损坏，而是 39 主站对普通聊天所需
`renshe_content` Meta Workspace 的统一 admission 阻塞。

101 不负责普通聊天。本轮聊天发送时没有出现录音、实时 ASR 或 Voiceprint 请求；101
只在 App 启动时承担自己的 Voiceprint 列表读取。普通聊天失败应由 39 的 Agent Catalog、
release、entitlement 和 Runtime mapping 链路处理。

## 3. 模拟器证据

### 3.1 当前源码重新构建

当前包重新构建后直接恢复真实登录态并进入思想图谱。图谱远端仍显示服务端不可用，
但交互式图谱本体正常渲染。

![当前源码构建启动](/Users/run/huahuoai-app/Flutter/reports/simulator-chat/2026-08-02/02-current-build-launch.png)

### 3.2 现有会话发送

现有会话中的普通文本发送失败，消息气泡保留发送时间和“发送失败”，页面收到
`META_WORKSPACE_UNAVAILABLE`，没有伪造 assistant 回复。

![现有会话失败](/Users/run/huahuoai-app/Flutter/reports/simulator-chat/2026-08-02/05-chat-after-send.png)

### 3.3 新建会话发送

点击“新建会话”后在空会话发送普通文本，仍返回相同错误。该分支排除了旧线程绑定、
旧消息内容和历史别名造成的影响。

![新会话失败](/Users/run/huahuoai-app/Flutter/reports/simulator-chat/2026-08-02/06-new-thread-after-send.png)

### 3.4 客户端错误提示修复

原页面直接显示服务端英文 wire code，属于客户端错误展示问题。本轮保持真实失败状态，
仅将其转换为“普通聊天服务尚未准备好，请稍后再试。”。失败消息、发送时间和输入草稿
均保留，方便用户重试；仍未生成本地假回复。

![中文失败提示](/Users/run/huahuoai-app/Flutter/reports/simulator-chat/2026-08-02/07-localized-failure.png)

## 4. 请求合同核对

当前普通聊天发送：

```text
POST /api/v1/chat/threads/{threadId}/messages
input.content[] = [{type: text, text: <用户输入>}]
expectedMetaWorkspaceKey = renshe_content
```

固定 Docs commit `97e510c8` 的 API 19 规定：

- `input.content[]` 是正式统一输入结构。
- `expectedMetaWorkspaceKey` 是已安装客户端允许的兼容选择字段。
- `renshe_content` 是普通/人设聊天的公开逻辑 key。
- key 缺失、未发布、非公开、无资格或输入不兼容时，服务端必须 fail-closed，不得自动
  改选默认 Agent、内部 Agent 或 Work AI。

因此当前请求不是 malformed request：主机、method、path、认证、幂等和
`input.content[]` 都正确，兼容选择字段也被 API 19 允许。39 返回
`META_WORKSPACE_UNAVAILABLE` 而不是 `BAD_REQUEST`/解析错误，也证明部署服务已经解析
请求并进入 Meta Workspace admission。

但是当前接线还不是计划要求的最终形态。API 19 明确规定新 App 工作应使用
`agentProfileId`；附件路由表也要求普通人设聊天每轮发送：

```text
agentProfileId = renshe_content
skillProfileIds = [renshe_content_creation]
```

当前 `ChatApi` 没有发送这两个字段，也没有在发送前用 Agent/Skill Catalog 验证
selectable/installed/enabled/available，而是继续依赖只供已安装旧客户端兼容的
`expectedMetaWorkspaceKey`。这是客户端 API 迁移尚未到位，但不是本次 422 的唯一根因：
此前线上审计已经证明 39 也缺少 `renshe_content` 的有效公开 publication；只改客户端
选择字段仍无法得到真实回复。

把客户端改回内部 Agent 名、隐藏 Prompt、旧顶层 `content` 或 Work AI 路由都不是
正确修复。正确顺序是后端先发布公开 Catalog/release，客户端再切换到显式公开
Profile/Skill 并做目录预检，最后共同复测。

本机 Backend 工作树不能直接作为 39 部署真相：其当前 `SendTextMessageRequest` 仍只
声明旧 `content/expectedMetaWorkspaceKey`，与固定 Docs 和已经接受 `input.content[]` 的
线上行为不一致。修复服务端时必须从 39 实际 release 对齐，不能直接部署本机脏分支。

## 5. 39 服务端根因范围

固定 Backend 代码中，`MetaWorkspaceAdmissionService` 会依次：

1. 加载并校验 Runtime planning manifest。
2. 读取当前用户 membership/feature entitlement。
3. 在公开 Catalog 中解析 `renshe_content`。
4. 校验不可变 Agent release 与 Runtime mapping。

任一环节失败都会返回 `META_WORKSPACE_UNAVAILABLE`。此前线上详细审计已经发现：

- 公开 Agent/Meta Workspace 列表只暴露禁止领域 `work_ai`。
- `renshe_content` Skills/Models 返回空列表。
- 数据库仍使用 `agent_renshe_neirong` 等内部 ID，缺少公开 ID 映射和有效 publication。
- 当前 publication 层只有 `agent_work_ai` 等少量旧发布事实。

结合本次旧线程和新线程稳定复现，根因位于 39 的 Agent 发布/admission 配置，而不是
Mobile 文本序列化、iOS 网络、登录 Token、线程历史或 101 ASR 服务。

## 6. 101 分流观察

当前构建明确配置：

- `HUAHUO_API_BASE_URL=https://chuda.cc`
- `HUAHUO_RECORDING_API_BASE_URL=https://recording.chuda.cc`
- 实时转录使用 recording base URL。
- Voiceprint Gateway 使用
  `https://recording.chuda.cc/voice-gateway/`。

App 首次启动时 Voiceprint 列表曾返回 HTTP 404；热重启后相同 GET 返回 HTTP 200。
该现象需要在后续声纹专项测试中检查认证恢复或网关短暂状态，但它没有发生在聊天发送
时间窗内，也不是普通聊天错误的来源。

## 7. 客户端修复

修改文件：

- `Flutter/src/lib/features/ui_v3/presentation/v3_chat_page.dart`
- `Flutter/src/test/features/chat/v3_chat_page_test.dart`
- 对应 Mobile SCM 文档同步更新。

修复内容：

- 将 Agent/Meta Workspace 未发布错误显示为中文服务不可用提示。
- 为 `SERVICE_BUSY`、认证失效、网络超时和能力未开放补充稳定中文提示。
- 未知错误不再直接向用户暴露后端内部 code。
- 保持消息 `failed` 状态、输入草稿和重试能力。
- 不切换 Agent、不调用 Mock、不伪造 assistant message。

## 8. 后端修复与复测门槛

39 服务端需要：

1. 在公开 Catalog 发布 `renshe_content`，并绑定正式 Agent release。
2. 发布并启用 `renshe_content_creation`，补齐 Model 和 Runtime mapping revision。
3. 确保目标用户 entitlement 能解析该公开 key。
4. 验证 Catalog、admission、planner 使用同一不可变 revision/hash。
5. 清理 admission 失败遗留的 planning Run，并保证失败请求不产生新残留。

修复后必须在同一模拟器复测：

- 旧线程发送成功。
- 新线程首条消息成功。
- user message 和 assistant message 都有服务端时间。
- assistant message 持久化后刷新仍存在。
- AgentRun 达 terminal，event 和 usage 可读。
- 39 有 Provider downstream log，101 同一时间窗无聊天请求。
- 五个 Work AI/Feed AI 禁止端点仍为 0 次调用。

## 9. 最终判定

| 项目 | 结果 |
| --- | --- |
| 当前源码模拟器构建与启动 | PASS |
| 真实登录态恢复 | PASS |
| 普通聊天页面进入 | PASS |
| 历史消息及时间显示 | PASS |
| 新建普通会话 | PASS |
| 普通文本发送 | FAIL_BACKEND |
| AI 回复 | BLOCKED，无结果 |
| 101 服务分流 | PASS，未参与聊天发送 |
| 客户端中文错误提示 | FIXED_AND_SIMULATOR_VERIFIED |
| Work AI/Feed AI 禁区 | PASS，未调用 |

普通聊天目前不满足可用验收标准。客户端可修部分已经完成并在模拟器复验；业务恢复仍
取决于 39 主站发布可用的 `renshe_content` Agent/Skill/Model 与 Runtime mapping。
