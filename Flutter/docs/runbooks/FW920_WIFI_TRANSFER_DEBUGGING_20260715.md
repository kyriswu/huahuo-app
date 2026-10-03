# FW920 Wi-Fi 文件传输调试总结

状态：iOS 三文件同 TCP 批量、受限尾部续取已验证；Android 与批量压力验收仍待完成
日期：2026-07-15  
适用工程：`Flutter/` 正式 App  
已验证硬件：FW920 主固件 `1.0.6`，Wi-Fi 固件 `1.0.2`，iPhone 真机

## 1. 当前结论

本轮已在 Flutter 正式 App 中完成四条真实 Wi-Fi 文件下载：

| 文件大小 | TCP 文件帧 | 原生耗时 | 结果 |
| ---: | ---: | ---: | --- |
| 71,172 bytes | `0x0B` seq `0...17` | 567 ms | SHA-256、原子落盘、本地录音库登记、播放通过 |
| 4,586,572 bytes | `0x0B` seq `0...1142` | 10,094 ms | SHA-256、原子落盘、本地录音库登记、播放通过 |
| 33,298 bytes | `0x0B` seq `0...8` | 5,778 ms | quiet boundary、SHA-256、原子落盘、登记、播放通过 |
| 28,268 bytes | `0x0B` seq `0...7` | 5,864 ms | 同批次热点重开、quiet boundary、登记、播放通过 |

另于 2026-07-16 完成一组同一 TCP 的三文件批量传输：

| 顺序 | 文件大小 | TCP 文件帧 | 结果 |
| ---: | ---: | ---: | --- |
| 1 | 294,662 bytes | `0x0B` seq `0...73` | 长度、SHA-256、原子落盘及登记通过 |
| 2 | 33,298 bytes | `0x0B` seq `74...82` | 长度、SHA-256、原子落盘及登记通过 |
| 3 | 71,172 bytes | `0x0B` seq `83...100` | 最终 quiet boundary、原子落盘及登记通过 |

该批次只建立一条 TCP、只读取一次 67 条目录，三项数据库状态均为
`completed`、尝试次数均为 1，且私有录音目录无 `.part` 残留。

已确认的正式时序：

```text
BLE ready
-> 0x1B 开启 Wi-Fi
-> 0x1F 获取一次性 SSID / 密码
-> 用户在系统设置中手动连接录音卡热点
-> TCP 192.168.200.1:8475
-> 收到 0x20 status=0x00
-> 发送一次 0x0A，读取完整目录直至 status=0x02
-> 对选定文件发送 0x0B（14-byte 文件名 + 4-byte seek）
-> 顺序接收 0x0B 文件数据帧
-> 校验序号、声明长度和最终文件长度
-> SHA-256
-> .part 原子移动为正式私有录音
-> 继续请求批次中的下一文件
-> 所有可传文件完成后关闭 TCP
-> 统一登记本地录音库
-> 播放验证
```

批量传输期间禁止在两个 `0x0B` 请求之间执行本地录音库 stat、哈希去重、
录音库登记或整库快照重写。原生返回只代表“已校验并原子落盘”，客户端仅用
SQLite 单行 UPSERT 保存不含 URI/路径的 staged 恢复检查点（原生文件 ID、
格式、大小、SHA-256），随后立即请求下一项；TCP 关闭后先原子保存一次整批，
再统一执行 stat、去重和入库。这样既保留异常退出恢复能力，也可避免数据库
I/O 占用热点有效期或让 FW920 会话在文件间空闲。

此前 RN 测试工程中“Wi-Fi 应用层尚未通过”的结论已经失效。本文件记录
Flutter 正式 App 的最新真机结论，并作为当前工程唯一维护的 FW920 Wi-Fi
接入说明。

## 2. Xnote Wi-Fi 帧

Wi-Fi TCP 不能发送 BLE 的 `D2 2D` 帧。FW920 使用独立 Xnote envelope：

| Offset | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 15 | ASCII `XnoteWifiHead` + 2 个空格 |
| 15 | 1 | command |
| 16 | 2 | sequence，大端 |
| 18 | 2 | data CRC，大端字段 |
| 20 | 4 | payload length，大端 |
| 24 | N | payload |
| 24 + N | 16 | ASCII `XnoteWifiTail` + 3 个空格 |

固定开销为 40 bytes。TCP 会拆包或合包，因此解析器必须累积 buffer，按
payload length 消费完整帧，并保留同一 read 中的剩余数据。

