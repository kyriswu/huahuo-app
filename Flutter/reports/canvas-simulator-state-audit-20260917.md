# 自由创作状态机仿真验收

测试日期：北京时间 2026-09-17；对应服务端日志 UTC 2026-09-16。

## 环境与边界

- 使用既有 iPhone 17 Pro Simulator，iOS 26.5，UDID `DC53F410-8577-4601-BC10-70A7BB931E04`。没有创建新模拟器，也没有使用物理 iPhone 的日志冒充本次证据。
- Device Hub 对应的既有设备可运行；Xcode DeviceInteraction 接口要求 iOS 27，不能操作此 26.5 runtime。因此使用 Flutter 原生 integration_test 驱动同一台模拟器，不将 host widget tests 等同于设备测试。
- 开始前备份 Simulator Documents；安装均使用 `--no-uninstall`。没有清空账号、注入 token、绕过 TLS、修改原有笔记或定位资料。
- 真实联调用现有登录态和 `https://chuda.cc`。测试创建有明确标记的笔记：`自由创作仿真验证-1789580935799` 及其自由创作副本/今日推荐副本。
- 所有代码变更限于 Flutter 测试入口、测试夹具和相应 SCM；没有为测试成功放松正文准入、保存确认、离开保护或状态锁。此前已有的自由创作状态机修复保留不变。
- 服务端只读取相关日志、Run/数据库记录和部署信息；没有改文件、重启、部署、迁移或重新投递任务。
- 测试结束已重新构建并运行正常 `lib/main.dart`，使用 `--no-uninstall-first` 保留数据；输入 `d` 分离后确认 Simulator App 进程仍运行、正常笔记界面可见，草稿表仍为 0。没有把测试入口留作日常应用。

## 验证分层

### 1. 确定性状态机回归

Host 回归最终 **340 项通过**。范围为 AI Controller/Transform Port、Interaction Policy、Autosave Coordinator、Script Draft Controller、Draft Repository、Workbench、Note Detail 和 Canvas。

原生 iPhone 17 Pro Simulator 全矩阵最终 **169 项通过**，执行 5 分 56 秒（不含构建）。最后的横屏 Chat 键盘、宽屏与 Reduce Motion 用例也通过，未保留中间夹具误报。

全矩阵并非只打开页面检查外观，包含以下可执行断言：

| 范围 | 状态与不变量 |
| --- | --- |
| 入口 | 空白、新笔记副本、今日推荐、资料、历史；冷缓存、旧草稿冲突、同来源重复创作、同路径参数变化、已删除来源 |
| 八类 Skill | 五种关系视角、两种开头、两种配图，以及需求/差异化/扩写/人设/原子化，共 14 个选项 × 全文/局部 × 接受/拒绝 = 56 次转换 |
| 差分 | 原文冻结、预览不可编辑、选区上下文保留、接受单步撤销、拒绝正文不变、旧基线/晚到结果失效 |
| AI 异常 | 运行中取消、等待结果恢复且不另发请求、临时失败重试原操作、终态失败重新生成、不合法返回拒绝 |
| Chat | 三轮关闭/重开；规范消息 ID 替换；同一 accepted Run 收口；先持久化幂等键再 POST；pending 不禁止编辑/保存；旧改写提案不能覆盖新正文 |
| 保存 | 非 debounce 写入屏障、冻结快照、云确认后导航、重试不复制笔记、本地失败文案、prepared/noteCommitted/historyCommitted 恢复、清理重试 |
| 生命周期 | 后台 flush、放弃后旧写入不能复活、离开/内部导航期间新编辑冲突、前台新入口排队、语音归属释放 |
| 编辑与布局 | 标题/正文焦点、富文本/链接/图片、撤销、长文光标、320px、小横屏键盘、字体放大、深色与减少动态效果 |

原生用例使用受控服务和 test text-input channel，以重复验证异步状态；不宣称真实键盘、麦克风、相机、系统杀进程和所有网络组合均已实测。340 项 host 与原生用例有复用，不应相加为独立用例数。

### 2. 真实服务联调

