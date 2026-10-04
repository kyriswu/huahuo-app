# 架构重构执行计划（2026-10-03）

状态：进行中。该计划用于停滞项目的交接期重构，先收敛边界和所有权，再删除兼容代码。功能需求不在本计划范围内；除非迁移需要，保持现有协议和运行行为。

## 目标

- 把移动端和移动端使用的共享包整理成按业务能力划分的模块化单体；现有桌面端停放。
- 固化 `Page → Controller → Repository → API Client → Transport/Storage/Native Adapter` 的依赖方向。
- 让聊天领域只依赖项目自己的中立助手契约，以便将来切换 OpenClaw、Coze 或 Dify 时不改页面和大部分应用层。
- 为长任务、数据库、缓存、录音卡和原生通道建立唯一 owner。
- 核查剩余退役接口和兼容出口，删除已确认没有消费者的部分；已完成的报告工具清理不重复实施。

## 非目标和限制

- 不修改服务器、不修改后端字段、不进行生产联调写操作。
- 不为了“整齐”删除 schema/migration、恢复/outbox、协议 fixture、原生测试、构建输入或用户资产。
- 不以目录改名、文件变短或报告全绿作为架构完成标准。
- 迁移期间允许短期兼容入口，但每个入口必须有消费者、退出条件和删除批次。

## 当前基线

- HEAD：`ab3083b4b998205e651a183ec0be85754c9f5c37`，工作树干净，只有新的 `origin` 远程。
- Graphify 0.9.73：`1,086` 个代码文件，`45,193` 个节点，`67,252` 条边；输出在本地 `graphify-out/`，不提交。
- `ui_v3`：`202` 个 Dart 文件，约 `144,091` 行；它同时容纳知识库、创作、工作台、数字孪生、录音、导入、账户等多个业务域。
- `app_providers.dart`：`2,913` 行，约 `177` 个 provider，Graphify degree `483`。
- `app_routes.dart`：`1,945` 行；桌面 `editor_workspace.dart`：`13,392` 行。
- 统一 API transport 存在于 `huahuo_api`，但移动聊天、声纹和桌面资源图片仍有 feature 内部 `HttpClient`。
- 当前架构检查可达 `448/448` 文件，但会报告组合根、巨型模块、跨层依赖、页面副作用、轮询和预算/规则误报；它是整改清单，不是通过证明。
- Desktop analyzer 当前有真实错误：`desktop/lib/features/topics/data/desktop_topics_cache.dart:212` 使用了不存在的 `DailyTopicSourceRef.hotspotId`。

## 目标依赖

```text
Page
  ↓
Controller / ViewState
  ↓
Repository / Application Port
  ↓
Domain API Client
  ↓
Transport / Storage / Native Adapter
```

组合根只创建实现并注入依赖。领域层不依赖 Flutter、Riverpod、HTTP、数据库或平台插件；页面不导入别的 feature 的 `data` 或 `presentation`；跨 feature 只依赖公开 application port。移动端和桌面端保持独立，只有第二个真实消费者存在时才提升共享代码。

## 迁移批次

### 0. 固定可重复基线

1. 固定移动端 analyzer、format、依赖检查结果。现有 desktop analyzer 错误按仓库范围规则延期，不作为本轮 P0 阻塞项。
2. 把架构检查输出分为 `error`、`warning`、`needs-review`，先修误报，不通过扩大预算隐藏问题。
3. 冻结 `ui_v3`、`app_providers.dart`、`app_routes.dart` 和桌面 `EditorWorkspace` 的新增跨域职责。

退出条件：干净环境可以使用固定 FVM/lockfile 运行检查；真实编译错误为零；外部服务和真机检查有明确单独入口。

### 1. 组合根和导航

拆分 `app_providers.dart` 为 runtime、auth/session、chat、recording、recording-card、ingestion、notifications、workspace/knowledge、billing 等 composition module。拆分路由常量、extra codec、guard、shell 和 feature registrar。onboarding 不再导入 app composition。

退出条件：组合根只负责装配；feature controller 可用构造参数和 fake port 单独测试；无 `app → feature → app` 循环。

