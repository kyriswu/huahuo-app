# Provider-neutral assistant runtime migration

## Objective

让 Flutter 只依赖项目自己的稳定助手协议和产品语义，保留当前功能行为，
为以后将项目后端上游从 OpenClaw 切换到 Coze 或 Dify 留出适配空间。

## Evidence

- Flutter 源码调用的是 `/api/v1/chat/*`、`/api/v1/agent/*` 项目接口。
- 未发现 Flutter 直接引用 OpenClaw、Coze 或 Dify SDK/endpoint。
- 当前 `ChatRepository` 已隔离 Controller，但仍暴露 `agentProfileId`、
  `AgentRunSnapshot`、`agentRunId`、SSE wire payload 和 `ApiResult`。
- Graphify 和源码搜索均显示 Controller 没有直接依赖 `data/chat_api.dart`；
  这条边界继续保留。

## Scope

本计划只迁移客户端聊天运行契约和其测试，不改变服务端字段、认证、数据、
Provider 配置或产品功能。图片下载、录音和其他媒体通道保持独立。

## Steps

1. 定义 `AssistantConversationRepository`、`AssistantRunHandle`、中立状态、
   增量事件、失败和 capability 模型。
2. 增加 fake provider contract tests，覆盖流式增量、polling fallback、
   取消、幂等、网络结果未知、最终结果回读、需要用户输入和错误映射。
3. 将当前项目协议实现命名为 `RemoteProjectChatRepository` 与
   `ProjectChatClient`，把 DTO 到中立模型的映射集中在 data 层。
4. 迁移 `ChatController`、`ChatRunTracker`、progress poller 和 onboarding
   适配器到中立事件；保留短期兼容 barrel。
5. 运行 formatter、analyzer、聚焦聊天测试和 Graphify impact review；通过后
   删除无消费者的旧契约和兼容出口。

## Acceptance

- Page 和 Controller 不导入 `AgentRunSnapshot`、`agentProfileId` 或厂商字段。
- Repository interface 不依赖 `huahuo_api` wire DTO、SSE payload 或 Flutter。
- 用 fake Provider 替换远程实现时，Controller 行为测试无需改变。
- 项目后端 Provider 变化不要求修改 Flutter 页面和状态机。
- 当前协议行为、幂等和未知结果语义保持不变；静态检查不代替后端联调。

## Risks and rollback

最大风险是把当前后端的进度/运行状态误认为所有 Provider 都具备的语义。
因此能力差异必须显式建模。每一步保持兼容入口，验证失败时只回滚本计划
的客户端契约变更，不恢复或修改服务器数据。

## Progress

### Tracker read migration slice

将 Tracker 的读取依赖直接切换为 `AssistantRuntimePort`；旧测试端口通过测试桥接
保留回归覆盖，不在业务状态机里新增双通道分支。补充中立读取 lease、工具记录和
独立的已落库消息标识，保持暂停取消、迟到响应隔离、终态回读与 File-Agent 工具
记录补充的行为。生产装配使用 RemoteProjectAssistantRuntime；工具记录的旧 UI/
checkpoint 投影暂留在应用层单一转换点，不改数据库格式、页面或原生代码。

验证：远程 DTO 映射、取消 lease、无正文的终态消息、新端口 fake 的暂停/恢复及
错误回读；现有 Tracker、Controller 与 onboarding 回归、analyzer 和前后影响检查。
回滚仅撤销此读取切片，不触碰当前工作树其他重构。后端依据为本地只读快照
`agent_run_service.go` 的公共投影及共享包 PublicAgentRun parser；不声称线上验证。

- [x] `ChatRunTracker` 生产装配优先使用 `AssistantRuntimePort`；旧
  `ChatAgentRunPort` 仅作为未注入中立运行时的兼容回退。
- [x] 中立快照补充工具记录、终态输出标识和可取消 read lease；Tracker 在单一转换点
  投影到现有 checkpoint/UI 工具记录模型，旧端口对象身份保持兼容。
- [x] 新增中立 Tracker 优先级合同测试；Tracker 全套 63 项通过，完整 lib/test
  analyzer 无错误（仅既有 423 条 lint info）。
- [x] 项目运行时的 read、lease、SSE 入口统一保留原有项目运行句柄校验；无效句柄
  在 transport 前拒绝，adapter 合同测试通过。


