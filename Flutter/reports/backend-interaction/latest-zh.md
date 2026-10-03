# Mobile/Desktop 后端交互详细审计报告

## 1. 报告信息

- 审计日期：2026-08-01（Asia/Shanghai）。
- 审计对象：Mobile、Desktop 共用的主业务 API，以及 Mobile 录音/ASR API。
- 主业务入口：`https://chuda.cc`，部署节点 39.107.250.25。
- 录音入口：`https://recording.chuda.cc`，计算节点 101.201.70.18。
- 协议基线：Docs commit `97e510c8` 的活动 API Catalog。
- APP 基线：当前 `Flutter-Desk-Mobile` 工作树。
- 真机证据：`run的iPhone`，iPhone 11，iOS 26.5.2，测试期间 Runner 正在运行。
- 禁止范围：Work AI/Feed AI 的 5 个端点。本轮对这 5 个端点的在线请求数为 0。

本报告不记录手机号、验证码、Token、签名 URL、完整用户 ID、录音正文、聊天正文或
服务端密钥。在线探测使用已经真实短信登录过的同一用户身份，未使用 Mock 身份；
测试 Token 为服务端生成的短期 Token，审计结束后未保存到工程或报告。

## 2. 证据等级与判定规则

为避免把推测当成线上事实，报告中的证据按以下四类使用：

| 标识 | 含义 | 能证明什么 |
| --- | --- | --- |
| `ONLINE_FACT` | 通过公网域名得到的真实 HTTP 结果、线上服务日志 | 当前部署版本的实际行为 |
| `DB_FACT` | 线上 PostgreSQL/Redis/系统服务的只读检查 | 当前部署数据、迁移和任务状态 |
| `SOURCE_INFERENCE` | 对当前线上 release 源码和 SQL 的只读核对 | 解释在线错误的代码路径，不单独代替在线证据 |
| `LOCAL_UNDEPLOYED_TEST` | 本机脏状态后端仓库的测试 | 只作为潜在问题线索，不代表 39/101 已部署版本 |

结果状态：

- `PASS`：在线请求成功且关键响应结构可解析。
- `FAIL_BACKEND`：请求已到服务端，因部署、数据库、运行时或服务端合同问题失败。
- `FAIL_CLIENT`：APP 合同清单、请求构造或客户端状态处理存在错误。
- `BLOCKED`：上游服务端条件阻止继续验证下游业务结果。
- `SKIPPED_PROHIBITED`：按要求禁止调用。

除特别注明外，GET 测试为只读测试。Mutation 只使用安全的空输入、无匹配查询、
测试幂等键或正式取消接口；没有创建真实业务内容。一次实时 ASR 会话和一次上传凭证
按服务端现有测试配置签发，均未上传内容并会自动过期。

## 3. 总体结论

| 领域 | 结果 | 主要责任侧 |
| --- | --- | --- |
| 短信登录、Token 识别、会话恢复 | PASS | APP + 主站 |
| 允许接口路由注册 | 174/185 已注册；11 个缺失 | 主站部署 |
| 首页、通知、资产聚合 | PASS，但存在字段泄漏 | 主站 |
| 热点推荐 | 首页可返回真实热点；Provider 为 degraded | 主站/热点 Provider |
| Workspace 内容与图谱 | FAIL_BACKEND | 主站 Workspace bootstrap |
| 搜索 | FAIL_BACKEND | 主站新旧内容索引未衔接 |
| Agent/Profile/Skill Catalog | FAIL_BACKEND | 主站发布数据 |
| 历史聊天读取 | PASS | 主站 |
| 新聊天发送与回复 | FAIL_BACKEND | 主站 Schema/Agent 发布/事务 |
| AgentRun | FAIL_BACKEND | 主站 Agent 发布与补偿 |
| 订阅 | FAIL_BACKEND | 主站代码与数据库 Schema 不匹配 |
| 会员、积分、Run Usage | FAIL_BACKEND | 主站缺表/迁移遗漏 |
| Material 列表 | FAIL_BACKEND | 主站 Material 查询/路径处理 |
| 录音上传、文件 ASR、最终转写 | PASS | APP + 录音节点 |
| 录音后处理写入 Workspace Note | FAIL_BACKEND | 录音节点 Note 重试/跨库设计 |
| 客户端录音终态轮询 | 已修复代码，待新包真机复验 | Mobile |
| Work AI/Feed AI | SKIPPED_PROHIBITED，0 次网络调用 | 按产品要求 |

