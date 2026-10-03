# 自由创作全入口与多轮聊天补充验收

测试时间：北京时间 2026-09-17（原始日志 UTC 2026-09-16）。
本文补充 `canvas-simulator-state-audit-20260917.md` 的第一阶段 Skill/状态机验收；
第一阶段的 169 个原生用例、340 个 host 用例不是本轮新增数量。

## 环境及执行边界

- 使用 Device Hub 已存在的 iPhone 17 Pro / iOS 26.5，UDID
  `DC53F410-8577-4601-BC10-70A7BB931E04`，未创建、清空或替换模拟器。
- Xcode DeviceInteraction 要求 iOS 27，不能驱动这台 26.5 设备；实际用 Flutter
  `integration_test` 在同一 Simulator 上操作真实 Flutter 控件，并读取原生截图。
- 真实联调使用当前登录态及生产 API `https://chuda.cc`；未注入身份、伪造云端
  响应或直接修改应用 SQLite。仅创建测试内容、修改明确标记的测试笔记。
- 开始前及聊天竞态发生后分别备份模拟器容器。后端源码与协议只读；服务端未部署、
  重启、迁移或修数据。其他任务的链接导入代码和文档没有纳入本次修改。
- “真实链路”与“受控依赖状态矩阵”分开统计：后者使用可控异步/API 夹具制造失败、
  并发、账号隔离等状态，不声称这些请求均访问过生产服务。

## 已确认并修复的根因

### 1. 连续聊天的新一轮被绑定到上一轮 Run

真实外部世界入口连续聊天，在第二轮完成后立即发送第三轮复现：第三个服务端 Run
已经成功，但本地只有两条 Canvas 回执；第三轮局部选区的临时 user ID 被绑定到
第二轮 Run 和第二轮 assistant，覆盖了第二轮回执。

根因不只是临时/正式消息 ID：轮询路径已经发布最终 Assistant，但终态回读队列
仍保留旧 Run；下一轮 reducer 优先读取旧 completion。同时，旧轮询的异步返回
只校验 Thread，没有校验新一轮已取得所有权，可能覆盖新的消息/nextAction。

修复位于 `chat_controller.dart`：

- 发布 Turn 之前，原子清理已有持久 Assistant 的成功 completion；streaming/pending
  内容不得冒充持久回复。
- 文本提交、重试、Thread 选择共用 generation 边界。轮询的等待、Run 读取、消息
  读取、finally 以及终态回读返回均校验所有权；旧请求不能接管或阻塞新 Run。
- 轮询路径自己持久化最终消息缓存，不再依赖冗余终态回读间接落盘。

两个确定性调度（completion 在轮询之前/期间到达）均在原实现失败，修复后通过；
补充缓存断言曾捕获移除冗余回读后的落盘缺口，已一并修正。
真实外部世界入口已重新完成五轮、保存、再进空白 Canvas，无 pending 残留。

### 2. 合法外部文章没有自由创作入口

外部文章 DTO 只有 Article revision，原准入错误要求 Note Raw revision，实际阅读器
不显示自由创作。只读确认后端 Article 协议后，外部订阅/知识广场 Raw seed 使用
Article revision；自有笔记仍使用对应 Note Part revision。未伪造可写 Note 身份。

### 3. 冷恢复误报“原笔记已变更或删除”

真实日志显示恢复前后的绑定指纹完全相同，但等待结束时 Library Provider 已换为
另一实例，尚未加载缓存。现在只在当前有效 Library 完成缓存恢复后校验绑定；在
“继续上次创作”弹层返回后再次确认当前 owner。真正的内容冲突仍拒绝覆盖。
“弹层期间替换 Library + 延迟缓存”用例原实现失败，修复后通过。

### 4. 等价 Session 刷新重建笔记依赖

同步 Journal、Workspace 同步工厂、Folder/Note Port 只订阅已就绪 Workspace 标识及
原有账号 scope，避免不相关 Session 通知触发重建。账号/Workspace 改变的隔离不变。
真实根 Provider 依赖身份用例原实现失败、修复后通过。这减少无效重建，但不假设
Library 永远不替换；第 3 项仍单独处理合法替换。

### 5. 冷启动通知期间 dispose

原生日志捕获 Knowledge 通知中重入依赖重建，导致 Subscription Controller 在
notifyListeners 时 dispose。运行时协调移至微任务，检查 mounted 和当前 Library
身份后执行原有 scope/入场检查。没有吞异常或放松账号校验。后续真实启动未再出现
该断言。新增受控测试在旧实现也能通过，故不把它当作精确负例复现证据。

### 6. 外部世界卡片溢出

402pt 窗口下长标题卡片固定高度产生 7px overflow。改为正文决定自然高度、封面跟随
容器的布局，保留最小高度；不靠缩字、截掉按钮或忽略错误。1.0/1.3 字号夹具检查
页脚边界及真实点击，原生后续进入无该溢出。

### 7. 深度洞察入口的已销毁详情控制器继续通知