### 2. API 和聊天垂直切片

把 `domain_clients.dart`、`contract_models.dart` 和 endpoint 定义按业务域拆开，保留一个统一 transport 机制。先完成 Chat：

```text
ChatPage → ChatController → AssistantConversationRepository
         → AssistantRuntimePort → ProjectChatClient → provider adapter
```

`agentProfileId`、`agentRunId`、厂商 SSE/Workflow 字段只留在协议适配器；图片下载和签名资源使用独立媒体 transport。现有中立端口和 `RemoteProjectChatRepository` 已落地，继续检查剩余消费者；`ChatApi` 类已经退役，不重复创建替代接口。

退出条件：页面和 Controller 只看到 Conversation、Turn、RunHandle、Status、StreamEvent、Output、Failure、Capability 等产品语义；取消、重试、幂等、轮询回退和迟到结果有测试。

### 3. 业务域拆分

先从 `ui_v3` 提取知识/工作区、创作画布、数字孪生、定位、导入和录音相关能力，逐个迁移消费者后删除旧入口。通知投影只接收公开贡献和 acknowledgement port，不直接编排聊天、录音和导入。

退出条件：跨 feature 不再导入另一 feature 的 data/presentation；页面不创建网络、数据库或持久轮询副作用。

### 4. 桌面 editor（延期，不进入当前重构）

当前不处理 `Flutter/desktop`。如果以后桌面成为明确需求，使用共享契约重新设计 JS 桌面壳应用，不继续扩展现有 desktop 实现。

退出条件：另立桌面应用计划并完成平台边界评审。

### 5. 任务、存储和缓存

让 `TaskOrchestrator` 只负责执行资源和取消；业务状态机负责状态转移；repository/ledger 负责持久化；页面只观察状态。统一页面轮询、任务 key、account/workspace scope、generation、backoff 和恢复。明确 SQLite worker、snapshot/JSON 迁移、outbox/checkpoint 的唯一写入权威。

退出条件：路由切换不会产生重复轮询；账号切换和迟到结果可丢弃；写入失败、进程终止、旧 schema 升级和恢复有测试。

### 6. Recording Card 原生边界

把 Dart/native 桥接拆为 typed port、协议 codec、连接 session、BLE/Wi-Fi transport、目录观察、transfer session 和业务 ledger。保留连接 epoch、乱序回调过滤、断点恢复和真机验证。

退出条件：原生桥只做平台适配；连接、传输和账本各有一个 owner；Android/iOS 协议 fixture 与真机回归可分别追踪。

### 7. 删除和收尾

完成消费者、导出和测试替身核查后，删除剩余退役/prohibited 空壳、旧兼容 export、无消费者的旧路径和重复缓存实现。顶层目录和 package 重命名另开机械迁移批次，不与业务重构混做。

## 每批验收

格式化、静态分析、聚焦行为测试和 Graphify/source impact review 必须通过；涉及 native、存储、长任务或协议时增加专项测试。报告须说明哪些是离线证据、哪些需要真机或后端环境，不能把静态检查当作联调结论。

## 回滚

每批保持单一目的并单独提交；回滚只撤销当前批次。涉及数据格式或协议的批次必须先具备兼容读、恢复路径和退出条件，未满足前不得删除旧迁移。


## 2026-10-04：移动原生端口装配切片

分支：`refactor/mobile-p0-composition`。按用户补充要求，现有桌面源码和测试不修改，桌面错误不阻塞本轮；未来桌面采用 JS 壳，具体框架另定。

范围：将 8 个无业务编排的原生端口 provider 提取到 `app/di/native_port_providers.dart`，迁移移动生产代码、测试和 integration_test 的直接导入；不保留旧组合根重导出。provider 类型、构造闭包、常驻生命周期和 override 身份保持不变；不修改 Swift/Kotlin、通道协议和存储格式。

影响：导出/分享、文件选择、传入资料、截屏和权限消费者；录音 provider 依赖账户路径解析器，本批保留原位置。onboarding 页面仍有其他跨域依赖，不宣称完整拆环。Graphify 已对新模块与组合根执行 explain；启发式图含虚假语法符号，导入和回调另用源码与 analyzer 校验。