当前最影响联调的不是网络可达性，而是后端部署版本与数据库迁移、公开 Agent 发布、
Workspace bootstrap 三者不一致。聊天、图谱、搜索、订阅和会员均因此无法完成端到端
成功验收；客户端不应通过 Mock 成功或改回旧内部 Agent 名掩盖这些问题。

## 4. API 路由全量审计

### 4.1 审计范围

APP Manifest 共 190 个操作：109 个正式操作、81 个兼容操作。其中 5 个
Work AI/Feed AI 操作为 `prohibited`，未调用；其余 185 个允许操作逐一使用精确
HTTP method 和 path 通过公网入口探测。未认证探测预期得到 401/400/业务校验错误，
只用于确认路由是否已注册，不执行真实业务 mutation。

结果：

- 174 个允许操作能够到达已注册路由。
- 11 个操作返回 404，线上部署源码也未找到对应路由。
- 5 个禁止操作没有被请求，主站审计时间窗中的调用数为 0。

### 4.2 缺失的 11 个路由

| # | Method | Path | 影响 |
| --- | --- | --- | --- |
| 1 | POST | `/api/v1/auth/refresh` | P0：Access Token 过期后无法刷新 |
| 2 | GET | `/api/v1/profile` | Profile 读取不可用 |
| 3 | POST | `/api/v1/profile` | Profile 创建不可用 |
| 4 | GET | `/api/v1/profile/{creativePositioningId}` | 定位 Profile 读取不可用 |
| 5 | POST | `/api/v1/profile/{creativePositioningId}/deactivate` | Profile 停用不可用 |
| 6 | POST | `/api/v1/profile/{creativePositioningId}/set-default` | 默认 Profile 不可用 |
| 7 | POST | `/workspaces/{workspaceId}/notes/{noteId}/generate` | Note 生成流程不可用 |
| 8 | GET | `/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}` | Proposal 查询不可用 |
| 9 | POST | `.../proposals/{proposalId}/apply` | Proposal 应用不可用 |
| 10 | POST | `.../proposals/{proposalId}/reject` | Proposal 拒绝不可用 |
| 11 | GET | `/workspaces/{workspaceId}/profile` | Workspace Profile 不可用 |

`POST /auth/refresh` 是最高优先级缺口。当前 Access Token TTL 为 2 小时，Mobile 的
认证恢复逻辑需要该正式端点；没有 Refresh 路由时，已登录用户在 Token 过期后只能
重新短信登录。这与此前“登录状态已失效”的用户现象一致。

### 4.3 禁止端点

以下端点本轮均为 `SKIPPED_PROHIBITED`，未进行路由探测、认证探测或业务探测：

1. `GET /work-ai/topic-generation/options`
2. `GET /work-ai/material-candidates`
3. `POST /work-ai/topic-generations`
4. `GET /feed-ai/messages/{messageId}/deposit-summary`
5. `POST /feed-ai/messages/{messageId}/retry-deposit`

但是 `ONLINE_FACT + SOURCE_INFERENCE` 显示：主站 App Config 仍返回
`workAiEnabled=true`、`feedAiEnabled=true`，线上源码仍注册相关路由，上传约束也仍
包含 `workAiVoice/feedAiVoice`。APP 侧已禁止 Transport 调用，但后端部署仍未完成
禁区收口。

## 5. 认证与租户边界

