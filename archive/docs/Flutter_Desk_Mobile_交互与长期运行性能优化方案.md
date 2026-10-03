# Flutter-Desk-Mobile 交互与长期运行性能优化方案

> 仓库：`Xieyangzai/Flutter-mobile`  
> 分支：`Flutter-Desk-Mobile`  
> 审计基线：`a35aed9cb88bd12298391c621e2dc7b1963c08d9`（提交信息：`多平台同步`）  
> 审计目标：解决“动作卡手”“输入不跟手”“运行时间越长越卡”“图谱持续占用”“大文档预览/保存偶发停顿”等问题，同时**不改变现有业务功能、数据语义、同步协议、自动保存、离线恢复、图谱交互与视觉功能**。

---

## 1. 结论

当前桌面端的性能问题不是单一的“Flutter 桌面性能不够”，而是多个热点叠加：

1. **编辑器正文变化直接触发 `EditorWorkspace` 顶层 `setState()`**，一个字符会扩大成整个工作区的 build。
2. 正文变化之后还会进行一次**段落上下文计算**，其中存在整篇文档 `toPlainText()`，并再次更新顶层状态。
3. Live Markdown 伴随预览存在“**全文 Snapshot → 全文 Delta/Markdown 转换 → Markdown 全文编译 → 全部 Block Widget 构造**”链路，并且容易被无关的 Workspace rebuild 重复触发。
4. 文档同步 Outbox 对**尚未绑定远端的本地文档**会保留多个 autosave revision 的完整 Snapshot；Outbox 又是整文件 JSON 重写。运行越久，队列可能越大，序列化和磁盘写入成本随之上升。
5. Chat recovery 会在内存中保留多会话完整消息，同时频繁把**整个恢复快照**重新 JSON 序列化并落盘，长期使用会增加内存、GC 和 IO 压力。
6. 普通知识图谱 Physics 每帧 `notifyListeners()` 后调用整个 Graph 的 `setState()`；开启 idle motion 后物理模拟还会刻意保持不休眠，存在长期 CPU/功耗占用。
7. 聊天图片虽然有自定义 64 MB 字节缓存，但 `Image.memory` 没有限制 decode 尺寸，超大原图可能以全分辨率进入 Flutter 解码缓存/GPU 纹理，造成额外内存压力。
8. Explorer、录音/转写进度等局部动作仍会触发 `EditorWorkspace` 顶层 `setState()`，使原本轻量的状态更新扩大为全局刷新。
9. LocalDocumentStore 自动保存时会重复读取/解析旧文件，再编码新 JSON、flush、backup、rename；安全性很好，但大文档下主线程和 IO 开销偏重。
10. 当前 `_documents` 会加载并长期持有所有完整文档 Snapshot；文档规模和数量上来以后，运行内存会逐渐变大。

因此，本次优化的核心不是“关掉动画/自动保存/同步”，而是：

> **缩小状态刷新边界 + 避免重复全文计算 + 合并尚未发送的中间状态 + 将大对象持久化改成增量/分片 + 控制长期驻留对象 + 将纯 CPU 重任务移出 UI isolate。**

---

# 2. 优化原则：哪些功能绝对不应该为了性能被删掉

本方案默认以下功能必须保持：

- 自动保存继续存在，默认 800 ms 语义可以保留。
- 本地文档仍保留 `.tmp / .bak / atomic rename` 的防损坏策略。
- 云同步最终内容、冲突处理、账号绑定逻辑保持。
- 用户未登录时的本地编辑不能丢失。
- Chat 历史、任务恢复、离线恢复能力保留。
- Markdown 预览内容、主题、图片、目录、布局功能保留。
- 知识图谱动画、拖拽、缩放、选择、2D/3D/稠密模式保留。
- 原图文件仍以原分辨率保存/上传；只限制 UI **解码尺寸**，不降低原始资源质量。
- 录音、上传、转写、轮询进度逻辑保持。
- 现有 API payload 和服务端协议原则上不改。

**不建议第一轮就引入 Riverpod/Bloc 等全量状态管理重构。**  
当前最有效的方案是先把高频状态从巨型 `EditorWorkspace` 中局部化。等性能稳定后再决定是否整体重构。

---

# 3. 优先级总表

| 优先级 | 模块 | 主要问题 | 用户体感 | 修改风险 | 推荐 |
|---|---|---|---|---|---|
| **P0** | Document Sync Outbox | 未绑定文稿 autosave 完整快照持续累积 | 越用越慢、IO 变重 | 中 | **立即修** |
| **P0** | EditorWorkspace | 每次正文变化顶层 `setState` | 打字、操作卡手 | 中低 | **立即修** |
| **P0** | Paragraph Context | 每次编辑后整文 `toPlainText` + 再次顶层刷新 | 输入卡顿 | 低 | **立即修** |
| **P0** | Markdown Companion | 全文转换 + 全文编译 + 全 Block 构造 | 大文档明显卡 | 中 | **立即修** |
| **P1** | Rich Text Toolbar | body 任意变化均 setState | 打字额外 rebuild | 低 | 尽快 |
| **P1** | Chat Recovery | 全消息常驻 + 整体快照重写 | 长时间运行越来越重 | 中 | 尽快 |
| **P1** | Knowledge Graph | 每帧整个图 Widget rebuild；idle 不休眠 | 图谱掉帧、CPU 长占用 | 中 | 尽快 |
| **P1** | Image Decode | 原图全尺寸 decode | 图片多时内存/GC 抖动 | 低 | 尽快 |
| **P1** | Explorer | 查询与列表由 Workspace 顶层刷新，部分列表 eager build | 搜索/切换卡手 | 低 | 尽快 |
| **P1** | Capture/Recording | 3 秒进度刷新引发顶层 setState | 后台转写时 UI 抖 | 低 | 尽快 |
| **P1** | Local Save | autosave 重复读旧 JSON + 主线程序列化 | 停笔后偶发卡一下 | 中 | 尽快 |
| **P2** | Document Loading | 所有完整 Snapshot 常驻 | 大量长文档长期内存增长 | 中高 | 第二阶段 |
| **P2** | Audio Hash | 大文件 SHA-256 在主 isolate 消耗 CPU | 上传大录音时卡 | 低 | 第二阶段 |
| **P2** | Markdown Sliver | 预览 Block 非真正懒加载 | 超长文档滚动/首开慢 | 中 | 第二阶段 |

---

# 4. P0-1：修复 Document Sync Outbox 长期增长

## 4.1 涉及文件

```text
Flutter/desktop/lib/features/documents/data/desktop_document_sync_adapters.dart
Flutter/desktop/lib/app/desktop_services.dart
```

