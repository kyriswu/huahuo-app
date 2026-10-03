# 国内 Android/iOS 会员支付客户端测试报告

- 报告日期：2026-08-07
- APP：`Flutter-Desk-Mobile`，HEAD `0e4e58a7133a95ad22c2530fcf8665c49b803b5e` 加当前未提交 `Flutter/` 工作树
- Docs：`codex/membership-payments-v1`，HEAD `97e510c8b7e2a2e33cc4bbf809fa666e26983bd3` 加 15 个 tracked 修改和 1 个 untracked API 28 文件
- 结论：**客户端合同、状态机和 Fail-closed 边界通过本地测试；Docs wire contract 尚未冻结，真实 Provider、39 后端部署和沙箱交易本轮未验收，不可据此开放生产支付。**

## 1. 本轮客户端同步

1. Shared 保留 API 28 的 8 条审计记录；Mobile 只可调用 Catalog、Android 下单、订单查询、iOS 验单和交易记录 5 条用户侧接口。
2. 微信、支付宝、Apple 三条签名回调已从客户端运行时 `EndpointCatalog` 移除，仅保留 `contractOnly` Manifest 记录；通用 `ApiClient` 也不能发起这些服务端入口。
3. Android 只持久化按账号隔离的安全 `orderId`，相同购买意图复用幂等键；支付 App 返回后仍等待服务端订单和会员投影确认。
4. iOS 启动时监听 purchase stream，但仅在用户点击恢复购买时调用恢复；服务端验单成功后才完成 StoreKit transaction。
5. 商品、协议、渠道、状态和交易记录均由正式 Controller 驱动；API 28 失败不会隐藏 API 27 已返回的会员事实。
6. 客户端拒绝金额、期限、内部权限、Provider Secret、receipt、purchase token 等私密字段；生产运行时不自动回退 Fake。
7. Desktop 只读取 API 27 会员/credits/Run usage，不提供购买入口。101 录音/ASR/声纹服务未进入支付链路。
8. Work AI/Feed AI 继续在 Transport 前禁止，购买会员不会解除该门禁。

## 2. 测试结果

| 范围 | 结果 | 证据摘要 |
| --- | --- | --- |
| Workspace `flutter pub get` | PASS | 根 Workspace 依赖解析成功 |
| Shared analyze | PASS | 0 issue |
| Shared full test | PASS | 60/60，包括 Billing、Manifest、callback 隔离和损坏响应 |
| Mobile analyze | PASS_WITH_INFO | 0 error、0 warning、170 info，低于 180 基线 |
| Mobile full test | PASS | 1163/1163 |
| API27 + Billing Controller/UI | PASS | 36/36；API27 7、Billing Controller 23、会员页 6 |
| Desktop analyze | PASS | 0 issue |
| Desktop full test | PASS | 222/222；含 API27 读取，无购买入口 |
| SCM check | PASS | 662 个有效文件 |
| Dart source reachability | PASS | 262/262 |
| APP / Docs `git diff --check` | PASS | 无空白或补丁格式错误 |
| 39 后端 live | SKIPPED_NO_ENV | 未提供本轮可验证的已部署 API 28、测试账号和 Token |
| 微信/支付宝真实交易 | SKIPPED_PROVIDER_CONFIG | 未验证商户沙箱、固定 SDK、回调和退款 |
| Apple Sandbox / Notifications V2 | SKIPPED_PROVIDER_CONFIG | 未验证 App Store Connect 商品、Sandbox 和通知地址 |
| Android debug APK | PASS | 已生成 `Flutter/src/build/app/outputs/flutter-apk/app-debug.apk`（184 MiB） |
| macOS Desktop 无签名 Release | PASS | `xcodebuild` 成功，已生成 72 MiB `huahuo_desktop.app` |
| Android release / iOS release | NOT_RUN_THIS_AUDIT | 仍需生产签名、Provisioning Profile 与 Flutter 3.44.6 最终验收 |

## 3. Docs 阻塞项

1. API 27 仍写死 `pilot_paid/active/expiresAt=null`，API 28 则引入 `pro/max`、有效期和 entitlement 状态；39 后端缺少唯一正式 DTO。
2. API 28 尚未冻结完整 `PaymentOrder`、Provider launch、iOS verify、transaction item 和 callback acknowledgement wire shape。
3. `cancelled` 同时被描述为“周期结束前仍可用”和“不进入 resolver”；客户端当前按更窄的 `active/grace_period` 规则 fail closed。
4. PRO/MAX 的聊天、ASR 和存储额度没有 API 27 剩余量投影，客户端无法诚实展示或验证余额。
5. API 28 仍是 Docs 未跟踪文件；在正式提交和评审前不能称为发布协议。

## 4. 上线前验收

1. 先修订并提交 API 27/API 28 DTO、取消续费语义、额度投影和 API 07 错误码。
2. 在 39 后端完成并部署 Provider、签名回调、Secret Ref、事务权益投影、Outbox、退款和对账，再用固定 Fixture 回归 Shared/Mobile。
3. Android 在安装真实微信/支付宝 App 的签名真机验收；iOS 使用 StoreKit Configuration 和 Sandbox 验收购买、恢复、续订、升级/降级、退款及 Notifications V2。
4. 最终使用要求的 Flutter 3.44.6 重跑全量测试和 Release 构建。本轮环境为 Flutter 3.44.5 / Dart 3.12.2。

完整 Docs 差异和责任映射见 `Flutter/reports/api-integration/docs-working-tree-sync-2026-08-07-zh.md`。
