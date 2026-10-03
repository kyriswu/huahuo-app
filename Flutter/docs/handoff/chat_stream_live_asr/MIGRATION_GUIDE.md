# 迁移指南

以下路径均相对于交付包根目录。自动生成的 `CORE_FILES.md` 为实际文件清单，`DEPENDENCIES.json` 保留静态 Dart 引用关系；完整 `Flutter/` 是防漏依赖的兜底，不能把核心列表误认为可直接单独编译的最小插件。

## 1. 核心代码地图

| 能力 | 主要文件/目录 |
| --- | --- |
| 聊一聊页面、输入与交互 | `Flutter/src/lib/features/ui_v3/presentation/v3_chat_page.dart`、`presentation/chat/` |
| 消息时间线、执行过程、输出展示 | `v3_chat_conversation_timeline.dart`、`v3_chat_execution_process.dart`、`v3_chat_runtime_summary.dart`；这些文件分别位于上述 `presentation/chat/` 或 `presentation/` |
| 会话与一轮消息状态机 | `Flutter/src/lib/features/chat/application/chat_controller.dart`、`chat_controller_state.dart`、`chat_controller_policies.dart`、`chat_turn_state_machine.dart` |
| SSE/Run 生命周期与恢复 | 同目录 `chat_run_tracker.dart`、`chat_thread_progress_poller.dart`、`chat_runtime_invocation_mapper.dart` |
| 增量文字逐步揭示 | 同目录 `chat_stream_reveal_buffer.dart`；必须与真实网络事件链路一起迁移，不是用打字动画替代服务端流 |
| 会话、语音、附件、资源 API | `Flutter/src/lib/features/chat/data/`，以及 `application/chat_voice_uploader.dart`、`chat_file_attachment_uploader.dart`、`chat_assistant_note_creator.dart`、`resource_image_reader.dart` |
| 共享 HTTP/SSE/协议模型 | `Flutter/packages/huahuo_api/lib/src/api/`；尤其 `api_client.dart`、`domain_clients.dart`、`endpoint_catalog.dart`、`api_contract_manifest.dart` |
| 实时转写状态机、结果合并 | `Flutter/src/lib/features/transcription/` 全目录 |
| 聊天录音/转写草稿状态 | `Flutter/src/lib/features/chat/application/voice_message_controller.dart` |
| 原生录音抽象 | `Flutter/src/lib/core/native/voice_recorder_port.dart` |
| 注入与生命周期绑定 | `Flutter/src/lib/app/di/chat_providers.dart`、`app/bootstrap/app_providers.dart`、`app/bootstrap/core_provider_module.dart`、`app/runtime/`、`app/lifecycle/` |
| 登录、缓存、诊断、调度 | `Flutter/src/lib/core/auth/`、`core/api/`、`core/storage/`、`core/tasking/` 等实际依赖；以 `DEPENDENCIES.json` 为准 |
| 其他实时转写使用场景 | `Flutter/src/lib/features/recordings/`、`features/ingestion/`、`features/ui_v3/presentation/v3_capture_pages.dart`、`v3_meeting_capture_page.dart` 与单人转写窗口 |

## 2. 三条链路，不要混淆

### A. 文字聊天与流式回答

页面输入 → `ChatController` → 会话创建/读取 → `RemoteChatApi` 提交结构化输入 → 获得 `agentRunId` → `ChatRunTracker` 订阅 SSE/跟踪 Run → 控制器合并事件 → reveal buffer 平滑显示 → Run 终态及 thread 持久化消息回读。

保留幂等提交、未知提交结果处理、同一会话并发准入、取消、错误展示、历史会话切换与标题别名、跨前后台恢复。收到 HTTP 200/202 不代表 AI 已完成，SSE 断开也不代表会话失败或成功。不要删除备用事件/状态轮询和最终消息回读。

### B. 实时语音转成可编辑文字

`VoiceMessageController.startLiveTranscription(owner: ...)` → 原生录音及共享 PCM → `LiveTranscriptController.start(owner: ...)` → 后端签发 STS 临时凭据 → 腾讯原生实时识别 → EventChannel `partial`/`segment`/`completed` 等事件 → 合并草稿 → 停止并等待尾段 → 可编辑文本，用户确认后走普通文本聊天提交。

