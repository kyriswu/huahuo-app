# Flutter 项目架构审计（2026-10-03）

## 结论

项目现在可以继续迭代，但架构的主要问题已经不是目录命名，而是所有权和依赖方向失控。移动端有一个同时装配几乎所有业务的组合根，`ui_v3` 是多个领域共用的垃圾桶，桌面端有一个 13,000 行级别的万能工作区，API 和原生桥接仍有巨型中心文件，页面和 feature 内部还存在独立网络客户端与轮询。

当前应按模块化单体重构：先建立业务能力边界，再逐步删除重复入口。没有证据表明现在需要拆成微服务；真正需要的是让 `Page → Controller → Repository → API Client → Transport/Storage/Native Adapter` 依赖可验证。

## 审计范围和证据

- 基线提交：`ab3083b4b998205e651a183ec0be85754c9f5c37`。
- Graphify 0.9.73：扫描 `1,086` 个代码文件，生成 `45,193` 个节点、`67,252` 条边。图是发现依赖的证据，不能替代 analyzer、源码搜索和测试。
- 架构检查：`Dart reachability 448/448`，同时报告若干跨层/页面副作用/轮询/预算问题；其中部分规则是债务提示或误报，不能直接按文字删除代码。
- Desktop analyzer 当前有 1 个已知错误：`desktop/lib/features/topics/data/desktop_topics_cache.dart:212:39` 引用了不存在的 `DailyTopicSourceRef.hotspotId`。根据仓库交接规则，现有 `desktop/` 已停放，不进入本轮 P0/P1；未来桌面需求按新的 JS 桌面壳应用重新评估。
- 未访问或修改服务器，未把 Simulator、mock 或静态清单当成真机/生产证据。

## P0：必须先处理

### 1. `app_providers.dart` 是服务定位器和组合根瓶颈

`src/lib/app/bootstrap/app_providers.dart` 有 `2,913` 行、约 `177` 个 provider，直接连接 API、数据库、存储、原生、聊天、录音、通知、工作区、账单等能力，Graphify degree 为 `483`。这让依赖从 import 和构造函数中消失，账号/工作区 scope、生命周期和长任务容易被全局 provider 混在一起。onboarding controller 的直接反向导入已移除，但部分页面仍依赖全局装配。

处理：拆成 runtime、session、chat、recording、recording-card、ingestion、notifications、workspace/knowledge、billing 等 composition module。app 只负责组合和 override，feature 只暴露 port 和状态。

### 2. `ui_v3` 不是 feature

`src/lib/features/ui_v3` 有 `202` 个 Dart 文件、约 `144,091` 行，目录同时承载知识库、创作画布、数字孪生、工作台、定位、资料导入、录音、账户和订阅。源码 import 聚合显示跨 feature import 约 `232` 条，其中涉及 presentation 的约 `137` 条；移动业务形成包含 `ui_v3`、chat、recordings、recording_card、ingestion、notifications、onboarding、book_work 的大环。

处理：冻结继续向 `ui_v3` 添加业务；按 knowledge、creation、workspace、digital_twin、positioning、ingestion、recordings 等能力迁移。公共视觉组件才进入 shared UI，跨域流程使用公开 application port 或明确 coordinator。

### 3. 桌面 `EditorWorkspace` 是第二个组合根（延期）

`desktop/lib/features/editor/presentation/editor_workspace.dart` 有 `13,392` 行，依赖 agent、assets、auth、book_work、calendar、chat、creations、digital_twin、documents、home、integration、navigation、notifications、positioning、proposals、recordings、support、topics、workspaces 等大量领域。页面同时持有布局、导航和跨域业务状态，无法局部测试。

处理：本轮不修复、不拆分现有桌面实现。若桌面重新成为产品需求，直接以共享契约为边界设计新的 JS 桌面壳应用；不继续给当前 `EditorWorkspace` 堆补丁。

### 4. 当前质量门禁不能作为唯一架构证明

检查会报模块超限、页面副作用、缺少性能 RFC、resident provider reason、跨层依赖、手写 `part` 和 stream 误报。应把输出分为 error/warning/needs-review；真正的编译错误和行为测试优先，不能简单提高预算或按正则删除正确的取消逻辑。

## P1：影响后期迭代的结构问题

### 5. API 机制统一得不完整

`packages/huahuo_api` 有统一 `HttpApiTransport`，但 feature 内仍直接创建 `HttpClient`：

- `src/lib/features/chat/data/chat_api.dart`
- `src/lib/features/ui_v3/data/voiceprint_api.dart`
- `desktop/lib/features/chat/data/desktop_resource_image_cache.dart`

