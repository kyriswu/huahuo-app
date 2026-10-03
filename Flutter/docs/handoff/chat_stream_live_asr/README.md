# 聊一聊 / 流式输出 / 语音实时转写迁移包

## 先看这里

本包从当前工程的工作目录导出，不是只从 Git 已提交版本导出；因此包含打包时已经存在的未提交功能修改。原工程的业务源码、测试和原生配置没有因打包而改写。

为落实“可以多一些，但不能少一些”，包内保留完整 Flutter 源码工作区，而不是只摘取几个页面。它是**源码交接包，不是已经解耦的即插即用插件，也不是完整后端部署包**。同事可以先对照原实现复现，再按依赖清单迁移至自己的工程。

## 包内结构

| 路径 | 用途 |
| --- | --- |
| `Flutter/src/` | 全部移动端 Dart 源码、UI、测试、素材、iOS/Android 原生工程 |
| `Flutter/packages/` | 四个本地共享包；API、协议、编辑器、产品模型与基础能力 |
| `Flutter/vendor/` | 原工程的本地插件与其已有原生 SDK；保留其许可和上游说明 |
| `Flutter/third_party/` | 锁定的 SQLite 本地 C 源码，避免 native build hook 缺依赖 |
| `Flutter/desktop/` | 工作区已声明的桌面成员；用于保持 workspace 完整，并供界面/共享层参考 |
| `backend_reference/` | 后端接口原文和聊天、SSE、实时 ASR 的相关实现参考；不是独立可编译后端 |
| `MIGRATION_GUIDE.md` | 核心入口、迁移顺序、运行配置、状态恢复与常见漏项 |
| `BACKEND_CONTRACT.md` | 根据当前前后端代码核对的协议摘要，以及旧文档冲突警告 |
| `NATIVE_INTEGRATION.md` | 原生录音桥、共享 PCM、腾讯 SDK、权限与注册方式 |
| `ACCEPTANCE_CHECKLIST.md` | 同事迁移后的最小验收清单及已有测试入口 |
| `CORE_FILES.md` / `DEPENDENCIES.json` | 核心文件、Dart 静态依赖闭包、外部包与资源清单 |
| `CHAT_UI_FILES.md` | 聊一聊 UI 专用索引：页面、输入区、时间线、历史会话、共享组件与素材 |
| `MANIFEST.json` | 交付文件完整清单及逐文件来源、大小、SHA-256 |
| `SHA256SUMS.txt` / `PACKAGING_REPORT.md` | 内容校验、打包范围、排除项和校验边界 |

## 建议阅读顺序

1. 阅读 `MIGRATION_GUIDE.md`，明确“实时转写成可编辑文字”与“录音上传后异步 ASR”是两条不同链路。
2. 阅读 `CORE_FILES.md`，顺着 UI → Controller → API → Tracker/Native Bridge 定位代码。
3. 阅读 `BACKEND_CONTRACT.md` 和 `NATIVE_INTEGRATION.md`，先接好后端、登录/工作区和麦克风。
4. 保留 `Flutter/pubspec.yaml` 与 `Flutter/pubspec.lock` 的依赖上下文，按 `ACCEPTANCE_CHECKLIST.md` 分阶段验证。

## 需要自行准备

- Flutter/Dart SDK、平台工具链、依赖下载网络和目标项目的应用标识/签名。
- 可用的业务后端、用户登录凭证、就绪的工作区、可用 Agent Profile 与相应权限/额度。
- 后端签发的腾讯实时 ASR 临时凭据；不能把长期 SecretId/SecretKey 写进 App。
- 若将现有腾讯 AAR 或本地推送 SDK 用于另一个产品，接收方需确认对应 SDK 的使用和再分发授权。

包内源码保留原默认配置，不代表授权访问原业务环境。运行前显式替换业务、录音、实时转写及可选声纹服务地址；不要直接使用生产账号、原工程的 App 标识或签名。

本次只做交接范围和压缩包完整性校验，不启动模拟器、不进行真实语音识别、不调用付费模型、不访问或修改服务器，也不声称迁移后的工程已经通过端到端测试。