验收：所有 8 个符号只有一个声明，无旧兼容 export；移动 lib/test/integration_test 分析无新增 error/warning；原生端口离线测试、onboarding 页面和 AppRoot 回归通过；架构 gate 不新增本切片规则发现。现有全局 gate 债务单列，不扩大预算。

回滚：仅还原本切片的装配声明和消费者导入，不涉及数据迁移。桌面范围规则保留。

进度：8 个原生端口的声明与消费者已迁移，旧兼容 export 已移除；架构检查 449/449 可达，新文件无发现。离线回归 56 项通过、1 项 AppRoot 外观失败；隔离 HEAD 副本复现相同失败（mistBlue 期望 light，实际 system），本批未改主题行为或断言。


## 2026-10-04：认证装配切片

继续使用同一移动组合根分支。目标是 `authApiProvider`、`authControllerProvider`、`appBootstrapControllerProvider`；迁到 `app/di/auth_providers.dart`，全迁移 lib/test/integration_test 的消费者，不添加兼容 export。Graphify 已复查当前组合根；源码核实消费者为登录页、路由、启动恢复、离线认证/根页面测试及设备集成测试。底层仍依赖 core_provider_module，后续其业务耦合另拆。

只移动原有 provider 构造闭包，保留 read/watch、常驻身份、restore microtask 和错误处理；不修改请求字段、认证/同步行为，不执行设备或服务器测试。验收为移动 analyzer 无 error/warning，认证控制器、启动恢复、装配和根页面离线测试不新增失败，依赖检查无新增循环或新模块债务。回滚仅恢复 provider 所在库及消费者导入。

### 两个装配切片的结果

- 已提取原生端口 8 个、认证/启动 provider 3 个；全部消费者显式导入新模块，原组合根无兼容重导出。声明和 read/watch/override 生命周期保持不变。
- 登录页、onboarding 问卷页和声纹页移除对 `app_providers.dart` 的直接导入。其他消费者仍使用组合根中的未迁移业务；全局依赖环尚未清完。
- `app_providers.dart` 从 2,913 行降为 2,813 行。认证模块 57 行、原生端口模块 55 行；文件缩短仅作规模记录，不作为架构完成证明。
- 移动 `lib test integration_test` analyzer 退出 0，无 error/warning，422 条既有 info。最终登录页及两个新模块聚焦分析无问题。格式与 diff 检查通过。
- 最终两组互不重叠的离线回归共 187 项通过、2 项失败：认证/会话/装配/导航组 146 通过、登录 golden 1 失败；原生端口/根页面/onboarding 组 41 通过、主题断言 1 失败。最终登录页导入修改后单独重跑为 21 通过、同一 golden 失败，未重复计入总数。
- 两个失败均在隔离 HEAD 源码副本复现：mistBlue 的 ThemeMode 预期 light、实际 system；登录 golden 相同的 0.41% / 1457px 差异。本批没有改运行时外观、删除断言、放宽阈值或更新 golden。它们仍需独立基线修复，不声称全绿。
- 架构检查 450/450 文件可达，两个新模块无发现；全局检查仍退出 1，既有超限、反向依赖和其他债务未解决。Graphify 最终刷新为 45,527 节点、67,309 边，两个新模块及消费者经图与源码交叉复核；生成图未提交。
- 现有桌面代码和测试无 diff；设备集成测试只更新导入并静态分析，未执行真机或服务器操作。

本批代码迁移完成，但整体 P0 仍在进行。下一批先拆数据库/诊断装配的公共依赖，再拆业务 composition 与路由；不能把移到新文件视为已解决 core 对 feature 的反向依赖或 ui_v3 领域边界。

## 下一批：数据库、诊断与图片缓存装配

基线 `2f8e3fc`，继续同一任务分支。已阅读 ADR-002 和异步恢复不变式，Graphify 查询组合根，源码核查 read/watch/override、后台 flush 和 worker dispose 路径。

