# Docs 工作树到客户端同步审计报告

日期：2026-08-07  
性质：合同差异映射与客户端本地验收；不代表真实后端或支付 Provider 联调通过

## 1. 审计基线

- Docs 仓库：`/Users/run/huahuoai-docs`
- Docs 分支：`codex/membership-payments-v1`
- 固定 HEAD：`97e510c8b7e2a2e33cc4bbf809fa666e26983bd3`
- 固定 HEAD 作者：`YMX899 <YMX899@users.noreply.github.com>`
- Docs 工作树：15 个 tracked 修改文件，另有 1 个 untracked API 28 文件
- APP 仓库：`/Users/run/huahuoai-app`
- APP 分支：`Flutter-Desk-Mobile`
- APP 审计起点 HEAD：`0e4e58a7133a95ad22c2530fcf8665c49b803b5e`

本报告审计的是固定 Docs HEAD 之上的未提交工作树。API 28 及相关修改在被正式评审、提交并固定 commit 前，不应被描述为已经发布的生产协议。
Git 不记录未提交工作树内容的作者；因此不能把固定 HEAD 作者归因为这 16 个工作树文件的修改者，需要在 Docs 提交后才能获得可审计的 author/committer 信息。

## 2. Docs 差异分类

### 2.1 产品文档

| 文件 | 主要差异 | 客户端影响 |
| --- | --- | --- |
| `02-prd/v0.1-mvp/membership-and-billing.md` | 将 Android 微信/支付宝单次购买和 iOS App Store 订阅加入范围 | Mobile 需要正式会员页、平台差异文案、恢复购买和状态展示；仍存在旧状态与“无需在线支付”冲突，见 P1 |
| `02-prd/v0.1-mvp/prd.md` | 关闭 OQ-002，并把首批商品规则指向 DEC-007/API 28 | 无独立 DTO；Mobile/Shared 必须遵循 API 28，不能从旧 PRD 推断 wire 字段 |

### 2.2 业务规则

| 文件 | 主要差异 | 客户端影响 |
| --- | --- | --- |
| `03-business-rules/membership-subscription-plan.md` | 固定三个 SKU、Android 价格、iOS 本地化价格及 PRO/MAX 权益 | Mobile 商品卡和权益文案需要目录驱动；Work AI/Feed AI 继续禁止；后半部旧档位与能力矩阵仍需清理 |

### 2.3 服务端与系统设计

| 文件 | 主要差异 | 责任边界 |
| --- | --- | --- |
| `04-system-facing-design/account-credit-ledger-and-settlement-design.md` | 明确会员支付不生成可购买 credits | Shared/Mobile/Desktop 只读取 API 27；支付事实和 credits 结算隔离由 39 后端保证 |
| `04-system-facing-design/app-api-contract.md` | 增加 API 28 App 流程映射 | 客户端接 Catalog、订单、iOS 验单和交易记录；Provider callback 仅为服务端合同 |
| `04-system-facing-design/cross-cutting/observability-feature-flag-readiness.md` | 增加支付渠道 readiness、对账与独立 Outbox | 仅 39 后端/Ops；客户端只能消费 disabled/unavailable 状态 |
| `04-system-facing-design/database-schema-v0.1.md` | 增加支付商品、订单、交易、权益、回调事件和 Outbox | 仅 39 后端数据库；Flutter 不保存第三方交易事实或 Provider 凭据 |
| `04-system-facing-design/error-code-registry.md` | 增加 API 28 公共和 callback 错误 | Shared 负责保留 code/retry metadata，Mobile 负责用户文案；API 07 新 Secret 错误仍缺注册 |
| `04-system-facing-design/state-machines.md` | 增加 AndroidOrder 与 iOS entitlement 状态机 | Shared DTO 和 Mobile Controller 已按状态集合建模；`cancelled` 可用性语义仍冲突 |

### 2.4 API 文档

| 文件 | 主要差异 | 客户端影响 |
| --- | --- | --- |
| `05-api/02-endpoint-catalog.md` | 增加 8 个 API 28 操作 | 5 个用户侧操作进入 Shared/Mobile；3 个 Provider callback 只保留 Manifest 合同记录 |
| `05-api/07-assets-membership-notification-api.md` | Push Provider 收敛为 JPush，要求授权后注册、账号解绑和 Push Token Secret Ref | Mobile 已接权限门禁、注册、撤销和非敏感本地恢复标记；Secret Ref/AES-GCM 仅由 39 后端实现 |
| `05-api/27-account-membership-credit-api.md` | 将会员支付边界交给 API 28 | Shared、Mobile、Desktop 已接会员/credits/Run usage；正式响应 DTO 尚未同步 PRO/MAX 投影 |
| `05-api/README.md` | 将 API 28 加入正式协议索引，继续排除通用 Commerce | 文档索引变更，不单独产生页面或运行时调用 |
| `05-api/28-membership-payment-api.md`（untracked） | 新增 Catalog、Android 下单/查单、iOS 验单、交易记录和三类 Provider callback | Shared/Mobile 已建立合同和流程；响应 DTO、取消语义与额度投影仍需冻结 |