## 4.2 当前问题

`DesktopDocumentOutbox.enqueue(...)` 当前逻辑大意为：

```dart
final isBound = bindings.containsKey(snapshot.id);

pending: <_PendingDocumentSync>[
  for (final entry in pending)
    if (!isBound || entry.localDocumentId != snapshot.id) entry,
  _PendingDocumentSync(
    mutationId: 'desktop-${snapshot.id}-${snapshot.revision}',
    localDocumentId: snapshot.id,
    snapshot: snapshot,
  ),
],
```

对于已经有远端 binding 的文档，旧 pending 可以被覆盖。

但对于**尚未绑定远端的文档**：

```dart
isBound == false
```

于是：

```dart
!isBound == true
```

旧的 autosave revision 会全部留下。

如果用户连续编辑：

```text
revision 1   完整 Snapshot
revision 2   完整 Snapshot
revision 3   完整 Snapshot
...
revision 500 完整 Snapshot
```

Outbox 不是只保存“最终需要同步的内容”，而可能保存大量中间 autosave 全量文档。

与此同时 Outbox store 每次保存会：

```dart
jsonEncode(outbox.toJson())
writeAsString(..., flush: true)
```

即每多一个 revision，以后的每一次 autosave 都要重新编码、重写一个更大的 JSON。

`desktop_services.dart` 中：

```dart
const documentWriteEnabled = bool.fromEnvironment(
  'HUAHUO_DOCUMENT_WRITE_ENABLED',
);
```

如果构建时没有显式开启，默认就是 `false`。此时队列不能 flush，长期运行时这个问题更容易积累。

### 典型恶化路径

```text
新建本地文档
    ↓
不停自动保存
    ↓
尚未绑定远端
    ↓
Outbox 中累积大量完整 snapshot
    ↓
每次 autosave 都重写越来越大的 outbox.json
    ↓
磁盘 IO + JSON encode 越来越慢
    ↓
软件运行越久越卡
```

## 4.3 推荐修改

### 原则

**未发送到服务端的 autosave 中间态，不需要全部保留。**

对于同一个 `localDocumentId`：

> 在没有形成远端可观察状态之前，只保留“最新未发送 Snapshot”。

这不会改变用户最终看到的文档内容。

### 推荐实现

把 enqueue 的 pending 合并逻辑统一成：

```dart
final nextPending = <_PendingDocumentSync>[
  for (final entry in pending)
    if (entry.localDocumentId != snapshot.id) entry,
  _PendingDocumentSync(
    mutationId: 'desktop-${snapshot.id}-${snapshot.revision}',
    localDocumentId: snapshot.id,
    snapshot: snapshot,
  ),
];
```

但在真正修改前，要先确认：

- 是否有产品需求要求“每一次 autosave revision 都必须成为服务端历史版本”；
- 如果需要历史版本，**历史版本应该由显式 checkpoint/version 机制维护**，而不是依赖尚未发送的 Outbox 全 Snapshot。

### 已有历史 Outbox 的迁移

加载 Outbox 时增加一次兼容压缩：

```text
读取旧 v2 outbox
    ↓
按 localDocumentId 分组
    ↓
只保留 revision 最大/最后出现的一条 pending
    ↓
保留 binding / conflict / metadata
    ↓
保存 compact 后的新 outbox
```

建议保持现有 formatVersion，若语义有变化也可升一个版本并兼容旧格式。

### unbound → 登录账号后的迁移

如果用户登录前编辑了文档：

```text
outbox-unbound.json
```

不要直接丢弃。

登录并获得 workspace scope 后：

1. 加载 unbound outbox；
2. 每个文档只保留最新 snapshot；
3. 合并到当前账号/workspace outbox；
4. 成功持久化后清空 unbound outbox。

这样既防止长期堆积，又保持“未登录编辑，登录后仍可同步”的功能。

## 4.4 不建议的做法

不要为了性能直接：

```text
关闭 autosave
```

不要直接：

```text
永远不写 outbox
```

不要把：

```text
HUAHUO_DOCUMENT_WRITE_ENABLED=true
```

当作性能修复。

因为这会改变环境/服务端行为，而不是解决队列数据结构问题。

## 4.5 必须增加测试

```text
100 次未绑定 autosave，同一文档：
pending.length == 1
pending.first.snapshot.revision == 最新 revision
内容 == 最新内容

100 次 autosave，10 个文档：
pending.length <= 10
每个文档都只保留最新 snapshot

旧的膨胀 outbox：
load 后自动 compact
最终内容完全一致

unbound → bindAccount：
所有文档最新内容被迁移
无重复 create
无内容丢失

remote write 开启后：
服务端最终文档 == 本地最终 snapshot
冲突语义不变
```

---

# 5. P0-2：正文输入不要再触发整个 EditorWorkspace rebuild

## 5.1 涉及文件

```text
Flutter/desktop/lib/features/editor/presentation/editor_workspace.dart
Flutter/packages/huahuo_editor/lib/src/editor/huahuo_editor_controller.dart
```

## 5.2 当前问题

创建编辑器时：

```dart
controller.addListener(_refresh);
controller.body.addListener(_handleEditorBodyChanged);
```

而：

```dart
void _refresh() {
  if (mounted) setState(() {});
}
```

正文变化：

```dart
void _handleEditorBodyChanged() {
  _refresh();
  _scheduleParagraphContextAttachment();
}
```

即用户输入一个字符：

```text
Quill body notify
    ↓
EditorWorkspace.setState
    ↓
整个工作区 build
```

而 `EditorWorkspace` 同时承载：

- 编辑器
- Explorer
- Chat
- Assets
- Knowledge Graph
- Notifications
- Recording/Capture
- Workspace 状态
- 顶部栏
- 右侧上下文
- 多种模式与大量 loading/status

所以一个字符会扩大为大量不相关的 build。

## 5.3 第一阶段最小改法

### 删除正文变化中的顶层 `_refresh()`

改成：

```dart
void _handleEditorBodyChanged() {
  _scheduleParagraphContextAttachment();
  _scheduleMarkdownCompanionRefresh();
}
```

不要：

```dart
_refresh();
```

Quill 编辑器本身有自己的 Controller/Element 更新机制，不需要为了显示新字符让整个 Shell rebuild。

### `HuahuoEditorController` 的 listener 也不要绑定整个 Workspace

当前：

```dart
controller.addListener(_refresh);
```

Controller 的 `notifyListeners()` 主要承载 save state 等状态。

建议改成局部监听：

```text
HuahuoEditorController
    ├── SaveStatusWidget
    ├── DocumentTitle/DirtyIndicator
    └── 必须依赖该状态的小组件
```