目标：提取 database_providers（snapshot store、AppDatabase、worker runtime、preferences DAO），diagnostics_providers（diagnostic DAO/logger/export），media_cache_providers（resource image cache），共 8 个 provider。诊断导出仍读取相同图片容量指标，故缓存装配一并迁出；三个新模块不得导入 app_providers，也不使用兼容重导出。业务 DAO 和恢复协调器暂留原处。

范围：移动 lib/test/integration_test 中的消费者、装配模块和此计划。不得修改 schema、迁移、账户键、数据路径、请求语义、worker 默认开关、read/watch、flush 时机、缓存预算或桌面源码。API 后端行为不在本批变更内。

风险：同一 provider 的身份与 override 分散后遗漏消费者；数据库 worker 异步关闭和日志后台 flush 失效；缓存账户隔离被打断。保持原构造闭包，通过全移动分析、app_providers、database/worker/write queue、diagnostic batch 和图片缓存测试验证。新模块依赖无回环；存储/日志不反向依赖全局组合根；既有 gate 债务不得靠扩大预算隐藏。

执行：提取声明及导入 → 迁移全部消费者并删除无用全局导入 → 验证声明唯一和代码块等价 → 格式/分析/聚焦测试 → Graphify 与源码复查。回滚仅还原声明和导入，不涉及数据格式变更。进度：实施前计划已记录。

### 数据库、诊断与图片缓存装配结果

- 8 个 provider 已迁到三个独立装配模块，移动源码、测试和 integration_test 消费者改用直接导入，无兼容重导出。与 `2f8e3fc` 逐段比较，构造代码保持一致；数据库构造仅增加现有 `database-worker-persistence` RFC 标记。
- 启动运行器、画布 AI 控制器、账户页、资产页和 billing 装配移除全局组合根导入。三个新模块经源码递归检查均无 import/export/part 路径回到 `app_providers.dart`；每个迁移符号只有一个声明。此结论不代表所有业务模块已解耦。
- 原组合根从 2,813 行降至 2,676 行。旧组合根数据库风险预算由 2 收紧至 1，新文件绑定现有 worker RFC，没有扩大或搬运豁免预算。
- 格式和 diff 检查通过；移动 `lib test integration_test` analyzer 无 error/warning，422 条既有 info。数据库、worker、写队列、日志批处理、装配、缓存和画布 AI 的 160 项测试通过；架构检查器 34 项测试通过，共 194 项离线回归通过。
- 架构 gate 为 453/453 文件可达，三个新模块无规则发现。全局门禁仍退出 1：与上批日志相比，仅组合根规模下降、显式导入导致部分既有超限文件增加一行以及可达文件数变化，既有债务仍待后续批次解决。
- Graphify 刷新为 45,622 节点、67,366 边、1,088 个源码文件，已查询三个新模块并用源码校验依赖。启发式图中的语法节点和路径归并不作编译证明；生成图保留本地，不提交。
- 没有改桌面、schema、API 协议、worker 开关或缓存预算；没有执行真机、服务器或生产验证。上批已确认的主题断言/golden 基线失败不在本批测试范围，也未修改。

本批完成。下一批继续拆分业务 composition 和路由；core 对 feature 的反向依赖、ui_v3 领域边界与大页面仍是未完成事项。当前改动留在 `refactor/mobile-p0-composition` 工作区，尚未提交或推送。

## 2026-10-04：UI 重构前的聊天边界切片 1

用户将重写页面 UI，优先稳定业务状态和操作边界，暂缓旧页面的纯视觉拆分。沿用任务分支，保留上批未提交的装配变更。

本批目标：删除 ChatControllerState 中无生产消费者的旧 `agentToolTrace` 副本及反向 DTO 转换；保留唯一中立 `assistantToolTrace`。提取 Controller 私有运行状态读取租约为纯 Dart 的 ChatAssistantRunReader，Controller 直接消费 AssistantRunSnapshot，删除重复 projection/read 包装。新 reader 只依赖中立 domain port，不引入 API、Riverpod、Flutter、原生或全局装配。

实施前：阅读 ADR-008、异步恢复和长任务导航不变式；Graphify 查询 ChatController，源码核查 state 消费者、read lease、取消调用点、终态回读和失败线程恢复。旧 trace 的生产引用仅为 Controller 内部复制，页面已经消费中立 trace；其他领域的旧 DTO 不在本批删除范围。