| 测试 | 在线结果 | 判定 |
| --- | --- | --- |
| App Config | HTTP 200 | PASS |
| 真实用户 `/me/status` | HTTP 200，用户 normal、Workspace ready | PASS |
| Workspace 列表 | HTTP 200，返回 1 个默认 Workspace | PASS |
| 无 Token 请求受保护接口 | HTTP 401 | PASS |
| 非法 Bearer Token | HTTP 401 `UNAUTHORIZED` | PASS |
| 不存在/非所属 Workspace | HTTP 404 `WORKSPACE_NOT_FOUND` | PASS |
| 空短信请求 | HTTP 200，业务码 `SMS_PHONE_INVALID` | 合同风格如此，校验生效 |
| 空登录请求 | HTTP 400 `BAD_REQUEST` | PASS |
| Token Refresh | HTTP 404 | FAIL_BACKEND |

真实手机号短信登录、Token 签发以及主站/录音服务对同一 Token 的识别均已通过。101
录音节点使用主站 Token 访问录音接口返回 200；同一个 Token 访问 101 上的主业务
`/me/status`、`/home`、`/chat/threads` 返回 401，说明录音节点的路由隔离有效。

## 6. 主站健康、部署和 Schema

### 6.1 Readiness

`ONLINE_FACT`：主站进程 active，但 `/readyz` 为 HTTP 503 degraded。22 项检查中
20 项成功、2 项失败：

- `accountCredit`: `schema_unavailable`
- `sseAdmission`: `RUNTIME_TRANSPORT_CONFIG_INVALID`

Runtime 本体可访问，2 个运行池 active，21 份 credential 可用；Provider 检查中
ASR、热点、模型、短信、存储均可用。热点子状态为 degraded：最近一次成功时间为
2026-07-29，最近 20 次有 2 次失败。

### 6.2 迁移状态

`DB_FACT`：主站 `schema_migrations` 最大版本为 69，但版本 68 缺失，现有记录从 67
直接到 69。当前部署代码已包含 Account/Credit 读取逻辑和 readiness 检查，数据库却
缺少以下表：

- `monthly_credit_periods`
- `account_credit_postings`
- `permanent_credit_lots`
- `account_credit_reservations`

由此导致：

- `GET /membership` -> HTTP 503 `SERVICE_BUSY`
- `GET /account/credits` -> HTTP 503 `SERVICE_BUSY`
- `GET /runs/{runId}/usage` -> HTTP 503

这是明确的“部署代码先于数据库 Schema”问题。应先恢复迁移链并验证回填，不应在
客户端把 503 解释为未登录、网络失败或零积分。

### 6.3 基础设施

- Redis：PASS。
- 主站磁盘使用约 85%，需要运维清理，但不是本轮业务错误的直接根因。
- `chuda.cc` TLS 校验成功，证书有效期 2026-07-08 至 2026-10-06。
- `recording.chuda.cc` TLS 校验成功，证书有效期 2026-08-01 至 2026-10-30。
- 两个域名 App Config 均可在约 170ms 量级返回，公网连通性正常。

## 7. Workspace、内容、图谱与搜索

### 7.1 同一 Workspace 状态自相矛盾

| 接口 | 结果 |
| --- | --- |
| `/me/status` | Workspace `ready` |
| `/workspaces` | 默认 Workspace `ready` |
| `/workspaces/{id}` | HTTP 409 `WORKSPACE_NOT_READY` |
| `/content-navigation/overview` | HTTP 409 `WORKSPACE_NOT_READY` |
| `/content-navigation/notes` | HTTP 409 `WORKSPACE_NOT_READY` |
| `/content-navigation/assets` | HTTP 409 `WORKSPACE_NOT_READY` |
| `/content-navigation/book` | HTTP 409 `WORKSPACE_NOT_READY` |

`DB_FACT`：全库有 135 个状态为 ready 的 Workspace，其中 134 个没有 bootstrap
receipt；全库仅 5 条 receipt。目标默认 Workspace 状态为 ready，但没有 receipt。
数据库中也没有应强制 ready/receipt 一致性的 contract trigger，只有 owner identity
相关 trigger。

根因不是客户端 workspaceId 选错，而是服务端把状态字段推进到 ready，却没有完成
或回填 bootstrap receipt。图谱的四个分支因此全部被服务端 admission 阻塞。