而不是：

```text
HuahuoEditorController
    ↓
EditorWorkspace.setState
```

可以先使用：

```dart
ListenableBuilder(
  listenable: editorController,
  builder: ...
)
```

或者增加：

```dart
ValueNotifier<HuahuoSaveState>
```

仅刷新保存状态区域。

## 5.4 推荐结构

第一轮不需要全面换状态管理框架。

只需形成下面的刷新边界：

```text
EditorWorkspaceShell
│
├── ActivityBar               // 稳定
├── ExplorerPane              // 自己的状态
├── DocumentWorkspace
│   ├── QuillEditor           // Quill 自己更新
│   ├── FormattingToolbar     // 只听 selection/style
│   ├── SaveIndicator         // 只听 saveState
│   ├── ParagraphContext      // debounce 后局部更新
│   └── MarkdownCompanion     // debounce + cache
│
├── ChatWorkspace             // 自己的 controller
├── GraphWorkspace            // painter/listenable
└── CaptureStatus             // 局部 ValueNotifier
```

---

# 6. P0-3：段落上下文不能在每次编辑后扫描整篇文档

## 6.1 当前问题

正文变化之后会：

```dart
_scheduleParagraphContextAttachment();
```

调度到 post-frame 后，再根据 selection 计算当前段落。

当前实现中存在：

```dart
final plainText = _editor.body.document.toPlainText();
```

这意味着每次编辑都可能复制/遍历完整文档字符串。

同时计算完成后还可能再次 `setState()`。

于是一次按键可能形成：

```text
按键
 ↓
Workspace setState
 ↓
Quill 更新
 ↓
post-frame callback
 ↓
document.toPlainText() 全文转换
 ↓
再次 Workspace setState
```

这对几百字影响不明显，但对几万字会明显放大。

## 6.2 推荐最小改法

### 增加 120～180 ms debounce

```dart
Timer? _paragraphContextDebounce;

void _scheduleParagraphContextAttachment() {
  _paragraphContextDebounce?.cancel();
  _paragraphContextDebounce = Timer(
    const Duration(milliseconds: 150),
    _refreshParagraphContext,
  );
}
```

### 更新前比较值

只有真正发生变化才通知 UI：

```dart
if (nextContext == _focusedParagraphContext) return;
_focusedParagraphContext.value = nextContext;
```

不要为了相同上下文重复 setState。

### 发送 AI 前兜底精确计算

为了保证功能完全不变：

当用户点击“发送”“引用当前段落”等动作时，调用：

```dart
await _ensureParagraphContextCurrent();
```

如果 debounce 尚未完成，立即计算一次最新 selection/context。

这样：

- 打字过程中减少全文扫描；
- 真正使用上下文时仍然 100% 获取最新内容。

## 6.3 第二阶段更优方案

不要整篇：

```dart
document.toPlainText()
```

而是根据当前 Quill selection 找到对应 line/leaf/block，只取当前段落范围。

如果 `flutter_quill 11.5.1` 的 Document API 能稳定获取 selection 所在 Line，应优先使用局部 Node 查询。

这项属于第二阶段，第一阶段 debounce 已能显著降低问题。

---

# 7. P0-4：重构 Live Markdown Companion 刷新链

## 7.1 涉及文件

```text
Flutter/desktop/lib/features/editor/presentation/editor_workspace.dart
Flutter/packages/huahuo_editor/lib/src/editor/huahuo_editor_controller.dart
Flutter/packages/huahuo_editor/lib/src/document/huahuo_document_codec.dart
Flutter/desktop/lib/shared/markdown/markdown_preview_pane.dart
Flutter/desktop/lib/shared/markdown/markdown_html_compiler.dart
```

## 7.2 当前重链路

Workspace 构建预览时：

```dart
final snapshot = _editor.snapshot;
```

但 `snapshot` 不是轻量 getter。

其中会做：

```dart
deltaJson: HuahuoDocumentCodec.encode(body.document),
markdownProjection:
    HuahuoDocumentCodec.documentToMarkdown(body.document),
```

然后 Markdown Preview 的 build 中又：

```dart
MarkdownHtmlCompiler().compile(...)
```

Compiler 会进一步：

- parse 全部 Markdown；
- render HTML；
- parse HTML fragment；
- sanitize；
- 生成 standalone HTML；
- 生成 headings/native nodes。

随后 Native Preview：

```dart
nodes
  .map(renderer.buildBlock)
  .toList()
```

一次性构造所有 Block Widget。

### 当前实际链路

```text
输入一个字符
  ↓
Workspace rebuild
  ↓
_editor.snapshot
  ↓
Document → Delta
  ↓
normalize
  ↓
JSON encode
  +
Delta → Markdown
  ↓
Markdown parse
  ↓
HTML render
  ↓
HTML parse/sanitize
  ↓
nativeNodes
  ↓
所有 block → Widget
  ↓
完整 Column layout
```

对于大文档，这是当前最重的交互链之一。

---

## 7.3 第一阶段：Live Preview 150 ms debounce

建议：

```dart
Timer? _previewDebounce;

void _scheduleMarkdownCompanionRefresh() {
  _previewDebounce?.cancel();
  _previewDebounce = Timer(
    const Duration(milliseconds: 150),
    _refreshMarkdownCompanion,
  );
}
```

编辑器立即响应，预览稍后更新。

人眼不会明显感受到 150 ms 的预览延迟，但 CPU 计算次数会大幅下降。

建议范围：

```text
120～180 ms
```

不建议超过 250 ms，否则伴随预览开始有明显迟滞感。

---

## 7.4 第二步：预览结果按 revision 缓存

增加一个轻量 Preview State：

```dart
class DocumentPreviewState {
  final String documentId;
  final int revision;
  final HuahuoNoteStage stage;
  final String markdown;
  final CompiledNativeMarkdown compiled;
}
```

缓存 key：

```text
documentId
+ revision
+ noteStage
+ MarkdownPreviewPreferences.renderKey
+ brightness
```

如果 key 没变化：

```text
直接复用 compiled 结果
```

无关的 Workspace setState 不应该重新编译相同 Markdown。

---

## 7.5 不要在通用 UI build 里调用 `_editor.snapshot`

建议拆出两种数据：

### Lightweight editor state

用于 UI：

```text
id
title
revision
saveState
activeStage
```

### Derived snapshot

只在以下时机生成：

- autosave；
- 显式保存；
- preview debounce 到期；
- 导出；
- 需要同步。

不要把全量 Snapshot 当成普通 getter 在 build 中随意获取。

---

## 7.6 拆分 Native Preview 与 HTML Export 编译链