### CRC 兼容规则

FW920 `1.0.6` / Wi-Fi `1.0.2` 的非空设备响应会把 CRC 字段写成
`0x0000`，即使 payload 的 CRC16/IBM 非零。仅对这个精确固件组合，
`0x0000` 表示“设备未提供 CRC”。

- 非零 CRC 必须匹配 CRC16/IBM。
- 其他固件不能自动套用零 CRC 兼容。
- CRC 缺失时仍必须严格校验 header、length、tail、command、sequence、
  最终长度和本地 SHA-256。

### 文件数据规则

- `0x0B` 可能没有独立的 5-byte size ACK，首帧可直接是文件数据。
- 没有 ACK 时以本次 TCP `0x0A` 目录中刷新后的大小为目标。
- TCP 会话的第一条文件数据帧建立 sequence 基线；同一会话后续文件继续
  使用该 sequence，必须逐一递增并允许 UInt16 回绕，不能按文件重置为零。
- 重复、倒序、缺帧和超过目标大小的数据必须失败，不能截断后假装成功。
- 达到目标大小后先等待自然 `0x02`，否则发送 `0x0C` 建立明确边界。
- FW `1.0.6` / Wi-Fi `1.0.2` 实测会在接受 `0x0C` 后保持静默；仅对该
  精确版本组合，停止帧写入成功后连续 2 秒无完整帧、半帧、Socket 错误或
  排队数据，且连接始终保持 ready，才可作为 quiet boundary。其他固件仍
  必须返回明确 ACK。

## 3. 成功日志基线

日志必须保持脱敏。下面只保留阶段、命令、数量和耗时：

```text
[FW920] device info firmware=1.0.6 wifiSupported=true wifiVersion=1.0.2
[FW920] wifi connection ready ... awaiting=0x20
[FW920] wifi frame accepted ... cmd=0x20 seq=0 payloadBytes=1 status=00
[FW920] wifi directory completed ... rows=71
[FW920] wifi request sent ...
[FW920] wifi data started without size ack ... targetBytes=71172
[FW920] wifi frame accepted ... cmd=0x0b seq=0 ...
...
[FW920] wifi frame accepted ... cmd=0x0b seq=17 ...
[FW920] wifi download committed ... bytes=71172 elapsedMs=567
```

较大文件成功基线：

```text
[FW920] wifi directory completed ... rows=67
[FW920] wifi data started without size ack ... targetBytes=4586572
[FW920] wifi frame accepted ... cmd=0x0b seq=0 ...
...
[FW920] wifi frame accepted ... cmd=0x0b seq=1142 ...
[FW920] wifi download committed ... bytes=4586572 elapsedMs=10094
```

批量链路开发时新增并于 2026-07-16 复验成功的边界样本：

```text
[FW920] wifi directory completed ... rows=67
[FW920] wifi data started without size ack ... targetBytes=33298
[FW920] wifi frame accepted ... cmd=0x0b seq=0 ...
...
[FW920] wifi frame accepted ... cmd=0x0b seq=8 ...
[FW920] wifi file boundary requesting ...
[FW920] wifi quiet boundary accepted ... profile=fw-1.0.6-wifi-1.0.2
[FW920] wifi download committed ... bytes=33298 elapsedMs=5778
```

该样本完整收到 `33,298` bytes，序号 `0...8` 连续，设备在 `0x0C` 后无
ACK。旧实现误报 `RECORDING_CARD_WIFI_BOUNDARY_TIMEOUT`；修复后仅在精确
固件 profile、Socket 健康且无残留帧时接受 quiet boundary，并完成本地登记
与真机播放。不能把一般网络超时当作成功。

热点重开链路于 2026-07-16 使用另一条小文件完成真机验证：

```text
[FW920] wifi enable acknowledged
[FW920] wifi preparation completed
# 热点等待期间重新发送 0x1B；此时没有创建 TCP 或新批次
[FW920] wifi enable acknowledged
[FW920] wifi preparation completed
[FW920] wifi connection ready ... awaiting=0x20
[FW920] wifi directory completed ... rows=67
[FW920] wifi data started without size ack ... targetBytes=28268
[FW920] wifi frame accepted ... cmd=0x0b seq=0 ...
...
[FW920] wifi frame accepted ... cmd=0x0b seq=7 ...
[FW920] wifi quiet boundary accepted ... profile=fw-1.0.6-wifi-1.0.2
[FW920] wifi download committed ... bytes=28268 elapsedMs=5864
```