### 7.2 内容快照和游标

| 测试 | 结果 |
| --- | --- |
| Content snapshot | HTTP 200，但 `atCursor="0"`，folders/objects 均为 0 |
| Changes 不带 `after` | HTTP 400，参数校验正常 |
| Changes `after=0` | HTTP 200，空列表 |
| Folder 列表 | HTTP 200，空 |
| Note 列表 | HTTP 200，空 |
| Note Folder 列表 | HTTP 200，空 |
| Note Type 列表 | HTTP 200，空 |
| Creation/Book Revision/Work 列表 | HTTP 200，空 |

Docs 明确 bootstrap cursor 不应固定为 0。当前 snapshot 的 `atCursor=0` 与缺失 receipt
相互印证，说明 Workspace 新内容合同没有完成初始化。

### 7.3 搜索

使用不会命中用户内容的安全关键词请求正式搜索接口，返回 HTTP 503
`WORKSPACE_SEARCH_UNAVAILABLE`。

`DB_FACT`：该 Workspace 的旧搜索体系有 11 个 document、188 个 chunk、63 个 job
（48 succeeded、15 dead_letter，错误为 `ROTATION_GENERATION_SUPERSEDED`）和 11 条
outbox；但新的 common content cursor 小于等于 0。服务端因此主动拒绝 SearchContent。

结论：旧搜索数据存在，但新 Workspace Content bootstrap 未完成，搜索和新内容合同
没有衔接。客户端不能靠重试解决。

### 7.4 Fixed Asset 错误语义

Fixed Asset 列表 HTTP 200 且为空，但分别读取 `experiences`、`knowledge`、`insights`、
`expression_patterns`、`methods` 时均返回 HTTP 400
`FIXED_ASSET_KIND_INVALID`。这些 kind 是合法值；不存在资产应返回空/404，而不是
“kind 非法”。这是服务端把资源不存在与枚举非法混为同一错误。

## 8. 首页、热点、通知与资产

| 测试 | 结果 | 备注 |
| --- | --- | --- |
| `/home` | HTTP 200 | 返回真实非空 hotspot，primaryAction=`view_hotspot_suggestion` |
| `/notifications` | HTTP 200 | 返回 23 条 |
| `/assets/overview` | HTTP 200 | creativePositioning 1、hotspot 1 |
| `/assets/markdown` | HTTP 200 | 可解析 |
| 旧 `content_line` 资产详情 | HTTP 403 `ASSET_PATCH_NOT_ALLOWED` | 旧/退役类型，不应恢复新接线 |

首页热点已恢复到“接口成功且有真实内容”的程度，但 Provider 子状态仍 degraded，不能
宣称热点流水线完全健康。

`ONLINE_FACT`：Home hotspot 响应仍包含 `relativePath`、`userId`、`workspaceId` 等内部
字段。当前客户端有防御性过滤，但后端不应把本地路径、内部用户/Workspace 标识放入
公开响应，应在序列化层移除。

## 9. Agent、Profile、Skill 与 Model Catalog

附件中的公开路由要求使用 `renshe_content`、`huoke_content`、`faya_germination`、
`visual_chat` 等公开 Profile ID，并按 Catalog 中 selectable/installed/enabled/available
状态决定是否启用。线上实际结果不满足该合同。

### 9.1 在线结果

- `/agent-profiles` HTTP 200，但唯一项是禁止领域的 `work_ai`。
- `/agent/meta-workspaces` HTTP 200，但唯一项也是 `work_ai`。
- `renshe_content`、`huoke_content`、`faya_germination`、`visual_chat`、
  `self_media_creation` 的 skills/models 查询为 HTTP 200 空列表。
- `deep_positioning`、`video_analysis` 的 skills/models 为 HTTP 409
  `AGENT_PROFILE_NOT_SELECTABLE`。
- Skill installations HTTP 200，但为空。

### 9.2 数据库证据

