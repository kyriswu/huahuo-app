# 无限花火 Flutter 移动端导航与程序架构优化执行方案

## 1. 文档目的

本方案针对 `Xieyangzai/Flutter-mobile` 仓库 `Flutter-Desk-Mobile` 分支当前移动端工程进行程序结构优化。

本次优化的核心目标不是增加新功能，也不是重新设计现有页面，而是在**不影响现有功能、业务流程和视觉交互的前提下**，解决当前页面切换、返回逻辑、路由状态、重复代码和导航架构中的潜在问题，降低后续开发和维护成本。

本方案重点包括：

- 统一页面跳转和返回规则；
- 删除重复、无效、历史遗留的导航逻辑；
- 避免 `GoRouter`、`PageView`、原生 `Navigator` 多套状态相互冲突；
- 优化页面之间的返回链路；
- 避免编辑、录音、导入等场景误返回造成数据或上下文丢失；
- 减少 `app_router.dart` 等超大文件的职责；
- 提高路由结构可维护性；
- 增加必要的导航测试，避免后续修改产生回归；
- 保持现有页面、功能、接口和数据结构基本不变。

---

# 2. 优化原则

本次修改必须严格遵循以下原则。

## 2.1 不改变现有业务功能

不得因为优化路由结构而删除现有业务能力，例如：

- 思想图谱；
- 创作空间；
- 代表作；
- 聊一聊；
- 独白；
- 外录；
- 内录；
- 文件导入；
- 链接导入；
- 笔记创建；
- 笔记编辑；
- 创作画布；
- 个人中心；
- 资产管理；
- 推送通知；
- 深度定位；
- 录音卡；
- 会员相关功能。

所有现有功能应继续保持可访问。

---

## 2.2 优先删除重复逻辑，而不是增加更多判断

当前部分导航问题的根源不是“判断不够多”，而是同一件事情存在多套实现。

优化时优先：

- 合并重复 Route；
- 删除重复 Redirect；
- 删除失效的 Legacy Route；
- 统一公共返回方法；
- 统一页面退出保护；
- 统一页面完成后的返回行为。

避免继续在不同页面增加大量 `if / else` 修补。

---

## 2.3 路由只负责页面关系，业务状态由 Controller 管理

路由不应承担：

- 编辑器状态；
- 当前录音状态；
- 图谱状态；
- 当前创作模式的业务数据；
- AI 任务状态。

Router 仅负责：

- 当前处于哪个页面；
- 页面从哪里进入；
- 返回哪里；
- Deep Link 如何恢复；
- 登录后应该继续前往哪里。

业务数据继续由 Riverpod Controller 管理。

---

## 2.4 不做大规模重写

本次不建议：

- 更换 Riverpod；
- 更换 GoRouter；
- 重写所有页面；
- 重写整个 V3 UI；
- 重构数据库；
- 修改现有 API；
- 修改现有业务模型。

原则是：

> 在现有 Flutter + Riverpod + GoRouter 架构上进行渐进式优化。

---

# 3. 当前主要问题概览

当前导航体系存在以下几类问题。

| 优先级 | 问题 | 风险 |
|---|---|---|
| P0 | 首页存在 Router 与 PageView 双状态源 | 页面状态和路由状态不一致 |
| P0 | 推送、外部导入直接使用 `go()` | 当前页面栈被替换 |
| P0 | 创作画布 PopScope 退出流程不完整 | 放弃后可能无法正确返回 |
| P0 | 录音页面缺少统一离开保护 | 误返回可能中断录音 |
| P1 | 保存后大量使用 `go()` | 丢失来源页面 |
| P1 | 登录后不恢复原目标页面 | Deep Link / 推送目标丢失 |
| P1 | Legacy Redirect 存在重复和冲突 | 跳转结果不稳定 |
| P1 | 删除后固定返回思想图谱 | 用户上下文丢失 |
| P2 | GoRouter 与 MaterialPageRoute 混用 | 页面栈难统一管理 |
| P2 | Router 文件职责过重 | 后续容易产生冲突 |
| P2 | 导航测试不足 | 返回逻辑容易回归 |