该次重开保留原批次，随后只建立一条 TCP、只读取一组 67 条目录；落盘后 BLE
自动重连，文件在本地录音库可见且真机播放通过。

同一 TCP 三文件成功基线：

```text
[FW920] wifi session opening ... requestedFiles=3
[FW920] wifi directory completed ... rows=67
[FW920] wifi data started ... targetBytes=294662
[FW920] wifi download committed ... bytes=294662
[FW920] wifi data started ... targetBytes=33298
[FW920] wifi download committed ... bytes=33298
[FW920] wifi data started ... targetBytes=71172
[FW920] wifi quiet boundary accepted ... profile=fw-1.0.6-wifi-1.0.2
[FW920] wifi download committed ... bytes=71172
[FW920] wifi session closed ...
```

文件数据 sequence 在三项之间连续为 `0...73`、`74...82`、`83...100`。
这证明同一 Socket 串行、逐项校验和逐项登记已通过三文件真机验收，但不替代
清单中 10 条以上混合大小文件、断网恢复和重启恢复的最终压力验收。

只有出现 `wifi download committed`、本地库记录、实际私有文件和播放成功，
才能判定下载通过。TCP 可连接或 UI 显示完成都不是充分条件。

## 4. 本轮踩过的坑

### 4.1 调试日志写入导致 App 崩溃

直接调用 `FileHandle.standardError.write` 时，Xcode 会话切换可能使底层
descriptor 失效，Objective-C 抛出无法被 Swift `do/catch` 捕获的
`Input/output error`，进而终止 App。

处理方式：

- 控制台继续使用 `NSLog`。
- 持久调试日志使用可失败的 POSIX `open(O_APPEND)` / `write`。
- 日志失败必须被丢弃，不能改变 BLE/Wi-Fi 业务行为。

### 4.2 同时存在两个 Runner 进程

Xcode 多次安装/启动时，设备上曾同时存在不同容器路径的 Runner。旧二进制
继续写旧格式日志，导致代码和日志不对应。

每次真机回归前检查：

```zsh
xcrun devicectl device info processes --device <DEVICE_UDID> \
  | rg 'Runner.app/Runner'
```

只应保留一个进程。确认旧 PID 后终止：

```zsh
xcrun devicectl device process terminate \
  --device <DEVICE_UDID> --pid <OLD_PID>
```

不要使用 `devicectl install app` 绕过 Xcode 签名部署；本轮稳定方式是由 Xcode
对已打开的 workspace 执行 Run。

### 4.3 一次性 TCP 探测破坏正式连接

旧流程先打开 TCP 做 `verifyWifiHandoff`，立即关闭，再打开第二条 TCP 下载。
FW920 `1.0.6` 可能保留第一个 client，第二条连接长期停留在 `preparing`。

正式流程不能创建 disposable preflight socket。正式 TCP 自身到达 ready、收到
`0x20`，就是连接验证。批量文件必须复用同一 TCP session。

### 4.4 把 BLE 帧发到 TCP

最初把 `D2 2D ... CRC` 的 BLE `0x0B` 帧写入 TCP。设备返回 Xnote 帧，App
按 BLE ACK 解析后报协议错误。Wi-Fi 必须使用第 2 节的 Xnote envelope。

### 4.5 CRC 校验过严

真实目录帧曾记录：

```text
cmd=0x0a length=20 declaredCRC=0000 computedCRC=0e1a tail=valid
```

Header、length 和 tail 都正确，失败原因只是固件没有填 CRC。修复必须限制在
精确固件 profile，不能全局关闭 CRC。

### 4.6 把目录帧当作文件数据

TCP 建立后设备会返回 `0x0A` 目录行。若直接发送 `0x0B`，未完成的目录流会
与文件流交错。必须先请求并消费完整目录，晚到的合法 `0x0A` 只能作为目录
处理，绝不能写入音频文件。

### 4.7 文件大小端误判

目录和 `0x0B` ACK 的 4-byte size 使用协议大端。曾经的“双候选取较小值”会
把约 1.2MB 解释成约 460MB，也会把 6,291,968 bytes 解释成 155,648 bytes。
不能再按数值大小或 1 GiB 产品上限切换端序；无效的大端值应保持不可用并在
传输前失败。可信目录与带长度 ACK 不一致时必须返回长度冲突，不能任选一个
作为截断边界。

### 4.8 Wi-Fi 模式下 BLE 断开被误报

