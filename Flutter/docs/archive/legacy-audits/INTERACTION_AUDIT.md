# Flutter 交互与路由审计

更新时间：2026-08-31

## 范围与基准

- 范围仅包含 `Flutter/`，重点检查交互、导航、返回栈、覆盖层、异步状态和可访问性；不进行视觉重设计。
- 基准为 Apple HIG、Material 3 interaction states 和 Flutter accessibility guidelines。
- 路由表原有 76 条声明，其中 `digitalTwin` 重复注册。删除重复项后为 75 个唯一路径。
- `页面`表示应通过 `push` 保留来源上下文；`根模式`表示通过 `go` 切换；`重定向`不创建无意义历史栈；`覆盖层`优先关闭自身再返回来源页。
- 下表的“代码审计”表示入口、目标、参数、返回或重定向行为已核对；只有标记“自动化”的项目才有本次新增或既有测试证据。

## 修复结论

| 项目 | 整改结果 | 验证 |
| --- | --- | --- |
| 路由唯一性 | 删除重复的 `/v3/profile/digital-twin` 注册 | 自动化：75 条路径唯一 |
| 全屏转场 | 聊一聊和动态个人页恢复平台页面转场及系统返回手势 | 代码审计、既有返回测试 |
| 旧路径和非法参数 | 继续使用现有安全解析与定向重定向，不扩展旧字符串 API | 自动化：legacy、query、未注册路径 |
| 弹窗叠加 | 来源路由已被覆盖时拒绝再打开共享弹窗；打开前收起键盘 | 自动化：同一时刻一个覆盖层 |
| 小控件命中 | 保留原视觉尺寸，录音卡紧凑操作使用 48dp 透明命中区和单一语义 | 自动化：iOS、Android、label guideline |
| 禁用与忙碌 | 声纹提交和共享按钮使用真实 `null` 回调，不暴露错误点击语义 | 自动化：异步忙碌状态 |
| 录音卡命令隔离 | 设备信息进入详情；连接、断开及录音命令不再穿透到详情页 | 自动化：控制页和管理页命令 |
| 聊天回复操作 | 复制、保存、创作统一字号、字重、图标和 48dp 命中 | 自动化：样式、禁用、语义 |
| 外观模式 | 设置只展示默认亮色和默认暗色；旧暗色保留，其余旧值安全回落亮色 | 自动化：持久化和迁移 |
| 空回调 | 生产代码中已无 `onTap: () {}` / `onPressed: () {}` | 静态扫描 |

## 75 个唯一注册路由

### 启动、鉴权、协议、帮助与首次流程（13）

| 路由 | 入口与目标 | 返回、状态及覆盖层 | 结论 |
| --- | --- | --- | --- |
| `/splash` | 冷启动 -> 启动恢复页 | 根流程；等待恢复后替换目标 | 代码审计 |
| `/restore-failed` | 恢复失败 -> 故障页 | 重试或进入明确兜底 | 代码审计 |
| `/auth` | 未登录/鉴权失效 -> 登录注册 | 登录完成后替换，不保留鉴权页 | 代码审计 |
| `/legal/user-agreement` | 登录页协议入口 -> 用户协议 | 页面返回来源 | 代码审计 |
| `/legal/privacy-policy` | 登录页协议入口 -> 隐私政策 | 页面返回来源 | 代码审计 |
| `/help` | 设置/支持入口 -> 帮助中心 | 页面返回来源；加载/空/错由页面负责 | 代码审计 |
| `/help/article/:articleId` | 帮助条目 -> 文章 | 参数绑定；页面返回帮助中心 | 代码审计 |
| `/help/customer-service` | 帮助入口 -> 客服 | 页面返回帮助中心 | 代码审计 |
| `/workspace-retry` | 工作空间初始化失败 -> 重试页 | 异步防重复由页面负责 | 代码审计 |
| `/onboarding` | 首次使用/一级定位 -> 引导 | 一次性流程完成后替换 | 代码审计 |
| `/v3/positioning/progress` | 定位任务 -> 进度页 | 处理中/失败/成功由任务页负责 | 代码审计 |
| `/v3/onboarding/setup` | 旧深链 -> 设备设置 | 重定向，不增加返回层 | 自动化 |
| `/v3/onboarding/device-setup` | 首次流程 -> 设备设置 | 权限/跳过/完成由页面负责 | 代码审计 |

