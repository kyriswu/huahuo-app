# Flutter 项目交接期架构审计

日期：2026-10-01

基线：HEAD `32b0d929` 加当前工作树，包括前一轮资料归档与现有原生修改。本文是交接期审计快照，不替代源码、协议和测试；长期架构决策落实后应进入 `docs/architecture`、`docs/invariants`、`docs/adr` 或 `docs/runbooks`。

这份审计只评价工程结构、职责、依赖、可验证性和长期维护成本，不评价当前产品功能是否符合需求，也不把一次清理提交误认为架构重构。证据来自当前工作树、静态源码检查和本地测试结构。没有访问服务器，没有执行会写入远端的 smoke 脚本。项目约定要求使用的 Graphify 缓存和图数据已不存在，因此本文不声称有 Graphify 图结果；依赖结论由 Dart import/export 搜索、源码检查和现有 gate 交叉验证。

## 结论先行

当前最危险的不是目录名称，而是组合根和业务边界失控：

1. 移动端 `app_providers.dart` 变成所有业务的服务定位器，且与 onboarding 形成真实循环依赖。
2. `ui_v3` 是 202 个文件、约 14.4 万行的 catch-all 功能区，知识库、创作画布、数字分身、工作台等不同业务共用内部模型和 controller。
3. 桌面 `editor_workspace.dart` 约 1.34 万行，同时持有编辑器、聊天、账号、工作区、通知、订阅、书籍和知识库状态；它不是页面，而是整个桌面应用的第二个组合根。
4. API 相关代码有真实运行时价值，但“API Integration Test Report”不是联调报告，主要是清单和静态存在性核对；退役接口也被保留在运行包和检查基线中。
5. 当前质量门禁会报红，但其中混有过期预算和脆弱正则规则。若先简单调大预算，问题会被掩盖；若直接按正则删除代码，也可能误删正确实现。

目标应是“模块化单体”：按业务能力建立边界，保留一个移动组合根和一个桌面组合根；暂不拆微服务，也不按文件数量机械拆分。

以下 P0 表示架构整改的先决事项，不代表已经证实线上事故。行数为实际工作树 Dart 文本行数，含注释/空行；用于定位热点，不等于复杂度或质量分数。此次没有执行全量 analyzer、测试或原生构建，也没有审计外部后端实现及远端分支保护。

| 区域 | Dart 文件 | 文本行数 |
| --- | ---: | ---: |
| 移动端 `src/lib` | 440 | 285,909 |
| 桌面端 `desktop/lib` | 83 | 44,202 |
| `huahuo_api/lib` | 29 | 21,345 |
| `huahuo_product/lib` | 31 | 7,489 |
| `huahuo_foundation/lib` | 6 | 1,677 |
| `huahuo_editor/lib` | 4 | 1,573 |

## 证据与整改清单

### P0：先修复边界和验证机制

#### 1. 组合根与 onboarding 循环依赖

证据：`src/lib/app/bootstrap/app_providers.dart:1-120` 导入几乎所有 feature、数据库、原生端口和共享 UI；`src/lib/features/onboarding/application/content_line_onboarding_controller.dart:6-17` 又反向导入 `app_providers.dart`。本地 `source_reachability_check.dart` 明确报告：`app_providers.dart -> content_line_onboarding_controller.dart -> app_providers.dart`。

影响：provider 初始化改动的影响面难以局部界定；即使测试只构造 onboarding controller，导入其库仍会带入 app 组合代码；循环依赖鼓励后续继续向全局组合文件添加服务。

处理：把 provider 声明按能力拆到 `features/<capability>/bootstrap` 或 `app/di/modules`；feature 只依赖端口和参数，不导入组合根。由 app 负责组装 override。验收为依赖检查无 cycle，onboarding 测试可在不导入 `app_providers.dart` 的情况下构造 controller。

#### 2. `ui_v3` 必须按业务边界拆分

证据：该目录 202 个 Dart 文件、约 144,067 行，占移动业务代码大头；同时包含知识库、画布、数字分身、热点聚合、工作台、导入和定位等。`knowledge_library_controller.dart` 约 5,293 行，`v3_creation_canvas_page.dart` 约 9,671 行，`v3_chat_page.dart` 约 6,907 行。