录音卡开启热点后 BLE 断开是预期切换。准备已经成功、TCP 会话仍有效时，
不能把它投影为“连接异常”，也不能再次结算一个已经返回的准备回调。

### 4.9 把固件静默结束误判为失败

FW `1.0.6` / Wi-Fi `1.0.2` 在完整文件后不一定发送自然 `0x02`，收到
`0x0C` 后也可能不返回 ACK。若一律要求 ACK，完整文件会在校验前被误报为
`BOUNDARY_TIMEOUT`。兼容处理必须同时满足：精确固件 profile、文件长度已
严格命中、停止帧写入成功、2 秒内无完整帧/半帧/网络错误。缺少任一条件都
继续失败关闭，不能用“静默”放宽一般协议校验。

### 4.10 把方法通道整数 0/1 误判为 Bool

单文件批次会携带 `fileIndex=0`、`fileCount=1` 和聚合起点 `0`。Flutter 标准
方法通道在 iOS 将这些整数解码为 `NSNumber`，而 Swift 的 `value is Bool`
会把数值 `0` 和 `1` 也判断为真，曾导致合法批次上下文在发送 `0x0B` 前被
拒绝为 `RECORDING_CARD_INVALID_FILE`。

数值解析必须先转换为 `NSNumber`，再使用 `CFGetTypeID(number) !=
CFBooleanGetTypeID()` 排除真正的布尔值。回归测试必须同时覆盖数值 `0/1`
可用以及真实 `true/false` 被拒绝；不能通过省略首项索引绕过问题，因为多文件
批次的第一项仍然是索引 `0`。

### 4.11 页面恢复扫描污染 Wi-Fi 目录

页面进入、连接成功、从系统设置恢复和手动刷新曾连续触发多次 BLE `0x0A`。
热点切换期间若 BLE 扫描与 TCP `0x0A` 重叠，新 Socket 可能先收到旧目录的
尾段。实测异常会话先出现 `35 rows + 0x02`，随后才出现完整
`67 rows + 0x02`；代码在首个结束帧冻结了陈旧目录，最终把 `84,710` 字节
目标用于仅返回 `84,360` 字节的流并正确报不完整。

正式处理是：仅保留一个 Runner；并发页面刷新合并为一次；Wi-Fi 批次从
`awaitingHotspot` 到落库期间禁止 BLE 状态/目录刷新；开始热点准备前等待
已有扫描结束。干净复验必须只看到单组 `67 rows + 0x02`，不能放宽长度校验
来掩盖目录代次污染。

### 4.12 热点等待超时后新建重复批次

FW920 热点开启后若用户长时间未连接会自动关闭。用户需要再次发送 `0x1B`
重新开启热点，但不得先取消任务再创建另一个批次。热点弹窗中的
`重新开启热点` 只对当前 `awaitingHotspot` 批次重新执行原生准备，保留批次
ID、文件顺序和持久记录，并刷新仅存在于弹窗内的凭据。只有点击
`我已连接` 才打开 TCP 会话。

2026-07-16 真机复验中，首次准备和弹窗内重开均收到 `0x1B status=0x00`；
重开期间没有 `0x20`、`0x0A` 或新 Socket，连接热点后才建立正式 TCP，并
完成 28,268-byte 文件下载、登记和播放。

### 4.13 连续请求后小文件只返回一帧

2026-07-16 的六选批次中，一条已同步文件在入队前跳过，原生会话实际请求
5 条。前三条分别完整提交 `294,662`、`33,298`、`71,172` bytes；第 4 条
TCP 目录声明 `4,924` bytes，但固件只发送 seq `101` 的一个 `4,040`-byte
数据帧，随后主动发送 `0x0B status=0x02`，1 秒尾帧宽限期内没有补发剩余
`884` bytes。该会话此前只有 `preparing -> ready`，没有 `waiting`、
`failed` 或 `cancelled`；BLE 断开也发生在目录开始前且明确为
`expectedWifi=true`。因此根因不是第 4 条传输时 BLE/Wi-Fi 断网，而是设备
文件流提前结束或目录与实际流不一致。

随后使用同一条失败文件做 fresh Socket 单项 A/B：新建热点、新建 TCP、重新
读取 67 行目录后，设备仍只返回 seq `0` 的 `4,040` bytes，随即主动返回
`0x0B status=0x02`。因此可排除批量会话复用、文件间隔和入库阶段；旧提交
`215f0d8` 的 Xnote 编解码和 `0x0B` payload 与当前相同，面对该线上数据也会
按短文件拒绝。正式规避保持以下边界：