| 路径 | 本轮证据/结果 |
| --- | --- |
| 社会关系转变、需求深化、差异化增强、开头优化、扩写、原子化 | 首次及可见“重新生成”均返回异常换行；前端以 `CANVAS_AI_INVALID_LINE_BREAKS` 拒绝，原文保持不变，关闭后可恢复编辑。真实 Skill 链路不通过。 |
| 配图 | 真实生成进入差分预览，拒绝后原文保留；该路径使用普通 Markdown 返回，不是同样的结构化正文 JSON。 |
| 人设植入 | 当前账号没有可用定位内容，正确显示“需要先完成定位对话”；没有为测试修改用户定位。真实生成未覆盖，受控矩阵已覆盖功能和两个范围。 |
| 聊一聊 | 两轮真实请求成功，期间关闭/重开并跨 App 再次启动；服务端正式消息和 Canvas assistant 回执均完成。第二轮 Run 尾缀 `4940328f86fa551d`，正常进入 settled。 |
| 显式保存 | 真实同步返回 success，接受精确远端绑定；本地历史 `manual-335a5b8c`；只读 SQLite 确认 `creation_canvas_drafts` 为 0。Note 正文与 Canvas Markdown 按既有 trim 边界一致。 |
| 保存后再次进入 | 真实 App 再次启动后进入空白自由创作，正文为空，无旧草稿冲突提示。 |
| 笔记 → 自由创作 | 标记笔记可生成独立副本、自动保存并显示“已保存”；校验新 Note ID、同步完成、草稿清除，原始 Note 正文不变。复测创建的每个副本拥有独立 ID。 |
| 今日推荐 → 自由创作 | 从当前首页实际推荐卡片进入详情，再点自由创作；真实生成、改为标记测试标题、确认保存、同步成功和草稿清除均通过。 |

真实 Skill 的所有付费选项没有机械重复 56 次：完整组合用受控原生矩阵验证，真实服务每类取一个选项及失败后的重试。后端返回已确定异常时不继续制造重复请求。

来源入口最终用例 `live Canvas Note and daily source entries` **1 项通过**，包含 fresh_entry → note_copy → daily_copy → complete，执行 32 秒（不含构建）。前面因驱动假设失败的记录保留，未算作通过。

## 确认的阻塞问题：后端脱敏改变正文 JSON

### 代码证据

只读检查 `/Users/run/huahuo-ai-backend/huahuoai-all/source/internal/runtime/openclaw_client.go`：

- `RuntimeRunResult.FinalAnswer` 构建处（约 814 行）调用 `redactRuntimeText(openclawFinalAnswer(...))`。
- `redactRuntimeText`（约 1300 行）对整个文本执行 `strings.ReplaceAll(value, "\\", "/")`，再执行敏感信息检测/脱敏。
- 合法 JSON 的 `"replacementMarkdown":"甲\n\n乙"` 因此变成 `"replacementMarkdown":"甲/n/n乙"`；JSON 仍能解析，但正文内容已经改变。引号和其他转义也有被破坏的风险。
- 前端提交指令已禁止 `/n/n`。仅增加提示词、重发同一请求或把 `/n` 全局替回换行，都不是根治；反向替换还会破坏合法路径、示例和代码。

### 线上证据与证据限制

- 示例 Run `agent_run_d03f99621113e1e012e50149a4cd4009` 的服务端状态为 `succeeded`；UTC 17:49:26 已有最终结果，客户端同时间拒绝非法换行。并非 Run 一直未完成。
- 只读数据库核对的前 11 个相关 Run 均成功；`public_result.finalAnswer` 解码后的 replacementMarkdown 含 8–9 处字面 `/n`，而实际换行数为 0。请求基线包含正常换行。原子化后续的两次失败另有 Simulator 日志佐证。
- 相关 Run 查询在服务端访问日志中返回 200。不能据此把“服务接口有响应”说成“Skill 内容可用”。
- 部署回执记录 source commit `45b7de8541292656558513efa6ee1e41731bddb8`；本地 backend HEAD 不同，部署包没有保留对应 Go 源文件，本地亦无该 commit 对象。**没有采集到脱敏前的供应商原始响应，也未逐字校验部署版本函数**。已确认本地后端实现存在确定性破坏，线上落库结果与其高度一致；上线根治仍必须核对部署版本并回归。

### 处理结论

当前授权只允许修改 Flutter，且服务器严格只读，因此**没有修改或部署后端**。Flutter 保持拒绝损坏内容，不以字符串替换掩盖来源问题。根治需要后端单独授权：保留安全正文原始字节，仅在敏感信息识别副本/明确敏感 token 上做路径归一化；继续保留凭证、私有路径等脱敏，并补 JSON 换行/引号/反斜杠、普通 Markdown 和敏感信息回归。

## 本轮测试实现与误报排除