补测深度洞察时原生断言：`FeedItemDetailController.refreshDerivedParts` 在远端
回读完成后访问已被 Provider 替换并销毁的实例。确定性测试先启动 Library 回读，
再 dispose 详情控制器，原实现稳定抛出同一异常。现在在读请求前及 await 后校验
详情生命周期，退休实例不再更新状态、登记任务、通知或启动轮询；Library 的成功
结果仍保留，新详情可以读取。没有阻断已接受 Outline/Sprout Run 的持久后台交接。

## 入口与多轮覆盖

每个真实入口执行：五轮同一 Thread、唯一 user/Run 身份、首轮双击发送拦截、pending
期间关开聊天与普通/AI 模式切换、每轮关开面板、记忆追问、局部选区、正文变化后的
新快照、双标记复述、对话历史、正文不被普通回答修改、真实云保存及保存后再次进入。

| 实际入口 | 本轮结果 |
| --- | --- |
| 知识广场 / 外部世界文章阅读器 | 五轮、保存、再次进入通过 |
| 普通笔记 / Raw | 五轮、保存、再次进入通过 |
| 今日推荐 | 五轮、保存、再次进入通过；首次驱动未滚回 A 的误报已纠正并复测 |
| 工作台 A 空白 | 五轮、保存、再次进入通过 |
| 账号页创作历史 | 五轮、更新原测试 Note、再次进入通过 |
| Canvas 菜单创作历史 | 五轮、再次更新同一测试 Note、再次进入通过 |
| Canvas 菜单新建笔记 | 放弃当前测试草稿并新建，五轮、保存、再次进入通过 |
| 外部世界已订阅文章 | 实际切换“我的订阅”→既有栏目→文章，五轮、保存、再次进入通过 |
| 普通笔记 / 纲要 | 五轮、保存、再次进入通过 |
| 普通笔记 / 深度洞察 | 修复后五轮、保存、再次进入通过；使用测试笔记的真实派生内容 |

以上 **10 类真实入口各完成 5 轮，合计 50 轮通过**，不包含中途失败重试产生的额外
请求。两种历史入口连续编辑并保存的仍是 `manual-335a5b8c`，没有另建副本。

受控入口矩阵覆盖全部 15 种素材来源：自有来源的 Raw/纲要/深度洞察及两种外部
阅读器的 Raw，共 41 种来源/阶段组合。每一种先测试真实详情按钮的导航 seed，
再执行五轮 Canvas 聊天，不把路由兼容参数误称为新增可见入口。

另有 26 轮长对话：52 条控制器消息，跨越可见窗口 30 条及持久回执 24 条的边界；
保留同一 Thread、唯一幂等键、最近 24 条回执及可继续发送/编辑状态。

### 额外第六轮差分与失败恢复

在独立 `20260917diff-blank` 会话中，前五轮完成后请求第六轮局部差分。Run
`2d73369f5f1e3778` 已 succeeded，并持久化正式 Assistant；但差分没有进入成功预览。
只读 SQLite 的实际回答包含普通删除/新增行，没有 `\ No newline at end of file`
标记。当前 Chat 协议发送的是 trim 后的正文快照，目标末行没有换行；这个返回缺少
必须的末尾换行语义，现有校验正确拒绝为 `CANVAS_AI_DIFF_INVALID`。测试指令也未
要求该标记，因此不能把这次失败归因于新的 Flutter 状态机缺陷。

保留 `chat-diff-evidence/` 的 SQLite 与错误弹层截图；没有放宽差分校验或修改正文。
之后只恢复确切的测试 session `canvas-session-1789591395768147`，核验六条回执均有
正式 Assistant、正文不含提议的 `-OK`，通过真实保存按钮完成云同步，生成
`manual-276c2473`，再进入空白 Canvas，草稿表为 0。恢复驱动明确记录
`recoveryOnly=rejected_sixth_diff`，不计入 50 轮，也不冒充“真实差分应用成功”。
有效差分应用、无效差分拒绝及正文边界保留由受控回归覆盖。

搜索、图谱、日期等是进入同一笔记详情的上游路径，不是独立 Canvas seed 类型。
旧 assistantReply/initialNoteId 仅在兼容路由层覆盖；未发现新的可见入口就不声称
通过真实按钮走过。空历史的“去创作”用受控账号验证，不删除现有账号历史造条件。

## 状态与 Skill 边界

原生受控矩阵覆盖初始化成功/失败/重试、历史冷恢复与真实冲突、AI 运行/取消/失败、
差分逐项保留/删除与应用/拒绝、过期结果、保存/恢复/失败、异步草稿清理、退出确认、
账号切换、Chat 准备/提交/拒绝/重放/结束、后台恢复、横屏键盘和 Reduce Motion。

八类 Skill 的受控组合与前一阶段真实服务验证见第一阶段报告。真实结构化 Skill
仍有服务端返回正文包含字面量 `/n` 的阻塞：六类结构化 Skill 被现有准入规则安全
拒绝；配图说明成功；人设真人设调用受当前账号未配置定位限制。不会为了“全绿”
把 `/n` 无条件替换为换行，也不会修改用户定位或越权修后端。麦克风/ASR 硬件链路
不能由 Simulator 的受控语音状态测试替代。