### 首页与创作空间（22）

| 路由 | 入口与目标 | 返回、状态及手势 | 结论 |
| --- | --- | --- | --- |
| `/v3` | 主入口 -> 首页壳 | 根模式；feed/workbench/masterpiece 由 query 决定 | 自动化 |
| `/v3/workbench` | 旧创作空间入口 -> 首页 workbench 模式 | 重定向，不留空页 | 自动化 |
| `/v3/masterpiece` | 旧作品入口 -> 首页 masterpiece 模式 | 重定向，不留空页 | 自动化 |
| `/v3/workbench/materials/:purpose` | 创作流程 -> 素材选择 | 非法 purpose 回首页创作模式；页面返回来源 | 自动化 |
| `/v3/workbench/generating/:purpose` | 素材确认 -> 生成中 | 非法 purpose 重定向；取消/失败由页面负责 | 自动化 |
| `/v3/workbench/generated/:purpose` | 生成完成 -> 结果页 | 非法 purpose 重定向；返回来源 | 自动化 |
| `/v3/workbench/canvas` | 创作入口/历史/素材 -> 画布 | 参数经安全解析；页面返回来源 | 自动化 |
| `/v3/workbench/recommendations/:recommendationId` | 今日内容 -> 推荐详情 | 参数绑定；进入画布时保留来源 | 代码审计 |
| `/v3/workbench/video-analysis` | 旧视频分析 -> 对应聊一聊技能 | 重定向，不留中间页 | 代码审计 |
| `/v3/workbench/video-analysis/running` | 旧运行状态 -> 对应聊一聊技能 | 重定向，状态由聊天 Run 负责 | 代码审计 |
| `/v3/workbench/video-analysis/result` | 旧结果状态 -> 对应聊一聊技能 | 重定向，结果由聊天会话负责 | 代码审计 |
| `/v3/workbench/deep-positioning` | 创作入口/任务 -> 深度定位 | taskId 安全校验；页面返回来源 | 自动化 |
| `/v3/profile/digital-twin` | 个人页/思想入口 -> 数字分身 | 唯一注册；页面返回来源 | 自动化 |
| `/v3/feed` | 旧 feed 根入口 -> `/v3` | 重定向，不留空页 | 自动化 |
| `/v3/search` | 首页搜索 -> 搜索页 | 页面返回首页；加载/空/错由页面负责 | 代码审计 |
| `/v3/feed/graph` | 首页图谱 -> 全屏交互图谱 | 页面返回首页；拖拽/缩放优先于全局横滑 | 既有手势测试 |
| `/v3/workbench/has-opinion` | 旧有观点入口 -> 画布 | 可选 feedItemId 安全解析后带入 | 自动化 |
| `/v3/workbench/no-opinion` | 旧无观点入口 -> 画布 | 重定向，不留中间页 | 自动化 |
| `/v3/workbench/tasks/:taskId` | 通知/后台任务 -> 任务页 | taskId 绑定；处理中/失败/完成由任务页负责 | 代码审计 |
| `/v3/workbench/create/:mode` | 旧创作深链 -> 画布 | 重定向，不留中间页 | 自动化 |
| `/v3/workbench/result/:mode` | 旧结果深链 -> 画布 | 重定向，不留中间页 | 自动化 |
| `/v3/workbench/history` | 画布 -> 创作历史 | 页面返回画布/来源 | 代码审计 |

### 通知、资产、采集、笔记与聊天（25）