数据库 Agent Profile 使用旧内部 ID，例如 `agent_renshe_neirong`、
`agent_huoke_neirong`、`agent_faya`、`agent_self_media_creation`、`agent_work_ai`；目标
公开 ID 没有对应行或明确映射。当前只有 `agent_work_ai` 有有效 publication。

Skill 也仍以内部 ID 为主，只有 `skill_general_chat` 有 current publication。人设、获客、
Sprout、视觉对话等目标 Skill 没有完整发布版本。

结论：APP 使用公开 Profile/Skill ID 的方向正确；后端 Catalog 数据仍停留在内部身份，
且把被禁止的 Work AI 暴露为唯一可选 Agent。应修复发布和公开映射，不能要求客户端
发送内部 Agent 名或隐藏 Prompt。

## 10. 聊一聊与 AgentRun

### 10.1 历史会话读取

真实用户有 3 个 active thread，列表和详情均 HTTP 200：

- 1 个线程为空。
- 1 个线程有 12 条消息、4 个 succeeded task。
- 1 个线程有 3 条消息、1 个 succeeded task。
- user/assistant/system 消息均有 `createdAt`，历史消息时间显示的数据基础存在。
- 线程有 title、createdAt、updatedAt；列表缺少 `lastMessageAt` 和 `messageCount`。
- 现有三个历史线程 scene 均为旧 `work_ai`，需要后端迁移或只读兼容，不能用于新请求。

附件提到的 `/chat/threads/{id}/resources` 不在固定 Docs Catalog，线上三个线程均返回
404。客户端不能把它当活动合同依赖。

### 10.2 新消息发送

审计请求使用正式 API 19 结构：公开 `agentProfileId=renshe_content`、公开 Skill
`renshe_content_creation`、有序 `input.content[]` 文本，未发送内部 Agent 名、Prompt、
本地路径或整篇同步正文。

结果：HTTP 503 `SERVICE_BUSY`。本次请求没有进入任何 Provider downstream log，说明
失败发生在模型调用前。此前同一真机请求曾返回 HTTP 422
`META_WORKSPACE_UNAVAILABLE`；当前部署虽然推进得更远，但仍被 Schema/Agent admission
阻塞。

因此“聊一聊回复是否正确”当前为 `BLOCKED`，不是请求格式错误，也不是手机网络错误。

### 10.3 AgentRun 与失败事务残留

直接使用同一公开 Agent/Skill 创建 AgentRun，返回 HTTP 503
`AGENT_RELEASE_UNAVAILABLE`。Run read 与 event page 可读取，但 usage 因积分表缺失返回
503。

更严重的是，失败的 Chat 和 Run 请求在数据库留下 2 个 `planning` AgentRun，事件页均
为空，长时间不进入 terminal：

- 直接 Run 使用正式 `{"reason":"user_cancelled"}` 成功取消，HTTP 202。
- Chat 关联 Run 使用同一正式取消请求两次均返回 HTTP 500 `INTERNAL_ERROR`。
- 审计结束时仍有 1 个 Chat 关联测试 Run 停留在 planning，无法通过公开 API 清理。

这是服务端事务/补偿错误：HTTP 失败不应遗留不可取消的 planning Run。该残留已在此
报告记录，未直接修改线上数据库。后端修复时应同时清理该审计 Run，并增加失败回滚、
超时终止和幂等取消测试。

## 11. 订阅、会员、积分与 Material

### 11.1 订阅

以下已使用真实 ID 或有效列表参数验证，均返回 HTTP 500 `INTERNAL_ERROR`：

- Publication 列表与详情
- Publication Section 列表
- Article 列表与详情
- Revision 列表
- Workspace Subscription Library

`DB_FACT`：数据库实际有 59 个 publication、27 个 article、59 个 sync state、1 个
subscription，不是“无数据”导致。

`SOURCE_INFERENCE`：部署 Repository SQL 期待 `source_publication_id`、`summary`、
`section_count`、`article_count`、`source_lifecycle`、`moderation_state` 等新字段；线上
`subscription_publications` 仍是旧列结构。sync state 表也缺少新 SQL 期待的 `status`
字段。代码和数据库 Schema 不匹配是 500 的直接根因。