当前 `MarkdownHtmlCompiler.compile()` 为 Native Flutter 预览也生成 HTML 相关结果。

建议拆为：

```dart
compileNative(...)
compileHtml(...)
```

### Native UI

只需要：

```text
Markdown parse
→ safety validation
→ headings
→ native nodes
```

### HTML export/diagnostics

才做：

```text
renderToHtml
→ parseFragment
→ sanitize
→ standalone document
```

这样不改变任何预览内容，但 Native UI 不再支付 HTML 中间链路成本。

---

## 7.7 Companion Preview 使用 Sliver 懒构建

当前虽然外层是 `ListView`，但其 child 是包含所有 block 的一个大 `Column`。

这不是 block 级 lazy build。

建议：

### 普通 article / companion 模式

使用：

```dart
CustomScrollView(
  slivers: [
    SliverList.builder(
      itemCount: nodes.length,
      itemBuilder: ...
    ),
  ],
)
```

### Magazine / Research 等需要整体排版的模式

第一阶段可以保留原布局，避免改变视觉。

因此：

```text
Companion/Article/Compact
    → Sliver lazy

复杂杂志/研究布局
    → 继续完整布局
```

---

# 8. P1-1：RichTextFormattingToolbar 不要每个字符都 setState

## 涉及文件

```text
Flutter/desktop/lib/features/editor/presentation/rich_text_formatting_toolbar.dart
```

当前：

```dart
widget.controller.body.addListener(_refreshSelectionStyle);

void _refreshSelectionStyle() {
  if (mounted) setState(() {});
}
```

body 任意变化都会刷新工具栏。

实际上工具栏只关心：

- selection range；
- 当前 selection style；
- undo/redo；
- 少量格式状态。

建议计算一个 fingerprint：

```dart
@immutable
class _ToolbarState {
  final int baseOffset;
  final int extentOffset;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool canUndo;
  final bool canRedo;
}
```

监听 body 后：

```dart
final next = _readToolbarState();
if (next == _lastState) return;
setState(() => _lastState = next);
```

这样纯文本连续输入时，若格式状态和 selection 关注项没有实际变化，可避免不必要的 toolbar rebuild。

如果 Quill 提供 selection/style 专用 stream，优先使用更窄的监听源。

---

# 9. P1-2：Chat Recovery 从“大一统 Snapshot”改为索引 + 按线程存储

## 9.1 涉及文件

```text
Flutter/desktop/lib/features/chat/application/desktop_chat_task_tracker.dart
Flutter/desktop/lib/features/chat/data/desktop_chat_recovery_store.dart
Flutter/desktop/lib/features/editor/presentation/editor_workspace.dart
```

## 9.2 当前问题

`DesktopChatTaskTracker` 的 Snapshot 长期持有：

```text
threads
messagesByThread
tasks
```

打开更多会话后：

```text
messagesByThread[threadId]
```

会持续保留完整消息。

Recovery Store 每次持久化会重新：

```text
整个 snapshot
→ jsonEncode
→ .part
→ flush
→ replace
```

于是：

```text
会话越多
   ↓
内存驻留消息越多
   ↓
每次 recovery 保存 JSON 越大
   ↓
GC + IO 越来越重
```

这非常符合“运行久后变卡”的症状。

## 9.3 推荐存储结构

改成：

```text
chat-recovery/
├── index.json
└── threads/
    ├── <threadId-1>.json
    ├── <threadId-2>.json
    └── ...
```

`index.json` 只保存：

```text
thread metadata
active/recent thread ids
task metadata
必要恢复标记
```

每个线程消息单独存。

## 9.4 内存策略

内存只保留：

```text
active thread
+ 最近 N 个 thread 的完整 messages
```

建议 N：

```text
3～8
```

旧线程不删除，只是从内存 LRU eviction。

用户重新打开时从：

```text
threads/<id>.json
```

lazy load。

因此不会丢聊天历史。

## 9.5 写盘策略

### 必须立即 durable

以下关键节点仍立即 flush：

- 新任务 accepted；
- terminal success/failure；
- 用户发送的重要本地消息；
- app 即将退出时。

### 非关键刷新可以合并

例如：

- thread list refresh；
- task heartbeat；
- 同一秒连续状态更新。

使用：

```text
200～500 ms persist debounce/coalesce
```

每次只保存最新状态。

---

# 10. P1-3：Chat Tracker 的 UI 更新不要再经过 EditorWorkspace 顶层

当前 `EditorWorkspace`：

```dart
_chatTaskTracker
  ..addListener(_handleChatTaskTrackerChanged);
```

Tracker 变化后会把 detail/messages 应用到 Workspace 并触发大范围 setState。

建议：

```text
ChatWorkspace
    ↓
直接 ListenableBuilder(chatTaskTracker)
```

EditorWorkspace 只维护：

```text
当前 threadId / 页面导航
```

消息新增、任务状态、loading 只刷新 Chat 面板。

这样后台 agent/status 更新时不会影响编辑器、Explorer、图谱等。

---

# 11. P1-4：Knowledge Graph 物理帧只重绘 Canvas，不重建整个 Graph

## 11.1 涉及文件

```text
Flutter/desktop/lib/features/editor/presentation/desktop_knowledge_graph.dart
Flutter/desktop/lib/features/editor/application/desktop_graph_physics_simulation.dart
```

## 11.2 当前问题

普通 Graph：

```dart
_physics = DesktopGraphPhysicsSimulation()
  ..addListener(_onPhysicsChanged);

void _onPhysicsChanged() {
  if (mounted) setState(() {});
}
```

Physics 每推进 frame：

```dart
_capturePositions();
notifyListeners();
```

于是：

```text
60 Hz physics
    ↓
notifyListeners
    ↓
DesktopKnowledgeGraph.setState
    ↓
整个 Graph widget subtree rebuild
    ↓
CustomPainter repaint
```

而实际上每帧变化的主要只是：

```text
node positions
edge geometry
```

Dense Graph 已经使用：

```dart
ValueNotifier<List<_ProjectedNode>>
```

方向更合理。

## 11.3 推荐修改

让普通 Graph 也采用：

```dart
ValueNotifier<GraphFrame> frame;
```

Painter 直接通过 repaint/listenable 驱动：

```dart
CustomPaint(
  painter: GraphPainter(
    repaint: frame,
    ...
  ),
)
```

物理帧变化：

```text
只更新 RenderCustomPaint
```

不要：

```text
设置按钮
图例
Overlay
GestureDetector
控制面板
全部重新 build
```

---

# 12. P1-5：保留 idle motion，但降低长期 CPU 占用