- [x] 定义第一版 `AssistantRuntimePort`、运行状态、输出、失败和不透明运行句柄。
- [x] 增加 `RemoteProjectAssistantRuntime`，将当前项目 Agent Run wire DTO 映射到
  中立模型。
- [x] 将聊天远程实现正式命名为 `RemoteProjectChatRepository`，并移除 `ChatApi`
  及 `ChatApiPort` 迁移期别名。
- [x] 增加中立 `AssistantStreamEvent` 和流端口；项目 SSE 及 Tracker 兼容路径均
  映射到中立事件，gap、capacity 和 draft delta 语义保持不变。
- [x] Chat Run Tracker 聚焦套件 63 项通过；旧 wire stream 仍可作为兼容回退，生产
  装配优先使用新的项目运行时流端口。
- [x] 增加中立 `AssistantProgressPage` / `AssistantProgressEvent` 和轮询端口；
  `ChatController` 优先读取中立进度，旧进度端口继续兼容。
- [x] 进度轮询测试 4 项、项目进度适配器测试 4 项通过；目标 analyzer 无错误，
  源码可达性保持 448/448。
- [x] 将 onboarding 首次定位流程切换到中立运行端口；旧聊天 Tracker/Controller
  仍保留兼容协议，避免一次性扩大迁移范围。
- [x] 目标 onboarding 测试 22 项通过；目标文件 analyzer 无错误；源码可达性为
  448/448 文件。
- [x] 聊天 Controller 套件的端口兼容回归完成；124 项中 123 项通过。剩余失败可
  单独稳定复现为既有测试 fake clock 的 `List.removeAt` 耗尽，不是本切片的失败。
- [x] 收紧项目 progress adapter 的字段边界：`messageId`、`runId`、显示文本和增量文本
  在 data 层校验，异常字段整页拒绝；轮询入口使用不透明 `AssistantRunHandle`。
- [x] 变更后 Graphify 已刷新；`AssistantThreadProgressPort` 的生产装配、Controller、
  项目适配器和测试消费者均可追踪。源码可达性仍为 448/448 文件。
- [x] 合并 Controller 中旧 progress 与中立 progress 的共享生命周期保护；两种读取方式
  只保留各自的 data adapter，避免重复处理并发、线程切换和 SSE 抢占逻辑。
- [x] 移除 `ChatApi`、`ChatApiPort` 兼容名称以及 `chat_api.dart` 的旧 domain barrel；
  所有源码、测试和集成探针显式依赖 `ChatRepository` 或
  `RemoteProjectChatRepository`。契约测试通过，分析器无错误，Graphify 刷新为
  45,552 nodes / 67,283 edges，源码可达性保持 448/448。
- [x] 将 positioning 更新仓库和 onboarding 的运行归属校验迁移到
  `AssistantRuntimePort`；中立快照补充可选 `workspaceId`，生产 tracker 不再注入
  旧 `ChatAgentRunApi`，bootstrap 只装配项目中立 runtime。
- [x] `ChatController` 的 Run readback 优先走 `AssistantRuntimePort`，在单一投影点
  映射页面仍需的安全工具轨迹和终态错误码；随后已删除旧运行端口及其生产回退。
- [x] `ChatController`、`ChatRunTracker` 的生产读取和 SSE 入口已完全切换到
  `AssistantRuntimePort` / `AssistantRuntimeStreamPort`；删除 `ChatAgentRunPort`、
  lease/stream 旧端口、`ChatAgentRunApi`、不可用实现和 `chatAgentRunApiProvider`。
  运行状态和 SSE wire DTO 只在 `RemoteProjectAssistantRuntime` 与测试桥接中映射；
  Repository 仍保留当前发送响应所需的项目协议解析。
- [x] 线程进度回退也统一使用 `AssistantThreadProgressPort`、
  `AssistantProgressPage` 和 `AssistantProgressEvent`；删除
  `ChatThreadProgressPort` 及其旧 data-layer parser，Controller 不再从
  `ChatRepository` 运行时类型探测进度能力。
- [x] 迁移 Controller、Tracker、SSE 及 API 映射测试装配到中立 runtime；Tracker
  聚焦测试 64 项通过，Controller/API 组合 170 项中 169 项通过，剩余 1 项是
  既有 fake clock 的 `List.removeAt` 耗尽（已在迁移前记录）。完整 `dart analyze`
  无 error，Graphify 刷新为 45,567 nodes / 67,252 edges。
