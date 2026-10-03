# iOS / Android 原生语音接入

仅复制 Dart 不够：腾讯识别桥依赖已有录音桥产生的共享 PCM。原始音频应由同一个采集链路供录音与识别消费，不能让页面、录音插件和腾讯 SDK 各自争抢麦克风。

## 1. Dart 通道

| 通道 | 所属能力 |
| --- | --- |
| `huahuoai/tencent_live_asr` | 实时识别控制，`start` / `stop` / `release` |
| `huahuoai/tencent_live_asr/events` | `partial` / `segment` / `completed` / `diagnostic` / `error` 等事件 |
| `huahuoai/voice_recorder` | 录音控制 |
| `huahuoai/voice_recorder_levels` | 音量反馈 |
| `huahuoai/voice_recorder_pcm16` | PCM16 音频数据 |

字段与事件类型以 `tencent_live_asr_port.dart`、`voice_recorder_port.dart` 和两平台桥接源文件为准。不要单独改通道名称、事件字段、session ID 或 generation 规则。

## 2. iOS

- `Flutter/src/ios/Runner/TencentLiveAsrBridge.swift`：`QCloudRealTimeRecognizer`、临时凭据、共享 PCM data source、异步启动确认、识别事件、结束与释放。
- `Flutter/src/ios/Runner/VoiceRecorderBridge.swift`：录音及 `VoiceRecorderPCM16NativeHub`，腾讯桥直接依赖此 hub。
- `Flutter/src/ios/Runner/AppDelegate.swift`：在 `didInitializeImplicitFlutterEngine` 内注册录音桥并持有腾讯桥实例；目标工程使用其他 Flutter engine 生命周期时应等价注册，不能漏掉对象持有。
- `Flutter/src/ios/Podfile`：iOS 最低版本 `15.0`；锁定 `QCloudRealTime` 为 `3.1.39`。Podfile 还含 SDK 头文件兼容处理，必须连同 `post_install` 一起核对，不要只摘一行 pod 声明。
- `Flutter/src/ios/Podfile.lock`：保留原解析版本。`Pods/` 未打包，接收方先 `flutter pub get`，再在 `Flutter/src/ios` 下 `pod install`。
- 保留/合并 `Runner-Bridging-Header.h`、Xcode build phase 与源文件引用；Info.plist 中有麦克风用途说明和后台 audio。背景录音按目标产品需求和平台要求开启，不因复制配置就自动获得能力。
- 原工程包含 App Group/分享/录屏/Widget 等附属 target，仅为完整工作区兜底。迁移三项功能时不得把原签名团队、Bundle ID 和 App Group 当成可直接复用的凭据。

## 3. Android

原生目录：`Flutter/src/android/app/src/main/kotlin/com/hangzhouchuda/huahuoai/`。

- `TencentLiveAsrAndroidBridge.kt`、`VoiceRecorderAndroidBridge.kt`、`VoiceRecordingForegroundService.kt`；录音服务引用的通知/平台辅助类已随完整原生目录提供。
- `MainActivity.kt` 负责 `configureFlutterEngine` 注册、权限结果转发与注销；在目标 Activity 中合并这些调用。
- 本地 SDK `Flutter/src/android/app/libs/asr-realtime-speakerSeparation-release.aar` 已随包提供，不是一个空占位文件。
- `android/app/build.gradle.kts` 保留 AAR 文件依赖、OkHttp `4.2.2`、Java/Kotlin 17、compileSdk 36、desugaring 和 release 前的 `verifyTencentRealtimeAsrAar` 类检查。
- `android/app/proguard-rules.pro` 必须随迁移合并：腾讯桥通过反射调用 SDK，release 混淆不能删除所需类/方法。
- `AndroidManifest.xml` 的 `RECORD_AUDIO`、麦克风前台服务权限、service 声明及运行时授权流程必须合并；仅有 Manifest 权限不等于已获得用户授权。
- Release 签名由接收方自己的 key.properties 或环境变量注入，本包不提供私钥/密码。

## 4. 生命周期必须保留

1. 请求麦克风权限，建立唯一的录音拥有者和共享 PCM 采集。
2. 申请未过期的 STS 凭据，再启动腾讯识别器并等待启动结果。
3. 使用增量 partial 与已确认 segment 合并文本，保留说话人信息/时间与当前 attempt 的隔离。
4. 停止时等待必要的尾段和完成事件，然后释放识别器、共享消费与录音资源，并完成后端 session。
5. 导航离开、切换账号、进入后台、取消、启动异常、断网重连都经过现有状态机清理，不直接在 UI dispose 中跳过控制器收尾。

模拟器可用于 UI/通道 wiring 检查，但不能替代物理设备的麦克风、后台行为和真实识别验收。不要创建新模拟器；需要模拟器时使用接收方已有设备，原工程通常使用 iPhone 17 Pro。

## 5. Android「服务授权不可用」排查记录

2026-09-12（北京时间）对账号 `188****0995` 的只读排查：

- **服务端访问日志**：01:26:53、01:27:46、01:34:31、02:04:22 的实时会话创建均返回 HTTP 201，随后约一秒出现返回 HTTP 200 的 complete 请求。
- **服务端数据库**：账号状态正常；对应四个会话均已下发，`failure_code` 为空，临时凭据有效期为 15 分钟。这里仅证明后端会话下发成功，不证明腾讯已经接受 WebSocket 请求；complete 是计费收尾，也不代表识别成功。
- **本地代码和 SDK**：Android 的六参数构造函数确实接收 STS token，SDK 通过 `X-TC-Token` 请求头发送，不能把本次问题归因于漏传 token。Android 和 iOS 使用不同的原生 SDK，不能用 iOS 正常代替 Android 验收。
- **确认的错误处理缺陷**：Android 丢弃提供方数字错误码，将各种服务端拒绝统一转换为 `PROVIDER_REJECTED`；共享弹窗又把该类别误判为授权失败。旧日志只有 `serverFailure=true`，无法区分鉴权、参数、并发、音频或服务异常。
- **本次修复**：在当前识别监听器内从公开的原始回调只提取整数错误码，按官方定义分类，并保留安全 Logcat 诊断。临时服务异常沿用有限重连，超并发允许手动重试，鉴权/配置/额度等终态不自动反复申请凭据。未知拒绝不再冒充鉴权失败。识别引擎、授权 SDK 二进制和 iOS 原生链路未更换。

错误码依据：腾讯云实时语音识别 WebSocket 官方文档
`https://cloud.tencent.com/document/product/1093/48982`。

验证结果：Android 桥接 JVM 定向测试 17 项通过；Flutter 控制器、弹窗和原生通道定向测试合计 36 项通过。未连接 Android 物理设备，因此**本次实际提供方拒绝原因和真机转写恢复仍未确认**，不能将错误分类修复等同于整条识别链路验收通过。

下一步需连接出现问题的 Android 手机，安装包含本次修改的版本，在「聊一聊」复现一次，读取对应的固定诊断标签：

```sh
adb devices -l
adb -s <设备序列号> logcat -v threadtime -s HuahuoLiveAsr:I '*:S'
```

关注 `stage=recognition_failed` 中的 `clientCode`、`serverFailure` 和 `providerCode`，再依据确定的提供方类别排查请求参数或服务配置。不得开启 SDK 全量请求日志，也不得输出 STS 凭据、完整请求 URL、原始提供方消息或识别正文。服务端始终只读。