这些路径可能绕过超时、认证策略、trace、错误映射、取消、指标和重试规则。应保留统一 transport 机制，但为聊天、媒体下载、声纹等提供明确专用适配器；签名 URL 不应默认带主服务认证头。

API 还有四个中心大文件：`api_client.dart`（1,745 行）、`domain_clients.dart`（3,536 行）、`contract_models.dart`（4,402 行）、`endpoint_catalog.dart`（1,471 行）。它们把 recording card、workspace、agent/chat、订阅、book work 等协议混在一起。应按业务域拆 client、wire DTO、parser，保留公共认证、取消、幂等、错误和诊断机制。

### 6. 聊天协议仍暴露上游实现概念

客户端仍能看到 `AgentProfileCatalogItem`、`AgentRunRequest`、`AgentRunClient`、`agentProfileId`、`agentRunId` 等类型或字段。将来从 OpenClaw 切到 Coze/Dify 时，如果这些类型进入页面或 Controller，迁移会扩散到整个 UI。

目标链路：

```text
Page → ChatController → AssistantConversationRepository
     → AssistantRuntimePort → ProjectChatClient → provider adapter
```

Flutter 长期只保留 Conversation、Turn、RunHandle、Status、StreamEvent、Output、Failure、Capability 等产品语义；provider 字段停留在协议适配器。

### 7. 长任务和轮询所有权分散

虽然已有 `TaskOrchestrator` 和 `OrchestratedPoller`，页面和 feature 仍分别创建轮询；例如 account profile、assets、positioning report/progress、transcription detail、work AI task 等页面直接持有 poller。`recording_card_auto_sync_coordinator.dart` 在未注入时还会自行创建 `TaskOrchestrator`。这些是重复请求、迟到结果和作用域泄漏的风险点；尚未通过运行测量证明发生，已有取消和 scope 保护应逐一核验。

处理：调度器只负责资源和取消；业务状态机负责转移；repository/ledger 负责持久化；页面只订阅状态。统一 task key、scope、generation、backoff、取消和恢复。

### 8. 原生 Recording Card 边界过度集中

`recording_card_controller.dart` 有 `12,393` 行，Dart native port 有 `3,459` 行，iOS bridge 有 `8,697` 行；它们混合 BLE、Wi-Fi、绑定、扫描、目录观察、文件传输、同步 ledger、协议编解码、事件和生命周期。

处理：拆成 typed port、protocol、connection session、BLE/Wi-Fi transport、directory observer、transfer session、ledger 和 native adapter。保留连接 epoch、乱序事件过滤、断点恢复；真机证据和离线协议测试分开记录。

### 9. 存储和通知边界不清

移动端同时有内存读模型、JSON/SQLite snapshot 和 database worker 的 outbox/inbox/checkpoint；这不是“都有所以删一个”，而是尚未把生产写入权威、恢复语义和迁移责任说清楚。通知 `pending_message_projection` 横跨聊天、onboarding、ingestion、recording、canvas、digital twin 等域，容易变成跨域命令中心。

处理：声明每类数据的写入 owner、事务边界、缓存语义和账户隔离；通知层只接收公开 contribution/acknowledgement port，刷新和结算交给任务结果协调器。

### 10. 共享包和 core 有反向依赖风险

`core/native` 存在导入 feature domain 的端口，破坏 `core → feature` 的层级方向；`huahuo_product` 同时包含领域、application、remote repository 和 feature catalog，职责需要按真实的双端消费者重新划分。共享包不能反向依赖 app；没有第二个真实消费者的代码不应提前抽成通用包。

## P2：性能和维护成本风险

- 普通 API 请求和若干媒体路径把完整响应/字节流读入内存，大 JSON、图片、录音和上传可能造成峰值；需要分页、大小上限、流式传输和独立资源预算。
- `ui_v3` 页面和组件过大，`v3_chat_page`、`v3_creation_canvas_page`、数字孪生和录音库页面容易扩大 rebuild 范围；状态应切成小的 immutable view state 和局部订阅。
- provider 图过大，作用域或前台恢复时可能重建大量对象；按 feature composition 和 account/workspace scope 懒加载。
- 页面级 `Timer.periodic`/poller 多，可能重复请求和后台耗电；长任务必须由 durable owner 管理。
- 图片、音频、图谱、录音缓存缺少统一的容量、TTL、LRU 和 scope 预算；缓存与不可丢失数据要分开。
- 原生 event stream 需要背压、采样、session/generation 过滤和 dispose；否则高频录音/传输事件会放大 Dart rebuild 和队列。
- 数据库、大 JSON、媒体处理需要在可测量后决定 isolate/worker；不能先引入线程抽象再猜性能。