| 路由 | 入口与目标 | 返回、状态、覆盖层及权限 | 结论 |
| --- | --- | --- | --- |
| `/v3/notifications` | 顶部通知 -> 通知覆盖页 | 半透明覆盖层；遮罩/返回先关闭；统一 motion token | 代码审计 |
| `/v3/assets` | 首页/个人页 -> 资产页 | query 决定分区；页面返回来源 | 自动化 |
| `/v3/assets/media/:resourceId` | 媒体资产 -> 预览 | 非法 id 回媒体列表；页面返回来源 | 自动化 |
| `/v3/assets/content-line/:contentLineId` | 内容线资产 -> 详情编辑 | 参数绑定；保存/错误由页面负责 | 代码审计 |
| `/v3/feed/record-source` | 加号 -> 采集来源 | 页面返回首页；权限状态由目标页负责 | 代码审计 |
| `/v3/feed/meeting` | 采集来源 -> 会议录音 | 麦克风权限、录音、取消、成功由页面负责 | 代码审计 |
| `/v3/feed/internal-recording` | 采集来源 -> 内部录音 | 麦克风权限、录音、取消、成功由页面负责 | 代码审计 |
| `/v3/feed/link-import` | 采集来源 -> 链接导入 | 输入/加载/失败/成功由页面负责 | 代码审计 |
| `/v3/feed/import` | 旧导入入口 -> 文档导入 | 重定向，不留中间页 | 自动化 |
| `/v3/feed/import/documents` | 加号 -> 文档导入 | 文件权限、处理中、失败、成功由页面负责 | 代码审计 |
| `/v3/feed/import/local-recordings` | 旧本地录音入口 -> 文档导入 | 重定向，不留中间页 | 自动化 |
| `/v3/feed/import/media` | 加号 -> 媒体导入 | 媒体权限、处理中、失败、成功由页面负责 | 代码审计 |
| `/v3/feed/note` | 加号/草稿 -> 新笔记 | 编辑、保存、取消由页面负责 | 代码审计 |
| `/v3/feed/note/:itemId` | 笔记详情 -> 编辑笔记 | itemId 绑定；加载中先于空态 | 既有状态测试 |
| `/v3/feed/upload` | 旧上传入口 -> 文档导入 | 重定向，不留中间页 | 自动化 |
| `/v3/feed/upload/parsing` | 旧解析入口 -> 文档导入 | 重定向，不伪造独立进度页 | 自动化 |
| `/v3/feed/monologue` | 采集入口 -> 独白 | 录音权限、转写、取消由页面负责 | 代码审计 |
| `/v3/feed/monologue/history` | 独白 -> 历史 | 页面返回独白 | 代码审计 |
| `/v3/feed/aggregation-agent/:sessionId` | 聚合任务 -> 对话页 | sessionId 绑定；流式/工具/失败由页面负责 | 代码审计 |
| `/v3/feed/chat` | 聊一聊及业务技能 -> 会话 | 平台页面转场；安全解析 thread/window/context；返回真实来源 | 自动化 |
| `/v3/feed/transcription-preview` | 转写完成入口 -> 预览 | 页面返回采集来源 | 代码审计 |
| `/v3/feed/assets/:assetId` | 旧资产详情 -> 内容详情 | 参数绑定；页面返回来源 | 代码审计 |
| `/v3/feed/items/:itemId/append/:source` | 笔记详情 -> 追加内容 | 非法 source 回详情；有效时返回详情 | 自动化 |
| `/v3/feed/items/:itemId` | 首页/搜索 -> 内容详情 | stage/section 安全归一化；页面返回来源 | 自动化 |
| `/v3/feed/transcription-done/:recordingId` | 录音任务 -> 转写详情 | 来源类型归一化；加载/错/成功由页面负责 | 代码审计 |

### 个人、知识、声纹与录音卡（15）