---

# 4. 第一阶段：统一导航规则

这是本次优化最重要的一部分。

建议整个移动端统一以下导航规范。

---

## 4.1 `push` 的使用场景

适用于：

> 当前页面进入一个子页面，并且用户预期可以返回原页面。

例如：

```text
思想图谱
    ↓
笔记详情
```

```text
我的资产
    ↓
笔记详情
```

```text
创作空间
    ↓
创作画布
```

```text
笔记详情
    ↓
聊一聊
```

统一使用：

```dart
context.push(...)
```

---

## 4.2 `pop` 的使用场景

适用于：

> 当前任务完成后回到来源页面。

例如：

- 编辑完成；
- 删除完成；
- 选择完成；
- 设置完成；
- 保存完成。

优先使用：

```dart
context.pop(result);
```

而不是：

```dart
context.go(...)
```

这样可以保留原页面状态。

---

## 4.3 `pushReplacement` 的使用场景

适用于：

> 当前页面任务已经完成，后续不需要再返回当前页面。

典型场景：

```text
新建笔记
    ↓ 保存
笔记详情
```

保存完成后：

```dart
context.pushReplacement(detailRoute);
```

这样返回时：

```text
笔记详情
    ↓
思想图谱 / 我的资产 / 创作空间
```

不会重新回到“新建笔记”页面。

---

## 4.4 `go` 的使用场景

`go()` 应减少使用。

只建议用于：

### 应用根状态切换

例如：

```text
未登录
→ 登录页
```

```text
登录成功且没有待恢复目标
→ /v3
```

### 冷启动 Deep Link

例如：

```text
App 未启动
→ 点击通知
→ 直接进入目标详情
```

### 无返回意义的顶层状态切换

例如：

```text
账号退出
→ /auth
```

普通业务页面之间禁止随意 `go()`。

---

# 5. 第二阶段：首页导航结构优化

当前：

```text
/v3
/v3/workbench
/v3/masterpiece
```

三个 Route 最终都构建：

```text
V3AppShell
```

而 `V3AppShell` 自己又使用：

```text
PageView
+
V3HomeMode
```

管理：

```text
feed
workbench
masterpiece
```

这相当于同一个状态被维护两次。

---

## 5.1 推荐调整方案

保留唯一首页 Route：

```text
/v3
```

三个首页模式改成内部状态：

```dart
enum V3HomeMode {
  feed,
  workbench,
  masterpiece,
}
```

现有 `V3AppShell` 基本可以继续保留。

---

## 5.2 外部直接打开某个模式

如果未来需要：

```text
直接进入创作空间
```

可以使用：

```text
/v3?mode=workbench
```

或者：

```text
/v3?mode=masterpiece
```

Router 只用于读取初始化模式。

之后用户左右切换仍然由 `V3AppShell` 管理。

---

## 5.3 删除重复 Route

完成适配后删除：

```text
/v3/workbench
/v3/masterpiece
```

或者暂时保留为兼容 Redirect：

```text
/v3/workbench
    ↓
/v3?mode=workbench
```

```text
/v3/masterpiece
    ↓
/v3?mode=masterpiece
```

兼容一个版本后再彻底删除。

---

## 5.4 预期效果

优化前：

```text
URL：/v3

实际页面：
创作空间
```

可能不同步。

优化后：

```text
Router：
只知道当前处于 Home

V3AppShell：
只负责 Home 内部模式
```

状态职责更加清晰。

---

# 6. 第三阶段：修复编辑页面返回问题

---

## 6.1 创作画布 PopScope 修复

当前 Canvas 已经存在：

```dart
PopScope
```

这是正确的。

但确认放弃以后，应保证：

```text
修改 _allowLeave
    ↓
Widget rebuild
    ↓
PopScope.canPop = true
    ↓
再 pop
```

建议统一写法：

```dart
setState(() {
  _allowLeave = true;
});

await WidgetsBinding.instance.endOfFrame;

if (!mounted) return;

if (context.canPop()) {
  context.pop();
} else {
  context.go('/v3?mode=workbench');
}
```