Physics 当前 idle motion 开启时会阻止 sleep：

```text
_idleMotionEnabled == true
→ _lowVelocitySteps 清零
→ 不进入 sleeping
```

视觉上能保持“活着”的效果，但意味着图谱可能长期持续 ticker。

不要简单关闭动画。

建议改成分档：

```text
用户拖拽/缩放/刚进入图谱：
60 FPS

布局仍在明显收敛：
60 FPS

稳定后的 idle motion：
20～30 FPS

窗口最小化/后台不可见：
暂停 ticker

窗口重新可见：
恢复
```

idle motion 本身幅度很小，24 FPS 与 60 FPS 的视觉差异远小于 CPU 差异。

### 建议

```text
activeFps = 60
idleFps = 24
backgroundFps = 0
```

具体值用 Flutter DevTools 实测后微调。

---

# 13. P1-6：聊天图片限制“解码尺寸”，不降低原图质量

## 13.1 涉及文件

```text
Flutter/desktop/lib/features/chat/data/desktop_resource_image_cache.dart
Flutter/desktop/lib/features/editor/presentation/editor_workspace.dart
```

自定义 Resource Image Cache 已有：

- Memory LRU 约 64 MB；
- Disk Cache 约 250 MB；
- inflight request 去重。

这些设计可以保留。

但聊天渲染中存在类似：

```dart
Image.memory(
  image.bytes,
  width: width,
  fit: BoxFit.contain,
  filterQuality: FilterQuality.medium,
)
```

未提供：

```dart
cacheWidth
cacheHeight
```

假设用户上传一张：

```text
6000 × 4000 JPEG
```

UI 只显示 600 px 宽，但 Flutter 仍可能解码成完整尺寸。

一个 RGBA 纹理大致可能达到：

```text
6000 × 4000 × 4 ≈ 96 MB
```

压缩 JPEG 本身可能只有几 MB，但解码后非常大。

## 13.2 推荐

按显示尺寸和 DPR 计算 decode width：

```dart
final dpr = MediaQuery.devicePixelRatioOf(context);
final decodeWidth = (width * dpr)
    .ceil()
    .clamp(1, 2048);

Image.memory(
  image.bytes,
  width: width,
  cacheWidth: decodeWidth,
  fit: BoxFit.contain,
);
```

对于头像、小缩略图也使用对应较小的 `cacheWidth`。

### 关键点

只改变：

```text
UI decode resolution
```

不改变：

```text
原文件 bytes
磁盘 cache 原图
上传原图
导出原图
```

因此功能和资源质量不受影响。

---

# 14. P1-7：Resource Image Disk Cache 避免在 sort 中 `statSync`

Disk cache enforce limit 时，当前逻辑已经 async 获取一次 stat，但排序阶段又调用：

```dart
file.statSync()
```

排序会反复比较，同一文件可能执行多次同步系统调用。

建议先收集：

```dart
class _CachedFileMeta {
  File file;
  int size;
  DateTime modified;
}
```

一次 async stat：

```text
File → stat
```

然后：

```dart
metas.sort((a, b) => a.modified.compareTo(b.modified));
```

全程内存比较。

进一步可以在 Cache 实例中维护：

```text
trackedDiskBytes
```

只有接近上限时才真正扫描整个目录。

---

# 15. P1-8：Explorer 自己管理搜索状态，不让搜索按键重建整个 Workspace

## 涉及文件

```text
Flutter/desktop/lib/features/editor/presentation/editor_workspace.dart
```

当前 Explorer 的 query 改变会触发顶层 state 更新。

而文档列表部分存在：

```text
ListView(
  children: [
    for (final document in filteredDocuments) ...
  ],
)
```

即每次 build 都 eager 构造当前列表。

### 推荐

拆成：

```dart
class DesktopExplorerPane extends StatefulWidget
```

或内部使用：

```dart
ValueNotifier<String> query
```

搜索输入只刷新 Explorer。

### 列表改为 lazy

将树形节点先 flatten：

```text
folder row
child document row
child document row
folder row
...
```

再使用：

```dart
ListView.builder(...)
```

或：

```dart
CustomScrollView
+ SliverList.builder
```

保留：

- 展开/折叠；
- 选中；
- 右键；
- icon；
- drag/drop；
- 原有排序。

如果文档很多，还可为每个 Document Summary 缓存：

```text
lowercaseTitle
lowercaseSubtitle
```

避免每次搜索重复 `toLowerCase()`。

---

# 16. P1-9：Capture/Recording 进度只刷新对应区域

## 涉及文件

```text
Flutter/desktop/lib/features/editor/presentation/editor_workspace.dart
Flutter/desktop/lib/features/recordings/data/desktop_recordings_adapters.dart
```

转写/录音状态轮询大约每 3 秒执行。

每次 `_updateCaptureRecord` 目前会更新 Workspace state。

后台一条录音转写时，即使用户在编辑文档，也会周期性把大 Workspace rebuild 一遍。

### 推荐

建立：

```dart
ValueNotifier<List<CaptureRecord>> captureRecords
```

或者：

```dart
CaptureController extends ChangeNotifier
```

仅：

```text
Capture 面板
Explorer 中 Capture 小区域
对应状态条
```

监听。

编辑器主体不再跟着重建。

### 记录列表

当前 UI 可能只显示最近几条，但 `_captureRecords` 会继续保留。

如果需要完整历史：

- 完整历史放服务端/本地持久层；
- 内存只保留 active + recent；
- 打开历史页时再加载。

如果当前 Capture 只是临时任务列表，可对 terminal record 做安全上限，例如最近 50～100 条。

**不要清理 running 状态。**

---

# 17. P1-10：保留 800 ms autosave，但把“全文计算”从输入线程隔离

## 涉及文件

```text
Flutter/packages/huahuo_editor/lib/src/editor/huahuo_editor_controller.dart
Flutter/packages/huahuo_editor/lib/src/document/huahuo_document_codec.dart
Flutter/desktop/lib/features/editor/data/local_document_store.dart
```

当前 autosave debounce 设计本身是合理的：

```text
输入
 ↓
800 ms 内继续输入
 ↓
Timer 重置
 ↓
停止输入 800 ms
 ↓
saveNow()
```

问题不是 800 ms，而是 saveNow 内的：

```dart
final pending = snapshot;
```

会同步生成：

```text
Delta JSON
Markdown Projection
```

大文档下会表现成：

```text
输入时还行
停止输入
约 0.8 秒后突然卡一下
```

## 推荐两阶段优化

### 阶段 A：缓存 derived result

根据 revision：

```text
如果 revision 没变化
→ 不重复 Delta→Markdown

preview 已经生成同 revision markdown
→ autosave 直接复用
```