| 路由 | 入口与目标 | 返回、状态、覆盖层及权限 | 结论 |
| --- | --- | --- | --- |
| `/v3/profile` | 侧栏/个人入口 -> 个人主页 | 页面返回来源 | 代码审计 |
| `/v3/profile/calendar` | 个人页 -> 活动日历 | 日期安全解析；页面返回个人页 | 自动化 |
| `/v3/profile/knowledge` | 个人页 -> 知识库 | mine/deposit 旧 tab 定向资产页；其余保留页面 | 自动化 |
| `/v3/profile/knowledge/channel/:channelId` | 知识库 -> 频道 | 非法频道回知识广场；页面返回知识库 | 自动化 |
| `/v3/profile/knowledge/world` | 知识库 -> 远端世界详情 | publicationId/query 安全解析；加载/错/空由页面负责 | 自动化 |
| `/v3/profile/deposits` | 旧沉淀入口 -> 个人资产沉淀页 | 重定向，不留中间页 | 自动化 |
| `/v3/profile/assets` | 个人页 -> 我的资产 | query 决定分区；页面返回个人页 | 自动化 |
| `/v3/profile/account` | 设置 -> 账号资料 | 页面返回设置；提交状态由页面负责 | 代码审计 |
| `/v3/profile/voiceprint` | 设置/录音卡 -> 声纹管理 | 麦克风权限、忙碌、失败、成功互斥 | 自动化 |
| `/v3/profile/voiceprint/enroll` | 声纹管理 -> 录入 | 参数绑定；忙碌按钮真实禁用；完成返回管理页 | 自动化 |
| `/v3/profile/academy` | 个人页 -> 学院占位页 | 页面返回个人页 | 代码审计 |
| `/v3/profile/:section` | 设置动态分区 -> 对应页 | 平台页面转场；系统返回真实来源 | 自动化 |
| `/v3/recording-card/control` | 首页组件 -> 录音卡控制 | widgetAction 归一化；命令防穿透和重复触发 | 自动化 |
| `/v3/recording-card/details` | 录音卡设备信息 -> 详情 | focus 参数归一化；页面返回控制/管理页 | 自动化 |
| `/v3/recording-card` | 个人页/录音卡入口 -> 设备与文件管理 | tab/focus 归一化；连接状态互斥；覆盖层先关闭 | 自动化 |

合计：13 + 22 + 25 + 15 = 75 个唯一注册路径。

## 共享交互契约

1. 可见紧凑控件不强行放大，通过透明命中区满足 iOS 44pt 和 Android 48dp；语义树只暴露一个有标签的操作。
2. 异步按钮在忙碌时使用 `null` 回调，控制器负责防重复提交，异步返回后在读取 `context` 前检查 mounted。
3. 覆盖层打开前收起键盘；已被覆盖的来源路由不能继续堆叠共享弹窗；关闭后由 Flutter 恢复来源焦点。
4. 全屏页面使用平台页面转场；通知保持覆盖层语义；旧入口只重定向，不制造返回栈中间页。
5. 首页横滑、图谱拖拽、编辑器文本选择及横向列表保持现有入口，组件自身手势优先，全局手势继续使用既有方向和阈值测试。
6. 外观设置只公开默认亮色和默认暗色，历史偏好迁移不导致启动失败。

## 验证记录

- 通过：路由唯一性与旧路径解析测试。
- 通过：外观 controller/repository/widget 测试。
- 通过：弹层防叠加、触控范围和可访问性标签测试。
- 通过：聊天回复操作、声纹忙碌状态、录音卡控制页及管理页关键交互测试。
- 通过：`flutter analyze --no-fatal-infos`，无 warning/error；保留 349 条既有 info lint。
- 通过：`dart run tool/scm_check.dart`，1198 个活动文件映射完整。
- 全量测试共 2422 项：2389 项通过；其余 33 项均为本次未改页面的既有 Golden 渲染偏差。录音卡、资料世界、作品、资产弹层、图谱、笔记聊天和账号邮箱等差异可在未修改提交与当前 SDK 下复现，因此未借本次交互整改更新无关产品截图。
- 通过：现有 iPhone 17 Pro（iOS 26.5，`DC53F410-8577-4601-BC10-70A7BB931E04`）完成 Debug 构建、安装、启动和首屏截图检查。
- Android `medium_phone` 设备仿真按 2026-08-31 最新要求暂缓；未创建新模拟器，自动化中的 Android 触控规范仍通过。