---

## 6.2 与 NotePage 的实现统一

`V3NotePage` 已经存在较合理实现。

建议抽出统一辅助逻辑，例如：

```text
SafeLeaveController
```

或者：

```text
UnsavedChangesGuard
```

统一处理：

- 是否有未保存内容；
- 是否正在保存；
- 是否允许离开；
- 是否已经打开确认弹窗；
- 返回后执行 pop / fallback。

---

## 6.3 删除重复实现

后续以下页面如果都有类似判断：

```text
_isDirty
_allowLeave
_confirmDiscard
context.canPop
fallbackRoute
```

应逐步统一。

不建议每个编辑页面继续复制一套。

---

# 7. 第四阶段：录音与采集页面统一退出保护

需要重点处理：

```text
V3MonologuePage
V3MeetingCapturePage
V3InternalRecordingPage
V3NoteAppendPage
```

以及后续所有：

```text
录音
录屏
蓝牙采集
上传
实时转写
```

页面。

---

## 7.1 新增统一 CaptureLeaveGuard

建议增加：

```text
shared/navigation/capture_leave_guard.dart
```

主要状态：

```dart
enum CaptureLeaveState {
  idle,
  capturing,
  processing,
}
```

---

## 7.2 idle 状态

直接允许：

```text
Back
→ pop
```

---

## 7.3 capturing 状态

禁止直接销毁页面。

显示确认：

```text
正在录制

离开当前页面将结束本次录制。

[继续录制]
[结束并离开]
```

避免当前：

```text
返回
→ dispose
→ 自动 cancelRecording()
```

这种用户无感知行为。

---

## 7.4 processing 状态

如果当前 Controller 已支持后台继续：

```text
允许返回
任务继续
```

例如：

```text
正在上传
正在转写
正在分析
```

页面退出后不要取消任务。

如果某个业务当前无法后台运行，再单独提示。

---

# 8. 第五阶段：修复保存后的返回上下文

目前部分页面保存后：

```dart
context.go('/v3/feed/items/xxx');
```

会清空前面业务导航上下文。

应按来源分两种情况。

---

## 8.1 编辑已有笔记

推荐：

```text
详情
  ↓ push
编辑
  ↓ 保存
pop(saved)
```

详情页监听返回值。

例如：

```dart
final changed = await context.push<bool>(...);

if (changed == true) {
  refresh();
}
```

---

## 8.2 创建新笔记

推荐：

```text
来源页
  ↓
新建笔记
  ↓
保存
  ↓
replace 成详情
```

使用：

```dart
context.pushReplacement(detailRoute);
```

---

## 8.3 Canvas 保存

Canvas 的保存后去向应保留现有业务体验。

如果当前是：

```text
创作空间
→ Canvas
→ 保存
→ 详情
```

建议：

```text
创作空间
→ Canvas
→ replace
→ 详情
```

这样：

```text
详情
→ Back
→ 创作空间
```

---

# 9. 第六阶段：删除 Legacy Route 冗余逻辑

当前存在：

```text
_legacyMainRedirectRoutes
```

以及：

```text
v3LocationForLegacyMainUri()
```

两套 Legacy 转换逻辑。

这是不必要的重复。

---

## 9.1 合并 Legacy Redirect

建议只保留：

```text
v3LocationForLegacyMainUri()
```

作为唯一 Legacy 转换表。

Router 顶层：

```dart
final legacyDestination =
    v3LocationForLegacyMainUri(state.uri);

if (legacyDestination != null) {
  return legacyDestination;
}
```

---

## 9.2 删除重复 Route

完成后删除大量：

```dart
GoRoute(
  path: '/main/...',
  redirect: ...
)
```

避免一个旧地址存在两个 Redirect 来源。

---

## 9.3 修复 diagnostics

当前：

```text
/main/settings/diagnostics
```

应该明确映射：

```text
/v3/profile/诊断
```

不得再返回 null 交给其他 Guard 处理。