不变项：接口请求/解析、认证、服务端字段、错误码、轮询频率、终态策略、scope/generation、后台任务 owner、缓存键和 UI 外观。取消只释放当前读取，不停止服务端任务；不新增兼容导出或迁移别的业务域，不动桌面。

步骤：删除旧 state 字段及消费者 → 提取租约读取 owner → 让轮询直接读取中立 snapshot → 增加并发租约、完成释放、取消异常和重复取消回归 → 全移动静态分析、聊天控制器/任务/UI 回归 → Graphify 与源码复查。

验收：无 agentToolTrace 旧字段；Controller 无 AgentRunToolTrace/AgentRunOutputFile 反向构造；state 无 API import；reader 不依赖实现层；保留线程/Run 绑定校验及原有取消调用点。架构门禁不扩大预算、不新增模块债务。UI、异步行为以离线测试为证，不声明真机或服务端结果。回滚只撤销本切片文件及测试，不撤销上批装配改动。

### 聊天边界切片结果

- 新增 `chat_assistant_run_reader.dart`，只依赖 `assistant_runtime.dart`。它集中管理可取消的 `AssistantRuntimeReadLease`，Controller 的轮询继续负责线程绑定、generation、终态回读和失败投影；释放读取租约不会取消服务端 Run。
- 删除 `ChatControllerState.agentToolTrace` 及 Controller 内 `AgentRunToolTrace`/`AgentRunOutputFile` 反向构造；生产状态只保留 `AssistantToolTrace`。`chat_run_tracker.dart` 仍保留旧 trace 作为持久化和兼容读取边界，本批没有扩大删除范围。
- ChatController 从 5,843 行降至 5,761 行。变更前 Graphify 中 ChatController degree 为 409；变更后图刷新为 45,651 节点、67,367 边、1,089 个源码文件。新 reader degree 为 10，仅连接中立 runtime port、lease 集合和生命周期方法；无 API、Riverpod、Flutter、全局组合根或 native import。
- 完整移动 analyzer 无 error/warning，422 条既有 info；格式、diff check 通过；架构可达性 454/454。架构 gate 仍只报告既有 recording-card、notification、页面债务，没有本切片新增发现。
- 聊天 Controller 单独回归日志为 `+124 -1`（125 项，124 通过、1 失败）。失败为 `records send/reply times...` 的 fake clock：测试只提供两个 `DateTime`，执行路径额外调用 `_nowUtc` 后在 `removeAt(0)` 越界。组合聊天页面回归还有多项 `pumpAndSettle` 超时和 timer 清理失败；本轮首次报告时尚未隔离验证，后续资产批次已在 HEAD 副本复现同一失败集合。没有通过放宽等待隐藏失败。
- 未执行真机、服务器或 Provider 联调；未改变请求字段、认证、轮询频率、缓存键、服务端任务生命周期或页面外观。当前改动尚未提交或推送。

下一步：在新 UI 接入前继续把页面轮询移入 feature controller/application owner；随后拆 ChatController 的历史加载、发送 admission、运行进度和缓存持久化职责。旧聊天 page 的布局拆分暂不作为底层架构验收。

### 页面轮询第一处迁移

在同一 UI 准备批次中，将账户页的 30 秒 usage poller 提取为
`AccountUsageRefreshCoordinator`。它位于 billing application 层，独立持有
`OrchestratedPoller`、网络资源声明、退避、前台条件和 `AccountUsageController.load()`；
`V3AccountProfilePage` 只在 route active/inactive/dispose 生命周期调用
`start/stop/dispose`，不再定义任务 key、间隔、资源或错误判定。初版将任务 owner 改为
`account-usage`，后续资产批次恢复 `account-usage-page` 以保持指标身份，并修正 Controller
解析时机，具体见该批结果。