影响：其中 `feed_item_models.dart` 被 66 个文件直接引用，业务修改的跨模块回归面很大；目录名表达的是视觉版本，不表达领域所有权。

处理：先建立 capability 清单并迁移为 `knowledge`, `creation`, `digital_twin`, `workspace`, `positioning`, `ingestion` 等边界；页面、application、data、domain 各自归属边界。公共视觉组件移到 `shared/ui`，跨边界通信只用端口或事件。验收为 feature 不能导入另一个 feature 的 presentation/data，`ui_v3` 只保留真正的 UI 组件或被删除。

#### 3. 桌面编辑器页面拆成 shell 与 feature controller

证据：`desktop/lib/features/editor/presentation/editor_workspace.dart` 13,392 行，字段区同时持有文档、聊天、账号、工作区、通知、订阅、每日主题、书籍、资源和图编辑状态；还通过 `part 'editor_product_navigation.dart'` 继续扩展同一类。

影响：一个页面拥有多个生命周期和并发状态，无法局部测试；桌面和移动端不能共享明确的业务端口。

处理：保留 `EditorShell` 只做布局、tab 和路由；将文档、聊天、工作区、通知、订阅分别提取为 controller/port，并用 immutable view model 输入页面。`part` 文件应迁移为普通库文件。验收为 shell 不直接调用 API，不保存跨域业务状态，单个 capability 可独立测试。

#### 4. 质量门禁必须从“正则债务报告”改成可信的架构检查

证据：本地检查有 91 条发现，其中包含过期行数预算、`INVALID RESIDENT PROVIDER REASON`、跨 presentation 规则和一次误报的 `UNCANCELLED STREAM SUBSCRIPTION`。该订阅实际由 `_cancelSubscription()` 和 `dispose()` 取消。门禁还把硬编码旧 revision 当作后端接口不可删除基线。

处理：保留编译器、Dart analyzer、真实测试和明确的依赖规则；取消“自然语言命中特定单词就证明生命周期正确”的机制，订阅释放采用分析器辅助和行为测试。保留有 owner 的“不新增债务”约束，将自动发现但未确认的问题标为 review 项；不要因文件变短就让整个流水线失败。验收为 gate 输出能区分 error/warning/needs-review，误报案例有回归测试，结构性规则可定位到符号。

#### 5. CI/门禁入口不完整且没有固定工具链

证据：`src/tool/quality_gate.dart:90-195` 使用裸 `dart`/`flutter`，离线 `pub get` 假定缓存已预热；分析覆盖六个成员，测试覆盖五个，漏掉现有 `huahuo_foundation/test`；format 同样遗漏该测试目录及 integration_test；集成测试没有固定设备；本地受版本管理的文件中未发现 `.github` workflow、`.gitlab-ci.yml` 或 CODEOWNERS。当前工作树有尚未跟踪的 `.fvmrc`，门禁没有显式验证实际 SDK 版本。远端是否另有流水线/保护规则未核验。

处理：增加统一 CI 入口，显式区分 bootstrap、format/analyze/unit、integration/device；使用 FVM 或 CI 安装的固定 SDK；补 foundation 测试；对真实设备测试单独标注证据来源。验收为干净环境能完成依赖解析，PR gate 不访问生产，原生变更触发相应编译/单测，发布 gate 完成发布配置构建。

### P1：删除重复职责和遗留实现

#### 6. API Integration 报告应改名并降级为静态 contract consistency check

`src/tool/api_integration_report.dart:14-65` 只读取 `EndpointCatalog` 和 `ApiContractManifest`，将“有运行时定义”记为 PASS；即便配置了环境，也写入 `CONFIGURED_NOT_EXECUTED_BY_REPORTER`，没有发请求、运行测试或读取测试 receipt。`testCase` 是硬编码字符串。标题 `API Integration Test Report` 会误导接手者。

处理：将其改名为 `api_contract_consistency_check.dart`，输出“清单一致性”而不是“集成通过”；真实 HTTP/SSE 验证放入显式 opt-in 的 integration test，输出带环境、设备、时间和测试命令的 artifact。提交库只保留 schema/manifest，`latest.json`/`latest.md` 改为 CI artifact 或明确标为生成物。固定的 `docsWorkingTreeRevision`（`api_integration_report.dart:233-235`）必须删除，改为运行时 git 信息或不输出。