### 11.2 会员、积分与用量

会员、积分、Run Usage 均因 Account/Credit 表缺失返回 503，详见 6.2。客户端应显示
明确不可用状态，不得当作免费会员、0 余额或登录过期。

### 11.3 Material

`GET /workspaces/{id}/materials` 返回 HTTP 500 `INTERNAL_ERROR`，目标 Workspace 即使
没有 Material 也无法得到正常空列表。全库有其他 Workspace 的 2 条 Material，说明
路由已经进入 Repository/转换路径，而不是 Catalog 完全缺失。

线上错误日志与本地后端相关测试都指向 Material 路径/投影处理，但精确线上堆栈仍需
后端增加安全错误日志后复测。

## 12. 录音、上传、ASR 与独白

### 12.1 路由隔离与认证

- 主站 Token 请求录音列表和录音卡文件：HTTP 200。
- 无 Token/非法 Token：HTTP 401。
- 同一 Token 请求 101 上的主业务接口：HTTP 401。
- 101 只在 VPC 地址监听 18080，公网 TLS 由 39 入口终止。

### 12.2 真实录音状态

目标用户有 3 个真实 Recording：

| Recording 状态 | 最终转写 | 生成资产 | 后处理子任务 |
| --- | --- | --- | --- |
| `final_transcript_generated` | 非空 | 5 | 2 |
| `transcribed` | 空 | 5 | 0 |
| `final_transcript_generated` | 非空 | 5 | 2 |

Recording detail、speaker panel、ASR task 均 HTTP 200。前一轮真机录制、上传、创建
Recording、Tencent 文件 ASR、说话人标注均有成功请求证据。ASR 确实生成了真实最终
文本，不是 Mock 成功。

全局任务状态：

- `asr_tasks`：failed 1、final_transcript_generated 8、transcribed 16、transcribing 1。
- Tencent Provider Job：failed 6、transcribed 25。
- Volcengine Provider Job：transcribing 1。
- Recording Asset：transcribed 16、final 后 minutes queued 8、queued 1、failed 1。

这说明 ASR 主链路可用，但仍有失败任务和大量后处理积压。

### 12.3 Note 后处理故障

101 Worker 日志重复出现：

```text
recording postprocess worker error: note create with initial part: NOTE_NOT_FOUND
```

`DB_FACT`：101 中目标用户已有 2 个 active recording note，均有 current raw
part/revision；`note_idempotency_records` 也有 2 次 note_create success。因此错误不是
最初 Note 从未创建，而更可能发生在后处理重试的 readback、补偿或跨事务可见性路径。

同时，39 主站该 Workspace 的 Note 列表为空，而 101 本地数据库有 2 个 Recording
Note。录音节点在隔离数据库创建 Note，不会自动让主站 Workspace 看见，形成明确的
跨服务数据分裂。应由主站 Workspace API/事件总线承接沉淀，或建立可靠同步与幂等
回放，不能只写 101 本地库。

### 12.4 实时会话状态收敛

全局实时会话：expired 2、failed 1、issued 19。19 个 issued 中有 18 个实际上已经超过
expiresAt，但状态仍是 issued。虽然容量计算可按 lease 过期时间释放，运营状态和故障
统计没有收敛，需要 expiry reaper 或读取时状态归一化。

受控测试中：

- 创建实时 ASR 会话 HTTP 201；同一幂等键重放返回 409
  `REALTIME_ASR_SESSION_CONFLICT`。因响应含一次性临时凭据，服务端当前不允许重放。
- 创建上传 Token HTTP 200；没有上传内容，凭证会自动过期。
- 空 Recording 创建 HTTP 400；不存在 ASR retry HTTP 404，校验正常。

101 的 `/readyz` 为 503：17 项检查仅 9 项通过，失败项包括 runtime、Redis、Provider、
SSE 等完整主站依赖。录音 API 和文件 ASR 实际可用，说明 recording-only 节点复用了
不适合其职责的全栈 readiness。应拆分 liveness、录音核心 readiness 与完整 Runtime
readiness，避免编排系统误判。