- 绝不接受 `4,040`、补零或修改目录目标；残缺 `.part` 必须删除。
- 500 ms 文件间空闲可以减少会话竞争，但不能修复该 fresh 单文件短发，不能
  再把它描述为根因修复。
- 若仍短发，关闭当前 TCP，先统一登记此前完整文件，将本批次结算为失败并
  取消未开始项；不把 BLE 恢复状态显示成原始失败原因。
- 下一次用户重新选择时创建新批次、重新开启热点并读取 fresh `0x0A` 目录，
  不要求恢复上一次残缺任务。

### 4.14 `4,040` 边界后的尾部是有效音频

同一设备文件随后通过 BLE 完整传输并原子入库，目录、BLE ACK、实际文件和
数据库 manifest 均为 `4,924` bytes。Apple 音频检查将完整副本识别为 MPEG-2
Layer III、32 kbps、16 kHz、单声道，约 1.23 秒；截取前 `4,040` bytes 只剩
约 1.01 秒。MP3 帧头每 144 bytes 出现一次，`4,040` 位于从 offset `4,032`
开始的帧内部第 8 byte。缺失的 `884` bytes 包含该帧剩余 136 bytes、后续
5 个完整帧和文件末尾 28 bytes，不能视为 padding，也不能降低目标长度后
登记。

请求 payload 的最后 4 bytes 是大端 seek，`4,040` 编码为
`00 00 0F C8`。2026-07-17 真机探针在首段 `4,040` bytes 和主动 `0x02`
后发送该 seek，设备返回剩余 `884` bytes。恢复结果与此前 BLE 完整副本均为
`4,924` bytes、SHA-256 完全相同，`cmp` 返回 0，Apple 音频检查也识别为同一
段约 1.23 秒的 MPEG-2 Layer III 音频。由此确认该固件组合的 Wi-Fi 非零 seek
能够正确续取缺失尾段。

正式恢复仍采用窄门：仅限主固件 `1.0.6` / Wi-Fi 固件 `1.0.2`，必须由合法
`0x0B status=0x02` 主动提前结束触发，首段必须恰为 `4,040` bytes，剩余必须
大于 0 且不超过一个 `4,040`-byte payload，同一文件只尝试一次。恢复保留原
`.part`、目录目标和 SHA-256 状态，为新
`0x0B` 段建立序号基线；只有精确达到原目录长度、完成边界、SHA-256 和原子
移动后才返回正常 DTO 并进入 Flutter 入库。若当前文件位于批次中间，尾段建立
的下一序号必须跨 quiet boundary 保留，并成为下一文件首帧的严格期望值。
拒绝、二次短发、下一文件序号不连续、overrun、未知状态或长度不符仍删除
`.part` 并失败。

### 4.15 2026-07-17 UI 假失败现场

本次真机原始日志已单独归档。六次均为独立单文件 TCP 会话，前五项分别提交
`19,910`、`35,306`、`294,662`、`45,972` 和 `16,448` bytes。最后一项目录
目标为 `4,924` bytes：

```text
wifi data started without size ack ... targetBytes=4924
wifi frame accepted ... seq=0 payloadBytes=4040
wifi frame accepted ... payloadBytes=1 status=02
wifi premature end observed ... acceptedBytes=4040 targetBytes=4924
wifi tail seek probe starting ... seekBytes=4040 remainingBytes=884
wifi frame accepted ... seq=2 payloadBytes=884
wifi quiet boundary accepted ...
wifi tail seek probe captured ... bytes=4924 registered=false
```

旧 Debug 版本在倒数第二步把完整文件移动到临时探针并返回
`RECORDING_CARD_WIFI_TAIL_SEEK_PROBE_CAPTURED`，所以 UI 显示失败且不入库。
网络连接始终 ready；BLE 断开为 `expectedWifi=true` 的热点切换，不是根因。
修复后不再返回探针错误，而是继续正式校验、原子落盘和统一入库。

同日修复后使用原持久化暂停任务在同一 iPhone/FW920 上复验。设备再次返回
`4,040 + 0x02`，正式恢复路径补回 `884` bytes，并出现：

```text
wifi tail seek recovery starting ... seekBytes=4040 remainingBytes=884
wifi frame accepted ... seq=2 payloadBytes=884
wifi tail seek recovery completed ... bytes=4924
wifi download committed ... bytes=4924
```