#### 7. API 契约清单、端点目录和报告 DTO 不应混在一个运行时 barrel

`packages/huahuo_api/lib/src/api/api_contract_manifest.dart` 同时包含运行时的 `AgentFeatureRoutes`/availability resolver、接口清单和仅供报告使用的 `ApiIntegrationReportEntry`；`huahuo_api.dart` 将它们全部导出。`endpoint_catalog.dart` 还承担认证、幂等、缓存策略和状态元数据，是真实运行时代码。

处理：保留 `EndpointCatalog`、client、domain clients 和运行时 feature route；先将只有工具消费的报告 DTO 移到 `tool`。scope/disposition、退役约束和文档 revision 分别追踪调用后再决定归属，不为几十行元数据新增一个包。对 manifest 与 catalog 明确各自权威字段，避免两份路径清单漂移。验收为生产包不导出 report-only 类型，API client 的测试仍可独立运行。

#### 8. 退役接口和“全历史不可删除”检查应移除

`features/backend_contracts/data/backend_contract_api.dart` 中多个方法（content line、memory note append、feed deposit、task events 等）只做输入校验后返回 `API_ENDPOINT_RETIRED` 或 `API_ENDPOINT_PROHIBITED`。这些仍占用生产接口和模型表面；`backend_contract_check.dart` 又以固定历史 revision `4093f23...` 阻止删除。

处理：本轮选定退役方法的生产调用搜索未找到调用，后续仍应结合 analyzer、测试替身和对外导出确认，再删除对应 port、实现和专用模型。已经从 catalog 移除的接口不必重复清理。禁止调用旧协议的负向测试应保留；若仍需迁移提示，用明确 deprecation，而不是无限保留空壳。不能直接删整个 `backend_contracts`：`app_route_screens.dart:198` 仍通过它执行 workspace retry，应先迁移至工作区用例端口。检查规则改为“当前支持契约 + 明确退役策略”，不保护所有历史字符串。

#### 9. `pending_message_projection` 是跨域命令中心

证据：该文件约 3,662 行，导入 app providers、路由、聊天、onboarding、ingestion、recording、canvas、masterpiece、digital twin 等多个域；`PendingMessageSource` 已有 13 类来源，且 `markHandled` 会刷新目标并结算任务结果。

处理：保留通知投影的纯模型和排序；各业务提供 `NotificationContribution`/ack port，通知层不直接 import 业务 controller 和 repository。刷新/结算交给 task result coordinator。验收为通知模块只依赖稳定事件和 acknowledgement port。

#### 10. 录音卡 controller/native port 需要按协议边界拆分

证据：`recording_card_controller.dart` 12,393 行，混合设备身份、权限、蓝牙/Wi-Fi 传输、文件落盘、同步 ledger、账号绑定和 API；`recording_card_native_port.dart` 3,459 行的一个 `MethodChannelRecordingCardPort` 实现十多个 port，管理 method/event channel、重试、连接 epoch 和所有协议结果。

处理：按连接会话、BLE/Wi-Fi transport、传输用例、持久化和账号绑定拆分。端口声明与 MethodChannel 实现分离；底层连接 epoch、旧回调过滤仍归原生适配器，业务 ledger 归用例。iOS `RecordingCardBridge.swift` 8,697 行、Android `RecordingCardAndroidBridge.kt` 6,344 行也需要同样划界。保留现有 Android/iOS 协议单测，复用跨端 wire fixture，按需要评估类型化通道而非强制引入 Pigeon。验收必须包含断连、迟到回调、传输恢复、账号切换及真机证据；不能靠剪切文件认定完成。

### P1：统一数据、共享包和平台边界

#### 11. 本地数据库存在两套存储架构，需确定唯一 owner

`AppDatabase` 支持内存记录、JSON/SQLite snapshot（`app_database.dart:922-955`），另有 `database_worker_schema.dart` 的物理 schema v4（含 outbox/inbox/checkpoint）。这是多层持久化机制，不应把业务 schema v16 与物理 schema v4 当成版本冲突。provider 初始为 `null`，但根 ProviderScope 会 override（`app_providers.dart:2653`），生产默认工厂提供 SQLite snapshot store（`:2961`）；不能据默认声明推断没有持久化。worker 路径仍受开关控制。