## 13. 客户端问题与本轮已有修复

此前 Mobile 把 `final_transcript_generated` 继续映射为“生成纲要中”，即使真实最终
转写已可用，也会每约 3 秒读取 Recording detail，最长 200 次。真实日志曾记录 230 次
详情读取，并同步触发主站联邦 `/me/status`，造成不必要流量。

当前工作树已按 SCM 先行规则修复：

- 增加 `resultReady`，区分“最终转写可用”和“服务端完整归档终态”。
- 出现真实非空 final transcript 后停止前台轮询。
- 不伪装成 completed/deposited；重新进入详情仍读取最新后处理状态。
- 录音卡可用真实最终文本完成本地知识沉淀，不等待故障中的 Workspace 后处理。
- 没有服务端纲要时保持为空，不生成假纲要。

该修复已通过自动化，但尚未把新包重新安装到真机，所以状态为
`FIXED_IN_CODE_PENDING_DEVICE_RETEST`。

本轮详细后端审计新发现一个 APP 清单问题：

```text
markHotspotSuggestionViewed: connected endpoint has no production adapter
```

即 Endpoint 被标记为 connected，但生产 Adapter 未实现。应在后续客户端改动中补齐
正式 Adapter，或把状态降为 contractReady；本轮只写报告，没有修改 Flutter 源码，
避免把服务端审计与未经页面回归的客户端改动混在一起。

## 14. 请求统计与可观测性

主站本轮认证业务审计窗口的响应聚合：

| HTTP/业务结果 | 次数 | 说明 |
| --- | ---: | --- |
| HTTP 200 | 78 | 大部分读取/校验成功 |
| HTTP 202 | 1 | 直接 Run 取消成功 |
| `FIXED_ASSET_KIND_INVALID` | 5 | 合法 kind 被错误分类 |
| `INVALID_ARGUMENT` | 13 | 包含有意的空输入/参数校验 |
| `WORKSPACE_NOT_READY` | 6 | Workspace 详情与图谱 |
| `INTERNAL_ERROR` | 10 | 订阅、Material、Chat Run 取消等 |
| `SERVICE_BUSY` | 5 | Chat、会员、积分、usage 等 |
| `AGENT_PROFILE_NOT_SELECTABLE` | 4 | 未发布 Profile |
| `AGENT_RELEASE_UNAVAILABLE` | 1 | 正式 Run 创建 |
| `WORKSPACE_SEARCH_UNAVAILABLE` | 1 | 搜索 bootstrap 缺失 |
| 其他 403/404 | 少量 | 旧资产、Book、租户边界验证 |

101 审计窗口：19 次 HTTP 200、1 次 201、1 次 400、5 次 401、1 次 404、1 次 409。

Chat/Run 在 Provider 调用前失败，主站没有 downstream request log，符合 admission/
Schema 根因。101 的 Tencent STS/Provider 签发在审计窗口也没有 downstream log，存在
可观测性缺口；建议为每次外部 Provider 请求记录脱敏 provider、operation、latency、
status、providerRequestId 和内部 traceId。

## 15. 自动化与本地测试

### 15.1 APP/共享包

| 测试 | 结果 |
| --- | --- |
| `huahuo_api` Manifest/Domain Client | 15 PASS |
| Mobile Auth/Chat/Recording/Contract/Hotspot 定向测试 | 36 PASS |
| 前一轮 Mobile 全量测试 | 1060 PASS，0 FAIL |
| 前一轮 Mobile analyze | 0 error、0 warning、174 条既有 info |
| SCM Check | PASS |
| Backend Contract Check | FAIL 1：热点已连接 Endpoint 无生产 Adapter |

### 15.2 本地后端仓库（非线上部署结论）

本机 `/Users/run/huahuo-ai-backend/huahuoai-backend` 已有大量用户修改，且不是线上
release 的纯净副本。执行：

```text
go test ./internal/services ./internal/persistence ./internal/api/routes ./internal/workspace
```