批次和项目最终均为 `completed`；本地录音记录与私有文件均为 `4,924` bytes，
SHA-256 与 BLE 参考一致，无 `.part` 残留。Wi-Fi 收尾后 BLE 自动重连并重新读取
完整目录，用户确认文件在“本地录音”可见、可播放，暂停批次造成的菜单锁也在
任务完成后解除。

### 4.16 批次中间项的同类短尾

随后一组 5 文件共享 TCP 批次在第一项立即复现同类固件行为：完整 67 行目录
声明 `4,204` bytes，设备只发送 seq `0` 的 `4,040` bytes 后主动返回 `0x02`，
剩余 `164` bytes。Socket 始终 ready，目录完整结束于 66 行，没有 CRC、目录、
序号、网络或存储错误。
当时正式恢复仍限制为会话最后一项，所以代码按设计返回：

```text
wifi session opening ... requestedFiles=5
wifi session file started ... directoryBytes=4204
wifi frame accepted ... seq=0 payloadBytes=4040
wifi premature end observed ... acceptedBytes=4040 targetBytes=4204
wifi premature end grace expired ...
wifi file failed ... code=RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE
```

同一日志中此前 7 文件共享会话也在该 `4,204 -> 4,040` 文件处复现，证明这不是
热点偶发断开。由于单文件真机已逐字节证明 `seek=4,040` 会返回正确尾段，批次
中间项现在复用同一窄门恢复；新的真机验收必须继续观察尾段后的下一文件数据
序号、quiet boundary、逐项 commit、统一入库及播放，不能只以首项补齐为通过。

### 4.17 深偏移短尾与通用恢复

中间项修复后的 5 文件真机复验确认首项 `4,204` bytes 在 `4,040 + 0x02` 后
通过 seek 补回 164 bytes，正常提交；下一项首帧严格衔接为 seq 3，前 4 项均在
同一 TCP 会话提交。最终 `72,614`-byte 文件连续接收至 seq 47，共 `72,360`
bytes，随后设备主动返回 `0x02`，尾差 254 bytes：

```text
wifi session opening ... requestedFiles=5
wifi directory completed ... rows=66
wifi tail seek recovery starting ... seekBytes=4040 remainingBytes=164
wifi tail seek recovery completed ... bytes=4204
wifi download committed ... bytes=4204
wifi session file started ... directoryBytes=18172
wifi frame accepted ... seq=3 ...
... four files committed ...
wifi session file started ... directoryBytes=72614
wifi frame accepted ... seq=47 payloadBytes=4040
wifi premature end observed ... acceptedBytes=72360 targetBytes=72614
wifi file failed ... code=RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE
```

Socket 全程 ready，目录、CRC、序号、网络和存储均无前置错误，因此它是同一
固件短尾缺陷在更深 accepted-byte offset 的表现，不是 Wi-Fi 断网。协议将
`0x0B` 最后 4 bytes 定义为大端字节 seek，`72,360` 应编码为
`00 01 1A A8`。

后续真机样本进一步给出完整证据：目录目标 `13,566` bytes，首段连续接收
`12,120` bytes 后 `0x02`，`seek=12,120` 返回完整 `1,446`-byte 尾段。恢复的
Wi-Fi 文件与同一录音的 BLE 完整副本均为 `13,566` bytes，SHA-256 完全相同，
`cmp` 返回 0，且都可识别为同一 16 kHz、32 kbps 单声道 MP3。结合此前
`seek=4,040` 的逐字节证据，确认 4,040 只是传输块边界，恢复 offset 应取实际
accepted `.part` bytes，而不是写死常量。

正式构建现允许一次通用尾段恢复：精确固件 profile、合法主动 `0x02`、1 秒
无尾帧、健康连接、空解析 buffer、`0 < accepted <= UInt32.max`、可信目录目标
未变化、尾差严格位于 `0..4,040` 之间且未重试。seek 后首个数据 payload 必须
恰好等于完整尾差，否则按忽略/舍入偏移失败。精确达到原目录长度后仍须通过
序号、边界、SHA-256、原子移动和统一入库；拒绝、二次短发、overrun 或任何
不一致仍删除 `.part`。产品路径不再返回 Debug 探针错误。

### 4.18 文件长度字节序误判被误报为 Wi-Fi 断开