### 2.5 决策记录

| 文件 | 主要差异 | 客户端影响 |
| --- | --- | --- |
| `06-decisions/decision-log.md` | DEC-007 固定 Android 单次购买、iOS 自动续订及服务端授予权益 | Mobile 不得依据 SDK 返回直接开会员；Desktop 不提供购买入口 |
| `06-decisions/open-questions.md` | OQ-002 关闭 | 商品和基础权益不再由客户端临时配置；后续变价必须通过新 Catalog revision |

## 3. 跨端与后端映射

| 能力 | Mobile | Shared `huahuo_api` | Desktop | 39 后端 |
| --- | --- | --- | --- | --- |
| API 07 Push 注册 | JPush、用户授权后注册、登出/换号撤销、失败重试 | 使用统一 `ApiClient` 传递正式错误 | 不适用 | Token 加密、账号/设备绑定、投递 Worker |
| API 27 会员与额度 | 会员页读取会员、credits、Run usage | 严格 DTO 与 typed Client | 读取同一会员和 credits，无购买入口 | 当前会员投影、额度与 Run admission |
| API 28 Catalog | Android 价格取后端；iOS 价格取 StoreKit | SKU、tier、协议、平台目录 DTO | 不接购买目录 | 商品开关、协议版本、稳定 `appAccountToken` |
| Android 支付 | 下单、调用原生 Port、仅保存账号隔离的 orderId、轮询确认 | 下单和查单 Client、幂等 Header | 不适用 | Provider 下单、回调验签、订单与权益投影 |
| iOS 支付 | 启动监听 purchase stream；显式恢复；服务端验单后才 complete | 验单 Client 与 entitlement DTO | 不适用 | Apple 验签、账号绑定、通知 V2、续订/退款同步 |
| 交易记录 | Mobile 分页展示 | owner-scoped page，并拒绝私密 Provider 字段 | 当前无产品入口 | 返回脱敏交易事实和稳定游标 |
| Provider callback | 不可调用 | 仅 Manifest `contractOnly` 记录 | 不可调用 | 微信、支付宝、Apple 三条服务端入口 |
| Secret Ref | 不保存商户密钥、Provider Secret 或 Push Token 明文 | 请求/响应泄漏检查 | 不保存支付 Secret | Secret Ref 解析、密钥轮换、审计和 fail-closed |
| 对账/退款/Outbox | 只刷新服务端状态 | 只消费公开状态 | 只读取最终会员投影 | 全部由 39 后端负责 |

录音、ASR、声纹和实时转录继续由 101 服务负责；本次会员支付、会员投影、聊天和其他 App API 属于 39 服务边界，支付凭据不得进入 101 服务。

## 4. 已同步项

1. API 07 的 JPush-only、授权后注册、换号重新注册、登出撤销和 Token 不落盘边界已在 Mobile 代码与聚焦测试中表达。
2. Shared 已包含 API 27 typed membership/credit/Run usage Client，并被 Mobile 与 Desktop Adapter 使用。
3. Shared 已包含 API 28 的五个用户侧 Endpoint、Billing DTO、Client、幂等和私密字段拒绝逻辑。
4. Mobile 已包含平台化会员页、Android 订单恢复、iOS StoreKit 监听/恢复/验单后完成、交易记录分页及不可用状态。
5. 三条 Provider callback 已由主线程从客户端运行时 `EndpointCatalog` 移除；它们只保留在合同 Manifest，Mobile/Desktop 无法通过 endpoint id 发起请求。
6. Desktop 保持“读取会员权益、不提供购买入口”的产品边界。
7. Work AI/Feed AI 的 5 个禁止操作继续为 `prohibited`，必须在 Transport 前失败；会员购买不得解除该门禁。
8. 思想图谱本阶段继续使用本地测试数据库和真实交互式布局，不接 39 服务，也不恢复 Feed AI 调用。

以上“已同步”表示客户端代码路径和测试资产已经落地；本轮本地全量结果见第 7 节，但不等同于真机支付或生产后端验收通过。

## 5. 尚未解决的合同问题

### P1