该迁移只改变装配位置，不改变请求、轮询频率、退避、状态判断或 UI。新文件 analyzer
无 error/warning（2 条新增 const info，后续已修正）；billing/controller 和聊天回归中，
membership 测试有失败，其基线来源未验证，不声称是既有问题，也不作为本次协调器通过证据。下一处按同样
方式迁移资产、定位和转写页轮询前，先为 coordinator 增加直接的任务生命周期测试。

## 2026-10-04：UI 重构前的资产轮询边界

目标：只迁移资产实时刷新使用的 `OrchestratedPoller` 装配，不迁移页面仍拥有的
`AssetsRequestOwner`、刷新合并、缓存失效、请求取消和 UI 状态投影。新增
`AssetsLiveRefreshCoordinator` 位于 assets application 层，接收抽象的
`canRun` 与 `refresh` 回调，统一任务 key、owner、网络资源、10 秒间隔、30 秒退避、
前台条件和 dispose；页面仅在 asset work 变化及 route active/inactive 时控制它。

实施前：Graphify 查询资产页 degree 112，源码核查 live work 监听、route 生命周期、
request owner 取消和 queued refresh；定位页 degree 48，发现其轮询同时包含 API、ETag、
ScopedReadCache、account/workspace 校验和 widget setState，因此不与资产批次混拆。

不变项：资产请求参数、缓存 revision/invalidation、并发刷新合并、owner supersede/cancel、
轮询 key/频率/退避、页面状态和视觉结构。验收为资产页面聚焦测试、assets controller
测试、analyzer、Graphify/source review；不执行服务端或真机操作。回滚只恢复 poller
装配和页面导入。

### 资产轮询边界结果

- 新增 `AssetsLiveRefreshCoordinator`，资产页不再直接创建 `OrchestratedPoller`；请求 owner、
  queued refresh、cache invalidation、supersede/cancel 仍由页面与 `AssetsController` 保持。
  `AssetsLiveRefreshCoordinator` 只依赖任务调度、活动指标和抽象 refresh/canRun 回调。
- 修正账户协调器：每次轮询通过 `currentController` 读取当前账户 Controller，账户/工作区
  切换不会继续使用旧实例；恢复原页面行为的 `account-usage-page` owner 和既有 RFC 标记。
- 新增 8 项生命周期测试，覆盖账户 Controller 替换、资产 inactive 不读、重复 start 单飞、
  stop 后迟到完成、前后台暂停恢复以及聊天 reader 租约释放；资产页面、资产 Controller、
  账户 Controller 与这些协调器共 41 项聚焦测试全部通过。
- 为资产页面测试显式 override `assetProjectionFreshnessProvider`，隔离设备身份和全局通知投影；
  这修复的是测试装配缺口，不改变生产逻辑。修复替身前，隔离 HEAD 与工作树聊天/资产失败
  名称集合一致：28 个失败复现（聊天 24、资产 4）；资产 4 个失败在补齐替身后已消除。
- 完整 analyzer 无 error/warning，422 条既有 info；架构可达性 456/456。与上批 gate 相比，
 仅移除了账户页的旧轮询 RFC 告警并增加两个新源码文件，未新增架构债务。Graphify 刷新为
 45,706 节点、67,424 边、1,094 个源码文件；生成图不提交。
- 未改 UI 布局、路由、请求协议、缓存语义、任务 owner 生命周期之外的业务行为；未执行真机、
  服务器或 Provider 联调。当前工作区改动仍未提交或推送。

下一步：定位进度页必须先把 `PositioningProgressClient`、ETag、ScopedReadCache 和
account/workspace scope 校验移到 application/data owner，再让页面只订阅状态；随后处理
转写和 Work AI 页面轮询。它们仍与 UI 组件替换解耦，但会涉及存储和长任务不变式，单独成批。

## 2026-10-04：定位内容覆盖率边界

目标：将 V3PositioningTaskProgress 的网络、ETag、缓存序列化、账户/工作区校验和轮询
移入 features/positioning 的 domain/application/data，装配在 app/di。页面只管理展示、
导航、可见性和已有任务阶段输入；不绑定新 UI 视觉结构。用户已授权继续此类底层解耦。