同一文件在五个 TCP 会话中都被客户端解析为 `155,648` bytes，并在连续接收
`152,680` bytes 后把 seq 38 的 `4,040`-byte payload 判为 overrun。后续取证
继续看到 seq 39–43，说明设备并未在错误阈值结束。原生端先返回
`RECORDING_CARD_WIFI_DATA_OVERRUN` 并关闭 Socket，页面才把暂停批次概括为
“Wi-Fi 连接已中断”；BLE 的 `expectedWifi=true` 仍只是热点切换。

根因是目录与 `0x0B` ACK 的双端序解析器采用“两个候选都合法时取较小值”。原始
长度 `00 60 02 00` 按 FW920 协议大端应为 `6,291,968`，按小端才是
`155,648`。同一错误类别此前已出现：`00 12 BD 1C` 按大端是符合约 5 分钟
32 kbps MP3 的 `1,228,060` bytes，按小端会错误显示约 `482 MB`；“取较小值”
只是在旧样本中碰巧选对，在本样本中反而截短。此前蓝牙得到的 `155,648`-byte
可播放 MP3 是客户端达到错误阈值后主动 `0x0C` 的前缀，不是独立 EOF 证明。

iOS、Android 现在统一使用协议大端值并标记 `trusted`，不因小端候选更小、仍在
1 GiB 内或大端超限而切换到小端。目录和 ACK 独立解析，可信值冲突会在写入前
分型失败；Wi-Fi 新目录也会清除调用方携带的陈旧大小。Wi-Fi 与 BLE 都使用修正
后的完整目标，继续保留严格长度、序号、SHA-256、边界和原子落盘检查；不增加
特定文件大小裁剪。Android 同时补齐单字节 `0x00/0x01/0x02` ACK 映射和重复目录
冲突检查，避免同一协议变体在两个平台得到不同边界。

修正版随后在 FW `1.0.6` / Wi-Fi `1.0.2` 真机上恢复一个 47 项批次：一次
TCP 会话内 `47/47` 全部完成，文件覆盖约 2 KB 至 874 KB，并包含多个非整包尾长
和一次性 tail-seek。日志未出现网络、序号、overrun、存储或入库错误；会话结束后
只执行一次强制 BLE 重连，握手和完整目录刷新均成功。本结果用于验证整类边界，
不把某个具体文件大小写入兼容特判。

## 5. 稳定读取真机日志

Debug 构建会写入 App Data Container：

```text
Library/Caches/fw920-debug.log
```

拉取日志：

```zsh
xcrun devicectl device copy from \
  --device <DEVICE_UDID> \
  --domain-type appDataContainer \
  --domain-identifier <APP_BUNDLE_ID> \
  --source Library/Caches/fw920-debug.log \
  --destination /tmp/fw920-debug.log \
  --timeout 20
```

筛选关键阶段：

```zsh
rg 'wifi (connection ready|frame accepted|directory completed|request sent|progress|download committed|download failed)' \
  /tmp/fw920-debug.log
```

只读核对私有录音目录时，输出中不要复制真实路径、文件名或用户数据到提交文档。
应只记录文件数量、大小、哈希是否为 64 位十六进制以及是否存在 `.part`。

## 6. 错误定位

| 错误阶段 | 首查内容 | 常见原因 |
| --- | --- | --- |
| Wi-Fi 准备 | `0x1B` ACK、`0x1F` 长度 | 固件不支持、凭据未缓存、BLE 提前断开 |
| TCP 连接 | 进程数量、手机当前 Wi-Fi、`0x20` | 连错热点、重复 Runner、前一个 TCP 未释放 |
| 目录 | `0x0A` rows/end、header/tail/length | 误发 BLE 帧、CRC profile、目录未消费完 |
| 文件请求 | 目录是否命中、请求 payload=18 bytes | 文件已删除、文件名不一致、旧目录 |
| 数据传输 | seq、accepted/target、30s no-progress | 丢帧、重复帧、网络切换、错误 size |
| 校验 | actual size、SHA-256、`.part` | 短文件、overrun、落盘失败、存储不足 |
| 本地录音库 | manifest、content hash、private stat | 登记失败、重复映射、私有文件缺失 |

会话级网络、协议、序号、完整性或存储错误应暂停批次；文件不存在或单项请求
被拒绝可以记录失败后继续。任何错误都不能生成 Mock 成功记录。

## 7. 隐私规则

可以记录：

- 固件版本、平台、阶段、command、payload length、sequence。
- 收到/目标字节数、耗时、错误码、CRC 是否匹配。
- 脱敏 correlation ID。

禁止记录：

- SSID/密码原文、绑定 token、账号 token。
- 真实设备唯一标识、真实文件名、完整私有路径。
- 音频 bytes、音频转写内容或用户原文。