---

## 9.4 Legacy Route 最终生命周期

建议：

### 当前版本

继续支持。

### 后续版本

打印调试日志：

```text
Legacy route used
```

### 稳定一段时间后

删除已经确定没有外部使用的旧 Route。

---

# 10. 第七阶段：增加 Pending Navigation

当前未登录用户打开 Deep Link：

```text
/v3/feed/items/123
```

会被跳转：

```text
/auth
```

登录以后通常进入：

```text
/v3
```

原目标丢失。

---

## 10.1 新增 PendingNavigationController

建议：

```text
core/navigation/pending_navigation_controller.dart
```

保存：

```dart
class PendingNavigation {
  final String location;
  final PendingNavigationReason reason;
  final DateTime createdAt;
}
```

---

## 10.2 支持来源

例如：

```text
pushNotification
deepLink
externalShare
authentication
```

---

## 10.3 登录成功流程

改为：

```text
登录成功
    ↓
Workspace ready
    ↓
检查 onboarding
    ↓
检查 pending destination
```

如果有：

```text
打开原目标
```

如果没有：

```text
进入 /v3
```

---

# 11. 第八阶段：优化推送导航

---

## 11.1 前台通知

当前 App 已打开时：

```text
不要 router.go()
```

改为：

```dart
router.push(destination);
```

效果：

```text
原页面
  ↓
通知详情
  ↓ Back
原页面
```

---

## 11.2 冷启动通知

App 未运行：

```text
允许 go(destination)
```

因为本身没有需要保留的栈。

---

## 11.3 推送与未保存编辑冲突

如果当前页面处于：

```text
编辑中
录音中
重要处理中
```

不建议自动切换。

通知点击应进入统一导航协调器，由当前页面决定：

```text
允许导航
或
弹出保存/退出确认
```

---

# 12. 第九阶段：外部文件分享导航优化

外部文件进入 App 时也应区分：

```text
Cold Start
Foreground
```

---

## 12.1 Cold Start

```text
go('/v3/feed/import/documents')
```

可以保留。

---

## 12.2 Foreground

改为：

```dart
push('/v3/feed/import/documents')
```

这样导入结束后：

```text
Back
→ 返回原页面
```

而不是永远回思想图谱。

---

# 13. 第十阶段：删除完整业务页面中的 MaterialPageRoute

Dialog、BottomSheet 继续使用：

```text
Navigator
```

没有问题。

但完整业务页面尽量统一使用 GoRouter。

当前类似：

```dart
Navigator.of(context).push(
  MaterialPageRoute(...)
)
```

打开完整 Agent Chat 页面。

建议改为正式 Route：

```text
/v3/feed/aggregation-agent/:sessionId
```

或者直接复用现有 Chat：

```text
/v3/feed/chat
```

通过参数传入上下文。

---

# 14. 第十一阶段：优化详情页删除后的返回行为

当前删除笔记后固定：

```text
go('/v3/feed')
```

应改为：

```text
优先 pop
```

例如：

```dart
if (context.canPop()) {
  context.pop(DeleteResult(item.id));
} else {
  context.go('/v3');
}
```

这样：

```text
我的资产
→ 笔记详情
→ 删除
→ 我的资产
```

而不是：

```text
→ 思想图谱
```

---

# 15. 第十二阶段：统一 fallbackRoute

当前页面经常直接写：

```text
/v3/feed
/v3/workbench
/v3/masterpiece
```

如果首页三模式改为统一 `/v3`，建议封装 Route 常量。

例如：

```text
AppRoutes.home
AppRoutes.feed
AppRoutes.workbench
AppRoutes.masterpiece
AppRoutes.chat
```

---

## 15.1 禁止大量硬编码路径

当前大量代码直接：

```dart
context.push('/v3/feed/...');
```

建议逐步改为：

```dart
AppRoutePaths.feedItem(id)
```

或者：

```dart
AppRouteLocation.feedItem(id)
```

这样以后修改路径时不需要全项目搜索字符串。

---

# 16. 第十三阶段：拆分 app_router.dart

