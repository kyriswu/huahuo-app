# 深度定位报告未更新：真机证据与修复

本次事件：UTC 2026-09-17 / 北京时间 2026-09-18。
仅修改 Flutter；未修改后端、服务器文件、数据库或线上任务，未部署或重新投递 Run。

## 结论

不是模型没有生成结果，也不是请求持续失败。最新定位任务已经正常完成，服务端保留了
一份有变更的 ready 候选，但 Flutter 把可选的生成 Run 绑定误当成候选来源，因而
从未进入 apply。进一步检查发现来源核验还依赖后端不返回的 thread.purpose；
两处协议错误已一起修正，避免第一处修好后继续被第二处拦住。

## 证据来源

### 1. 物理 iPhone 与实时控制台

- `flutter devices` 选择物理设备 `00008030-00160CC92E7A802E`，名称 run的iPhone。
- `devicectl device info details` 确认 iPhone 11、iOS 26.6、wired/paired、开发者模式开启。
  真机容器复制及 Flutter attach 成功，未使用 iPhone 17 Pro Simulator 代替。
- 执行 `flutter attach` 后取得真实 Dart VM 会话；本次观察期间未收到可用于回溯此次
  定位的新增业务输出，不能据此推断任务没有执行。
- 使用 `d` 分离，未使用 `q`，未热重载/重启/重新安装。分离后进程清单仍有同一
  `Runner.app/Runner`，PID 63270。

### 2. 真机持久化 SQLite

完整 recordings 目录复制到 `/tmp/huahuo-device-log-audit.tN2gPe`，主数据库及 WAL/SHM
一起保留；全部 SQLite 查询使用 `-readonly`，未直接编辑真机容器。

- `diagnostic_logs` 122 条；最新定位状态在 `2026-09-17T17:33:13.163778Z` 为
  `completed:waitingForCandidate:ok`。
- `app_preferences` 内对应 `positioning.op.` 检查点有 7 个深度定位 Run，全部处于
  `waitingForCandidate`，proposalId/version/ETag/幂等键/内容摘要均未绑定。
- 最新 Run 创建于 `2026-09-17T17:30:28.697439Z`，Run 标识见后文。
- `local_recording_upload_drafts`、`recording_transcription_receipts` 各 1 条，记录时间
  是 UTC 9 月 16 日，属于另一个 user_scope，不能作为本次定位执行证据。
- `chat_run_checkpoints` 为 0 条；本次恢复事实来自定位偏好检查点，不把缺少聊天检查点
  解释成 Run 没执行。
- 可观测性缺口：定位状态日志只有 scope_hash 和聚合状态，缺少逐条 runId/proposalId
  关联信息及应用/正式回读阶段记录。使用偏好检查点、服务端任务和候选记录补齐关联；
  不单凭缺少某阶段日志断言该阶段从未执行。

### 3. 服务端任务与数据库（39 服务器，只读）

PostgreSQL 会话使用 `default_transaction_read_only=on`、10 秒 statement timeout，
并查询确认只读设置为 on。

```text
runId:
agent_run_user_d2adbdbf13d85dc73c0546217dd7707a19cbb3c2f7aa231e0b393f772351ebaf_workspace_chat_workspace_chat_run_6abc5c084e9f9322
threadId: thread_f61170e17f82865e2544bf03397804b5
proposalId: dcp_capture_37e2d2e12ac14477afff9259ef387829
```

- Run 为 `succeeded`、`completionMode=normal`、`agentProfileId=positioning_lv2`；
  UTC `2026-09-17T17:33:12.496202Z` 完成更新。
- 候选在 UTC `2026-09-17T17:33:10.802586Z` 生成，版本 1、7634 字节，
  `state=ready`、`has_changes=true`、`run_binding_state=pending`、`applied_at=NULL`。
- 候选 `owner_metadata.sourceRunId` 与真机最新 Run、候选版本表 agent_run_id 一致。
- 线程属于同一工作区，`scene=work_ai`，最新请求 profile 为 `positioning_lv2`。

### 4. 服务端 Nginx 访问日志（只读）

本次查询的 `/var/log/nginx/access.log` 中该候选有 58 次 GET，0 次 `/apply` POST。
候选详情及 Run 查询为 HTTP 200。结合数据库仍是 ready、applied_at 为空，证据表明
客户端一直在读取，未推进到应用候选；不是 apply 请求报错后反复重试。

## 根因与实现

后端实现与协议核对范围：

- `source/internal/services/digital_twin_draft_capture_service.go`：捕获候选写入
  SourceRunID，绑定状态为 pending，候选本身可以直接处于 ready。
- `source/internal/domain/document_change_proposal.go` 的 PublicView：只有 published
  绑定公开 `run.runId`；真正来源在 `target.metadata.sourceRunId`。
- `source/internal/services/chat_service.go` 的 GetThreadForAuth 与
  `source/internal/persistence/agent_run_repository.go` 的 LastThreadRequestProfile：
  返回线程 scene 和最近请求的 profile，并不返回 thread.purpose。
- 相关 SCM、变更协议及 Flutter 现有 API 解析器一并核对，未调整后端协议。

旧客户端在候选发现、检查点匹配、来源核验都使用 proposal.runId，因此合法的 pending
捕获候选被视为“不是本 Run 的候选”。即使绕过第一处，解析器对缺失 purpose 默认 general，
仍会被旧来源校验拒绝。此前测试构造了不符合真实返回形状的完整绑定/显式 purpose，
未覆盖这两个缺失字段场景。

修复仅涉及定位生命周期：

1. 增加定位专用来源解析函数，统一读取 canonical positioning owner 的 sourceRunId。
2. 候选发现、旧检查点恢复、详情校验和 apply 回执校验共享此来源，不修改通用绑定模型。
3. 按真实线程 scene 和解析器从 lastRequestProfile 得到的 positioning profile 核验；
   保留正常成功 Run、精确线程/工作区、当前登录身份及 owner 检查。
4. 继续沿用持久化版本/ETag/幂等键、候选摘要和正式原文回读；不把 Assistant 文本、
   旧缓存或“没找到候选”当作更新成功。

先更新对应 SCM，再修改源文件及测试；新增测试已登记 SOURCE_TREE。未更改其他功能。

## 验证与边界

- 先用 pending 且无 run.runId 的公开 DTO 复现原故障，再验证修复。
- 两份定向测试共 30 项通过：七个旧检查点中的最新任务恢复、跨设备发现、响应丢失/
  重启不重复应用、正式报告延迟回读、来源缺失与外部工作区/线程/profile 拒绝等。
- 5 个相关 Dart 文件静态检查无 error/warning；26 条 info 为现有风格提示，未扩大范围清理。
- `git diff --check -- Flutter` 通过。
- 本次没有运行全量测试、没有创建模拟器，也没有向真实账号发起 apply。
- 修复已在本地 Flutter 代码中完成，尚未重新安装到真机。服务器候选在只读审计结束时
  仍为 ready；安装修复版后可在定位报告页“继续恢复”现有任务，无需重做深度定位。
  实际线上 apply 与最终正式报告回读仍需在修复版运行后确认。