## 8. 批量传输验收清单

- [x] 热点过期前后可在同一批次重开，重开阶段不提前创建 TCP。
- [x] 三条文件共用一次 TCP 和一次 67 条目录，sequence 跨文件连续，逐项登记。
- [ ] 一次 BLE Wi-Fi 准备、一次热点提示、一次 TCP `0x20`。
- [ ] 一次 `0x0A` 目录可服务全部选中文件。
- [ ] 至少 10 条大小混合文件在同一 TCP 中严格串行。
- [ ] 每个文件有独立 sequence、长度、SHA-256、`.part` 和原子提交。
- [ ] 前一文件结束边界确认后才请求下一文件。
- [ ] 当前文件失败不会污染下一文件；会话错误会暂停剩余队列。
- [ ] 取消保留已完成文件、删除当前 `.part`、取消未开始项。
- [ ] App 重启后已完成项保留，未完成项重新连接热点后从文件头重试。
- [ ] 重复批次不会生成重复本地文件；本地重命名后仍能按 hash/manifest 识别。
- [ ] 所有成功文件在本地录音库可见且实际可播放。
- [ ] Android 在完成同等 FW920 真机冒烟前只标记“代码对齐，硬件待验收”。

## Wi-Fi 批次的异常恢复与真机验收边界

本节记录当前实现契约，不表示以下系统场景已通过真机验收。

- 控制器是唯一任务状态源；`startQueuedWifiBatch`、`resumeWifiBatch`、
  `retryFailedWifiBatch` 完整执行核验、原设备连接、重新获取热点凭据、加入热点、
  建立 TCP、逐文件下载、关闭 TCP 和本地登记。弹窗只观察指定 batchId。
- operationPhase 区分恢复、热点准备、加入热点和结束；批次 state 区分传输、
  校验、本地登记、暂停和终态。二者不是另一套并行运行时。
- 下载前单条检查点保存 planned_native_file_id、attempt_id、设备/源文件身份和
  长度可信度，并等待持久化。只有完整文件通过长度/哈希校验后才原子改名。
  恢复只查指定目标，不在文件间扫描整库；已提交但未回调的文件先补登记。
- 未提交文件沿用预分配目标，从头覆盖 `.part`；不增加跨进程字节续传。
  本文历史受限尾部续取和原有固件兼容规则保持不变。
- 用户结束意图 stop_requested 先持久化再清理，不能被旧回调撤销。
  已完成项与本地文件保留；尾部账本标记 STOPPED_BY_USER、人工重试类别，
  即使关闭批次摘要，自动蓝牙同步也不能立即重新接管这些项。
- 启动先恢复本地批次，再处理原生首帧触发的目录扫描，避免本地核验世代竞争。
  前台恢复先查询原生 Wi-Fi；仍有效则仅观察，失效则暂停并提供继续/结束。
  权限窗口造成的短暂失焦不直接判为连接失败，本地登记不依赖 TCP 存活。
- 进度、中断和控制请求关联批次/尝试；重复继续合并，迟到事件被丢弃。
  页面退出或“稍后查看”不终止任务；账号运行时销毁则停止自己的传输。
- Android 手动 Wi-Fi 与现有 connectedDevice 前台服务共用资源所有权，
  实际传输按需持有有限时长 CPU 唤醒锁；网络 onLost 和会话错误上报 Dart。
  iOS 使用有限后台执行额度，到期中断并释放会话；不降低文件保护等级。
- 身份缺失、混合设备、重复项目、非法本地目标等记录不静默跳过，不伪装完成。
  无法安全续传时显示恢复受阻，允许显式结束并保留文件。

### 必须另行执行的物理设备验收

1. Android/iPhone 真实传输时关闭 Wi-Fi、切换热点、离开范围、录音卡断电。
2. 两端切换应用、锁屏、长时间后台后返回；Android 用户强停和进程回收。
3. iOS 后台额度到期、锁屏文件保护、解锁后恢复。
4. 传输中主动录音、热点加入拒绝/取消、权限撤销、空间不足。
5. 结束与下载完成同时发生、再次继续与旧热点回调同时到达。

验收记录应区分物理设备/Simulator、原生事件、Dart 状态和持久化检查点。
本次静态检查、单元/组件测试及 Simulator 编译不能替代上述无线网络与系统生命周期验收。
本次默认不安装或覆盖手机上的应用，也不承诺进程被杀后继续传输。