当前 `app_router.dart` 已经承担：

- Router 创建；
- Route 声明；
- Legacy Redirect；
- 参数解析；
- Splash；
- RestoreFailed；
- WorkspaceStatus；
- Route 辅助函数。

职责明显过多。

建议拆分为：

```text
app/navigation/
├── app_router.dart
├── app_routes.dart
├── app_route_paths.dart
├── route_guards.dart
├── legacy_route_redirect.dart
├── route_parameter_parser.dart
└── navigation_observer.dart
```

---

## 16.1 app_router.dart

只负责：

```text
GoRouter(...)
```

以及 Route 组合。

---

## 16.2 app_routes.dart

负责：

```text
V3 页面声明
```

---

## 16.3 route_guards.dart

继续负责：

```text
Auth
Bootstrap
Workspace
Onboarding
```

---

## 16.4 legacy_route_redirect.dart

集中处理：

```text
/main/...
```

旧 Route。

---

## 16.5 route_parameter_parser.dart

处理：

```text
safe ID
日期
purpose
mode
query
```

---

# 17. 第十四阶段：减少 app_providers.dart 的体积

当前 `app_providers.dart` 已经非常大。

虽然本次主要检查导航，但从架构优化角度建议逐步拆分。

例如：

```text
app/bootstrap/providers/
├── auth_providers.dart
├── database_providers.dart
├── notification_providers.dart
├── billing_providers.dart
├── recording_providers.dart
├── ui_v3_providers.dart
└── ingestion_providers.dart
```

最后：

```text
app_providers.dart
```

只做 export / composition。

---

# 18. 第十五阶段：删除无效兼容代码

当前部分代码存在明显的历史兼容痕迹，例如：

```text
@Deprecated initialIndex
```

以及：

```text
V3WorkbenchPage
```

和：

```text
V3WorkbenchHomeSurface
```

同时存在。

这些代码不建议立即全部删除。

应先确认调用关系。

---

## 18.1 删除原则

只有满足：

```text
没有生产代码引用
没有测试依赖
没有 Deep Link 使用
没有旧版本恢复依赖
```

时再删除。

---

## 18.2 推荐流程

先：

```text
标记 deprecated
```

再：

```text
迁移调用
```

然后：

```text
运行测试
```

最后：

```text
删除
```

禁止一次性清理导致功能缺失。

---

# 19. 第十六阶段：完善导航测试

建议新增：

```text
Flutter/src/integration_test/navigation_flow_test.dart
```

---

## 19.1 首页测试

```text
思想图谱
→ 创作空间
→ 代表作
→ 思想图谱
```

确认：

```text
页面正常
状态正常
无异常 Route
```

---

## 19.2 Feed Detail

```text
思想图谱
→ 笔记
→ Back
→ 思想图谱
```

---

## 19.3 Assets Detail

```text
我的资产
→ 笔记
→ Back
→ 我的资产
```

---

## 19.4 Edit Save

```text
我的资产
→ 详情
→ 编辑
→ 修改
→ 保存
→ 详情
→ Back
→ 我的资产
```

---

## 19.5 Edit Discard

```text
编辑
→ 修改
→ Back
→ 弹确认
→ 继续编辑
```

以及：

```text
编辑
→ 修改
→ Back
→ 放弃
→ 正常退出
```

---

## 19.6 Canvas

```text
创作空间
→ Canvas
→ 修改
→ Back
→ 确认
```

---

## 19.7 Recording

```text
开始录音
→ Back
```

必须：

```text
出现确认
```

而不是静默退出。

---

## 19.8 Notification

```text
详情页面
→ 打开通知目标
→ Back
→ 原详情
```

---

## 19.9 External Share

```text
编辑页面
→ 外部文件进入
```

确认：

```text
不会静默丢失编辑内容
```

---

## 19.10 Auth Deep Link

```text
未登录
→ 打开 /v3/feed/items/123
→ 登录
→ 恢复 /v3/feed/items/123
```

---

# 20. 推荐最终目录结构

优化后建议：

