# 思想图谱 1D / 3D 导航记忆修复

## 根因

- Feed 页面用局部 `_showNotes` 保存显示维度；路由重建后重新使用首页默认 1D。
- 节点选择则由独立的 `FeedGraphController` 持有，可能由其他页面继续保留。
- 底部 `V3GraphNodeActionCard` 原先只检查 Feed 和选中笔记，没有检查当前是否为 3D，因此产生“1D 列表 + 3D 资产卡片”的混合界面。
- Home 外壳还维护一份 `_feedNotesVisible`，由页面回调更新，存在显示维度与手势维度不同步的风险。

## 修改范围

- 新增轻量 `FeedViewModeController`，在当前账号/工作区会话内记忆维度，不依赖页面或重型图谱控制器的存活。首次使用入口默认值，之后仅显式维度选择更新；切换账号/工作区重置。
- Feed 和 Home 手势共用此状态。通知跳转、push/pop、replace、兜底 go 首页、完整页面重建，不再把 3D 覆盖成 1D。
- 节点卡片仅允许在 3D 渲染；明确切换到 1D 时清除图谱选择。即使其他页面随后留下选择，1D 仍不显示卡片。
- 为保持 1D 搜索可用，其搜索结果直接进入详情；3D 搜索继续选中节点并展示卡片。
- 没有改变图谱物理交互、动画预算、后端接口、定位报告、代表作、纲要或消息业务状态机。模式记忆是会话级，不新增跨 App 重启的磁盘配置。

## 定向验证

7 项通过：

1. 首次维度只初始化一次，同一 scope 不被后续默认值覆盖；换工作区重置。
2. 1D 经通知入口、replace 资产详情、返回，以及销毁首页后兜底返回，仍为 1D。
3. 3D 经相同路径仍为 3D；返回后画布拖动仍由图谱接管，不误触主页切页。
4. 1D 遇到残留节点选择时不显示卡片；显式切换清除选择；图谱控制器重建不改变维度。
5. 1D 搜索结果可进入笔记详情，返回仍为 1D 且无节点卡片。
6. 现有底部分页仅在思想图谱显示图谱的回归。
7. 现有 1D 内容区横向导航回归。

4 个相关 Dart 文件静态分析无问题，diff 无空白错误。测试使用真实 Home/Feed/图谱控制器、生产首页路由和隔离笔记；详情/通知目标为路由测试占位页，没有调用后端或付费生成。本轮未读取真机日志或安装 Simulator，用户截图仅作为故障现象依据。

## 旧测试基线

扩展 Home/gesture 检查共 19 项：13 通过、6 失败。临时用修改前的两份页面源码重跑原有 14 项：8 通过、同样 6 失败；对照后已恢复全部修复代码。没有修改这些不在本次范围内的旧测试或功能：

- `Figma 3081:1877 exposes the canonical 1D Home controls`：测试没有 GoRouter，且仍期待旧的聚合面板。
- `profile remains reachable after a child goes to retained home`：个人面板关闭断言失败。
- `M11 direct workbench shell matches the Mobile V5 fixture`：旧 golden 图像不一致，伴随录音卡插件缺失。
- `M01 create entry matches the two-option Mobile V5 sheet`：测试环境录音卡插件缺失。
- `V5 home shell limits the graph to AI feed mode`：仍期待已不存在的边缘手势控件。
- `M03 header actions retain notifications and Feed without workspace search`：返回思想图谱标题断言失败。

核验日志保留在 `/tmp/huahuo-feed-mode-focused.log`、`/tmp/huahuo-feed-mode-tests.log`、`/tmp/huahuo-feed-mode-baseline.log`、`/tmp/huahuo-feed-mode-analyze.log`。
