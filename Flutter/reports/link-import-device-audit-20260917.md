# 链接导入失败：真机与服务端只读排查

## 结论与修复边界

两条小红书链接均已被 39 接受，实际失败发生在服务端 URL Reader 的
XHS Python 桥接阶段，不是 Flutter URL 校验、鉴权或网络提交失败。
服务端 `PYTHON_VERSION_UNSUPPORTED` 与运行环境缺失相互印证。

本次仅修改 Flutter。39 严格只读，未部署、安装依赖、重启、修改数据库或
重新投递任务；本地后端源码也未修改。客户端修正不能替代服务端运行环境
修复，因此线上链接解析故障仍待后端授权处理，不能宣称已恢复。

## 证据来源

### 物理 iPhone 持久化 SQLite（非 Simulator）

- 设备：iPhone 11，iOS 26.6；UDID `00008030-00160CC92E7A802E`。
- 已配对、USB 连接、Developer Mode Enabled；应用进程存在且成功读取容器。
  后续锁屏查询为 `unlockedSinceBoot=true`、`passcodeRequired=true`，不宣称
  此时仍处于解锁状态。
- 完整复制 `Documents/recordings` 到独立临时目录
  `/tmp/huahuo-device-log-audit.CoLvaC`，保留 SQLite、WAL 和 SHM。
  此设备工具把目录内容直接放到目标目录，不额外套 `recordings/`。
- 数据库只读查询：`material_ingestion_drafts` 2 条、`diagnostic_logs` 93 条、
  `local_recording_upload_drafts` 1 条、`recording_transcription_receipts` 1 条；
  `chat_run_checkpoints` 无记录。
- 两条链接任务都停留在 `taskSubmitted`，状态 `failed`，错误
  `PYTHON_VERSION_UNSUPPORTED`，未取得 Note ID。
- 两条草稿共用用户范围 `user-31ae9ef93d2f65e32ebb762423c16ae4`。
  录音上传及转写回执属于独立录音任务，没有证据表明与两条 URL 任务相关。

| 本地 draft_id | 远端 ingestion_id | 创建时间 UTC |
| --- | --- | --- |
| `link-1789577655456518` | `ingestion_40f238d028ec7533512fa56c678b283a` | 2026-09-16 16:54:15.456518Z |
| `link-1789577685583516` | `ingestion_62cbeef7e479e31df50a8b883cdda2d1` | 2026-09-16 16:54:45.583516Z |

UTC 加 8 小时即北京时间 2026-09-17 00:54:15 / 00:54:45。
原日志包含 17 条 `ingestion_started` 和 16 条 `ingestion_failed`，后续刷新
仍返回同一错误。旧日志没有 remoteTaskId 和远端阶段；只能结合草稿表关联，
这是可观测性缺口，不能把缺日志解释为未执行。

### 真机实时控制台

执行了 `flutter attach -d <上述真机UDID>`，曾连接到 Dart VM Service，随后
工具报告 `Lost connection to device` 并退出；没有获得新的链接复现日志。
没有输入 `q`、没有主动终止或重装 App，也没有以 Simulator 日志代替。
本报告的失败结论来自真机持久化记录和服务端证据，不来自实时控制台。

### 39 Nginx 访问日志

两次 `POST /api/v1/workspaces/.../note-ingestions` 分别在北京时间
2026-09-17 00:54:15、00:54:45 返回 **202**。针对上述 ingestion ID 的 GET
返回 **200**，直到 01:03:52 的后续操作仍只是查询旧任务。
HTTP 200 只表示成功读到任务，不表示链接分析成功。

### 39 任务数据库与运行环境

PostgreSQL 连接强制 `default_transaction_read_only=on`，设置 5 秒查询超时；
仅查询两条指定 ingestion ID，不输出数据库密码或访问凭证。

| 任务 | note_ingestions | note_jobs | 首次失败时间（北京时间） |
| --- | --- | --- | --- |
| `ingestion_40f238d028ec7533512fa56c678b283a` | failed / PYTHON_VERSION_UNSUPPORTED | note_url_import / failed / attempt=1 / max_attempts=5 | 2026-09-17 00:54:16.857750 |
| `ingestion_62cbeef7e479e31df50a8b883cdda2d1` | failed / PYTHON_VERSION_UNSUPPORTED | note_url_import / failed / attempt=1 / max_attempts=5 | 2026-09-17 00:54:46.898628 |

两者 `promoted_hnote_id` 为空。查询时任务仍停在首次失败，并没有因为 App
显示“重试”而再次运行。指定时间范围的 Worker journal 未命中任务 ID 或
错误码，不以此否认数据库已经记录的执行。