影响：迁移、事务、恢复和性能语义分裂；接手者难以判断哪套 schema 是生产真相。

处理：先明确内存读模型、worker 写入、flush 成功和故障恢复的权威关系。建议逐步收敛到一个生产写入边界；JSON 若确实只服务旧数据迁移/测试，再移到对应适配器。保持逻辑 schema 与物理 schema 分层，由同一存储模块维护；不因使用 JSON payload 就重写所有表。验收覆盖写入失败、进程中断、旧 schema 升级、账号隔离；在确认支持的数据版本前不能删除迁移。

#### 12. 桌面本地 JSON store 没有统一 storage contract

桌面多个 feature 各自实现 JSON 文件读写。已有版本和账号隔离，不能称为“完全没有治理”。具体差异是 `desktop_chat_recovery_store.dart:46-58` 和 `desktop_topics_cache.dart:60-94` 先删旧文件再 rename；`local_document_store.dart:105-125` 与 preferences stores 有 backup/恢复路径。共同机制被重复实现，失败时的语义不同。前两处存在删除与替换之间的崩溃窗口，但本轮未做故障注入，也未证明发生过数据丢失。

处理：优先抽取可靠的文件替换、备份恢复和按路径串行写机制；领域 JSON 编码仍由各模块负责。可重建 cache、用户文档和必须可靠保存的 outbox 分别定义容错要求，不强行共用一个吞错策略。验收包括写临时文件后崩溃、替换失败、并发保存和账号切换。

#### 13. `huahuo_product` 的职责描述与实际使用不一致

包描述为“Shared product capabilities and application orchestration”，但移动端只在 `app/product/mobile_feature_registry.dart` 引用一次，桌面端有多处使用；包内同时含 domain、application、remote repositories 和 feature catalog。

处理：逐项确认哪些业务用例应跨端共享：已有共同语义的模型/用例由两端复用，确实桌面专用的 orchestration 留在 desktop。不要仅凭“只有一个消费者”就删除包。该包当前是纯 Dart，应继续不依赖具体 Flutter app/平台；`huahuo_foundation` 本身是 Flutter 视觉包，不应为了名称而强行引入纯业务层。验收是明确包职责与公开端口，并在选定能力上证明两端行为契约一致，不额外维护源文件索引。

#### 14. core 反向依赖 feature，层级规则已经失效

证据：`core/native/knowledge_export_port.dart` 导入 `features/ui_v3/domain/knowledge_export_models.dart`，`core/native/screen_capture_port.dart` 导入 ingestion domain。源码 import/export 启发式统计发现 72 个 feature 文件引用 app，共 141 条文件依赖边；反向 app 到 feature 共 208 条。统计未解析全部条件导入及动态绑定，作为结构证据而非编译证明。

处理：把端口和纯数据结构下沉到 `core`/shared contract package，或将实现上移到 feature data；core 不能导入 feature，feature 不能导入 app composition。验收为依赖规则采用 import graph/AST，层级反向依赖为零。

### P2：治理和可维护性

#### 15. 大文件债务必须按责任拆解，不要只改预算

当前最大文件包括 desktop editor 13,392 行、recording card 12,393 行、canvas page 9,671 行、chat page 6,907 行、chat tracker 5,372 行、API contract models 4,877 行。现有 gate 的预算不少已 stale 或已超出，说明债务表没有 owner 和退出标准。

处理：每个热点建立拆分目标、owner、禁止新增职责规则和迁移验收；文件大小只是信号，按状态机、repository、view model、组件和 wire model 拆分。验收看依赖和职责是否独立、能否单独测试，行数阈值只是提醒，不能再制造一套任意预算。

#### 16. 手写 `part`、共享主题和跨页副作用应收敛

检查报告发现 8 个 handwritten `part`、多个 presentation data/cross-feature findings、页面 build side effect。`recording_card_controller.dart` 和桌面 editor 都使用 `part` 扩展巨型库。

处理：普通 Dart library 文件按职责拆分；页面只渲染 state，初始化、订阅和写入移到 controller/lifecycle coordinator；共享主题保留在 `shared`，业务模型不放进去。验收为页面 build 无网络/数据库/文件副作用，part 数量只在生成代码场景保留。

#### 17. 生产默认地址和工具脚本的风险要分开治理

