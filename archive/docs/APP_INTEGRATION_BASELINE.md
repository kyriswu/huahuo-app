# 花火 APP 双仓库接入基线

> 历史交接资料：当前产品源码以 `Flutter/src`、`Flutter/desktop` 和
> `Flutter/packages` 为准。文中旧的 SCM 镜像和 `SOURCE_TREE.md` 约定已经退役，
> 不要按这些历史步骤操作。

状态：冻结交接基线，允许合同开发和 Mock 接入，不代表生产后端已经可用。

## 1. 唯一代码基线

```text
repository:       git@github.com:YMX899/huahuoai-app.git
handoff branch:   baseline/flutter-desktop-api-integration
source commit:    23c8b30e46ad73097d2c357ce7b1b526c79fcd9a
workspace root:   Flutter/
mobile app:       Flutter/src/
desktop app:      Flutter/desktop/
shared packages:  Flutter/packages/
```

`source commit` 是包含手机端、Windows/macOS Desktop 和共享包的产品代码
基线。交接分支只允许在该提交之上增加交接文档或经过单独验收的 APP 接入提交。
接收方必须使用交接方给出的完整 commit，不得只跟随可移动分支，也不得把旧
`Flutter-UI` 分支手工合并进来。

旧 APP API 基线 `e0471b2b7ec023cdea44b48ce2f27a170915613b` 与当前
Desktop 基线来自共同祖先，并非父子关系。当前 Desktop 基线内五个既有核心 API
文件与该旧基线字节一致，因此可以在当前基线上继续 API Foundation，但不能通过
合并旧分支来“补齐”代码。

## 2. 唯一协议基线

```text
repository:     git@github.com:YMX899/huahuoai-docs.git
remote branch:  baseline/docs-native-api-contract
commit:         97e510c8b7e2a2e33cc4bbf809fa666e26983bd3
product root:   products/huahuo-ai/
API root:       products/huahuo-ai/05-api/
```

APP 仓库不复制 API 正文。所有请求、响应、错误、分页、幂等、Agent/Skill 选择和
媒体输入合同都从上述 Docs commit 读取。这样可以避免 APP 内置副本与正式协议漂移。

## 3. 接收步骤

```powershell
git clone git@github.com:YMX899/huahuoai-app.git huahuoai-app
git -C huahuoai-app fetch origin baseline/flutter-desktop-api-integration
git -C huahuoai-app switch --detach <交接方提供的完整 APP commit>

git clone git@github.com:YMX899/huahuoai-docs.git huahuoai-docs
git -C huahuoai-docs fetch origin baseline/docs-native-api-contract
git -C huahuoai-docs switch --detach 97e510c8b7e2a2e33cc4bbf809fa666e26983bd3
```

接收后先验证：

```powershell
git -C huahuoai-app status --short
git -C huahuoai-app rev-parse HEAD
git -C huahuoai-docs status --short
git -C huahuoai-docs rev-parse HEAD
```

两个工作树都必须为空，Docs HEAD 必须严格等于上述 commit。APP HEAD 必须严格
等于交接方提供的完整 handoff commit，不能以分支最新值代替验收 pin。

## 4. 代码目录

```text
Flutter/
  pubspec.yaml                         Dart workspace
  src/                                 Android/iOS 手机端
  desktop/                             Windows/macOS Desktop
  packages/huahuo_foundation/          共享设计基础
  packages/huahuo_editor/              共享文档编辑核心
```

`Flutter/desktop` 是独立 Desktop App，不是手机页面的响应式副本。Desktop 不得直接
import `Flutter/src/lib`；共享代码只能向 `Flutter/packages` 下沉。手机端和 Desktop
可以接同一套公共 API 协议，但需要各自的应用层适配和验收。

当前 Desktop 状态是 `implementation-partial`：本地编辑、知识图谱、Markdown 预览、
Windows/macOS runner 和测试资产已经存在，但尚不能据此宣称完整云同步或正式 Backend
接入已经完成。

## 5. 协议阅读顺序

1. `products/huahuo-ai/05-api/README.md`
2. `05-api/02-endpoint-catalog.md`
3. `05-api/01-common-api-protocol.md`
4. `05-api/03-auth-session-api.md`
5. `05-api/08-error-idempotency-quota-rate-limit.md`
6. `05-api/09-async-polling-upload-recovery.md`
7. 当前功能对应的 `05-api/19`、`20`、`21`、`22`、`23`、`24`、`25` 或 `27`
8. `04-system-facing-design/app-api-contract.md`，仅用于查找流程和 05 owner
9. 05 文档直接链接的特定 04 内部协议

`05-api/02-endpoint-catalog.md` 是唯一接口目录。APP 不得从旧页面代码、SCM 示例、
Backend 当前返回或历史对话反推新的 wire 字段。

## 6. Profile 和 Agent 接入规则

- APP 只提交 Catalog 返回的 `agentProfileId`、`skillProfileIds[]` 和可选
  `modelProfileId`。
- 首批规范 Agent ID 见 API 23。新发布 Profile 的 APP Public ID 与 Runtime ID
  字符串相同，但 APP 永远不接收或维护 Runtime 映射字段。
- APP 不追加 `_agent`，不删除前缀，不提交 Database ID、Release ID、Prompt、Tool
  policy 或物理路径。
- 未发布的 Profile/Skill 使用 Mock 或明确不可用状态，不能静默降级到其他 Agent。

## 7. 本地构建和验证

要求 Flutter 3.44.6；Dart SDK 必须满足 `>=3.12.0 <4.0.0`。Windows 还需要支持
Desktop C++ 的 Visual Studio 工具链，macOS 构建需要 Xcode。

Workspace 依赖：

```powershell
Set-Location huahuoai-app/Flutter
flutter pub get
```

手机端：

```powershell
Set-Location src
flutter analyze
flutter test
flutter run -d <android-or-ios-device>
```

Windows Desktop：

```powershell
Set-Location ../desktop
dart format --set-exit-if-changed lib test
flutter analyze
flutter test
flutter run -d windows
flutter build windows --release
```

macOS 必须在 macOS 环境另外完成 build、启动和截图验收。不得用 Windows 通过结果
代替 macOS 平台验收。

## 8. 当前允许和禁止的工作

现在允许：公共网络层、DTO、目录读取、Agent/Skill 选择器、Mock repository、合同测试、
页面接线，以及 Desktop 对同一公共合同的独立适配。

现在禁止宣称完成：真实 Backend 联调、生产切换、尚未发布的 Agent/Skill、今日选题读取、
Feed 聚合、人设植入、完整 Desktop 云同步。真实环境切换必须等待 Backend Merge、Ops、
PostgreSQL 和 `39.107.250.25` 联合验证全部通过。

任何 APP 修改仍遵守仓库 `AGENTS.md`：直接修改源码、测试和正式协议，并按当前工作流
完成格式化、分析和聚焦测试。当前产品代码基线不得通过 reset、clean、旧分支覆盖或
历史副本回填。

## 9. 交付证据

每个 APP 任务至少报告：

- 使用的 APP commit 和 Docs commit；
- 修改的 Flutter 源码和测试文件；
- 手机端与 Desktop 分别完成了什么；
- Mock 与真实接口状态；
- analyze/test/build/启动和截图结果；
- 未验证平台与剩余 Backend 阻塞；
- 结论：一致、部分一致或阻塞。
