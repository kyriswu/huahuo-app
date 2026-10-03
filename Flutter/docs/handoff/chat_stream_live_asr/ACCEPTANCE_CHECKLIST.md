# 迁移后的最小验收

本清单供接收方在目标工程执行，不代表打包时已经执行。优先少量、有针对性的验证，不需先运行全工程测试。

## 1. 包体与依赖

- 解压后在包根执行 `shasum -a 256 -c SHA256SUMS.txt`，确认文件没有损坏。
- 阅读 `PACKAGING_REPORT.md`，确认 Dart 引用、路径依赖、声明资源和原生 AAR 的检查结果。
- 恢复 pub 依赖；iOS 恢复 Pods；确认自己的后端地址、账号、工作区、Agent Profile、ASR 权限与签名配置。

## 2. 文字对话与真实流

- 新会话与已有会话都能发消息；空输入/重复点击不会产生错误提交。
- Assistant 内容来自真实网络增量事件，Markdown/代码块/资源逐步显示正常。
- 断网、SSE 静默、重连后不重复字符、不丢终态；保留轮询回退与 thread 最终回读。
- 停止生成、请求拒绝、提交结果未知、失败重试有明确且可操作的状态。
- 切换会话/退出页面/回到前台后，不串会话、不出现重复回答或悬空任务。
- 历史、标题操作、附件、预览、对话框、导航等迁移进来的可见控件都能工作。

## 3. 实时语音转写

- 首次授权、拒绝权限、取消录音、无声输入都有正确反馈，不能卡在 loading。
- 说话中可见 partial，句子确认后不重复拼接；停止后的尾段保留。
- 转写最终形成可编辑文本草稿；修改后发送走正常文本聊天，不误发成音频上传。
- 快速开始/停止、上一轮迟到回调、切会话、切账号不污染新轮次。
- 断网/凭据过期/额度不足/后台恢复错误可恢复，退出后不持续占用麦克风。
- 如迁移了录音上传能力，单独验证文件保存、上传、ASR 任务与回执；这不是实时转写测试的替代品。

## 4. 已有测试入口

以下文件随包原样提供。先挑选相关的一小组，环境恢复后再执行：

```sh
cd Flutter/src
flutter test test/features/chat/chat_stream_reveal_buffer_test.dart \
  test/features/chat/chat_run_tracker_test.dart \
  test/features/transcription/live_transcript_controller_test.dart \
  test/features/transcription/live_transcription_api_test.dart \
  test/features/transcription/tencent_live_asr_port_test.dart
```

更完整的功能测试位于 `test/features/chat/`、`test/features/transcription/`；共享 API 解析测试位于 `Flutter/packages/huahuo_api/test/`，移动 HTTP/SSE 测试入口为 `Flutter/src/test/core/api_client_test.dart`。Android 原生测试在 `android/app/src/test/`，iOS 测试在 `ios/RunnerTests/`。

## 5. 本次交付验证边界

本次验证的是静态源码交付范围、Dart 引用存在、工作区/资源/本地 SDK 文件存在、源码字节一致、归档内容哈希与 ZIP CRC；没有在新工程构建、没有跑完整 Flutter 测试，也没有做真实模型/腾讯识别/计费调用。包中保留的原测试可用于迁移后的回归。