1. **API 27 会员 DTO 与 API 28 冲突**：API 27 仍写死 `pilot_paid/active/expiresAt=null`，API 28 与客户端已使用 `free/pro/max`、有效期和完整 entitlement 状态。39 后端没有唯一可实现合同。
2. **API 28 响应 DTO 不完整**：尚未规范 `PaymentOrder`、微信/支付宝 launch payload、iOS verify 响应及 transaction item 的必填字段。当前客户端依赖 `orderNo/sku/provider/status/membership` 和 `transactionId/sku/status`，存在联调失败风险。
3. **取消续费语义冲突**：文档一处说 `cancelled` 在付费期内仍可用，另一处说 resolver 只接受 `active/grace_period`；客户端当前按后者判定。
4. **权益额度没有公开投影**：API 28 固定聊天次数、ASR 时长和存储额度，但 API 27 只返回通用 credits。客户端无法展示剩余聊天、ASR 和存储量，也无法以合同测试证明 39 后端已执行这些限制。
5. **产品文档保留旧结论**：会员 PRD 仍有 `trial/blocked` 旧状态及“不要求在线支付”；订阅能力矩阵仍把 Work AI/Feed AI 写成会员能力，与当前禁止策略冲突。

### P2

1. API 07 新增的 `PUSH_TOKEN_SECRET_UNAVAILABLE`、`PUSH_TOKEN_SECRET_WRITE_FAILED`、`PUSH_TOKEN_SECRET_RESOLVE_FAILED` 尚未进入全局错误码注册表，缺少 HTTP、可见性与重试规则。
2. API 28 没有冻结协议类型 wire value、平台必需协议集合、benefit code 和 `period` 值；Mobile 当前使用本地约定，后端可能产生兼容差异。
3. Provider callback 的 Provider 专用应答格式尚未在 API 28 中明确。客户端已移除运行时入口，但 39 后端仍需按微信、支付宝和 Apple 的正式协议实现应答。
4. Provider callback 当前只验证 Manifest 唯一记录和客户端运行时不可解析；逐接口报告不得把这类断言描述为 callback 网络请求/响应测试。

## 6. 39 后端专属清单

- `billing_products`、`payment_orders`、`payment_transactions`、`membership_entitlements`、`payment_callback_events` 和 billing Outbox 的迁移与事务约束。
- 微信、支付宝和 Apple Provider 配置、签名验证、时间窗、金额/币种、App/Bundle/Product 身份校验。
- `originalTransactionId` 永久账号绑定与跨账号冲突。
- 同级续期、独立 entitlement、退款/撤销、宽限期、对账和漏单补偿。
- `memberships` 当前权益投影、tier 优先级和聊天/ASR/存储额度执行。
- Push Token AES-GCM Secret Ref、密钥轮换迁移、Worker 内存解析及日志/响应脱敏。
- Provider/channel readiness、告警、审计与生产环境 fail-closed。

这些职责不应通过 Flutter Mock、客户端本地状态或 SDK 返回码替代。

## 7. 测试与 live 状态

- Workspace `flutter pub get`：PASS。
- Shared `huahuo_api`：`dart analyze` 0 issue，`dart test` 60/60 PASS；包括 198 条 Manifest、Provider callback runtime 隔离、API 24/25/27/28 合同和损坏响应。
- Mobile：全量 `flutter test` 1163/1163 PASS；`flutter analyze` 为 0 error、0 warning、170 info，低于 180 条基线。
- Mobile Agent/Chat/Workbench/Canvas 定向组合：102/102 PASS；Book/Work Controller/Widget：11/11 PASS。
- Desktop：`flutter analyze` 0 issue，`flutter test` 222/222 PASS。
- SCM：662 个有效文件 PASS；Dart source reachability：262/262 PASS；APP 与 Docs `git diff --check` PASS。
- 构建：Android debug APK PASS；macOS Desktop 无签名 Release PASS。Android/iOS 已签名 Release 仍待 Flutter 3.44.6、签名和 Provisioning Profile 最终验收。
- 未提供可用的 39 live base URL、正式测试账号/Token、已部署 API 28、微信/支付宝商户沙箱或 App Store Sandbox 验收条件时，所有 live 项统一记录为 `SKIPPED_NO_ENV`。
- `SKIPPED_NO_ENV` 只表示环境缺失，不表示接口 PASS，也不能作为真实支付、退款、续订、Push 投递或额度执行证据。
- 图谱本地测试路径不属于后端 live 验收项；其验收重点是本地数据可见、交互式节点/连线、点击与状态变化正常。

## 8. 建议收口顺序

1. 先修订 Docs 的 API 27、API 28、会员 PRD、订阅规则和 API 07 错误码冲突。
2. 依据最终 DTO 调整 Shared，再调整 Mobile；Desktop 只跟随 API 27 读取合同。
3. 由 39 后端完成数据库、Provider、Secret Ref、Outbox、对账和额度执行。
4. 更新逐操作报告，区分 Manifest、合同 Fixture、本地 UI、模拟器、真机和 live 后端证据。
5. 最后执行统一测试与真机/沙箱验收；缺环境项目保留 `SKIPPED_NO_ENV`，不得伪装成功。
