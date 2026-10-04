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