结果：persistence PASS；其余共 14 个失败，包括 1 个 Retention、3 个 Material Route、
10 个 Workspace Note/Material/Path 测试。主要错误为 `MATERIAL_PATH_INVALID`、
`NOTE_PROJECTION_FAILED`、`WORKSPACE_FORBIDDEN invalid workspace root`。

这些只作为修复线索。39 的部署目录没有 Go 工具链，无法对同一线上源码原地执行该组
测试，因此不能把 14 个本地失败直接记为 14 个线上回归。

## 16. 建议的后端修复顺序

### P0：恢复基础合同

1. 补齐并部署 `/auth/refresh`，验证 2 小时 Token 过期、Refresh 轮换、重放和撤销。
2. 修复迁移链：查明缺失的 68，创建 Account/Credit 表，保证 readiness、会员、积分、
   Run Usage 一起恢复。
3. 修复 Workspace bootstrap：为 ready Workspace 回填 receipt/cursor，并增加
   ready 必须有 receipt 的数据库约束或原子状态机。
4. 迁移并发布公开 Agent/Profile/Skill/Model Catalog；禁止 `work_ai` 成为唯一公开项。
5. 修复 Chat/Run 失败事务：失败不留 planning Run，Chat 关联 Run 可取消，可由超时
   reconciler 收敛；清理本轮遗留的 1 个审计 Run。

### P1：恢复主要产品能力

6. 执行 Subscription Schema 迁移或回滚不兼容 Repository，消除全部订阅 500。
7. 修复 Material 空列表和路径转换，增加线上安全错误上下文。
8. 完成 SearchContent 与 common content cursor 的 bootstrap/reindex 衔接。
9. 修复录音 Note 后处理的重试/readback，并解决 101 本地 Note 与 39 主站 Workspace
   的跨库数据分裂。
10. 补齐 Profile、Note Generate/Proposal、Workspace Profile 共 10 个缺失业务路由。

### P2：安全性与运维质量

11. 从后端 App Config、Route、Upload constraint 移除 Work AI/Feed AI 暴露。
12. 从 Home 响应移除 `relativePath` 和内部身份字段。
13. 将合法但不存在的 Fixed Asset 与 invalid kind 使用不同错误码。
14. 为 recording-only 节点拆分 readiness；增加实时会话 expiry 状态收敛。
15. 补全主站与录音 Provider downstream log，清理两台服务器磁盘。

## 17. 修复后的复测门槛

后端修复不能只以 `/readyz` 变绿作为完成标准，至少逐项满足：

1. Refresh Token 在真实登录后跨过 Access Token TTL 仍能恢复会话。
2. 同一 Workspace 在 me/list/detail/graph 上统一为 ready，snapshot cursor 非固定 0。
3. `renshe_content` 与对应 Skill/Model 在 Catalog 可选、有 publication 和 revision。
4. 聊天消息返回持久 assistant message，时间字段存在；Run 达 terminal 且 events/usage
   可读，失败请求不残留 planning。
5. 首页热点仍成功，图谱四分支、搜索、订阅、会员、积分、Material 不再返回
   409/500/503。
6. 新录音从上传、ASR、最终文本到主站 Workspace Note 可见完整闭环，重复重试不产生
   重复 Note/Part。
7. 五个 Work AI/Feed AI 禁区端点在 APP 侧保持 0 Transport 调用，后端不再公开启用。

## 18. 最终判定

网络、TLS、短信登录和 Token 识别正常；录音上传与真实 ASR 主链路可用，历史聊天读取
正常。当前核心失败集中在后端部署一致性：主站缺迁移、Workspace bootstrap 不完整、
公开 Agent 发布缺失、订阅 Schema 过旧，以及录音后处理跨库不闭环。

因此当前版本不满足“后端交互全面正常”的验收条件。优先完成 P0 后，应使用同一真实
手机号和同一物理 iPhone 重跑登录恢复、首页热点、聊一聊发送/回复、图谱、搜索、
订阅、会员、录音沉淀，并把 HTTP trace、Run event、Provider downstream log 和最终
数据库状态关联到同一 traceId，才能确认问题真正闭环。
