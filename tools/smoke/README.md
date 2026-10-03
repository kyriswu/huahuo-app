# 接口测试脚本

这里集中保存原根目录及 `测试脚本/` 中的 PowerShell、Python 和 Shell 脚本。
本次仅整理位置，脚本内容保持不变。Flutter 自身的验证入口继续位于
`Flutter/src/tool/` 和 `Flutter/src/integration_test/`。

这些脚本包含创建测试数据、调用真实 API 及远程操作；本次整理只做离线校验，
未执行接口测试。使用时遵守根目录 `AGENTS.md` 的服务器只读约束。
脚本原有的环境参数、外部仓库路径和运行目录要求仍然适用。

部分 PowerShell 脚本从同目录加载 `minutes_api_common.ps1`，该文件在整理前就缺失。
另有脚本通过 `BackendSourceRoot` 指向外部后端仓库。迁移没有补齐或替换这些依赖，
不能据此认为所有脚本可独立运行。以 `$PSScriptRoot` 为基准的输出会写到新位置，
本目录的忽略规则覆盖已有脚本的常见输出。

历史使用说明在 `archive/docs/`。API 目录元数据中保留的
`测试脚本/run-streaming-sn-workspace-smoke.ps1` 是原始证据路径，
对应脚本现位于本目录。
