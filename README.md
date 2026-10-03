# 花火 AI workspace

当前产品代码只在 `Flutter/` 下维护：

- `Flutter/src/`：Android/iOS 手机端
- `Flutter/desktop/`：Windows/macOS Desktop
- `Flutter/packages/`：手机端和 Desktop 共用的包
- `Flutter/docs/`：架构、约束、运行手册和历史归档
- `Flutter/plans/`：跨模块工作的 Plan/ExecPlan
- `Flutter/reports/`：测试和联调证据
- `Flutter/tool/`：项目级工具；端到端脚本放在对应应用的 `tool/` 或 `integration_test/`

根目录按用途分区：

- `Flutter/`：产品工程及其文档、验证工具。
- [`tools/smoke/`](tools/smoke/README.md)：跨项目接口测试脚本。
- `design/`：独立设计素材；`brand/` 保存 Logo 源文件，`icons/` 保存参考图标。
- [`archive/`](archive/README.md)：历史方案、交接资料、源码快照、诊断证据和录音。

脚本、素材和历史文档不再直接放在根目录。这些辅助目录不参与 Flutter 构建。
修改产品行为时只从 `Flutter/src`、
`Flutter/desktop`、`Flutter/packages`、测试和正式协议开始；需要保留新的证据时，
放入 `Flutter/reports/`，长期规则放入 `Flutter/docs/architecture`、
`Flutter/docs/invariants`、`Flutter/docs/adr` 或 `Flutter/docs/runbooks`。

项目内的 `.dart_tool/`、`build/`、FVM 和 Graphify 输出均可再生，不应提交。