```text
Flutter/src/lib/

app/
├── bootstrap/
├── di/
└── navigation/
    ├── app_router.dart
    ├── app_routes.dart
    ├── app_route_paths.dart
    ├── route_guards.dart
    ├── legacy_route_redirect.dart
    ├── pending_navigation_controller.dart
    └── navigation_observer.dart

shared/
├── navigation/
│   ├── capture_leave_guard.dart
│   ├── unsaved_changes_guard.dart
│   └── safe_navigation.dart
├── theme/
└── ui_v3/

features/
├── ui_v3/
├── notifications/
├── recordings/
├── ingestion/
├── billing/
└── ...
```

---

# 21. 不建议本次修改的内容

为了控制风险，本次不建议顺带修改：

- 数据库结构；
- 网络协议；
- API 接口；
- Riverpod 整体架构；
- AI 功能；
- 图谱算法；
- 支付逻辑；
- 推送 SDK；
- 录音底层 Native Plugin；
- UI 视觉风格；
- 页面布局。

这些属于其他专项。

本次应集中处理：

```text
导航
返回
页面生命周期
路由结构
无用代码
重复逻辑
测试
```

---

# 22. 推荐实施顺序

## 第一批：低风险、高收益

优先修改：

1. Canvas PopScope；
2. Legacy diagnostics Redirect；
3. 详情删除返回；
4. 保存流程中的 `go()`；
5. 推送 Foreground 使用 `push()`；
6. 外部导入 Foreground 使用 `push()`。

这些修改对 UI 几乎没有影响。

---

## 第二批：导航架构统一

处理：

1. Home 双状态源；
2. `/v3/workbench`；
3. `/v3/masterpiece`；
4. Route 常量；
5. Legacy Redirect 合并。

---

## 第三批：页面生命周期

处理：

1. 独白；
2. 外录；
3. 内录；
4. 追加录音；
5. 上传；
6. 分析。

增加统一 Leave Guard。

---

## 第四批：代码结构

拆分：

```text
app_router.dart
app_providers.dart
```

删除无用兼容代码。

---

## 第五批：测试

补齐：

```text
navigation_flow_test
```

以及关键 widget test。

---

# 23. 验收标准

完成本次优化以后，应满足以下要求。

---

## 页面返回

所有普通页面：

```text
从哪里进入
返回哪里
```

---

## 编辑保护

有未保存内容时：

```text
不得直接离开
```

---

## 录音保护

录音过程中：

```text
不得静默退出
```

---

## 推送

前台通知：

```text
不会破坏当前导航栈
```

---

## Deep Link

未登录 Deep Link：

```text
登录以后恢复目标
```

---

## Home

思想图谱 / 创作空间 / 代表作：

```text
只有一套状态源
```

---

## Legacy

旧链接：

```text
只能经过一套 Redirect
```

---

## Router

完整业务页面：

```text
统一走 GoRouter
```

---

## 无功能损失

优化前能够打开的正式功能：

```text
优化后仍然可打开
```

---

# 24. 总结

当前工程并不需要推翻现有导航体系。

现有基础已经具备：

```text
Flutter
Riverpod
GoRouter
V3AppShell
PopScope
统一 V3PageScaffold
```

因此最合理的方案是：

> 保留现有技术栈，对路由职责、页面状态、返回策略和页面生命周期进行统一。

本次优化完成后，主要收益包括：

- 页面返回更加自然；
- 不容易返回错误页面；
- 编辑内容不容易丢失；
- 录音过程中不容易误退出；
- 推送不会破坏当前操作；
- Deep Link 可以正确恢复；
- Router 文件职责更加清晰；
- 重复 Legacy 代码减少；
- 后续增加页面更加简单；
- 导航 Bug 更容易通过自动测试发现；
- 在不改变现有功能的情况下，提高整个移动端工程的稳定性和可维护性。

最终建议将本次改造定位为：

> **“导航与页面生命周期专项架构优化”**

而不是功能重构。

这样风险最低，也最符合当前无限花火进入持续完善阶段的需要。