### 阶段 B：纯数据放 isolate

主 isolate 只拿 Quill Delta 的可发送 DTO：

```dart
List<Map<String, dynamic>>
```

然后：

```dart
Isolate.run(() {
  // normalize
  // json encode
  // markdown projection
});
```

注意：

不要把：

```text
QuillController
BuildContext
Document 对象
```

直接传 isolate。

只传可发送的纯 Dart 数据。

---

# 18. P1-11：LocalDocumentStore 保留原子保存，但避免每次重复解析旧 JSON

## 当前保存链

当前一次 save 大体会：

```text
检查 target
↓
读取旧 target
↓
jsonDecode
↓
检查 formatVersion
↓
再次读取/解析旧 snapshot 判断 readable
↓
新 snapshot toJson
↓
jsonEncode
↓
write tmp + flush
↓
backup
↓
rename
```

可靠性是好的，但 autosave 高频场景中重复验证成本偏高。

## 推荐

### 文档 load/open 时

记录：

```text
path
known formatVersion
lastModified
lastWrittenRevision
```

### 后续 autosave

若：

```text
mtime 与自己上次写入一致
```

则说明文件未被外部修改，可直接：

```text
encode
→ tmp
→ flush
→ atomic replace
```

只有检测到外部修改时才重新 parse/revalidate。

### 不要删除

以下安全能力必须保留：

```text
.tmp
.bak
flush
rename rollback
future formatVersion protection
```

---

# 19. P2-1：所有完整文档不要永远常驻内存

## 当前状态

`LocalDocumentStore.loadAll()` 会读出所有完整 Snapshot。

每个 Snapshot 可能包含：

- `deltaJson`
- `markdownProjection`
- metadata
- linked materials
- annotations
- derived note fields

`EditorWorkspace._documents` 长期持有全部内容。

打开当前文档后还会再创建 Quill `Document` 对象。

大量长文档时：

```text
完整 JSON 字符串
+ Markdown 字符串
+ 当前 Quill tree
+ Preview nodes
+ Chat data
+ Image cache
```

会共同提高常驻内存。

## 推荐第二阶段架构

增加：

```dart
class HuahuoDocumentSummary {
  String id;
  String title;
  DateTime modifiedAt;
  int revision;
  // explorer/graph 所需轻量字段
}
```

启动时：

```text
只加载 summaries
```

点击文档：

```text
lazy load full snapshot
```

最近打开文档维护一个小 LRU，例如：

```text
3～8 个 full snapshot
```

Graph/Explorer 尽量只消费 Summary/关系索引。

这是比较大的结构性修改，建议 P0/P1 完成后再做。

---

# 20. P2-2：大录音 SHA-256 放 Worker Isolate

## 涉及文件

```text
Flutter/desktop/lib/features/recordings/data/desktop_recordings_adapters.dart
```

音频允许很大的文件。

当前 hashing 通过 stream 读取虽然 IO 是异步的，但 SHA-256 计算本身仍会在当前 isolate 消耗 CPU。

对于几百 MB～GB 音频，可能持续抢占 UI isolate 时间片。

建议：

```dart
final digest = await Isolate.run(
  () => hashFileByPath(path),
);
```

Worker isolate 自己：

```text
File.openRead()
→ sha256
```

UI 继续：

- 展示进度；
- 响应编辑；
- 图谱交互。

上传流程和最终 hash 完全不变。

---

# 21. 当前不需要优先改的地方

以下部分当前实现方向已经比较合理，不建议为了“优化”乱改：

## 21.1 大部分业务列表已经使用 builder

工程中很多 Chat、Work、Asset 列表使用：

```dart
ListView.separated(
  itemCount: ...,
  itemBuilder: ...,
)
```

这是对的。

问题主要集中在：

- Workspace 顶层状态；
- Markdown 大 Column；
- Explorer 部分 eager rows。

## 21.2 Workspace/Topic polling 有停止条件

轮询不是简单永久跑死。

只要保持：

```text
start/stop
mounted
refreshing guard
terminal guard
```

即可。

重点是让轮询结果**局部刷新**，不需要删除轮询功能。

## 21.3 Dense Graph 已经有局部更新意识

Dense graph 使用 `ValueNotifier` 和空间桶等策略。

不要推翻。

应该把普通 Graph 往 Dense Graph 的局部更新方式靠。

## 21.4 dispose 生命周期总体并非严重泄漏

`EditorWorkspace`、Graph、Window listener 等主要 Controller/Timer/Listener 都有 dispose/stop。

当前“越用越卡”更像：

```text
数据结构持续增长
+ 重复全量序列化
+ 主线程全文计算
+ 高刷新范围
+ 图片解码内存
+ 持续物理动画
```

而不是一个简单的“忘记 cancel Timer”。

---

# 22. 推荐的最终状态边界

不要求一次重构到这个程度，但可以作为方向：

```text
DesktopApp
└── EditorWorkspaceShell
    ├── ActivityBar
    ├── ExplorerController
    │   └── ExplorerPane
    │
    ├── DocumentController
    │   ├── QuillEditorPane
    │   ├── SaveState
    │   ├── ParagraphContext
    │   └── PreviewController
    │       └── MarkdownCompanion
    │
    ├── ChatController / ChatTaskTracker
    │   └── ChatWorkspace
    │
    ├── GraphController
    │   ├── GraphStaticControls
    │   └── GraphCanvas(repaint only)
    │
    ├── CaptureController
    │   └── CapturePane
    │
    └── NotificationController
        └── NotificationPane
```

核心原则：

> 高频变化离它使用的位置越近越好。

不要：

```text
任何 controller.notify
    ↓
EditorWorkspace.setState
```

---

# 23. 推荐实施顺序

建议分成 7 个独立 PR/commit，便于回归和定位。

## Commit 1 — 修复长期退化

```text
perf(sync): compact pending document outbox
```

包含：

- 未绑定文档 pending latest-only；
- 旧 outbox migration compact；
- unbound → bound migration；
- 新增相关测试。

这是“运行越久越卡”最值得先排除的原因。

---

## Commit 2 — 输入链局部化

```text
perf(editor): isolate body and selection rebuilds
```

包含：

- 删除 body → `_refresh()`；
- save state 局部监听；
- paragraph context 150 ms debounce；
- context 相同不通知；
- send/quote 前强制 ensure-current；
- toolbar state fingerprint。

目标：

> 输入字符时不再触发整个 Workspace。

---

## Commit 3 — Live Preview

```text
perf(preview): debounce and cache markdown companion
```

包含：