- 当前发布目录：`/opt/huahuoai-backend/releases/huahuo-ai-0.1.0-20260912T135057Z-df17437331b4`。
- 当前 Worker 的 URL Reader 专用环境变量未设置。
- 系统 `/usr/bin/python3 --version` 为 **3.10.12**。
- 当前发布的 `tools/local-url-reader/.runtime/xhs-venv/bin/python` 不存在。
- 当前发布的 Reader `third_party/` 仅见 `UPSTREAMS.md`，没有 XHS-Downloader。
- 已部署 `bridge.mjs` 在专用 Python 不可执行时回退到普通 Python；
  `xhs_bridge.py` 的下载器分支要求 Python >= 3.12，直接报上述错误。

没有调用 101：本次实际入口为 39 Worker 内嵌的 URL Reader；修改旧 101
独立服务不会修复已确认的执行链路。

## 前后端协议核对

本地后端根目录：`/Users/run/huahuo-ai-backend/huahuoai-all`。
已阅读 `CHANGE-RELEASE-PLAN-url-note-import-20260815.md` 和对应实现：

- `source/internal/services/note_ingestion_service.go:68`：同租户/用户/工作空间/URL
  得到稳定 ingestion ID。
- `source/internal/persistence/note_repository.go:856`：CreateIngestion 按来源
  去重，已有失败任务直接返回，不重新入队；更换幂等键也不能恢复它。
- `source/internal/api/routes/note_routes.go:88`：公开协议有 create/get/cancel/
  promote，没有失败 URL 任务重试端点。
- `source/internal/urlreader/command_client.go:475`：子进程环境采用白名单，
  没有透传 `URL_READER_XHS_PYTHON`。只在 Worker systemd 中添加该变量不足以
  解决本地实现所示问题；需使用发布内的正确默认路径或明确配置/传递专用解释器。
- `source/tools/local-url-reader/src/lib/config.mjs:131` 与
  `scripts/bridges/xhs_bridge.py:389` 定义专用 Python 路径及版本约束。

本地 Go 源码用于解释协议和提出修复方案，不冒充部署二进制逐字相同的证据。
运行环境缺失及 Python 分支错误另有已部署文件和真实任务数据支持。

## 本次 Flutter 改动

1. 将已受理任务的操作显示为“刷新状态”，明确仅查询，不重新分析。
2. 刷新期间保持原持久化失败状态，使用独立内存标记显示查询进度，避免伪造
   queued 状态；重复操作互斥，远端后来恢复时仍可完成同一个草稿。
3. Python/依赖/配置错误显示服务端配置异常，不再要求用户检查链接公开权限。
4. 增加任务受理和远端阶段变化诊断，记录 draftId、remoteTaskId、checkpoint、
   status、remoteStatus 和 failureOrigin；不记录源 URL、正文或凭证。
5. 先更新 `Flutter/scm`，使用现有两个测试文件补充回归，不新增源码/测试文件。

## 服务端根因修复（待授权，本次未执行）

1. 在正式发布流程中包含固定版本 XHS-Downloader 及依赖，配置 Python 3.12+
   专用环境，并在以 Worker 身份启动的受限子进程中检查解释器及上游导入。
   不能仅升级系统 Python，也不能仅修改未被子进程白名单透传的变量。
2. 增加发布前 XHS 运行环境校验，防止 `.runtime` 和 `third_party` 未随发布
   交付而静默退回 Python 3.10。保留网络出口和 URL 安全边界。
3. 环境修复后，旧任务仍是终态且按 URL 去重。需要正式、鉴权、幂等、受限的
   后端重试/恢复机制，或者经授权的运维恢复流程；不得通过修改 URL 查询参数、
   随机幂等键、前端直连 101 或擅自改表来绕过。
4. 上述服务端操作及一次真实链接端到端验收需要单独授权，不在只读排查范围。

## 验证结果

- 对两个修改后的源码和两个测试文件定向运行 `flutter analyze --no-pub`：
  **No issues found**；Dart 格式检查通过。
- 运行 `material_ingestion_coordinator_test.dart` 与
  `v3_link_import_page_test.dart`：**25 项通过，2 项失败**。本次新增的远端失败
  刷新/诊断回归和页面配置错误/查询进度回归均通过。
- 两项失败是既有“无 Checkbox”“无 link-import-distillation-option”断言与
  当前蒸馏选项不一致。`git show HEAD` 确认旧断言和控件在改动前均存在；
  本次未修改该控件或两项断言，未扩展范围修复蒸馏功能。
- 未重新安装真机 App，未提交新的线上解析任务，未声称完成生产端到端恢复。