- 新增受控原生矩阵入口和真实服务 opt-in 入口；真实服务入口拒绝覆盖已有用户草稿，只允许显式指定本次标记草稿继续，不恢复未完成提交。
- 原生异步服务回调改用 `expectSync`，避免 Flutter test guarded zone 的夹具错误；pending fixture 保持 SSE 开启，不把立即断流假装成持续运行。
- Chat fixture 为不同幂等键产生不同正式消息 ID，同一次重试仍使用同一 ID；原夹具复用一组 ID，不能验证重复聊天。
- 合成键盘指标按 `max(viewPadding - viewInsets, 0)` 计算 padding；保留真实未遮挡 home-indicator padding 的旧夹具会产生不可能的横屏溢出。
- 更新过时的保存状态断言；链接表单先滚动到现有按钮再点击并校验；只读来源提供“创建副本”能力时保持可点击，无能力时隐藏。
- 实测驱动等待 workspace 就绪、composer 出现、发送按钮启用以及云保存完成；不把规范消息回读期的临时锁当作 Chat 卡死。
- Note 保存既有边界会 trim Quill 终止换行；曾有严格末尾换行断言失败，但请求同步和草稿清理已成功。不能把该测试断言误判为应用保存失败。
- iOS 离开使用实际顶部返回按钮，而非在根路由模拟 Android platform pop；跨路由断言读取当前 workspace library，而不保留启动期会被替换的实例。

以上改动均先更新对应 SCM；新增测试已登记 SOURCE_TREE。没有因测试夹具误报改动业务锁、路由保护或正文逻辑。

四个本轮新增/修改 Dart 测试文件最终 `dart analyze` 无问题，`dart format --output=none --set-exit-if-changed` 与 `git diff --check` 通过。工作区中同时存在的链接导入/素材摄入变更属于其他工作，未修改或回退。

## 测试数据保留

测试产生的 5 条标记笔记保留供核对，没有自动删除云端数据：基础笔记 `manual-335a5b8c`，同源独立副本 `manual-1d65675d`、`manual-33890fc`、`manual-2fc2ddf3`，今日推荐副本 `manual-3a968a7e`。后者来源是首页当时展示的 `topic_01`；验证的是该卡片的真实生成/保存链路，不把卡片本身的推荐来源当作已验收的另一个后端服务。

真实入口完成并启动受控矩阵后，再读 Simulator SQLite，`creation_canvas_drafts` 仍为 0，各副本分别落入历史，没有复活未保存草稿。中途驱动复测增加了独立副本，不是一次保存重复创建多条 Note。

## 复现方式

在 `/Users/run/huahuoai-app/Flutter/src` 执行：

```sh
HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET=1 flutter test --no-pub --no-uninstall \
  -d DC53F410-8577-4601-BC10-70A7BB931E04 \
  integration_test/v3_creation_canvas_state_machine_simulator_test.dart \
  --reporter expanded
```

真实服务入口为 `integration_test/v3_creation_canvas_live_simulator_test.dart`，必须显式提供 `--dart-define=HUAHUO_CANVAS_LIVE_AUDIT=true` 和实际 API base。默认只运行 Skill/Chat/save；提供 `HUAHUO_CANVAS_LIVE_AUDIT_NOTE_ID` 时只运行来源入口，ID 必须指向标记测试笔记。真实执行会创建测试笔记并消耗实际 AI 请求，不属于默认离线测试。

## 原始记录

本机独立目录 `/tmp/huahuo-canvas-simulator-audit.R1zFVl` 保存执行日志、有限截图和开始前的 Simulator Documents 备份。该目录含账号测试上下文，未整体复制入仓库。

- `host-core-final.log`：340 项 host 回归。
- `device-state-matrix-final.log`：169 项原生 Simulator 最终全绿结果。
- `device-matrix-3.log`：八类 Skill 全选项矩阵及重复 Chat 的原生结果。
- `device-full-state-matrix.log`、`device-viewport-recheck.log`：中间原生结果，包含后来排除的夹具误报，不作为最终全绿证据。
- `device-live-complete.log`、`device-live-continuation.log`、`device-live-chat-sources.log`：真实 Skill 首次/重试、缺少定位、配图和首轮 Chat。
- `device-live-chat-save-composer.log`：第二轮 Chat、真实云保存及末尾换行断言差异；SQLite 另行只读确认清理成功。
- `live-chat-save-completed/`、`live-note-copy-completed/`：对应阶段截图。
- `device-live-source-navigation.log`、`live-source-completed/`：最终真实笔记/今日推荐完整链路通过的日志与截图。
- `final-dart-analyze.log`：本轮四个 Dart 测试文件静态检查通过。
- `normal-app-restored.png`：最终恢复正常应用的原生截图。

本报告不能作出“所有情况均无问题”的保证。确认覆盖的状态、服务阻塞、账号前置条件和未实测硬件路径需分别处理。