- 150 ms preview debounce；
- 按 revision cache markdown；
- Preview compile cache；
- 不在通用 build 中获取 full snapshot；
- Native compiler 与 HTML compiler 可先留接口，第二小步拆。

目标：

> 大文档编辑时 Preview 不再按每个字符全文重算。

---

## Commit 4 — Graph

```text
perf(graph): repaint physics without rebuilding controls
```

包含：

- 普通 graph frame ValueNotifier；
- CustomPainter repaint；
- static controls 与 canvas 分离；
- idle 24/30 FPS；
- background/minimized pause；
- 不改变动画功能。

---

## Commit 5 — Chat 与图片

```text
perf(chat): compact recovery persistence and image decoding
```

包含：

- active/recent message LRU；
- thread 按文件存储；
- recovery index；
- ordinary persist debounce；
- crash-critical persist immediate；
- Image.memory cacheWidth；
- disk cache sort 去 `statSync`。

---

## Commit 6 — Explorer / Capture

```text
perf(workspace): localize explorer and capture state
```

包含：

- Explorer local state；
- lazy rows；
- Capture controller；
- polling 只刷新 status 区域；
- terminal history 内存策略。

---

## Commit 7 — IO / Isolate

```text
perf(io): move heavy serialization and hashing off ui isolate
```

包含：

- snapshot pure DTO；
- Delta/Markdown encode isolate；
- large audio hash isolate；
- LocalDocumentStore 避免重复旧文件 parse。

---

# 24. 性能验收场景

每一次优化必须在 **Profile mode** 验证，而不是 Debug mode。

建议固定下面场景做基准。

---

## Case A：长文档输入

准备：

```text
5 万字符
10 万字符
含标题、列表、图片、代码块
```

操作：

```text
连续输入 2 分钟
快速删除
选中
复制
滚动
Undo/Redo
```

分别测试：

```text
Live Preview OFF
Live Preview ON
```

观察：

- Flutter DevTools Frame Chart；
- UI/Raster frame time；
- CPU profile；
- memory；
- GC；
- input latency。

目标：

```text
输入不出现持续性丢帧
不出现每按键一次大范围 Widget rebuild
Preview 更新保持 120～250 ms 内
停笔 autosave 不应产生明显 >50 ms 卡顿尖峰
```

---

## Case B：大量本地 autosave / Remote write disabled

设置：

```text
HUAHUO_DOCUMENT_WRITE_ENABLED=false
```

新建未绑定远端文档。

持续编辑至少：

```text
30 分钟 / 500+ autosave
```

验收：

```text
Outbox 对同一文档 pending 不随 autosave 次数线性增长
Outbox 文件大小达到稳定量级
每次 autosave 时延不会随时间线性恶化
最终 snapshot 内容正确
```

---

## Case C：Explorer 大数据

准备：

```text
500～2000 documents
```

操作：

```text
快速搜索
展开文件夹
切换文档
编辑正文同时保持 Explorer 展开
```

目标：

```text
正文输入不引发 Explorer rebuild
Explorer 搜索只影响 Explorer subtree
列表只构造可视区域附近 row
```

---

## Case D：Knowledge Graph 30 分钟

操作：

```text
打开图谱
拖拽节点
缩放
等待稳定
保持窗口前台 30 分钟
切后台/最小化
重新打开
```

目标：

```text
交互阶段保持当前视觉流畅度
idle CPU 明显下降
后台 ticker 停止或接近零
Graph controls 不随 physics frame rebuild
恢复前台后行为一致
```

---

## Case E：长时间 Chat

准备：

```text
100+ threads
大量长消息
含多张高分辨率图片
```

操作：

```text
不断切换 thread
产生 task 状态更新
滚动图片消息
运行 1～2 小时
```

目标：

```text
messages RAM 达到 plateau，不随打开过的所有 thread 无限增长
Recovery 写盘耗时不随全部历史线性增长
重新打开旧 thread 可以从磁盘恢复完整内容
图片显示清晰
原图不丢失
解码内存明显下降
```

---

## Case F：大录音

文件：

```text
500 MB
1 GB+
```

同时：

```text
编辑文档
滚动 Chat
```

目标：

```text
hash/upload 期间 UI 仍响应
无长时间 UI isolate CPU 满载
最终 SHA-256 与现有实现完全一致
```

---

# 25. 功能回归清单

所有性能 PR 合入前至少验证：

## Editor

- [ ] 正文字符不丢失。
- [ ] IME 中文输入正常。
- [ ] Undo/Redo 正常。
- [ ] 粗体/斜体/颜色/列表/引用等格式正常。
- [ ] Toolbar 状态与光标位置一致。
- [ ] 当前段落 AI 上下文始终是最新内容。
- [ ] 文档切换不会读取上一个文档 Context。

## Autosave

- [ ] 800 ms 自动保存仍工作。
- [ ] 应用异常退出后最新已保存内容可恢复。
- [ ] `.bak` 恢复正常。
- [ ] future format version protection 不变。
- [ ] 同一 revision 不产生重复昂贵 projection。

## Sync

- [ ] 未登录编辑不会丢。
- [ ] 登录后可迁移待同步文档。
- [ ] 未绑定文档只保存最新 pending。
- [ ] 已绑定文档 update 行为不变。
- [ ] 冲突逻辑不变。
- [ ] 服务端最终内容与本地最新内容一致。

## Preview

- [ ] Companion 内容正确。
- [ ] 主题/亮暗模式正确。
- [ ] Table of Contents 正确。
- [ ] 本地图片正常。
- [ ] Remote image policy 正常。
- [ ] Magazine/Research 等特殊布局不变。
- [ ] 快速输入后 Preview 最终追上最新 revision。

## Chat

- [ ] 当前 thread 消息完整。
- [ ] 旧 thread 再打开能恢复完整消息。
- [ ] pending/running/terminal task 恢复正常。
- [ ] Crash recovery 关键节点不丢。
- [ ] 图片显示清晰。
- [ ] 原图仍可完整使用。

## Graph

- [ ] 2D/3D/Dense 模式结果一致。
- [ ] Node drag 正常。
- [ ] Pan/zoom 正常。
- [ ] Selection 正常。
- [ ] idle motion 仍存在。
- [ ] 从后台恢复无跳变/异常。
- [ ] Graph settings 正常。

## Capture/Recording

- [ ] 录音创建正常。
- [ ] upload 正常。
- [ ] transcribe 正常。
- [ ] progress 正常。
- [ ] failure/retry 正常。
- [ ] terminal 状态不丢。

---

# 26. 建议增加的性能保护测试

普通 Widget Test 不能完全测 FPS，但可以防止性能问题重新写回来。

建议加入以下结构测试。