## 可以删除、应迁移、必须保留

### 完成核查后可以删除

- 历史报告中已经过期的状态描述；当前 `ApiIntegrationReportEntry` 已移除，报告工具已改名，无需再次执行。
- 没有调用方、没有公开导出、没有测试替身依赖的 retired/prohibited endpoint 空壳和专用模型。
- 所有消费者迁移后的 `core/api` 宽泛兼容 export、重复 route/provider 入口。`ChatApi` 类已退役，现有 `chat_api.dart` 文件承载真实 Repository 和媒体适配器，不能按旧文件名直接删除。
- 已迁移能力在 `ui_v3` 和桌面万能 editor 中的旧页面/旧 adapter。
- 仅为重复文件写入机制的 desktop JSON store 实现；保留领域编码，合并可靠替换、备份和串行写机制。

### 现在先迁移，不直接删除

- `app_providers.dart`、`app_routes.dart`、`domain_clients.dart`、`contract_models.dart`：它们仍是运行时入口，必须先迁消费者。
- `backend_contracts`：已完成迁移。workspace retry 现在由 `features/workspace/data/workspace_recovery_repository.dart` 持有；旧聚合包装、模型、测试和专用质量门禁已删除。
- `TaskOrchestrator`、outbox/checkpoint、恢复 coordinator、schema migration：它们承载取消、恢复和数据保护。
- Recording Card Dart/native bridge：先有协议 fixture、迟到回调和真机验证，再删兼容路径。

### 不应因仓库大而删除

- `vendor/jpush_flutter`、`third_party/sqlite`、lockfile、构建配置和原生协议测试。
- 数据库 migration、golden/行为测试、合法测试 fixture、应用资产。
- `huahuo_api` 的统一 transport、认证/错误/幂等机制和按域 client（应拆文件，不应另起第二套 API 框架）。
- 本地可再生成的 `.dart_tool`、`build`、`graphify-out`：它们不进 Git；是否删除只是本机清理，不是架构重构。

## 推荐顺序

1. 固定移动端检查基线，整理架构检查的误报分类；桌面错误延期。
2. 冻结 `ui_v3` 和万能组合根，拆 `app_providers`/路由。
3. 以 Chat 垂直切片验证 `Page → Controller → Repository → API Client`，统一 feature 网络入口并隔离 provider。
4. 拆移动端 `ui_v3` 和通知投影；现有桌面 editor 不进入本轮。
5. 明确数据库/任务/缓存 owner，再拆 Recording Card 原生桥接。
6. 最后删除已验证无消费者的退役接口、兼容出口和旧路径。

每一步都要运行 format、analyzer、聚焦测试和 Graphify/source impact review；涉及 native、存储、长任务或协议时，增加专项测试，不能只看目录结构。

## API Integration 的准确含义

当前应区分运行时、契约检查与历史报告：

1. `huahuo_api` 的运行时 client、transport、认证、幂等和解析，是真正被 App 调用的代码，应保留并按域整理。
2. `ApiContractManifest`/`EndpointCatalog` 的契约和端点元数据，用于静态一致性和运行时策略，不等于服务器联调。
3. 当前工具已是 `src/tool/api_contract_consistency_check.dart`，明确标注 `offline_metadata_only`、`networkExecuted: false`、`testsExecuted: false`。历史报告仍可能使用旧标题，应视为历史快照。真实 HTTP/SSE 联调需要显式 opt-in 测试和环境证据。

## 已完成事项与证据限制

旧审计中的报告改名、report-only DTO 清理、`ChatApi` 类退役和 onboarding controller 直接导入组合根的问题已有改进，不重复列为未完成重构。中立助手端口及适配器也已存在，下一批应检查剩余消费者和映射边界，不重新创建一套接口。文件规模和依赖环证明维护风险，不证明卡顿；性能结论需要后续 profile 的响应大小、峰值内存、帧耗时和请求频率数据。

本轮复核：移动架构检查可达 448/448，仍有债务发现；桌面 analyzer 错误按范围约束延期。`recording_waveform_controller` 的取消误报经源码复核：`_cancelSubscription()` 调用 `subscription.cancel`。未重新执行全量测试。

## 当前判断

项目不需要继续堆 provider、service locator、万能 editor 或第二套网络框架。最有价值的下一步是先完成移动端批次 0：建立可信架构 gate，然后用 Chat 做一条完整的垂直切片；该切片成功后再复制到录音、知识库和 Recording Card。