移动 recording API 和桌面服务默认指向 `https://chuda.cc`（`core_provider_module.dart:33`、`desktop_services.dart:42`）；历史 `tools/smoke` 脚本有生产/远端默认行为。清理时已保留脚本，但它们必须不能被 PR gate 隐式调用。

处理：应用生产构建通过显式 release 配置注入地址；开发构建无配置时失败或使用本地 stub；所有 smoke 脚本要求显式 `--base-url`/`--token` 并打印环境，默认 dry-run。验收为单元测试和 PR gate 不可能访问生产。

#### 18. Feature parity 是登记表一致性，不是两端行为一致性

`src/tool/feature_parity_check.dart:33-85` 从 catalog 状态统计 aligned，检查 `implementationEvidence` 文件是否存在、入口字段是否登记；未执行这些页面。该检查有用，但不能成为“两端已对齐”的验收。

处理：命名为 registry consistency；行为共性用 shared port contract tests，两端 UI 各自验证交互。现有 native deferrals 可保留，不为追求登记表全绿强制桌面实现移动能力。help/legal 两份资源目前靠字节相等检查，应评估共享资源包或构建时复制，避免人工双份维护。

#### 19. API clients/models 仍有全局大文件和兼容出口

`contract_models.dart` 4,877 行、`domain_clients.dart` 3,827 行；身份、工作区、录音、笔记等领域混在一个文件。移动端 `core/api/api_client.dart`、`endpoint_catalog.dart` 只是对整个 `huahuo_api` 的宽泛重导出，并非第二套 HTTP 实现。

处理：沿现有 billing/auth/recordings 的目录方式逐步拆分 contract model 与 domain client；提供按领域的公开入口。移动兼容 export 在导入迁移完成后删除。不要为了“重复文件”误删 client，也不引入第二个 API 生成框架。availability resolver 中已废弃的 skill/model 入参（manifest 第 106–165 行）在调用迁移后删除，保留服务端选择的当前语义。

#### 20. 测试资产不少，但测试分层与运行范围需要重整

现有移动单测文件 274 个、integration_test 25 个、桌面测试 37 个、API 测试 21 个、product 8 个、foundation 1 个、editor 3 个。这是文件数，不是通过数或覆盖率。Android 有协议单测，iOS `RunnerTests.swift` 有连接 epoch 等测试，不能评价为“没有测试”。

问题在于 screenshot、live backend、Simulator、硬件测试放在一个 integration_test 目录，nightly 直接跑整个目录；例如 `backend_live_contract_probe_test.dart` 会执行 workspace retry。PR gate 清单未显式运行原生 XCTest/Gradle 单测。

处理：按离线行为、外部服务、Simulator、真机分组/标签，分别声明环境与命令；native 变更触发 native 测试；截图只证明观察到的外观，测试中的行为断言另行评价。重构保留已有账号隔离、幂等、恢复、乱序事件、协议 fixture 测试，将巨型测试按被拆出的能力迁移，避免为源代码文本写更多镜像测试。

#### 21. 工具和历史资料要有保留边界，不能继续成为工程真相

之前已移出源码的 `archive`、截图/录音、`reports` 和历史 smoke 脚本并未因此变成可执行规范。`tools/smoke/README.md` 已说明部分脚本依赖缺失的 `minutes_api_common.ps1`，不能作为新团队的统一验证入口。

处理：保留可追溯的历史证据；无维护者/无依赖闭包的脚本归档或退役，将有效验证迁到当前测试入口。生成 reports 不再手改状态。`vendor/jpush_flutter` 有实际 path 依赖、固定上游版本/哈希和补丁说明，`third_party/sqlite` 是构建输入，不能当缓存删除。`.git` 历史体积不会因工作树归档而下降；历史重写是独立决策，本轮不做。

## 删除、迁移和保留的明确边界