此链路不是自动把音频资源上传为 voice-message。保留 `owner`、`attemptId`、session generation 和退出页面清理，防止上一轮回调污染下一轮、多个页面抢麦、切账号串数据。共享的转写 provider 还绑定账号/工作区与前后台生命周期，不能只复制页面按钮。

### C. 录音文件上传与异步转写

原生录音文件 → 私有路径解析/上传 → 媒体资源确认 → voice-message 或 recording/ASR 任务 → 状态轮询/回执投影。这是已有兼容能力及录音场景链路，不应删掉，也不能拿它替代 B 的边说边转写。

## 3. 推荐迁移顺序

1. 先在独立目录解压保留原目录层级。不要覆盖目标工程现有文件，也不要丢掉工作区根 `pubspec.yaml`、锁文件、`desktop` 成员或本地包路径。
2. 接入基础层：API transport、鉴权/token 刷新、会话/工作区、幂等键、失败模型、缓存 DAO、调度和生命周期。目标工程已有对应能力时实现原 Port 的适配器，不要改写业务状态机来绕开前置条件。
3. 迁移 chat domain/data/application、Riverpod providers、共享 UI/theme/Markdown/编辑器、附件与媒体能力。跟随 `CORE_FILES.md` 的闭包迁移相关依赖。
4. 先验证文字提交、真实 SSE 输出、停止生成、历史回读，再接原生录音、腾讯 SDK 和 realtime-asr 会话接口。
5. 接上完整页面交互：输入/发送、历史操作、附件选择/上传/重试、资源预览、录音/停止/取消、错误对话框与导航。不要留下有视觉反馈但没有业务动作的按钮。
6. 最后再逐层删减不需要的工作区成员/产品能力，届时同步修改目标工程的 pubspec、资源与 DI；本交接包不提前裁掉它们。

## 4. SDK 与启动配置

源码声明：Dart `>=3.12.0 <4.0.0`；移动端 Flutter `>=3.44.0`。精确依赖以包内根 `Flutter/pubspec.lock` 和各成员 `pubspec.yaml` 为准。打包机 SDK 的本地缓存版本记录在 `MANIFEST.json`，不是要求下载某个未经验证的“最新版”。

至少显式设置这些 dart-defines，避免录音配置回退到原生产域名：

```sh
cd Flutter/src
flutter pub get
flutter run -d '<已有设备ID>' \
  --dart-define=HUAHUO_API_BASE_URL=https://your-backend.example \
  --dart-define=HUAHUO_RECORDING_API_BASE_URL=https://your-backend.example \
  --dart-define=HUAHUO_LIVE_TRANSCRIPTION_BACKEND_BASE_URL=https://your-backend.example \
  --dart-define=HUAHUO_VOICE_GATEWAY_BASE_URL=https://your-voice-service.example
```

示例域名必须替换成自己的真实服务。`HUAHUO_VOICE_GATEWAY_BASE_URL` 用于声纹等相关语音服务，不等同于腾讯长期密钥配置；暂不接声纹时使用目标工程的无声纹适配器。实时转写地址默认跟随 recording API 地址，录音地址在原源码中有生产默认值，所以必须显式覆盖。

`HUAHUO_V3_DEMO_AUTH` 仅是 debug 演示鉴权开关，不能替代真实后端登录，也不会凭空产生有效的腾讯 STS 凭据。真实聊天还依赖工作区 ready 和可用公开 Agent Profile。

App 保留原包名/Bundle ID、App Group、推送和其他产品能力。迁移到新工程应合并所需桥接注册，并使用自己的签名、权限声明和标识；不要直接复制原 AppDelegate/MainActivity 覆盖目标工程。

## 5. 保留的完整性边界

- 已包含全量业务源码、测试、golden 素材、integration_test、共享包、原生源文件、本地 AAR 与 vendor SDK。
- 不包含 `build/`、`.dart_tool/`、CocoaPods 下载缓存、Flutter 生成配置、本机签名/凭据、设备数据库、日志或生产配置文件。依赖需在接收方机器恢复。
- 后端实现是协议核对用摘录，Go import 的全工程依赖不在本包中；要部署整个原后端必须另行取得完整后端工程及受控配置。
- 静态依赖检查不能证明运行时路由、权限、资源 URL、SDK 账号授权或真实服务可用；按验收清单在目标工程验证。