已读取异步恢复/长任务导航不变式、共享 API PositioningProgressClient/DTO/parser 及现有
ScopedReadCache。Graphify 复查页面 degree 48；入边/测试使用源码搜索确认。接口仍是原
workspacePositioningProgress，客户端字段、认证、协议解析和状态语义不变，无服务端操作。

设计：纯 Dart PositioningCoverage + Repository port；RemotePositioningProgressRepository
保留原缓存 payload、键、TTL、ETag/304、失败传播规则，保存前验证读取仍属于当前 owner。
PositioningProgressController 使用现有 OrchestratedPoller（3 秒、30 秒退避、15 秒 deadline）
与可见/任务活动输入。每个页面实例拥有一个 controller，dispose 释放轮询；app/di factory
捕获创建时 scope 并实时校验，不将 API/数据库/provider 容器放进领域模型。

风险/验收：缓存初始展示 stale；304 无缓存不得成功；last_known_good 始终 stale；失败保留
旧覆盖率；暂停、结束、切换 scope 或 dispose 后不得保存迟到响应；返回不取消后台任务。
新增 repository/controller 测试并运行现有定位页面回归、全移动分析和 Graphify/source gate。
不修改布局、文案、golden、实际任务 owner、请求或缓存格式。回滚仅本批新增边界与页面绑定。

补充验证范围：复查发现上批 AccountUsageRefreshCoordinator 捕获固定 Controller，
与原页面每轮 ref.read 当前实例不同。本批改为每轮解析当前 Controller，恢复账户替换
语义，并补账户/资产协调器生命周期测试及 reader 租约测试。先前计划中将聊天/会员
测试称为“既有失败”尚缺隔离基线证据，本批验证前应视作未归因失败；不得据调用栈
未经过新代码就判定与重构无关。

### 定位内容覆盖率边界结果

- 新增 `features/positioning/domain/positioning_progress_repository.dart` 的中立 `PositioningCoverage` 与 repository port；新增 `RemotePositioningProgressRepository`，集中处理 `PositioningProgressClient`、ETag/304、`ScopedReadCache` 序列化、last-known-good stale 语义及 scope 所有权检查。
- 新增 `PositioningProgressController`，集中持有 3 秒轮询、30 秒最大退避、15 秒 deadline、前台/路由/任务活动条件、generation 和 dispose；页面只订阅 coverage、管理展示和导航。
- 新增 `positioningProgressControllerFactoryProvider`，创建时捕获 account/workspace scope，scope 改变时旧 Controller/请求不能更新新页面或写入新缓存。缓存键和 API endpoint 保持不变。
- 页面从原先同时依赖 API、数据库、缓存和任务调度，降为 Controller + task state + route lifecycle；页面布局、文案和服务端覆盖率不等同生成耗时的语义未改。
- 新增 Controller/Repository 测试覆盖缓存 stale、304 无缓存失败、valid/last_known_good、失败保留旧覆盖率、隐藏/终态/scope/background/dispose/15 秒 deadline 的迟到响应丢弃，以及恢复后的新 generation；定位页回归增加 account/workspace 切换验证。相关缓存、页面和 Controller 共 26 项通过。
- 最终 Graphify：45,761 节点、67,487 边、1,099 个源码文件。页面状态 degree 从 11 降至 5；图中移除了 API、session、缓存和调度 provider 的直连。图未完整提取 DI factory/port 回调边，已用源码、analyzer 和真实 Provider 装配的离线测试补查；没有新增 native 边界。完整移动 analyzer 无 error/warning，422 条既有 info；可达性 460/460。与本批前的 pollers gate 日志比较，只移除了定位页旧轮询 RFC 告警，没有新增架构告警；完整架构 gate 因既有债务仍未通过。
- 未执行真机、服务器或上游服务联调；未修改服务端字段、认证、轮询配置、后台生成任务生命周期、缓存格式或 UI 视觉结构。读取取消、超时和账户切换后的响应归属检查得到加强。改动仍未提交、未推送。

## 2026-10-04：退役 backend_contracts 聚合包装