## 26.1 EditorWorkspace rebuild isolation

引入测试计数 Widget：

```text
编辑正文 20 个字符
```

断言：

```text
Explorer build count 不随 20 次字符输入增长 20 次
ActivityBar build count 不随字符输入增长
```

---

## 26.2 Preview debounce

模拟：

```text
100 ms 内输入 20 次
```

断言：

```text
preview compile <= 1～2 次
最终 revision == 最新 revision
```

---

## 26.3 Outbox compact

模拟：

```text
同 document 100 revisions
```

断言：

```text
pending == 1
```

---

## 26.4 Recovery LRU

模拟打开：

```text
20 threads
```

断言：

```text
in-memory full messages <= configured LRU
```

同时旧 thread 仍能从 store load。

---

## 26.5 Image decode

验证：

```text
6000px 原图
600px display width
```

ImageProvider decode target 不超过设定上限。

---

# 27. 建议增加 Debug/Profile 观测点

为了以后不靠“感觉卡”定位，可以在 Profile/Debug instrumentation 中记录：

```text
previewCompileMs
snapshotEncodeMs
localSaveMs
outboxBytes
outboxPendingCount
chatRecoveryBytes
loadedChatThreadCount
resourceImageMemoryBytes
graphActiveFps
graphPhysicsStepMs
activeFullDocumentCount
```

只在：

```text
assert / kDebugMode / profile telemetry
```

中使用，不建议生产版频繁打印日志。

特别推荐在 Debug 页面显示：

```text
Outbox pending: 1
Outbox size: 220 KB
Chat memory threads: 5
Image byte cache: 42 MB / 64 MB
Graph state: idle@24fps
Preview revision: 152
```

这样以后出现“运行久了卡”时能快速判断到底是哪一块增长。

---

# 28. 第一轮最值得做的 8 个具体修改

如果当前只安排一轮性能优化，建议直接完成下面 8 项：

1. **Document Outbox 同文档只保留最新未发送 autosave Snapshot。**
2. **删除 `_handleEditorBodyChanged()` 中的 Workspace `_refresh()`。**
3. **Paragraph context 改 150 ms debounce，并避免相同值重复更新。**
4. **Live Markdown Companion 改 150 ms debounce + revision cache。**
5. **`_editor.snapshot` 不再作为 Preview build 的普通 getter。**
6. **Chat 图片 `Image.memory` 增加 `cacheWidth`。**
7. **普通 Knowledge Graph Physics 改为 painter/listenable 局部 repaint。**
8. **Capture/Chat Tracker 状态更新不再调用 Workspace 顶层 setState。**

这 8 项完成之后再 Profile。

如果此时已经明显流畅，第二轮再做：

```text
Chat Recovery 分片
Markdown Sliver
文档 Lazy Load
Isolate 序列化
音频 Hash Isolate
LocalDocumentStore IO 深化优化
```

---

# 29. 不建议“一次性大改”的原因

当前工程功能已经很多：

```text
Editor
AI Chat
Document Sync
Book Work
Topics
Notifications
Recordings
Knowledge Graph
Assets
Markdown Preview
```

如果为了性能一次把 `EditorWorkspace` 全部重写：

- 回归面太大；
- 很难判断性能提升来自哪一项；
- 很容易破坏离线恢复、同步或边界状态；
- Review 困难。

更稳妥的方式是：

```text
先测
↓
每次只切一个高频状态边界
↓
补测试
↓
Profile 对比
↓
再做下一项
```

这也是本方案将优化拆成多个 commit 的原因。

---

# 30. 最终判断

目前代码中最需要警惕的不是某一个“超大的 Dart 文件”本身，而是：

```text
巨型 State 边界
+ 高频全局 setState
+ 高频全文派生计算
+ 长期累积的全量 Snapshot/Chat History
+ 全量 JSON 重写
+ 全尺寸图片 decode
+ 长期不停的 Physics ticker
```

其中：

## 直接造成“动作卡手”的核心

```text
Editor body → EditorWorkspace.setState
Paragraph context → full document.toPlainText
Live Preview → full snapshot / markdown compile
Graph physics → whole Graph setState
```

## 直接造成“运行久了越来越卡”的核心

```text
Unbound Document Outbox 全 Snapshot 累积
Chat Recovery 全消息常驻 + 全快照重写
图片 decoded memory
所有完整 Document Snapshot 长期驻留
持续 idle Physics
```

第一轮不要追求“重写架构”，而应优先把这些可确认的放大器切断。

完成 P0 + P1 后，现有功能可以全部保留，同时能够显著减少：

- 无效 Widget build；
- 主线程同步全文计算；
- 重复 JSON 序列化；
- 长期内存增长；
- 磁盘写入放大；
- 图片解码峰值；
- 后台持续 CPU 消耗。

---

# 31. 建议最终验收标准

优化完成后，至少达到：

```text
① 同一输入动作不再触发整个 Workspace rebuild。

② Live Preview 开启时，大文档输入仍保持可连续操作，
   Preview 最终在 120～250 ms 内追上最新 revision。

③ Remote write disabled / 新文档未绑定情况下，
   Outbox 不会随着 autosave revision 线性增长。

④ 打开很多 Chat 后，完整消息内存有明确上限，
   旧消息仍可从磁盘恢复。

⑤ 图片多的 Chat 不再因为超高分辨率 decode 造成明显内存峰值。

⑥ Knowledge Graph idle 时 CPU 显著下降，
   但动画和交互视觉功能保留。

⑦ 录音/转写后台轮询不会周期性重建编辑器工作区。

⑧ 运行 1～2 小时后，
   在重复同一组操作的前提下，
   内存、Outbox、Recovery cache 应趋于平台区间，
   而不是持续单调增长。

⑨ 所有 autosave / crash recovery / sync / chat recovery / graph /
   recording 功能回归通过。
```

---

## 推荐执行优先级

```text
P0
├── Sync Outbox compact
├── Editor body rebuild isolation
├── Paragraph context debounce
└── Markdown companion debounce/cache

P1
├── Toolbar narrow state
├── Chat recovery split/LRU
├── Graph painter-only repaint + adaptive idle FPS
├── Image decode limit
├── Explorer local state/lazy list
├── Capture local state
└── Local autosave IO reduction

P2
├── Full document lazy loading
├── Markdown block Sliver
├── Serialization isolate
└── Audio hash isolate
```

**先完成 P0，再用 Flutter DevTools Profile mode 做一次长文档 + 30 分钟运行测试。**  
如果 P0 完成后输入与运行时退化已经大幅改善，再继续 P1；这样对工程功能影响最小，也最容易回归和定位。