## 证据与回归记录

本轮独立原始目录：`/tmp/huahuo-canvas-entry-chat-audit.spMwUN`，含容器备份、阶段截图、
真实 API 运行日志。该目录有账号上下文，不整体提交到仓库。

- `live-external-square-owned-restore.log`、`chat-race-evidence/`：第三轮回执串轮证据。
- `live-external-square-final.log`、`live-note-raw-final.log`：真实五轮完整成功。
- `host-chat-baseline.log`：两种竞态原实现失败；另一个旧时钟夹具也在原实现失败。
- `host-chat-cache-before.log`：轮询最终消息未及时写入显示缓存的断言证据。
- `live-note-sprout-final-pass.log`、`host-disposed-detail-before.log`：详情回读
  生命周期异常的原生与确定性负例证据；文件名不代表该中间运行通过。
- `host-chat-all-final.log`：共享 Chat Controller **124 项通过**，1 项原有时钟夹具失败。
- `host-canvas-chat-final.log`：Canvas **212 项通过**；该次命令另列了两个不存在的测试
  路径，加载失败不计产品回归，原生最终结果另行记录。
- `host-core-final.log`：AI/保存/草稿/交互/根 Provider **195 项通过**。
- `host-derived-final.log`：详情/纲要/深度洞察/录音派生交接 **44 项通过**，包含
  生命周期新用例；没有为了修复普通详情回读而破坏已接受任务的后台交接。
- `host-focused-final.log`：可见入口等 **43 项通过**；卡片布局 2 项及冷缓存恢复另测。
- `live-chat-diff-final.log`：额外差分因换行语义不匹配被拒绝，保留失败结果；
  `live-chat-diff-recovery-final.log`：该测试草稿恢复、保存、再次进入通过。
- `final-live-evidence/`：最终真实入口 manifest、截图与完整 recordings 副本；
  只读确认 `creation_canvas_drafts` 0 条、`creation_canvas_history` 18 条。
  18 条含第一阶段和中途重试的测试作品，未擅自删除测试云端笔记。
- `host-chat-diff-boundary.log`：快照 trim 边界与末尾换行标记的 2 项针对性回归通过。
- `final-focused-analyze.log`、`final-last-edits-analyze.log`、
  `final-drivers-analyze.log`：对应本轮改动与原生驱动静态检查无问题；
  `final-derived-analyze.log` 的 9 条构造器初始化风格 info 为已有提示，无 error/warning。
- `baseline-head-regression.log`：原生产代码同样出现 23 项既有 UI/runtime 失败
  （包括既有 golden、旧标签与入场夹具）；未更新无关 golden 或修改无关功能。
- `native-state-final.log`：同一 iPhone 17 Pro 原生最终矩阵 **259 项全部通过**，
  用例执行 15 分 20 秒（不含构建）。构成为 Canvas 212、真实详情按钮入口夹具 41、
  外部卡片布局 2、运行时通知生命周期 1、连续 Chat Run 竞态 2、已销毁详情回读 1。
  原生测试复用 host 的受控用例，不将二者相加为独立测试数。
- 正常应用恢复核验另见末尾记录。

## 复现命令

在 `Flutter/src` 执行；必须保留既有登录数据，并启用工程非正式 target 的显式许可：

```sh
HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET=1 flutter test --no-pub --no-uninstall \
  -d DC53F410-8577-4601-BC10-70A7BB931E04 \
  integration_test/v3_creation_canvas_entry_chat_simulator_test.dart \
  --dart-define=HUAHUO_API_BASE_URL=https://chuda.cc \
  --dart-define=HUAHUO_CANVAS_ENTRY_CHAT_AUDIT=blank \
  --reporter expanded
```

## 正常应用恢复

最终重新构建 `lib/main.dart`，使用 `--no-uninstall-first` 保留账号与笔记；启动后
正常思想图谱/笔记列表可见，执行 `d` 分离 Flutter 调试而非 `q` 终止应用。分离后
再次确认同一 Simulator 的 Runner 进程仍在。截图 `normal-main-final.png`、构建运行
记录 `restore-main-final.log`、进程及完整 recordings 副本在
`normal-restored-evidence/`。最终只读副本确认草稿 0 条、创作历史 18 条；没有遗留
测试入口或未保存测试草稿。测试作品保留在当前账号，未删除原有用户资料。

其他入口选择见对应 integration test 的 SCM。生产请求会创建测试笔记并调用真实
AI，不是默认离线测试。不得拿真实用户未保存草稿做清理夹具。

原生受控矩阵命令（不发送生产 AI 请求，不把导入文件中的无关 golden 作为本轮目标）：

```sh
HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET=1 flutter test --no-pub --no-uninstall \
  -d DC53F410-8577-4601-BC10-70A7BB931E04 \
  integration_test/v3_creation_canvas_state_machine_simulator_test.dart \
  --name '^state |^detail visible Canvas ingress|^world external Canvas ingress|^runtime Knowledge replacement waits|^chat ChatController next turn cannot inherit|^derived disposed detail readback' \
  --reporter expanded
```