| 对象 | 建议 | 必要前提 |
| --- | --- | --- |
| report-only `ApiIntegrationReportEntry` | 移出生产包 | 更新 reporter 导入，输出语义回归 |
| 硬编码 docs working-tree 字符串 | 删除 | 无；若需要版本信息须真实采集 |
| 自动生成的 API latest/index 状态镜像 | 停止作为手工权威，改 CI artifact | 保存所需历史 receipt，修正生成路径及消费者 |
| 无生产调用的 retired/prohibited 方法与专用模型 | 删除候选 | 全调用/导出/测试替身核查，保留禁用旧请求的测试 |
| `backend_contracts` 聚合层 | 迁移有效 workspace retry 后拆除 | 不能直接删仍使用的 provider |
| `core/api` 兼容 export | 最后收敛删除 | 导入迁移与 analyzer 通过 |
| `ui_v3` catch-all / handwritten part | 拆职责后退役 | 不通过机械移动掩盖耦合 |
| `huahuo_api` clients、EndpointCatalog、幂等和鉴权 | 保留并按领域整理 | 变更协议前必须对照后端实现/协议 |
| 状态机、outbox/checkpoint、schema migration | 保留并明确 owner | 不能因“复杂”删掉恢复/数据保护 |
| native 单测、真实硬件证据、合法测试 fixture | 保留 | 区分历史证据与当前验证 |
| vendor SDK、sqlite 源码、lockfile | 保留 | 它们是可重复构建输入 |

## 目标依赖关系与交接验收

保留现有 workspace，暂不将 `src` 重命名为 `mobile`；更换顶层路径会牵动大量构建和工具，收益低于边界收敛。

组合根 → 业务 bootstrap/公开端口；页面 → 本领域 application；application → 本领域 domain/ports；data/native adapter → ports + transport/storage。跨业务编排归 app 的专门用例协调器，或只依赖双方公开端口，不能让 notification/chat 再成为全局依赖中枢。`core` 不依赖 app/features；共享视觉层不依赖业务。

长期任务要区分四个 owner：调度器负责执行资源与取消，领域用例负责状态转移，repository/ledger 负责持久化与恢复，通知负责投影与用户确认。现有 `TaskOrchestrator`、`ChatRunTracker`、recording ledger 不应无差别合成“万能任务引擎”。

每一步完成必须满足：改动范围明确；边界无新增逆向依赖；协议/账户作用域/生命周期保持；分析与相关测试通过；native/存储改动具备专项验证；文档只记录长期约束与决策。不要用“目录看起来整齐”“报告全绿”作为架构验收。

## API Integration 到底是什么

应把现有东西分成三层理解：

- **运行时 API 层**：`huahuo_api` 的 clients、`EndpointCatalog`、认证/幂等/响应解析是真正会被 App 调用的代码，不能因为报告混乱而删除。
- **契约层**：`ApiContractManifest` 记录路径、方法、authority、响应类型和 wired/contract-only/prohibited 状态，适合做编译期/静态一致性检查，但不是网络测试。
- **报告层**：`api_integration_report.dart` 生成 `reports/api-integration/latest.*`。它统计 manifest 与 catalog 是否有对应定义；配置 token 也不会发请求，结果里的 live status 明确写着 skipped。因此它现在应该叫“API contract consistency report”。

建议保留运行时 clients 和必要的契约测试，重命名/缩小报告工具，移除报告 DTO 对生产包的导出，删除无调用方的 retired/prohibited 空壳。真实联调另建 opt-in integration test，并把测试 receipt 与环境信息作为 CI artifact。

## 推荐实施顺序

1. 先修 quality gate、CI 工具链和 API 报告命名，建立可信基线；不改业务行为。
2. 删除已确认无调用方的退役 API 空壳和 report-only 运行时类型。
3. 拆 `app_providers` 循环依赖，建立 capability provider modules 和 import 规则。
4. 以 `ui_v3`、桌面 editor、notification projection 为第一批边界重构对象。
5. 统一数据库/storage owner，再拆录音卡 Dart/native transport。
6. 最后按热点文件逐步压缩债务；每一步运行格式化、analyzer、相关单测和依赖影响检查。

## 本轮验证记录

- `source_reachability_check.dart`：退出码 1，440/440 文件可达，报告 91 条架构/债务发现；其中已人工确认一次 stream cancellation 为误报。
- `quality_gate.dart pr --list`：退出码 0，仅验证步骤清单，不代表步骤通过。
- `quality_gate.dart --dependency-policy`：退出码 0。
- API reporter 此前前后各生成 215 operations、0 failures；这是 reporter 输出回归，不是 API 联调证据。
- 没有执行生产 smoke、服务器写操作或物理设备验证。