目标：保留现有工作区重试行为，将唯一生产用例迁到 workspace feature，删除 backend_contracts 的无消费者包装、模型及专用测试。保持 Page → Controller → Repository → ApiClient；Controller 负责原有命令幂等上下文，Repository 负责 endpoint 与响应解析。页面原有 creating 状态读取、8 次确认循环、导航及 UI 不在此批改动范围。

影响：生产调用为 app_route_screens.dart 的 workspace recovery；另有显式联网 integration probe 调用。迁移 probe 的依赖但不执行它（包含服务端写操作）。确认旧模型名在全工作区无其他消费者后删除；保留共享 EndpointCatalog、manifest、真实领域 client 及静态契约检查工具，不混淆它们与被删除的运行时聚合包装。

协议：读取现有 client、endpoint catalog/manifest 和请求测试；本机未找到后端实现副本，本批不更改请求字段、认证、响应接受规则或同步策略。完整保留 POST /api/v1/workspace/retry-create、空 JSON body、原有 idempotency operation/scene/key 及 ack 解析，包括非法文本过滤。若发现必须改协议，暂停该部分直至取得后端证据。

步骤：依赖核查/Graphify → workspace 边界和 DI → 页面及 integration probe 替换 → 删除旧模块和专用测试 → 请求/解析/失败测试、页面验证、全移动 analyzer、静态契约与架构门禁 → Graphify 复查。回滚仅此切片；保留先前未提交重构和用户 UI 文档；不操作服务器或桌面。

### backend_contracts 迁移结果

- 新增 `features/workspace/domain/workspace_recovery.dart` 和 `features/workspace/data/workspace_recovery_repository.dart`，并通过 `app/di/workspace_providers.dart` 装配。页面和显式 integration probe 均改用 `WorkspaceRecoveryRepository.retryCreate`。
- 删除 `features/backend_contracts` 的 580 行 API 聚合、283 行历史模型、225 行宽泛兼容测试；删除只扫描历史 backend contract 聚合的 `tool/backend_contract_check.dart` 及其 45 行测试，并从 quality gate 移除重复门禁。保留并验证统一 `api_contract_consistency_check.dart`。
- 保持 `workspaceRetryCreate`、`POST /api/v1/workspace/retry-create`、空 JSON body、原幂等 operation/scene/key、认证和 ack 解析。新增测试覆盖成功请求和畸形 ack fail-closed；workspace、页面回归共 9 项通过；契约一致性检查为 215 declarations / 0 issues；全移动 analyzer 无 error/warning，422 条既有 info；源码可达性 461/461。
- Graphify 刷新为 45,673 节点、67,375 边、1,098 个源码文件。`WorkspaceRecoveryRepository` 的生产装配通过源码与测试确认；旧 `BackendContractApi` 源文件和引用均不存在，图中仅残留无 source 的历史 orphan node，不代表当前代码依赖。
- 未执行真实服务器 probe；integration probe 仅完成代码迁移。改动仍未提交、未推送。

## 2026-10-04：删除 core/api 重复转发入口

目标：删除 `src/lib/core/api` 中只转发 `package:huahuo_api/huahuo_api.dart` 的五个 shim，所有调用方直接依赖共享 API 包；保留 `AppCachePolicy` 与 `ScopedReadCache` 等真实实现。此批只整理依赖入口，不改变请求字段、认证、缓存、重试、上传或 UI 行为。

实施：删除 `api_client.dart`、`api_envelope.dart`、`endpoint_catalog.dart`、`idempotency.dart`、`upload_client.dart`；迁移 180 个原 shim 引用文件（包含 core 内部实现、应用代码和测试）到直接 `huahuo_api` 导入。补齐 `WorkspaceRecoveryRepository` 及其测试的遗漏导入，并保留 document proposal/positioning 的 `hide` 语义。旧 shim 路径在 `src` 中已无引用。

验证：Dart analyzer 无 error/warning（436 条既有 info）；API client、幂等性、workspace recovery 聚焦测试全部通过；API 契约检查为 215 declarations / 0 issues；源码可达性为 456/456；Graphify 刷新为 45,814 节点、67,214 条边、1,093 个源码文件。未执行服务器、真机或桌面工作；未改变 UI 视觉结构。Graphify 图产物不提交，工作区改动仍未提交或推送。
